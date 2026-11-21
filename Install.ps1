param()
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($tool in @("git", "node", "npm")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found on PATH. Install it and restart PowerShell."
    }
}
$programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
$edgePaths = @()
if ($programFilesX86) {
    $edgePaths += Join-Path $programFilesX86 "Microsoft\Edge\Application\msedge.exe"
}
if ($env:ProgramFiles) {
    $edgePaths += Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"
}
if (-not ($edgePaths | Where-Object { Test-Path $_ })) {
    Write-Warning "Microsoft Edge was not found in the standard install folders. Playwright may still locate it if installed elsewhere."
}
Push-Location $Root
try {
    npm install
    if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE." }
    $projectsPath = Join-Path $Root "config/projects.json"
    if (-not (Test-Path $projectsPath)) {
        Copy-Item (Join-Path $Root "config/projects.example.json") $projectsPath
        Write-Host "Created config/projects.json. Edit it before running DevBridge."
    }
} finally { Pop-Location }
Write-Host "Setup completed. Configure config/projects.json, then run DevBridge.ps1 -CheckOnly."
