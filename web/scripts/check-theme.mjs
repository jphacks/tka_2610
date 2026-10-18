// 壁紙と床材（src/three/scenes/home/theme.ts の applyTheme）を、本物の家の建物 GLB（backend/static/models/rooms/）と
// catalog.json（backend/static/home/catalog.json）で当ててみて、材質の作りと当て方を確かめる。
// npm run check:theme で動かす（tsc -p tsconfig.theme-check.json で theme.ts だけを node_modules/.cache/ に出力してから読む）。
// ブラウザも GPU も使わない。画像は読み込まず、ImageLoader を差し替えて「読めた」ことにする（読み終わる順番もここで決める）。
//
//   材質   … どのテーマでも、壁（下・上）と床に catalog のテクスチャの組の材質が付く。色の画像は sRGB、法線と ORM はリニア、
//            flipY = false、RepeatWrapping、repeat = (1 UV の長さ) / tileMeters、法線の向き (1, −1)、ORM を粗さと金属の両方に使う。
//            白壁（plaster）の色の補正は plaster だけ。内装セット（finish-pack）の材質の色は白
//   場所   … 共有する壁の、隣の部屋に向いた面（userData.faceRoom）は隣の部屋の壁紙。床・幅木・土台・枠は建物の部屋のまま／触らない
//   継ぎ目 … 下の壁と上の壁で、テクスチャの v が床からの高さ y / tile_h と同じになる（上下で模様が切れない）
//   競合   … 画像を待っている前のテーマが、あとから頼んだテーマを上書きしない。読めない画像があれば今の材質のまま
//   不変   … 建物の形（頂点・ノードの行列）、GLB の材質、ほかの複製は変わらない。同じテーマの材質は建物どうしで共有する
//
// 環境変数 HOME_ROOM_MODELS_DIR で別の建物の GLB のフォルダを渡せる（サーバーと同じ名前の変数）。
// 違いがあれば最初の 30 件を表示して、終了コードを 1 にする。

import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import * as THREE from 'three'
// アプリと同じ GLTFLoader（drei の useGLTF が使う three-stdlib のもの）。three/addons の GLTFLoader（r186）は
// ノードの extras.pivot を回転の中心として読み替えるので、キットの extras.pivot（"bottom-center" の文字）で位置が NaN になる
import { GLTFLoader } from 'three-stdlib'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '../..')
const modulePath = resolve(here, '../node_modules/.cache/theme-check/src/three/scenes/home/theme.js')
const catalogPath = resolve(repo, 'backend/static/home/catalog.json')
const texturesDir = resolve(repo, 'backend/static/home/textures')
const roomsDir = process.env.HOME_ROOM_MODELS_DIR
  ? resolve(process.cwd(), process.env.HOME_ROOM_MODELS_DIR)
  : resolve(repo, 'backend/static/models/rooms')

if (!existsSync(modulePath)) {
  console.error(`[check:theme] ${modulePath} がありません。先に tsc -p tsconfig.theme-check.json を実行してください`)
  process.exit(1)
}

const errors = []
const fail = (message) => errors.push(message)
const close = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps
const frac = (n) => n - Math.floor(n)
/** 整数との差（0〜0.5） */
const offInt = (n) => Math.min(frac(n), 1 - frac(n))

// ---------- 画像の読み込みを差し替える（theme.ts が読む前に） ----------

/** 読み込みを止めておく URL → そのときの読み終わり（done）・失敗（error） */
const held = new Map()
const holding = new Set()
const requested = []
THREE.ImageLoader.prototype.load = function load(url, onLoad, _onProgress, onError) {
  requested.push(url)
  const image = { width: 1024, height: 1024, url }
  const done = () => onLoad(image)
  if (holding.has(url)) held.set(url, { done, error: () => onError(new Error(`held: ${url}`)) })
  else queueMicrotask(done)
  return image
}
// 建物の GLB に入っている画像も同じ差し替えで「読めた」ことにする（GLTFLoader は self.URL で blob の URL を作る）
globalThis.self ??= globalThis
const settle = () => new Promise((r) => setTimeout(r, 0))
async function release(urls, how = 'done') {
  for (const url of urls) {
    const h = held.get(url)
    if (!h) fail(`止めていない画像を読み終えようとしました: ${url}`)
    else {
      held.delete(url)
      holding.delete(url)
      h[how]()
    }
  }
  await settle()
}

// 読めない画像を試す (d) で theme.ts が出す警告は、わざと失敗させたものなので数えるだけにする
let expectedWarnings = 0
const warn = console.warn
console.warn = (...args) => {
  if (String(args[0]).includes('テーマのテクスチャを読み込めませんでした') && String(args[0]).includes('brick_base.jpg')) expectedWarnings++
  else warn(...args)
}

const { applyTheme, preloadTheme } = await import(pathToFileURL(modulePath).href)

// ---------- catalog（サーバーの /api/museum の catalog と同じ形にする。museum_api.rs の CATALOG_VIEW） ----------

const catalog = JSON.parse(readFileSync(catalogPath, 'utf8'))
const materials = {}
for (const [id, m] of Object.entries(catalog.materials)) {
  for (const file of [m.baseColor, m.normal, m.orm]) {
    if (!existsSync(resolve(texturesDir, file))) fail(`素材 ${id} の画像 ${file} がありません`)
  }
  const url = (file) => `/home-assets/textures/${file}`
  materials[id] = { tile_meters: m.tileMeters, base_url: url(m.baseColor), normal_url: url(m.normal), orm_url: url(m.orm) }
}
const themes = catalog.themes
const FINISH_PACK_THEMES = ['nordic_oak', 'sage_ash', 'white_marble', 'dark_marble', 'brick_oak', 'walnut_cream']
const themeOf = (id) => {
  const t = themes.find((x) => x.id === id)
  if (!t) throw new Error(`テーマ ${id} が catalog.json にありません`)
  return { wall: t.wall, floor: t.floor }
}
for (const id of FINISH_PACK_THEMES) themeOf(id)

// theme.ts の対応と同じ（キットの名前だけ素材の id と違う。内装セットは同じ）
const WALL_TEXTURE = { plaster: 'plaster', oak: 'oak_wall', brick: 'brick', limestone: 'limestone' }
const FLOOR_TEXTURE = { oak: 'oak_floor', limestone: 'limestone' }
const WALL_BAKED = { plaster: 'Wall_Plaster', oak: 'Wall_Oak', brick: 'Wall_Brick', limestone: 'Wall_Limestone' }
const FLOOR_BAKED = { oak: 'Floor_Oak', limestone: 'Floor_Limestone' }
const FINISH_PACK = new Set(
  Object.entries(catalog.materials)
    .filter(([, m]) => m.baseColor.startsWith('finish-pack/'))
    .map(([id]) => id),
)
const UV = { wall_lower: { unit: 1, center: 0.46 }, wall_upper: { unit: 1, center: 2.56 }, floor: { unit: 2, center: null } }
const PARTS = new Set(Object.keys(UV))

// ---------- 建物の GLB ----------

// リビング（hub）は必ず要る。左・右・前の部屋は、GLB があるときだけ調べる（今の家はリビングだけ）
const ROOM_IDS = ['hub', 'left', 'right', 'front'].filter((id) => id === 'hub' || existsSync(resolve(roomsDir, `${id}.glb`)))
/** リビングと壁を共有する部屋（共有の壁の面 faceRoom を調べる。リビングだけの家では空） */
const SIDE_ROOMS = ROOM_IDS.filter((id) => id !== 'hub')
/** 競合を試す建物（部屋が足りなければリビングを複製して使う） */
const roomAt = (i) => ROOM_IDS[i % ROOM_IDS.length]
const loader = new GLTFLoader()
const glbs = {}
for (const id of ROOM_IDS) {
  const file = resolve(roomsDir, `${id}.glb`)
  if (!existsSync(file)) {
    console.error(`[check:theme] ${file} がありません`)
    process.exit(1)
  }
  const buf = readFileSync(file)
  const gltf = await loader.parseAsync(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), '')
  glbs[id] = gltf.scene
}

/** MuseumModel と同じく、GLB の scene を複製して使う（メッシュは別、材質と形は GLB のものを共有） */
function cloneRoom(id) {
  const root = glbs[id].clone(true)
  root.updateMatrixWorld(true)
  return root
}
function meshesOf(root) {
  const list = []
  root.traverse((o) => {
    if (o.isMesh) list.push(o)
  })
  return list
}

/** GLB の材質と形の控え（最後に、何も書き換わっていないことを確かめる） */
function snapshot(root) {
  return meshesOf(root).map((mesh) => {
    const mats = Array.isArray(mesh.material) ? mesh.material : [mesh.material]
    return {
      mesh,
      material: mesh.material,
      props: mats.map((m) => JSON.stringify([m.name, m.color?.getHexString(), m.roughness, m.metalness, m.map?.uuid ?? null])),
      position: Array.from(mesh.geometry.attributes.position.array),
      uv: Array.from(mesh.geometry.attributes.uv?.array ?? []),
      matrix: mesh.matrixWorld.toArray(),
    }
  })
}
function sameAsSnapshot(snap, label, { materials: checkMaterial = true } = {}) {
  for (const s of snap) {
    const mats = Array.isArray(s.material) ? s.material : [s.material]
    const props = mats.map((m) => JSON.stringify([m.name, m.color?.getHexString(), m.roughness, m.metalness, m.map?.uuid ?? null]))
    if (checkMaterial && s.mesh.material !== s.material) fail(`${label}: ${s.mesh.name} の材質が替わりました`)
    if (props.join() !== s.props.join()) fail(`${label}: ${s.mesh.name} の GLB の材質が書き換わりました`)
    if (Array.from(s.mesh.geometry.attributes.position.array).join() !== s.position.join()) fail(`${label}: ${s.mesh.name} の頂点が変わりました`)
    if (Array.from(s.mesh.geometry.attributes.uv?.array ?? []).join() !== s.uv.join()) fail(`${label}: ${s.mesh.name} の UV が変わりました`)
    s.mesh.updateMatrixWorld(true)
    if (s.mesh.matrixWorld.toArray().join() !== s.matrix.join()) fail(`${label}: ${s.mesh.name} の位置が変わりました`)
  }
}
const glbSnapshots = Object.fromEntries(ROOM_IDS.map((id) => [id, snapshot(glbs[id])]))

/** メッシュに付くはずのテクスチャの組（null は GLB の材質のまま） */
function expectedSet(roomId, mesh, rooms, original) {
  const part = mesh.userData.role
  const face = part === 'floor' ? undefined : mesh.userData.faceRoom
  const own = (typeof face === 'string' && rooms[face]) || rooms[roomId]
  const isFloor = part === 'floor'
  const name = isFloor ? own.floor : own.wall
  const baked = isFloor ? FLOOR_BAKED[name] : WALL_BAKED[name]
  if (baked !== undefined && original.name === baked) return null
  return isFloor ? (FLOOR_TEXTURE[name] ?? name) : (WALL_TEXTURE[name] ?? name)
}

/** 材質 material が、テクスチャの組 setId を場所 part に貼る正しい作りか */
function checkMaterial(material, setId, part, label) {
  const def = materials[setId]
  if (material.name !== `Theme_${setId}_${part}`) {
    fail(`${label}: 材質 ${material.name}（${setId} の ${part} のはず）`)
    return
  }
  const [tileW, tileH] = def.tile_meters
  const { unit, center } = UV[part]
  const repeat = [unit / tileW, unit / tileH]
  const offsetY = center === null ? 0 : frac(center / tileH)
  const textures = { map: material.map, normalMap: material.normalMap, roughnessMap: material.roughnessMap, metalnessMap: material.metalnessMap }
  for (const [key, t] of Object.entries(textures)) {
    if (!t) {
      fail(`${label}: ${key} がありません`)
      continue
    }
    const color = key === 'map'
    if (t.colorSpace !== (color ? THREE.SRGBColorSpace : THREE.NoColorSpace)) fail(`${label}: ${key} の色空間 ${t.colorSpace}`)
    if (t.flipY !== false) fail(`${label}: ${key} の flipY が false ではありません`)
    if (t.wrapS !== THREE.RepeatWrapping || t.wrapT !== THREE.RepeatWrapping) fail(`${label}: ${key} が RepeatWrapping ではありません`)
    if (!close(t.repeat.x, repeat[0]) || !close(t.repeat.y, repeat[1])) fail(`${label}: ${key} の repeat (${t.repeat.x}, ${t.repeat.y}) ≠ (${repeat})`)
    if (!close(t.offset.x, 0) || !close(t.offset.y, offsetY)) fail(`${label}: ${key} の offset (${t.offset.x}, ${t.offset.y}) ≠ (0, ${offsetY})`)
    const url = color ? def.base_url : key === 'normalMap' ? def.normal_url : def.orm_url
    if (t.source?.data?.url !== url) fail(`${label}: ${key} の画像 ${t.source?.data?.url}（${url} のはず）`)
  }
  if (material.roughnessMap !== material.metalnessMap) fail(`${label}: ORM を粗さと金属の両方に使っていません`)
  if (material.roughness !== 1 || material.metalness !== 0) fail(`${label}: roughness ${material.roughness} / metalness ${material.metalness}`)
  if (!close(material.normalScale.x, 1) || !close(material.normalScale.y, -1)) fail(`${label}: normalScale (${material.normalScale.x}, ${material.normalScale.y})`)
  if (material.aoMap) fail(`${label}: aoMap は使わない`)
  const want = setId === 'plaster' ? [0.9, 0.88, 0.83] : [1, 1, 1]
  const c = material.color
  if (!close(c.r, want[0]) || !close(c.g, want[1]) || !close(c.b, want[2])) fail(`${label}: 色 (${c.r}, ${c.g}, ${c.b}) ≠ (${want})`)
  if (FINISH_PACK.has(setId) && !(c.r === 1 && c.g === 1 && c.b === 1)) fail(`${label}: 内装セットの材質の色が白ではありません`)
}

/**
 * 継ぎ目：壁の表と裏（UV が v = y − 中心の高さ の面）で、テクスチャの v（uv.v × repeat.y + offset.y）が y / tile_h と
 * 整数の差しかないか。上下の壁の境目（y = 0.92）の頂点がどちらにもあることも確かめる。合わない面（出入口の側面など）は数えるだけ
 */
const seamCount = { lower: 0, upper: 0, checked: 0, other: 0 }
function checkSeam(mesh, material, part, label) {
  if (part === 'floor') return
  const { center } = UV[part]
  const pos = mesh.geometry.attributes.position
  const uv = mesh.geometry.attributes.uv
  const normal = mesh.geometry.attributes.normal
  const tileH = 1 / material.map.repeat.y
  const v3 = new THREE.Vector3()
  const n3 = new THREE.Vector3()
  const normalMatrix = new THREE.Matrix3().getNormalMatrix(mesh.matrixWorld)
  for (let i = 0; i < pos.count; i++) {
    v3.fromBufferAttribute(pos, i).applyMatrix4(mesh.matrixWorld)
    n3.fromBufferAttribute(normal, i).applyMatrix3(normalMatrix).normalize()
    const v = uv.getY(i)
    if (Math.abs(n3.y) > 0.01 || Math.abs(v - (v3.y - center)) > 1e-4) {
      seamCount.other++
      continue
    }
    seamCount.checked++
    const t = v * material.map.repeat.y + material.map.offset.y
    if (offInt(t - v3.y / tileH) > 1e-4) fail(`${label}: y = ${v3.y.toFixed(3)} でテクスチャの v が床からずれています（${t} と ${v3.y / tileH}）`)
    if (close(v3.y, 0.92, 1e-4)) seamCount[part === 'wall_lower' ? 'lower' : 'upper']++
  }
}

/** 部屋ごとの仕上げ rooms を、ある部屋の建物（ROOM_IDS）に当てて、全部のメッシュを確かめる */
async function applyAll(rooms, label) {
  const roots = Object.fromEntries(ROOM_IDS.map((id) => [id, cloneRoom(id)]))
  const originals = Object.fromEntries(ROOM_IDS.map((id) => [id, new Map(meshesOf(roots[id]).map((m) => [m, m.material]))]))
  const snaps = Object.fromEntries(ROOM_IDS.map((id) => [id, snapshot(roots[id])]))
  for (const id of ROOM_IDS) preloadTheme(rooms[id], materials)
  let late = 0
  for (const id of ROOM_IDS) applyTheme(roots[id], rooms[id], materials, { faceRooms: rooms, onLate: () => late++ })
  await settle()
  const used = new Map()
  for (const id of ROOM_IDS) {
    for (const mesh of meshesOf(roots[id])) {
      const original = originals[id].get(mesh)
      const where = `${label} ${id}/${mesh.name}`
      if (!PARTS.has(mesh.userData.role)) {
        if (mesh.material !== original) fail(`${where}（${mesh.userData.role}）: 壁と床のほかの材質が替わりました`)
        continue
      }
      const set = expectedSet(id, mesh, rooms, original)
      if (set === null) {
        if (mesh.material !== original) fail(`${where}: 焼き込みと同じ素材なのに GLB の材質ではありません（${mesh.material.name}）`)
        continue
      }
      checkMaterial(mesh.material, set, mesh.userData.role, where)
      checkSeam(mesh, mesh.material, mesh.userData.role, where)
      const key = `${set}:${mesh.userData.role}`
      if (used.has(key) && used.get(key) !== mesh.material) fail(`${where}: 同じ素材と場所なのに別の材質です（${key}）`)
      used.set(key, mesh.material)
    }
    // 形と位置は変わらない（材質は替えるので見ない）。GLB の材質そのものも書き換えない
    sameAsSnapshot(snaps[id], `${label} ${id}`, { materials: false })
  }
  return { roots, late, used }
}

// ---------- 1. 連続して切り替えたときの競合（画像をまだ読んでいないテーマで先に試す） ----------

{
  const urlsOfFinish = (f) => {
    const sets = [WALL_TEXTURE[f.wall] ?? f.wall, FLOOR_TEXTURE[f.floor] ?? f.floor]
    return sets.flatMap((s) => [materials[s].base_url, materials[s].normal_url, materials[s].orm_url])
  }
  /** f の画像のうち、まだ読んでいないものを止める（止めた URL を返す。全部読んであれば試せないので違いにする） */
  const hold = (f) => {
    const urls = urlsOfFinish(f).filter((u) => !requested.includes(u))
    if (urls.length === 0) fail(`競合: ${f.wall} / ${f.floor} の画像はもう読んであるので、待たせられません`)
    for (const u of urls) holding.add(u)
    return urls
  }
  const wallName = (root) => meshesOf(root).find((m) => m.userData.role === 'wall_lower' && !m.userData.faceRoom).material.name
  const floorName = (root) => meshesOf(root).find((m) => m.userData.role === 'floor').material.name

  // (a) 前のテーマ A を待っている間に B を選ぶ。B が先に読めて、あとから A が読めても B のまま
  const root = cloneRoom('hub')
  const A = themeOf('sage_ash')
  const B = themeOf('walnut_cream')
  const heldA = hold(A)
  let lateA = 0
  let lateB = 0
  applyTheme(root, A, materials, { onLate: () => lateA++ })
  await settle()
  if (wallName(root) !== 'Wall_Plaster') fail(`競合 (a): 画像を待つ間に材質が替わりました（${wallName(root)}）`)
  applyTheme(root, B, materials, { onLate: () => lateB++ })
  await settle()
  if (wallName(root) !== 'Theme_warm_cream_wall_lower' || floorName(root) !== 'Theme_warm_walnut_floor') {
    fail(`競合 (a): あとから選んだテーマになっていません（${wallName(root)} / ${floorName(root)}）`)
  }
  await release(heldA)
  if (wallName(root) !== 'Theme_warm_cream_wall_lower' || floorName(root) !== 'Theme_warm_walnut_floor') {
    fail(`競合 (a): 遅れて読めた前のテーマに戻りました（${wallName(root)} / ${floorName(root)}）`)
  }
  if (lateA !== 0 || lateB !== 1) fail(`競合 (a): onLate の回数 A ${lateA}・B ${lateB}（0 と 1 のはず）`)

  // (b) C と D を両方待つ。D（あと）が先に読め、C（前）があとで読めても D のまま
  const root2 = cloneRoom(roomAt(1))
  const C = themeOf('dark_marble')
  const D = themeOf('brick_oak')
  const heldC = hold(C)
  const heldD = hold(D)
  applyTheme(root2, C, materials)
  applyTheme(root2, D, materials)
  await release(heldD)
  if (wallName(root2) !== 'Theme_soft_brick_wall_lower' || floorName(root2) !== 'Theme_white_oak_floor') fail(`競合 (b): D になっていません（${wallName(root2)}）`)
  await release(heldC)
  if (wallName(root2) !== 'Theme_soft_brick_wall_lower') fail(`競合 (b): 前のテーマ C に戻りました（${wallName(root2)}）`)

  // (c) E を待つ間に、焼き込みと同じナチュラル（画像を待たない）を選ぶ。E が読めても GLB の材質のまま
  const root3 = cloneRoom(roomAt(2))
  const E = themeOf('white_marble')
  const heldE = hold(E)
  applyTheme(root3, E, materials)
  applyTheme(root3, themeOf('natural'), materials)
  await settle()
  await release(heldE)
  if (wallName(root3) !== 'Wall_Plaster' || floorName(root3) !== 'Floor_Oak') fail(`競合 (c): ナチュラルのはずが ${wallName(root3)} / ${floorName(root3)}`)

  // (d) 読めない画像があるテーマは当てない（今の材質のまま）。もう一度選ぶと読み直す
  // （内装セットの画像は (a)〜(c) で全部読んだので、まだ読んでいないキットのレンガで試す）
  const root4 = cloneRoom(roomAt(3))
  applyTheme(root4, themeOf('nordic_oak'), materials)
  await settle()
  const F = themeOf('brick')
  const heldF = hold(F)
  applyTheme(root4, F, materials)
  await release(heldF.slice(0, 1), 'error')
  await release(heldF.slice(1))
  if (wallName(root4) !== 'Theme_nordic_chalk_wall_lower') fail(`読めない画像 (d): 今の材質のままのはずが ${wallName(root4)}`)
  const before = requested.length
  applyTheme(root4, F, materials)
  await settle()
  if (!requested.slice(before).includes(heldF[0])) fail('読めない画像 (d): もう一度選んでも読み直しませんでした')
  if (wallName(root4) !== 'Theme_brick_wall_lower' || floorName(root4) !== 'Theme_limestone_floor') fail(`読めない画像 (d): 読み直したあとも ${wallName(root4)}`)
}

// ---------- 2. どのテーマも、どの部屋に当てても材質・場所・継ぎ目が正しい ----------

const all = themes.map((t) => t.id)
for (const id of all) {
  const f = themeOf(id)
  await applyAll(Object.fromEntries(ROOM_IDS.map((r) => [r, f])), `テーマ ${id}`)
}

// ---------- 3. 部屋ごとに別のテーマ：共有する壁の表と裏 ----------

const mixes = [
  { hub: 'nordic_oak', left: 'sage_ash', right: 'dark_marble', front: 'brick_oak' },
  { hub: 'walnut_cream', left: 'white_marble', right: 'natural', front: 'timber' },
  { hub: 'natural', left: 'brick', right: 'walnut_cream', front: 'dark_marble' },
]
for (const mix of mixes) {
  const rooms = Object.fromEntries(ROOM_IDS.map((r) => [r, themeOf(mix[r])]))
  const { roots } = await applyAll(rooms, `部屋ごと ${Object.values(mix).join('/')}`)
  // リビングの共有する壁：隣の部屋に向いた面（faceRoom）は隣の部屋の壁紙、リビング側の面はリビングの壁紙
  const hubWalls = meshesOf(roots.hub).filter((m) => m.userData.role === 'wall_lower' || m.userData.role === 'wall_upper')
  for (const face of SIDE_ROOMS) {
    const outer = hubWalls.filter((m) => m.userData.faceRoom === face)
    if (outer.length === 0) fail(`リビングに ${face} に向いた壁の面（faceRoom）がありません`)
    for (const m of outer) {
      const want = WALL_TEXTURE[rooms[face].wall] ?? rooms[face].wall
      const isOriginal = rooms[face].wall === 'plaster'
      if (isOriginal ? m.material.name !== 'Wall_Plaster' : !m.material.name.startsWith(`Theme_${want}_`)) {
        fail(`共有の壁 ${m.name}（${face} 向き）: ${m.material.name}（${rooms[face].wall} のはず）`)
      }
    }
  }
}

// 共有する壁の面の向き：faceRoom の面は、壁の中心線より隣の部屋の側にある（表裏が入れ替わっていない）
{
  const root = cloneRoom('hub')
  const box = new THREE.Box3()
  const c = new THREE.Vector3()
  // 壁の中心線 = リビングの内寸の半分 + 壁の厚さの半分（内寸は GLB のルートの extras.dimensionsMeters。10 m なら ±5.12）
  let dims = null
  root.traverse((o) => {
    if (!dims && Array.isArray(o.userData.dimensionsMeters)) dims = o.userData.dimensionsMeters
  })
  if (!dims) fail('リビングの GLB に extras.dimensionsMeters がありません')
  const mid = (dims?.[0] ?? 0) / 2 + 0.12
  const inside = mid - 0.22
  const side = { left: (v) => v.x < -mid, right: (v) => v.x > mid, front: (v) => v.z < -mid }
  // リビングに向いた面：共有の壁なら内側の半分（中心は壁の中心線より内側）、共有しない壁なら壁 1 枚（中心は壁の中心線の上）
  const on = mid + 0.005
  const inner = { left: (v) => v.x >= -on && v.x < -inside, right: (v) => v.x <= on && v.x > inside, front: (v) => v.z >= -on && v.z < -inside }
  for (const mesh of meshesOf(root)) {
    const face = mesh.userData.faceRoom
    if (typeof face !== 'string') continue
    box.setFromObject(mesh).getCenter(c)
    if (!SIDE_ROOMS.includes(face)) fail(`共有の壁 ${mesh.name}: 隣の部屋 ${face} が無いのに faceRoom があります`)
    if (!side[face]?.(c)) fail(`共有の壁 ${mesh.name}（faceRoom ${face}）が隣の部屋の側にありません（中心 ${c.x.toFixed(2)}, ${c.z.toFixed(2)}）`)
  }
  // リビングの西・東・北の壁には、リビングに向いた面がある（隣の部屋があってもなくても）
  for (const face of ['left', 'right', 'front']) {
    const own = meshesOf(root).filter((m) => {
      if (m.userData.faceRoom || !(m.userData.role === 'wall_lower' || m.userData.role === 'wall_upper')) return false
      box.setFromObject(m).getCenter(c)
      return inner[face](c)
    })
    if (own.length === 0) fail(`リビングの ${face} 側の壁に、リビングに向いた面がありません`)
  }
}

if (seamCount.lower === 0 || seamCount.upper === 0) fail(`上下の壁の境目（y = 0.92）の頂点が見つかりません（下 ${seamCount.lower}・上 ${seamCount.upper}）`)

// ---------- 4. 共有と不変 ----------

{
  // 同じテーマの材質は建物の複製どうしで同じ物（作り直さない）。GLB の scene そのものの材質は替わらない
  const a = cloneRoom(roomAt(1))
  const b = cloneRoom(roomAt(1))
  const f = themeOf('dark_marble')
  applyTheme(a, f, materials)
  applyTheme(b, f, materials)
  await settle()
  const wallA = meshesOf(a).filter((m) => m.userData.role === 'wall_upper').map((m) => m.material)
  const wallB = meshesOf(b).filter((m) => m.userData.role === 'wall_upper').map((m) => m.material)
  if (wallA.length === 0 || !wallA.every((m, i) => m === wallB[i] && m === wallA[0])) fail('同じテーマの材質が建物どうしで共有されていません')
  for (const id of ROOM_IDS) sameAsSnapshot(glbSnapshots[id], `GLB ${id}`)
}

if (expectedWarnings !== 1) fail(`読めない画像 (d): theme.ts の警告が ${expectedWarnings} 回（1 回のはず）`)

const total = seamCount.checked
if (errors.length) {
  console.error(`[check:theme] ${errors.length} 件の違いがあります`)
  for (const e of errors.slice(0, 30)) console.error(`  - ${e}`)
  process.exit(1)
}
console.log(
  `[check:theme] OK: テーマ ${themes.length} 種（内装セット ${FINISH_PACK_THEMES.length} 種）× ${ROOM_IDS.length} 部屋（${ROOM_IDS.join('・')}）、部屋ごとの組 ${mixes.length} 通り、` +
    `競合 4 通り。壁の表と裏の頂点 ${total} 個で上下の模様がつながる（境目の頂点 下 ${seamCount.lower}・上 ${seamCount.upper}、` +
    `決まりの違う面（上面・出入口の側面など）の頂点 ${seamCount.other} 個は対象外）`,
)
