// 手写 PNG 解码（只够用：8 位、非隔行、color type 0/2/3/4/6），用来算
// 「logo 周围的透明留白有多少」「不透明部分的平均色」—— 生成图标前先量一下。
const fs = require('fs');
const zlib = require('zlib');

const file = process.argv[2];
const buf = fs.readFileSync(file);
let pos = 8;
let width = 0, height = 0, depth = 0, colorType = 0;
const idat = [];
let palette = null;
while (pos < buf.length) {
  const len = buf.readUInt32BE(pos);
  const type = buf.toString('ascii', pos + 4, pos + 8);
  const data = buf.subarray(pos + 8, pos + 8 + len);
  if (type === 'IHDR') {
    width = data.readUInt32BE(0);
    height = data.readUInt32BE(4);
    depth = data[8];
    colorType = data[9];
  } else if (type === 'PLTE') {
    palette = data;
  } else if (type === 'IDAT') {
    idat.push(data);
  } else if (type === 'IEND') {
    break;
  }
  pos += 12 + len;
}

const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
const raw = zlib.inflateSync(Buffer.concat(idat));
const stride = width * channels;
const px = Buffer.alloc(height * stride);
let offset = 0;
for (let y = 0; y < height; y++) {
  const filter = raw[offset++];
  const line = raw.subarray(offset, offset + stride);
  offset += stride;
  for (let x = 0; x < stride; x++) {
    const a = x >= channels ? px[y * stride + x - channels] : 0;
    const b = y > 0 ? px[(y - 1) * stride + x] : 0;
    const c = x >= channels && y > 0 ? px[(y - 1) * stride + x - channels] : 0;
    let v = line[x];
    switch (filter) {
      case 1: v += a; break;
      case 2: v += b; break;
      case 3: v += (a + b) >> 1; break;
      case 4: {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
        break;
      }
    }
    px[y * stride + x] = v & 0xff;
  }
}

let minX = width, minY = height, maxX = -1, maxY = -1;
let rSum = 0, gSum = 0, bSum = 0, opaque = 0, transparent = 0;
for (let y = 0; y < height; y++) {
  for (let x = 0; x < width; x++) {
    const i = y * stride + x * channels;
    let r, g, b, a = 255;
    if (colorType === 6) [r, g, b, a] = [px[i], px[i + 1], px[i + 2], px[i + 3]];
    else if (colorType === 4) { [r, g, a] = [px[i], px[i], px[i + 1]]; }
    else if (colorType === 2) [r, g, b] = [px[i], px[i + 1], px[i + 2]];
    else if (colorType === 0) { [r, g, b] = [px[i], px[i], px[i]]; }
    else if (colorType === 3) {
      const idx = px[i] * 3;
      [r, g, b] = [palette[idx], palette[idx + 1], palette[idx + 2]];
    }
    if (a <= 8) { transparent++; continue; }
    opaque++;
    rSum += r; gSum += g; bSum += b;
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }
}

const hex = (v) => v.toString(16).padStart(2, '0').toUpperCase();
console.log(`${file}: ${width}×${height} depth=${depth} colorType=${colorType} channels=${channels}`);
console.log(
  `不透明像素 ${opaque} / 全透明 ${transparent}（${((opaque / (width * height)) * 100).toFixed(1)}% 有内容）`,
);
if (opaque > 0) {
  console.log(
    `图形外框: x ${minX}..${maxX}  y ${minY}..${maxY}` +
      `（左右留白 ${minX} / ${width - 1 - maxX}，上下 ${minY} / ${height - 1 - maxY}）`,
  );
  console.log(
    `不透明部分平均色: #${hex(Math.round(rSum / opaque))}${hex(Math.round(gSum / opaque))}${hex(Math.round(bSum / opaque))}`,
  );
}
