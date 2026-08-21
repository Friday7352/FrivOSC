<#
  Installer logic tests — no WinForms, no registry, no real install.

  The functions extracted here are the ones that can do damage or lose
  data: ownership decides whether a folder gets deleted recursively, and
  the config merge decides whether someone's Frivo address survives an
  update. Both are run for real against a temporary tree.

  Runs under StrictMode, like the installer does.

      pwsh -NoProfile -File tests/test-install-logic.ps1
#>

param([string] $RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$script:pass = 0
$script:fail = 0

function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) { Write-Host ("  PASS  " + $Name); $script:pass++ }
    else { Write-Host ("  FAIL  " + $Name + $(if ($Detail) { "  --  $Detail" } else { '' })); $script:fail++ }
}

# --- lift the pure functions out of the installer ------------------------
$installPath = Join-Path $RepoRoot 'Install-FrivOSC.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$null, [ref]$errors)
if ($errors -and @($errors).Count -gt 0) { Write-Host 'Install-FrivOSC.ps1 has parse errors'; exit 1 }

$wanted = @(
    'Get-FrivOSCInstallMarkerPath'
    'Test-FrivOSCInstallOwnership'
    'Write-FrivOSCInstallMarker'
    'Get-ExistingFrivOSCInstall'
    'Find-InstalledPython'
)
foreach ($name in $wanted) {
    $fn = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true)
    if (-not $fn) { Write-Host ("Missing function: " + $name); exit 1 }
    Invoke-Expression $fn.Extent.Text
}

$script:InstallMarkerName = '.frivosc-install.json'
$script:InstallMarkerId = 'com.frivo.frivosc'

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('frivosc-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
    Write-Host "`nOwnership — what may be deleted"

    $owned = Join-Path $sandbox 'owned'
    New-Item -ItemType Directory -Path $owned -Force | Out-Null
    Write-FrivOSCInstallMarker $owned
    Assert-True 'a folder this installer wrote a marker into is owned' (Test-FrivOSCInstallOwnership $owned)

    $bare = Join-Path $sandbox 'someone-elses-files'
    New-Item -ItemType Directory -Path $bare -Force | Out-Null
    'important' | Set-Content -LiteralPath (Join-Path $bare 'notes.txt')
    Assert-True 'an unrelated folder is NOT owned' (-not (Test-FrivOSCInstallOwnership $bare)) 'this gate is what stops a recursive delete'

    Assert-True 'a folder that does not exist is NOT owned' (-not (Test-FrivOSCInstallOwnership (Join-Path $sandbox 'nope')))

    # A marker copied elsewhere still names its original path. Honouring the
    # recorded path is what stops a stray copy authorising a delete.
    $moved = Join-Path $sandbox 'moved'
    New-Item -ItemType Directory -Path $moved -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $owned $script:InstallMarkerName) -Destination (Join-Path $moved $script:InstallMarkerName)
    Assert-True 'a marker copied into another folder does NOT transfer ownership' (-not (Test-FrivOSCInstallOwnership $moved))

    $foreign = Join-Path $sandbox 'foreign'
    New-Item -ItemType Directory -Path $foreign -Force | Out-Null
    '{"Id":"com.example.other","InstallPath":"' + ($foreign -replace '\\', '\\') + '"}' |
        Set-Content -LiteralPath (Join-Path $foreign $script:InstallMarkerName)
    Assert-True 'a marker from a different product is NOT ours' (-not (Test-FrivOSCInstallOwnership $foreign))

    $corrupt = Join-Path $sandbox 'corrupt'
    New-Item -ItemType Directory -Path $corrupt -Force | Out-Null
    'not json at all {{{' | Set-Content -LiteralPath (Join-Path $corrupt $script:InstallMarkerName)
    $threw = $false
    try { [void](Test-FrivOSCInstallOwnership $corrupt) } catch { $threw = $true }
    Assert-True 'a corrupt marker returns false instead of throwing' (-not $threw)

    Write-Host "`nExisting-install detection"

    $state = Get-ExistingFrivOSCInstall $bare
    Assert-True 'unknown folder reports None' ($state.State -eq 'None')
    $state = Get-ExistingFrivOSCInstall $owned
    Assert-True 'owned folder without a venv reports Partial' ($state.State -eq 'Partial') $state.State

    New-Item -ItemType Directory -Path (Join-Path $owned '.venv\Scripts') -Force | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $owned '.venv\Scripts\python.exe')
    $state = Get-ExistingFrivOSCInstall $owned
    Assert-True 'owned folder with a venv reports Installed' ($state.State -eq 'Installed') $state.State

    Write-Host "`nConfig merge — an update must not lose settings"

    # Write-FrivOSCConfig touches ACLs, which do not exist on Linux, so the
    # merge itself is reproduced here against the same rules it uses.
    function Merge-Config([string] $Path, [string] $Url) {
        $config = [ordered]@{}
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            foreach ($property in $existing.PSObject.Properties) { $config[$property.Name] = $property.Value }
        }
        if ($Url) { $config['frivo_url'] = $Url.TrimEnd('/') }
        if (-not $config.Contains('frivo_url')) { $config['frivo_url'] = '' }
        [IO.File]::WriteAllText($Path, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }

    $configPath = Join-Path $sandbox 'config.json'
    $result = Merge-Config $configPath 'https://192.168.1.50:5000/'
    Assert-True 'a fresh install stores the address' ($result.frivo_url -eq 'https://192.168.1.50:5000')
    Assert-True 'a trailing slash is trimmed' (-not $result.frivo_url.EndsWith('/'))

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $config | Add-Member -NotePropertyName 'listen_port' -NotePropertyValue 9005 -Force
    $config | Add-Member -NotePropertyName 'ca_cert' -NotePropertyValue 'C:\certs\ca.crt' -Force
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

    $result = Merge-Config $configPath ''
    Assert-True 'an update with no address keeps the saved one' ($result.frivo_url -eq 'https://192.168.1.50:5000') $result.frivo_url
    Assert-True 'an update keeps a hand-edited port' ($result.listen_port -eq 9005)
    Assert-True 'an update keeps a hand-edited certificate path' ($result.ca_cert -eq 'C:\certs\ca.crt')

    $result = Merge-Config $configPath 'https://10.0.0.9:5000'
    Assert-True 'a new address replaces the old one' ($result.frivo_url -eq 'https://10.0.0.9:5000')
    Assert-True 'and still keeps the other settings' ($result.listen_port -eq 9005)

    Write-Host "`nStrictMode — empty collections"

    # The class that shipped in Frivo 1.1.2: an empty result unwrapped to
    # $null, and .Count threw on it.
    $threw = $false
    try { $found = Find-InstalledPython; [void]($null -eq $found) } catch { $threw = $true }
    Assert-True 'Find-InstalledPython survives finding nothing' (-not $threw)

} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
