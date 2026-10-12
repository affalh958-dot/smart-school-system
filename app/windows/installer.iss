; سكربت إنشاء مثبّت ويندوز (Inno Setup) لنظام إدارة المدرسة الذكي.
; يُجمّع إلى SmartSchool-Setup.exe داخل GitHub Actions.

#define AppName "نظام إدارة المدرسة الذكي"
#define AppNameEn "Smart School System"
#define AppVersion "1.0.2"
#define AppExe "school_app.exe"

[Setup]
AppId={{8F3C2B10-9D4A-4E77-9E1B-5A6C7D8E9F01}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Smart School System
DefaultDirName={autopf}\SmartSchool
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
OutputDir=..\dist
OutputBaseFilename=SmartSchool-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; كامل مجلد الإخراج (exe + dll + data + مكتبات VC++ المحزومة محلياً).
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
