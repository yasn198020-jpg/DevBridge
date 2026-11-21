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
    # Only accept the final non-empty line. Ignore commands shown inside fenced examples.
    $plain = [regex]::Replace($Message, '(?s)```.*?```', '')
    $lines = @($plain -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return $null }
    $lastLine = $lines[$lines.Count - 1].Trim()
    if ($lastLine -match '^DEVBRIDGE:\s*(BUILD|WAIT|DONE|ABORT)
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

Build output (last lines):
```text
$LogText
```

Please inspect the result. If a code change is needed, make it in this repository and branch, then finish your reply with exactly one command line:
DEVBRIDGE: BUILD
If the task is complete, reply with:
DEVBRIDGE: DONE
If you need to pause, use:
DEVBRIDGE: WAIT
"@
    Invoke-Bridge $script:BrowserProcess "send" $report | Out-Null
}
function Invoke-OneBuild {
    Assert-RepositorySafe
    Write-Log "Fetching origin/$expectedBranch"
    Invoke-Git $repo @("fetch", "origin", $expectedBranch) | Out-Null
    $localSha = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
    $remoteSha = (Invoke-Git $repo @("rev-parse", "origin/$expectedBranch") | Select-Object -First 1).Trim()
    if ($localSha -ne $remoteSha) {
        $ancestor = & git -C $repo merge-base --is-ancestor HEAD "origin/$expectedBranch" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Local branch is not behind the remote (or histories diverged). Refusing to reset, merge or rebase."
        }
        Invoke-Git $repo @("pull", "--ff-only", "origin", $expectedBranch) | Out-Null
    } else {
        Write-Log "No new remote commit; will run the configured build on current HEAD."
    }
    Assert-RepositorySafe
    $commit = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
    $buildCommand = [string]$selected.buildCommand
    $buildArgs = @($selected.buildArguments)
    $working = if ($selected.workingDirectory -and $selected.workingDirectory -ne ".") {
        Join-Path $repo ([string]$selected.workingDirectory)
    } else { $repo }
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
Assert-RepositorySafe
Write-Log "Selected project '$($selected.name)' on branch '$expectedBranch'."

if ($CheckOnly) {
    Write-Log "Preflight passed. No browser or build was started."
    exit 0
}
if (-not (Test-Path -LiteralPath $BridgePath)) { throw "Missing browser/bridge.mjs" }
$script:BrowserProcess = Start-Bridge
try {
    Write-Log "Opening ChatGPT browser. Sign in manually if needed."
    $snapshot = Invoke-Bridge $script:BrowserProcess "snapshot"
    $lastSeenHash = Get-MessageHash ([string]$snapshot.assistantText)
    Write-Log "Browser ready. Waiting for a NEW assistant message with a DevBridge command."
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
        $hash = Get-MessageHash $message
        if ($hash -eq $lastSeenHash) { continue }
        $command = Get-CommandFromMessage $message
        if (-not $command) { continue }
        $lastSeenHash = $hash
        Write-Log "Received command: $command"
        switch ($command) {
            "WAIT" { Write-Log "Assistant requested WAIT. Monitoring continues." }
            "DONE" { Write-Log "Assistant marked task DONE."; break }
            "ABORT" { throw "Assistant requested ABORT." }
            "BUILD" {
                $cycles++
                if ($cycles -gt $maxCycles) { throw "Maximum build cycle count ($maxCycles) reached." }
                Invoke-OneBuild
            }
        }
        if ($command -eq "DONE") { break }
    }
} finally {
    if ($script:BrowserProcess -and -not $script:BrowserProcess.HasExited) {
        try { Invoke-Bridge $script:BrowserProcess "quit" | Out-Null } catch {}
        try { $script:BrowserProcess.StandardInput.Close() } catch {}
        try { $script:BrowserProcess.Kill() } catch {}
    }
    Write-Log "DevBridge stopped."
}
) {
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

Build output (last lines):
```text
$LogText
```

Please inspect the result. If a code change is needed, make it in this repository and branch, then finish your reply with exactly one command line:
DEVBRIDGE: BUILD
If the task is complete, reply with:
DEVBRIDGE: DONE
If you need to pause, use:
DEVBRIDGE: WAIT
"@
    Invoke-Bridge $script:BrowserProcess "send" $report | Out-Null
}
function Invoke-OneBuild {
    Assert-RepositorySafe
    Write-Log "Fetching origin/$expectedBranch"
    Invoke-Git $repo @("fetch", "origin", $expectedBranch) | Out-Null
    $localSha = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
    $remoteSha = (Invoke-Git $repo @("rev-parse", "origin/$expectedBranch") | Select-Object -First 1).Trim()
    if ($localSha -ne $remoteSha) {
        $ancestor = & git -C $repo merge-base --is-ancestor HEAD "origin/$expectedBranch" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Local branch is not behind the remote (or histories diverged). Refusing to reset, merge or rebase."
        }
        Invoke-Git $repo @("pull", "--ff-only", "origin", $expectedBranch) | Out-Null
    } else {
        Write-Log "No new remote commit; will run the configured build on current HEAD."
    }
    Assert-RepositorySafe
    $commit = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
    $buildCommand = [string]$selected.buildCommand
    $buildArgs = @($selected.buildArguments)
    $working = if ($selected.workingDirectory -and $selected.workingDirectory -ne ".") {
        Join-Path $repo ([string]$selected.workingDirectory)
    } else { $repo }
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
Assert-RepositorySafe
Write-Log "Selected project '$($selected.name)' on branch '$expectedBranch'."

if ($CheckOnly) {
    Write-Log "Preflight passed. No browser or build was started."
    exit 0
}
if (-not (Test-Path -LiteralPath $BridgePath)) { throw "Missing browser/bridge.mjs" }
$script:BrowserProcess = Start-Bridge
try {
    Write-Log "Opening ChatGPT browser. Sign in manually if needed."
    $snapshot = Invoke-Bridge $script:BrowserProcess "snapshot"
    $lastSeenHash = Get-MessageHash ([string]$snapshot.assistantText)
    Write-Log "Browser ready. Waiting for a NEW assistant message with a DevBridge command."
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
        $hash = Get-MessageHash $message
        if ($hash -eq $lastSeenHash) { continue }
        $command = Get-CommandFromMessage $message
        if (-not $command) { continue }
        $lastSeenHash = $hash
        Write-Log "Received command: $command"
        switch ($command) {
            "WAIT" { Write-Log "Assistant requested WAIT. Monitoring continues." }
            "DONE" { Write-Log "Assistant marked task DONE."; break }
            "ABORT" { throw "Assistant requested ABORT." }
            "BUILD" {
                $cycles++
                if ($cycles -gt $maxCycles) { throw "Maximum build cycle count ($maxCycles) reached." }
                Invoke-OneBuild
            }
        }
        if ($command -eq "DONE") { break }
    }
} finally {
    if ($script:BrowserProcess -and -not $script:BrowserProcess.HasExited) {
        try { Invoke-Bridge $script:BrowserProcess "quit" | Out-Null } catch {}
        try { $script:BrowserProcess.StandardInput.Close() } catch {}
        try { $script:BrowserProcess.Kill() } catch {}
    }
    Write-Log "DevBridge stopped."
}
