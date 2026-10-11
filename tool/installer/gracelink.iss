; Gracelink 的 Windows 安装向导（Inno Setup 7）
;
; 为什么要它（2026-10-09 用户）：市面上的软件双击后都有一串页面 —— 协议、选安装目录、
; 勾快捷方式；我们原来那版自研安装器（`tool/installer/installer.dart`）**一句话都不问**。
; 现在换成 Inno，向导就是用户要的那几步：
;
;   许可协议（必须点「我接受」）→ 选择安装位置 → 选择附加任务（桌面快捷方式 /
;   固定到任务栏）→ 安装进度 → 完成（可勾「运行 Gracelink」）
;
; 仍然保持那几条底线：
;   * **不要管理员权限**（`PrivilegesRequired=lowest`，装到 `%LOCALAPPDATA%\Programs\Gracelink`）；
;   * **一个文件分发**（Inno 把整个程序目录打进一个 exe）；
;   * **静默安装那条路照旧在**：`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`
;     （将来 App 内做「下载完自己装」时用这一组；现在 Windows 端的检查更新还是把
;     地址丢给浏览器，见 `lib/features/mine/app_update_flow.dart`）；
;   * 卸载走 Inno 自己的卸载器（`unins000.exe`）—— App 那边「关于」页的判定也认它
;     （`lib/core/platform/app_uninstaller.dart`），老自研安装器留下的 `uninstall.exe`
;     则作为旧版的兼容入口继续能卸。
;
; 编译（构建脚本 `tool/installer/build_installer.dart` 会自动把 ISCC 备好再调它）：
;   ISCC.exe /DAppVersion=1.0.0 /DReleaseDir=<绝对路径> gracelink.iss
;
; 目录约定：ReleaseDir 是 `flutter build windows --release` 的产物目录，
; 输出落在仓库的 `dist\Gracelink-Setup-<版本名>.exe`。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef ReleaseDir
  #define ReleaseDir "..\..\build\windows\x64\runner\Release"
#endif
#define AppName "Gracelink"
#define AppExe "gracelinkim.exe"

[Setup]
; AppId 是这个软件的**身份**：升级、修复、卸载都靠它认人。
; 换个值 = Windows 眼里换了一个软件（会并存两份），所以**别动它**。
; （老自研安装器手写的是卸载项 HKCU\...\Uninstall\Gracelink，升级时由 [Code] 清掉）
AppId={{7F1C2A64-9B3E-4E7A-9D2B-6F5A1C4E8B30}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Gracelink
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
; 不要开头那句「这将安装 Gracelink 到您的计算机，是否继续？」：双击就直接进协议页
; （跟市面上的软件一样；/SP- 那个参数就是用来关它的，这里干脆默认关掉）
DisableStartupPrompt=yes
; 不要「选择安装语言」那一页：系统是中文就用中文，否则用英文（见 [Languages] 那段）
ShowLanguageDialog=no
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
; 不要「选择开始菜单文件夹」那一页（现代安装包基本都省掉它）
DisableProgramGroupPage=yes
; 「选择安装位置」留着 —— 用户明确要的这一步
DisableDirPage=no
; 也不要「准备安装」那一页：选完附加任务上的按钮就是「安装」，少点一下
DisableReadyPage=yes
; 只要当前用户权限：装进用户目录，不弹 UAC（以后做静默升级才不会卡在提权框上）
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 向导左上角的图标 + 控制面板里显示的那个图标
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
; 协议页：必须选「我接受」才能继续。文件就在本目录，纯文本按 UTF-8 读。
; 这一行只是**兜底**：真正给哪份协议由 [Languages] 每条的 LicenseFile 决定
; （中文系统 → license.txt、别的系统 → license-en.txt）。
LicenseFile=license.txt
; 安装包自己「属性」里的版本/公司（以前那个自研 stub 没有这些字段）
VersionInfoVersion={#AppVersion}
VersionInfoCompany=Gracelink
VersionInfoDescription={#AppName} 安装程序
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
; 文件被占用时（老版本还开着）交给自己的 [Code] 去收摊，不用 Inno 的 Restart Manager
; —— 我们那个 ✕ 是「缩回托盘」，Restart Manager 的 WM_CLOSE 关不掉它，会卡在
; 「文件正在使用」那一页上。见 [Code] 里 ssInstall 那段 taskkill。
CloseApplications=no

[Languages]
; 英文排前面只是**兜底**：Inno 先拿系统语言精确匹配（中文 Windows → 简体中文），
; 匹配不上才用列表里第一个 —— 所以非中文系统上拿到的是英文，不是中文。
; 语言选择框关掉（见 [Setup] 里 ShowLanguageDialog=no）：双击直接进协议页。
;
; 协议也跟着语言走（[Languages] 的 LicenseFile 覆盖 [Setup] 那一行）：向导界面说什么
; 语言，协议页就是什么语言 —— 中文系统不会看到英文协议，反之亦然。两份正文是同一套
; 九节（英文那份末尾注明以中文为准）。
; 验：`verify_wizard.ps1` 加 `-Lang english` 就能在中文系统上看英文那份（/LANG= 是
; Inno 的官方参数，用它会顺带跳过语言选择框）。
Name: "english"; MessagesFile: "compiler:Default.isl"; LicenseFile: "license-en.txt"
Name: "chinesesimp"; MessagesFile: "languages\ChineseSimplified.isl"; LicenseFile: "license.txt"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
; 「固定到任务栏」是**尽最大努力**：Windows 10 上那条 shell 动词能用，
; Windows 11 上微软收紧了，可能没反应（见 [Code] 里 PinToTaskbar 的说明）。
Name: "taskbarpin"; Description: "固定到任务栏"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 程序本体 + data\（Flutter 运行时、语言包、图标都在里面）
; 排除编译中间产物：.exp / .lib / .pdb 是给链接器看的，用户机器上没用
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "*.exp,*.lib,*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 「程序」菜单里直接摆一条（不套 Gracelink\ 文件夹）——老自研安装器就是摆在外面的，
; 两条同名同目标，升级时正好覆盖掉旧的，开始菜单不会出现两个 Gracelink。
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; 装完勾「运行 Gracelink」（普通安装走这条）
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; 静默升级那一路也要把 App 拉回来：升级前它被我们关掉了，不拉回来用户会以为装挂了。
; （`NoSilentRelaunch` 只是给自动化验证用的开关：静默装一遍看文件对不对时别真把
;  App 拉起来 —— 构建脚本不用它。）
#ifndef NoSilentRelaunch
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: IsSilentMode
#endif

[UninstallDelete]
; 只清 Inno 装进去的东西之外的那几样（App 自己的聊天记录在 %APPDATA%，
; 不在这里，卸载不动它）：
; * data\ 里会有运行时落下的东西；
; * *.lib / *.exp / *.pdb 是老自研安装器那版留在目录里的（它把整个 Release 目录
;   压进去了，我们这版不装这些）；
; 不整目录删掉：万一用户把安装目录选在了一个本来就有别的东西的地方，
; 「卸载 = 删掉整个 {app}」会连累别人。
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.lib"
Type: files; Name: "{app}\*.exp"
Type: files; Name: "{app}\*.pdb"

[Code]
const
  // 老自研安装器留下的卸载项（`tool/installer/installer.dart` 写的那个键）
  LegacyUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\Gracelink';

function IsSilentMode: Boolean;
begin
  Result := WizardSilent;
end;

{ 关掉正在运行的 App。
  为什么必须自己动手：我们那个 ✕ 是「缩回托盘」（窗口 SW_HIDE），Restart Manager
  发 WM_CLOSE 关不掉它 —— 文件还占着，安装会停在「文件正在使用」。这里直接
  taskkill（老自研安装器也是这么干的），/T 连它拉起的子进程一起收掉。 }
procedure KillRunningApp;
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/IM {#AppExe} /F /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(600);
end;

{ 固定到任务栏：走 shell 那条（未公开的）动词 `taskbarpin`。
  * Windows 10：一般能成；
  * Windows 11：微软把这条收紧了，可能不起作用 —— 所以它是**勾选项**，
    失败也不报错、不影响安装（这个动词返回的成功与否本身也不可靠）。 }
procedure PinToTaskbar;
var
  ResultCode: Integer;
begin
  ShellExec('taskbarpin', ExpandConstant('{app}\{#AppExe}'), '', '', SW_SHOWNORMAL,
    ewNoWait, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    KillRunningApp;
    { 从老自研安装器升级过来的：把它的卸载项和 uninstall.exe 清掉，
      免得控制面板里出现两个 Gracelink }
    if RegKeyExists(HKCU, LegacyUninstallKey) then
      RegDeleteKeyIncludingSubkeys(HKCU, LegacyUninstallKey);
    DeleteFile(ExpandConstant('{app}\uninstall.exe'));
    { 开始菜单那条：旧的（老自研安装器建的）先删掉，[Icons] 里会照原样重建一条，
      免得旧的留着指向已经不在的位置 }
    DeleteFile(ExpandConstant('{userprograms}\{#AppName}.lnk'));
  end;
  { 「固定到任务栏」勾了才做（文件都铺完了，快捷方式也已经在了） }
  if CurStep = ssPostInstall then
  begin
    if WizardIsTaskSelected('taskbarpin') then
      PinToTaskbar;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { 卸载前也要先把 App 关掉：它开着的话删除会失败（它还把 DLL 占着） }
  if CurUninstallStep = usUninstall then
    KillRunningApp;
end;
