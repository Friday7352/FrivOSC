[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$build = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $build

function Find-InnoSetupCompiler {
    <#
        Where ISCC.exe ends up. Both Inno Setup 6 and 7 are accepted: 7 is
        current, 6 is what most machines already have, and either compiles
        these scripts. The registry is checked as well as the usual folders
        because Inno can be installed anywhere, and someone who already has
        it should never be told to install it again.
    #>
    # Built up rather than written as one array literal: Join-Path throws
    # when its base is empty, and any of these variables can be, so the
    # guard has to happen before the join rather than after it.
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles)
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $roots += (Join-Path $env:LOCALAPPDATA 'Programs')
    }

    $candidates = @()
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($name in @('Inno Setup 7', 'Inno Setup 6')) {
            $candidates += (Join-Path $root (Join-Path $name 'ISCC.exe'))
        }
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        try {
            Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Inno Setup*' -and $_.InstallLocation } |
                ForEach-Object { $candidates += (Join-Path $_.InstallLocation 'ISCC.exe') }
        } catch { }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }

    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
    return $null
}

function Install-InnoSetupWithWinget {
    if (-not (Get-Command 'winget.exe' -ErrorAction SilentlyContinue)) { return $false }
    Write-Host 'Installing Inno Setup with winget...'
    try {
        & winget.exe install --id JRSoftware.InnoSetup --exact --silent `
            --accept-package-agreements --accept-source-agreements
    } catch {
        return $false
    }
    # winget's exit code is not reliable enough to trust on its own here —
    # "already installed" and "needs a restart" both come back non-zero. Let
    # the caller look for ISCC.exe instead.
    return $true
}

function Install-InnoSetupFromJrsoftware {
    <#
        The fallback for machines with no winget — Windows Server, a stripped
        image, an account where the App Installer is not provisioned. Asks
        GitHub which release is current rather than hard-coding a version,
        because the download URLs carry the version number and would rot.
    #>
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    # Invoke-WebRequest's progress bar makes a large download several times
    # slower on Windows PowerShell. It is restored below.
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $installer = Join-Path $env:TEMP 'innosetup-latest.exe'
    try {
        Write-Host 'Asking jrsoftware.org which Inno Setup is current...'
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/jrsoftware/issrc/releases' `
            -Headers @{ 'User-Agent' = 'installer-build-script' } -TimeoutSec 30

        $asset = $null
        foreach ($release in $releases) {
            if ($release.prerelease -or $release.draft) { continue }
            # x64 first, then the plain name Inno Setup 6 releases use.
            $asset = $release.assets | Where-Object { $_.name -like 'innosetup-*x64.exe' } | Select-Object -First 1
            if (-not $asset) {
                $asset = $release.assets |
                    Where-Object { $_.name -like 'innosetup-*.exe' -and $_.name -notlike '*x86*' } |
                    Select-Object -First 1
            }
            if ($asset) { break }
        }
        if (-not $asset) { throw 'No Inno Setup installer was listed.' }

        Write-Host ('Downloading {0}...' -f $asset.name)
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing -TimeoutSec 600

        Write-Host 'Installing Inno Setup...'
        # /SP- skips the "This will install..." prompt; the rest is Inno's own
        # standard unattended set. It is an Inno Setup installer itself.
        $process = Start-Process -FilePath $installer `
            -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOCANCEL') `
            -Wait -PassThru
        return ($process.ExitCode -eq 0)
    } catch {
        Write-Host ('Could not install Inno Setup automatically: {0}' -f $_.Exception.Message)
        return $false
    } finally {
        $ProgressPreference = $previousProgress
        if (Test-Path -LiteralPath $installer) {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-InnoSetupCompiler {
    <#
        Find it, or install it and find it. Only throws once both routes have
        been tried, so "install Inno Setup" is never asked of someone who just
        wanted to double-click a build script.
    #>
    $iscc = Find-InnoSetupCompiler
    if ($iscc) { return $iscc }

    Write-Host 'Inno Setup was not found. Installing it now.'
    [void](Install-InnoSetupWithWinget)
    $iscc = Find-InnoSetupCompiler
    if ($iscc) { return $iscc }

    [void](Install-InnoSetupFromJrsoftware)
    $iscc = Find-InnoSetupCompiler
    if ($iscc) { return $iscc }

    throw @'
Inno Setup could not be installed automatically.

Install it by hand from https://jrsoftware.org/isdl.php (either version 6 or
7 works), then run this build script again. If you have just installed it,
close this window and open a new one first — a new install is not on the
path of a window that was already open.
'@
}

function Build-FrivOSCHost {
    param([string] $Output, [string] $Manifest)

    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw 'The Windows .NET compiler needed to build FrivOSC was not found.'
    }

    $automation = @(& powershell.exe -NoProfile -Command '[System.Management.Automation.PSObject].Assembly.Location') | Select-Object -First 1
    if (-not (Test-Path -LiteralPath $automation -PathType Leaf)) {
        throw 'Windows PowerShell automation support was not found.'
    }

    $arguments = @(
        '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
        ('/out:{0}' -f $Output),
        ('/win32icon:{0}' -f (Join-Path $root 'FrivOSCIcon.ico')),
        ('/reference:{0}' -f $automation),
        '/reference:System.Windows.Forms.dll',
        (Join-Path $build 'FrivOSCHost.cs')
    )
    if ($Manifest) { $arguments += ('/win32manifest:{0}' -f $Manifest) }
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Output -PathType Leaf)) {
        throw ('Could not build {0}.' -f (Split-Path -Leaf $Output))
    }
}

Build-FrivOSCHost -Output (Join-Path $root 'FrivOSCHost.exe')
Build-FrivOSCHost -Output (Join-Path $root 'FrivOSCSetupHost.exe') -Manifest (Join-Path $build 'FrivOSCSetupHost.manifest')

$iscc = Get-InnoSetupCompiler
& $iscc (Join-Path $build 'FrivOSC.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup could not build FrivOSCSetup.exe.' }

$installer = Join-Path $root 'dist\FrivOSCSetup.exe'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'FrivOSCSetup.exe was not created.' }
Write-Host ('Built: {0}' -f $installer)
