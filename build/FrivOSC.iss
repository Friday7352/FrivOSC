#define AppName "FrivOSC"
#define AppPublisher "Friday"

; The version comes from one file at the repo root, so a release is a
; one-line edit rather than four literals that can disagree — which they
; already had, before anything shipped.
#define VersionFile AddBackslash(SourcePath) + "..\VERSION"
#define VersionHandle FileOpen(VersionFile)
#define AppVersion Trim(FileRead(VersionHandle))
#expr FileClose(VersionHandle)
#if AppVersion == ""
  #error VERSION at the repo root is empty. Put a version number in it.
#endif

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=FrivOSC Setup
OutputDir=..\dist
OutputBaseFilename=FrivOSCSetup
Compression=lzma2/max
SolidCompression=yes
SetupIconFile=..\FrivOSCIcon.ico
PrivilegesRequired=admin
CreateAppDir=no
Uninstallable=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableReadyMemo=yes
DisableFinishedPage=yes
DisableStartupPrompt=yes
MinVersion=10.0

; Inno is only a delivery shell here: it unpacks the payload and immediately
; hands over to FrivOSC-Setup.ps1, which is the wizard the user actually
; sees. Every page above is disabled so the two never appear at once.
[Files]
Source: "..\FrivOSC-Launcher.ps1";  DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSC-Setup.ps1";     DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSC-Setup.vbs";     DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSC-Uninstall.ps1"; DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSC.Ui.psm1";       DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSC.png";           DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSCHost.exe";       DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSCIcon.ico";       DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\FrivOSCSetupHost.exe";  DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\Install-FrivOSC.ps1";   DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
; Install-FrivOSC.ps1 and the service both read this.
Source: "..\VERSION";              DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\LICENSE";               DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\README.md";             DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\Uninstall-FrivOSC.vbs"; DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\frivosc_service.py";    DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall
Source: "..\requirements.txt";      DestDir: "{tmp}\FrivOSCSetupPayload"; Flags: ignoreversion deleteafterinstall

[Run]
Filename: "{tmp}\FrivOSCSetupPayload\FrivOSCSetupHost.exe"; Parameters: "--script ""{tmp}\FrivOSCSetupPayload\FrivOSC-Setup.ps1"""; Flags: waituntilterminated hidewizard 64bit

[Code]
function PostMessage(hWnd: HWND; Msg, wParam, lParam: Longint): Boolean;
  external 'PostMessageW@user32.dll stdcall';

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpReady then
  begin
    WizardForm.Hide;
    PostMessage(WizardForm.NextButton.Handle, $00F5, 0, 0);
  end;
end;
