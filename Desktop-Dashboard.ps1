param(
    [string]$Project = "Android 5.1.1"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Suppress RichTextBox repaint while replacing its contents to prevent flicker.
if (-not ("DevBridgeNativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevBridgeNativeMethods {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
}
"@
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BridgeScript = Join-Path $Root "DevBridge.ps1"
$LogPath = Join-Path $Root "logs/devbridge.log"
$BuildLogPath = Join-Path $Root "logs/last-build.log"
$StopPath = Join-Path $Root "state/stop-monitoring.request"
$script:BridgeProcess = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = "DevBridge - Android 5.1.1 monitor"
$form.Size = New-Object System.Drawing.Size(900, 620)
$form.MinimumSize = New-Object System.Drawing.Size(720, 480)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245,247,250)

$header = New-Object System.Windows.Forms.Label
$header.Text = "DEVBRIDGE / ANDROID 5.1.1"
$header.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
$header.Location = New-Object System.Drawing.Point(22,18)
$header.Size = New-Object System.Drawing.Size(600,36)
$form.Controls.Add($header)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(22,66)
$statusPanel.Size = New-Object System.Drawing.Size(840,92)
$statusPanel.Anchor = "Top,Left,Right"
$statusPanel.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($statusPanel)

$status = New-Object System.Windows.Forms.Label
$status.Text = "Stopped"
$status.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$status.Location = New-Object System.Drawing.Point(18,12)
$status.Size = New-Object System.Drawing.Size(600,30)
$status.ForeColor = [System.Drawing.Color]::FromArgb(90,98,110)
$statusPanel.Controls.Add($status)

$detail = New-Object System.Windows.Forms.Label
$detail.Text = "Monitoring branch compat/android-5.1.1-api22-vosk"
$detail.Location = New-Object System.Drawing.Point(20,49)
$detail.Size = New-Object System.Drawing.Size(780,24)
$detail.ForeColor = [System.Drawing.Color]::DimGray
$statusPanel.Controls.Add($detail)

$start = New-Object System.Windows.Forms.Button
$start.Text = "Start monitoring"
$start.Location = New-Object System.Drawing.Point(22,174)
$start.Size = New-Object System.Drawing.Size(230,42)
$start.BackColor = [System.Drawing.Color]::FromArgb(35,135,85)
$start.ForeColor = [System.Drawing.Color]::White
$start.FlatStyle = "Flat"
$start.FlatAppearance.BorderSize = 0
$start.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$form.Controls.Add($start)

$stop = New-Object System.Windows.Forms.Button
$stop.Text = "Stop"
$stop.Location = New-Object System.Drawing.Point(264,174)
$stop.Size = New-Object System.Drawing.Size(170,42)
$stop.BackColor = [System.Drawing.Color]::FromArgb(190,65,65)
$stop.ForeColor = [System.Drawing.Color]::White
$stop.FlatStyle = "Flat"
$stop.FlatAppearance.BorderSize = 0
$stop.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$stop.Enabled = $false
$form.Controls.Add($stop)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = "Event log"
$logTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$logTitle.Location = New-Object System.Drawing.Point(22,235)
$logTitle.Size = New-Object System.Drawing.Size(300,25)
$form.Controls.Add($logTitle)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(22,265)
$logBox.Size = New-Object System.Drawing.Size(840,285)
$logBox.Anchor = "Top,Bottom,Left,Right"
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(24,28,35)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(225,231,239)
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BorderStyle = "FixedSingle"
$form.Controls.Add($logBox)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = "Closing this window does not stop the background monitor."
$footer.Location = New-Object System.Drawing.Point(22,560)
$footer.Size = New-Object System.Drawing.Size(840,22)
$footer.Anchor = "Bottom,Left"
$footer.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($footer)

function Set-Running([bool]$running, [string]$message = "") {
    if ($running) {
        $status.Text = "Monitoring is running"
        $status.ForeColor = [System.Drawing.Color]::FromArgb(35,135,85)
        $start.Enabled = $false
        $stop.Enabled = $true
        if ($message) { $detail.Text = $message }
    } else {
        $status.Text = "Stopped"
        $status.ForeColor = [System.Drawing.Color]::FromArgb(90,98,110)
        $start.Enabled = $true
        $stop.Enabled = $false
        if ($message) { $detail.Text = $message }
    }
}

function Test-BridgeRunning {
    return ($null -ne $script:BridgeProcess -and -not $script:BridgeProcess.HasExited)
}

$start.Add_Click({
    if (Test-BridgeRunning) { return }
    if (-not (Test-Path -LiteralPath $BridgeScript)) {
        [System.Windows.Forms.MessageBox]::Show("DevBridge.ps1 was not found in the project folder.", "DevBridge") | Out-Null
        return
    }
    $stateDir = Join-Path $Root "state"
    $logDir = Join-Path $Root "logs"
    New-Item -ItemType Directory -Force -Path $stateDir,$logDir | Out-Null
    if (Test-Path -LiteralPath $StopPath) { Remove-Item -LiteralPath $StopPath -Force }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $BridgeScript + '" -Project "' + $Project.Replace('"','') + '"'
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:BridgeProcess = New-Object System.Diagnostics.Process
    $script:BridgeProcess.StartInfo = $psi
    try {
        if (-not $script:BridgeProcess.Start()) { throw "Could not start DevBridge." }
        Set-Running $true "Starting DevBridge and checking the remote branch..."
    } catch {
        Set-Running $false
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Launch error") | Out-Null
    }
})

$stop.Add_Click({
    if (Test-BridgeRunning) {
        New-Item -ItemType File -Force -Path $StopPath | Out-Null
        $stop.Enabled = $false
        $status.Text = "Stopping..."
        $status.ForeColor = [System.Drawing.Color]::FromArgb(180,120,35)
        $detail.Text = "DevBridge will stop safely after the current operation."
    } else {
        Set-Running $false
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if (Test-BridgeRunning) {
        $start.Enabled = $false
        if (-not (Test-Path -LiteralPath $StopPath) -and $status.Text -notlike "*running*") {
            Set-Running $true "Monitoring origin/compat/android-5.1.1-api22-vosk."
        }
    } elseif ($script:BridgeProcess -and $script:BridgeProcess.HasExited) {
        $exit = $script:BridgeProcess.ExitCode
        Set-Running $false ("Process exited (code {0}). You can start it again." -f $exit)
    }

    try {
        $eventLines = @()
        $buildLines = @()
        if (Test-Path -LiteralPath $LogPath) {
            $eventLines = @(Get-Content -LiteralPath $LogPath -Tail 60 -ErrorAction Stop)
        }
        if (Test-Path -LiteralPath $BuildLogPath) {
            $buildLines = @(Get-Content -LiteralPath $BuildLogPath -Tail 100 -ErrorAction Stop)
        }

        # Newest output is always shown first. The build log is streamed by
        # Tee-Object while Gradle runs, so this view updates during the build.
        [array]::Reverse($eventLines)
        [array]::Reverse($buildLines)
        $display = New-Object System.Collections.Generic.List[string]
        if ($buildLines.Count -gt 0) {
            $display.Add("=== LIVE BUILD OUTPUT (newest first) ===")
            foreach ($line in $buildLines) { $display.Add([string]$line) }
            $display.Add("")
        }
        if ($eventLines.Count -gt 0) {
            $display.Add("=== EVENTS (newest first) ===")
            foreach ($line in $eventLines) { $display.Add([string]$line) }
        }
        $newText = $display -join [Environment]::NewLine
        if ($logBox.Text -ne $newText) {
            # Prevent the control from painting intermediate blank/partial frames.
            [void][DevBridgeNativeMethods]::SendMessage($logBox.Handle, 0x000B, [IntPtr]::Zero, [IntPtr]::Zero)
            try {
                $logBox.Text = $newText
                $logBox.SelectionStart = 0
                $logBox.ScrollToCaret()
                $logBox.SelectionStart = 0
            } finally {
                [void][DevBridgeNativeMethods]::SendMessage($logBox.Handle, 0x000B, [IntPtr]::new(1), [IntPtr]::Zero)
                $logBox.Invalidate()
            }
        }

        if ($eventLines.Count -gt 0) {
            $latest = [string]$eventLines[0]
            if ($latest -match 'Build finished with exit code 0') {
                $detail.Text = "Build completed successfully."
            } elseif ($latest -match 'Build finished with exit code') {
                $detail.Text = "Build failed - see the build output above."
            } elseif ($latest -match 'Building commit') {
                $detail.Text = "Build is running - live Gradle output is shown below."
            } elseif ($latest -match 'New remote commit detected|Coalescing rapid commits') {
                $detail.Text = "GitHub changes detected - waiting for the commit batch to finish."
            } elseif ($latest -match 'Automatic Git monitoring enabled') {
                $detail.Text = "Waiting for GitHub commits; polling every 20 seconds."
            } elseif ($latest -match 'DevBridge stopped') {
                $detail.Text = "Monitoring stopped."
            }
        }
        if ($buildLines.Count -gt 0 -and $eventLines.Count -gt 0 -and ([string]$eventLines[0] -match 'Building commit')) {
            $detail.Text = "Build is running - live Gradle output is shown below."
        }
    } catch {}
})
$timer.Start()

$form.Add_FormClosing({
    $timer.Stop()
})

[void]$form.ShowDialog()
