// 界面里写死的中文：切到 English 之后这些不会变 —— 属于「细节漏网」。
// 只挑界面层（features/），并排掉注释、日志、异常消息。
const fs = require('fs');
const path = require('path');

const root = process.argv[2] || 'lib/features';
const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith('.dart')) files.push(full);
  }
})(root);

const hits = [];
for (const file of files) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  lines.forEach((line, index) => {
    const trimmed = line.trim();
    if (trimmed.startsWith('//') || trimmed.startsWith('///')) return;
    if (/^(debugPrint|print|assert)\(/.test(trimmed)) return;
    if (/^\s*\/\//.test(line)) return;
    // 去掉行尾注释再找中文字面量
    const code = line.replace(/\/\/.*$/, '');
    const matches = code.match(/'[^']*[\u4e00-\u9fff][^']*'/g);
    if (!matches) return;
    // i18n 调用里不会有中文字面量，所以这里不用排除
    hits.push(`${file.replace(/\\/g, '/')}:${index + 1}  ${matches.join('  ')}`);
  });
}

console.log(`=== 界面层写死的中文：${hits.length} 处 ===`);
console.log(hits.join('\n'));
