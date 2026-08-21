[CmdletBinding()]
param([string]$InstallPath=(Join-Path $env:ProgramFiles 'FrivOSC'))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSCommandPath
$SetupLog=Join-Path ([IO.Path]::GetTempPath()) 'FrivOSC-Setup.log'

# Everything below runs inside this try. Setup is started with the window
# hidden, so without it any failure before the wizard appears is completely
# invisible — nothing opens, nothing is written, and there is nothing to
# report. Frivo learned this the hard way in 1.0.1.
try {

$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){
  $setupHost=Join-Path $root 'FrivOSCSetupHost.exe'
  if(Test-Path -LiteralPath $setupHost){Start-Process -FilePath $setupHost -Verb RunAs -WindowStyle Hidden -ArgumentList @('--script',('"{0}"' -f $PSCommandPath));exit}
  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',('"{0}"' -f $PSCommandPath),'-InstallPath',('"{0}"' -f $InstallPath));exit
}

. (Join-Path $root 'Install-FrivOSC.ps1') -NoUi -InstallPath $InstallPath
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $root 'FrivOSC.Ui.psm1') -Force
$Theme=Get-FrivoTheme
$existing=Get-ExistingFrivOSCInstall $InstallPath

$form=New-FrivoForm -Theme $Theme -Title 'FrivOSC Setup' -Width 620 -Height 500 -IconPath (Join-Path $root 'FrivOSCIcon.ico')
$header=New-FrivoHeader -Theme $Theme -Form $form -Title 'Welcome to FrivOSC Setup' -Subtitle 'VRChat OSC for Frivo' -LogoPngPath (Join-Path $root 'FrivOSC.png')
$body=New-Object System.Windows.Forms.Panel;$body.Location=[Drawing.Point]::new(0,76);$body.Size=[Drawing.Size]::new(620,362);$body.BackColor=$Theme.Bg;$form.Controls.Add($body)
$footer=New-Object System.Windows.Forms.Panel;$footer.Location=[Drawing.Point]::new(0,438);$footer.Size=[Drawing.Size]::new(620,62);$footer.BackColor=$Theme.Bg;$form.Controls.Add($footer)
$back=New-FrivoButton -Theme $Theme -Parent $footer -Text 'Back' -X 272 -Y 14 -W 96 -H 36
$next=New-FrivoButton -Theme $Theme -Parent $footer -Text 'Next' -X 380 -Y 14 -W 110 -H 36 -Primary $true
$cancel=New-FrivoButton -Theme $Theme -Parent $footer -Text 'Cancel' -X 502 -Y 14 -W 96 -H 36
function Page{$p=New-Object System.Windows.Forms.Panel;$p.Location=[Drawing.Point]::new(0,0);$p.Size=[Drawing.Size]::new(620,362);$p.BackColor=$Theme.Bg;$p.Visible=$false;$body.Controls.Add($p);return $p}

# --- existing install ---------------------------------------------------
$old=Page
$oldText=New-FrivoLabel -Theme $Theme -Parent $old -Text '' -X 28 -Y 10 -W 564 -H 104 -Font $Theme.FontUI -Color $Theme.Ink
$oldCard=New-FrivoCard -Theme $Theme -Parent $old -X 24 -Y 122 -W 572 -H 216
$update=New-FrivoRadio -Theme $Theme -Parent $oldCard -Text 'Update FrivOSC' -X 18 -Y 12 -W 536 -Checked $true
[void](New-FrivoLabel -Theme $Theme -Parent $oldCard -Text 'Updates the program files. Keeps your Frivo address and settings.' -X 38 -Y 34 -W 516 -H 30 -Font $Theme.FontSmall -Color $Theme.Dim)
$repair=New-FrivoRadio -Theme $Theme -Parent $oldCard -Text 'Repair FrivOSC' -X 18 -Y 82 -W 536
[void](New-FrivoLabel -Theme $Theme -Parent $oldCard -Text 'Rebuilds the private Python environment. Settings are kept.' -X 38 -Y 104 -W 516 -H 30 -Font $Theme.FontSmall -Color $Theme.Dim)
$remove=New-FrivoRadio -Theme $Theme -Parent $oldCard -Text 'Uninstall FrivOSC' -X 18 -Y 152 -W 536
[void](New-FrivoLabel -Theme $Theme -Parent $oldCard -Text 'Removes FrivOSC and its settings. Frivo itself is not affected.' -X 38 -Y 174 -W 516 -H 30 -Font $Theme.FontSmall -Color $Theme.Dim)

# --- welcome ------------------------------------------------------------
$welcome=Page
[void](New-FrivoLabel -Theme $Theme -Parent $welcome -Text 'This wizard will install FrivOSC on this computer.' -X 28 -Y 12 -W 564 -H 22 -Font $Theme.FontMid -Color $Theme.Ink)
[void](New-FrivoLabel -Theme $Theme -Parent $welcome -Text "FrivOSC lets Frivo connect to VRChat through OSC. Install it on the computer you play VRChat on.`r`n`r`nIt installs its own small Python environment and needs no other downloads. Click Next to continue." -X 28 -Y 44 -W 564 -H 200 -Font $Theme.FontUI -Color $Theme.Dim)

# --- destination --------------------------------------------------------
$location=Page
[void](New-FrivoLabel -Theme $Theme -Parent $location -Text 'DESTINATION FOLDER' -X 30 -Y 10 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$locCard=New-FrivoCard -Theme $Theme -Parent $location -X 24 -Y 30 -W 572 -H 58
$pathBox=New-FrivoTextBox -Theme $Theme -Parent $locCard -X 16 -Y 16 -W 428 -H 26
$pathBox.Text=$InstallPath
$browse=New-FrivoButton -Theme $Theme -Parent $locCard -Text 'Browse...' -X 456 -Y 12 -W 100 -H 32
$browse.Add_Click({$d=New-Object System.Windows.Forms.FolderBrowserDialog;if($d.ShowDialog() -eq 'OK'){$pathBox.Text=Join-Path $d.SelectedPath 'FrivOSC'}})

# --- Frivo address ------------------------------------------------------
# The one thing FrivOSC genuinely cannot work out for itself. Everything
# else on this wizard has a sane default; this does not, so it gets its own
# page and a Test button rather than being buried among the checkboxes.
$server=Page
[void](New-FrivoLabel -Theme $Theme -Parent $server -Text 'FRIVO SERVER' -X 30 -Y 10 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$srvCard=New-FrivoCard -Theme $Theme -Parent $server -X 24 -Y 30 -W 572 -H 66
$urlBox=New-FrivoTextBox -Theme $Theme -Parent $srvCard -X 16 -Y 20 -W 428 -H 26
$urlBox.Text='https://localhost:5000'
$testBtn=New-FrivoButton -Theme $Theme -Parent $srvCard -Text 'Test' -X 456 -Y 16 -W 100 -H 32
$srvNote=New-FrivoLabel -Theme $Theme -Parent $server -Text 'If Frivo runs on this same computer, leave this as it is. Otherwise enter that computer''s address, for example https://192.168.1.50:5000' -X 28 -Y 106 -W 564 -H 44 -Font $Theme.FontSmall -Color $Theme.Dim
$testNote=New-FrivoLabel -Theme $Theme -Parent $server -Text '' -X 28 -Y 156 -W 564 -H 60 -Font $Theme.FontSmall -Color $Theme.Dim
[void](New-FrivoLabel -Theme $Theme -Parent $server -Text 'FrivOSC only makes outgoing connections to Frivo. It does not open any ports on this computer and needs no firewall rule.' -X 28 -Y 226 -W 564 -H 44 -Font $Theme.FontSmall -Color $Theme.Faint)

function Test-FrivoServer([string]$Url){
  # Frivo serves HTTPS with a certificate it signed itself, which this
  # machine has no reason to trust. Setup is only checking that something
  # answers, so certificate validation is deliberately bypassed here.
  $callback=[System.Net.ServicePointManager]::ServerCertificateValidationCallback
  try{
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback={$true}
    try{[System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12}catch{}
    $base=$Url.TrimEnd('/')
    try{
      $hello=Invoke-WebRequest -Uri ($base+'/api/frivosc/hello') -Method Post -Body '{"version":"setup"}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 8
      if($hello.StatusCode -ge 200 -and $hello.StatusCode -lt 300){return [pscustomobject]@{Ok=$true;Message='Frivo answered and supports FrivOSC.'}}
    }catch{
      $status=$null
      try{$status=[int]$_.Exception.Response.StatusCode}catch{}
      if($status -eq 404){
        # Reachable, but running a Frivo build from before FrivOSC existed.
        # Worth saying plainly rather than reporting a bare failure.
        return [pscustomobject]@{Ok=$false;Message='Frivo answered, but this version does not support FrivOSC yet. Update Frivo, then use Test again.'}
      }
    }
    $root=Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 8
    if($root.StatusCode -ge 200 -and $root.StatusCode -lt 400){return [pscustomobject]@{Ok=$false;Message='Something answered at that address, but it did not look like Frivo.'}}
    return [pscustomobject]@{Ok=$false;Message='No answer from that address.'}
  }catch{
    return [pscustomobject]@{Ok=$false;Message=('Could not reach Frivo: '+$_.Exception.Message)}
  }finally{
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback=$callback
  }
}

$testBtn.Add_Click({
  $testNote.ForeColor=$Theme.Dim
  $testNote.Text='Testing...'
  [System.Windows.Forms.Application]::DoEvents()
  $result=Test-FrivoServer $urlBox.Text
  $testNote.ForeColor=if($result.Ok){$Theme.Signal}else{$Theme.Warn}
  $testNote.Text=$result.Message
})

# --- options ------------------------------------------------------------
$options=Page
[void](New-FrivoLabel -Theme $Theme -Parent $options -Text 'SHORTCUTS' -X 30 -Y 8 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$shortcuts=New-FrivoCard -Theme $Theme -Parent $options -X 24 -Y 28 -W 572 -H 58
$desktopShortcut=New-FrivoCheck -Theme $Theme -Parent $shortcuts -Text 'Create a desktop shortcut' -X 18 -Y 16 -W 536 -Checked $true
[void](New-FrivoLabel -Theme $Theme -Parent $options -Text 'STARTUP' -X 30 -Y 100 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$startupCard=New-FrivoCard -Theme $Theme -Parent $options -X 24 -Y 120 -W 572 -H 74
$startWithWindows=New-FrivoCheck -Theme $Theme -Parent $startupCard -Text 'Start FrivOSC automatically when you sign in' -X 18 -Y 12 -W 536 -Checked $true
[void](New-FrivoLabel -Theme $Theme -Parent $startupCard -Text 'Runs quietly in the background so VRChat and Frivo stay in step.' -X 38 -Y 38 -W 516 -H 20 -Font $Theme.FontSmall -Color $Theme.Dim)
[void](New-FrivoLabel -Theme $Theme -Parent $options -Text 'IN VRCHAT' -X 30 -Y 208 -W 400 -H 14 -Font $Theme.FontCaps -Color $Theme.Faint)
$vrcCard=New-FrivoCard -Theme $Theme -Parent $options -X 24 -Y 228 -W 572 -H 72
[void](New-FrivoLabel -Theme $Theme -Parent $vrcCard -Text "Turn on OSC in VRChat's Options menu. FrivOSC has nothing to listen to until you do." -X 18 -Y 22 -W 536 -H 40 -Font $Theme.FontSmall -Color $Theme.Dim)

function Start-FrivOSCLauncher([string]$Target){
  # FrivOSCHost.exe is a build output (build\Build-FrivOSCInstaller.ps1
  # compiles it). A repo install has no host, so fall back to PowerShell
  # rather than silently doing nothing, which is how this first went wrong.
  $launcher=Join-Path $Target 'FrivOSC-Launcher.ps1'
  if(-not (Test-Path -LiteralPath $launcher)){return}
  $launcherHost=Join-Path $Target 'FrivOSCHost.exe'
  try{
    if(Test-Path -LiteralPath $launcherHost){
      Start-Process -FilePath $launcherHost -WorkingDirectory $Target -ArgumentList @('--script',('"{0}"' -f $launcher))
    }else{
      Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Target -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',('"{0}"' -f $launcher))
    }
  }catch{}
}

# --- installing / done --------------------------------------------------
$installPage=Page
$bar=New-FrivoProgress -Theme $Theme -Parent $installPage -X 24 -Y 14 -W 572 -H 10
$activity=New-FrivoLabel -Theme $Theme -Parent $installPage -Text 'Working' -X 24 -Y 28 -W 572 -H 18 -Font $Theme.FontSmall -Color $Theme.Dim
$log=New-FrivoTextBox -Theme $Theme -Parent $installPage -X 24 -Y 52 -W 572 -H 286 -Multiline

$done=Page
[void](New-FrivoLabel -Theme $Theme -Parent $done -Text 'FrivOSC is installed.' -X 28 -Y 12 -W 564 -H 22 -Font $Theme.FontMid -Color $Theme.Ink)
[void](New-FrivoLabel -Theme $Theme -Parent $done -Text "FrivOSC runs in the background. In Frivo, open Settings and turn on the OSC controls you want.`r`n`r`nOpen the FrivOSC shortcut any time to check that VRChat and Frivo are both connected." -X 28 -Y 52 -W 564 -H 90 -Font $Theme.FontUI -Color $Theme.Dim)
$launchCard=New-FrivoCard -Theme $Theme -Parent $done -X 24 -Y 154 -W 572 -H 62
$launchAfterInstall=New-FrivoCheck -Theme $Theme -Parent $launchCard -Text 'Open FrivOSC after setup finishes' -X 18 -Y 19 -W 536 -Checked $true

# --- page order ---------------------------------------------------------
$pages=New-Object System.Collections.ArrayList
if($existing.State -ne 'None'){
  [void]$pages.Add(@{p=$old;t='Existing FrivOSC installation';s='Update, repair, or remove FrivOSC';n='Next'})
}else{
  [void]$pages.Add(@{p=$welcome;t='Welcome to FrivOSC Setup';s='VRChat OSC for Frivo';n='Next'})
  [void]$pages.Add(@{p=$location;t='Select destination';s='Choose where to install FrivOSC';n='Next'})
  [void]$pages.Add(@{p=$server;t='Connect to Frivo';s='Where is Frivo running?';n='Next'})
  [void]$pages.Add(@{p=$options;t='Configuration';s='Shortcuts and startup';n='Install'})
}
[void]$pages.Add(@{p=$installPage;t='Installing';s='This only takes a moment';n='Next'})
[void]$pages.Add(@{p=$done;t='Setup complete';s='Ready to use with Frivo';n='Finish'})
$installIndex=$pages.Count-2;$doneIndex=$pages.Count-1;$script:i=0
if($existing.State -ne 'None'){
  $oldText.Text="FrivOSC is already installed at:`r`n$($existing.Path)`r`n`r`nSelect an option to continue."
  if($existing.State -eq 'Partial'){$oldText.Text="FrivOSC has an incomplete installation at:`r`n$($existing.Path)`r`n`r`nUpdate will recreate its private environment.";$update.Checked=$true}
}

function Show([int]$n){
  foreach($x in $pages){$x.p.Visible=$false}
  $pages[$n].p.Visible=$true
  $header.Title.Text=$pages[$n].t
  $header.Subtitle.Text=$pages[$n].s
  $next.Text=$pages[$n].n
  $back.Visible=($n -gt 0 -and $n -lt $installIndex)
  $back.Enabled=$back.Visible
  $cancel.Enabled=($n -lt $installIndex)
  $next.Enabled=($n -ne $installIndex)
}

$script:isInstalling=$false;$script:setupFailed=$false;$script:pulse=0
$pulseTimer=New-Object System.Windows.Forms.Timer;$pulseTimer.Interval=450
$pulseTimer.Add_Tick({if($script:isInstalling){$script:pulse=($script:pulse+1)%4;$activity.Text=('Working'+('.' * $script:pulse))}})
function Log([string]$m){$log.AppendText($m+"`r`n");$log.SelectionStart=$log.TextLength;$log.ScrollToCaret();[System.Windows.Forms.Application]::DoEvents()}

$back.Add_Click({if($script:i -gt 0){$script:i--;Show $script:i}})
$cancel.Add_Click({$form.Close()})
$next.Add_Click({
  if($script:setupFailed){$form.Close();return}
  $cur=$pages[$script:i]

  if($cur.p -eq $old -and $remove.Checked){
    $uninstaller=Join-Path $existing.Path 'Uninstall-FrivOSC.vbs'
    if(Test-Path -LiteralPath $uninstaller){Start-Process $uninstaller}else{Uninstall-FrivOSC -Target $existing.Path}
    $form.Close();return
  }

  # A blank address installs a FrivOSC that cannot do anything, and the
  # only sign would be silence. Stop here rather than let that ship.
  if($cur.p -eq $server -and [string]::IsNullOrWhiteSpace($urlBox.Text)){
    $testNote.ForeColor=$Theme.Warn
    $testNote.Text='Enter the address Frivo is running on before continuing.'
    return
  }

  $beginInstall=($cur.p -eq $options) -or ($cur.p -eq $old -and $existing.State -ne 'None')
  if($beginInstall){
    $repairing=($existing.State -ne 'None' -and ($repair.Checked -or $existing.State -eq 'Partial'))
    $operation=if($existing.State -eq 'None'){'Installing FrivOSC'}elseif($repairing){'Repairing FrivOSC'}else{'Updating FrivOSC'}
    $pages[$installIndex].t=$operation
    $pages[$installIndex].s=if($repairing){'Rebuilding the private environment'}else{'This only takes a moment'}
    $script:i=$installIndex;Show $script:i
    $script:isInstalling=$true;$pulseTimer.Start()
    Set-FrivOSCSetupPulse { [System.Windows.Forms.Application]::DoEvents() }
    try{
      Log ($operation+'. Do not close this window.')
      # An update keeps whatever address is already saved: passing '' here
      # tells the installer to merge rather than overwrite.
      $url=if($existing.State -eq 'None'){$urlBox.Text.Trim()}else{''}
      Install-FrivOSC -Target $pathBox.Text -FrivoUrl $url -Repair:$repairing `
        -CreateDesktopShortcut $desktopShortcut.Checked -StartWithWindows $startWithWindows.Checked `
        -OnProgress {param($p,$m)$bar.SetValue($p);Log $m}
      $script:isInstalling=$false;$pulseTimer.Stop()
      $script:i=$doneIndex;Show $script:i
    }catch{
      $script:isInstalling=$false;$script:setupFailed=$true;$pulseTimer.Stop()
      $header.Title.Text='Setup failed'
      $header.Subtitle.Text='FrivOSC was not changed'
      $activity.Text='Setup failed'
      Log ('Setup failed: '+$_.Exception.Message)
      $next.Enabled=$true;$next.Text='Close';$cancel.Visible=$false
    }
    return
  }

  if($cur.p -eq $done){
    if($launchAfterInstall.Checked){ Start-FrivOSCLauncher $pathBox.Text }
    $form.Close();return
  }

  $script:i++;Show $script:i
})
Show 0
[void]$form.ShowDialog()

} catch {
    $reason = $_.Exception.Message
    $where  = $_.ScriptStackTrace
    try {
        Add-Content -LiteralPath $SetupLog -Value (
            "{0}`r`n{1}`r`n{2}`r`n----" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $reason, $where)
    } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            ("FrivOSC Setup could not start.`r`n`r`n{0}`r`n`r`nDetails were saved to:`r`n{1}" -f $reason, $SetupLog),
            'FrivOSC Setup',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
    exit 1
}
