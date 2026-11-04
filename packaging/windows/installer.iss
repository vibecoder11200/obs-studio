; Inno Setup script for the fork's Windows installer (upstream-parity .exe).
; Compiled in CI against the unpacked cpack package tree:
;   iscc /DSourceDir=<unpacked zip> /DAppVersion=<version> installer.iss
; Registers the virtual camera DLLs silently (installer runs elevated) and
; offers an optional portable_mode task.

#define AppName "OBS Studio"
#define AppPublisher "obs-studio fork"
#ifndef AppVersion
#define AppVersion "0.0.0"
#endif
#ifndef SourceDir
#define SourceDir "."
#endif

; Stable AppId across versions (do not change between releases).
#define AppIdGuid "{{8A6C0F42-19DC-4B9B-9D31-70C67D1F4A2E}}"

[Setup]
AppId={#AppIdGuid}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\obs-studio
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Relative OutputDir resolves against SourceDir; CI passes an absolute
; SourceDir (the unpacked package), so the installer lands next to it and
; the workflow picks it up from there.
OutputDir={#SourceDir}
OutputBaseFilename=OBS-Studio-{#AppVersion}-Windows-x64-Installer
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\bin\64bit\obs64.exe
; The virtual camera DLLs and the installer's registry writes require admin.
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "portablemode"; Description: "Portable mode (keep settings and plugins inside the install folder)"; GroupDescription: "Install mode:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\bin\64bit\obs64.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\bin\64bit\obs64.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\bin\64bit\obs64.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; Register the virtual camera modules silently (both architectures). The
; 32-bit DLL must be registered by the 32-bit regsvr32 (SysWOW64) — a
; 64-bit regsvr32 cannot load it (ERROR_BAD_EXE_FORMAT).
Filename: "{sys}\regsvr32.exe"; Parameters: "/s ""{app}\core\win-dshow\data\lvc920x64.dll"""; StatusMsg: "Registering virtual camera (64-bit)..."; Flags: runhidden
Filename: "{syswow64}\regsvr32.exe"; Parameters: "/s ""{app}\core\win-dshow\data\lvc920x86.dll"""; StatusMsg: "Registering virtual camera (32-bit)..."; Flags: runhidden

[UninstallRun]
; Unregister in reverse order; errors ignored on purpose (partial installs).
Filename: "{syswow64}\regsvr32.exe"; Parameters: "/u /s ""{app}\core\win-dshow\data\lvc920x86.dll"""; Flags: runhidden; RunOnceId: "UnregX86"
Filename: "{sys}\regsvr32.exe"; Parameters: "/u /s ""{app}\core\win-dshow\data\lvc920x64.dll"""; Flags: runhidden; RunOnceId: "UnregX64"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
begin
	if CurStep = ssPostInstall then begin
		// OBS looks for the marker at BASE_PATH "../.." from bin\64bit,
		// i.e. the install root - not next to the binaries.
		if WizardIsTaskSelected('portablemode') then
			SaveStringToFile(ExpandConstant('{app}\portable_mode'), '', False);
	end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
	if CurUninstallStep = usPostUninstall then
		RegDeleteKeyIncludingSubkeys(HKEY_LOCAL_MACHINE, 'SOFTWARE\Logitech\Identity');
end;
