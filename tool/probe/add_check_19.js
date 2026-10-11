// 在 check_server.js 的结尾（打印结果之前）插入第 12 组自检。
// 用法：node build/probe/add_check_19.js
const fs = require('fs');
const file = 'build/server-patch/sfu-group-call/check_server.js';
let src = fs.readFileSync(file, 'utf8');

const anchor = "console.log('');\nif (failures) {";
if (!src.includes(anchor)) {
  console.error('找不到插入点');
  process.exit(1);
}
if (src.includes('// ------------------------------------------------- 12. 界面不迟钝')) {
  console.log('已经加过，跳过');
  process.exit(0);
}

const block = `// ------------------------------------------------- 12. 界面不迟钝（S6.19）
console.log('12) 界面不迟钝的两条（心跳也清场 + 行超时封顶）');
check(
  'heartbeat 里也清场（否则「版本号不变 → 客户端不拉快照 → 清场永远不跑」的死锁）',
  /public function heartbeat\\(\\)[\\s\\S]{0,1200}?\\$this->prune\\(\\$roomId\\);/.test(
    controller,
  ) &&
    /public function room\\(\\)[\\s\\S]{0,300}?\\$this->prune\\(\\$roomId\\);/.test(
      controller,
    ),
);
check(
  '行超时封顶 45 秒（客户端心跳 20 秒一拍 + 每 5 秒回查；90 秒在真机上就是「人都走了还写着在共享」）',
  /\\$ttl\\s*=\\s*min\\(45, max\\(30, \\(int\\)\\$this->setting\\('row_ttl'/.test(
    controller,
  ),
);

`;

src = src.replace(anchor, block + anchor);
fs.writeFileSync(file, src);
console.log('已插入第 12 组自检');
