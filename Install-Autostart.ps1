param([switch]$Uninstall, [string]$Project = "")
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "DevBridge"
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed DevBridge automatic startup."
    } else { Write-Host "DevBridge automatic startup was not installed." }
    exit 0
}
$scriptPath = Join-Path $Root "DevBridge.ps1"
if (-not (Test-Path $scriptPath)) { throw "DevBridge.ps1 not found." }
$projectsPath = Join-Path $Root "config/projects.json"
if (-not (Test-Path $projectsPath)) { throw "Missing config/projects.json. Run Install.ps1 and configure a project first." }
$projectConfig = Get-Content $projectsPath -Raw | ConvertFrom-Json
$projects = @($projectConfig.projects)
if (-not $Project) {
    $enabled = @($projects | Where-Object { $_.enabled })
    if ($enabled.Count -ne 1) { throw 'Specify -Project "Project name" because config/projects.json does not have exactly one enabled project.' }
    $Project = [string]$enabled[0].name
}
if (-not ($projects | Where-Object { $_.name -eq $Project })) { throw "Project '$Project' was not found in config/projects.json." }
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Project "' + $Project.Replace('"', '') + '"'
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "DevBridge ChatGPT build monitor" -Force | Out-Null
Write-Host "DevBridge will start hidden at Windows sign-in. The browser will open visibly."
Write-Host "Start now: Start-ScheduledTask -TaskName DevBridge"
Write-Host "Remove: .\Install-Autostart.ps1 -Uninstall"
