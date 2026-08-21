<#
  FrivOSC — uninstaller

  Confirm, then a live step log, then a summary. The same shape as Evora's,
  with less to take away: no firewall rule, no hosts entry, no downloaded
  models. FrivOSC never installed anything outside its own folder, the
  ProgramData settings folder, one scheduled task, and one shortcut.
#>

[CmdletBinding()]
param(
    [switch] $Silent,
    [switch] $KeepSettings,
    [string] $InstallPath = (Split-Path -Parent $PSCommandPath)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSCommandPath
$LogPath = Join-Path ([IO.Path]::GetTempPath()) 'FrivOSC-Uninstall.log'
$TaskName = 'FrivOSC'
$DataDir = Join-Path $env:ProgramData 'FrivOSC'
$MarkerName = '.frivosc-install.json'
$MarkerId = 'com.frivo.frivosc'

$script:Steps = New-Object System.Collections.ArrayList

function Write-UninstallLog([string] $Text) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogPath -Value ("[{0}] {1}" -f $stamp, $Text) -Encoding utf8
}

function Add-Step([string] $Text, [bool] $Ok = $true) {
    $line = ('{0} [{1}]' -f $Text, $(if ($Ok) { 'OK' } else { 'FAILED' }))
    [void] $script:Steps.Add([pscustomobject]@{ Text = $Text; Ok = $Ok })
    Write-UninstallLog $line
    return $line
}

function Test-FrivOSCAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal] $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-FrivOSCInstallOwnership([string] $Path) {
    <#
        The uninstaller deletes a whole folder, so it has to be certain the
        folder is one setup created. The marker records the path it was
        written for; anything else is left alone.
    #>
    try {
        $markerPath = Join-Path $Path $MarkerName
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
        $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$marker.Id -ne $MarkerId) { return $false }
        $actual = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $recorded = [IO.Path]::GetFullPath([string]$marker.InstallPath).TrimEnd('\', '/')
        return $actual.Equals($recorded, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Stop-FrivOSCProcesses([string] $Target) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    $venvRoot = [IO.Path]::GetFullPath((Join-Path $Target '.venv')).TrimEnd('\', '/')
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('python.exe', 'pythonw.exe') -and $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith($venvRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($process in $running) {
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 400 }
    return $running.Count
}

function Invoke-FrivOSCRemoval {
    param([string] $Target, [bool] $PreserveSettings)

    $stopped = 0
    try { $stopped = Stop-FrivOSCProcesses $Target; [void](Add-Step 'Stopped the FrivOSC service' $true) }
    catch { [void](Add-Step 'Stop the FrivOSC service' $false) }
    Write-UninstallLog ("stopped {0} process(es)" -f $stopped)

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        [void](Add-Step 'Removed the startup task' $true)
    } catch { [void](Add-Step 'Remove the startup task' $false) }

    try {
        Remove-Item -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FrivOSC' -Recurse -Force -ErrorAction SilentlyContinue
        [void](Add-Step 'Removed the Installed apps entry' $true)
    } catch { [void](Add-Step 'Remove the Installed apps entry' $false) }

    $shortcutRemoved = $true
    foreach ($root in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))) {
        # GetFolderPath can return an empty string, and Join-Path throws on
        # one rather than returning anything useful.
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $link = Join-Path $root 'FrivOSC.lnk'
        try { if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force -ErrorAction Stop } }
        catch { $shortcutRemoved = $false }
    }
    [void](Add-Step 'Removed shortcuts' $shortcutRemoved)

    if ($PreserveSettings) {
        [void](Add-Step 'Kept your settings' $true)
    } else {
        try {
            if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction Stop }
            [void](Add-Step 'Removed settings' $true)
        } catch { [void](Add-Step 'Remove settings' $false) }
    }

    if (Test-FrivOSCInstallOwnership $Target) {
        try {
            Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop
            [void](Add-Step 'Removed program files' $true)
        } catch {
            # This script usually lives inside the folder it is deleting, so
            # a lock here is expected rather than a failure. Hand the rest to
            # a detached command and report it as done, because it will be.
            Write-UninstallLog ('Deferred removal: ' + $_.Exception.Message)
            $cmd = 'ping 127.0.0.1 -n 4 > nul & rmdir /s /q "{0}"' -f $Target
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -WindowStyle Hidden | Out-Null
            [void](Add-Step 'Removed program files' $true)
        }
    } else {
        [void](Add-Step 'Left unrecognised files alone' $true)
        Write-UninstallLog ('No FrivOSC marker at {0}; folder not removed.' -f $Target)
    }
}

if (-not (Test-FrivOSCAdministrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath), '-InstallPath', ('"{0}"' -f $InstallPath))
    if ($Silent) { $arguments += '-Silent' }
    if ($KeepSettings) { $arguments += '-KeepSettings' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments
    exit 0
}

if ($Silent) {
    Invoke-FrivOSCRemoval -Target $InstallPath -PreserveSettings ([bool] $KeepSettings)
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $Root 'FrivOSC.Ui.psm1') -Force
$Theme = Get-FrivoTheme

$form = New-FrivoForm -Theme $Theme -Title 'Uninstall FrivOSC' -Width 500 -Height 430 -IconPath (Join-Path $Root 'FrivOSCIcon.ico')
$header = New-FrivoHeader -Theme $Theme -Form $form -Title 'Uninstall FrivOSC' -Subtitle $InstallPath -LogoPngPath (Join-Path $Root 'FrivOSC.png')

$bodyTop = 76
$confirm = New-Object System.Windows.Forms.Panel
$confirm.Location = [Drawing.Point]::new(0, $bodyTop); $confirm.Size = [Drawing.Size]::new(500, 354)
$confirm.BackColor = $Theme.Bg; $form.Controls.Add($confirm)

[void](New-FrivoLabel -Theme $Theme -Parent $confirm -Text 'This removes FrivOSC, its startup task, and its shortcut.' -X 28 -Y 10 -W 444 -H 48 -Font $Theme.FontUI -Color $Theme.Dim)
$removeCard = New-FrivoCard -Theme $Theme -Parent $confirm -X 24 -Y 72 -W 452 -H 112
[void](New-FrivoLabel -Theme $Theme -Parent $removeCard -Text 'FrivOSC will be removed from this computer.' -X 18 -Y 16 -W 416 -H 20 -Font $Theme.FontMid -Color $Theme.Ink)
[void](New-FrivoLabel -Theme $Theme -Parent $removeCard -Text 'This does not change Frivo, VRChat, or your Windows Python installation.' -X 18 -Y 38 -W 416 -H 18 -Font $Theme.FontSmall -Color $Theme.Dim)
$keepSettingsCheck = New-FrivoCheck -Theme $Theme -Parent $removeCard -Text 'Keep my settings' -X 18 -Y 62 -W 416 -Checked $true
[void](New-FrivoLabel -Theme $Theme -Parent $removeCard -Text 'The Frivo address will be there again if you reinstall.' -X 38 -Y 84 -W 390 -H 16 -Font $Theme.FontSmall -Color $Theme.Dim)
$removeButton = New-FrivoButton -Theme $Theme -Parent $confirm -Text 'Uninstall FrivOSC' -X 24 -Y 250 -W 452 -H 44 -Primary $true
$cancelButton = New-FrivoButton -Theme $Theme -Parent $confirm -Text 'Cancel' -X 24 -Y 302 -W 452 -H 38

$run = New-Object System.Windows.Forms.Panel
$run.Location = [Drawing.Point]::new(0, $bodyTop); $run.Size = [Drawing.Size]::new(500, 354)
$run.BackColor = $Theme.Bg; $run.Visible = $false; $form.Controls.Add($run)
$runLog = New-FrivoTextBox -Theme $Theme -Parent $run -X 24 -Y 8 -W 452 -H 230 -Multiline
$summary = New-FrivoLabel -Theme $Theme -Parent $run -Text '' -X 28 -Y 246 -W 444 -H 48 -Font $Theme.FontUI -Color $Theme.Ink
$closeButton = New-FrivoButton -Theme $Theme -Parent $run -Text 'Close' -X 24 -Y 302 -W 452 -H 38 -Primary $true

$cancelButton.Add_Click({ $form.Close() })

$removeButton.Add_Click({
    # Read the checkbox once, into a name that is not a parameter of
    # anything in scope. A [switch] parameter given $null silently becomes
    # $false, which is how an earlier version of this deleted settings the
    # user had asked to keep.
    $preserveSettings = [bool] $keepSettingsCheck.Checked
    $confirm.Visible = $false
    $run.Visible = $true
    $header.Title.Text = 'Removing FrivOSC'
    $header.Subtitle.Text = 'This only takes a moment'
    [System.Windows.Forms.Application]::DoEvents()

    $script:Steps.Clear()
    Invoke-FrivOSCRemoval -Target $InstallPath -PreserveSettings $preserveSettings

    foreach ($step in $script:Steps) {
        $runLog.AppendText(('{0} [{1}]' -f $step.Text, $(if ($step.Ok) { 'OK' } else { 'FAILED' })) + "`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    }
    $runLog.SelectionStart = $runLog.TextLength
    $runLog.ScrollToCaret()

    $failed = @($script:Steps | Where-Object { -not $_.Ok })
    if ($failed.Count -eq 0) {
        $header.Title.Text = 'FrivOSC was removed'
        $summary.ForeColor = $Theme.Signal
        $summary.Text = 'FrivOSC has been removed from this computer.'
    } else {
        $header.Title.Text = 'FrivOSC was mostly removed'
        $summary.ForeColor = $Theme.Warn
        $summary.Text = ('{0} step(s) did not finish. See {1}' -f $failed.Count, $LogPath)
    }
    $header.Subtitle.Text = $InstallPath
})

$closeButton.Add_Click({ $form.Close() })
[void] $form.ShowDialog()
