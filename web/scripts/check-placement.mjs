// 置けるかどうかの判定（src/three/scenes/home/placement.ts）を、Rust（backend/src/home.rs）と同じ総当たり表で照合する。
// npm run check:placement で動かす（tsc -p tsconfig.check.json で placement.ts だけを node_modules/.cache/ に出力してから読む）。
//
// 総当たり表は backend/src/testdata/placement-cases.json（home.rs のテスト regen_placement_cases が書き出す）。
// 環境変数 PLACEMENT_CASES で別のファイルを渡せる。
//
//   cases … 面（または床）× 作品 × 回転 × 目標の位置。目標を面（床なら部屋）の中へ寄せた位置（clampToRect）、
//           拡縮率（displayScale）、置けるかどうか（canPlace）が、表の値と一致するかを見る
//   extra … 先に objects を置いた配置に candidate を置けるか（重なり・部屋の外・寸法なしなど）
//   world … （表にあれば）置いた物の世界座標と向き（worldOf。部屋の中心 origin と親の家具の変換を引き継ぐか）
//
// 表の形は 2 つとも読める：
//   v2（リビングだけ）… 配置は schemaVersion 2、床のケースに room が無い。ドアの判定はしない（リビングにドアが無かったころの表）
//   v3〜v5（部屋ごと）… 配置は schemaVersion 3〜5（3・4 は 4 部屋、5 はリビングだけ）、床のケースに room（部屋の id）がある。部屋の定義（中心・大きさ・ドア）は
//                       表の house（/api/museum の house と同じ形）か room_defs から読み、無ければ仕様の値（DEFAULT_HOUSE）を使う。
//                       ドアの前の判定は、候補（candidate）を「新しく置いた物」として調べる（Rust は保存時に動かした物だけを調べる）。
//                       ケースに moved: false があれば、そのケースではドアの判定をしない
//
// Node 20.19 でも動くよう、TypeScript を直接読む機能（--experimental-strip-types）は使わない。
// 違いがあれば最初の 20 件を表示して、終了コードを 1 にする。

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const outDir = resolve(here, '../node_modules/.cache/placement-check')
const modulePath = resolve(outDir, 'src/three/scenes/home/placement.js')
const casesPath = process.env.PLACEMENT_CASES
  ? resolve(process.cwd(), process.env.PLACEMENT_CASES)
  : resolve(here, '../../backend/src/testdata/placement-cases.json')

if (!existsSync(modulePath)) {
  console.error(`[check:placement] ${modulePath} がありません。先に tsc -p tsconfig.check.json を実行してください`)
  process.exit(1)
}
if (!existsSync(casesPath)) {
  console.error(`[check:placement] 総当たり表 ${casesPath} がありません（cd backend && cargo test regen_placement_cases -- --ignored で作る）`)
  process.exit(1)
}

// 出力先は node_modules の下なので、web/package.json の "type": "module" が届かない。ES モジュールとして読ませる
writeFileSync(resolve(outDir, 'package.json'), '{ "type": "module" }\n')
const placement = await import(pathToFileURL(modulePath).href)
const {
  DOOR_ZONE_DEPTH,
  DOOR_ZONE_WIDTH,
  FLOOR_ART_FIT,
  WALL_HEIGHT,
  WALL_ART_FIT,
  WALL_MARGIN,
  WALL_MOUNT_MIN,
  artExtent,
  assetOf,
  canPlace,
  clampToRect,
  displayScale,
  roomRect,
  surfaceOf,
  topRect,
  worldOf,
} = placement

const fixture = JSON.parse(readFileSync(casesPath, 'utf8'))
const tolPosition = fixture.tolerance?.position ?? 1e-9
const tolScale = fixture.tolerance?.scale ?? 1e-6

// 表の形（v2 = リビングだけ、v3 = 4 部屋）
const layoutsOf = Object.values(fixture.layouts ?? {})
const v3 =
  layoutsOf.some((l) => l?.schemaVersion >= 3) ||
  (fixture.cases ?? []).some((c) => c.room !== undefined) ||
  fixture.house !== undefined ||
  fixture.room_defs !== undefined

/**
 * 仕様の部屋の定義（home.rs の ROOM_DEFS と同じ値のはず）。表に house も room_defs も無いときだけ使う。
 * 今の家は中央のリビング hub 10 × 10 の 1 部屋だけで、出入口は無い
 */
const DEFAULT_HOUSE = {
  wall_thickness: 0.24,
  rooms: [{ id: 'hub', name: 'hub', origin: [0, 0], size: [10, 10], model_url: null, cutaway: [], doors: [] }],
}

/** 表の部屋の定義を、/api/museum の house の形にそろえる（room_defs は配列か { id: def } のどちらでも） */
function houseOf(f) {
  const normalize = (r, id) => ({
    id: r.id ?? id,
    name: r.name ?? r.name_ja ?? r.id ?? id,
    origin: r.origin,
    size: r.size,
    model_url: null,
    cutaway: r.cutaway ?? [],
    doors: (r.doors ?? []).map((d) => ({ side: d.side, offset: d.offset ?? 0, clear_width: d.clear_width ?? 0, height: d.height ?? 0 })),
  })
  if (f.house?.rooms) return { wall_thickness: f.house.wall_thickness ?? 0.24, rooms: f.house.rooms.map((r) => normalize(r)) }
  if (f.room_defs) {
    const defs = Array.isArray(f.room_defs) ? f.room_defs.map((r) => normalize(r)) : Object.entries(f.room_defs).map(([id, r]) => normalize(r, id))
    return { wall_thickness: f.wall_thickness ?? 0.24, rooms: defs }
  }
  return null
}
const fixtureHouse = houseOf(fixture)
const house = v3 ? (fixtureHouse ?? DEFAULT_HOUSE) : null
const houseSource = !v3 ? 'なし（v2。ドアの判定なし）' : fixtureHouse ? (fixture.house ? '表の house' : '表の room_defs') : '仕様の値（表に house が無い）'
/** そのケースで使う部屋の定義。v3 でも moved: false のケースはドアの判定をしない */
const houseFor = (item) => (house && item.moved !== false ? house : undefined)

// 表の catalog は判定に使う項目だけなので、CatalogAsset の残りの項目は仮の値で埋める
const catalog = {
  kit_version: fixture.layouts?.supports?.kitVersion ?? '',
  assets: fixture.catalog.assets.map((a) => ({
    name: a.id,
    name_ja: a.id,
    file_url: '',
    category: '',
    top_anchor: null,
    layer: null,
    placement: 'floor',
    mount_height: null,
    support: (a.surfaces ?? []).length > 0,
    surfaces: [],
    ...a,
  })),
  themes: [],
  materials: {},
}

// 作品の実寸（artwork_id で引く）。寸法なし（size: null）の作品は入れない。frame は写真の額縁（壁に掛けられる）
const arts = new Map()
for (const art of Object.values(fixture.arts)) {
  if (art.size) arts.set(art.artwork_id, { size: art.size, custom: Boolean(art.custom), frame: Boolean(art.frame) })
}
const sizeOf = (artworkId) => arts.get(artworkId) ?? null

const mismatches = []
const counts = { position: 0, scale: 0, ok: 0, setup: 0 }
const miss = (kind, label, detail) => {
  counts[kind] += 1
  mismatches.push(`${label}: ${detail}`)
}
const near = (a, b, tol) => Math.abs(a - b) <= tol
const fmt = (v) => JSON.stringify(v)

// 定数がそろっているか
if (fixture.floor_art_fit && !fixture.floor_art_fit.every((v, i) => near(v, FLOOR_ART_FIT[i], 1e-12))) {
  miss('setup', 'floor_art_fit', `表 ${fmt(fixture.floor_art_fit)} / Web ${fmt(FLOOR_ART_FIT)}`)
}
if (fixture.wall_art_fit && !fixture.wall_art_fit.every((v, i) => near(v, WALL_ART_FIT[i], 1e-12))) {
  miss('setup', 'wall_art_fit', `表 ${fmt(fixture.wall_art_fit)} / Web ${fmt(WALL_ART_FIT)}`)
}
if (fixture.wall_margin !== undefined && !near(fixture.wall_margin, WALL_MARGIN, 1e-12)) {
  miss('setup', 'wall_margin', `表 ${fixture.wall_margin} / Web ${WALL_MARGIN}`)
}
// 壁の家具の高さの決まり（表にあれば。wall: { height, mount_min }）
if (fixture.wall?.height !== undefined && !near(fixture.wall.height, WALL_HEIGHT, 1e-12)) {
  miss('setup', 'wall.height', `表 ${fixture.wall.height} / Web ${WALL_HEIGHT}`)
}
if (fixture.wall?.mount_min !== undefined && !near(fixture.wall.mount_min, WALL_MOUNT_MIN, 1e-12)) {
  miss('setup', 'wall.mount_min', `表 ${fixture.wall.mount_min} / Web ${WALL_MOUNT_MIN}`)
}
// ドアの前の大きさ（表にあれば。door_zone: { width, depth }）
if (fixture.door_zone?.width !== undefined && !near(fixture.door_zone.width, DOOR_ZONE_WIDTH, 1e-12)) {
  miss('setup', 'door_zone.width', `表 ${fixture.door_zone.width} / Web ${DOOR_ZONE_WIDTH}`)
}
if (fixture.door_zone?.depth !== undefined && !near(fixture.door_zone.depth, DOOR_ZONE_DEPTH, 1e-12)) {
  miss('setup', 'door_zone.depth', `表 ${fixture.door_zone.depth} / Web ${DOOR_ZONE_DEPTH}`)
}

const cases = fixture.cases ?? []
cases.forEach((c, i) => {
  const label = `cases[${i}] ${c.layout} ${c.surface} ${c.art} rot=${c.rotation} ${c.target}`
  const layout = fixture.layouts[c.layout]
  const art = fixture.arts[c.art]
  const target = fixture.targets[c.target]
  if (!layout || !art || !target) return miss('setup', label, '表の layout・art・target が見つかりません')

  let rect
  let envelope
  let candidate
  if (c.surface === 'floor') {
    // 床のケースは部屋ごと（v3 の room。無ければリビング）。位置は部屋の中の位置
    const room = c.room ?? 'hub'
    rect = roomRect(layout, room)
    envelope = FLOOR_ART_FIT
    candidate = { kind: 'artwork', id: 'cand', artworkId: art.artwork_id, roomId: room }
  } else {
    const [assetId, surfaceId] = c.surface.split('/')
    const asset = assetOf(catalog, assetId)
    const surface = asset ? surfaceOf(asset, surfaceId) : undefined
    if (!surface) return miss('setup', label, 'catalog に面がありません')
    rect = topRect(surface)
    envelope = surface.art_fit
    candidate = { kind: 'artwork', id: 'cand', artworkId: art.artwork_id, parentId: `f-${assetId}` }
    if (surfaceId !== 'top') candidate.surface = surfaceId
  }

  // 目標の位置を、置いた後の寸法で面（床なら部屋）の中へ寄せる（ドラッグと同じ。表は 1 cm に丸めていない）
  const [w, d] = artExtent(art.artwork_id, envelope, c.rotation, sizeOf)
  const [x, z] = clampToRect(rect, w, d, c.rotation, target[0], target[1])
  if (!near(x, c.position[0], tolPosition) || !near(z, c.position[1], tolPosition)) {
    miss('position', label, `位置 表 ${fmt(c.position)} / Web ${fmt([x, z])}`)
  }

  const scale = art.size ? displayScale({ size: art.size, custom: Boolean(art.custom), frame: Boolean(art.frame) }, envelope, c.rotation) : null
  const sameScale = scale === null || c.scale === null ? scale === c.scale : near(scale, c.scale, tolScale)
  if (!sameScale) miss('scale', label, `拡縮率 表 ${c.scale} / Web ${scale}`)

  // 置けるかどうかは表の位置で調べる（位置の違いと判定の違いを分けて見るため）
  candidate.position = [c.position[0], 0, c.position[1]]
  candidate.rotationY = c.rotation
  const check = canPlace(layout, catalog, candidate, { sizeOf, house: houseFor(c) })
  if (check.ok !== c.ok) miss('ok', label, `置ける 表 ${c.ok} / Web ${check.ok}${check.ok ? '' : `（${check.reason}）`}`)
})

const extra = fixture.extra ?? []
extra.forEach((e, i) => {
  const label = `extra[${i}] ${e.id}`
  const base = fixture.layouts[e.layout]
  if (!base) return miss('setup', label, `表の layout「${e.layout}」が見つかりません`)
  const layout = { ...base, objects: [...base.objects, ...(e.objects ?? [])] }
  const check = canPlace(layout, catalog, e.candidate, { sizeOf, house: houseFor(e) })
  if (check.ok !== e.ok) miss('ok', label, `置ける 表 ${e.ok} / Web ${check.ok}${check.ok ? '' : `（${check.reason}）`}`)
})

// 世界座標（表にあれば）：{ layout, id（object_id）, objects?, position: [x, y, z], rotation_y（rotationY） }
const worlds = fixture.world ?? fixture.worlds ?? fixture.world_cases ?? []
worlds.forEach((w, i) => {
  const id = w.id ?? w.object_id
  const label = `world[${i}] ${w.layout} ${id}`
  const base = fixture.layouts[w.layout]
  if (!base) return miss('setup', label, `表の layout「${w.layout}」が見つかりません`)
  const layout = { ...base, objects: [...base.objects, ...(w.objects ?? [])] }
  const object = layout.objects.find((o) => o.id === id)
  if (!object) return miss('setup', label, `object「${id}」が配置にありません`)
  const got = worldOf(layout, catalog, object, house ?? DEFAULT_HOUSE)
  const want = w.position
  const wantYaw = w.rotation_y ?? w.rotationY
  if (!got || !want) return miss('setup', label, `世界座標 表 ${fmt(want)} / Web ${fmt(got)}`)
  const samePosition = want.every((v, k) => near(v, got.position[k], Math.max(tolPosition, 1e-9)))
  const sameYaw = wantYaw === undefined || near(wantYaw, got.rotationY, 1e-9)
  if (!samePosition || !sameYaw) miss('position', label, `世界座標 表 ${fmt([want, wantYaw])} / Web ${fmt([got.position, got.rotationY])}`)
})

console.log(`[check:placement] ${casesPath}`)
if (fixture.generated_by) console.log(`[check:placement] generated_by: ${fixture.generated_by}`)
const floorRooms = [...new Set(cases.filter((c) => c.surface === 'floor').map((c) => c.room ?? 'hub'))]
console.log(
  `[check:placement] 表の形: ${v3 ? '部屋ごと（床のケースに room あり）' : 'v2（リビングだけ）'}・床のケースの部屋: ${floorRooms.join(', ') || 'なし'}・部屋の定義: ${houseSource}`,
)
console.log(
  `[check:placement] cases ${cases.length} 件・extra ${extra.length} 件・world ${worlds.length} 件 → 違い ${mismatches.length} 件` +
    `（位置 ${counts.position}・拡縮率 ${counts.scale}・置ける ${counts.ok}・表の不備 ${counts.setup}）`,
)
if (mismatches.length > 0) {
  for (const line of mismatches.slice(0, 20)) console.log(`  ${line}`)
  if (mismatches.length > 20) console.log(`  …ほか ${mismatches.length - 20} 件`)
  process.exitCode = 1
}
