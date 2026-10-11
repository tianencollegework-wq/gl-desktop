// 找"用户看得见的写死中文"：只留界面语义的位置（Text/label/title/hint/tooltip/
// message/content/snackbar/toast/Exception 文案），把 debugPrint 这类内部日志剔掉。
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..', '..');
const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith('.dart')) files.push(full);
  }
})(path.join(root, 'lib'));

const cjk = /[\u4e00-\u9fff]/;
const literal = /'([^'\\\n]*)'/g;
const visible = /(Text\(|\.text\s*[=:]|label|title|hint|tooltip|message|content|subtitle|notice|toast|SnackBar|AppBar)/;
const hidden = /(debugPrint|print\(|_record\(|trace\.|log\()/;
const categories = new Map();

for (const file of files) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  let inBlockComment = false;
  lines.forEach((line, index) => {
    const trimmed = line.trim();
    if (inBlockComment) {
      if (trimmed.includes('*/')) inBlockComment = false;
      return;
    }
    if (trimmed.startsWith('/*')) {
      if (!trimmed.includes('*/')) inBlockComment = true;
      return;
    }
    if (trimmed.startsWith('//') || trimmed.startsWith('*')) return;
    const code = line.split('//')[0];
    if (hidden.test(code) || !visible.test(code)) return;
    let m;
    literal.lastIndex = 0;
    while ((m = literal.exec(code)) !== null) {
      const value = m[1];
      if (!cjk.test(value)) continue;
      if (/\bt\(|\btranslate\(|\.t\(/.test(code)) continue; // 走语言包的
      if (/^[\s\u4e00-\u9fff]*$/.test(value) === false) continue;
      const where = path.relative(root, file).replace(/\\/g, '/');
      if (!categories.has(where)) categories.set(where, []);
      categories.get(where).push(`${index + 1}  ${value}`);
    }
  });
}

let total = 0;
for (const [where, list] of categories) {
  total += list.length;
  console.log(`\n${where}（${list.length}）`);
  for (const item of list.slice(0, 12)) console.log('  ' + item);
}
console.log(`\n合计 ${total} 处`);
