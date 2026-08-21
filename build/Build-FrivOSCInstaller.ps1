[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$build = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $build

function Find-InnoSetupCompiler {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
    throw 'Inno Setup 6 was not found. Install it, then run this build script again.'
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

$iscc = Find-InnoSetupCompiler
& $iscc (Join-Path $build 'FrivOSC.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup could not build FrivOSCSetup.exe.' }

$installer = Join-Path $root 'dist\FrivOSCSetup.exe'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'FrivOSCSetup.exe was not created.' }
Write-Host ('Built: {0}' -f $installer)
