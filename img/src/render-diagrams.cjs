// img/src/*.html の #fig を PNG（2 倍）に書き出す。出力は img/<名前>.png
// AWS Deep Cuts 用。元は Kenta-Matsuda/slide-template の tools/render-diagrams.cjs
// 使い方: node render-diagrams.cjs <chrome のパス> [名前 ...]
//   例) node render-diagrams.cjs "C:/Program Files/Google/Chrome/Application/chrome.exe"
//   例) node render-diagrams.cjs /usr/bin/chromium architecture
// body に data-transparent="1" を付けると背景を透明にする
// 図の外周には、見やすさのために余白（既定 32px）を付けて書き出す。
// body に data-margin="0" のように書くと、図ごとに余白を変えられる
const path = require('path');
const fs = require('fs');
const puppeteer = require('puppeteer-core');

const [, , browserPath, ...names] = process.argv;
if (!browserPath) { console.error('使い方: node render-diagrams.cjs <chrome のパス> [名前 ...]'); process.exit(2); }
const srcDir = __dirname;
const outDir = path.resolve(srcDir, '..');
const files = names.length ? names.map((n) => n + '.html') : fs.readdirSync(srcDir).filter((f) => f.endsWith('.html'));

(async () => {
  const args = ['--allow-file-access-from-files'];
  if (process.platform === 'linux') args.push('--no-sandbox');
  const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
  if (proxy) args.push(`--proxy-server=${proxy}`);
  const browser = await puppeteer.launch({ executablePath: browserPath, headless: true, args });
  const page = await browser.newPage();
  await page.setViewport({ width: 1400, height: 900, deviceScaleFactor: 2 });
  for (const f of files) {
    await page.goto('file://' + path.join(srcDir, f).replace(/\\/g, '/'), { waitUntil: 'networkidle0' });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() => document.body.dataset.ready === '1', { timeout: 15000 });
    const margin = await page.evaluate(() => {
      const m = Number(document.body.dataset.margin ?? 32);
      document.body.style.padding = m + 'px';
      return m;
    });
    const fig = await page.$('#fig');
    const box = await fig.boundingBox();
    const out = path.join(outDir, f.replace(/\.html$/, '.png'));
    const transparent = await page.evaluate(() => document.body.dataset.transparent === '1');
    await page.screenshot({
      path: out,
      omitBackground: transparent,
      captureBeyondViewport: true,
      clip: { x: box.x - margin, y: box.y - margin, width: box.width + margin * 2, height: box.height + margin * 2 },
    });
    console.log('wrote', path.relative(process.cwd(), out));
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
