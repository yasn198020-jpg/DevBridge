$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$failed = $false

Write-Host "=== DevBridge static validation ==="
$psFiles = @("DevBridge.ps1", "Install.ps1", "Install-Autostart.ps1", "Test-DevBridge.ps1")
foreach ($relative in $psFiles) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path $path)) { continue }
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) {
        $failed = $true
        Write-Host "FAIL PowerShell syntax: $relative" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host $_.Message }
    } else { Write-Host "PASS PowerShell syntax: $relative" -ForegroundColor Green }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { $failed = $true; Write-Host "FAIL Node.js not found." -ForegroundColor Red }
else {
    & $node.Source --check (Join-Path $Root "browser/bridge.mjs")
    if ($LASTEXITCODE -ne 0) { $failed = $true; Write-Host "FAIL JavaScript syntax: browser/bridge.mjs" -ForegroundColor Red }
    else { Write-Host "PASS JavaScript syntax: browser/bridge.mjs" -ForegroundColor Green }
}

foreach ($relative in @("config/settings.json", "config/settings.example.json", "config/projects.example.json")) {
    $path = Join-Path $Root $relative
    if (Test-Path $path) {
        try { Get-Content $path -Raw | ConvertFrom-Json | Out-Null; Write-Host "PASS JSON: $relative" -ForegroundColor Green }
        catch { $failed = $true; Write-Host "FAIL JSON: $relative - $($_.Exception.Message)" -ForegroundColor Red }
    }
}

$mainScript = Get-Content (Join-Path $Root "DevBridge.ps1") -Raw
if ($mainScript -match "Read-Host") { $failed = $true; Write-Host "FAIL Manual Enter prompt is still present." -ForegroundColor Red }
else { Write-Host "PASS No manual Enter prompt." -ForegroundColor Green }
if ($mainScript -notmatch "function Get-RemoteBuildTarget" -or
    $mainScript -notmatch "function Wait-ForQuietRemoteCommit" -or
    $mainScript -notmatch "gitPollIntervalSeconds" -or
    $mainScript -notmatch "Coalescing rapid commits" -or
    $mainScript -notmatch "Starting automatic build for the latest coalesced remote state") {
    $failed = $true
    Write-Host "FAIL Automatic Git monitoring or rapid-commit coalescing is missing." -ForegroundColor Red
} else { Write-Host "PASS Automatic Git monitoring coalesces rapid commits before building." -ForegroundColor Green }

if ($mainScript -notmatch "monitor-state\.json") { $failed = $true; Write-Host "FAIL Persistent conversation state is missing." -ForegroundColor Red }
else { Write-Host "PASS Persistent conversation state is configured." -ForegroundColor Green }
if ($mainScript -notmatch "build-publish-android511\.ps1" -or $mainScript -notmatch '"-VersionCode"' -or $mainScript -notmatch "versionInfo\.Next") {
    $failed = $true
    Write-Host "FAIL Android 5.1.1 must call the VS Code build script with an explicit VersionCode." -ForegroundColor Red
} else { Write-Host "PASS Android 5.1.1 uses the VS Code build script with an explicit VersionCode." -ForegroundColor Green }

if ($failed) { throw "DevBridge validation failed. Fix the reported errors before enabling autostart." }
Write-Host "ALL STATIC CHECKS PASSED." -ForegroundColor Green
