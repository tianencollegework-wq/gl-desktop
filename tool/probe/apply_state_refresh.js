// 服务端 Sfu.php：两处改动
//   1) heartbeat 里也清场（prune）—— 断掉“版本号不变就不拉快照、清场永远不跑”的死锁
//   2) 行超时封顶 45 秒 —— 掉线的人最迟 45 秒从注册表消失
// 用法：node build/probe/apply_state_refresh.js
const fs = require('fs');
const path = 'build/server-patch/sfu-group-call/app/enterprise/controller/Sfu.php';
let src = fs.readFileSync(path, 'utf8');
const before = src;

const edits = [
  {
    from: `    public function heartbeat()
    {
        $roomId = $this->roomId($this->body('room_id'));
        $this->touchMine($roomId);`,
    to: `    public function heartbeat()
    {
        $roomId = $this->roomId($this->body('room_id'));
        // ⚠️ **心跳也要清场**（2026-09-27 补）。
        //
        // 以前清场（\`prune\`）只在拉快照（\`room\`）里跑，而客户端的“该不该拉快照”
        // 看的是**版本号变没变** —— 两边正好互相等：
        //
        //   掉线/被杀的那个人不会自己写注册表 → 版本号不变 → 客户端不拉快照
        //   → 清场永远不跑 → **那一行就永远挂在房间里**
        //
        // 真机上就是“人都走了三分钟，我这儿还写着他在共享屏幕”。
        // 心跳是每个还在通话里的人**每 20 秒一定会调一次**的接口，把它当作清场
        // 的第二个入口，这一条路就断了。
        $this->prune($roomId);
        $this->touchMine($roomId);`,
  },
  {
    from: `    private function prune($roomId)
    {
        $this->ensureTable();
        $ttl      = (int)$this->setting('row_ttl', 90);
        $deadline = time() - max(30, $ttl);`,
    to: `    private function prune($roomId)
    {
        $this->ensureTable();
        // 行超时**封顶 45 秒**（2026-09-27）：客户端现在每 5 秒回查一次状态、
        // 每 20 秒一次心跳，45 秒 = 两拍心跳 + 余量，健康的人不可能被误清。
        // 而配置里那个 90 秒在真机上就是“人都走了界面还写着他在共享”——
        // 掉线的人没有端点可挂，只能靠这一刀清。
        $ttl      = min(45, max(30, (int)$this->setting('row_ttl', 45)));
        $deadline = time() - $ttl;`,
  },
];

for (const edit of edits) {
  if (!src.includes(edit.from)) {
    console.error('找不到要替换的原文（可能已经改过）：' + edit.from.split('\n')[1]);
    process.exit(1);
  }
  src = src.replace(edit.from, edit.to);
}

if (src === before) {
  console.error('没有任何改动');
  process.exit(1);
}
fs.writeFileSync(path, src);
console.log('已改：' + path);
