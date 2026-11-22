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
    # Windows PowerShell 5.1 can treat native stderr output as a terminating
    # error when the global ErrorActionPreference is Stop. Git commonly writes
    # progress to stderr even when the command succeeds, so capture its output
    # and rely on LASTEXITCODE for the actual result.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & git -C $WorkingDirectory @GitArguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

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
    $psi.StandardOutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { throw "Could not start browser bridge." }
    return $p
}
function Invoke-Bridge($Process, $Operation, $Text = $null, $ConversationId = $null, [bool]$PinPreferred = $false) {
    if ($Process.HasExited) { throw "Browser bridge process has exited (code $($Process.ExitCode))." }
    $request = @{ op = $Operation }
    if ($null -ne $Text) { $request.text = $Text }
    if ($null -ne $ConversationId) { $request.conversationId = $ConversationId }
    if ($PinPreferred) { $request.pinPreferred = $true }
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
    if ($lastLine -match '^DEVBRIDGE:\s*(BUILD(?:\s+READY)?|WAIT|DONE|ABORT)\s*$') {
        $command = $Matches[1].ToUpperInvariant() -replace '\s+', ' '
        if ($command -eq "BUILD READY") { return "BUILD" }
        return $command
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
function Send-BuildReport([string]$Commit, [int]$ExitCode, [string]$LogText, [string]$ConversationId) {
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

Inspect the result. If code changes are needed, commit them to this same repository and branch, then end your reply with the standalone line DEVBRIDGE: BUILD READY. The older DEVBRIDGE: BUILD command is also accepted.
If the task is complete and this build passed, end with DEVBRIDGE: DONE.
If you need to pause, end with DEVBRIDGE: WAIT.
"@
    Invoke-Bridge $script:BrowserProcess "send" $report $ConversationId | Out-Null
}
function Assert-LastBuildCurrent {
    if (-not $script:HasBuildResult -or $script:LastBuildExitCode -ne 0 -or -not $script:LastBuiltCommit) {
        throw "DONE rejected: no successful local build has been reported in this run."
    }
    Assert-RepositorySafe
    Invoke-Git $repo @("fetch", "origin", $expectedBranch) | Out-Null
    $head = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
    $remote = (Invoke-Git $repo @("rev-parse", "origin/$expectedBranch") | Select-Object -First 1).Trim()
    if ($head -ne $remote -or $head -ne $script:LastBuiltCommit) {
        throw "DONE rejected: the configured branch has changed since the last successful build. ChatGPT must issue DEVBRIDGE: BUILD again."
    }
}
function Invoke-Handoff([string]$PreviousAssistantHash, [string]$PendingCommand = "NONE", [string]$ConversationId = "") {
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
    Invoke-Bridge $script:BrowserProcess "send" $handoffPrompt $ConversationId | Out-Null
    $timeoutSeconds = [Math]::Max(60, [int]$settings.automation.handoffWaitSeconds)
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $previousText = ""
    $stable = 0
    $summary = $null
    $poll = [Math]::Max(2, [int]$settings.automation.pollIntervalSeconds)
    Write-Log "Waiting for ChatGPT handoff summary (timeout ${timeoutSeconds}s)."
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $poll
        $snap = Invoke-Bridge $script:BrowserProcess "snapshot" $null $ConversationId
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
    Invoke-Bridge $script:BrowserProcess "newchat" $null $ConversationId | Out-Null
    $continuation = @"
We are continuing an existing development task. Read this handoff carefully and continue from the stated next action. Do not repeat completed work. Keep using the same repository and exact branch. Follow the DevBridge command protocol: when a local build is needed and the complete commit batch is ready, finish your response with DEVBRIDGE: BUILD READY; when the task and build are complete, use DEVBRIDGE: DONE.

Pending DevBridge action: $PendingCommand. If it is BUILD, do not repeat source edits; simply resume by ending your response with DEVBRIDGE: BUILD.

$summary
"@
    Invoke-Bridge $script:BrowserProcess "send" $continuation $null $true | Out-Null
    $newChatSnapshot = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Start-Sleep -Seconds 1
        $newChatSnapshot = Invoke-Bridge $script:BrowserProcess "snapshot" $null $null $true
        if ($newChatSnapshot.conversationId) { break }
    }
    Write-Log "Opened a new chat and transferred the handoff summary."
    return $newChatSnapshot
}
function Get-NextBuildVersion {
    if (-not $selected.versionSource) { return $null }

    $source = $selected.versionSource
    $url = [string]$source.url
    $field = [string]$source.field
    $increment = if ($null -ne $source.increment) { [int]$source.increment } else { 1 }
    $minimum = if ($null -ne $source.minimum) { [int]$source.minimum } else { 1 }

    if ($url -notmatch '^https://') { throw "versionSource.url must use HTTPS." }
    if (-not $field) { throw "versionSource.field is required." }
    if ($increment -lt 1) { throw "versionSource.increment must be at least 1." }
    if ($minimum -lt 1) { throw "versionSource.minimum must be at least 1." }

    # Windows PowerShell 5.1 may otherwise negotiate obsolete TLS defaults.
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $document = Invoke-RestMethod -Uri $url -Method Get -UseBasicParsing -TimeoutSec 20
    } catch {
        throw "Could not read build version from '$url': $($_.Exception.Message). Build was not started."
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
    }

    $property = $document.PSObject.Properties[$field]
    if (-not $property) { throw "Version field '$field' was not found in '$url'. Build was not started." }

    $current = 0L
    if (-not [long]::TryParse([string]$property.Value, [ref]$current) -or $current -lt $minimum) {
        throw "Invalid published version '$($property.Value)' in field '$field'. Minimum allowed is $minimum. Build was not started."
    }
    $next = $current + [long]$increment
    if ($next -gt 2147483647) { throw "Next version $next exceeds the supported Int32 range." }

    return [pscustomobject]@{
        Current = [int]$current
        Next = [int]$next
        Placeholder = [string]$source.placeholder
    }
}
function Resolve-BuildArguments($VersionInfo) {
    $arguments = @($selected.buildArguments | ForEach-Object { [string]$_ })
    if ($null -eq $VersionInfo) { return ,$arguments }

    if (-not $VersionInfo.Placeholder) {
        throw "versionSource.placeholder is required when automatic versioning is enabled."
    }
    $matches = @($arguments | Where-Object { $_.Contains($VersionInfo.Placeholder) }).Count
    if ($matches -ne 1) {
        throw "buildArguments must contain versionSource.placeholder exactly once ('$($VersionInfo.Placeholder)')."
    }

    for ($i = 0; $i -lt $arguments.Count; $i++) {
        $arguments[$i] = $arguments[$i].Replace($VersionInfo.Placeholder, [string]$VersionInfo.Next)
    }
    return ,$arguments
}
function Invoke-OneBuild([string]$ConversationId) {
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
    $versionInfo = Get-NextBuildVersion
    if ($null -ne $versionInfo) {
        Write-Log "Published version: $($versionInfo.Current); next build version: $($versionInfo.Next)"
    }
    $buildCommand = [string]$selected.buildCommand
    $buildArgs = Resolve-BuildArguments $versionInfo
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
    $script:LastBuiltCommit = $commit
    $script:HasBuildResult = $true
    Write-Log "Build finished with exit code $exitCode"
    Send-BuildReport $commit $exitCode $logText $ConversationId
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
    $versionInfo = Get-NextBuildVersion
    if ($null -ne $versionInfo) {
        # Validate placeholder and show the exact version without starting a build.
        [void](Resolve-BuildArguments $versionInfo)
        Write-Log "Version check passed. Published: $($versionInfo.Current); next build: $($versionInfo.Next)"
    }
    Write-Log "Preflight passed. No browser or build was started."
    exit 0
}
if (-not (Test-Path -LiteralPath $BridgePath)) { throw "Missing browser/bridge.mjs" }
$browserExe = [string]$settings.browser.executablePath
if (-not $browserExe -or -not (Test-Path -LiteralPath $browserExe)) { throw "Configured browser executable was not found: '$browserExe'." }
$profileSetting = [string]$settings.browser.profileDirectory
if (-not $profileSetting) { $profileSetting = "browser-profile" }
$browserProfile = if ([IO.Path]::IsPathRooted($profileSetting)) { $profileSetting } else { Join-Path $Root $profileSetting }
New-Item -ItemType Directory -Force -Path $browserProfile | Out-Null
$cdpUrl = [string]$settings.browser.cdpUrl
if (-not $cdpUrl) { $cdpUrl = "http://127.0.0.1:9222" }
$cdpPort = 9222
try { $cdpPort = [int]([uri]$cdpUrl).Port } catch {}
$cdpReady = $false
try { $null = Invoke-RestMethod -Uri ($cdpUrl.TrimEnd("/") + "/json/version") -TimeoutSec 2; $cdpReady = $true } catch {}
if (-not $cdpReady) {
    $chatUrl = [string]$settings.browser.chatUrl
    if (-not $chatUrl) { $chatUrl = "https://chatgpt.com/" }
    Write-Log "Starting configured browser with the persistent DevBridge profile."
    Start-Process -FilePath $browserExe -ArgumentList @("--remote-debugging-port=$cdpPort", "--user-data-dir=$browserProfile", $chatUrl) | Out-Null
}
$script:BrowserProcess = Start-Bridge
try {
    $snapshot = $null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        try { $snapshot = Invoke-Bridge $script:BrowserProcess "snapshot"; break } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $snapshot) { throw "Could not connect to the browser or open ChatGPT within 90 seconds." }
    $statePath = Join-Path $StateRoot "monitor-state.json"
    $chatHashes = @{}
    if (Test-Path $statePath) {
        try {
            $saved = Get-Content $statePath -Raw | ConvertFrom-Json
            if ($saved.chats) { foreach ($prop in $saved.chats.PSObject.Properties) { $chatHashes[$prop.Name] = [string]$prop.Value } }
        } catch { Write-Log "Monitor state unreadable; creating a fresh safe baseline." }
    }
    function Save-ChatState {
        $state = @{ chats = $chatHashes; lastChatUrl = [string]$snapshot.url }
        $tmp = $statePath + ".tmp"
        Set-Content -LiteralPath $tmp -Value ($state | ConvertTo-Json -Depth 8) -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $statePath -Force
    }
    $chatId = [string]$snapshot.conversationId
    if ($chatId) {
        $chatHashes[$chatId] = Get-MessageHash ([string]$snapshot.assistantMessageId + "|" + [string]$snapshot.assistantText)
        Save-ChatState
    }
    Write-Log "Monitoring started automatically; no Enter key is required. $($snapshot.url)"
    $cycles = 0
    $pollSeconds = [Math]::Max(2, [int]$settings.automation.pollIntervalSeconds)
    $maxCycles = [Math]::Max(1, [int]$settings.automation.maxBuildCycles)
    $pendingKey = ""
    $stable = 0
    while ($true) {
        Start-Sleep -Seconds $pollSeconds
        $snapshot = Invoke-Bridge $script:BrowserProcess "snapshot"
        $chatId = [string]$snapshot.conversationId
        if (-not $chatId -or -not $snapshot.assistantText) { continue }
        $message = [string]$snapshot.assistantText
        $hash = Get-MessageHash ([string]$snapshot.assistantMessageId + "|" + $message)
        if (-not $chatHashes.ContainsKey($chatId)) {
            $chatHashes[$chatId] = $hash
            Save-ChatState
            $pendingKey = ""; $stable = 0
            Write-Log "New conversation selected; current answer baselined without executing history."
            continue
        }
        if ($hash -eq $chatHashes[$chatId]) { $pendingKey = ""; $stable = 0; continue }
        $key = $chatId + "|" + $hash
        if ($key -eq $pendingKey) { $stable++ } else { $pendingKey = $key; $stable = 0 }
        if ($stable -lt 2) { continue }
        $chatHashes[$chatId] = $hash
        Save-ChatState
        $command = Get-CommandFromMessage $message
        if ($command -eq "DONE") {
            try { Assert-LastBuildCurrent; Write-Log "Assistant marked task DONE after successful latest build."; break }
            catch {
                $feedback = "DevBridge rejected DONE for safety: $($_.Exception.Message) Inspect repository state and use DEVBRIDGE: BUILD or DEVBRIDGE: WAIT."
                Invoke-Bridge $script:BrowserProcess "send" $feedback $chatId | Out-Null
                continue
            }
        }
        if ($command -eq "ABORT") { throw "Assistant requested ABORT." }
        $threshold = [int]$settings.automation.handoffAtConversationCharacters
        if ($threshold -gt 0 -and [int]$snapshot.conversationCharacters -ge $threshold) {
            $pending = if ($command -eq "BUILD") { "BUILD" } else { "NONE" }
            Write-Log "Conversation reached handoff threshold; transferring to a new chat."
            $legacyHash = Get-MessageHash ("$($snapshot.conversationMessageCount)|" + $message)
            $handoffSnapshot = Invoke-Handoff $legacyHash $pending $chatId
            $handoffChatId = [string]$handoffSnapshot.conversationId
            if ($handoffChatId) {
                $chatHashes[$handoffChatId] = Get-MessageHash ("|")
                Save-ChatState
            }
            $pendingKey = ""; $stable = 0
            continue
        }
        if ($command) {
            Write-Log "Received command $command in conversation $chatId"
            switch ($command) {
                "WAIT" { Write-Log "Assistant requested WAIT." }
                "BUILD" {
                    $cycles++
                    if ($cycles -gt $maxCycles) { throw "Maximum build cycle count ($maxCycles) reached." }
                    Invoke-OneBuild $chatId
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
