// Headless render of a GLB with three.js in Chromium (Playwright).
// Usage: node render/render.cjs MODEL.glb OUT_DIR
// Writes OUT_DIR/front.png and OUT_DIR/oblique.png and prints JSON info.
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  console.error('playwright is not installed. Install it with "npm install playwright" in this folder ' +
    '(or globally) and make a Chromium available ("npx playwright install chromium", or set CHROME_PATH).');
  process.exit(2);
}

const [, , glbPath, outDir] = process.argv;
if (!glbPath || !outDir) {
  console.error('usage: node render/render.cjs MODEL.glb OUT_DIR');
  process.exit(2);
}
const root = path.resolve(__dirname, '..');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.glb': 'model/gltf-binary' };

const server = http.createServer((req, res) => {
  const u = decodeURIComponent(req.url.split('?')[0]);
  let f;
  if (u === '/model.glb') f = path.resolve(glbPath);
  else if (u === '/viewer.html') f = path.join(root, 'render', 'viewer.html');
  else if (u.startsWith('/node_modules/three/')) f = path.join(root, u);
  if (!f || (!f.startsWith(root + path.sep) && f !== path.resolve(glbPath))) { res.writeHead(404); res.end(); return; }
  fs.readFile(f, (err, data) => {
    if (err) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(f)] || 'application/octet-stream' });
    res.end(data);
  });
});

(async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const opts = {
    headless: true,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
      '--ignore-gpu-blocklist', '--disable-dev-shm-usage', '--no-sandbox'],
  };
  if (process.env.CHROME_PATH) opts.executablePath = process.env.CHROME_PATH;
  const browser = await chromium.launch(opts);
  try {
    const page = await browser.newPage();
    page.on('pageerror', (e) => console.error('page exception:', e.message));
    await page.goto(`http://127.0.0.1:${port}/viewer.html`);
    await page.waitForFunction('window.state !== "loading"', null, { timeout: 120000 });
    const st = await page.evaluate('window.state');
    if (st !== 'ready') throw new Error('model load failed: ' + st);
    const info = await page.evaluate('window.modelInfo');
    fs.mkdirSync(outDir, { recursive: true });
    for (const view of ['front', 'oblique']) {
      const url = await page.evaluate((v) => window.renderView(v), { view, h: 1000 });
      fs.writeFileSync(path.join(outDir, view + '.png'), Buffer.from(url.split(',')[1], 'base64'));
    }
    console.log(JSON.stringify(info));
  } finally {
    await browser.close();
    server.close();
  }
})().catch((e) => { console.error(e.message || e); process.exit(1); });
