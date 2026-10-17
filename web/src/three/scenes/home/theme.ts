// 壁紙と床材（テーマ）を家の建物に当てる（applyTheme）。家の建物（MuseumModel の中身）に対して呼ぶ。
//
// 家の GLB（home-empty.glb）の材質は 4 つだけ（Foundation・Floor_Oak・Wall_Plaster・Trim_Oak）。
// メッシュの userData.role を見て、壁（wall_lower / wall_upper）と床（floor）の材質だけを差し替える。幅木・柱・土台はそのまま。
// GLB に焼き込まれている素材と同じものを選んだとき（白壁・オークの床）は、GLB の材質に戻す（出荷時の見た目をそのまま保つ）。
// 部屋どうしで共有する壁（リビングの GLB の西・東・北の壁）は、隣の部屋に向いた半分が別のメッシュで、userData.faceRoom に
// その部屋の id（left / right / front）が入っている。その壁には、建物の部屋ではなく隣の部屋の壁紙を当てる（faceRooms）。
// 床には印が無いので、床は建物の部屋のまま（印があっても壁だけに使う）。
//
// 材質は「テクスチャの組 × 場所（下の壁・上の壁・床）」ごとに 1 つ作り、全部の画面で共有する（モジュールの中に覚えておく）。
// 共有しているので、材質そのものに色を付けたり書き換えたりしてはいけない（鑑賞モードは walk/stageMaterials.ts で複製してから変える）。
// 画像は URL ごとに 1 回だけ読み込み、場所ごとのテクスチャ（repeat・offset だけが違う）は同じ画像（THREE.TextureSource）を使う。
// 画像を読み込み終わるまでは今の材質のままにして、読み込めたら差し替える（黒い壁が一瞬出ないように）。
//
// テクスチャの向きと材質の作り方は、three.js の GLTFLoader が GLB の材質を作るときと同じにしている：
//   - base（色）は sRGB、normal と ORM はリニア。flipY = false（glTF の UV の向き）
//   - 法線マップは normalScale = (1, −1)（GLB に接線が無いとき、GLTFLoader が y を反転するのと同じ）
//   - ORM は R = 遮蔽、G = 粗さ、B = 金属。1 枚を roughnessMap と metalnessMap の両方に使う（glTF の metallicRoughness と同じ並び）
//   - 遮蔽（aoMap）は使わない。今の素材は R がすべて 255（遮蔽なし）で、GLB の材質も遮蔽を使っていないため
//
// ---------- UV と repeat・offset ----------
// 家の GLB の UV はメートル単位で、モジュールごとに中心合わせになっている（キットの書き出しのまま）：
//   壁 … 1 m の壁ごとに u = x − (その壁の中心)。v = y − c。c は下の壁（高さ 0〜0.92 m）が 0.46、上の壁（0.92〜3.2 m）が 2.06
//   床 … 1 m のタイルごとに (u, v) = (x − タイルの中心の x, z − タイルの中心の z) / 2。1 UV が 2 m（オークの床のテクスチャ 1 枚と同じ大きさ）
// テクスチャの座標は uv × repeat + offset なので、repeat = (1 UV の長さ m) / (テクスチャ 1 枚の大きさ m)。壁は 1 / tile、床は 2 / tile。
//
// 上下の壁の継ぎ目（y = 0.92）：テクスチャの v 座標は (y − c) / tile_h + offset.y。
// offset.y = c / tile_h にすると、下の壁も上の壁も y / tile_h になり、床（y = 0）から模様が切れ目なく続く。
// offset が無いと上下で (2.06 − 0.46) / tile_h だけずれ、整数でなければ継ぎ目が見える。
// レンガ（高さ 0.6 m）では 1.6 / 0.6 = 2.67 段で、0.67 段（0.4 m）ずれる → 下 0.46 / 0.6 = 0.767、上 2.06 / 0.6 = 3.433（端数 0.433）にする。
// （1 m の素材でも 0.6 ずれるので、同じ式で全部の壁にかける）
//
// 横方向（壁の u・床）はメッシュどうしで UV が同じなので、offset では合わせられない。
// テクスチャ 1 枚の幅が 1 m を割り切るとき（壁は全部 1 m、石の床は 1 m で repeat 2）だけ、隣の壁・タイルと模様がつながる。
// オークの床（2 m）は 1 m のタイルに半分ずつ同じ所が出る。これは GLB に焼き込まれたままの見た目で、ここでは GLB の材質をそのまま使う。

import * as THREE from 'three'
import type { FloorFinish, HomeMaterial, WallFinish } from '../../../api'

/** 壁紙と床材の組み合わせ（配置 JSON の rooms.hub の wall / floor） */
export interface HomeFinish {
  wall: WallFinish
  floor: FloorFinish
}

/** テクスチャの組（catalog.materials）。キーは素材の id */
export type HomeMaterials = Record<string, HomeMaterial>

/** 部屋の id → その部屋の壁紙と床材（配置 JSON の rooms）。共有する壁の、隣の部屋に向いた面（userData.faceRoom）に使う */
export type FaceRoomFinishes = Partial<Record<string, HomeFinish>>

/** 差し替える場所。メッシュの userData.role と同じ名前 */
type Part = 'wall_lower' | 'wall_upper' | 'floor'

const PARTS: ReadonlySet<string> = new Set<Part>(['wall_lower', 'wall_upper', 'floor'])

/**
 * 壁紙・床材の名前 → テクスチャの組（catalog.materials のキー）。キットの素材は buildRoom（Wall_Oak は oak_wall の画像）と同じ対応。
 * 内装セット（finish-pack。画像は backend/static/home/textures/finish-pack/<id>/）は、名前と素材の id が同じ
 */
const WALL_TEXTURE: Record<WallFinish, string> = {
  plaster: 'plaster',
  oak: 'oak_wall',
  brick: 'brick',
  limestone: 'limestone',
  nordic_chalk: 'nordic_chalk',
  sage_limewash: 'sage_limewash',
  mushroom_limewash: 'mushroom_limewash',
  warm_cream: 'warm_cream',
  soft_brick: 'soft_brick',
}
const FLOOR_TEXTURE: Record<FloorFinish, string> = {
  oak: 'oak_floor',
  limestone: 'limestone',
  white_oak: 'white_oak',
  pale_ash: 'pale_ash',
  warm_walnut: 'warm_walnut',
  carrara_marble: 'carrara_marble',
  nero_marble: 'nero_marble',
}

/**
 * GLB に焼き込まれている材質の名前（キットの命名）。メッシュの元の材質がこの名前なら、選んだ素材は焼き込みと同じ。
 * 内装セットの素材は建物の GLB に焼き込まれていないので書かない（いつもテクスチャを貼る）
 */
const WALL_BAKED: Partial<Record<WallFinish, string>> = { plaster: 'Wall_Plaster', oak: 'Wall_Oak', brick: 'Wall_Brick', limestone: 'Wall_Limestone' }
const FLOOR_BAKED: Partial<Record<FloorFinish, string>> = { oak: 'Floor_Oak', limestone: 'Floor_Limestone' }

/**
 * 材質の色（glTF の baseColorFactor, リニア）。キットの GLB と同じ。書いていない素材は白。
 * 白壁（plaster）の色はキットの画像に掛ける補正なので、ほかの素材には掛けない。内装セットの色の画像は仕上がりの色なので白のまま
 */
const BASE_COLOR: Record<string, [number, number, number]> = { plaster: [0.9, 0.88, 0.83] }

/** 場所ごとの UV の決まり（上の説明）。unit: 1 UV が何 m か、center: v = 0 の高さ（m。壁だけ） */
const UV: Record<Part, { unit: number; center: number | null }> = {
  wall_lower: { unit: 1, center: 0.46 },
  wall_upper: { unit: 1, center: 2.06 },
  floor: { unit: 2, center: null },
}

/** 渡されないときの異方性フィルタの強さ（斜めから見た床や壁がぼやけないように） */
const DEFAULT_ANISOTROPY = 8

const frac = (n: number) => n - Math.floor(n)

// ---------- 画像（URL ごとに 1 回だけ読み込む） ----------

interface ImageEntry {
  source: THREE.TextureSource<HTMLImageElement | null>
  /** 読み込めたら true、読めなければ false */
  ready: Promise<boolean>
  loaded: boolean
}

const images = new Map<string, ImageEntry>()
const imageLoader = new THREE.ImageLoader()

/** URL の画像。初めてなら読み込みを始める */
function imageOf(url: string): ImageEntry {
  const cached = images.get(url)
  if (cached) return cached
  const entry: ImageEntry = { source: new THREE.TextureSource(null), loaded: false, ready: Promise.resolve(false) }
  entry.ready = new Promise<boolean>((resolve) => {
    imageLoader.load(
      url,
      (image) => {
        entry.source.data = image
        entry.loaded = true
        resolve(true)
      },
      undefined,
      () => {
        // 読めなかった：次に選んだときに読み直せるよう忘れる（材質は今のまま）
        images.delete(url)
        console.warn(`テーマのテクスチャを読み込めませんでした: ${url}`)
        resolve(false)
      },
    )
  })
  images.set(url, entry)
  return entry
}

const urlsOf = (m: HomeMaterial) => [m.base_url, m.normal_url, m.orm_url]

// ---------- 材質（テクスチャの組 × 場所ごとに 1 つ） ----------

const cache = new Map<string, THREE.MeshStandardMaterial>()

function makeTexture(url: string, color: boolean, repeat: [number, number], offsetY: number, anisotropy: number) {
  const texture = new THREE.Texture()
  // 同じ画像は同じ TextureSource を使う（GPU には 1 枚だけ送られる。repeat と offset は材質ごとの値なので別のテクスチャにする）
  texture.source = imageOf(url).source
  texture.colorSpace = color ? THREE.SRGBColorSpace : THREE.NoColorSpace
  texture.flipY = false
  texture.wrapS = THREE.RepeatWrapping
  texture.wrapT = THREE.RepeatWrapping
  texture.repeat.set(repeat[0], repeat[1])
  texture.offset.set(0, offsetY)
  texture.anisotropy = anisotropy
  texture.needsUpdate = true
  return texture
}

/** テクスチャの組 setId を場所 part に貼る材質。画像を読み込み終わってから呼ぶ */
function materialFor(setId: string, def: HomeMaterial, part: Part, anisotropy: number) {
  const key = `${setId}:${part}`
  let material = cache.get(key)
  if (material) return material
  const [tileW, tileH] = def.tile_meters
  const { unit, center } = UV[part]
  const repeat: [number, number] = [unit / tileW, unit / tileH]
  const offsetY = center === null ? 0 : frac(center / tileH)
  const orm = makeTexture(def.orm_url, false, repeat, offsetY, anisotropy)
  const [r, g, b] = BASE_COLOR[setId] ?? [1, 1, 1]
  material = new THREE.MeshStandardMaterial({
    name: `Theme_${setId}_${part}`,
    color: new THREE.Color().setRGB(r, g, b, THREE.LinearSRGBColorSpace),
    map: makeTexture(def.base_url, true, repeat, offsetY, anisotropy),
    normalMap: makeTexture(def.normal_url, false, repeat, offsetY, anisotropy),
    normalScale: new THREE.Vector2(1, -1),
    roughnessMap: orm,
    metalnessMap: orm,
    roughness: 1,
    metalness: 0,
  })
  cache.set(key, material)
  return material
}

// ---------- 当てる ----------

/** メッシュの元の材質（GLB の材質）。焼き込みの素材に戻すときに使う。MuseumModel の複製ごとに別のメッシュなので、画面どうしで混ざらない */
const originals = new WeakMap<THREE.Mesh, THREE.Material | THREE.Material[]>()
/** 建物ごとに、最後に頼まれた applyTheme の番号（画像を待っている間に次のテーマが選ばれたら、前のものは当てない） */
const requests = new WeakMap<THREE.Object3D, number>()
let requestSeq = 0

type TextureSet = { id: string; def: HomeMaterial }

/** 壁と床に貼るテクスチャの組。catalog に無ければ null（その場所は GLB の材質のまま） */
function setsOf(finish: HomeFinish, materials: HomeMaterials): { wall: TextureSet | null; floor: TextureSet | null } {
  const pick = (id: string) => (materials[id] ? { id, def: materials[id] } : null)
  return { wall: pick(WALL_TEXTURE[finish.wall]), floor: pick(FLOOR_TEXTURE[finish.floor]) }
}

/** 差し替える 1 つのメッシュと、貼るテクスチャの組（null なら GLB の材質に戻す） */
interface Target {
  mesh: THREE.Mesh
  part: Part
  set: TextureSet | null
}

/**
 * root の壁と床のメッシュごとに、何を貼るかを決める。元の材質もここで覚える。
 * faceRoom の印がある壁は faceRooms のその部屋の素材（無ければ finish）で決める
 */
function targetsOf(root: THREE.Object3D, finish: HomeFinish, materials: HomeMaterials, faceRooms?: FaceRoomFinishes): Target[] {
  const targets: Target[] = []
  root.traverse((obj) => {
    const mesh = obj as THREE.Mesh
    const part = mesh.userData.role as Part
    if (!mesh.isMesh || !PARTS.has(part)) return
    if (!originals.has(mesh)) originals.set(mesh, mesh.material)
    const original = originals.get(mesh)!
    const isFloor = part === 'floor'
    // 隣の部屋に向いた壁の面は、その部屋の素材。床と、印の無い壁は建物の部屋の素材
    const face: unknown = isFloor ? undefined : mesh.userData.faceRoom
    const own = (typeof face === 'string' && faceRooms?.[face]) || finish
    const sets = setsOf(own, materials)
    // 元の材質が選んだ素材の焼き込みなら、GLB の材質のまま（白壁・オークの床）。焼き込みの無い素材（内装セット）はいつも貼る
    const bakedName = isFloor ? FLOOR_BAKED[own.floor] : WALL_BAKED[own.wall]
    const baked = bakedName !== undefined && !Array.isArray(original) && original.name === bakedName
    targets.push({ mesh, part, set: baked ? null : isFloor ? sets.floor : sets.wall })
  })
  return targets
}

function assign(targets: Target[], anisotropy: number) {
  for (const { mesh, part, set } of targets) {
    mesh.material = set ? materialFor(set.id, set.def, part, anisotropy) : originals.get(mesh)!
  }
}

export interface ApplyThemeOptions {
  /** テクスチャの異方性フィルタの強さ（renderer.capabilities.getMaxAnisotropy()）。無ければ 8 */
  anisotropy?: number
  /** 画像を待ってから差し替えたとき（その場で差し替えたときは呼ばない）。描き直しや、鑑賞モードの材質の整え直しに使う */
  onLate?: () => void
  /**
   * 部屋の id → 壁紙と床材。userData.faceRoom の印がある壁（共有する壁の、隣の部屋に向いた面）には finish の代わりにこれを当てる。
   * 渡さないとき・印の部屋が無いときは finish のまま
   */
  faceRooms?: FaceRoomFinishes
}

/**
 * 家の建物 root の壁と床に、壁紙・床材 finish を当てる（隣の部屋に向いた壁の面は options.faceRooms）。
 * 何度呼んでもよい（同じテーマなら材質の参照を入れ直すだけ）。
 * 画像を読み込み済みならその場で差し替える。まだなら今の材質のまま読み込み、終わったら差し替えて onLate を呼ぶ
 * （root の中で使う素材の画像を全部待ってから、まとめて差し替える）
 */
export function applyTheme(root: THREE.Object3D, finish: HomeFinish, materials: HomeMaterials, options: ApplyThemeOptions = {}) {
  const anisotropy = options.anisotropy ?? DEFAULT_ANISOTROPY
  const request = ++requestSeq
  requests.set(root, request)
  const targets = targetsOf(root, finish, materials, options.faceRooms)
  // まだ読み込んでいない画像（imageOf がここで読み込みを始める）
  const missing = new Set<ImageEntry>()
  for (const { set } of targets) {
    for (const url of set ? urlsOf(set.def) : []) {
      const entry = imageOf(url)
      if (!entry.loaded) missing.add(entry)
    }
  }
  if (missing.size === 0) {
    assign(targets, anisotropy)
    return
  }
  void Promise.all([...missing].map((entry) => entry.ready)).then((results) => {
    // 待っている間に次のテーマが頼まれた・読めない画像があった：今の材質のまま
    if (requests.get(root) !== request || !results.every(Boolean)) return
    assign(targets, anisotropy)
    options.onLate?.()
  })
}

/** home-empty.glb に焼き込まれている素材。先読みを省くためだけに使う（当てるときは元の材質の名前で調べる） */
const SHIPPED: HomeFinish = { wall: 'plaster', floor: 'oak' }

/** テーマの画像を先に読み込み始める（GLB を待つ間に。何度呼んでもよい）。焼き込みと同じ素材は読まない */
export function preloadTheme(finish: HomeFinish, materials: HomeMaterials) {
  const sets = setsOf(finish, materials)
  if (finish.wall !== SHIPPED.wall && sets.wall) urlsOf(sets.wall.def).forEach(imageOf)
  if (finish.floor !== SHIPPED.floor && sets.floor) urlsOf(sets.floor.def).forEach(imageOf)
}
