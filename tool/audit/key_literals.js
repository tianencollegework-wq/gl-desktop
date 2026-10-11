// 动态拼 key 的地方（switch 里返回 'common.xxx' 那种）查不到，这里换个角度：
// 把所有「看起来像 i18n key」的字面量捞出来，看哪个不在语言包里 —— 拼错一个字母
// 用户界面上就会直接显示 key 本身。
const fs = require('fs');
const path = require('path');

const root = process.argv[2] || '.';
const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith('.dart')) files.push(full);
  }
})(path.join(root, 'lib'));

const zh = JSON.parse(
  fs.readFileSync(path.join(root, 'assets/i18n/zh-Hans.json'), 'utf8'),
);
const en = JSON.parse(
  fs.readFileSync(path.join(root, 'assets/i18n/en.json'), 'utf8'),
);

// key 形如 'chat.emojiFlags'、'user.cancelAccount'（只含词与点，且至少一个点）
const literalRe = /'([a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)+)'/g;
const unknown = new Map();
for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  let m;
  while ((m = literalRe.exec(text)) !== null) {
    const key = m[1];
    if (key in zh && key in en) continue;
    if (!unknown.has(key)) unknown.set(key, new Set());
    unknown.get(key).add(path.relative(root, file));
  }
}

console.log(`=== 像 key 但语言包里没有的字符串：${unknown.size} 个 ===`);
for (const [key, where] of unknown) {
  console.log(`  ${key}   ← ${[...where].join(', ')}`);
}
