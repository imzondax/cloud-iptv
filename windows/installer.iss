; Compile through scripts\build_windows_installer.bat, which builds the app
; and passes the version from pubspec.yaml.
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6F0C1E52-8B7A-4D3E-9A41-2C5D7E8F1B30}
AppName=Cloud IPTV
AppVersion={#AppVersion}
AppPublisher=Cloud IPTV
DefaultDirName={autopf}\Cloud IPTV
DefaultGroupName=Cloud IPTV
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=CloudIPTV_Setup
SetupIconFile=runner\resources\app_icon.ico
WizardSmallImageFile=runner\resources\installer_small.bmp
; Tells Windows to drop cached icons, or updates keep showing the old one.
ChangesAssociations=yes
UninstallDisplayName=Cloud IPTV
UninstallDisplayIcon={app}\cloud_iptv.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Cloud IPTV"; Filename: "{app}\cloud_iptv.exe"
Name: "{autodesktop}\Cloud IPTV"; Filename: "{app}\cloud_iptv.exe"

[Run]
Filename: "{app}\cloud_iptv.exe"; Description: "Launch Cloud IPTV"; Flags: nowait postinstall skipifsilent
