<#
  FrivOSC — status window

  FrivOSC is meant to be invisible, so this window exists for exactly one
  moment: when something is not working and nobody knows which half. It
  answers the two questions that matter — is VRChat sending, is Frivo
  reachable — and lets the address be corrected without editing JSON.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSCommandPath
$TaskName = 'FrivOSC'
$DataDir = Join-Path $env:ProgramData 'FrivOSC'
$ConfigPath = Join-Path $DataDir 'config.json'
$LogPath = Join-Path $DataDir 'frivosc.log'
$StatusPath = Join-Path $DataDir 'status.json'
$ServicePython = Join-Path $Root '.venv\Scripts\python.exe'
$ServiceScript = Join-Path $Root 'frivosc_service.py'

function Read-FrivOSCConfig {
    $config = [ordered]@{ frivo_url = ''; listen_port = 9001; vrchat_send_port = 9000 }
    try {
        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($property in $saved.PSObject.Properties) { $config[$property.Name] = $property.Value }
        }
    } catch { }
    return $config
}

function Save-FrivOSCUrl([string] $Url) {
    $config = Read-FrivOSCConfig
    $config['frivo_url'] = $Url.TrimEnd('/')
    try {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        [IO.File]::WriteAllText($ConfigPath, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}

function Test-FrivOSCRunning {
    <#
        Look for a python interpreter from this install's own environment
        rather than trusting the task's reported state, which stays "Ready"
        for a moment after the process has actually gone.
    #>
    try {
        $venvRoot = [IO.Path]::GetFullPath((Join-Path $Root '.venv')).TrimEnd('\', '/')
        $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('python.exe', 'pythonw.exe') -and $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($venvRoot, [StringComparison]::OrdinalIgnoreCase)
        })
        return $running.Count -gt 0
    } catch { return $false }
}

function Start-FrivOSCService {
    try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop; return $true } catch { }
    # No task registered (a copy run from source, say) — start it directly.
    try {
        if ((Test-Path -LiteralPath $ServicePython) -and (Test-Path -LiteralPath $ServiceScript)) {
            Start-Process -FilePath $ServicePython -ArgumentList @('-u', ('"{0}"' -f $ServiceScript)) `
                -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
            return $true
        }
    } catch { }
    return $false
}

function Stop-FrivOSCService {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    try {
        $venvRoot = [IO.Path]::GetFullPath((Join-Path $Root '.venv')).TrimEnd('\', '/')
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('python.exe', 'pythonw.exe') -and $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($venvRoot, [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Get-FrivOSCLogTail([int] $Lines = 12) {
    try {
        if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @('No log yet.') }
        # @() so a single-line log does not come back as a bare string and
        # throw on .Count under StrictMode.
        $tail = @(Get-Content -LiteralPath $LogPath -Tail $Lines -ErrorAction Stop)
        if ($tail.Count -eq 0) { return @('The log is empty.') }
        return $tail
    } catch { return @('The log could not be read.') }
}

function Read-FrivOSCStatus {
    <#
        The service publishes what it knows to status.json every couple of
        seconds. Reading that is the only honest answer to "is Frivo
        reachable", because the service is the thing doing the reaching —
        an independent check from here once said no while the service was
        happily connected, since Invoke-WebRequest and Python disagree about
        self-signed certificates.

        Fresh is the important field: a status file older than the publish
        interval by a wide margin means the process that wrote it is gone.
    #>
    $result = [pscustomobject]@{
        Present = $false; Fresh = $false; Connected = $false; Detail = ''
        FrivoUrl = ''; ListenPort = 0; VrchatPackets = 0; Muted = $null
    }
    try {
        if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) { return $result }
        $saved = Get-Content -LiteralPath $StatusPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $result.Present = $true
        $names = @($saved.PSObject.Properties.Name)
        if ($names -contains 'connected') { $result.Connected = [bool]$saved.connected }
        if ($names -contains 'detail') { $result.Detail = [string]$saved.detail }
        if ($names -contains 'frivo_url') { $result.FrivoUrl = [string]$saved.frivo_url }
        if ($names -contains 'listen_port') { $result.ListenPort = [int]$saved.listen_port }
        if ($names -contains 'vrchat_packets') { $result.VrchatPackets = [int]$saved.vrchat_packets }
        if ($names -contains 'muted') { $result.Muted = $saved.muted }
        if ($names -contains 'updated_at') {
            # Unix seconds from Python, compared against this machine's clock.
            $age = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0) - [double]$saved.updated_at
            $result.Fresh = ($age -lt 15)
        }
    } catch { }
    return $result
}

function Test-FrivoReachable([string] $Url) {
    <#
        Only used before the service has been started, so an address can be
        checked without launching anything. Once the service is running its
        own report wins.
    #>
    if ([string]::IsNullOrWhiteSpace($Url)) { return [pscustomobject]@{ Ok = $false; Message = 'No Frivo address is set.' } }
    $callback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        # Frivo's certificate is self-signed, so it will never validate on
        # this machine. This check is only asking whether Frivo answers.
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
        $response = Invoke-WebRequest -Uri ($Url.TrimEnd('/')) -UseBasicParsing -TimeoutSec 6
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
            return [pscustomobject]@{ Ok = $true; Message = ('Frivo answered at {0}' -f $Url) }
        }
        return [pscustomobject]@{ Ok = $false; Message = ('Frivo answered with status {0}' -f $response.StatusCode) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = ('No answer from {0}. Start FrivOSC to keep trying.' -f $Url) }
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $callback
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $Root 'FrivOSC.Ui.psm1') -Force
$Theme = Get-FrivoTheme
$config = Read-FrivOSCConfig

# ==================================================================
# Window
# ------------------------------------------------------------------
# Laid out to match Frivo's launcher: header with a status dot, then
# one card per fact, then the activity log, then the actions. Every
# label is given more height than its font strictly needs — Windows
# PowerShell's GDI text renderer clips descenders otherwise, which is
# what cut the tails off "FrivOSC is running".
# ==================================================================

$form = New-FrivoForm -Theme $Theme -Title 'FrivOSC' -Width 470 -Height 690 -IconPath (Join-Path $Root 'FrivOSCIcon.ico')
$header = New-FrivoHeader -Theme $Theme -Form $form -Title 'FrivOSC' -Subtitle '' -LogoPngPath (Join-Path $Root 'FrivOSC.png')

# The running indicator sits where Frivo's does, so the two windows read
# the same way at a glance.
$statusDot = New-Object System.Windows.Forms.Panel
$statusDot.Location = [Drawing.Point]::new(82, 56)
$statusDot.Size = [Drawing.Size]::new(9, 9)
$statusDot.BackColor = $Theme.Faint
Set-FrivoRounded $statusDot 9
$form.Controls.Add($statusDot)

$statusLabel = $header.Subtitle
$statusLabel.Location = [Drawing.Point]::new(98, 52)
$statusLabel.Size = [Drawing.Size]::new(340, 20)
$statusLabel.Text = 'Checking...'

$body = New-Object System.Windows.Forms.Panel
$body.Location = [Drawing.Point]::new(0, 84)
$body.Size = [Drawing.Size]::new(470, 606)
$body.BackColor = $Theme.Bg
$form.Controls.Add($body)

function New-FrivOSCStatusCard {
    <#
        Caption, a headline in the accent-neutral heading font, and a
        quieter line underneath for the detail. Same three-part shape as
        Frivo's address cards.
    #>
    param([int] $Y, [string] $Caption)
    $card = New-FrivoCard -Theme $Theme -Parent $body -X 24 -Y $Y -W 422 -H 84
    [void](New-FrivoLabel -Theme $Theme -Parent $card -Text $Caption -X 18 -Y 14 -W 380 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
    $value = New-FrivoLabel -Theme $Theme -Parent $card -Text '' -X 18 -Y 33 -W 386 -H 26 -Font $Theme.FontMid -Color $Theme.Ink
    $value.AutoEllipsis = $true
    $detail = New-FrivoLabel -Theme $Theme -Parent $card -Text '' -X 18 -Y 60 -W 386 -H 20 -Font $Theme.FontSmall -Color $Theme.Dim
    $detail.AutoEllipsis = $true
    return [pscustomobject]@{ Card = $card; Value = $value; Detail = $detail }
}

$frivoCard = New-FrivOSCStatusCard -Y 10 -Caption 'CONNECTION TO FRIVO'
$vrchatCard = New-FrivOSCStatusCard -Y 104 -Caption 'VRCHAT'

$serverCard = New-FrivoCard -Theme $Theme -Parent $body -X 24 -Y 198 -W 422 -H 88
[void](New-FrivoLabel -Theme $Theme -Parent $serverCard -Text 'FRIVO ADDRESS' -X 18 -Y 14 -W 380 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$urlBox = New-FrivoTextBox -Theme $Theme -Parent $serverCard -X 18 -Y 36 -W 292 -H 34
$urlBox.Text = [string]$config['frivo_url']
$saveButton = New-FrivoButton -Theme $Theme -Parent $serverCard -Text 'Save' -X 322 -Y 36 -W 82 -H 34
$saveButton.Font = $Theme.FontUI

[void](New-FrivoLabel -Theme $Theme -Parent $body -Text 'RECENT ACTIVITY' -X 28 -Y 302 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$logBox = New-FrivoTextBox -Theme $Theme -Parent $body -X 24 -Y 320 -W 422 -H 146 -Multiline
$logBox.ReadOnly = $true
$logBox.Font = $Theme.FontSmall

$powerButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Start FrivOSC' -X 24 -Y 482 -W 422 -H 46 -Primary $true
$logButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Open log folder' -X 24 -Y 540 -W 205 -H 38
$closeButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Close' -X 241 -Y 540 -W 205 -H 38

$hintLabel = New-FrivoLabel -Theme $Theme -Parent $body -Text '' -X 28 -Y 586 -W 414 -H 20 -Font $Theme.FontSmall -Color $Theme.Faint
$hintLabel.TextAlign = 'MiddleCenter'

# ==================================================================
# Status
# ==================================================================

$script:Busy = $false

function Update-FrivOSCStatus {
    if ($script:Busy) { return }
    $running = Test-FrivOSCRunning
    $current = Read-FrivOSCConfig
    $status = Read-FrivOSCStatus
    $reporting = ($running -and $status.Fresh)

    if ($running) {
        $statusDot.BackColor = $Theme.Signal
        $statusLabel.ForeColor = $Theme.Dim
        $statusLabel.Text = 'Running'
    } else {
        $statusDot.BackColor = $Theme.Faint
        $statusLabel.ForeColor = $Theme.Dim
        $statusLabel.Text = 'Not running'
    }
    $powerButton.Text = if ($running) { 'Stop FrivOSC' } else { 'Start FrivOSC' }

    $url = [string]$current['frivo_url']
    if ($status.FrivoUrl) { $url = $status.FrivoUrl }

    if ($reporting -and $status.Connected) {
        $frivoCard.Value.ForeColor = $Theme.Signal
        $frivoCard.Value.Text = 'Connected'
        $frivoCard.Detail.Text = $url
    } elseif ($reporting) {
        $frivoCard.Value.ForeColor = $Theme.Warn
        $frivoCard.Value.Text = 'Not connected'
        $frivoCard.Detail.Text = if ($status.Detail) { $status.Detail } else { ('No answer from {0}' -f $url) }
    } elseif ($running) {
        # Started, but has not published a status yet. This lasts a second
        # or two; guessing during it is how the old window ended up saying
        # the opposite of what the log said.
        $frivoCard.Value.ForeColor = $Theme.Dim
        $frivoCard.Value.Text = 'Checking...'
        $frivoCard.Detail.Text = $url
    } elseif ([string]::IsNullOrWhiteSpace($url)) {
        $frivoCard.Value.ForeColor = $Theme.Warn
        $frivoCard.Value.Text = 'No address set'
        $frivoCard.Detail.Text = 'Enter the address you open Frivo at, then Save.'
    } else {
        # Not running, so nothing is reporting — check the address here so
        # it can be corrected before starting anything.
        $reach = Test-FrivoReachable $url
        $frivoCard.Value.ForeColor = if ($reach.Ok) { $Theme.Dim } else { $Theme.Warn }
        $frivoCard.Value.Text = if ($reach.Ok) { 'Frivo is up' } else { 'No answer' }
        $frivoCard.Detail.Text = $reach.Message
    }

    $listenPort = [int]$current['listen_port']
    if ($status.ListenPort -gt 0) { $listenPort = $status.ListenPort }
    if ($reporting -and $status.VrchatPackets -gt 0) {
        $vrchatCard.Value.ForeColor = $Theme.Signal
        $vrchatCard.Value.Text = 'Receiving'
        if ($status.Muted -eq $true) {
            $vrchatCard.Detail.Text = 'Your microphone is muted in VRChat'
        } elseif ($status.Muted -eq $false) {
            $vrchatCard.Detail.Text = 'Your microphone is live in VRChat'
        } else {
            $vrchatCard.Detail.Text = ('Listening on 127.0.0.1:{0}' -f $listenPort)
        }
    } elseif ($reporting) {
        $vrchatCard.Value.ForeColor = $Theme.Dim
        $vrchatCard.Value.Text = 'Waiting'
        $vrchatCard.Detail.Text = ('Nothing heard yet on 127.0.0.1:{0}' -f $listenPort)
    } else {
        $vrchatCard.Value.ForeColor = $Theme.Dim
        $vrchatCard.Value.Text = 'Not listening'
        $vrchatCard.Detail.Text = ('Starts on 127.0.0.1:{0}' -f $listenPort)
    }

    if ($running) {
        $hintLabel.Text = 'Closing this window leaves FrivOSC running.'
    } else {
        $hintLabel.Text = 'Stopped. Nothing is being sent to VRChat.'
    }

    $logBox.Text = ((Get-FrivOSCLogTail 10) -join "`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Wait-FrivOSCSettle([int] $Milliseconds) {
    # Keeps the window painting while the service starts or stops, so it
    # does not grey out the way an unresponsive window does.
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    }
}

$saveButton.Add_Click({
    $script:Busy = $true
    try {
        if (Save-FrivOSCUrl $urlBox.Text) {
            # The address is read at startup, so a running service is still
            # pointed at the old one until it is restarted.
            if (Test-FrivOSCRunning) {
                Stop-FrivOSCService
                Wait-FrivOSCSettle 600
                [void](Start-FrivOSCService)
                Wait-FrivOSCSettle 1500
            }
        } else {
            $frivoCard.Value.ForeColor = $Theme.Warn
            $frivoCard.Value.Text = 'Could not save'
            $frivoCard.Detail.Text = 'Try opening FrivOSC as administrator.'
            return
        }
    } finally { $script:Busy = $false }
    Update-FrivOSCStatus
})

$powerButton.Add_Click({
    $script:Busy = $true
    $powerButton.Enabled = $false
    try {
        if (Test-FrivOSCRunning) {
            Stop-FrivOSCService
            Wait-FrivOSCSettle 800
        } else {
            [void](Start-FrivOSCService)
            Wait-FrivOSCSettle 1800
        }
    } finally {
        $script:Busy = $false
        $powerButton.Enabled = $true
    }
    Update-FrivOSCStatus
})

$logButton.Add_Click({
    try {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        Start-Process -FilePath 'explorer.exe' -ArgumentList $DataDir | Out-Null
    } catch { }
})

$closeButton.Add_Click({ $form.Close() })

# Refreshed on a timer rather than only on open: the point of this window
# is watching a state change while you fix something in VRChat or Frivo.
$refresh = New-Object System.Windows.Forms.Timer
$refresh.Interval = 1500
$refresh.Add_Tick({ Update-FrivOSCStatus })
$form.Add_Shown({ Update-FrivOSCStatus; $refresh.Start() })
$form.Add_FormClosing({ $refresh.Stop() })

[void] $form.ShowDialog()
