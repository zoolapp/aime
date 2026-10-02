// Renders assets/video/launch-2026-10-01 frame by frame (headless Chromium → ffmpeg).
// Usage: node scripts/video/render-launch.mjs [--stills 2.5,7,...] [--out dist/video] [--fps 30] [--scale 2]
// Needs playwright-core (AIME_VIDEO_NODE_MODULES or build/video-tools) and a Chromium; never touches user directories.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]?.startsWith('--') ? true : all[i + 1] ?? true]] : acc, []));
const fps = Number(args.fps ?? 30), scale = Number(args.scale ?? 2);
const out = path.resolve(root, args.out ?? 'dist/video');
const name = 'aime-launch-2026-10-01';

const require = createRequire(import.meta.url);
const modules = process.env.AIME_VIDEO_NODE_MODULES ?? path.join(root, 'build/video-tools/node_modules');
const { chromium } = require(path.join(modules, 'playwright-core'));

function findChrome() {
  if (process.env.AIME_CHROME) return process.env.AIME_CHROME;
  const cache = path.join(os.homedir(), 'Library/Caches/ms-playwright');
  // The headless shell paints reliably; full Chrome for Testing returned transparent screenshots here.
  const dirs = fs.readdirSync(cache).filter(d => /^chromium_headless_shell-\d+$/.test(d)).sort((a, b) => +b.split('-')[1] - +a.split('-')[1]);
  for (const d of dirs) {
    for (const bin of ['chrome-headless-shell-mac-arm64/chrome-headless-shell', 'chrome-mac/headless_shell']) {
      const p = path.join(cache, d, bin); if (fs.existsSync(p)) return p;
    }
  }
  throw new Error('No Chromium found; set AIME_CHROME');
}

// Static server: only the film, the brand assets, the screenshots and the pinned font are served.
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.ttf': 'font/ttf' };
const allowed = ['assets/video/', 'assets/brand/', 'assets/screenshots/', 'build/brand-fonts/'].map(d => path.join(root, d));
const server = http.createServer((req, res) => {
  let p;
  try { p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname)); } catch { res.writeHead(400).end(); return; }
  if (!allowed.some(d => p.startsWith(d)) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': types[path.extname(p)] ?? 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/assets/video/launch-2026-10-01/index.html`;

const chrome = findChrome();
console.log(`chromium: ${chrome}`);
const browser = await chromium.launch({ executablePath: chrome });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale });
const external = [];
const local = `http://127.0.0.1:${server.address().port}/`;
// Anything outside the local server is blocked, and the run fails if the page tried.
await page.route('**/*', r => { const u = r.request().url(); if (u.startsWith(local) || u.startsWith('data:')) return r.continue(); external.push(u); return r.abort(); });
page.on('pageerror', e => { console.error('page error:', e.message); process.exitCode = 1; });
await page.goto(url);
await page.evaluate(() => window.__ready);
const duration = await page.evaluate(() => window.__duration);
fs.mkdirSync(out, { recursive: true });

if (args.cues) {
  const file = path.resolve(root, String(args.cues));
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(await page.evaluate(() => window.__cues), null, 1));
  console.log(`cues → ${file}`);
} else if (args.stills) {
  const dir = path.resolve(root, args.stillsOut ?? '.ui-acceptance/2026-10-01-video');
  fs.mkdirSync(dir, { recursive: true });
  for (const t of String(args.stills).split(',').map(Number)) {
    await page.evaluate(t => window.__seek(t), t);
    await page.screenshot({ path: path.join(dir, `still-${t.toFixed(2)}.png`) });
  }
  console.log(`stills → ${dir}`);
} else {
  const frames = Math.round(duration * fps);
  const master = scale >= 2;
  const ff = spawn('ffmpeg', ['-v', 'error', '-y', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
    '-filter_complex', master ? '[0:v]split=2[a][b];[b]scale=1920:1080:flags=lanczos[c]' : '[0:v]scale=1920:1080:flags=lanczos[c]',
    ...(master ? ['-map', '[a]', '-c:v', 'libx264', '-preset', 'slow', '-crf', '14', '-tune', 'animation', '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-level', '5.1', '-movflags', '+faststart', path.join(out, `${name}-4k-silent.mp4`)] : []),
    '-map', '[c]', '-c:v', 'libx264', '-preset', 'slow', '-crf', '15', '-tune', 'animation', '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-level', '4.2', '-r', String(fps), '-movflags', '+faststart', path.join(out, `${name}-1080p-silent.mp4`)],
    { stdio: ['pipe', 'inherit', 'inherit'] });
  const done = new Promise((r, j) => ff.on('close', c => c ? j(new Error(`ffmpeg ${c}`)) : r()));
  const started = Date.now();
  for (let i = 0; i < frames; i++) {
    await page.evaluate(t => window.__seek(t), i / fps);
    const png = await page.screenshot({ type: 'png' });
    if (!ff.stdin.write(png)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 60 === 0) process.stdout.write(`\rframe ${i}/${frames}  ${((Date.now() - started) / 1000).toFixed(0)}s`);
  }
  ff.stdin.end();
  await done;
  console.log(`\nrendered ${frames} frames → ${out}`);
}
if (external.length) { console.error('external requests:', external); process.exitCode = 1; }
await browser.close();
server.close();
