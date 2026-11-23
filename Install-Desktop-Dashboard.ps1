$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dashboard = Join-Path $Root "Desktop-Dashboard.ps1"
if (-not (Test-Path -LiteralPath $Dashboard)) { throw "Desktop-Dashboard.ps1 was not found." }

$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "DevBridge-monitoring.lnk"

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Dashboard + '"'
$shortcut.WorkingDirectory = $Root
$shortcut.Description = "Start and stop DevBridge monitoring"
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,14"
$shortcut.Save()

Write-Host "Shortcut created: $shortcutPath"
Write-Host "Open DevBridge-monitoring on the desktop."
