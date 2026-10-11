// 列出每个依赖「在 macOS 上到底有没有原生实现」。
//
// 为什么需要这个：Mac 版编得出来、装得上去，不代表功能都在 —— `flutter build macos`
// 只会把「声明了 macos 平台」的插件链进去，没声明的那些调用会在运行时抛
// MissingPluginException（我们自己的 Dart 封装大多吞掉它 → 功能静默消失）。
// 所以这份清单是「哪些功能在 Mac 上会没有」的答案。
//
// 用法：node tool/audit/macos_support.js [pub-cache 路径]
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

// 分平台实现的名字里带平台后缀（`_android` / `_windows` / `_linux` / `_web` / `_ios`）：
// 它们「没有 macos」是正常的，macOS 那份叫 `_macos` 或走 darwin 共享源码。
const PLATFORM_SUFFIX = /_(android|ios|linux|windows|web|macos|darwin)$/;

const rows = [];
for (const { name, version, kind } of blocks) {
  if (PLATFORM_SUFFIX.test(name)) continue;
  const dir = path.join(cache, `${name}-${version}`);
  if (!fs.existsSync(dir)) {
    // flutter / sky_engine 这类 SDK 包在缓存外，不算依赖问题
    if (!['flutter', 'flutter_test'].includes(kind || '')) continue;
    rows.push([name, version, '（SDK 自带）']);
    continue;
  }
  // 行尾先统一成 `\n`：有的包是 CRLF 发的（`open_filex` / `record` 就是），
  // 不归一化则 `lines.indexOf('flutter:')` 永远找不到，整包**静默漏掉**
  // —— 那比报错危险：清单看着齐全，其实少了几行。
  const pubspec = fs
    .readFileSync(path.join(dir, 'pubspec.yaml'), 'utf8')
    .replace(/\r\n/g, '\n');
  // 只看**插件**：纯 Dart 包（riverpod、dio 之类）跟平台无关。
  // 用逐行扫而不是一条大正则：`flutter:` 段常常是文件最后一段，
  // 末尾还有个换行 —— 那时 `(?=^\S)` 这种收尾条件永远不成立（踩过）。
  const lines = pubspec.split('\n');
  const start = lines.indexOf('flutter:');
  if (start < 0) continue;
  let isPlugin = false;
  let macosDeclared = false;
  for (let j = start + 1; j < lines.length; j++) {
    const line = lines[j];
    if (line.trim() === '') continue;
    if (!/^\s/.test(line)) break; // 出了 flutter: 这一段
    if (/^\s+plugin:\s*$/.test(line)) isPlugin = true;
    // 6 个空格 = plugin: → platforms: 下的平台名
    if (/^ {6}macos:\s*$/.test(line)) macosDeclared = true;
  }
  if (!isPlugin) continue;
  const hasMacosDir = fs.existsSync(path.join(dir, 'macos'));
  const darwin = fs.existsSync(path.join(dir, 'darwin'));
  let note;
  if (macosDeclared && hasMacosDir) note = '✅ 有 macos/ 原生实现';
  else if (macosDeclared && darwin) note = '✅ 声明 macos，源码在 darwin/（iOS 共用）';
  else if (macosDeclared) note = '✅ 声明了 macos';
  else if (hasMacosDir) note = '⚠️ 有 macos/ 目录但没在 platforms 里声明';
  // 名字里带平台/分工词的是**分平台实现**：它们本来就不该有 macos
  //（macOS 那份叫 `_macos` / `_foundation` / 走 darwin 共享源码）。
  // 真正要盯的是**不带这些词、却只声明了别的平台**的那种。
  else if (/(android|ios|windows|linux|web|ohos|jni|common|foundation)/.test(name))
    note = '➖ 分平台实现（不该有 macos）';
  else note = '❌ 没有 macos —— Mac 上这个功能不会生效';
  rows.push([name, version, note, kind === 'direct main']);
}

const width = Math.max(...rows.map((row) => row[0].length));
console.log('=== 有原生代码的依赖，在不在 macOS 上 ===\n');
for (const [name, version, note, isDirect] of rows) {
  console.log(
    `${name.padEnd(width)}  ${version.padEnd(12)} ${note}${isDirect ? '  ← 直接依赖' : ''}`,
  );
}

const bad = rows.filter((row) => row[2].startsWith('❌'));
const relay = rows.filter((row) => row[2].startsWith('➖'));
console.log(
  `\n共 ${rows.length} 个带原生代码的依赖：${bad.length} 个真缺口、` +
    `${relay.length} 个分平台实现（正常）。`,
);
if (bad.length) {
  console.log('\n真缺口（在 macOS 上这个功能没有实现）：');
  for (const [name] of bad) console.log('  - ' + name);
} else {
  console.log('\n没有真缺口。');
}
