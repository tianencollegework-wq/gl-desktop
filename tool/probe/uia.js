// 从 uiautomator 的 dump 里找节点，打印中心坐标（用来喂 adb shell input tap）
//   node build/probe/uia.js build/probe/u.xml --list
//   node build/probe/uia.js build/probe/u.xml 新歌首发
const fs = require('fs');
const [, , file, needle] = process.argv;
const xml = fs.readFileSync(file, 'utf8');
const nodes = xml.match(/<node\b[^>]*>/g) || [];
const rows = nodes.map((raw) => {
  const attr = (name) => {
    const m = raw.match(new RegExp(name + '="([^"]*)"'));
    return m ? m[1] : '';
  };
  const bounds = attr('bounds').match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
  return {
    text: attr('content-desc') || attr('text'),
    clickable: attr('clickable'),
    cls: attr('class'),
    point: bounds
      ? [
          Math.round((+bounds[1] + +bounds[3]) / 2),
          Math.round((+bounds[2] + +bounds[4]) / 2),
        ]
      : null,
  };
});
for (const row of rows) {
  if (!row.text) continue;
  if (needle === '--list' || row.text.includes(needle)) {
    console.log(`${row.text.replace(/\n/g, ' / ')} → ${row.point} clickable=${row.clickable} ${row.cls}`);
  }
}
