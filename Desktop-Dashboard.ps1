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
$ProjectsConfigPath = Join-Path $Root "config/projects.json"
$script:ProjectConfigs = @()
if (Test-Path -LiteralPath $ProjectsConfigPath) {
    $projectsDocument = Get-Content -LiteralPath $ProjectsConfigPath -Raw | ConvertFrom-Json
    $script:ProjectConfigs = @($projectsDocument.projects | Where-Object {
        $_.repository -and $_.branch -and $_.name -and $_.buildCommand
    })
}
if ($script:ProjectConfigs.Count -eq 0) {
    throw "No build profiles found in config/projects.json. Existing profiles provide build commands; repository discovery itself is automatic."
}
$script:SelectedProject = $script:ProjectConfigs | Where-Object { $_.name -eq $Project } | Select-Object -First 1
if (-not $script:SelectedProject) {
    $script:SelectedProject = $script:ProjectConfigs | Where-Object { $_.enabled } | Select-Object -First 1
}
if (-not $script:SelectedProject) { $script:SelectedProject = $script:ProjectConfigs[0] }

function Get-RepositorySearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @("C:\tep\git", "I:\tep\git", (Join-Path $env:USERPROFILE "source\repos"), (Join-Path $env:USERPROFILE "git"))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container) -and -not $roots.Contains([IO.Path]::GetFullPath($candidate))) {
            $roots.Add([IO.Path]::GetFullPath($candidate))
        }
    }
    foreach ($profile in $script:ProjectConfigs) {
        $parent = Split-Path -Parent ([string]$profile.repository)
        if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
            $full = [IO.Path]::GetFullPath($parent)
            if (-not $roots.Contains($full)) { $roots.Add($full) }
        }
    }
    return @($roots)
}
function Find-LocalGitRepositories {
    $found = New-Object System.Collections.Generic.List[string]
    $visited = @{}
    $skipNames = @(".git", "node_modules", ".gradle", "build", "bin", "obj", "packages")
    $scan = {
        param([string]$folder, [int]$depth)
        if ($depth -gt 7 -or $visited.ContainsKey($folder)) { return }
        $visited[$folder] = $true
        if (Test-Path -LiteralPath (Join-Path $folder ".git")) {
            $found.Add([IO.Path]::GetFullPath($folder))
            return
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $folder -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($skipNames -notcontains $child.Name) { & $scan $child.FullName ($depth + 1) }
        }
    }
    foreach ($rootPath in (Get-RepositorySearchRoots)) { & $scan $rootPath 0 }
    foreach ($profile in $script:ProjectConfigs) {
        $path = [IO.Path]::GetFullPath([string]$profile.repository)
        if ((Test-Path -LiteralPath (Join-Path $path ".git")) -and -not $found.Contains($path)) { $found.Add($path) }
    }
    return @($found | Sort-Object -Unique)
}
function Get-RepositoryBranches([string]$RepositoryPath) {
    $lines = @(& git -C $RepositoryPath branch --format="%(refname:short)" 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($lines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}


$form = New-Object System.Windows.Forms.Form
$form.Text = ("DevBridge - {0}" -f $script:SelectedProject.name)
$form.Size = New-Object System.Drawing.Size(900, 620)
$form.MinimumSize = New-Object System.Drawing.Size(720, 480)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245,247,250)

$header = New-Object System.Windows.Forms.Label
$header.Text = "DEVBRIDGE / BUILD MONITOR"
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
$detail.Text = ("{0} | {1}" -f $script:SelectedProject.repository, $script:SelectedProject.branch)
$detail.AutoEllipsis = $true
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

$choose = New-Object System.Windows.Forms.Button
$choose.Text = "Choose repository / branch"
$choose.Location = New-Object System.Drawing.Point(452,174)
$choose.Size = New-Object System.Drawing.Size(250,42)
$choose.BackColor = [System.Drawing.Color]::FromArgb(65,105,160)
$choose.ForeColor = [System.Drawing.Color]::White
$choose.FlatStyle = "Flat"
$choose.FlatAppearance.BorderSize = 0
$choose.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$form.Controls.Add($choose)

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

function Show-ProjectSelector {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Select local repository and branch"
    $dialog.Size = New-Object System.Drawing.Size(720,330)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $repoLabel = New-Object System.Windows.Forms.Label
    $repoLabel.Text = "Local Git repository (automatic scan)"
    $repoLabel.Location = New-Object System.Drawing.Point(22,18)
    $repoLabel.Size = New-Object System.Drawing.Size(650,22)
    $dialog.Controls.Add($repoLabel)

    $repoCombo = New-Object System.Windows.Forms.ComboBox
    $repoCombo.Location = New-Object System.Drawing.Point(22,44)
    $repoCombo.Size = New-Object System.Drawing.Size(660,28)
    $repoCombo.DropDownStyle = "DropDownList"
    $dialog.Controls.Add($repoCombo)

    $branchLabel = New-Object System.Windows.Forms.Label
    $branchLabel.Text = "Local Git branches (current branch is marked with *)"
    $branchLabel.Location = New-Object System.Drawing.Point(22,84)
    $branchLabel.Size = New-Object System.Drawing.Size(650,22)
    $dialog.Controls.Add($branchLabel)

    $branchCombo = New-Object System.Windows.Forms.ComboBox
    $branchCombo.Location = New-Object System.Drawing.Point(22,110)
    $branchCombo.Size = New-Object System.Drawing.Size(660,28)
    $branchCombo.DropDownStyle = "DropDownList"
    $dialog.Controls.Add($branchCombo)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Location = New-Object System.Drawing.Point(22,148)
    $hint.Size = New-Object System.Drawing.Size(660,42)
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $dialog.Controls.Add($hint)

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = "Refresh scan"
    $refresh.Location = New-Object System.Drawing.Point(22,218)
    $refresh.Size = New-Object System.Drawing.Size(130,34)
    $dialog.Controls.Add($refresh)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Select"
    $ok.Location = New-Object System.Drawing.Point(462,218)
    $ok.Size = New-Object System.Drawing.Size(105,34)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Location = New-Object System.Drawing.Point(577,218)
    $cancel.Size = New-Object System.Drawing.Size(105,34)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)

    $script:DiscoveredRepositories = @()
    $script:DiscoveredBranches = @{}
    $loadRepositories = {
        $repoCombo.Items.Clear()
        $branchCombo.Items.Clear()
        $hint.Text = "Scanning local Git folders..."
        $dialog.Refresh()
        $script:DiscoveredRepositories = @(Find-LocalGitRepositories)
        foreach ($path in $script:DiscoveredRepositories) { [void]$repoCombo.Items.Add($path) }
        $preferred = [string]$script:SelectedProject.repository
        $repoCombo.SelectedItem = $preferred
        if ($repoCombo.SelectedIndex -lt 0 -and $repoCombo.Items.Count -gt 0) { $repoCombo.SelectedIndex = 0 }
        if ($repoCombo.Items.Count -eq 0) { $hint.Text = "No Git repositories found in the search folders." }
    }
    $loadBranches = {
        $branchCombo.Items.Clear()
        $repoValue = [string]$repoCombo.SelectedItem
        if (-not $repoValue) { return }
        $branches = @(Get-RepositoryBranches $repoValue)
        $script:DiscoveredBranches[$repoValue] = $branches
        $current = [string](& git -C $repoValue branch --show-current 2>$null)
        foreach ($branch in $branches) {
            $display = if ($branch -eq $current) { "* " + $branch } else { $branch }
            [void]$branchCombo.Items.Add($display)
        }
        $preferredBranch = [string]$script:SelectedProject.branch
        $index = -1
        for ($i = 0; $i -lt $branchCombo.Items.Count; $i++) {
            if ([string]$branchCombo.Items[$i] -eq ("* " + $preferredBranch) -or [string]$branchCombo.Items[$i] -eq $preferredBranch) { $index = $i; break }
        }
        if ($index -lt 0) {
            for ($i = 0; $i -lt $branchCombo.Items.Count; $i++) { if (([string]$branchCombo.Items[$i]).StartsWith("* ")) { $index = $i; break } }
        }
        if ($index -lt 0 -and $branchCombo.Items.Count -gt 0) { $index = 0 }
        if ($index -ge 0) { $branchCombo.SelectedIndex = $index }
        $profile = $script:ProjectConfigs | Where-Object { [IO.Path]::GetFullPath([string]$_.repository) -eq [IO.Path]::GetFullPath($repoValue) } | Select-Object -First 1
        if ($profile) {
            $hint.Text = "Build profile: " + [string]$profile.name + ". DevBridge will not switch branches automatically; select the branch currently checked out in Git."
        } else {
            $hint.Text = "Repository discovered, but no build profile exists for it in config/projects.json. It can be inspected, but cannot be built by DevBridge yet."
        }
    }
    $repoCombo.Add_SelectedIndexChanged($loadBranches)
    $refresh.Add_Click({ & $loadRepositories })
    & $loadRepositories
    & $loadBranches

    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $repoValue = [string]$repoCombo.SelectedItem
        $displayBranch = [string]$branchCombo.SelectedItem
        $branchValue = $displayBranch -replace '^\* ', ''
        $current = [string](& git -C $repoValue branch --show-current 2>$null)
        if (-not $repoValue -or -not $branchValue) {
            [System.Windows.Forms.MessageBox]::Show("Select a repository and branch.", "DevBridge") | Out-Null
        } elseif ($branchValue -ne $current) {
            [System.Windows.Forms.MessageBox]::Show("The selected branch is not checked out. DevBridge never switches branches automatically. Check out this branch in Git first, then select it again.", "Branch not active") | Out-Null
        } else {
            $match = $script:ProjectConfigs | Where-Object {
                [IO.Path]::GetFullPath([string]$_.repository) -eq [IO.Path]::GetFullPath($repoValue) -and $_.branch -eq $branchValue
            } | Select-Object -First 1
            if (-not $match) {
                [System.Windows.Forms.MessageBox]::Show("This repository/branch has no build profile. Existing build settings are kept unchanged.", "No build profile") | Out-Null
            } else {
                $script:SelectedProject = $match
                $form.Text = ("DevBridge - {0}" -f $script:SelectedProject.name)
                $detail.Text = ("{0} | {1}" -f $repoValue, $branchValue)
            }
        }
    }
    $dialog.Dispose()
}

$choose.Add_Click({
    if (Test-BridgeRunning) {
        [System.Windows.Forms.MessageBox]::Show("Stop monitoring before changing the selected repository or branch.", "DevBridge") | Out-Null
        return
    }
    Show-ProjectSelector
})

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
    $selectedName = ([string]$script:SelectedProject.name).Replace('"','')
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $BridgeScript + '" -Project "' + $selectedName + '"'
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
            Set-Running $true ("Monitoring {0} | {1}" -f $script:SelectedProject.repository, $script:SelectedProject.branch)
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
