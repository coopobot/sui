; ---------------------------------------------------------------------------
; 随手记 Sui —— Windows x64 安装包（Inno Setup 6.3+）
;
; 版本号**不写死**：必须由编译命令注入，避免与版本真源（pubspec.yaml）漂移——
;   ISCC.exe /DMyAppVersion=<x.y.z> clients\flutter_app\installer\sui.iss
; 便捷入口（自动同步 / 校验 / 构建 / 取版本 / 打印 SHA256）：
;   SuiDevAgent scripts/build_windows_installer.ps1
;
; 设计见 SuiDevAgent technology/design/low-level-design/windows-packaging.md（决策 ADR-018）
; 载荷来源：..\build\windows\x64\runner\Release\（flutter build windows --release 的产物整目录）
; 产物输出：..\dist\sui-setup-<版本>-x64.exe（dist/ 已在 .gitignore 中）
; ---------------------------------------------------------------------------

#ifndef MyAppVersion
  #error 缺少版本号：请用 ISCC /DMyAppVersion=<x.y.z> 编译。版本真源 = clients/flutter_app/pubspec.yaml 的 version 字段，可用 scripts/version.sh show 查看。
#endif

#define MyAppName      "随手记 Sui"
#define MyAppPublisher "com.sui"
#define MyAppExeName   "sui_flutter_app.exe"
#define ReleaseDir     "..\build\windows\x64\runner\Release"
#define DistDir        "..\dist"

[Setup]
; AppId 定稿后**不可修改**：升级安装靠它识别同一产品（生成于 2026-10-08）
AppId={{2C5737ED-D110-4516-B088-CACBA1300D9A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Sui
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName} {#MyAppVersion}
UninstallDisplayIcon={app}\{#MyAppExeName}
; x64compatible 需要 Inno Setup >= 6.3（更早版本请改用 x64）
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
MinVersion=10.0
OutputDir={#DistDir}
OutputBaseFilename=sui-setup-{#MyAppVersion}-x64
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 升级安装时用 Restart Manager 检测被占用的文件，避免安装失败
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; 中文向导不是 Inno 官方自带（属社区非官方翻译）：需把 ChineseSimplified.isl 放入
; Inno 安装目录的 Languages\ 后取消下一行注释。
; Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 整个 Release 目录（exe + flutter_windows.dll + 插件 DLL + data/）递归装入安装目录
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; 用户数据（%APPDATA%\com.sui\Sui\sui\sui.sqlite）**不删除**：卸载保留笔记，避免误删。
; 用户数据目录不在本安装器管理范围内，故不使用 [UninstallDelete]。

[Code]
// 目标机缺少 VC++ 2015-2022 x64 运行库时给出提示（可继续安装）。
// 依据：flutter build windows 产物依赖 MSVCP140.dll / VCRUNTIME140.dll / VCRUNTIME140_1.dll。
function VCRedistInstalled: Boolean;
var
  Installed: Cardinal;
begin
  Result :=
    RegQueryDWordValue(HKEY_LOCAL_MACHINE,
      'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) and
    (Installed = 1);
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  if not VCRedistInstalled then
  begin
    MsgBox('未检测到 Microsoft Visual C++ 2015-2022 运行库（x64）。' + #13#10 + #13#10 +
           '「随手记 Sui」依赖 MSVCP140.dll / VCRUNTIME140.dll，缺少该运行库将无法启动。' + #13#10 +
           '可继续安装，但请先安装 VC++ 运行库（vc_redist.x64.exe）后再启动程序。',
           mbInformation, MB_OK);
  end;
end;
