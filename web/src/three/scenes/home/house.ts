// 家の建物（部屋の定義。/api/museum の house）を扱う、three.js を使わない小さな関数。
//
// 部屋の位置・大きさ・ドア・GLB は、Rust の home.rs の ROOM_DEFS が house.rooms[] として返す値だけを使い、ここには数値を書かない。
// house が無い古いサーバーのときだけ、model_url のリビング 1 部屋（配置 JSON の rooms.hub の大きさ）として扱う。
// three.js を使わないので、three/index.tsx から画面にも渡している（GLB の先読み・3D の代わりの説明を出すかどうか）。

import type { HouseRoom, Museum, RoomId, Side, Vec3 } from '../../../api/types'

/** 壁の高さ（m。家のキットの値。鑑賞モードの天井の高さ CEILING_HEIGHT と同じ）。カメラに家全体を収めるときの上端 */
export const WALL_TOP = 3.2
/** house が無いときの壁の厚さ（m。今の家の GLB の値） */
const LEGACY_WALL = 0.24

const legacyCache = new WeakMap<Museum, HouseRoom[]>()

/**
 * 部屋の定義の一覧（house.rooms）。house が無い古いサーバーでは、model_url のリビング 1 部屋。
 * 同じ museum には同じ配列を返す（useMemo などの依存に使えるように）
 */
export function houseRoomsOf(museum: Museum): HouseRoom[] {
  const rooms = museum.house?.rooms
  if (rooms && rooms.length > 0) return rooms
  let legacy = legacyCache.get(museum)
  if (!legacy) {
    const hub = museum.layout.rooms.hub
    legacy = [
      {
        id: 'hub',
        name: museum.rooms.find((r) => r.id === 'hub')?.name ?? 'リビング',
        origin: [0, 0],
        size: [hub?.width ?? 8, hub?.depth ?? 8],
        model_url: museum.model_url,
        doors: [],
        cutaway: [],
      },
    ]
    legacyCache.set(museum, legacy)
  }
  return legacy
}

/** 部屋 1 つの建物の GLB */
export interface Shell {
  room: HouseRoom
  url: string
}

/**
 * 描く建物（部屋ごとの GLB）。model_url が null の部屋は飛ばす（その部屋の建物は描かない）。
 * walk のとき、walk_model_url（サーバーの WALK_MODEL_PATH。ふだんは無い）があれば、リビングの建物の代わりにそれを使う
 */
export function shellsOf(museum: Museum, { walk = false }: { walk?: boolean } = {}): Shell[] {
  const shells: Shell[] = []
  for (const room of houseRoomsOf(museum)) {
    const url = walk && room.id === 'hub' && museum.walk_model_url ? museum.walk_model_url : room.model_url
    if (url) shells.push({ room, url })
  }
  return shells
}

/** 家の建物の GLB の URL（部屋ごと。重なりなし）。warmUp3D で先読みする。walk は鑑賞モード（shellsOf と同じ） */
export function shellUrlsOf(museum: Museum, options: { walk?: boolean } = {}): string[] {
  return [...new Set(shellsOf(museum, options).map((s) => s.url))]
}

/** 家の建物の GLB が 1 つでもあるか（無ければ、3D の代わりに「見つかりません」を出す） */
export function hasHouseModel(museum: Museum): boolean {
  return shellsOf(museum).length > 0
}

/** 真上から見た範囲（m） */
export interface Bounds2 {
  minX: number
  maxX: number
  minZ: number
  maxZ: number
}

/** 壁の厚さ（house.wall_thickness。house が無ければ今の GLB の値） */
export function wallThicknessOf(museum: Museum): number {
  return museum.house?.wall_thickness ?? LEGACY_WALL
}

/** 部屋 1 つの外形（内寸に壁の厚さを足したもの。世界座標） */
export function roomBounds(room: HouseRoom, wall: number): Bounds2 {
  const [ox, oz] = room.origin
  const hw = room.size[0] / 2 + wall
  const hd = room.size[1] / 2 + wall
  return { minX: ox - hw, maxX: ox + hw, minZ: oz - hd, maxZ: oz + hd }
}

/** 家全体の外形（全部の部屋の外形を合わせた範囲。世界座標） */
export function houseBounds(rooms: HouseRoom[], wall: number): Bounds2 {
  const all = rooms.map((r) => roomBounds(r, wall))
  return {
    minX: Math.min(...all.map((b) => b.minX)),
    maxX: Math.max(...all.map((b) => b.maxX)),
    minZ: Math.min(...all.map((b) => b.minZ)),
    maxZ: Math.max(...all.map((b) => b.maxZ)),
  }
}

/**
 * 出入口のある壁（隣の部屋との間の壁）の向き。家全体を見下ろす画面では、カメラの向きに関係なくいつもカットする
 * （HouseShells の cutaway = 'house'）。リビングの壁の向こうにある隣の部屋が、その壁に隠れないようにするため。
 * カメラの側の 2 面は、HouseShells がカメラの位置から毎フレーム決める（cutaway.ts の facingSides）。
 * house.rooms[].cutaway（Rust: ROOM_DEFS の cutaway。南東から見るときの向き）は、今は使わない
 */
export function doorSidesOf(room: HouseRoom): Side[] {
  return [...new Set<Side>(room.doors.map((door) => door.side))]
}

/** 部屋の名前（house.rooms[].name）。見つからなければ id */
export function roomNameOf(rooms: HouseRoom[], roomId: RoomId | string): string {
  return rooms.find((r) => r.id === roomId)?.name ?? roomId
}

/** 範囲 bounds の角（床と壁の上端の 8 点）。fitDistance に渡す */
export function cornersOf(b: Bounds2, top = WALL_TOP): Vec3[] {
  const points: Vec3[] = []
  for (const y of [0, top]) {
    for (const x of [b.minX, b.maxX]) for (const z of [b.minZ, b.maxZ]) points.push([x, y, z])
  }
  return points
}

/**
 * 真上から見て、カメラ（direction の向きから見る）の左右と奥行きの向きに points を並べたときの、範囲の真ん中（y = 0）。
 * 家全体を画面の真ん中に置く見る先にする（マップ。部屋の並びが左右対称でなくても、片寄らないように）
 */
export function frameCenter(points: Vec3[], direction: Vec3): Vec3 {
  const len = Math.hypot(direction[0], direction[2]) || 1
  // 奥（水平）と右（水平）
  const f: [number, number] = [-direction[0] / len, -direction[2] / len]
  const r: [number, number] = [-f[1], f[0]]
  let minR = Infinity
  let maxR = -Infinity
  let minF = Infinity
  let maxF = -Infinity
  for (const [x, , z] of points) {
    const pr = x * r[0] + z * r[1]
    const pf = x * f[0] + z * f[1]
    minR = Math.min(minR, pr)
    maxR = Math.max(maxR, pr)
    minF = Math.min(minF, pf)
    maxF = Math.max(maxF, pf)
  }
  if (!Number.isFinite(minR)) return [0, 0, 0]
  const cr = (minR + maxR) / 2
  const cf = (minF + maxF) / 2
  return [cr * r[0] + cf * f[0], 0, cr * r[1] + cf * f[1]]
}

/**
 * カメラを target から direction の向きに置いたとき、points が全部写る、target からの距離。
 * fovDeg は縦の画角、aspect は横 / 縦。margin だけ余白を取る（1.1 なら 1 割）。
 * 点 v（target から見た位置）がカメラの右 r・上 u・奥 f の座標で (x, y, D − v·d) に来るので、
 * |x| ≤ (D − v·d)·tan(横の画角 / 2)、|y| ≤ (D − v·d)·tan(縦の画角 / 2) を満たす最小の D
 */
export function fitDistance(points: Vec3[], target: Vec3, direction: Vec3, fovDeg: number, aspect: number, margin = 1.08): number {
  const len = Math.hypot(...direction) || 1
  const d: Vec3 = [direction[0] / len, direction[1] / len, direction[2] / len]
  // 右 = 奥（−d）× 上（+Y）、上 = 右 × 奥
  const f: Vec3 = [-d[0], -d[1], -d[2]]
  let r: Vec3 = [-f[2], 0, f[0]]
  const rl = Math.hypot(...r) || 1
  r = [r[0] / rl, r[1] / rl, r[2] / rl]
  const u: Vec3 = [r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]]
  const tanV = Math.tan(((fovDeg / 2) * Math.PI) / 180) / margin
  const tanH = tanV * aspect
  const dot = (a: Vec3, b: Vec3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
  let distance = 0
  for (const p of points) {
    const v: Vec3 = [p[0] - target[0], p[1] - target[1], p[2] - target[2]]
    const need = dot(v, d) + Math.max(Math.abs(dot(v, r)) / tanH, Math.abs(dot(v, u)) / tanV)
    distance = Math.max(distance, need)
  }
  return distance
}
