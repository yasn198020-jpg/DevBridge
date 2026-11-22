param([switch]$Uninstall)
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
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "DevBridge ChatGPT build monitor" -Force | Out-Null
Write-Host "DevBridge will start hidden at Windows sign-in. The browser will open visibly."
Write-Host "Start now: Start-ScheduledTask -TaskName DevBridge"
Write-Host "Remove: .\Install-Autostart.ps1 -Uninstall"
