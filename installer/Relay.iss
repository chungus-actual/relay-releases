#ifndef AppVersion
  #error AppVersion must be supplied by Build.ps1
#endif
#ifndef PublishDir
  #error PublishDir must be supplied by Build.ps1
#endif
#ifndef Bootstrapper
  #error Bootstrapper must be supplied by Build.ps1
#endif

[Setup]
AppId={{F35259AB-5848-4623-B12E-2B74B2A4DE73}
AppName=Relay
AppVersion={#AppVersion}
AppPublisher=chungus-actual
AppPublisherURL=https://github.com/chungus-actual/relay
DefaultDirName={localappdata}\Programs\Relay
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
AppMutex=Local\Relay.Personal
CloseApplications=no
RestartApplications=no
SetupIconFile=..\Assets\Relay.ico
UninstallDisplayIcon={app}\Relay.exe
OutputBaseFilename=Relay-{#AppVersion}-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
VersionInfoVersion={#AppVersion}

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Bootstrapper}"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\Relay"; Filename: "{app}\Relay.exe"; WorkingDir: "{app}"; AppUserModelID: "Relay.Personal"
Name: "{autodesktop}\Relay"; Filename: "{app}\Relay.exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "Relay.Personal"

[Run]
Filename: "{app}\Relay.exe"; Description: "Open Relay"; Flags: nowait postinstall skipifsilent

[Code]
const
  RuntimeKey = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function HasRuntimeAt(Root: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(Root, RuntimeKey, 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0');
end;

function HasRuntime: Boolean;
begin
  Result := HasRuntimeAt(HKCU32) or HasRuntimeAt(HKCU64) or HasRuntimeAt(HKLM32) or HasRuntimeAt(HKLM64);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  if not HasRuntime then begin
    ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
    if not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
      Result := 'Could not start Microsoft WebView2 setup. Check your connection and try again.'
    else if (ExitCode <> 0) and (ExitCode <> 3010) then
      Result := 'Microsoft WebView2 setup failed. Check your connection and try again.'
    else if not HasRuntime then
      Result := 'Microsoft WebView2 Runtime is required. Install it from Microsoft and run Relay setup again.';
    if (Result = '') and (ExitCode = 3010) then NeedsRestart := True;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command: String;
begin
  if CurUninstallStep = usUninstall then
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Relay', Command) then
      if CompareText(Command, '"' + ExpandConstant('{app}\Relay.exe') + '" --startup') = 0 then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Relay');
  { Profiles and settings under LocalAppData\Relay are deliberately retained. }
end;
