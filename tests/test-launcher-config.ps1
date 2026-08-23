<#
    The launcher's config read/write, lifted out of FrivOSC-Launcher.ps1.

    Two things matter here and neither is visible by reading the code:

    * The settings page writes one key at a time into a file the *service*
      also owns. Anything not being changed has to survive untouched,
      including keys this window has never heard of.
    * `stop_on_close` has to default to false. FrivOSC is meant to be
      invisible; closing a status window is not a request to stop relaying
      to VRChat, and a missing key must not read as "stop".

    The functions are extracted from the launcher at run time rather than
    copied, so this fails if the real ones change shape.

    Usage:  pwsh -NoProfile -File tests/test-launcher-config.ps1
    Runs on Linux or Windows. Nothing outside a temporary folder is touched.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSCommandPath
$launcher = Join-Path (Split-Path -Parent $here) 'FrivOSC-Launcher.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw ("FrivOSC-Launcher.ps1 was not found at {0}." -f $launcher)
}

function Get-LauncherFunction([string] $Source, [string] $Name, [string] $Until) {
    $start = $Source.IndexOf(('function {0} {{' -f $Name))
    $end = $Source.IndexOf(('function {0} {{' -f $Until), $start)
    if ($start -lt 0 -or $end -le $start) {
        throw ('{0} could not be located in the launcher.' -f $Name)
    }
    return $Source.Substring($start, $end - $start)
}

$source = Get-Content -LiteralPath $launcher -Raw
$start = $source.IndexOf('function Read-FrivOSCConfig {')
$end = $source.IndexOf('function Test-FrivOSCStartsWithWindows {')
if ($start -lt 0 -or $end -le $start) {
    throw 'The config functions could not be located in the launcher.'
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('frivosc-cfg-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$DataDir = $sandbox
$ConfigPath = Join-Path $sandbox 'config.json'
. ([scriptblock]::Create($source.Substring($start, $end - $start)))
# The one that decides, on close, between hiding to the notification area
# and stopping the relay.
. ([scriptblock]::Create((Get-LauncherFunction $source 'Test-FrivOSCStopOnClose' 'Sync-FrivOSCSettingsView')))

$fails = @()
function Check([string] $Name, [bool] $Condition, $Got) {
    if ($Condition) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name   got=$Got"; $script:fails += $Name }
}

try {
    Write-Host '--- defaults ---'
    $config = Read-FrivOSCConfig
    Check 'no config file still reads' ($null -ne $config) 'null'
    Check 'stop_on_close defaults to false, so FrivOSC keeps relaying' `
        ($config['stop_on_close'] -eq $false) $config['stop_on_close']
    Check 'the VRChat ports have their usual defaults' `
        ($config['listen_port'] -eq 9001 -and $config['vrchat_send_port'] -eq 9000) `
        ("$($config['listen_port'])/$($config['vrchat_send_port'])")

    Write-Host ''
    Write-Host '--- writing one key at a time ---'
    Check 'the address saves' (Save-FrivOSCUrl 'https://192.168.1.248:5000/') $false
    Check 'and its trailing slash is trimmed' `
        ((Read-FrivOSCConfig)['frivo_url'] -eq 'https://192.168.1.248:5000') `
        (Read-FrivOSCConfig)['frivo_url']

    Check 'stop_on_close saves' (Save-FrivOSCConfigValue 'stop_on_close' $true) $false
    $config = Read-FrivOSCConfig
    Check 'and reads back as true' ($config['stop_on_close'] -eq $true) $config['stop_on_close']
    Check 'without disturbing the address' `
        ($config['frivo_url'] -eq 'https://192.168.1.248:5000') $config['frivo_url']

    Write-Host ''
    Write-Host '--- keys this window has never heard of ---'
    # The service owns this file too. Writing a setting from here must not
    # quietly delete something the service put there.
    $raw = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $raw | Add-Member -NotePropertyName 'heartbeat_seconds' -NotePropertyValue 9.5 -Force
    $raw | Add-Member -NotePropertyName 'ca_cert' -NotePropertyValue 'C:\ca.crt' -Force
    Set-Content -LiteralPath $ConfigPath -Value ($raw | ConvertTo-Json)

    [void](Save-FrivOSCConfigValue 'stop_on_close' $false)
    $config = Read-FrivOSCConfig
    Check 'a service-owned number survives a write from here' `
        ($config['heartbeat_seconds'] -eq 9.5) $config['heartbeat_seconds']
    Check 'so does a service-owned path' `
        ($config['ca_cert'] -eq 'C:\ca.crt') $config['ca_cert']
    Check 'and the key we actually changed changed' `
        ($config['stop_on_close'] -eq $false) $config['stop_on_close']

    Write-Host ''
    Write-Host '--- what closing the window does ---'
    # False means hide to the notification area and keep relaying. This is
    # the default, and it has to survive a missing key, a missing file and
    # a corrupt one — every one of those must not read as "stop".
    Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
    Check 'no config file: the window hides rather than stopping the relay' `
        (-not (Test-FrivOSCStopOnClose)) 'it would stop'

    [void](Save-FrivOSCUrl 'https://frivo.local:5000')
    Check 'a config with no such key: still hides' `
        (-not (Test-FrivOSCStopOnClose)) 'it would stop'

    [void](Save-FrivOSCConfigValue 'stop_on_close' $true)
    Check 'asked to stop: it stops' (Test-FrivOSCStopOnClose) 'it would hide'

    [void](Save-FrivOSCConfigValue 'stop_on_close' $false)
    Check 'asked to keep running: back to hiding' `
        (-not (Test-FrivOSCStopOnClose)) 'it would stop'

    Set-Content -LiteralPath $ConfigPath -Value '{ broken'
    Check 'a corrupt config does not silently start stopping the relay' `
        (-not (Test-FrivOSCStopOnClose)) 'it would stop'

    Write-Host ''
    Write-Host '--- a corrupt file ---'
    Set-Content -LiteralPath $ConfigPath -Value '{ not json at all'
    $threw = $false
    try { $config = Read-FrivOSCConfig } catch { $threw = $true }
    Check 'does not throw' (-not $threw) 'it threw'
    Check 'and falls back to the safe default' `
        ((-not $threw) -and $config['stop_on_close'] -eq $false) 'no'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails.Count) {
    Write-Host ("{0} failed: {1}" -f $fails.Count, ($fails -join ', '))
    exit 1
}
Write-Host '18 passed, 0 failed'
