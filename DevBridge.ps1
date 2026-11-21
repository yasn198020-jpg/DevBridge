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

if (-not (Test-Path -LiteralPath $SettingsPath)) { throw "Missing config/settings.json" }
if (-not (Test-Path -LiteralPath $ProjectsPath)) {
    throw "Create config/projects.json from config/projects.example.json and configure a project."
}
$settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
$projectConfig = Get-Content -LiteralPath $ProjectsPath -Raw | ConvertFrom-Json
$projects = @($projectConfig.projects)

if (-not $Project) {
    $enabled = @($projects | Where-Object { $_.enabled })
    if ($enabled.Count -ne 1) { throw "Specify -Project or enable exactly one project in config/projects.json." }
    $selected = $enabled[0]
} else {
    $selected = $projects | Where-Object { $_.name -eq $Project } | Select-Object -First 1
    if (-not $selected) { throw "Project '$Project' was not found in config/projects.json." }
}

$repo = [IO.Path]::GetFullPath([string]$selected.repository)
if (-not (Test-Path -LiteralPath (Join-Path $repo ".git"))) { throw "Not a Git working tree: $repo" }
$expectedBranch = [string]$selected.branch
$actualBranch = (Invoke-Git $repo @("branch", "--show-current") | Select-Object -First 1).Trim()
if ($actualBranch -ne $expectedBranch) {
    throw "Branch mismatch. Expected '$expectedBranch', found '$actualBranch'. DevBridge will not switch branches automatically."
}
$status = Invoke-Git $repo @("status", "--porcelain")
if (@($status | Where-Object { $_.Trim() }).Count -gt 0) {
    throw "Working tree is not clean. Commit or stash local changes before DevBridge can pull."
}

if ($CheckOnly) {
    Write-Log "Preflight OK: project='$($selected.name)', branch='$actualBranch', repo='$repo'."
    exit 0
}

Write-Log "Fetching origin/$expectedBranch"
Invoke-Git $repo @("fetch", "origin", $expectedBranch) | Out-Null
Invoke-Git $repo @("merge-base", "--is-ancestor", "HEAD", "origin/$expectedBranch") | Out-Null
Write-Log "Fast-forwarding local branch"
Invoke-Git $repo @("pull", "--ff-only", "origin", $expectedBranch) | Out-Null

$buildCommand = [string]$selected.buildCommand
$buildArgs = @($selected.buildArguments)
$working = if ($selected.workingDirectory -and $selected.workingDirectory -ne ".") {
    Join-Path $repo ([string]$selected.workingDirectory)
} else { $repo }

Write-Log "Starting build: $buildCommand $($buildArgs -join ' ')"
Push-Location $working
try {
    & $buildCommand @buildArgs 2>&1 | Tee-Object -FilePath (Join-Path $LogRoot "last-build.log")
    $buildExit = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($buildExit -ne 0) {
    Write-Log "BUILD FAILED (exit $buildExit). See logs/last-build.log"
    exit $buildExit
}
Write-Log "BUILD SUCCEEDED"
