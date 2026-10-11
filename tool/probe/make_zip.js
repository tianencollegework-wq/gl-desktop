#!/usr/bin/env node
/**
 * 打 ZIP 包（给服务端补丁用）。
 *
 * 为什么不直接用系统里的工具：
 *  * **Windows 的 `Compress-Archive` 会把路径写成反斜杠**（`app\enterprise\...`），
 *    而站点是 Linux：宝塔/unzip 解出来会是一个**名字里带反斜杠的单个文件**，
 *    等于什么都没装上（这个坑踩过一次）；
 *  * 这台开发机上通常没有 `zip` 命令（Git Bash 不带），`tar -a -f x.zip` 造出来的
 *    其实是**没有压缩的 tar**，只是名字叫 .zip。
 *
 * 所以自己按 ZIP 规范写：正斜杠路径、deflate 压缩、每个文件都带 CRC32。
 * 解压出来就是站点根目录该有的那几层（`app/`、`config/`、`sql/`…）。
 *
 * 用法：
 *   node build/probe/make_zip.js <输出.zip> <源目录> <要打进包的相对路径…>
 *
 * 例：
 *   node build/probe/make_zip.js build/server-patch/x.zip \
 *     build/server-patch/sfu-group-call README.txt app config sql check_server.js
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ZIP 规范要求的 CRC32（每一条文件头都要写）
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

/** 把一个相对路径展开成文件清单（目录递归、按名字排序，保证两次打包结果一致） */
function collectFiles(root, entry) {
  const abs = path.join(root, entry);
  const stat = fs.statSync(abs);
  if (stat.isDirectory()) {
    const out = [];
    for (const name of fs.readdirSync(abs).sort()) {
      out.push(...collectFiles(root, `${entry}/${name}`));
    }
    return out;
  }
  return [entry];
}

const [outZip, ...args] = process.argv.slice(2);
if (!outZip || args.length < 2) {
  console.error(
    '用法: node build/probe/make_zip.js <输出.zip> <源目录> <相对路径…>',
  );
  process.exit(1);
}
const root = args[0];
const files = args
  .slice(1)
  .flatMap((entry) => collectFiles(root, entry))
  .map((entry) => entry.split(path.sep).join('/'));

const chunks = [];
const central = [];
let offset = 0;

for (const name of files) {
  const data = fs.readFileSync(path.join(root, name));
  const deflated = zlib.deflateRawSync(data, { level: 9 });
  const useDeflate = deflated.length < data.length;
  const body = useDeflate ? deflated : data;
  const method = useDeflate ? 8 : 0;
  const crc = crc32(data);
  const nameBuf = Buffer.from(name, 'utf8');

  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0); // 本地文件头
  local.writeUInt16LE(20, 4); // 解压需要 2.0
  local.writeUInt16LE(0x0800, 6); // 文件名是 UTF-8
  local.writeUInt16LE(method, 8);
  local.writeUInt16LE(0, 10); // 时间（0 = 00:00）
  local.writeUInt16LE(0x21, 12); // 日期（1980-01-01，规范允许的最小值）
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(body.length, 18);
  local.writeUInt32LE(data.length, 22);
  local.writeUInt16LE(nameBuf.length, 26);
  local.writeUInt16LE(0, 28);

  chunks.push(local, nameBuf, body);
  central.push({
    name: nameBuf,
    method,
    crc,
    compressed: body.length,
    size: data.length,
    offset,
  });
  offset += local.length + nameBuf.length + body.length;
}

const centralStart = offset;
for (const item of central) {
  const head = Buffer.alloc(46);
  head.writeUInt32LE(0x02014b50, 0); // 中央目录项
  head.writeUInt16LE(20, 4); // 打包工具版本
  head.writeUInt16LE(20, 6); // 解压需要 2.0
  head.writeUInt16LE(0x0800, 8);
  head.writeUInt16LE(item.method, 10);
  head.writeUInt16LE(0, 12);
  head.writeUInt16LE(0x21, 14);
  head.writeUInt32LE(item.crc, 16);
  head.writeUInt32LE(item.compressed, 20);
  head.writeUInt32LE(item.size, 24);
  head.writeUInt16LE(item.name.length, 28);
  head.writeUInt16LE(0, 30); // 额外字段
  head.writeUInt16LE(0, 32); // 注释
  head.writeUInt16LE(0, 34); // 磁盘号
  head.writeUInt16LE(0, 36); // 内部属性
  head.writeUInt32LE(0, 38); // 外部属性
  head.writeUInt32LE(item.offset, 42);
  chunks.push(head, item.name);
  offset += head.length + item.name.length;
}

const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0); // 中央目录结束记录
end.writeUInt16LE(0, 4);
end.writeUInt16LE(0, 6);
end.writeUInt16LE(central.length, 8);
end.writeUInt16LE(central.length, 10);
end.writeUInt32LE(offset - centralStart, 12);
end.writeUInt32LE(centralStart, 16);
end.writeUInt16LE(0, 20);
chunks.push(end);

fs.mkdirSync(path.dirname(outZip), { recursive: true });
fs.writeFileSync(outZip, Buffer.concat(chunks));
console.log(
  `已写出 ${outZip}（${files.length} 个文件，${fs.statSync(outZip).size} 字节）`,
);
for (const name of files) console.log('  ' + name);
