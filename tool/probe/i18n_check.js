// 文案自检（只在开发时跑，不进 App）：
// 1. 两份语言包的键是否一一对应（少一个 = 切到英文就有地方显示成 key 原文）；
// 2. lib/ 里 `t('xxx')` 用到的字面量是不是都在语言包里（缺了会原样显示 key）。
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..', '..');
const read = (p) => JSON.parse(fs.readFileSync(path.join(root, p), 'utf8'));

const zh = read('assets/i18n/zh-Hans.json');
const en = read('assets/i18n/en.json');

const zhKeys = new Set(Object.keys(zh));
const enKeys = new Set(Object.keys(en));

const onlyZh = [...zhKeys].filter((k) => !enKeys.has(k));
const onlyEn = [...enKeys].filter((k) => !zhKeys.has(k));

// 空值 / 占位符不一致（`{name}` 一边有一边没有 → 有一边会显示出 {name} 原文）
const emptyValues = [...zhKeys].filter((k) => String(zh[k]).trim() === '');
const paramMismatch = [...zhKeys].filter((k) => {
  if (!enKeys.has(k)) return false;
  const names = (s) =>
    (String(s).match(/\{[a-zA-Z0-9_]+\}/g) || []).sort().join(',');
  return names(zh[k]) !== names(en[k]);
});

// lib/ 下所有 `t('...')` / `has('...')` 的字面量
const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith('.dart')) files.push(full);
  }
})(path.join(root, 'lib'));

const used = new Map(); // key -> [文件:行]
for (const file of files) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, index) => {
    const re = /\b(?:t|has)\(\s*'([A-Za-z0-9_.]+)'/g;
    let m;
    while ((m = re.exec(line)) !== null) {
      const key = m[1];
      if (!used.has(key)) used.set(key, []);
      used.get(key).push(
        path.relative(root, file).replace(/\\/g, '/') + ':' + (index + 1),
      );
    }
  });
}

const missing = [...used.entries()].filter(([key]) => !zhKeys.has(key));

// 反向：语言包里有、代码里从没用过的（多半是残留，不是 bug，但值得看一眼）
const unused = [...zhKeys].filter(
  (key) => !used.has(key) && /^(call|group|chat|conversation)\./.test(key),
);

const show = (title, list) => {
  console.log(`\n== ${title}（${list.length}）==`);
  for (const item of list.slice(0, 60)) console.log('  ' + item);
};

show('英文缺的键', onlyZh);
show('中文缺的键', onlyEn);
show('中文空文案', emptyValues);
show('两份占位符不一致', paramMismatch);
show(
  '代码里用了、语言包里没有',
  missing.map(([key, where]) => `${key}  ← ${where[0]}`),
);
show('call/group/chat 前缀里没被用到的键（残留）', unused);
