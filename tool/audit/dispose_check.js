// 资源释放粗筛：文件里 new 了几个需要 dispose 的东西，dispose() 里是否都收了
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

// 这些东西要成对出现；`StreamController` 等按需
const kinds = [
  'TextEditingController',
  'ScrollController',
  'PageController',
  'AnimationController',
  'StreamController',
  'TabController',
  'FocusNode',
  'Timer(',
];

for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  const rel = path.relative(root, file);

  const created = kinds
    .map((kind) => ({
      kind,
      count: (text.match(new RegExp(kind.replace('(', '\\('), 'g')) || []).length,
    }))
    .filter((item) => item.count > 0);
  if (created.length === 0) continue;

  // 计数器里 `Timer(` 会连 `Timer?` / `Timer(` 一起数，这里不追求精确，
  // 只看「有没有 dispose / cancel 这一类收尾」
  const hasDispose = /\n\s*void dispose\(\)/.test(text) || /super\.dispose\(\)/.test(text);
  const cancels = (text.match(/\.cancel\(\)/g) || []).length;
  const disposes = (text.match(/\.dispose\(\)/g) || []).length;

  const risky =
    created.some((item) =>
      ['TextEditingController', 'ScrollController', 'PageController', 'AnimationController', 'StreamController', 'TabController', 'FocusNode'].includes(item.kind),
    ) && !hasDispose;

  if (risky) {
    console.log(
      `⚠ ${rel}\n    创建：${created.map((c) => `${c.kind}×${c.count}`).join(', ')}\n    dispose()：无   .dispose() 次数=${disposes}  .cancel() 次数=${cancels}`,
    );
  }
}
console.log('\n（只列「建了控制器但文件里没有 dispose()」的，Timer 单独看 .cancel() 次数）');
