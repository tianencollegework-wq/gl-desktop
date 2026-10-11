// 一次性脚本：群通话诊断面板那批 key，插到 `group.call` 那一行后面。
const fs = require('fs');

const zh = {
  'group.diagnostics': '群通话诊断',
  'group.diagRoom': '房间',
  'group.diagRoomId': '房间号',
  'group.diagSessions': '会话（发布 ｜ 接收）',
  'group.diagPublished': '我发布',
  'group.diagSpeaker': '说话人',
  'group.diagSubs': '订阅',
  'group.diagCounters': '计数（重建一直涨说明网络或凭据有问题）',
};

const en = {
  'group.diagnostics': 'Group call diagnostics',
  'group.diagRoom': 'Room',
  'group.diagRoomId': 'Room id',
  'group.diagSessions': 'Sessions (publish | receive)',
  'group.diagPublished': 'Published by me',
  'group.diagSpeaker': 'Speaker',
  'group.diagSubs': 'Subscriptions',
  'group.diagCounters': 'Counters (rebuilds climbing = network or credentials)',
};

function patch(file, map) {
  const raw = fs.readFileSync(file, 'utf8');
  const lines = raw.split('\r\n');
  const at = lines.findIndex((line) =>
    line.trimStart().startsWith('"group.call"'),
  );
  if (at < 0) throw new Error('找不到 group.call 那一行：' + file);
  const extra = Object.entries(map).map(([key, value]) => {
    const text = JSON.stringify(value).slice(1, -1);
    return `  ${JSON.stringify(key)}: "${text}",`;
  });
  const merged = [...lines.slice(0, at + 1), ...extra, ...lines.slice(at + 1)];
  const text = merged.join('\r\n');
  JSON.parse(text);
  fs.writeFileSync(file, text);
  console.log(`${file}: 插入 ${extra.length} 条`);
}

patch('assets/i18n/zh-Hans.json', zh);
patch('assets/i18n/en.json', en);
