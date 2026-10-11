// 粗粒度「哪块没人管」地图：以文件名为线索，看 test/ 里有没有提到它。
// 不追求精确（很多测试是整页/整链路跑的），用来找**整块空白**。
const fs = require('fs');
const path = require('path');

const root = process.argv[2] || '.';

function dartFiles(dir) {
  const out = [];
  (function walk(current) {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.dart')) out.push(full);
    }
  })(dir);
  return out;
}

const libFiles = dartFiles(path.join(root, 'lib')).filter(
  (f) => !f.endsWith('.g.dart'),
);
const testFiles = dartFiles(path.join(root, 'test'));
let testText = '';
for (const file of testFiles) testText += fs.readFileSync(file, 'utf8');

// 测试里 import 了哪个实现文件——最可靠
const importRe = /package:gracelinkim\/([A-Za-z0-9_/.]+\.dart)/g;
const imported = new Set();
let m;
while ((m = importRe.exec(testText)) !== null) imported.add(m[1]);

const untested = [];
for (const file of libFiles) {
  const rel = path.relative(path.join(root, 'lib'), file).replace(/\\/g, '/');
  if (imported.has(rel)) continue;
  // 整个目录被别的文件带着测过也算（比如 widgets/media/ 的各个气泡）
  const dir = path.dirname(rel);
  const dirCovered = [...imported].some((other) => path.dirname(other) === dir);
  untested.push({ rel, dirCovered });
}

const notEvenDir = untested.filter((item) => !item.dirCovered);
console.log(
  `lib 文件 ${libFiles.length} 个；测试直接 import ${imported.size} 个；` +
    `没被 import ${untested.length} 个（其中所在目录也没被覆盖 ${notEvenDir.length} 个）`,
);
console.log('\n=== 所在目录都没被测试 import 的（最可能是空白区）===');
for (const item of notEvenDir) console.log(`  ${item.rel}`);
