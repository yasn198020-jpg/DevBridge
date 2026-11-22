param()
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($tool in @("git", "node", "npm")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found on PATH." }
}
$settingsPath = Join-Path $Root "config/settings.json"
if (-not (Test-Path $settingsPath)) { throw "Missing config/settings.json." }
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
$browserExe = [string]$settings.browser.executablePath
if (-not $browserExe -or -not (Test-Path -LiteralPath $browserExe)) { throw "Configured browser executable not found: '$browserExe'." }
Push-Location $Root
try {
    npm install --no-package-lock
    if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE." }
    $projectsPath = Join-Path $Root "config/projects.json"
    if (-not (Test-Path $projectsPath)) {
        Copy-Item (Join-Path $Root "config/projects.example.json") $projectsPath
        Write-Host "Created config/projects.json."
    }
} finally { Pop-Location }
Write-Host "Setup complete. Configure projects, run .\DevBridge.ps1 -CheckOnly, then .\Install-Autostart.ps1 to enable logon startup."
