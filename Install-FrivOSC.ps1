<#
  FrivOSC — one-click Windows installer

  Deliberately much smaller than Evora's. FrivOSC only forwards UDP
  packets and makes outbound HTTP calls, so there is no GPU runtime, no
  model download, and — because it never listens on a network port — no
  firewall rule to add or to clean up afterwards.

  What it does need is a Python interpreter, an isolated environment, the
  address of the Frivo server, and something to start it at logon.
#>

[CmdletBinding()]
param(
    [switch] $Silent,
    [switch] $Uninstall,
    [switch] $NoUi,
    [string] $FrivoUrl = '',
    [string] $InstallPath = (Join-Path $env:ProgramFiles 'FrivOSC')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'FrivOSC Setup supports 64-bit Windows 10 and Windows 11.'
}

# Installing under Program Files and writing the machine-wide uninstall
# entry both require elevation. Relaunch once, keeping the wizard visible.
$admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $admin) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    if ($Silent) { $arguments += '-Silent' }
    if ($Uninstall) { $arguments += '-Uninstall' }
    if ($NoUi) { $arguments += '-NoUi' }
    if ($FrivoUrl) { $arguments += @('-FrivoUrl', ('"{0}"' -f $FrivoUrl)) }
    if ($InstallPath) { $arguments += @('-InstallPath', ('"{0}"' -f $InstallPath)) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments
    exit 0
}

$SourceDir = Split-Path -Parent $PSCommandPath
$LogPath = Join-Path ([IO.Path]::GetTempPath()) 'FrivOSC-Setup.log'
$script:InstallMarkerName = '.frivosc-install.json'
$script:InstallMarkerId = 'com.frivo.frivosc'
$script:TaskName = 'FrivOSC'
$script:RequiredPythonRuntime = '3.11.9'
# Where the service reads its settings. Setup writes it here while
# elevated; the service reads it while not, and Program Files is not
# writable by an ordinary user.
$script:DataDir = Join-Path $env:ProgramData 'FrivOSC'

function Write-SetupLog([string] $Message) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogPath -Value ("[{0}] {1}" -f $stamp, $Message) -Encoding utf8
}

function Get-FrivOSCInstallMarkerPath([string] $Path) {
    return Join-Path $Path $script:InstallMarkerName
}

function Test-FrivOSCInstallOwnership([string] $Path) {
    <#
        Never claim a folder this installer did not create. The marker
        records the path it was written for, so pointing setup at, say,
        C:\Windows cannot make it believe it owns the contents.
    #>
    try {
        $markerPath = Get-FrivOSCInstallMarkerPath $Path
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
        $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$marker.Id -ne $script:InstallMarkerId) { return $false }
        $actual = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $recorded = [IO.Path]::GetFullPath([string]$marker.InstallPath).TrimEnd('\', '/')
        return $actual.Equals($recorded, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Write-FrivOSCInstallMarker([string] $Path) {
    $marker = [ordered]@{
        Id = $script:InstallMarkerId
        InstallPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Get-FrivOSCInstallMarkerPath $Path), ($marker | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

function Get-ExistingFrivOSCInstall([string] $Path) {
    if (Test-FrivOSCInstallOwnership $Path) {
        $state = if (Test-Path -LiteralPath (Join-Path $Path '.venv\Scripts\python.exe') -PathType Leaf) { 'Installed' } else { 'Partial' }
        return [pscustomobject]@{ State = $state; Path = $Path; Owned = $true }
    }
    return [pscustomobject]@{ State = 'None'; Path = $Path; Owned = $false }
}

${script:SetupPulse} = {}
function Set-FrivOSCSetupPulse([scriptblock] $Pulse) { $script:SetupPulse = if ($Pulse) { $Pulse } else { {} } }

function Invoke-Checked([string] $FilePath, [string[]] $Arguments, [string] $WorkingDirectory) {
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw ('Setup could not find the required program: {0}' -f $FilePath)
    }
    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw ('Setup could not find its working folder: {0}' -f $WorkingDirectory)
    }
    Write-SetupLog ('RUN {0} {1}' -f $FilePath, ($Arguments -join ' '))
    $quotedArguments = @($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $quotedArguments
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    while (-not $process.HasExited) {
        & $script:SetupPulse
        Start-Sleep -Milliseconds 300
    }
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0) { throw ("{0} failed with exit code {1}." -f $FilePath, $exitCode) }
}

function Find-InstalledPython {
    <#
        Any Python 3.9 or newer will do — the service imports nothing
        outside the standard library. Prefer whatever is already on the
        machine and only download an interpreter when there is none, so a
        PC that already has Python does not acquire a second copy.
    #>
    $candidates = New-Object System.Collections.ArrayList
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        foreach ($version in @('-3.12', '-3.11', '-3.10', '-3')) {
            try {
                $reported = @(& $py.Source $version -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1)
                if ($reported.Count -eq 1) { [void]$candidates.Add($reported[0].ToString().Trim()) }
            } catch { }
        }
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) { [void]$candidates.Add($python.Source) }
    # Join-Path throws on an empty base rather than returning anything, and
    # these variables are not guaranteed — a service context can be missing
    # LocalAppData entirely. Skip the root rather than fail the install.
    foreach ($root in @(
        @{ Base = $env:ProgramFiles;  Suffix = '{0}\python.exe' }
        @{ Base = $env:LocalAppData;  Suffix = 'Programs\Python\{0}\python.exe' }
    )) {
        if ([string]::IsNullOrWhiteSpace($root.Base)) { continue }
        foreach ($name in @('Python312', 'Python311', 'Python310')) {
            [void]$candidates.Add((Join-Path $root.Base ($root.Suffix -f $name)))
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            # A Microsoft Store alias is a zero-byte stub that opens the
            # Store rather than running anything.
            try { if ((Get-Item -LiteralPath $candidate).Length -lt 1024) { continue } } catch { continue }
            return $candidate
        }
    }
    return $null
}

function Install-Python {
    $python = Find-InstalledPython
    if ($python) {
        Write-SetupLog ('Using the Python already installed at {0}' -f $python)
        return $python
    }
    $installer = Join-Path ([IO.Path]::GetTempPath()) ('python-{0}-amd64.exe' -f $script:RequiredPythonRuntime)
    Write-SetupLog ('Downloading Python {0} from python.org.' -f $script:RequiredPythonRuntime)
    Invoke-WebRequest -Uri ('https://www.python.org/ftp/python/{0}/python-{0}-amd64.exe' -f $script:RequiredPythonRuntime) `
        -OutFile $installer -UseBasicParsing
    try {
        Invoke-Checked -FilePath $installer -Arguments @(
            '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_launcher=1', 'Include_test=0'
        ) -WorkingDirectory $env:TEMP
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
    $python = Find-InstalledPython
    if (-not $python) { throw 'Python installed but could not be located. Restart Windows, then run setup again.' }
    return $python
}

function Copy-ProgramFiles([string] $Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $keep = @(
        '.gitattributes', '.gitignore', 'LICENSE', 'README.md', 'requirements.txt',
        'frivosc_service.py', 'Install-FrivOSC.ps1', 'Uninstall-FrivOSC.vbs',
        'FrivOSC-Uninstall.ps1', 'FrivOSC-Launcher.ps1', 'FrivOSCHost.exe', 'FrivOSCSetupHost.exe',
        'FrivOSC.Ui.psm1', 'FrivOSC-Setup.ps1', 'FrivOSC-Setup.vbs', 'FrivOSC.png', 'FrivOSCIcon.ico'
    )
    foreach ($name in $keep) {
        $from = Join-Path $SourceDir $name
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination (Join-Path $Destination $name) -Force
        }
    }
}

function Write-FrivOSCConfig([string] $FrivoUrl) {
    <#
        Merges rather than overwrites: an update must not discard a port or
        certificate path someone set by hand, and must not blank the Frivo
        address when setup was run without one.
    #>
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    $configPath = Join-Path $script:DataDir 'config.json'
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            foreach ($property in $existing.PSObject.Properties) { $config[$property.Name] = $property.Value }
        } catch { Write-SetupLog 'Existing config.json could not be read; writing a fresh one.' }
    }
    if ($FrivoUrl) { $config['frivo_url'] = $FrivoUrl.TrimEnd('/') }
    if (-not $config.Contains('frivo_url')) { $config['frivo_url'] = '' }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

    # The service writes its log here while running as an ordinary user.
    $acl = Get-Acl -LiteralPath $script:DataDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $script:DataDir -AclObject $acl
}

function Register-FrivOSCTask([string] $Target, [bool] $StartWithWindows = $true) {
    <#
        At logon as the signed-in user, not at boot as SYSTEM the way Evora
        runs. FrivOSC is only useful while someone is at the machine playing
        VRChat, and running it as the user keeps it out of an elevated
        context it has no need for.
    #>
    $python = Join-Path $Target '.venv\Scripts\pythonw.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        $python = Join-Path $Target '.venv\Scripts\python.exe'
    }
    $script = Join-Path $Target 'frivosc_service.py'
    $action = New-ScheduledTaskAction -Execute $python -Argument ('-u "{0}"' -f $script) -WorkingDirectory $Target
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $registration = @{
        TaskName = $script:TaskName
        Action = $action
        Principal = $principal
        Settings = $settings
        Description = 'Bridges VRChat OSC to Frivo'
    }
    # A task is registered either way, so the launcher can start FrivOSC on
    # demand. The checkbox only decides whether it also gets a logon trigger.
    if ($StartWithWindows) { $registration.Trigger = New-ScheduledTaskTrigger -AtLogOn }
    Register-ScheduledTask @registration | Out-Null
    try { Start-ScheduledTask -TaskName $script:TaskName } catch { Write-SetupLog 'Could not start the task immediately.' }
}

function Register-FrivOSCInstalledApp([string] $Target) {
    $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FrivOSC'
    $uninstaller = Join-Path $Target 'Uninstall-FrivOSC.vbs'
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayName' -Value 'FrivOSC' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayVersion' -Value '1.0' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'Publisher' -Value 'Friday' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'InstallLocation' -Value $Target -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'UninstallString' -Value ('wscript.exe "{0}"' -f $uninstaller) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayIcon' -Value ((Join-Path $Target 'FrivOSCIcon.ico') + ',0') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
}

function Remove-FrivOSCInstalledApp {
    Remove-Item -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FrivOSC' -Recurse -Force -ErrorAction SilentlyContinue
}

function Stop-FrivOSCForUpdate([string] $Target) {
    try { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue } catch { }
    # The task hosts a python.exe that holds the install folder open. End
    # only the interpreters running out of this exact installation.
    $venvRoot = [IO.Path]::GetFullPath((Join-Path $Target '.venv')).TrimEnd('\', '/')
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('python.exe', 'pythonw.exe') -and $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith($venvRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($process in $running) {
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 400 }
}

function New-Shortcut([string] $Target, [string] $Link, [string] $WorkingDirectory, [string] $IconPath, [string] $Arguments) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Link)
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = 'Open FrivOSC status and settings'
    if ($Arguments) { $shortcut.Arguments = $Arguments }
    if ($IconPath -and (Test-Path -LiteralPath $IconPath -PathType Leaf)) { $shortcut.IconLocation = ('{0},0' -f $IconPath) }
    $shortcut.Save()
}

function Uninstall-FrivOSC([string] $Target, [switch] $KeepSettings) {
    Write-SetupLog ('FrivOSC uninstall starting for {0}' -f $Target)
    Stop-FrivOSCForUpdate $Target
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-FrivOSCInstalledApp

    foreach ($root in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))) {
        if (-not $root) { continue }
        $link = Join-Path $root 'FrivOSC.lnk'
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    }

    if (-not $KeepSettings -and (Test-Path -LiteralPath $script:DataDir)) {
        Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Only ever delete a folder this installer wrote a marker into.
    if ((Test-FrivOSCInstallOwnership $Target) -and (Test-Path -LiteralPath $Target)) {
        try {
            Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop
        } catch {
            # The uninstaller itself may be running from inside the folder.
            # Schedule the leftovers rather than reporting a failure.
            Write-SetupLog ('Deferred removal of {0}: {1}' -f $Target, $_.Exception.Message)
            $cmd = 'ping 127.0.0.1 -n 4 > nul & rmdir /s /q "{0}"' -f $Target
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -WindowStyle Hidden | Out-Null
        }
    }
    Write-SetupLog 'FrivOSC uninstall completed.'
}

function Install-FrivOSC {
    param(
        [string] $Target,
        [scriptblock] $OnProgress,
        [string] $FrivoUrl = '',
        [bool] $CreateDesktopShortcut = $true,
        [bool] $StartWithWindows = $true,
        [switch] $Repair
    )
    & $OnProgress 5 'Preparing FrivOSC...'
    if (Test-FrivOSCInstallOwnership $Target) {
        & $OnProgress 8 'Stopping the running FrivOSC service...'
        Stop-FrivOSCForUpdate $Target
    }

    $venv = Join-Path $Target '.venv'
    $venvPython = Join-Path $venv 'Scripts\python.exe'

    if ($Repair -and (Test-Path -LiteralPath $venv -PathType Container)) {
        & $OnProgress 10 'Removing the previous private environment...'
        Remove-Item -LiteralPath $venv -Recurse -Force -ErrorAction Stop
    }

    & $OnProgress 15 'Copying program files...'
    Copy-ProgramFiles $Target

    if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
        & $OnProgress 55 'Reusing the private Python environment...'
    } else {
        & $OnProgress 25 'Looking for a Python runtime...'
        $python = Install-Python
        & $OnProgress 45 'Creating the private Python environment...'
        if (Test-Path -LiteralPath $venv) { Remove-Item -LiteralPath $venv -Recurse -Force }
        Invoke-Checked -FilePath $python -Arguments @('-m', 'venv', $venv) -WorkingDirectory $Target
        if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
            throw ('Python completed but did not create the expected environment at: {0}' -f $venvPython)
        }
    }
    # No pip install step, and no requirements to resolve: the service uses
    # the standard library only. That is the whole reason this install is
    # seconds rather than minutes.

    & $OnProgress 70 'Saving the Frivo address...'
    Write-FrivOSCConfig $FrivoUrl

    Write-FrivOSCInstallMarker $Target

    & $OnProgress 85 'Registering FrivOSC to start with Windows...'
    Register-FrivOSCTask $Target -StartWithWindows $StartWithWindows
    Register-FrivOSCInstalledApp $Target

    if ($CreateDesktopShortcut) {
        $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = [Environment]::GetFolderPath('Desktop') }
        $hostExe = Join-Path $Target 'FrivOSCHost.exe'
        $launcher = Join-Path $Target 'FrivOSC-Launcher.ps1'
        $icon = Join-Path $Target 'FrivOSCIcon.ico'
        if ([string]::IsNullOrWhiteSpace($desktop)) {
            & $Log 'No desktop folder was found, so no shortcut was created.'
        } elseif (Test-Path -LiteralPath $hostExe -PathType Leaf) {
            New-Shortcut -Target $hostExe -Link (Join-Path $desktop 'FrivOSC.lnk') -WorkingDirectory $Target `
                -IconPath $icon -Arguments ('--script "{0}"' -f $launcher)
        } else {
            # FrivOSCHost.exe is a build output. Installing straight from the
            # repository there is none, and skipping the shortcut entirely
            # left no way to open FrivOSC at all. Point at PowerShell instead.
            $powershell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
            if (Test-Path -LiteralPath $powershell -PathType Leaf) {
                New-Shortcut -Target $powershell -Link (Join-Path $desktop 'FrivOSC.lnk') -WorkingDirectory $Target `
                    -IconPath $icon -Arguments ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $launcher)
            } else {
                & $Log 'Windows PowerShell was not found, so no shortcut was created.'
            }
        }
    }

    & $OnProgress 100 'FrivOSC is ready.'
}

if ($Uninstall) {
    try { Uninstall-FrivOSC -Target $InstallPath; exit 0 }
    catch { Write-Error $_; exit 1 }
}

if ($Silent) {
    try {
        Install-FrivOSC -Target $InstallPath -FrivoUrl $FrivoUrl -OnProgress {
            param($percent, $message) Write-Host ("{0}%  {1}" -f $percent, $message)
        }
        exit 0
    } catch { Write-Error $_; exit 1 }
}

if ($NoUi) { return }

throw 'Run FrivOSC-Setup.ps1 for the setup window, or pass -Silent.'
