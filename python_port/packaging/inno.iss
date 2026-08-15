; Inno Setup script for pLayout (Windows). Compile after `pyinstaller packaging\playout.spec`.
; Per-user install (no admin prompt), Start-menu entry, uninstaller, `.plate` association.

#define MyAppName "pLayout"
#ifndef MyAppVersion
#define MyAppVersion "1.4.0"
#endif
#define MyAppPublisher "nettilor"
#define MyAppExeName "pLayout.exe"

[Setup]
AppId={{7B0C4C56-2C4B-4E2A-9E38-3F1D6C7B9A21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=pLayout-{#MyAppVersion}-setup
SetupIconFile=..\playout\resources\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\pLayout\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; .plate -> pLayout (per-user; HKA resolves to HKCU for a lowest-privilege install)
Root: HKA; Subkey: "Software\Classes\.plate"; ValueType: string; ValueName: ""; ValueData: "pLayout.plate"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\pLayout.plate"; ValueType: string; ValueName: ""; ValueData: "Plate layout"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\pLayout.plate\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\pLayout.plate\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
