; GetterX installer for Windows (Inno Setup 6).
; One installer, two choices on the first page:
;   * Install  - normal installation (Start menu, uninstaller, per-user or all users)
;   * Portable - just extracts GetterX into a folder you choose; settings and
;                downloads stay in that folder, nothing is written to the registry.
;
; Build: ISCC.exe /DAppVersion=1.2.3 /DSourceDir=..\..\build\windows\x64\runner\Release getterx.iss
; Silent update (used by GetterX itself): GetterX-windows-x64-setup.exe /VERYSILENT /RELAUNCH=1
; Silent portable: /VERYSILENT /PORTABLE=1 /DIR="D:\Apps\GetterX"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6E4B8C2A-6C7B-4C58-9D3E-2B7F0A9E5C11}
AppName=GetterX
AppVersion={#AppVersion}
AppVerName=GetterX {#AppVersion}
AppPublisher=GetterX
AppPublisherURL=https://github.com/gmwester/GetterX
AppSupportURL=https://github.com/gmwester/GetterX/issues
AppUpdatesURL=https://github.com/gmwester/GetterX/releases
DefaultDirName={autopf}\GetterX
DefaultGroupName=GetterX
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
OutputBaseFilename=GetterX-windows-{#Arch}-setup
OutputDir=..\..\dist
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\getterx.exe
CloseApplications=yes
RestartApplications=no
Uninstallable=not IsPortable
CreateUninstallRegKey=not IsPortable
UsePreviousAppDir=yes
LicenseFile=..\..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "portable.txt"; DestDir: "{app}"; Check: IsPortable; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\GetterX"; Filename: "{app}\getterx.exe"; Check: not IsPortable
Name: "{autodesktop}\GetterX"; Filename: "{app}\getterx.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\getterx.exe"; Description: "{cm:LaunchProgram,GetterX}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\getterx.exe"; Flags: nowait; Check: ShouldRelaunch

[UninstallRun]
Filename: "schtasks.exe"; Parameters: "/Delete /F /TN ""GetterX Check"""; Flags: runhidden; RunOnceId: "RemoveTask"

[Code]
var
  ModePage: TInputOptionWizardPage;
  PortableFromCmd: Boolean;

function IsPortable: Boolean;
begin
  if PortableFromCmd then
    Result := True
  else if ModePage <> nil then
    Result := ModePage.SelectedValueIndex = 1
  else
    Result := False;
end;

function ShouldRelaunch: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;

procedure InitializeWizard;
begin
  PortableFromCmd := ExpandConstant('{param:PORTABLE|0}') = '1';
  ModePage := CreateInputOptionPage(wpLicense,
    'Installation type', 'How do you want to use GetterX?',
    'Choose Install for a normal installation, or Portable to keep GetterX, its settings and downloads together in one folder (e.g. on a USB drive).',
    True, False);
  ModePage.Add('Install (Start menu entry, uninstaller, automatic updates via installer)');
  ModePage.Add('Portable (extract to a folder; nothing written to the registry or AppData)');
  if PortableFromCmd then
    ModePage.SelectedValueIndex := 1
  else
    ModePage.SelectedValueIndex := 0;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = ModePage.ID) then
  begin
    if IsPortable then
      WizardForm.DirEdit.Text := ExpandConstant('{userdocs}\GetterX Portable')
    else
      WizardForm.DirEdit.Text := ExpandConstant('{autopf}\GetterX');
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  // Updates of an existing installation go straight through.
  if (PageID = ModePage.ID) and PortableFromCmd then
    Result := True;
end;
