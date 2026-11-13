// Validate a GLB and render it from the given camera directions (headless Chromium + three.js).
// usage: node render.cjs MODEL.glb OUT_DIR VIEWS.json     (run `npm install` in this folder first)
// A view: {"name": "front", "az": 0, "el": 15, "zoom": 1, "up": [0,1,0], "w": 900, "h": 700}
//   az = degrees from the front (+Z) towards the object's +X, el = degrees above the horizon.
'use strict';
const fs = require('fs'), http = require('http'), path = require('path');
const validator = require('gltf-validator');
const { chromium } = require('playwright');
const [, , glb, outDir, viewsPath] = process.argv;
const views = JSON.parse(fs.readFileSync(viewsPath, 'utf8'));
const html = `<!doctype html><html><head><style>html,body{margin:0}canvas{display:block}</style>
<script type="importmap">{"imports":{"three":"/three/build/three.module.js","three/addons/":"/three/examples/jsm/"}}</script></head><body><script type="module">
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
const r = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true }); r.setPixelRatio(1);
r.toneMapping = THREE.NeutralToneMapping; r.outputColorSpace = THREE.SRGBColorSpace;
r.shadowMap.enabled = true; r.shadowMap.type = THREE.PCFSoftShadowMap; document.body.appendChild(r.domElement);
const scene = new THREE.Scene(); scene.background = new THREE.Color('#d9d7d3');
scene.environment = new THREE.PMREMGenerator(r).fromScene(new RoomEnvironment(), 0.04).texture; scene.environmentIntensity = 0.6;
const key = new THREE.DirectionalLight(0xffffff, 1.5); key.castShadow = true; key.shadow.mapSize.set(2048, 2048);
key.shadow.bias = -0.0002; key.shadow.radius = 5; scene.add(key, key.target);
const desk = new THREE.Mesh(new THREE.PlaneGeometry(6, 6), new THREE.MeshStandardMaterial({ color: '#e6e4e0', roughness: 0.9 }));
desk.rotation.x = -Math.PI / 2; desk.position.y = -0.0002; desk.receiveShadow = true; scene.add(desk);
const cam = new THREE.PerspectiveCamera(32, 1, 0.005, 50); let box; window.state = 'loading';
window.shot = (v) => {
  const W = v.w || 900, H = v.h || 700; r.setSize(W, H); cam.aspect = W / H;
  const c = box.getCenter(new THREE.Vector3()), rad = box.getSize(new THREE.Vector3()).length() / 2;
  const az = THREE.MathUtils.degToRad(v.az || 0), el = THREE.MathUtils.degToRad(v.el ?? 20);
  const d = new THREE.Vector3(Math.sin(az) * Math.cos(el), Math.sin(el), Math.cos(az) * Math.cos(el));
  cam.position.copy(c).addScaledVector(d, rad / Math.tan(THREE.MathUtils.degToRad(cam.fov / 2)) / (v.zoom || 1) * 1.05);
  cam.up.set(...(v.up || [0, 1, 0])); cam.lookAt(c); cam.updateProjectionMatrix();
  const s = rad * 1.6; key.position.set(c.x + s, c.y + 2.2 * s, c.z + 0.9 * s); key.target.position.copy(c);
  Object.assign(key.shadow.camera, { left: -s, right: s, top: s, bottom: -s, near: 0.01, far: 8 * s }); key.shadow.camera.updateProjectionMatrix();
  r.render(scene, cam); return r.domElement.toDataURL('image/png'); };
new GLTFLoader().load('/model.glb', (g) => {
  g.scene.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
  scene.add(g.scene); box = new THREE.Box3().setFromObject(g.scene); window.state = 'ready';
}, undefined, (e) => { window.state = 'error ' + e.message; });
</script></body></html>`;
(async () => {
  const rep = await validator.validateBytes(new Uint8Array(fs.readFileSync(glb)));
  console.log(`validator: errors ${rep.issues.numErrors}, warnings ${rep.issues.numWarnings}, infos ${rep.issues.numInfos}`);
  for (const m of rep.issues.messages.filter((x) => x.severity <= 1).slice(0, 8)) console.log('  ', m.code, m.pointer || '', m.message);
  const three = path.join(__dirname, 'node_modules', 'three');
  const srv = http.createServer((q, s) => {
    const u = decodeURIComponent(q.url.split('?')[0]);
    if (u === '/') { s.writeHead(200, { 'Content-Type': 'text/html' }); return s.end(html); }
    const f = u === '/model.glb' ? path.resolve(glb) : path.join(three, u.replace('/three/', ''));
    if (!f.startsWith(three) && u !== '/model.glb' || !fs.existsSync(f)) { s.writeHead(404); return s.end(); }
    s.writeHead(200, { 'Content-Type': u.endsWith('.glb') ? 'model/gltf-binary' : 'text/javascript' }); s.end(fs.readFileSync(f)); });
  await new Promise((k) => srv.listen(0, '127.0.0.1', k));
  const br = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--no-sandbox'] });
  try {
    const pg = await br.newPage(); pg.on('pageerror', (e) => console.error('page:', e.message));
    await pg.goto(`http://127.0.0.1:${srv.address().port}/`);
    await pg.waitForFunction('window.state !== "loading"', null, { timeout: 120000 });
    if (await pg.evaluate('window.state') !== 'ready') throw new Error(await pg.evaluate('window.state'));
    for (const v of views)
      fs.writeFileSync(path.join(outDir, v.name + '.png'), Buffer.from((await pg.evaluate((x) => window.shot(x), v)).split(',')[1], 'base64'));
    console.log('rendered: ' + views.map((v) => v.name).join(' '));
  } finally { await br.close(); srv.close(); }
  if (rep.issues.numErrors) process.exit(1);
})().catch((e) => { console.error(e.message || e); process.exit(1); });
