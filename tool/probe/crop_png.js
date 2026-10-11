// Dependency-free PNG helpers for reading device screenshots (Node built-ins only).
// CLI: node crop_png.js <in.png> <out.png> <x> <y> <w> <h> <scale>
//      -> also writes <out.png>.html with the crop as a data URI for the Preview tab
//      (the preview server only serves the html file, not sibling assets).
// Lib: const { decode, encode } = require('./crop_png.js')
const fs = require('fs');
const zlib = require('zlib');

function decode(file) {
  const b = fs.readFileSync(file);
  let off = 8, w = 0, h = 0, colorType = 0, bitDepth = 0;
  const idat = [];
  while (off < b.length) {
    const len = b.readUInt32BE(off);
    const type = b.slice(off + 4, off + 8).toString('latin1');
    const data = b.slice(off + 8, off + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      if (data[12] !== 0) throw new Error('interlaced PNG not supported');
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    off += 12 + len;
  }
  if (bitDepth !== 8) throw new Error('bit depth ' + bitDepth + ' not supported');
  const ch = colorType === 6 ? 4 : colorType === 2 ? 3 : colorType === 0 ? 1 : -1;
  if (ch < 0) throw new Error('color type ' + colorType + ' not supported');
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * ch;
  const out = Buffer.alloc(h * stride);
  let prev = Buffer.alloc(stride);
  const paeth = (a, b2, c) => {
    const p = a + b2 - c, pa = Math.abs(p - a), pb = Math.abs(p - b2), pc = Math.abs(p - c);
    return pa <= pb && pa <= pc ? a : pb <= pc ? b2 : c;
  };
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)];
    const src = raw.slice(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const dst = out.slice(y * stride, (y + 1) * stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= ch ? dst[i - ch] : 0, up = prev[i], c = i >= ch ? prev[i - ch] : 0;
      let v = src[i];
      if (f === 1) v += a; else if (f === 2) v += up; else if (f === 3) v += (a + up) >> 1;
      else if (f === 4) v += paeth(a, up, c);
      dst[i] = v & 0xff;
    }
    prev = dst;
  }
  return { w, h, ch, px: out };
}

function encode(w, h, ch, px) {
  const colorType = ch === 4 ? 6 : ch === 3 ? 2 : 0;
  const stride = w * ch;
  const raw = Buffer.alloc(h * (stride + 1));
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;
    px.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const crcTable = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crcTable[n] = c >>> 0;
  }
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
    const crcBuf = Buffer.alloc(4);
    crcBuf.writeUInt32BE(crc(body));
    return Buffer.concat([len, body, crcBuf]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = colorType;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function crop(img, x, y, w, h, scale) {
  const cw = w * scale, chh = h * scale;
  const out = Buffer.alloc(cw * chh * img.ch);
  for (let yy = 0; yy < h; yy++) {
    for (let xx = 0; xx < w; xx++) {
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          const di = ((yy * scale + sy) * cw + xx * scale + sx) * img.ch;
          const si = ((y + yy) * img.w + (x + xx)) * img.ch;
          img.px.copy(out, di, si, si + img.ch);
        }
      }
    }
  }
  return out;
}

function main() {
  const [input, output, xs, ys, ws, hs, ss] = process.argv.slice(2);
  const x = +xs, y = +ys, w = +ws, h = +hs, scale = +(ss || 1);
  const img = decode(input);
  if (x + w > img.w || y + h > img.h) throw new Error('crop out of bounds');
  const out = crop(img, x, y, w, h, scale);
  const png = encode(w * scale, h * scale, img.ch, out);
  fs.writeFileSync(output, png);
  fs.writeFileSync(output + '.html',
    '<!doctype html><meta charset="utf-8"><body style="margin:0;background:#222">' +
    '<img style="image-rendering:pixelated" src="data:image/png;base64,' + png.toString('base64') + '">');
  console.log(JSON.stringify({ source: img.w + 'x' + img.h, crop: `${x},${y} ${w}x${h}`, out: `${w * scale}x${h * scale}`, bytes: png.length, html: output + '.html' }));
}

module.exports = { decode, encode, crop };

if (require.main === module) main();
