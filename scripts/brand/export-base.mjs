// Deterministic SVG/PNG base assets. No processing of generated reference images.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const out = path.join(root, 'assets/brand/aime/base-v1');
const require = createRequire(import.meta.url);
let sharp;
try { sharp = require('sharp'); } catch {
  if (!process.env.AIME_BRAND_NODE_MODULES) throw new Error('Provide sharp via AIME_BRAND_NODE_MODULES or local node_modules');
  sharp = require(path.join(process.env.AIME_BRAND_NODE_MODULES, 'sharp'));
}
const tokens = JSON.parse(await fs.readFile(path.join(out, 'tokens.json'), 'utf8'));
const type = JSON.parse(await fs.readFile(path.join(out, 'type-outlines.json'), 'utf8'));
const c = tokens.colors;
const esc = s => String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
const mark = (x,y,s,color) => `<path data-mark-id="bookmark-v1" transform="translate(${x} ${y}) scale(${s})" fill="${color}" d="${tokens.mark.path}"/>`;
const latin = (x,y,s,color) => `<g aria-label="AIME" transform="translate(${x} ${y}) scale(${s})" fill="none" stroke="${color}" stroke-width="${tokens.latinWordmark.strokeWidth}" stroke-linecap="round" stroke-linejoin="round">${tokens.latinWordmark.paths.map(d=>`<path d="${d}"/>`).join('')}</g>`;
const txt = (key,x,y,color=c.ink,s=1) => `<path aria-label="${esc(type[key].text)}" transform="translate(${x} ${y}) scale(${s})" fill="${color}" d="${type[key].d}"/>`;
const rect = (x,y,w,h,r,color) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="${color}"/>`;
const svg = (w,h,body,title) => `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img"><title>${esc(title)}</title>${body}</svg>\n`;
async function save(name,markup,width,height) {
  await fs.writeFile(path.join(out,name+'.svg'),markup);
  await sharp(Buffer.from(markup)).resize(width,height).png().toFile(path.join(out,name+'.png'));
}
function lockup(markColor,textColor,bg) {
  return (bg?rect(0,0,542,200,22,bg):'')+mark(28,28,1.2,markColor)+latin(184,28,1.3,textColor)+txt('name',184,172,textColor);
}
await save('mark-vermilion',svg(144,164,mark(22,22,1,c.vermilion),'AIME 独立字签朱红'),576,656);
await save('mark-black',svg(144,164,mark(22,22,1,c.black),'AIME 独立字签黑色'),576,656);
await save('mark-white',svg(144,164,mark(22,22,1,c.white),'AIME 独立字签白色'),576,656);
await save('lockup-color',svg(542,200,lockup(c.vermilion,c.ink),'AIME 彩色横向组合'),1084,400);
await save('lockup-black',svg(542,200,lockup(c.black,c.black),'AIME 黑色横向组合'),1084,400);
await save('lockup-white',svg(542,200,lockup(c.white,c.white),'AIME 白色横向组合'),1084,400);
await save('lockup-reversed',svg(542,200,lockup(c.white,c.white,c.black),'AIME 黑底白标矩形组合'),1084,400);
const square = tokens.square;
for (const [name,bg,fg] of [['square-black',c.black,c.white],['square-white',c.white,c.black],['square-paper',c.paper,c.vermilion]]) {
  const body=rect(0,0,square.canvas,square.canvas,square.radius,bg)+mark(square.markX,square.markY,square.markWidth/tokens.mark.width,fg);
  await save(name,svg(square.canvas,square.canvas,body,'AIME 正方形图标 '+name),1024,1024);
  await sharp(Buffer.from(svg(square.canvas,square.canvas,body,name))).resize(256,256).png().toFile(path.join(out,name+'-256.png'));
}
await save('app-icon-candidate',svg(128,128,rect(12.8,12.8,102.4,102.4,23,c.paper)+mark(36.8,31.4,.544,c.vermilion),'AIME App图标待接入候选'),1024,1024);
await fs.mkdir(path.join(out,'menu'),{recursive:true});
const menuSpec=tokens.menu;
const menu = fg=>svg(menuSpec.canvasPoints,menuSpec.canvasPoints,mark(menuSpec.markX,menuSpec.markY,menuSpec.markHeight/tokens.mark.height,fg),'AIME 透明菜单栏字签');
await fs.writeFile(path.join(out,'menu','menu-template.svg'),menu(c.black));
for (const n of [16,20,24,32]) for (const scale of [1,2]) {
  const pix=n*scale;
  await sharp(Buffer.from(menu(c.black))).resize(pix,pix).png().toFile(path.join(out,'menu',`menu-${n}@${scale}x.png`));
  await sharp(Buffer.from(menu(c.white))).resize(pix,pix).png().toFile(path.join(out,'menu',`menu-white-${n}@${scale}x.png`));
}
let pattern='';for(let row=0;row<2;row++)for(let col=0;col<6;col++)pattern+=mark(32+col*100,22+row*144,.68,col===5?c.sand:c.vermilion);
await save('pattern-tabs',svg(640,320,rect(0,0,640,320,0,c.paper)+pattern,'AIME 字签重复图案'),1280,640);
await save('tagline',svg(450,80,txt('tagline',16,53),'中文常新，自在表达。'),900,160);
// Small-size contact sheet: assets displayed at native pixel size, with enlarged
// previews only in the lower row. This is an asset review, not macOS UI evidence.
let contact=rect(0,0,1000,440,0,c.paper)+txt('smallLabel',30,42);
const text=(x,y,t,color=c.ink)=>`<text x="${x}" y="${y}" font-family="sans-serif" font-size="14" fill="${color}">${t}</text>`;
for (let i=0;i<4;i++) {
  const n=[16,20,24,32][i], x=38+i*112;
  contact+=mark(x+(32-n)/2,98,13/120*n/16,c.black)+text(x,152,n+'px');
  contact+=rect(500+i*112,80,90,94,10,c.ink)+mark(530+i*112+(32-n)/2,98,13/120*n/16,c.white)+text(523+i*112,152,n+'px',c.white);
  contact+=mark(x,234,.7,c.black)+mark(536+i*112,234,.7,c.white);
}
contact=contact.replace(rect(0,0,1000,440,0,c.paper),rect(0,0,1000,440,0,c.paper)+rect(500,200,468,210,16,c.ink));
await save('small-size-review',svg(1000,440,contact,'AIME 菜单栏单色小尺寸目视板'),1000,440);
// Graphic application references only; these are not product UI screenshots.
let extension=rect(0,0,1600,1020,0,c.paper)+txt('boardTitle',60,65)+txt('webLabel',60,132);
extension+=rect(60,160,1480,240,18,c.white)+`<g transform="translate(90 182) scale(.82)">${lockup(c.vermilion,c.ink)}</g>`+txt('tagline',850,303,c.ink,1.25);
extension+=txt('socialLabel',60,480)+rect(60,512,920,444,22,c.white)+`<g transform="translate(94 535) scale(1.2)">${lockup(c.vermilion,c.ink)}</g>`+txt('tagline',132,865,c.ink,1.2);
extension+=mark(820,552,.82,c.vermilion)+mark(820,693,.82,c.sand);
extension+=txt('stickerLabel',1040,480)+rect(1040,512,206,206,42,c.black)+mark(1088.3,550.9,1.094,c.white)+rect(1280,512,206,206,42,c.white)+mark(1328.3,550.9,1.094,c.black);
extension+=mark(1058,800,.9,c.vermilion)+mark(1214,800,.9,c.ink)+mark(1370,800,.9,c.sand);
await save('extension-board',svg(1600,1020,extension,'AIME 网页/发布/头像图形参照'),1600,1020);
// Base board is regenerated after the optional paper-reference image exists.
let board=rect(0,0,1600,1120,0,c.paper)+txt('boardTitle',60,63)+text(1370,62,'BASE / 1.0');
board+=txt('tagline',60,145,c.ink,1.2)+txt('logoLabel',60,220);
board+=`<g transform="translate(52 245) scale(1.35)">${lockup(c.vermilion,c.ink)}</g>`;
board+=`<g transform="translate(60 546) scale(.72)">${lockup(c.black,c.black)}</g>`;
board+=`<g transform="translate(60 713) scale(.72)">${lockup(c.white,c.white,c.black)}</g>`;
board+=txt('squareLabel',895,220);
for(const [i,bg,fg] of [[0,c.black,c.white],[1,c.white,c.black],[2,c.paper,c.vermilion]]) {
 const x=894+i*202;board+=rect(x,254,172,172,35,bg)+mark(x+40.3,286.5,.914,fg);
}
board+=txt('menuLabel',895,490)+rect(890,516,274,90,14,c.white)+rect(1185,516,294,90,14,c.ink);
for(let i=0;i<3;i++){board+=mark(930+i*74,538,.35,c.black)+mark(1225+i*74,538,.35,c.white);}
board+=txt('paletteLabel',895,672);
for(const [i,color] of [c.vermilion,c.paper,c.ink,c.sand].entries()) {board+=rect(895+i*151,704,130,84,15,color)+text(897+i*151,819,color);}
board+=txt('patternLabel',60,929);
for(let i=0;i<5;i++)board+=mark(60+i*85,953,.53,i===4?c.sand:c.vermilion);
const paperPath=path.join(out,'paper-reference.png');
try {
 const data=await fs.readFile(paperPath);board+=txt('paperLabel',895,884)+`<image x="895" y="914" width="584" height="164" preserveAspectRatio="xMidYMid meet" href="data:image/png;base64,${data.toString('base64')}"/>`;
} catch(error) {if(error.code!=='ENOENT')throw error;}
await save('brand-board',svg(1600,1120,board,'AIME 视觉基底：圆角字签与正方形图标'),1600,1120);
console.log('Exported deterministic SVG/PNG assets, square icons, 16–32pt menu candidates and review boards.');
