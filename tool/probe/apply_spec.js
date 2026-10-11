// 通用打补丁器：把 spec 文件里的「锚点 → 替换」逐对打到目标文件上。
//
// spec 文件的格式（`::` 分隔的段落，见 v3_patch_spec.txt）：
//   @@A1
//   <锚点原文>
//   @@R1
//   <替换后的原文>
//   @@A2
//   ...
//
// 任何一处锚点找不到 / 不唯一，都**当场报错退出且不写文件** —— 打一半的补丁比没打更糟。
//
// 用法：node build/probe/apply_spec.js <spec.txt> <目标文件>
const fs = require('fs');

const specPath = process.argv[2];
const target = process.argv[3];
if (!specPath || !target) {
  console.error('用法：node build/probe/apply_spec.js <spec.txt> <目标文件>');
  process.exit(1);
}

const lines = fs.readFileSync(specPath, 'utf8').split(/\r?\n/);
const blocks = {};
let key = null;
for (const line of lines) {
  const m = line.match(/^@@([AR]\d+)$/);
  if (m) {
    key = m[1];
    blocks[key] = [];
    continue;
  }
  if (key) blocks[key].push(line);
}
for (const k of Object.keys(blocks)) {
  while (blocks[k].length && blocks[k][blocks[k].length - 1] === '') blocks[k].pop();
}

let src = fs.readFileSync(target, 'utf8');
let applied = 0;
for (let i = 1; ; i++) {
  const a = blocks['A' + i];
  const r = blocks['R' + i];
  if (!a || !r) break;
  const anchor = a.join('\n');
  const first = src.indexOf(anchor);
  if (first < 0) {
    console.error('锚点 ' + i + ' 没找到，没有做任何修改');
    process.exit(1);
  }
  if (src.indexOf(anchor, first + 1) >= 0) {
    console.error('锚点 ' + i + ' 不唯一，没有做任何修改');
    process.exit(1);
  }
  src = src.slice(0, first) + r.join('\n') + src.slice(first + anchor.length);
  applied += 1;
  console.log('✓ 锚点 ' + i + ' 已替换');
}
if (applied === 0) {
  console.error('spec 里一对锚点都没有');
  process.exit(1);
}

fs.writeFileSync(target, src);
console.log('完成：打了 ' + applied + ' 处 → ' + target);
