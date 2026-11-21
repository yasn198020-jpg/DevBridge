param(
    [string]$Project = "",
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SettingsPath = Join-Path $Root "config/settings.json"
$ProjectsPath = Join-Path $Root "config/projects.json"
$LogRoot = Join-Path $Root "logs"
$StateRoot = Join-Path $Root "state"
$BridgePath = Join-Path $Root "browser/bridge.mjs"
New-Item -ItemType Directory -Force -Path $LogRoot, $StateRoot | Out-Null

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath (Join-Path $LogRoot "devbridge.log") -Value $line -Encoding UTF8
}
function Invoke-Git([string]$WorkingDirectory, [string[]]$GitArguments) {
    $output = & git -C $WorkingDirectory @GitArguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw ("git {0} failed (exit {1}): {2}" -f ($GitArguments -join " "), $code, ($output -join [Environment]::NewLine))
    }
    return @($output)
}
function Assert-RepositorySafe {
    $actual = (Invoke-Git $repo @("branch", "--show-current") | Select-Object -First 1).Trim()
    if ($actual -ne $expectedBranch) {
        throw "Branch mismatch. Expected '$expectedBranch', found '$actual'. DevBridge never switches branches automatically."
    }
    $dirty = Invoke-Git $repo @("status", "--porcelain")
    if (@($dirty | Where-Object { $_.Trim() }).Count -gt 0) {
        throw "Working tree is not clean. Commit or stash local changes before continuing."
    }
}
function Start-Bridge {
    $node = Get-Command node -ErrorAction Stop
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node.Source
    $psi.Arguments = '"' + $BridgePath + '"'
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { throw "Could not start browser bridge." }
    return $p
}
function Invoke-Bridge($Process, $Operation, $Text = $null) {
    $request = @{ op = $Operation }
    if ($null -ne $Text) { $request.text = $Text }
    $Process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress))
    $Process.StandardInput.Flush()
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait(30000)) { throw "Timed out waiting for browser bridge response ($Operation)." }
    $line = $task.Result
    if ([string]::IsNullOrWhiteSpace($line)) { throw "Browser bridge closed its output unexpectedly." }
    $response = $line | ConvertFrom-Json
    if (-not $response.ok) { throw "Browser bridge: $($response.error)" }
    return $response
}
function Get-CommandFromMessage([string]$Message) {
    # Only accept the final non-empty line; fenced code examples are ignored.
    $plain = [regex]::Replace($Message, '(?s)```.*?```', '')
    $lines = @($plain -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return $null }
    $lastLine = $lines[$lines.Count - 1].Trim()
    if ($lastLine -match '^DEVBRIDGE:\s*(BUILD|WAIT|DONE|ABORT)$') {
        return $Matches[1].ToUpperInvariant()
    }
    return $null
}
function Get-MessageHash([string]$Message) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Message)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally { $sha.Dispose() }
}
function Send-BuildReport([string]$Commit, [int]$ExitCode, [string]$LogText) {
    $limit = 18000
    if ($LogText.Length -gt $limit) { $LogText = $LogText.Substring($LogText.Length - $limit) }
    $statusText = if ($ExitCode -eq 0) { "BUILD SUCCEEDED" } else { "BUILD FAILED (exit $ExitCode)" }
    $report = @"
DevBridge build report
Project: $($selected.name)
Repository: $repo
Branch: $expectedBranch
Commit: $Commit
Result: $statusText

BUILD OUTPUT:
--------------------
$LogText
--------------------

Inspect the result. If code changes are needed, commit them to this same repository and branch, then end your reply with the standalone line DEVBRIDGE: BUILD.
If the task is complete and this build passed, end with DEVBRIDGE: DONE.
If you need to pause, end with DEVBRIDGE: WAIT.
"@
    Invoke-Bridge $script:BrowserProcess "send" $report | Out-Null
}
function Invoke-Handoff([string]$PreviousAssistantHash, [string]$PendingCommand = "NONE") {
    $handoffPrompt = @"
Prepare a handoff summary for continuing this exact development task in a NEW ChatGPT conversation.
Begin your response with this exact first line:
DEVBRIDGE HANDOFF SUMMARY

Include:
- repository URL and exact working branch
- user's original goal and constraints
- files and changes already made
- commits or revisions already completed
- build results and unresolved errors
- what is currently being attempted
- the single most useful next action
- pending DevBridge action at handoff time: $PendingCommand
- any important instructions needed to avoid repeating work

Be concise but preserve technical details. Do not claim anything was tested unless a build report confirms it. Do not include a DevBridge command line.
"@
    Invoke-Bridge $script:BrowserProcess "send" $handoffPrompt | Out-Null
    $timeoutSeconds = [Math]::Max(60, [int]$settings.automation.handoffWaitSeconds)
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $previousText = ""
    $stable = 0
    $summary = $null
    $poll = [Math]::Max(2, [int]$settings.automation.pollIntervalSeconds)
    Write-Log "Waiting for ChatGPT handoff summary (timeout ${timeoutSeconds}s)."
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $poll
        $snap = Invoke-Bridge $script:BrowserProcess "snapshot"
        $candidate = [string]$snap.assistantText
        if (-not $candidate) { continue }
        $candidateHash = Get-MessageHash ("$($snap.conversationMessageCount)|" + $candidate)
        if ($candidateHash -eq $PreviousAssistantHash) { continue }
        if ($candidate -eq $previousText) { $stable++ } else { $previousText = $candidate; $stable = 0 }
        if ($stable -lt 3) { continue }
        if ($candidate -match '^DEVBRIDGE HANDOFF SUMMARY(?:\r?\n|$)') {
            $summary = $candidate
            break
        }
        throw "ChatGPT returned a stable response without the required handoff marker. Stopping instead of opening a new chat."
    }
    if (-not $summary) { throw "Timed out waiting for the handoff summary. Current chat was left open." }

    $handoffPath = Join-Path $StateRoot "handoff.md"
    Set-Content -LiteralPath $handoffPath -Value $summary -Encoding UTF8
    Write-Log "Saved handoff summary to $handoffPath"
    Invoke-Bridge $script:BrowserProcess "newchat" | Out-Null
    $continuation = @"
We are continuing an existing development task. Read this handoff carefully and continue from the stated next action. Do not repeat completed work. Keep using the same repository and exact branch. Follow the DevBridge command protocol: when a local build is needed, finish your response with DEVBRIDGE: BUILD; when the task and build are complete, use DEVBRIDGE: DONE.

Pending DevBridge action: $PendingCommand. If it is BUILD, do not repeat source edits; simply resume by ending your response with DEVBRIDGE: BUILD.

$summary
"@
    Invoke-Bridge $script:BrowserProcess "send" $continuation | Out-Null
    Start-Sleep -Seconds 2
    $newChatSnapshot = Invoke-Bridge $script:BrowserProcess "snapshot"
    Write-Log "Opened a new chat and transferred the handoff summary."
    return (Get-MessageHash ("$($newChatSnapshot.conversationMessageCount)|" + [string]$newChatSnapshot.assistantText))
}
function Invoke-OneBuild {
    Assert-RepositorySafe
    Write-Log "Fetching origin/$expectedBranch"
    Invoke-Git $repo @("fetch", "origin", $expectedBranch) | Out-Null
    $localSha = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
    $remoteSha = (Invoke-Git $repo @("rev-parse", "origin/$expectedBranch") | Select-Object -First 1).Trim()
    if ($localSha -ne $remoteSha) {
        & git -C $repo merge-base --is-ancestor HEAD "origin/$expectedBranch" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Local branch is not behind the remote (or histories diverged). Refusing to reset, merge or rebase."
        }
        Invoke-Git $repo @("pull", "--ff-only", "origin", $expectedBranch) | Out-Null
    } else {
        Write-Log "No new remote commit; building current HEAD."
    }
    Assert-RepositorySafe
    $commit = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
    $buildCommand = [string]$selected.buildCommand
    $buildArgs = @($selected.buildArguments)
    $working = if ($selected.workingDirectory -and $selected.workingDirectory -ne ".") {
        Join-Path $repo ([string]$selected.workingDirectory)
    } else { $repo }
    if (-not (Test-Path -LiteralPath $working)) { throw "Build working directory does not exist: $working" }
    $buildLog = Join-Path $LogRoot "last-build.log"
    Write-Log "Building commit $commit"
    Push-Location $working
    try {
        & $buildCommand @buildArgs 2>&1 | Tee-Object -FilePath $buildLog
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
    } catch {
        $_ | Out-String | Tee-Object -FilePath $buildLog -Append
        $exitCode = 1
    } finally { Pop-Location }
    $logText = if (Test-Path $buildLog) { Get-Content $buildLog -Raw } else { "(No build output was captured.)" }
    $script:LastBuildExitCode = [int]$exitCode
    $script:HasBuildResult = $true
    Write-Log "Build finished with exit code $exitCode"
    Send-BuildReport $commit $exitCode $logText
}

if (-not (Test-Path $SettingsPath)) { throw "Missing config/settings.json" }
if (-not (Test-Path $ProjectsPath)) {
    throw "Create config/projects.json from config/projects.example.json and configure at least one project."
}
$settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
$projectConfig = Get-Content $ProjectsPath -Raw | ConvertFrom-Json
$projects = @($projectConfig.projects)
if (-not $Project) {
    $enabled = @($projects | Where-Object { $_.enabled })
    if ($enabled.Count -ne 1) { throw "Enable exactly one project or pass -Project with its name." }
    $selected = $enabled[0]
} else {
    $selected = $projects | Where-Object { $_.name -eq $Project } | Select-Object -First 1
    if (-not $selected) { throw "Project '$Project' was not found in config/projects.json." }
}
$repo = [IO.Path]::GetFullPath([string]$selected.repository)
$expectedBranch = [string]$selected.branch
if (-not (Test-Path -LiteralPath (Join-Path $repo ".git"))) { throw "Not a Git working tree: $repo" }
if (-not $expectedBranch) { throw "Project branch is not configured." }
if (-not $selected.buildCommand) { throw "Project buildCommand is not configured." }
if (-not (Get-Command ([string]$selected.buildCommand) -ErrorAction SilentlyContinue)) {
    throw "Build command '$($selected.buildCommand)' was not found on PATH. Use an installed command or an absolute executable path."
}
Assert-RepositorySafe
Write-Log "Selected project '$($selected.name)' on branch '$expectedBranch'."

if ($CheckOnly) {
    Write-Log "Preflight passed. No browser or build was started."
    exit 0
}
if (-not (Test-Path -LiteralPath $BridgePath)) { throw "Missing browser/bridge.mjs" }
$script:BrowserProcess = Start-Bridge
try {
    Write-Log "Opening ChatGPT browser. Sign in and open the intended conversation in Edge."
    [void](Read-Host "When the correct ChatGPT conversation is visible, press Enter here to start monitoring")
    $snapshot = Invoke-Bridge $script:BrowserProcess "snapshot"
    $lastSeenHash = Get-MessageHash ("$($snapshot.conversationMessageCount)|" + [string]$snapshot.assistantText)
    Write-Log "Waiting for a NEW assistant message ending with a DevBridge command."
    $cycles = 0
    $pollSeconds = [Math]::Max(2, [int]$settings.automation.pollIntervalSeconds)
    $maxCycles = [Math]::Max(1, [int]$settings.automation.maxBuildCycles)
    $lastText = ""
    $stableCount = 0
    while ($true) {
        Start-Sleep -Seconds $pollSeconds
        $snapshot = Invoke-Bridge $script:BrowserProcess "snapshot"
        $message = [string]$snapshot.assistantText
        if (-not $message) { continue }
        if ($message -eq $lastText) { $stableCount++ } else { $lastText = $message; $stableCount = 0 }
        if ($stableCount -lt 1) { continue }
        $hash = Get-MessageHash ("$($snapshot.conversationMessageCount)|" + $message)
        if ($hash -eq $lastSeenHash) { continue }
        $lastSeenHash = $hash
        $command = Get-CommandFromMessage $message
        if ($command -eq "DONE") {
            if (-not $script:HasBuildResult -or $script:LastBuildExitCode -ne 0) {
                throw "DONE rejected: no successful local build has been reported in this run."
            }
            Write-Log "Assistant marked task DONE after a successful local build."
            break
        }
        if ($command -eq "ABORT") { throw "Assistant requested ABORT." }

        $handoffThreshold = [int]$settings.automation.handoffAtConversationCharacters
        if ($handoffThreshold -gt 0 -and [int]$snapshot.conversationCharacters -ge $handoffThreshold) {
            $pendingCommand = if ($command -eq "BUILD") { "BUILD" } else { "NONE" }
            Write-Log "Conversation reached approximately $($snapshot.conversationCharacters) characters; starting handoff (pending: $pendingCommand)."
            $lastSeenHash = Invoke-Handoff $lastSeenHash $pendingCommand
            $lastText = ""
            $stableCount = 0
            continue
        }

        if ($command) {
            Write-Log "Received command: $command"
            switch ($command) {
                "WAIT" { Write-Log "Assistant requested WAIT. Monitoring continues." }
                "BUILD" {
                    $cycles++
                    if ($cycles -gt $maxCycles) { throw "Maximum build cycle count ($maxCycles) reached." }
                    Invoke-OneBuild
                }
            }
        }
    }
} finally {
    if ($script:BrowserProcess -and -not $script:BrowserProcess.HasExited) {
        try { Invoke-Bridge $script:BrowserProcess "quit" | Out-Null } catch {}
        try { $script:BrowserProcess.StandardInput.Close() } catch {}
        try { $script:BrowserProcess.Kill() } catch {}
    }
    Write-Log "DevBridge stopped."
}
