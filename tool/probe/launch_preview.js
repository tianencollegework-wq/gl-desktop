// 生成启动屏预览页（把两套新资源按「系统实际会怎么画」模拟出来）。
// 用法：node build/probe/launch_preview.js  → 写 build/probe/launch_preview.html
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const RES = path.join(ROOT, 'android/app/src/main/res');
const b64 = (p) => fs.readFileSync(p).toString('base64');

const flat = b64(path.join(RES, 'mipmap-xxxhdpi/launch_logo.png')); // 400dp 那档
const pad = b64(path.join(RES, 'mipmap-xxxhdpi/launch_logo_pad.png')); // 768 画布 / 476 原图

const html = `<!doctype html><meta charset="utf-8">
<style>
  body{margin:0;background:#e9edf2;font:13px/1.6 -apple-system,system-ui,sans-serif;color:#222}
  h2{font-size:13px;margin:0 0 6px}
  .row{display:flex;gap:18px;padding:18px;flex-wrap:wrap}
  .card{background:#fff;border-radius:10px;padding:12px;box-shadow:0 1px 4px rgba(0,0,0,.12)}
  .tag{color:#666;font-size:12px;margin-top:6px;max-width:220px}
  canvas{display:block;border:1px solid #dfe4ea;border-radius:6px}
</style>
<div class="row">
  <div class="card">
    <h2>① Android 11 及以下 · 原生启动窗口</h2>
    <canvas id="a" width="220" height="380"></canvas>
    <div class="tag">白底 + 原图居中（100dp）。这里是按 220×380 的窗口比例画的近似效果。</div>
  </div>
  <div class="card">
    <h2>② Android 12+ · 系统强制蒙版（真实裁切）</h2>
    <canvas id="b" width="240" height="240"></canvas>
    <div class="tag">画布 240px 代表 288dp 图标区；红色是直径 2/3 的蒙版圆。灰 = 被切掉的透明部分。</div>
  </div>
  <div class="card">
    <h2>③ Android 12+ · 白底上用户实际看到的</h2>
    <canvas id="c" width="240" height="240"></canvas>
    <div class="tag">蒙版内的像素贴到白底启动背景上。</div>
  </div>
  <div class="card">
    <h2>④ 对照：原图直接交给系统（会掉东西）</h2>
    <canvas id="d" width="240" height="240"></canvas>
    <div class="tag">同一蒙版圆，图铺满画布 → 四角和底下那行 GraceLink 被切。</div>
  </div>
</div>
<script>
const FLAT = 'data:image/png;base64,${flat}';
const PAD  = 'data:image/png;base64,${pad}';
const load = (src) => new Promise(r => { const i = new Image(); i.onload = () => r(i); i.src = src; });

(async () => {
  const [flat, pad] = await Promise.all([load(FLAT), load(PAD)]);

  // ① 原生启动窗口：白底 + 居中 100dp 原图（窗口 220×380 近似）
  const a = document.getElementById('a').getContext('2d');
  a.fillStyle = '#fff'; a.fillRect(0, 0, 220, 380);
  const s1 = 100 * 220 / 411; // 411dp 屏宽 → 220px
  a.drawImage(flat, (220 - s1) / 2, (380 - s1) / 2, s1, s1);

  // ② 蒙版模拟：画布 = 图标区，圆直径 = 画布 2/3
  const mask = (ctx, img, size, bg) => {
    const r = size / 3;
    ctx.clearRect(0, 0, size, size);
    ctx.save();
    ctx.beginPath();
    ctx.arc(size / 2, size / 2, r, 0, Math.PI * 2);
    ctx.clip();
    if (bg) { ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, size, size); }
    ctx.drawImage(img, 0, 0, size, size);
    ctx.restore();
    ctx.beginPath();
    ctx.arc(size / 2, size / 2, r, 0, Math.PI * 2);
    ctx.strokeStyle = '#e5484d'; ctx.lineWidth = 1.5; ctx.stroke();
  };
  mask(document.getElementById('b').getContext('2d'), pad, 240, false);
  mask(document.getElementById('c').getContext('2d'), pad, 240, true);
  mask(document.getElementById('d').getContext('2d'), flat, 240, true);
})();
</script>`;

fs.writeFileSync(path.join(__dirname, 'launch_preview.html'), html);
console.log('build/probe/launch_preview.html');
