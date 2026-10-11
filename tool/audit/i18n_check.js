// 核对：代码里 t('xxx') / translate('xxx') 用到的 key，语言包里有没有
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

const keyRe = /(?:\.t|translate)\(\s*'([^']+)'/g;
const used = new Map(); // key -> [files]
for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  let m;
  while ((m = keyRe.exec(text)) !== null) {
    const key = m[1];
    if (!used.has(key)) used.set(key, new Set());
    used.get(key).add(path.relative(root, file));
  }
}

const langs = ['zh-Hans', 'en'];
const packs = {};
for (const lang of langs) {
  packs[lang] = JSON.parse(
    fs.readFileSync(path.join(root, 'assets/i18n', `${lang}.json`), 'utf8'),
  );
}

for (const lang of langs) {
  const missing = [];
  for (const [key, where] of used) {
    if (!(key in packs[lang])) missing.push({ key, where: [...where].slice(0, 3) });
  }
  console.log(`\n=== ${lang}：代码用到但语言包缺失 ${missing.length} 个 ===`);
  for (const item of missing) console.log(`  ${item.key}   ← ${item.where.join(', ')}`);
}

// 反向：语言包里有、代码里从没用过（可能拼错 key，或该删的旧文案）
const unused = [];
for (const key of Object.keys(packs['zh-Hans'])) {
  if (!used.has(key)) unused.push(key);
}
console.log(`\n=== zh-Hans 有但代码没直接用到：${unused.length} 个（前 40）===`);
console.log(unused.slice(0, 40).join('  '));

// 两份语言包的键差集
const zh = new Set(Object.keys(packs['zh-Hans']));
const en = new Set(Object.keys(packs['en']));
const onlyZh = [...zh].filter((k) => !en.has(k));
const onlyEn = [...en].filter((k) => !zh.has(k));
console.log(`\n=== 只有 zh 的键 ${onlyZh.length}：${onlyZh.slice(0, 20).join('  ')}`);
console.log(`=== 只有 en 的键 ${onlyEn.length}：${onlyEn.slice(0, 20).join('  ')}`);

// 动态拼 key 的地方（查不到，但要看一眼有多少）
const dynamic = [];
for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  const re = /(?:\.t|translate)\(\s*(?!')([^)'\n]{1,80})\)/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    dynamic.push(`${path.relative(root, file)}: ${m[1]}`);
  }
}
console.log(`\n=== 动态 key ${dynamic.length} 处（前 25）===`);
console.log(dynamic.slice(0, 25).join('\n'));
