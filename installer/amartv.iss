; AmarTv Windows installer (Inno Setup 6). Built by scripts\build_usb_kit.ps1.
; - Installs for the current user only: no admin rights, no UAC prompt.
; - If a config.json sits next to AmarTv-Setup.exe (e.g. on the USB stick),
;   it is copied in, so the app starts already configured.
; - Data (favorites, settings) lives in the install folder and survives updates.

#define AppVersion GetEnv("AMARTV_VERSION")
#if AppVersion == ""
  #define AppVersion "1.1.0"
#endif

[Setup]
AppId={{6C3F8E2A-7B41-4E1D-9A55-2D8C1F0B7A31}
AppName=AmarTv
AppVersion={#AppVersion}
AppPublisher=Amar
DefaultDirName={localappdata}\Programs\AmarTv
DefaultGroupName=AmarTv
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=AmarTv-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\AmarTv.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Asks to close AmarTv if it is running during an update.
AppMutex=AmarTv.SingleInstance

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: checkedonce

[Files]
Source: "..\dist\AmarTv\*"; DestDir: "{app}"; Excludes: "Start AmarTv.bat"; Flags: recursesubdirs ignoreversion
Source: "{src}\config.json"; DestDir: "{app}"; Flags: external skipifsourcedoesntexist onlyifdoesntexist

[Icons]
Name: "{group}\AmarTv"; Filename: "{app}\AmarTv.exe"
Name: "{autodesktop}\AmarTv"; Filename: "{app}\AmarTv.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\AmarTv.exe"; Description: "Start AmarTv now"; Flags: nowait postinstall skipifsilent
