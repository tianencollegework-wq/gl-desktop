// 给服务端 Sfu.php 打上这一刀：**renegotiate 之后按会话真实状态重算注册表**。
//
// 为什么必须做（真机上的三个症状全出自这里）：CF 对 `tracks/new`（发布）不一定直接
// 回 answer —— 它认为还需要一次重协商时回的是一个 offer，而且**不带任何 track 结果**
// （那一刻确实什么都还没发布）。客户端答完这一趟 renegotiate 之后发布才真正生效。
// 若注册表只认 publish 那一次的回包，它就永远空着 → 别人不会来订阅我 →
// 听不到我、共享屏也没人看得到，而客户端那边一切看起来都正常。
//
// 用法：node build/probe/patch_sfu_registry.js <Sfu.php 路径>
'use strict';

const fs = require('fs');

const file = process.argv[2];
if (!file) {
  console.error('用法：node patch_sfu_registry.js <Sfu.php 路径>');
  process.exit(1);
}

let src = fs.readFileSync(file, 'utf8');

if (src.includes('private function syncRegistry(')) {
  console.log('已经打过这一刀，跳过');
  process.exit(0);
}

const RENEGOTIATE_CALL =
  "            'sessionDescription' => ['type' => 'answer', 'sdp' => $sdp],\n" +
  '        ]);\n' +
  '        $this->touch($row);\n';

if (!src.includes(RENEGOTIATE_CALL)) {
  console.error('找不到 renegotiate 里的锚点，没动文件');
  process.exit(2);
}

const RECONCILE = `        // ⚠️ **这一步不能省**：把注册表按 CF 那边会话的真实状态重算一遍。
        //
        // 为什么：CF 对 \`tracks/new\`（发布）**不一定直接回 answer** —— 它认为还需要
        // 一次重协商时，回的是**一个 offer**（\`requiresImmediateRenegotiation\`），
        // 而且**不带任何 track 结果**（那一刻确实什么都还没发布）。真正发布成功是
        // 客户端把 answer 交到这里之后。
        //
        // 若注册表只认 \`publish\` 那一次的回包，它就会**永远空着**：别人不会来订阅我
        // （听不到我的声音）、共享屏也没人看得到，而客户端那边一切看起来都正常 ——
        // 真机上报的三个症状就是这么来的。
        if ($this->syncRegistry($row)) {
            // 注册表变了必须广播：别人得知道该来订阅（或退订）我这几条
            $this->bumpEpoch((string)$row['room_id']);
        }

`;

const SYNC_METHOD = `
    /**
     * 把注册表这一行按 CF 会话的**真实状态**重算（tracks / mids），返回有没有变。
     *
     * 用官方那条「看清这个会话现在有什么」的接口：
     * \`GET /sessions/{sessionId}\` → \`{tracks:[{location,mid,trackName,status}], …}\`。
     * 拿它重算比"事后猜"可靠；而且它是**读**接口，随时能调、不扰动会话，
     * 也不会占着那条会话的重协商状态机。
     *
     * 两条边界：
     * * 查不到（网络抖 / 上游出错）→ **原样不动**：拿不准不是"我把发布撤了"；
     * * 只认 \`location = local\` 的：远端那几条是我**订阅**来的，不属于这一行的发布
     *   清单（接收会话那一行也就因此不会被写脏）。
     */
    private function syncRegistry($row)
    {
        $state  = $this->cfQuiet('GET', '/sessions/' . rawurlencode($row['session_id']));
        $tracks = $state['tracks'] ?? null;
        if (!is_array($tracks)) {
            return false;
        }

        $names = [];
        $mids  = $this->midMap($row['mids']);
        foreach ($tracks as $track) {
            if (!is_array($track)) {
                continue;
            }
            if (strtolower((string)($track['location'] ?? '')) !== 'local') {
                continue;
            }
            $name = trim((string)($track['trackName'] ?? ''));
            if ($name === '') {
                continue;
            }
            // 已经关掉/失效的那条不算"我在发布"
            if (strtolower((string)($track['status'] ?? '')) === 'inactive') {
                continue;
            }
            if (!in_array($name, $names, true)) {
                $names[] = $name;
            }
            $mid = trim((string)($track['mid'] ?? ''));
            if ($mid !== '') {
                $mids[$mid] = $name;
            }
        }

        $newMids   = $this->midRaw($mids);
        $newTracks = implode(',', $names);
        if ($newMids === (string)$row['mids'] && $newTracks === (string)$row['tracks']) {
            return false;
        }

        $this->putMember(
            (string)$row['room_id'],
            (string)$row['user_id'],
            (string)$row['purpose'],
            (string)$row['session_id'],
            $newMids,
            $newTracks
        );
        return true;
    }

`;

// 1) renegotiate 之后补上重算
src = src.replace(
  RENEGOTIATE_CALL,
  RENEGOTIATE_CALL.replace('        $this->touch($row);\n', RECONCILE + '        $this->touch($row);\n'),
);

// 2) 新方法插在 cfQuiet 之前（照文件里"上游调用"那一块的顺序放）
const CF_QUIET_ANCHOR = '    private function cfQuiet($method, $path, $body = null)';
if (!src.includes(CF_QUIET_ANCHOR)) {
  console.error('找不到 cfQuiet 锚点，没动文件');
  process.exit(3);
}
src = src.replace(CF_QUIET_ANCHOR, SYNC_METHOD.trimStart() + CF_QUIET_ANCHOR);

fs.writeFileSync(file, src);
console.log('已写入：' + file);
