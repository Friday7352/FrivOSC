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

# ==================================================================
# One launcher at a time
# ==================================================================
# Now that closing the window leaves it sitting in the notification area,
# clicking the shortcut again is a normal thing to do. A second copy would
# mean a second tray icon and two windows disagreeing about the same
# service, so it signals the first to show itself and leaves.

$createdMutex = $false
$instanceLock = New-Object System.Threading.Mutex($true, 'Local\FrivOSCLauncher', [ref] $createdMutex)
$showSignal = New-Object System.Threading.EventWaitHandle($false,
    [System.Threading.EventResetMode]::ManualReset, 'Local\FrivOSCLauncherShow')
if (-not $createdMutex) {
    [void] $showSignal.Set()
    exit
}

$LauncherLog = Join-Path $env:TEMP 'FrivOSC-Launcher.log'

# Everything below runs inside one try. This window is opened from a
# shortcut, so an unhandled error has no console to land in — it would
# simply fail to appear, which is exactly how the setup wizard once looked
# broken for an afternoon.
try {

$Root = Split-Path -Parent $PSCommandPath
$TaskName = 'FrivOSC'
$DataDir = Join-Path $env:ProgramData 'FrivOSC'
$ConfigPath = Join-Path $DataDir 'config.json'
$LogPath = Join-Path $DataDir 'frivosc.log'
$StatusPath = Join-Path $DataDir 'status.json'
$ServicePython = Join-Path $Root '.venv\Scripts\python.exe'
$ServiceScript = Join-Path $Root 'frivosc_service.py'

function Read-FrivOSCConfig {
    # stop_on_close defaults to false: FrivOSC is meant to be invisible, and
    # closing a status window is not a request to stop relaying.
    $config = [ordered]@{ frivo_url = ''; listen_port = 9001; vrchat_send_port = 9000
                          stop_on_close = $false }
    try {
        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($property in $saved.PSObject.Properties) { $config[$property.Name] = $property.Value }
        }
    } catch { }
    return $config
}

function Save-FrivOSCConfigValue([string] $Name, $Value) {
    <#
        Read, change one key, write the whole thing back. The service owns
        this file too, so anything not named here has to survive untouched.
    #>
    $config = Read-FrivOSCConfig
    $config[$Name] = $Value
    try {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        [IO.File]::WriteAllText($ConfigPath, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}

function Save-FrivOSCUrl([string] $Url) {
    return Save-FrivOSCConfigValue 'frivo_url' ($Url.TrimEnd('/'))
}

function Test-FrivOSCStartsWithWindows {
    <#
        Setup registers the scheduled task either with an at-logon trigger
        or with none at all. A task with no trigger still runs when
        something starts it by hand, which is exactly the "installed but
        not automatic" state — so the presence of a trigger is the answer.
    #>
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return @($task.Triggers).Count -gt 0
    } catch { return $false }
}

function Set-FrivOSCStartsWithWindows([bool] $Enabled) {
    <#
        Adds or removes the at-logon trigger on the existing task rather
        than re-registering it, so the task keeps the action, principal and
        settings that setup chose.

        Returns $false when Windows refuses. The task is registered for the
        Users group, and editing it can need administrator rights depending
        on how the machine is configured; the caller says so rather than
        leaving a checkbox showing a state that was never applied.
    #>
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        if ($Enabled) {
            $task.Triggers = @(New-ScheduledTaskTrigger -AtLogOn)
        } else {
            # $null rather than @(): an empty array is rejected by
            # Set-ScheduledTask, while $null clears the collection.
            $task.Triggers = $null
        }
        Set-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
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
        ChatboxTotal = 0; ChatboxAge = $null
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
        if ($names -contains 'chatbox_total') { $result.ChatboxTotal = [int]$saved.chatbox_total }
        if ($names -contains 'chatbox_last' -and [double]$saved.chatbox_last -gt 0) {
            $result.ChatboxAge = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0) - [double]$saved.chatbox_last
        }
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
        return [pscustomobject]@{ Ok = $false; Message = ('No answer from {0}' -f $Url) }
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
# Drawn icons
# ------------------------------------------------------------------
# Drawn rather than shipped as images: two glyphs at one size, needed
# in three tints each, is more work as twelve PNGs than as thirty
# lines of GDI+. They also stay crisp at any DPI this way.
# ==================================================================

function Draw-FrivoMicIcon {
    param(
        $Graphics,
        [System.Drawing.Rectangle] $Box,
        [System.Drawing.Color] $Color,
        [bool] $Muted,
        # Whatever is behind the glyph. The muted slash is drawn twice —
        # once in this colour and slightly thicker — so it reads as passing
        # over the microphone rather than as another part of it.
        [System.Drawing.Color] $Background
    )

    $pen = New-Object System.Drawing.Pen($Color, 2.0)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $brush = New-Object System.Drawing.SolidBrush($Color)
    try {
        $cx = $Box.X + [int]($Box.Width / 2)
        $top = $Box.Y + 2

        # Capsule body.
        $Graphics.FillRectangle($brush, ($cx - 5), ($top + 5), 10, 8)
        $Graphics.FillEllipse($brush, ($cx - 5), $top, 10, 10)
        $Graphics.FillEllipse($brush, ($cx - 5), ($top + 8), 10, 10)

        # Cradle, stem, base.
        $Graphics.DrawArc($pen, ($cx - 9), ($top + 6), 18, 16, 0, 180)
        $Graphics.DrawLine($pen, $cx, ($top + 22), $cx, ($top + 27))
        $Graphics.DrawLine($pen, ($cx - 6), ($top + 27), ($cx + 6), ($top + 27))

        if ($Muted) {
            $shadow = New-Object System.Drawing.Pen($Background, 4.5)
            try { $Graphics.DrawLine($shadow, ($cx - 11), ($top - 3), ($cx + 11), ($top + 26)) }
            finally { $shadow.Dispose() }
            $Graphics.DrawLine($pen, ($cx - 10), ($top - 2), ($cx + 10), ($top + 25))
        }
    } finally {
        $pen.Dispose(); $brush.Dispose()
    }
}

function Draw-FrivoChatIcon {
    param($Graphics, [System.Drawing.Rectangle] $Box, [System.Drawing.Color] $Color, [bool] $Active)

    $pen = New-Object System.Drawing.Pen($Color, 2.0)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $brush = New-Object System.Drawing.SolidBrush($Color)
    try {
        $x = $Box.X + 2
        $y = $Box.Y + 3
        $w = $Box.Width - 4
        $h = 20

        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {
            $r = 7
            $path.AddArc($x, $y, $r * 2, $r * 2, 180, 90)
            $path.AddArc(($x + $w - $r * 2), $y, $r * 2, $r * 2, 270, 90)
            $path.AddArc(($x + $w - $r * 2), ($y + $h - $r * 2), $r * 2, $r * 2, 0, 90)
            $path.AddArc($x, ($y + $h - $r * 2), $r * 2, $r * 2, 90, 90)
            $path.CloseFigure()
            $Graphics.DrawPath($pen, $path)
        } finally { $path.Dispose() }

        # Tail.
        $tail = @(
            [System.Drawing.Point]::new(($x + 7), ($y + $h - 1)),
            [System.Drawing.Point]::new(($x + 7), ($y + $h + 6)),
            [System.Drawing.Point]::new(($x + 15), ($y + $h - 1))
        )
        $Graphics.FillPolygon($brush, $tail)

        # Three dots when text is flowing, one flat line when it is not.
        if ($Active) {
            $dotY = $y + [int]($h / 2) - 2
            foreach ($offset in @(-6, 0, 6)) {
                $Graphics.FillEllipse($brush, ($x + [int]($w / 2) + $offset - 2), $dotY, 4, 4)
            }
        } else {
            $midY = $y + [int]($h / 2)
            $Graphics.DrawLine($pen, ($x + 7), $midY, ($x + $w - 7), $midY)
        }
    } finally {
        $pen.Dispose(); $brush.Dispose()
    }
}

# ==================================================================
# Window
# ------------------------------------------------------------------
# Laid out to match Frivo's launcher: header with a status dot, the
# connection stated in words, then the two things anybody actually
# opens this window to check — is VRChat's mic muted, and is text
# arriving from Frivo — as icons rather than as a log to read. The
# log is still here, one click away, for when something is wrong.
# ==================================================================

$form = New-FrivoForm -Theme $Theme -Title 'FrivOSC' -Width 470 -Height 636 -IconPath (Join-Path $Root 'FrivOSCIcon.ico')
# This window now outlives its own close button, so it should be
# minimizable like any other window that sticks around.
$form.MinimizeBox = $true
$header = New-FrivoHeader -Theme $Theme -Form $form -Title 'FrivOSC' -Subtitle '' -LogoPngPath (Join-Path $Root 'FrivOSC.png')

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

# Two views in the same space, swapped rather than stacked — the same
# shape Frivo's launcher uses, so the two windows behave alike.
$body = New-Object System.Windows.Forms.Panel
$body.Location = [Drawing.Point]::new(0, 84)
$body.Size = [Drawing.Size]::new(470, 552)
$body.BackColor = $Theme.Bg
$form.Controls.Add($body)

$settingsView = New-Object System.Windows.Forms.Panel
$settingsView.Location = [Drawing.Point]::new(0, 84)
$settingsView.Size = [Drawing.Size]::new(470, 552)
$settingsView.BackColor = $Theme.Bg
$settingsView.Visible = $false
$form.Controls.Add($settingsView)

# ---------- connection ----------
$frivoCard = New-FrivoCard -Theme $Theme -Parent $body -X 24 -Y 10 -W 422 -H 100
[void](New-FrivoLabel -Theme $Theme -Parent $frivoCard -Text 'CONNECTION TO FRIVO' -X 18 -Y 14 -W 380 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$frivoValue = New-FrivoLabel -Theme $Theme -Parent $frivoCard -Text '' -X 18 -Y 33 -W 386 -H 26 -Font $Theme.FontMid -Color $Theme.Ink
$frivoValue.AutoEllipsis = $true
# Two lines and no ellipsis. These messages carry an address and a
# sentence about what to do next, and both matter — "No answer from
# https://192.168.1.248:5000. Start FrivOSC to keep..." told you the
# problem and then hid the answer.
$frivoDetail = New-FrivoLabel -Theme $Theme -Parent $frivoCard -Text '' -X 18 -Y 58 -W 386 -H 36 -Font $Theme.FontSmall -Color $Theme.Dim

# ---------- the two live indicators ----------
function New-FrivOSCIndicator {
    <#
        Icon above, name under it, state under that. Two of these side by
        side replace the log that used to fill this window: the answer to
        "is it working" should be a glyph you can read at a glance from
        across the room, not eight timestamped lines.
    #>
    param([int] $X, [string] $Caption)

    $card = New-FrivoCard -Theme $Theme -Parent $body -X $X -Y 120 -W 205 -H 126
    $icon = New-Object System.Windows.Forms.Panel
    $icon.Location = [Drawing.Point]::new(([int](205 / 2) - 20), 16)
    $icon.Size = [Drawing.Size]::new(40, 38)
    $icon.BackColor = $Theme.Surface
    $card.Controls.Add($icon)

    $name = New-FrivoLabel -Theme $Theme -Parent $card -Text $Caption -X 10 -Y 62 -W 185 -H 18 -Font $Theme.FontSmall -Color $Theme.Dim
    $name.TextAlign = 'MiddleCenter'
    $state = New-FrivoLabel -Theme $Theme -Parent $card -Text '' -X 10 -Y 82 -W 185 -H 26 -Font $Theme.FontMid -Color $Theme.Ink
    $state.TextAlign = 'MiddleCenter'
    $state.AutoEllipsis = $true

    return [pscustomobject]@{ Card = $card; Icon = $icon; State = $state }
}

$micTile = New-FrivOSCIndicator -X 24 -Caption 'MICROPHONE'
$chatTile = New-FrivOSCIndicator -X 241 -Caption 'CHATBOX'

# Repainted by invalidating the panel rather than by swapping images, so
# there is nothing to dispose and nothing to hold a file open.
$script:MicColor = $Theme.Faint
$script:MicMuted = $false
$script:ChatColor = $Theme.Faint
$script:ChatActive = $false

$micTile.Icon.Add_Paint({
    param($sender, $eventArgs)
    $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    Draw-FrivoMicIcon -Graphics $eventArgs.Graphics `
        -Box ([System.Drawing.Rectangle]::new(0, 0, $sender.Width, $sender.Height)) `
        -Color $script:MicColor -Muted $script:MicMuted -Background $sender.BackColor
})
$chatTile.Icon.Add_Paint({
    param($sender, $eventArgs)
    $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    Draw-FrivoChatIcon -Graphics $eventArgs.Graphics `
        -Box ([System.Drawing.Rectangle]::new(0, 0, $sender.Width, $sender.Height)) `
        -Color $script:ChatColor -Active $script:ChatActive
})

# ---------- address ----------
$serverCard = New-FrivoCard -Theme $Theme -Parent $body -X 24 -Y 258 -W 422 -H 88
[void](New-FrivoLabel -Theme $Theme -Parent $serverCard -Text 'FRIVO ADDRESS' -X 18 -Y 14 -W 380 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$urlBox = New-FrivoTextBox -Theme $Theme -Parent $serverCard -X 18 -Y 36 -W 292 -H 34
$urlBox.Text = [string]$config['frivo_url']
$saveButton = New-FrivoButton -Theme $Theme -Parent $serverCard -Text 'Save' -X 322 -Y 36 -W 82 -H 34
$saveButton.Font = $Theme.FontUI

# ---------- activity, collapsed ----------
$activityButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Show activity' -X 24 -Y 358 -W 422 -H 32
$activityButton.Font = $Theme.FontUI
$logBox = New-FrivoTextBox -Theme $Theme -Parent $body -X 24 -Y 400 -W 422 -H 140 -Multiline
$logBox.ReadOnly = $true
$logBox.Font = $Theme.FontSmall
$logFrame = $logBox.Parent
$logFrame.Visible = $false

$powerButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Start FrivOSC' -X 24 -Y 402 -W 422 -H 46 -Primary $true
$settingsButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Settings' -X 24 -Y 460 -W 205 -H 38
$closeButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Close' -X 241 -Y 460 -W 205 -H 38
$hintLabel = New-FrivoLabel -Theme $Theme -Parent $body -Text '' -X 28 -Y 506 -W 414 -H 20 -Font $Theme.FontSmall -Color $Theme.Faint
$hintLabel.TextAlign = 'MiddleCenter'

# ==================================================================
# Settings view
# ==================================================================

$backButton = New-FrivoButton -Theme $Theme -Parent $settingsView -Text ([string][char]0x2190 + '  Back') -X 24 -Y 6 -W 100 -H 32
$backButton.Font = $Theme.FontUI

[void](New-FrivoLabel -Theme $Theme -Parent $settingsView -Text 'WHEN I CLOSE THIS WINDOW' -X 30 -Y 54 -W 380 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$closeCard = New-FrivoCard -Theme $Theme -Parent $settingsView -X 24 -Y 74 -W 422 -H 112

$keepRadio = New-FrivoRadio -Theme $Theme -Parent $closeCard -Text 'Keep FrivOSC running in the background' -X 18 -Y 14 -W 390
[void](New-FrivoLabel -Theme $Theme -Parent $closeCard -Text 'Hides to the notification area and keeps relaying.' -X 42 -Y 38 -W 360 -H 20 -Font $Theme.FontSmall -Color $Theme.Dim)

$stopRadio = New-FrivoRadio -Theme $Theme -Parent $closeCard -Text 'Stop FrivOSC' -X 18 -Y 64 -W 390
[void](New-FrivoLabel -Theme $Theme -Parent $closeCard -Text 'Closing the window stops the relay entirely.' -X 42 -Y 88 -W 360 -H 20 -Font $Theme.FontSmall -Color $Theme.Dim)

[void](New-FrivoLabel -Theme $Theme -Parent $settingsView -Text 'STARTUP' -X 30 -Y 200 -W 380 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$startCard = New-FrivoCard -Theme $Theme -Parent $settingsView -X 24 -Y 220 -W 422 -H 78
$startupCheck = New-FrivoCheck -Theme $Theme -Parent $startCard -Text 'Start FrivOSC when I sign in to Windows' -X 18 -Y 14 -W 390
$startupNote = New-FrivoLabel -Theme $Theme -Parent $startCard -Text 'Runs in the background from sign-in, with no window.' -X 42 -Y 38 -W 360 -H 36 -Font $Theme.FontSmall -Color $Theme.Dim

[void](New-FrivoLabel -Theme $Theme -Parent $settingsView -Text 'TROUBLESHOOTING' -X 30 -Y 312 -W 380 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$toolsCard = New-FrivoCard -Theme $Theme -Parent $settingsView -X 24 -Y 332 -W 422 -H 76
[void](New-FrivoLabel -Theme $Theme -Parent $toolsCard -Text 'Config and log files live in ProgramData.' -X 18 -Y 16 -W 250 -H 44 -Font $Theme.FontSmall -Color $Theme.Dim)
$logButton = New-FrivoButton -Theme $Theme -Parent $toolsCard -Text 'Open log folder' -X 268 -Y 20 -W 136 -H 36
$logButton.Font = $Theme.FontUI

$settingsHint = New-FrivoLabel -Theme $Theme -Parent $settingsView -Text '' -X 28 -Y 422 -W 414 -H 40 -Font $Theme.FontSmall -Color $Theme.Faint
$settingsHint.TextAlign = 'TopCenter'

# ==================================================================
# Notification area
# ==================================================================
# Closing this window with "keep running" chosen hides it here rather than
# ending it. Before this, the window simply vanished and the only evidence
# FrivOSC was still relaying was Task Manager.

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = 'FrivOSC'
$trayIconPath = Join-Path $Root 'FrivOSCIcon.ico'
if (Test-Path -LiteralPath $trayIconPath) {
    try { $notify.Icon = New-Object System.Drawing.Icon($trayIconPath) } catch { }
}
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('Show FrivOSC')
[void]$trayMenu.Items.Add('-')
$miQuit = $trayMenu.Items.Add('Stop FrivOSC and quit')
$notify.ContextMenuStrip = $trayMenu
$notify.Visible = $true

$script:Quitting = $false
$script:BalloonShown = $false
$script:ActivityOpen = $false
$script:SettingsLoading = $false

function Show-FrivOSCWindow {
    # Nothing repaints while hidden, so what is on screen is as old as the
    # moment it was closed. Refresh before showing it, not after.
    try { Update-FrivOSCStatus } catch { }
    $form.ShowInTaskbar = $true
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $form.BringToFront()
    $form.Activate()
    # Windows can refuse a background process the foreground once. Raising
    # TopMost just for this activation gets the window in front without
    # leaving FrivOSC permanently above everything else.
    $form.TopMost = $true
    $form.TopMost = $false
}

function Test-FrivOSCStopOnClose {
    try {
        $current = Read-FrivOSCConfig
        return ($current.Contains('stop_on_close') -and [bool]$current['stop_on_close'])
    } catch { return $false }
}

function Set-FrivOSCActivityOpen([bool] $Open) {
    <#
        The window grows rather than scrolls. Everything below the log just
        moves down by its height, which keeps one set of coordinates in the
        layout above instead of two.
    #>
    $script:ActivityOpen = $Open
    $shift = if ($Open) { 156 } else { 0 }
    $logFrame.Visible = $Open
    $activityButton.Text = if ($Open) { 'Hide activity' } else { 'Show activity' }
    $powerButton.Location = [Drawing.Point]::new(24, (402 + $shift))
    $logButton.Location = [Drawing.Point]::new(24, (460 + $shift))
    $closeButton.Location = [Drawing.Point]::new(241, (460 + $shift))
    $hintLabel.Location = [Drawing.Point]::new(28, (506 + $shift))
    $body.Size = [Drawing.Size]::new(470, (552 + $shift))
    $form.ClientSize = [Drawing.Size]::new(470, (636 + $shift))
}

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
        $statusLabel.Text = 'Running'
    } else {
        $statusDot.BackColor = $Theme.Faint
        $statusLabel.Text = 'Not running'
    }
    $statusLabel.ForeColor = $Theme.Dim
    $powerButton.Text = if ($running) { 'Stop FrivOSC' } else { 'Start FrivOSC' }

    # ---- connection ----
    $url = [string]$current['frivo_url']
    if ($status.FrivoUrl) { $url = $status.FrivoUrl }

    if ($reporting -and $status.Connected) {
        $frivoValue.ForeColor = $Theme.Signal
        $frivoValue.Text = 'Connected'
        $frivoDetail.Text = $url
    } elseif ($reporting) {
        $frivoValue.ForeColor = $Theme.Warn
        $frivoValue.Text = 'Not connected'
        $frivoDetail.Text = ('{0}{1}' -f $url, $(if ($status.Detail) { "  -  " + $status.Detail } else { '' }))
    } elseif ($running) {
        # Started, but has not published a status yet. This lasts a second
        # or two; guessing during it is how the old window ended up saying
        # the opposite of what the log said.
        $frivoValue.ForeColor = $Theme.Dim
        $frivoValue.Text = 'Checking...'
        $frivoDetail.Text = $url
    } elseif ([string]::IsNullOrWhiteSpace($url)) {
        $frivoValue.ForeColor = $Theme.Warn
        $frivoValue.Text = 'No address set'
        $frivoDetail.Text = 'Enter the address you open Frivo at, then Save.'
    } else {
        # Nothing is running, so nothing is reporting — check the address
        # here so it can be corrected before starting anything.
        $reach = Test-FrivoReachable $url
        $frivoValue.ForeColor = if ($reach.Ok) { $Theme.Dim } else { $Theme.Warn }
        $frivoValue.Text = if ($reach.Ok) { 'Frivo is up' } else { 'No answer' }
        $frivoDetail.Text = $reach.Message
    }

    # ---- microphone ----
    # Unknown is its own state, not a guess at unmuted: VRChat only sends
    # MuteSelf when it changes, so before the first one there is genuinely
    # nothing to report.
    if ($reporting -and $status.VrchatPackets -gt 0 -and $null -ne $status.Muted) {
        if ($status.Muted) {
            $script:MicColor = $Theme.Warn; $script:MicMuted = $true
            $micTile.State.ForeColor = $Theme.Warn
            $micTile.State.Text = 'Muted'
        } else {
            $script:MicColor = $Theme.Signal; $script:MicMuted = $false
            $micTile.State.ForeColor = $Theme.Signal
            $micTile.State.Text = 'Live'
        }
    } else {
        $script:MicColor = $Theme.Faint; $script:MicMuted = $false
        $micTile.State.ForeColor = $Theme.Dim
        $micTile.State.Text = if ($reporting) { 'Waiting' } else { 'Unknown' }
    }
    $micTile.Icon.Invalidate()

    # ---- chatbox ----
    # "Receiving" is a recent arrival, not a lifetime total: the question
    # this answers is whether text is flowing right now.
    $recent = ($null -ne $status.ChatboxAge -and $status.ChatboxAge -lt 20)
    if ($reporting -and $recent) {
        $script:ChatColor = $Theme.Signal; $script:ChatActive = $true
        $chatTile.State.ForeColor = $Theme.Signal
        $chatTile.State.Text = 'Receiving'
    } elseif ($reporting -and $status.ChatboxTotal -gt 0) {
        $script:ChatColor = $Theme.Dim; $script:ChatActive = $false
        $chatTile.State.ForeColor = $Theme.Dim
        $chatTile.State.Text = ('{0} sent' -f $status.ChatboxTotal)
    } elseif ($reporting) {
        $script:ChatColor = $Theme.Faint; $script:ChatActive = $false
        $chatTile.State.ForeColor = $Theme.Dim
        $chatTile.State.Text = 'Idle'
    } else {
        $script:ChatColor = $Theme.Faint; $script:ChatActive = $false
        $chatTile.State.ForeColor = $Theme.Dim
        $chatTile.State.Text = 'Off'
    }
    $chatTile.Icon.Invalidate()

    $stopOnClose = ($current.Contains('stop_on_close') -and [bool]$current['stop_on_close'])
    if (-not $running) {
        $hintLabel.Text = 'Stopped. Nothing is being sent to VRChat.'
    } elseif ($stopOnClose) {
        $hintLabel.Text = 'Closing this window stops FrivOSC.'
    } else {
        $hintLabel.Text = 'Closing this window leaves FrivOSC running.'
    }

    if ($script:ActivityOpen) {
        $logBox.Text = ((Get-FrivOSCLogTail 10) -join "`r`n")
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.ScrollToCaret()
    }
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

function Show-FrivOSCSettings([bool] $Open) {
    if ($Open) {
        # Collapse the log first. It resizes the window, and a settings page
        # sitting in a window sized for something else looks broken.
        Set-FrivOSCActivityOpen $false
        Sync-FrivOSCSettingsView
    }
    $body.Visible = -not $Open
    $settingsView.Visible = $Open
}

function Sync-FrivOSCSettingsView {
    <#
        Reads the real state each time the page opens rather than trusting
        what the controls were left showing — the scheduled task can be
        changed from outside this window, and a checkbox that disagrees
        with Task Scheduler is worse than no checkbox.
    #>
    $script:SettingsLoading = $true
    try {
        $current = Read-FrivOSCConfig
        $stopOnClose = $false
        if ($current.Contains('stop_on_close')) { $stopOnClose = [bool]$current['stop_on_close'] }
        $keepRadio.Checked = -not $stopOnClose
        $stopRadio.Checked = $stopOnClose

        $startupCheck.Checked = Test-FrivOSCStartsWithWindows
        $settingsHint.Text = ''
    } finally {
        $script:SettingsLoading = $false
    }
}

$settingsButton.Add_Click({ Show-FrivOSCSettings $true })
$backButton.Add_Click({ Show-FrivOSCSettings $false; Update-FrivOSCStatus })

$keepRadio.Add_CheckedChanged({
    if ($script:SettingsLoading -or -not $keepRadio.Checked) { return }
    if (-not (Save-FrivOSCConfigValue 'stop_on_close' $false)) {
        $settingsHint.ForeColor = $Theme.Warn
        $settingsHint.Text = 'Could not save. Try opening FrivOSC as administrator.'
    } else {
        $settingsHint.ForeColor = $Theme.Faint
        $settingsHint.Text = ''
    }
})

$stopRadio.Add_CheckedChanged({
    if ($script:SettingsLoading -or -not $stopRadio.Checked) { return }
    if (-not (Save-FrivOSCConfigValue 'stop_on_close' $true)) {
        $settingsHint.ForeColor = $Theme.Warn
        $settingsHint.Text = 'Could not save. Try opening FrivOSC as administrator.'
    } else {
        $settingsHint.ForeColor = $Theme.Faint
        $settingsHint.Text = ''
    }
})

$startupCheck.Add_CheckedChanged({
    if ($script:SettingsLoading) { return }
    $wanted = $startupCheck.Checked
    if (Set-FrivOSCStartsWithWindows $wanted) {
        $settingsHint.ForeColor = $Theme.Faint
        $settingsHint.Text = ''
        return
    }
    # Put the box back rather than leaving it claiming something Windows
    # refused to do.
    $script:SettingsLoading = $true
    try { $startupCheck.Checked = -not $wanted } finally { $script:SettingsLoading = $false }
    $settingsHint.ForeColor = $Theme.Warn
    $settingsHint.Text = "Windows would not change the scheduled task.`r`nTry opening FrivOSC as administrator."
})

$activityButton.Add_Click({
    Set-FrivOSCActivityOpen (-not $script:ActivityOpen)
    Update-FrivOSCStatus
})

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
            $frivoValue.ForeColor = $Theme.Warn
            $frivoValue.Text = 'Could not save'
            $frivoDetail.Text = 'Try opening FrivOSC as administrator.'
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

$notify.Add_DoubleClick({ Show-FrivOSCWindow })
$miShow.Add_Click({ Show-FrivOSCWindow })
$miQuit.Add_Click({
    # The one path that really ends everything: the service stops and the
    # tray icon goes with it.
    $script:Quitting = $true
    Stop-FrivOSCService
    $form.Close()
    # The message loop is running without a visible form whenever this is
    # reached from the tray, so closing the form alone would leave it
    # spinning with nothing on screen.
    [System.Windows.Forms.Application]::Exit()
})

# Refreshed on a timer rather than only on open: the point of this window
# is watching a state change while you fix something in VRChat or Frivo.
$refresh = New-Object System.Windows.Forms.Timer
$refresh.Interval = 1500
$refresh.Add_Tick({
    # Skipped while hidden. There is nothing to repaint, and the file reads
    # and process scan behind it are not worth doing to an invisible window.
    if ($form.Visible) { Update-FrivOSCStatus }
    # A second launcher was started — bring this one forward instead.
    if ($showSignal.WaitOne(0)) {
        [void]$showSignal.Reset()
        Show-FrivOSCWindow
    }
})
$form.Add_Shown({ Set-FrivOSCActivityOpen $false; Update-FrivOSCStatus; $refresh.Start() })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:Quitting) { return }
    if ($eventArgs.CloseReason -ne [System.Windows.Forms.CloseReason]::UserClosing) { return }

    if (Test-FrivOSCStopOnClose) {
        $script:Quitting = $true
        Stop-FrivOSCService
        return
    }

    # Hidden, not closed. The service keeps relaying and the tray icon is
    # the evidence of it.
    $eventArgs.Cancel = $true
    $form.Hide()
    $form.ShowInTaskbar = $false
    if (-not $script:BalloonShown) {
        $script:BalloonShown = $true
        try {
            $notify.ShowBalloonTip(2500, 'FrivOSC',
                'Still running. Right-click here to stop it.',
                [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    }
})

$form.Add_FormClosed({
    $refresh.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Run() rather than ShowDialog(): the loop has to outlive the window when
# it is hidden to the tray, and has to keep running with no window at all.
[System.Windows.Forms.Application]::Run($form)
try { $instanceLock.ReleaseMutex() } catch { }

} catch {
    $reason = $_.Exception.Message
    $where = $_.ScriptStackTrace
    try {
        Add-Content -LiteralPath $LauncherLog -Value (
            "{0}`r`n{1}`r`n{2}`r`n----" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $reason, $where)
    } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            ("FrivOSC's window could not open.`r`n`r`n{0}`r`n`r`nDetails were written to:`r`n{1}" -f $reason, $LauncherLog),
            'FrivOSC',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch { }
    exit 1
}
