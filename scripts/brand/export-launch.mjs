// Campaign cards: exact existing vector identity, no raster image editing.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const out = path.join(root, 'assets/social/2026-10-01');
const require = createRequire(import.meta.url);
let sharp;
try { sharp = require('sharp'); } catch {
  if (!process.env.AIME_BRAND_NODE_MODULES) throw new Error('Provide sharp via AIME_BRAND_NODE_MODULES');
  sharp = require(path.join(process.env.AIME_BRAND_NODE_MODULES, 'sharp'));
}
const tokens = JSON.parse(await fs.readFile(path.join(root, 'assets/brand/aime/base-v1/tokens.json'), 'utf8'));
const type = JSON.parse(await fs.readFile(path.join(out, 'type-outlines.json'), 'utf8'));
const lockup = await fs.readFile(path.join(root, 'assets/brand/aime/base-v1/lockup-color.svg'), 'utf8');
const lockupBody = lockup.replace(/^[\s\S]*?<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '');
const c = tokens.colors;
const escape = s => s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
const placements = [];
function text(key, x, y, color = c.ink) {
  const t = type[key];
  placements.push({key, text: t.text, x, y, width: t.width, size: t.size});
  return `<path aria-label="${escape(t.text)}" transform="translate(${x} ${y})" fill="${color}" d="${t.d}"/>`;
}
function card(width, height, english) {
  placements.length = 0;
  const right = width - 64;
  const markX = width - 290;
  let body = `<rect width="${width}" height="${height}" fill="${c.paper}"/>`;
  body += `<g transform="translate(62 35) scale(.48)">${lockupBody}</g>`;
  const key = name => english ? `${name}En` : name;
  body += text(key('preview'), right - type[key('preview')].width, 82);
  body += text(key('headline1'), 76, 258);
  body += text(key('headline2'), 76, 342);
  body += text(key('category'), 80, 411);
  body += text(key('values'), 80, 458);
  body += `<path data-mark-id="bookmark-v1" transform="translate(${markX} 219) scale(1.68)" fill="${c.vermilion}" d="${tokens.mark.path}"/>`;
  body += `<path d="M80 ${height - 108} H${right}" fill="none" stroke="${c.sand}" stroke-width="1"/>`;
  body += text('url', 80, height - 59);
  body += text(key('tagline'), right - type[key('tagline')].width, height - 59);
  for (const p of placements) {
    if (p.x < 64 || p.x + p.width > width - 64 || p.y - p.size < 35 || p.y > height - 35) throw new Error(`Out of bounds: ${p.key}`);
  }
  const title = english ? 'AIME: Some words, better typed in quiet.' : 'AIME：有些话，适合静静打出来。';
  const description = english ? 'Open-source Chinese input for macOS, built on RIME; local input, optional AI and vocabulary subscriptions; developer preview.' : '基于 RIME 的开源 macOS 中文输入法，本地输入，按需 AI，词库订阅更新；0.1.x 开发预览。';
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img"><title>${title}</title><desc>${description}</desc>${body}</svg>\n`;
  return {svg, placements: [...placements]};
}
const result = [];
for (const [name, width, height, english] of [['github-social', 1280, 640, false], ['x-social', 1200, 630, false], ['github-social-en', 1280, 640, true], ['x-social-en', 1200, 630, true]]) {
  const {svg, placements: bounds} = card(width, height, english);
  await fs.writeFile(path.join(out, `${name}.svg`), svg);
  await sharp(Buffer.from(svg)).png().toFile(path.join(out, `${name}.png`));
  const meta = await sharp(path.join(out, `${name}.png`)).metadata();
  if (meta.width !== width || meta.height !== height) throw new Error('Wrong output size');
  result.push({name, width, height, bounds, result: 'PASS'});
}
await fs.writeFile(path.join(out, 'layout-verification.json'), JSON.stringify(result, null, 2) + '\n');
console.log('PASS: four bilingual GitHub/X cards; vector identity preserved; all text inside safe margins');
