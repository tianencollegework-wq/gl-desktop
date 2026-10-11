# Windows 发版：版本号、安装包与代码签名

这份文档管三件事：**版本号怎么定**、**安装包怎么打**（Inno Setup 向导）、
**怎么签**。都只跟「把 `Gracelink-Setup-x.y.z.exe` 交到别人手上」这一步有关，
跟日常开发无关。

---

## 一、版本号规范

### 真源头只有一个

```
pubspec.yaml:   version: 1.0.0+261008
                └─版本名─┘ └内部号┘
```

从它派生出去的东西**不要再手改**：

| 派生物 | 谁在用 |
|---|---|
| 安装包文件名 `Gracelink-Setup-1.0.0.exe` | `tool/installer/build_installer.dart` |
| 程序本体资源里的版本（`1.0.0+261008`） | Flutter 的 CMake 把 `version:` 原样递给 runner（`FLUTTER_VERSION` 宏） |
| 「关于」页 / 设置页的版本名 | `lib/core/config/app_info.dart`、`lib/domain/mine/profile_form.dart`（**兜底常量**，见下） |
| 检查更新比大小用的内部号 | Windows runner 的 `gracelinkim/app_info` 通道 → `AppVersionInfo.code` |
| 服务端 `update.json` 里的 `version` / `code` | 用户手改，**发版时记得同步** |

Dart 里那两处常量是「读不到本机版本时的兜底」（单测、老 runner）。它们**不是**
第二个源头：`tool/release/bump_version.dart` 负责让它们跟着 pubspec 走，
`test/release/version_consistency_test.dart` 负责在漂了的时候报红。

### 版本名 `X.Y.Z`

* `Z`（patch）：修 bug、改文案这种不发新功能的；
* `Y`（minor）：加功能（用户能察觉的）；
* `X`（major）：不兼容或大改版。

对外的所有显示（关于页、更新弹窗）用的都是它。

### 内部号 `YYMMDD`

* 就是**发版那天**：`261008` = 2026-10-08；
* **只增不减**：安卓不允许装 `versionCode` 更小的包，服务端清单也是拿它比大小；
* 同一天要再发一版 → 内部号 `+1`（`261009` → `261010`），仍然单调；
* 永远是 **6 位**（`YYMMDD`），工具会校验。

> 为什么不是「1、2、3……递增」：线上清单里现在就是 `261008` 这一套，
> 换编号体系会让「已装 261008 的用户」看到一个永远存在的更新提示，
> 安卓那边更糟（装不上）。

### 怎么升版

```bash
# 发版前自查：pubspec / Dart 常量 / CHANGELOG 三处是否一致
dart run tool/release/bump_version.dart --check

# 收一个补丁版（内部号自动改成今天；同一天再发自动 +1）
dart run tool/release/bump_version.dart --bump patch --note "修了登录页弹窗字号"

# 同一天第二次打包 / 重发
dart run tool/release/bump_version.dart --build

# 明确指定（改大版本、或内部号要压一个值）
dart run tool/release/bump_version.dart --set 1.1.0 --code 261015
```

一次改四处：`pubspec.yaml`、`lib/core/config/app_info.dart`、
`lib/domain/mine/profile_form.dart`、`CHANGELOG.md`（顶部加一条，标题行的格式由
`--check` 校验，别手改）。

### 一个已知的 Windows 元数据细节

Win32 的 `VERSIONINFO` 里，**数值版本的第 4 段是 16 位**（最大 65535），而我们的
内部号是 6 位（`261008`）—— 于是图形界面看到的数值版本是 `1.0.0.64400`
（`261008 % 65536`）。**这是截断，不影响任何功能**：

* 属性页显示、程序自己读的，都是**字符串**那两栏（`1.0.0+261008`），用户看到的是对的；
* 「检查更新」比的是清单里的 `code` 与 runner 报的内部号（都是完整整数）。

不改的理由：把内部号压进 16 位就得换编号体系，代价见上面那条注。

---

## 二、安装包长什么样（Inno Setup）

安装包由 **Inno Setup** 编译：脚本 `tool/installer/gracelink.iss`，构建脚本
`tool/installer/build_installer.dart` 负责把编译器备好、把 .iss 跑起来。

双击后是**标准向导**（2026-10-09 用户要的）：许可协议（必须点「我接受」，文案在
`tool/installer/license.txt`（中文）/ `license-en.txt`（英文），改字只改这两个 txt）→
选择安装位置 → 选择附加任务（桌面快捷方式 / 固定到任务栏）→ 安装 → 完成
（可勾「运行 Gracelink」）。

**协议正文只写这套软件实际是什么**（2026-10-10 重写过一次）：Gracelink（恩信）是
**官方服务的 Windows 客户端** —— 装完连我们的服务器、用 Gracelink 账号登录，
**不是自托管**，所以别再写「本软件免费提供」以外的价钱承诺、也别写成「由您自行
搭建服务器 / 自建才有数据」那一套（那是上游 Raingad-IM 的卖点，不是我们的）。
九节：软件说明（含真实功能清单：单聊群聊、通讯录、群组、一对一/群组音视频、扫码
登录、「发现」里的资讯与灵听）、许可、账号与安全、使用规范、数据与隐私（聊天记录在
本机 `%APPDATA%`、卸载不删、消息经服务器投递）、第三方组件（Flutter 等开源件）、
免责（含「别拿它当应急救援用途」）、更新与变更、其他。改文案就改这两个 txt，
重新 `build_installer.dart` 一遍即可。

**协议跟着语言走**（2026-10-10 加的）：`[Setup] LicenseFile` 只是兜底，真正用哪份
由 `[Languages]` 每条自己的 `LicenseFile` 决定（Inno 支持这个参数）—— 中文 Windows
看到 `license.txt`，别的系统看到 `license-en.txt`，不会出现「英文界面配中文协议」。
英文那份是逐节直译，末尾注一句「以中文为准」。验办法：在中文机器上给向导加
`/LANG=english`（Inno 官方参数，顺带跳过语言选择框），见第二节的 `-Lang english`。

几条已经定下来的东西：

* **装到 `%LOCALAPPDATA%\Programs\Gracelink`、不要管理员权限**
  （`PrivilegesRequired=lowest`）—— 跟老版安装位置一致，以后做「App 自己静默装更新」
  也不会卡在 UAC 上；安装目录那一页还在，用户想改就改；
* **升级不用先卸**：同一个 `AppId` 覆盖安装；老自研安装器那版（`uninstall.exe` +
  它手写的卸载项 + 开始菜单那条）会被自动清掉，所以「设置 → 应用」和开始菜单里
  不会出现两个 Gracelink；
* **静默那条路还在**（将来 App 内自己装更新时用）：

  ```bash
  Gracelink-Setup-1.0.0.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="D:\setup.log"
  ```

  静默装完会把 App 拉回来（`[Run]` 里那条 `Check: IsSilentMode`：升级前它被安装器
  关掉了，不拉回来用户会以为装挂了）；
* **卸载程序叫 `unins000.exe`**，装完就登记在「设置 → 应用」里，卸载时会把
  `data\` 与老版留下的编译中间产物一并清掉；App 里「关于 → 卸载恩信」认它
  （认不到再回落到老名字 `uninstall.exe`，那是存量用户的）；
* 卸载**不动用户数据**：聊天记录/登录态在 `%APPDATA%`，卸载不碰（与
  「卸载后可以重新安装，登录状态与聊天记录会保留」那句提示一致）。

### 不用点也能验一遍向导

打完之后想看一眼「协议 / 目录 / 附加任务」三页是不是都在、中英文有没有乱码，不用手点：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tool\installer\verify_wizard.ps1 dist\Gracelink-Setup-1.0.0.exe
# 中文机器上验英文那份（/LANG=english）：
#   ... -File tool\installer\verify_wizard.ps1 dist\Gracelink-Setup-1.0.0.exe -Lang english
```

它把安装包拉开（`/DIR` 指到 `%TEMP%\gracelink-wizard-check\dest`，**每次先删掉**——
目录已存在的话 Inno 会先弹「文件夹已存在」那个确认框，把后面的按键吃掉），
按 Alt+A / Alt+N 走到「附加任务」那一页，把每页的**标题**与控件、协议正文读出来写到
`%TEMP%\gracelink-wizard-check\wizard-check.txt`，然后关掉向导 —— **不会装任何东西**。
（附加任务页上那两个勾选项是 Inno 自画控件、UIA 读不到文字，那页只能看到标题；
勾选项本身靠 `[Tasks]` 与静默安装里的 `/TASKS` 验。）

两个 2026-10-10 踩出来的坑，写在脚本头部：

* 自画的控件在 UIA 里只是**没有模式的 Pane**（连「我接受」那个单选都点不动），
  只能靠按键；
* `SendKeys` 走的是系统输入队列，落到当时的前台窗口上 —— 机器上别的软件（一个聊天
  客户端）一弹窗，Alt+A 就全进了人家那里，向导一动不动。现在改成把
  `WM_SYSKEYDOWN/UP`（lParam 里带 Alt 上下文）**直接 Post 给向导窗口**，不用抢前台。
  页面状态只有标题能读，所以脚本只判「标题变了没」，具体是哪一页写进 dump 里给人看。

### Inno Setup 从哪来（不用你手工装）

`build_installer.dart` 找不到编译器时会从 GitHub 下一份**官方安装器**，用
`/PORTABLE=1` 就地解到 `build\installer\inno\`（不写注册表、不进「应用」列表），
版本钉在这个脚本顶部的 `innoVersion`（现在是 7.1.0）。缓存没了就自动再下一次。
想用自己装的那份（Inno Setup IDE 里编、或机器上本来就有）：

```bash
set GRACELINK_ISCC=C:\Program Files\Inno Setup 7\ISCC.exe
```

> **许可那件事（要你拍板）**：Inno Setup 的 `LICENSE.TXT` 明说允许商用
> （"Permission is granted to anyone to use this software for any purpose, including
> commercial applications"），但作者**请求**商用用户买一份许可
> （<https://jrsoftware.org/isorder.php>，一次性、按人数分档），7.x 的编译器还会在
> 输出里印一行 "Non-commercial use only"。买不买是公司的决定，不买也用得了；
> 想完全避开这一摊就换 NSIS（zlib 许可、随便商用，代价是脚本要重写一遍、界面
> 没有 Inno 现代）。

---

## 三、代码签名

### 为什么

没签名的包，别人双击时 Windows 会拦一句「**未知发布者**」—— 那不是 bug，是
SmartScreen 对「没有任何品牌背书」的包的态度。签过名之后，同一位置显示的是证书上的
公司名（`Gracelink`），属性页的「数字签名」也会多一条。

**签名 ≠ 从此不被拦**：SmartScreen 另有一套「这个应用下载得够不够多」的信誉机制，
新证书要攒一段时间。签名的确定性收益是**有身份、可追责、内容未被篡改**。

### 流水线怎么跑（已经接好了）

```bash
# 1) 证书三条路，给一条就行（环境变量，别写进仓库）

#    ① .pfx 文件 + 口令（最常见）
set GRACELINK_SIGN_PFX=D:\secrets\gracelink.pfx
set GRACELINK_SIGN_PFX_PASSWORD=...

#    ② 证书装在证书库里：给指纹（硬件令牌插着时也走这条）
set GRACELINK_SIGN_CERT_SHA1=0123456789ABCDEF...

#    ③ 云签名服务（Azure Artifact Signing / DigiCert KeyLocker 那种）：
#       给一条包装命令，{file} 会被换成待签文件
set GRACELINK_SIGN_COMMAND=D:\tools\sign-with-cloud.cmd {file}

# 2) 照常打包 —— 脚本会先签程序本体、再签安装包，并打印验签结果
flutter build windows --release
dart run tool/installer/build_installer.dart

# 3) 对外发布那次，打开严格模式：验签不过就报错，别把残次品发出去
set GRACELINK_SIGN_STRICT=1
```

* 没配证书 → 脚本打印「这个包是**未签名**的」并继续（内测包需要这样）；
* 配了证书但签名失败 → **构建失败**（不许静悄悄发出一个没签上的包）；
* 时间戳默认打 `http://timestamp.digicert.com`（可用 `GRACELINK_SIGN_TIMESTAMP_URL`
  换）。**必须打时间戳**：不打的话证书一过期，所有已发出的旧包签名一起失效。

核验（拿真证书时应该 `Status: Valid`）：

```powershell
Get-AuthenticodeSignature dist\Gracelink-Setup-1.0.0.exe |
  Select-Object Status, SignerCertificate, TimeStamperCertificate
```

### 证书从哪来（2026 年的现实）

先说结论：**我们没有证书，这一件事只能你去办**。流水线已经通到「插上证书就能签」，
用自签证书端到端验过一遍（步骤见最后一节）。

**关键约束**：自 2023-06-01 起，OV 和 EV 一样，私钥**不能**以普通文件形态长期保存
—— 必须是硬件令牌 / HSM，或者走 CA 自己的**云签名服务**。所以「买张证书丢进 CI」
这条路基本没了，要么插令牌，要么用云签。

三条现实的路（价格是 2026 年的公开行情，买之前自己再核一遍）：

| 路 | 大致花费 | 适合谁 | 注意 |
|---|---|---|---|
| **CA 的 OV 证书**（沃通 / GlobalSign / DigiCert / Sectigo 等，或国内代理） | **约 ¥1200–3600/年**（Certum 那档最便宜，GlobalSign 约 ¥2000，沃通 2026 年报到 ¥3588） | 公司在中国内地注册、要正规发票 | 需要营业执照等资料，1–3 天签发；**私钥在硬件令牌里**（有些品牌另收 ¥800/个），换机器要带着令牌 |
| **CA 的云签名服务**（例如 Certum 的云签、SSL.com 的 eSigner，约 $249/年起） | 依品牌而定 | 想让 CI / 脚本无人值守签名 | 免令牌；密钥在 CA 那边，签名走它给的命令行工具（正好用 `GRACELINK_SIGN_COMMAND`） |
| **Azure Artifact Signing**（原 Trusted Signing，约 **$9.99/月** Basic） | 最低 | 公司在**美国 / 加拿大 / 欧盟 / 英国 / 澳大利亚**注册 | Public Trust 目前只对上面这些地区的组织开放（2026 年仍如此）；中国内地注册的公司走不了这条路；需要过身份验证，组织成立年限也有要求 |

> 旧名与新名：微软 2026 年把它从 *Trusted Signing* 改叫 **Artifact Signing**，
> 功能没变。搜索时两个名字都试试。

**签名之后做的事**：把证书主体名（公司名）与 `windows/runner/Runner.rc` 里的
`CompanyName` 对齐（用户在两处都会看到），然后按上面第 2 步走一遍。

### 我们现在的状态（照实记）

* 流水线：**已实现并测过**（`test/release/signing_test.dart` 钉参数拼装；
  `build_installer.dart` 里签两次 + 验签）；
* 证书：**还没有** → 现在打出来的包是未签名的，别人双击会看到「未知发布者」；
* 端到端「签名全绿（`Status: Valid`）」那条路**没在真证书上验过**（没证书），
  验过的是「签名确实写进文件、验签输出看得懂、自签证书的失败原因符合预期」。

---

## 四、发版清单（照着做）

1. `dart run tool/release/bump_version.dart --bump patch --note "…"` —— 升版 + 记一笔；
2. 改服务端 `update.json`：`windows` 那格的 `version` / `code` / `url` 与新版对齐
   （**这条最容易忘**，忘了用户永远收不到更新提示）；
3. `flutter analyze` 干净、`flutter test` 全过；
4. `flutter build windows --release`；
5. `dart run tool/installer/build_installer.dart`（配好证书 + `GRACELINK_SIGN_STRICT=1`）；
6. 核验签名（上面那行 PowerShell）；
7. **装上跑一遍**：双击 → 向导（协议 → 安装目录 → 附加任务）→ 勾「运行 Gracelink」
   → 登录页确认版本号、扫码登录能出二维码；（动手之前想先看一眼，用
   `tool/installer/verify_wizard.ps1`，见第二节）
8. 把 `dist\Gracelink-Setup-x.y.z.exe` 发给用户 / 传到下载页。

---

## 五、附：用自签证书把流水线验一遍（不用于对外发布）

```powershell
# 建一张自签的代码签名证书（当前用户证书库，不需要管理员）
$cert = New-SelfSignedCertificate -Type CodeSigningCert `
  -Subject "CN=Gracelink Self-test" -FriendlyName "Gracelink 自签测试" `
  -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable

# 导出成 .pfx（口令随便给一个，只在本机临时用）
$pw = ConvertTo-SecureString -String "test-only" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath D:\build\gracelink-test.pfx -Password $pw

# 用完把证书从证书库里删掉（.pfx 也删掉，别留在机器上）
Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)"
```

```bash
GRACELINK_SIGN_PFX=D:\\build\\gracelink-test.pfx \
GRACELINK_SIGN_PFX_PASSWORD=test-only \
dart run tool/installer/build_installer.dart
```

预期输出：`代码签名：.pfx 证书文件`、两次「签好了」、以及一句
「签名已写进文件，但验签没全绿：…」—— 自签证书**必然**验不过（信任链回不到
受信任的根），这正是 `GRACELINK_SIGN_STRICT=1` 只在公开发布那次开的原因。
