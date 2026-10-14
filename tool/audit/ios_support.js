// 列出每个依赖「在 iOS 上到底有没有原生实现」，顺便读出它要求的最低 iOS 版本。
//
// 为什么需要这个（与 tool/audit/macos_support.js 同一件事，只是换个平台）：
// iOS 版**本机编不出来**（开发机是 Windows），所以「哪个功能在 iPhone 上会静默消失」
// 这件事只能靠读依赖自己声明的平台来答 —— `flutter build ios` 只会把「声明了 ios
// 平台」的插件链进去，没声明的那些调用会在运行时抛 MissingPluginException，
// 而我们自己的 Dart 封装大多把它吞掉（功能就没了，还不报错）。
//
// 第二件事更值钱：**最低 iOS 版本**。Xcode 的 IPHONEOS_DEPLOYMENT_TARGET 必须
// ≥ 所有插件的下限，否则 CI 上第一条错误就是「xxx requires a higher minimum
// deployment target」—— 而那要等到 GitHub 上跑一次才知道。这里在本机就能算出来。
//
// 用法：node tool/audit/ios_support.js [pub-cache 路径]
//   只读 pubspec.lock 与 pub 缓存，不改任何东西。

const fs = require('fs');
const path = require('path');

const cache =
  process.argv[2] ||
  path.join(
    process.env.LOCALAPPDATA || '',
    'Pub',
    'Cache',
    'hosted',
    'pub.dev',
  );

// pubspec.lock 的每个依赖是一块：`  <名字>:` 开头，到下一块之前
const lock = fs.readFileSync('pubspec.lock', 'utf8');
const body = lock.slice(lock.indexOf('packages:') + 'packages:'.length || 0);
const blocks = body
  .split(/\n(?= {2}[a-z0-9_]+:\n)/)
  .map((text) => {
    const name = (text.match(/^ {2}([a-z0-9_]+):/) || [])[1];
    const version = (text.match(/ {4}version: "([^"]+)"/) || [])[1];
    const kind = (text.match(/ {4}dependency: "?([^"\n]+)"?/) || [])[1];
    return { name, version, kind };
  })
  .filter((entry) => entry.name && entry.version);

// 分平台实现的名字里带平台后缀（`_android` / `_windows` / `_macos` / `_ios`）：
// 它们「没有 ios」是正常的，iOS 那份叫 `_ios` 或走 darwin 共享源码。
const PLATFORM_SUFFIX = /_(android|ios|linux|windows|web|macos|ohos)$/;

/// 从 podspec（CocoaPods）或 Package.swift（SPM）里读它要求的最低 iOS 版本。
///
/// 两种都要看：Flutter 3.44 起插件可以只发 SPM 包（仓库里 `ios/` 下只有
/// Package.swift），只找 podspec 会把它们误报成「没有实现」。
function minimumIos(dir) {
  const iosDir = path.join(dir, 'ios');
  const darwinDir = path.join(dir, 'darwin');
  const found = [];

  const readIf = (file) => {
    try {
      return fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
    } catch (_) {
      return null;
    }
  };

  for (const base of [iosDir, darwinDir]) {
    if (!fs.existsSync(base)) continue;
    for (const entry of fs.readdirSync(base)) {
      // ① podspec：`s.platform = :ios, '13.0'` / `s.platforms = { :ios => '12.0' }`
      if (entry.endsWith('.podspec')) {
        const text = readIf(path.join(base, entry));
        if (!text) continue;
        // podspec 里最低版本有四种写法，全都要认（漏一种就等于「没读到」）：
        //   s.ios.deployment_target = '13.0'        ← 现在最常见
        //   s.platform = :ios, '13.0'
        //   s.platforms = { :ios => '12.0' }
        //   s.deployment_target('13.0')
        const patterns = [
          /ios\.deployment_target\s*=\s*'([\d.]+)'/,
          /\.platform\s*=?\s*:ios[^\d]*([\d.]+)/,
          /ios\s*=>\s*'([\d.]+)'/,
          /deployment_target\(\s*'([\d.]+)'\s*\)/,
        ];
        for (const pattern of patterns) {
          const match = text.match(pattern);
          if (match) {
            found.push({ version: match[1], from: `${path.basename(base)}/${entry}` });
            break;
          }
        }
      }
      // ② Package.swift：`platforms: [.iOS(.v12)]`（`.v12` 是 SPM 的写法）
      const pkg = path.join(base, entry, 'Package.swift');
      if (entry !== 'Package.swift' && !fs.existsSync(pkg)) continue;
      const swifts = entry === 'Package.swift' ? path.join(base, entry) : pkg;
      const text = readIf(swifts);
      if (!text) continue;
      const match = text.match(/\.iOS\(\.v(\d+)(?:_(\d+))?\)/);
      if (match) {
        const version = match[2] ? `${match[1]}.${match[2]}` : `${match[1]}.0`;
        found.push({
          version,
          from: path.relative(dir, swifts),
        });
      }
    }
  }
  return found;
}

/// 比较两个版本号字符串（只看数字段），返回较大者
function later(a, b) {
  const pa = String(a).split('.').map(Number);
  const pb = String(b).split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0;
    const y = pb[i] || 0;
    if (x !== y) return x > y ? a : b;
  }
  return a;
}

const rows = [];
let highest = '0.0';
let highestBy = '';

for (const { name, version, kind } of blocks) {
  if (PLATFORM_SUFFIX.test(name)) continue;
  const dir = path.join(cache, `${name}-${version}`);
  if (!fs.existsSync(dir)) {
    // flutter / sky_engine 这类 SDK 包在缓存外，不算依赖问题
    if (!['flutter_test', 'flutter'].includes(kind || '')) continue;
    rows.push([name, version, '（SDK 自带）', '', kind === 'direct main']);
    continue;
  }
  // 行尾先统一成 `\n`：有的包是 CRLF 发的（`open_filex` / `record` 就是），
  // 不归一化则整包静默漏掉 —— 那比报错危险。
  const pubspec = fs
    .readFileSync(path.join(dir, 'pubspec.yaml'), 'utf8')
    .replace(/\r\n/g, '\n');
  // 只看**插件**：纯 Dart 包（riverpod、dio 之类）跟平台无关
  const lines = pubspec.split('\n');
  const start = lines.indexOf('flutter:');
  if (start < 0) continue;
  let isPlugin = false;
  let iosDeclared = false;
  for (let j = start + 1; j < lines.length; j++) {
    const line = lines[j];
    if (line.trim() === '') continue;
    if (!/^\s/.test(line)) break; // 出了 flutter: 这一段
    if (/^\s+plugin:\s*$/.test(line)) isPlugin = true;
    // 6 个空格 = plugin: → platforms: 下的平台名
    if (/^ {6}ios:\s*$/.test(line)) iosDeclared = true;
    // 也有写成 `platforms: { ios: ... }` 的一行式（老模板），一并认
    if (/^\s+platforms:.*\bios:/.test(line)) iosDeclared = true;
  }
  if (!isPlugin) continue;

  const hasIosDir = fs.existsSync(path.join(dir, 'ios'));
  const darwin = fs.existsSync(path.join(dir, 'darwin'));
  const mins = minimumIos(dir);
  const minText = mins.length
    ? mins.map((entry) => entry.version).sort((a, b) => (later(a, b) === a ? -1 : 1))[0] +
      `（${mins[0].from}）`
    : '';

  let note;
  if (iosDeclared && hasIosDir) note = '✅ 有 ios/ 原生实现';
  else if (iosDeclared && darwin) note = '✅ 声明 ios，源码在 darwin/（macOS 共用）';
  else if (iosDeclared) note = '✅ 声明了 ios';
  else if (hasIosDir) note = '⚠️ 有 ios/ 目录但没在 platforms 里声明';
  else if (/(android|windows|linux|web|macos|ohos|jni|common|foundation|desktop)/.test(name))
    note = '➖ 分平台实现（不该有 ios）';
  else note = '❌ 没有 ios —— iPhone 上这个功能不会生效';

  const best = mins.map((entry) => entry.version).reduce(later, '0.0');
  if (mins.length && later(best, highest) === best && best !== highest) {
    highest = best;
    highestBy = name;
  }

  rows.push([name, version, note, minText, kind === 'direct main']);
}

const width = Math.max(...rows.map((row) => row[0].length));
const minWidth = Math.max(...rows.map((row) => row[3].length));
console.log('=== 有原生代码的依赖，在不在 iOS 上 —— 以及它要求的最低 iOS ===\n');
for (const [name, version, note, minText, isDirect] of rows) {
  console.log(
    `${name.padEnd(width)}  ${version.padEnd(12)} ${note.padEnd(30)}` +
      `${minText.padEnd(minWidth)}${isDirect ? '  ← 直接依赖' : ''}`,
  );
}

const bad = rows.filter((row) => row[2].startsWith('❌'));
const relay = rows.filter((row) => row[2].startsWith('➖'));
console.log(
  `\n共 ${rows.length} 个带原生代码的依赖：${bad.length} 个真缺口、` +
    `${relay.length} 个分平台实现（正常）。`,
);
if (bad.length) {
  console.log('\n真缺口（在 iPhone 上这个功能没有实现）：');
  for (const [name] of bad) console.log('  - ' + name);
} else {
  console.log('\n没有真缺口。');
}

console.log(
  `\n所有插件里最高的最低版本是 iOS ${highest}` +
    (highestBy ? `（${highestBy} 提的）` : ''),
);
console.log(
  '→ ios/Runner.xcodeproj 里的 IPHONEOS_DEPLOYMENT_TARGET 不得低于它' +
    '（低了在 Xcode 上是「xxx requires a higher minimum deployment target」，' +
    '在本机看不出来）。',
);
