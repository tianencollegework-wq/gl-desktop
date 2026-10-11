// 一次性脚本：把群通话那批 key 插到两份语言包里 `group.user` 那行后面。
// 不用 JSON.stringify 重写：那会把整份文件的排版/换行都改掉，diff 没法看。
const fs = require('fs');

const zh = {
  'group.call': '群通话',
  'group.callPeople': '{n} 人在通话',
  'group.callJoining': '正在加入...',
  'group.callReconnecting': '正在重连...',
  'group.callFailed': '进不去这个群通话',
  'group.callRetry': '重试',
  'group.callBack': '返回',
  'group.callMembers': '成员',
  'group.callMembersTitle': '通话成员（{n}）',
  'group.callNotJoined': '未加入',
  'group.callMuted': '已静音',
  'group.callSpeaking': '正在说话',
  'group.callMe': '我',
  'group.callIsSharing': '{name} 正在共享屏幕',
  'group.callMyScreenHint': '他们现在看到的就是你的屏幕',
  'group.callEmpty': '还没人进来',
  'group.callMicFailed': '麦克风切换失败，请重试',
  'group.callBusy': '你正在通话中，请先挂断',
};

const en = {
  'group.call': 'Group call',
  'group.callPeople': '{n} in call',
  'group.callJoining': 'Joining...',
  'group.callReconnecting': 'Reconnecting...',
  'group.callFailed': "Couldn't join this group call",
  'group.callRetry': 'Retry',
  'group.callBack': 'Back',
  'group.callMembers': 'Members',
  'group.callMembersTitle': 'Members ({n})',
  'group.callNotJoined': 'Not joined',
  'group.callMuted': 'Muted',
  'group.callSpeaking': 'Speaking',
  'group.callMe': 'Me',
  'group.callIsSharing': '{name} is sharing their screen',
  'group.callMyScreenHint': 'They can see your screen now',
  'group.callEmpty': 'Nobody has joined yet',
  'group.callMicFailed': "Couldn't switch the microphone",
  'group.callBusy': "You're in a call already — hang up first",
};

function patch(file, map) {
  const raw = fs.readFileSync(file, 'utf8');
  const lines = raw.split('\r\n');
  const at = lines.findIndex((line) => line.trimStart().startsWith('"group.user"'));
  if (at < 0) throw new Error('找不到 group.user 那一行：' + file);
  const extra = Object.entries(map).map(([key, value]) => {
    const text = JSON.stringify(value).slice(1, -1); // 去掉外层引号，保持原文件风格
    return `  ${JSON.stringify(key)}: "${text}",`;
  });
  const merged = [...lines.slice(0, at + 1), ...extra, ...lines.slice(at + 1)];
  const text = merged.join('\r\n');
  JSON.parse(text); // 插坏了立刻炸，别把坏文件写回去
  fs.writeFileSync(file, text);
  console.log(`${file}: 插入 ${extra.length} 条`);
}

patch('assets/i18n/zh-Hans.json', zh);
patch('assets/i18n/en.json', en);
