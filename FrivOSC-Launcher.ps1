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

function Test-FrivoReachable([string] $Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return [pscustomobject]@{ Ok = $false; Message = 'No Frivo address is set.' } }
    $callback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        # Frivo's certificate is self-signed, so it will never validate on
        # this machine. This check is only asking whether Frivo answers.
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
        $response = Invoke-WebRequest -Uri ($Url.TrimEnd('/')) -UseBasicParsing -TimeoutSec 6
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
            return [pscustomobject]@{ Ok = $true; Message = ('Connected to {0}' -f $Url) }
        }
        return [pscustomobject]@{ Ok = $false; Message = ('Frivo answered with status {0}' -f $response.StatusCode) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = ('Cannot reach Frivo at {0}' -f $Url) }
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

$form = New-FrivoForm -Theme $Theme -Title 'FrivOSC' -Width 520 -Height 520 -IconPath (Join-Path $Root 'FrivOSCIcon.ico')
$header = New-FrivoHeader -Theme $Theme -Form $form -Title 'FrivOSC' -Subtitle 'VRChat OSC for Frivo' -LogoPngPath (Join-Path $Root 'FrivOSC.png')

$bodyTop = 76
$body = New-Object System.Windows.Forms.Panel
$body.Location = [Drawing.Point]::new(0, $bodyTop); $body.Size = [Drawing.Size]::new(520, 444)
$body.BackColor = $Theme.Bg; $form.Controls.Add($body)

[void](New-FrivoLabel -Theme $Theme -Parent $body -Text 'STATUS' -X 30 -Y 6 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$statusCard = New-FrivoCard -Theme $Theme -Parent $body -X 24 -Y 26 -W 472 -H 96
$serviceLabel = New-FrivoLabel -Theme $Theme -Parent $statusCard -Text 'Checking...' -X 18 -Y 14 -W 436 -H 20 -Font $Theme.FontMid -Color $Theme.Ink
$vrchatLabel = New-FrivoLabel -Theme $Theme -Parent $statusCard -Text '' -X 18 -Y 40 -W 436 -H 18 -Font $Theme.FontSmall -Color $Theme.Dim
$frivoLabel = New-FrivoLabel -Theme $Theme -Parent $statusCard -Text '' -X 18 -Y 62 -W 436 -H 18 -Font $Theme.FontSmall -Color $Theme.Dim

[void](New-FrivoLabel -Theme $Theme -Parent $body -Text 'FRIVO SERVER' -X 30 -Y 134 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$urlCard = New-FrivoCard -Theme $Theme -Parent $body -X 24 -Y 154 -W 472 -H 58
$urlBox = New-FrivoTextBox -Theme $Theme -Parent $urlCard -X 16 -Y 16 -W 328 -H 26
$urlBox.Text = [string]$config['frivo_url']
$saveButton = New-FrivoButton -Theme $Theme -Parent $urlCard -Text 'Save' -X 356 -Y 12 -W 100 -H 32

[void](New-FrivoLabel -Theme $Theme -Parent $body -Text 'RECENT ACTIVITY' -X 30 -Y 224 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$logBox = New-FrivoTextBox -Theme $Theme -Parent $body -X 24 -Y 244 -W 472 -H 132 -Multiline
$logBox.ReadOnly = $true

$startButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Start' -X 24 -Y 390 -W 150 -H 38 -Primary $true
$stopButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Stop' -X 184 -Y 390 -W 150 -H 38
$closeButton = New-FrivoButton -Theme $Theme -Parent $body -Text 'Close' -X 346 -Y 390 -W 150 -H 38

function Update-FrivOSCStatus {
    $running = Test-FrivOSCRunning
    if ($running) {
        $serviceLabel.ForeColor = $Theme.Signal
        $serviceLabel.Text = 'FrivOSC is running'
    } else {
        $serviceLabel.ForeColor = $Theme.Warn
        $serviceLabel.Text = 'FrivOSC is not running'
    }
    $startButton.Enabled = -not $running
    $stopButton.Enabled = $running

    $current = Read-FrivOSCConfig
    $listenPort = [int]$current['listen_port']
    $vrchatLabel.Text = ('Listening for VRChat on 127.0.0.1:{0}' -f $listenPort)

    $reach = Test-FrivoReachable ([string]$current['frivo_url'])
    $frivoLabel.ForeColor = if ($reach.Ok) { $Theme.Dim } else { $Theme.Warn }
    $frivoLabel.Text = $reach.Message

    $logBox.Text = ((Get-FrivOSCLogTail 12) -join "`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

$saveButton.Add_Click({
    if (Save-FrivOSCUrl $urlBox.Text) {
        # The address is read at startup, so a running service is still
        # pointed at the old one until it is restarted.
        if (Test-FrivOSCRunning) {
            Stop-FrivOSCService
            Start-Sleep -Milliseconds 600
            [void](Start-FrivOSCService)
            Start-Sleep -Milliseconds 800
        }
        Update-FrivOSCStatus
    } else {
        $frivoLabel.ForeColor = $Theme.Warn
        $frivoLabel.Text = 'Could not save. Try running FrivOSC as administrator.'
    }
})

$startButton.Add_Click({
    $startButton.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    [void](Start-FrivOSCService)
    Start-Sleep -Milliseconds 1200
    Update-FrivOSCStatus
})

$stopButton.Add_Click({
    $stopButton.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    Stop-FrivOSCService
    Start-Sleep -Milliseconds 600
    Update-FrivOSCStatus
})

$closeButton.Add_Click({ $form.Close() })

# Refreshed on a timer rather than only on open: the point of this window
# is watching a state change while you fix something in VRChat or Frivo.
$refresh = New-Object System.Windows.Forms.Timer
$refresh.Interval = 3000
$refresh.Add_Tick({ Update-FrivOSCStatus })
$form.Add_Shown({ Update-FrivOSCStatus; $refresh.Start() })
$form.Add_FormClosing({ $refresh.Stop() })

[void] $form.ShowDialog()
