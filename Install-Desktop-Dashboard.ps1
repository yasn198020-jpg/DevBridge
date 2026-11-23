$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dashboard = Join-Path $Root "Desktop-Dashboard.ps1"
if (-not (Test-Path -LiteralPath $Dashboard)) { throw "Desktop-Dashboard.ps1 was not found." }

$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "DevBridge — мониторинг.lnk"

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Dashboard + '"'
$shortcut.WorkingDirectory = $Root
$shortcut.Description = "Запуск и остановка мониторинга DevBridge"
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,14"
$shortcut.Save()

Write-Host "Создан ярлык: $shortcutPath"
Write-Host "Откройте ярлык «DevBridge — мониторинг» на рабочем столе."
