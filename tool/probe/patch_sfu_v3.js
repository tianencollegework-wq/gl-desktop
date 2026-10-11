// 把 v3_patch_spec.txt 里的「锚点 → 替换」逐对打到目标 Sfu.php 上。
//
// 为什么用脚本改而不是手改：补丁源目录在 build/ 下（编辑器只读不改），而且改造必须
// **可重复、可验证** —— 锚点找不到、锚点不唯一、已经打过，都要当场报错退出，
// 绝不能"改了一半还以为成功了"。
//
// 用法：node build/probe/patch_sfu_v3.js <目标 Sfu.php 的路径>
const fs = require('fs');

const specPath = 'build/probe/v3_patch_spec.txt';
const target = process.argv[2];
if (!target) {
  console.error('用法：node build/probe/patch_sfu_v3.js <Sfu.php>');
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
if (src.includes('ensureColumns')) {
  console.error('已经打过这个补丁了（找到 ensureColumns）：' + target);
  process.exit(2);
}

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

fs.writeFileSync(target, src);
console.log('完成：打了 ' + applied + ' 处 → ' + target);
