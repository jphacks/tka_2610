// おうちの配置の計算（置けるかどうか・世界座標・自動で置く場所）と、模様替えの操作。three.js を使わない純粋な関数だけを置く。
//
// backend/src/home.rs と同じ計算にしてある（どちらかを変えたら、もう片方も合わせる）。
// サーバーは保存のたびに同じ検証をするので、ここは「ドラッグ中に緑・赤を出す」「置けない操作をその場で止める」ためのもの。
// 各ルールの横に、対応する Rust のテスト（home.rs の tests）の名前を書いている。
//
// 座標：メートル、Y-up。床は y = 0。家具の原点は底面の中心、正面は +Z。
//   壁に掛ける家具（catalog の placement が 'wall'）だけは、原点が背面の底の中心で、背面を部屋の壁の内側の面に付ける。
//   position の y はその家具の底面の高さ（模様替えで上げ下げできる）。床の家具と作品の y はいつも 0。
//   家の部屋は house.rooms から受け取る（今は中央の hub だけ）。部屋どうしは平行移動だけで回転はない。
//   家具と床の作品の position は、所属する部屋（roomId）の中心を原点にした「部屋の中の位置」。
//   世界座標 = 部屋の中心（house.rooms[].origin。roomOrigin）+ position（worldOf。Rust: world_of）。
//   置けるかどうかは、部屋ごとに部屋の中の位置で調べる（部屋の矩形・出入口の前・同じ部屋の中の重なり）。
//   rotationY θ で、家具から見た (x, z) は部屋の中で (x·cosθ + z·sinθ, −x·sinθ + z·cosθ) になる（three.js の rotation.y と同じ）。
// 家具に載せる作品の position は、親の家具の「回す前」の向きで、載せる面（天板・本棚の段。surface）の中心からの位置。
//   作品の部屋は親の家具の部屋（roomOf）。部屋の平行移動は親の家具に 1 回だけ掛かる。
//
// 作品が場所を取る大きさは、作品の実寸（SlotArtwork.model_size）を置き場所の枠（envelope）に収めた「置いた後の寸法」
// （displayScale・placedSize。Rust: display_scale・placed_size）。枠は家具の上なら面の art_fit、床なら FLOOR_ART_FIT。
// 実寸が分からない作品は、今までどおり枠そのものを足元にする（Rust: art_rect）。
//
// three.js を使わないので、three/index.tsx から画面にも渡している（最初の読み込みに入っても数 KB）。
// web/scripts/check-placement.mjs が、このファイルだけを tsc で出力して Rust と同じ総当たり表
// （backend/src/testdata/placement-cases.json）で照合する（npm run check:placement）。そのため実行時の import は書かない
// （型も api/index.ts ではなく api/types.ts から読む。index.ts は通信の処理まで辿ってしまうため）。

import type {
  ArtworkObject,
  CatalogAsset,
  CatalogSurface,
  FurnitureObject,
  HomeCatalog,
  House,
  Layout,
  LayoutObject,
  RoomId,
  SlotView,
  Vec3,
} from '../../../api/types'

/** 壁から家具まで空ける距離（m）。Rust: WALL_MARGIN */
export const WALL_MARGIN = 0.12
/** 重なり・はみ出しの許容（m）。ぴったり接するのは重なりにしない。Rust: TOLERANCE */
const TOLERANCE = 0.002
/** 家具の天板の面の id。作品の surface を省いたときはこの面。Rust: TOP_SURFACE */
export const TOP_SURFACE = 'top'
/** 床に置く作品の枠（幅・高さ・奥行き）。家具と同じく 0.8 × 0.8 の場所を取る。Rust: FLOOR_ART_FIT */
export const FLOOR_ART_FIT: Vec3 = [0.8, 1.0, 0.8]
/** 実寸の GLB（custom）を小さすぎるときに大きくする下限（枠に収まる最大の大きさに対する割合）。Rust: CUSTOM_MIN_FILL */
export const CUSTOM_MIN_FILL = 0.6
/** 壁に掛ける作品（写真の額縁）の枠。幅と奥行きを同じにして、どの壁に掛けても同じ大きさにする。Rust: WALL_ART_FIT */
export const WALL_ART_FIT: Vec3 = [0.9, 0.9, 0.9]
/** 壁の判定の許容。壁ぎりぎりに寄せた位置が丸めの違いではみ出し扱いにならないよう、重なりと同じ 2 mm（Rust の check_placement と同じ） */
const EPSILON = TOLERANCE
/** 自動で置く場所を探すときの間隔（m） */
const SEARCH_STEP = 0.5
/** 中央の部屋（リビング）。床の作品で roomId を省いたときと、古い配置の家具の部屋 */
export const HUB: RoomId = 'hub'
/** 部屋の壁の高さ（m）。壁の家具は、上に飾る作品の枠まで含めてこれより下に掛ける。Rust: WALL_HEIGHT（house.ts の WALL_TOP と同じ） */
export const WALL_HEIGHT = 4.2
/** 壁の家具を掛けられるいちばん低い高さ（底面の y, m）。Rust: WALL_MOUNT_MIN */
export const WALL_MOUNT_MIN = 0.3
/** 壁の家具の向きの許容（ラジアン）。90° ごとの向きにだけ掛けられる。Rust: ANGLE_EPSILON */
const ANGLE_EPSILON = 1e-6
/** 出入口（ドア）の前の、物を置けない場所の幅（中心から左右に 1.27 m）と、壁の内側の面からの奥行き（m）。キットと同じ。Rust: DOOR_ZONE_WIDTH・DOOR_ZONE_DEPTH */
export const DOOR_ZONE_WIDTH = 2.54
export const DOOR_ZONE_DEPTH = 1.15

// =============================
// 平面の計算
// =============================

/** 真上から見た長方形（x と z の範囲）。Rust: Rect */
export interface Rect {
  minX: number
  maxX: number
  minZ: number
  maxZ: number
}

/** 幅 w・奥行き d の箱を rotationY だけ回したときの外接長方形（キットの objectBounds）。Rust: footprint */
export function footprint(x: number, z: number, w: number, d: number, rotationY: number): Rect {
  const c = Math.abs(Math.cos(rotationY))
  const s = Math.abs(Math.sin(rotationY))
  const hx = (w * c + d * s) / 2
  const hz = (w * s + d * c) / 2
  return { minX: x - hx, maxX: x + hx, minZ: z - hz, maxZ: z + hz }
}

/** 2 mm より深く重なっていれば true。Rust: rect_overlap */
export function rectOverlap(a: Rect, b: Rect) {
  return (
    a.minX < b.maxX - TOLERANCE &&
    a.maxX > b.minX + TOLERANCE &&
    a.minZ < b.maxZ - TOLERANCE &&
    a.maxZ > b.minZ + TOLERANCE
  )
}

/** inner が outer からはみ出していない（2 mm まで許す）。Rust: rect_inside */
export function rectInside(inner: Rect, outer: Rect) {
  return (
    inner.minX >= outer.minX - TOLERANCE &&
    inner.maxX <= outer.maxX + TOLERANCE &&
    inner.minZ >= outer.minZ - TOLERANCE &&
    inner.maxZ <= outer.maxZ + TOLERANCE
  )
}

/** 面の上で作品を置ける範囲（面の中心から見た座標・回す前）。Rust: top_rect */
export function topRect(surface: CatalogSurface): Rect {
  const hx = surface.size[0] / 2
  const hz = surface.size[1] / 2
  return { minX: -hx, maxX: hx, minZ: -hz, maxZ: hz }
}

/**
 * 幅 w・奥行き d の物を rotationY だけ回して (x, z) に置くとき、外接長方形が rect からはみ出さない位置に寄せる。Rust: clamp_to_rect
 * 模様替えのドラッグで、面や部屋の縁で止めて縁に沿って滑らせるため（丸い縁に作品が載って浮かないように）。
 * 物がその向きで rect より大きい方向は、rect の中心にする
 */
export function clampToRect(rect: Rect, w: number, d: number, rotationY: number, x: number, z: number): [number, number] {
  const frame = footprint(0, 0, w, d, rotationY)
  const clamp = (v: number, lo: number, hi: number) => (lo > hi ? (lo + hi) / 2 : Math.min(Math.max(v, lo), hi))
  return [clamp(x, rect.minX - frame.minX, rect.maxX - frame.maxX), clamp(z, rect.minZ - frame.minZ, rect.maxZ - frame.maxZ)]
}

/**
 * 部屋 roomId の中で家具を置ける範囲（部屋の中心が原点。壁から 12 cm 内側。hub は ±4.88）。Rust: room_rect
 * 大きさは配置 JSON の rooms[roomId]（Rust は ROOM_DEFS の size を使う。配置の大きさはそれと同じでないと 400 なので同じ値）。
 * 配置に無い部屋はリビングの大きさ
 */
export function roomRect(layout: Layout, roomId: RoomId = HUB): Rect {
  const { width, depth } = layout.rooms[roomId] ?? layout.rooms.hub
  return {
    minX: -width / 2 + WALL_MARGIN,
    maxX: width / 2 - WALL_MARGIN,
    minZ: -depth / 2 + WALL_MARGIN,
    maxZ: depth / 2 - WALL_MARGIN,
  }
}

/**
 * 部屋の中心の世界座標（x, z）。Rust: ROOM_DEFS の origin（room_to_world。/api/museum の house.rooms[].origin）。
 * house が無い（古いサーバー）・house に無い部屋は原点（リビングだけの家と同じ）
 */
export function roomOrigin(house: House | null | undefined, roomId: RoomId): [number, number] {
  const room = house?.rooms.find((r) => r.id === roomId)
  return room ? [room.origin[0], room.origin[1]] : [0, 0]
}

/**
 * 物の部屋。家具と床の作品は roomId（床の作品で省いていればリビング）、家具の上の作品は親の家具の部屋。
 * 親の家具が見つからなければ undefined。Rust: Layout::room_of
 */
export function roomOf(layout: Layout, object: LayoutObject): RoomId | undefined {
  if (object.kind === 'furniture') return object.roomId
  if (!object.parentId) return object.roomId ?? HUB
  return furnitureById(layout, object.parentId)?.roomId
}

/**
 * 部屋 roomId の出入口（ドア）の前の、床に物を置けない場所（部屋の中心が原点）。Rust: door_zone（door_zones_follow_room_defs）
 * 壁に沿って出入口の中心（壁の中心から offset。north / south の壁は +X、east / west の壁は +Z が正）から ±1.27 m、
 * 壁の内側の面から部屋の中へ 1.15 m（例：hub の東は x ∈ [2.85, 4.0]・z ∈ [−1.27, 1.27]）。
 * 出入口は /api/museum の house.rooms[].doors（Rust: ROOM_DEFS の doors）。house が無ければ出入口も無い
 */
export function doorZones(house: House | null | undefined, roomId: RoomId): Rect[] {
  const room = house?.rooms.find((r) => r.id === roomId)
  if (!room) return []
  const hw = room.size[0] / 2
  const hd = room.size[1] / 2
  const half = DOOR_ZONE_WIDTH / 2
  return room.doors.map(({ side, offset }) => {
    switch (side) {
      case 'north':
        return { minX: offset - half, maxX: offset + half, minZ: -hd, maxZ: -hd + DOOR_ZONE_DEPTH }
      case 'south':
        return { minX: offset - half, maxX: offset + half, minZ: hd - DOOR_ZONE_DEPTH, maxZ: hd }
      case 'west':
        return { minX: -hw, maxX: -hw + DOOR_ZONE_DEPTH, minZ: offset - half, maxZ: offset + half }
      case 'east':
        return { minX: hw - DOOR_ZONE_DEPTH, maxX: hw, minZ: offset - half, maxZ: offset + half }
    }
  })
}

/** 理由の文言に出す部屋の名前（house.rooms[].name）。house が無ければ undefined */
function roomName(house: House | null | undefined, roomId: RoomId) {
  return house?.rooms.find((r) => r.id === roomId)?.name
}

/** 部屋の壁の内側の面で囲まれた範囲（部屋の中心が原点）。壁の家具はこの中に収める。Rust: room_inner_rect */
export function roomInnerRect(layout: Layout, roomId: RoomId = HUB): Rect {
  const { width, depth } = layout.rooms[roomId] ?? layout.rooms.hub
  return { minX: -width / 2, maxX: width / 2, minZ: -depth / 2, maxZ: depth / 2 }
}

/** 壁の向き。北 = −Z、南 = +Z、西 = −X、東 = +X（Rust: Side） */
export type WallSide = 'north' | 'south' | 'west' | 'east'

/** 壁に掛ける家具か */
export const isWallAsset = (asset: CatalogAsset | undefined) => asset?.placement === 'wall'

/**
 * 家具が上に場所を取る高さ（底面から, m）：家具の高さか、面に飾る作品の枠の上のどちらか高いほう。Rust: Asset::reach
 * （wall_furniture_overlaps_by_height。サイドボードの上の壁に棚を掛けるなら、天板の作品の枠より上）
 */
export function reachOf(asset: CatalogAsset): number {
  return asset.surfaces.reduce((top, s) => Math.max(top, s.anchor[1] + s.art_fit[1]), asset.dimensions_meters[1])
}

/** 壁の家具を掛けられる高さ（底面の y の下限と上限, m）。Rust: mount_range（wall_furniture_height_range） */
export function mountRange(asset: CatalogAsset): [number, number] {
  return [WALL_MOUNT_MIN, WALL_HEIGHT - reachOf(asset)]
}

/**
 * 家具の足元（真上から見た外接長方形、部屋の中の位置）。Rust: furniture_rect（wall_furniture_footprint_and_world）
 * 床の家具は原点が底面の中心。壁の家具は原点が背面なので、正面（+Z を rotationY で回した (sinθ, cosθ)）の向きへ奥行きの半分ずらした所が中心
 */
export function furnitureRect(asset: CatalogAsset, object: { position: Vec3; rotationY: number }): Rect {
  const [w, , d] = asset.dimensions_meters
  let x = object.position[0]
  let z = object.position[2]
  if (isWallAsset(asset)) {
    x += (d / 2) * Math.sin(object.rotationY)
    z += (d / 2) * Math.cos(object.rotationY)
  }
  return footprint(x, z, w, d, object.rotationY)
}

/** 壁に掛けた作品か（配置 JSON の placement が 'wall'） */
export const isWallArt = (object: LayoutObject | undefined): boolean => object?.kind === 'artwork' && object.placement === 'wall'

/**
 * 壁に掛けた作品の背面が付いている壁。向きが 90° ごとで、足元（rect）の背面の側が壁の内側の面にあるときだけ返す。
 * 向きは壁の家具と同じ（0 で北の壁、π で南、π/2 で西、−π/2 で東）。Rust: art_wall_side（wall-frame-* の extra）
 */
export function artWallSide(layout: Layout, roomId: RoomId, rotationY: number, rect: Rect): WallSide | null {
  const quarter = Math.round(rotationY / (Math.PI / 2))
  if (Math.abs(rotationY - quarter * (Math.PI / 2)) > ANGLE_EPSILON) return null
  const inner = roomInnerRect(layout, roomId)
  const k = ((quarter % 4) + 4) % 4
  const [side, gap]: [WallSide, number] =
    k === 0
      ? ['north', rect.minZ - inner.minZ]
      : k === 2
        ? ['south', rect.maxZ - inner.maxZ]
        : k === 1
          ? ['west', rect.minX - inner.minX]
          : ['east', rect.maxX - inner.maxX]
  return Math.abs(gap) <= TOLERANCE ? side : null
}

/** 壁ごとの、背面を付けたときの向き（rotationY）。正面が部屋の中を向く */
const WALL_ROTATION: Record<WallSide, number> = { north: 0, south: Math.PI, west: Math.PI / 2, east: -Math.PI / 2 }

/**
 * 壁の家具の背面が付いている壁。向きが 90° ごとで、背面が壁の内側の面にあるときだけ返す。Rust: wall_side（wall_furniture_hangs_on_a_wall）
 * rotationY 0 は正面 +Z で北の壁（z = −奥行き / 2）、π は南の壁、π/2 は正面 +X で西の壁、−π/2 は東の壁
 */
export function wallSideOf(layout: Layout, roomId: RoomId, object: { position: Vec3; rotationY: number }): WallSide | null {
  const quarter = Math.round(object.rotationY / (Math.PI / 2))
  if (Math.abs(object.rotationY - quarter * (Math.PI / 2)) > ANGLE_EPSILON) return null
  const inner = roomInnerRect(layout, roomId)
  const [x, , z] = object.position
  const k = ((quarter % 4) + 4) % 4
  const [side, gap]: [WallSide, number] =
    k === 0 ? ['north', z - inner.minZ] : k === 2 ? ['south', z - inner.maxZ] : k === 1 ? ['west', x - inner.minX] : ['east', x - inner.maxX]
  return Math.abs(gap) <= TOLERANCE ? side : null
}

/** 2 つの高さの範囲（下, 上）が 2 mm より深く重なっていれば true。Rust: span_overlap */
function spanOverlap(a: [number, number], b: [number, number]) {
  return a[0] < b[1] - TOLERANCE && a[1] > b[0] + TOLERANCE
}

/** 壁との間隔の判定。2 mm だけ許す（Rust: rejects_wall_clearance） */
function insideRoom(rect: Rect, room: Rect) {
  return (
    rect.minX >= room.minX - EPSILON &&
    rect.maxX <= room.maxX + EPSILON &&
    rect.minZ >= room.minZ - EPSILON &&
    rect.maxZ <= room.maxZ + EPSILON
  )
}

const TAU = Math.PI * 2

/** 角度を (−π, π] にそろえる。Rust: wrap_angle（rotation_wraps） */
export function wrapAngle(angle: number) {
  if (angle > -Math.PI && angle <= Math.PI) return angle
  const r = ((angle % TAU) + TAU) % TAU
  return r > Math.PI ? r - TAU : r
}

// =============================
// 作品の大きさ（実寸と置いた後の寸法）
// =============================

/** 作品のモデルの実寸（幅・高さ・奥行き, m）と、実寸で作った GLB（model_kind が custom）か、写真の額縁（frame。壁に掛けられる）か。Rust: ArtSize */
export interface ArtSize {
  size: Vec3
  custom: boolean
  frame: boolean
}

/** 作品（artworkId）の実寸を返す関数。分からなければ null（枠そのものを足元にする）。Rust: Sizes */
export type SizeOf = (artworkId: string) => ArtSize | null | undefined

/** 作品の実寸と種類（model_kind）から ArtSize を作る。Rust: ArtSize::from_model */
export function artSizeOf(size: Vec3, modelKind: string): ArtSize {
  return { size, custom: modelKind === 'custom', frame: modelKind === 'frame' }
}

/** 壁に掛けた作品の、置いた後の寸法（WALL_ART_FIT に収めたもの）。寸法が分からなければ枠そのもの */
export function wallArtSize(object: ArtworkObject, sizeOf?: SizeOf): Vec3 {
  const art = sizeOf?.(object.artworkId)
  return art ? placedSize(art, WALL_ART_FIT, object.rotationY) : WALL_ART_FIT
}

/** 飾っている作品の実寸（slots の artwork.model_size）。作品の id（slot.artwork.id = 配置 JSON の artworkId）で引く */
export function sizesFromSlots(slots: SlotView[]): SizeOf {
  const sizes = new Map<string, ArtSize>()
  for (const slot of slots) {
    const size = slot.artwork?.model_size
    if (size) sizes.set(slot.artwork.id, artSizeOf(size, slot.artwork.model_kind))
  }
  return (artworkId) => sizes.get(artworkId) ?? null
}

/**
 * 作品を枠 envelope（幅・高さ・奥行き）に収める拡縮率。Rust: display_scale（display_scale_fits_rotated_extents）
 * 回した後の縦横（ex・ez）で決める。0° なら実寸のまま収まる作品も、浅い面で 90° 回すと収まる分だけ縮む
 * （帆船 0.56 × 0.34 をサイドボードの枠 0.56 × 0.48 に：0° = 1、90° = 0.48 / 0.56 = 0.857…）。
 * 実寸の GLB（custom）は本物より大きく見せないよう 1 倍まで。ただし枠に対して小さすぎる物（ペットボトルなど）は、
 * 枠に収まる最大の倍率の CUSTOM_MIN_FILL まで大きくする（Rust: display_scale。custom_models_are_enlarged_when_tiny）
 */
export function displayScale(art: ArtSize, envelope: Vec3, rotationY: number): number {
  const [w, h, d] = art.size
  const [ew, eh, ed] = envelope
  const s = Math.abs(Math.sin(rotationY))
  const c = Math.abs(Math.cos(rotationY))
  const ex = w * c + d * s
  const ez = w * s + d * c
  const scale = Math.min(ew / ex, ed / ez, eh / h)
  return art.custom ? Math.max(Math.min(scale, 1), scale * CUSTOM_MIN_FILL) : scale
}

/** 置いた後の寸法（実寸 × displayScale。回す前の幅・高さ・奥行き）。Rust: placed_size */
export function placedSize(art: ArtSize, envelope: Vec3, rotationY: number): Vec3 {
  const scale = displayScale(art, envelope, rotationY)
  return [art.size[0] * scale, art.size[1] * scale, art.size[2] * scale]
}

/** 作品が場所を取る幅と奥行き（回す前）。実寸が分からなければ枠そのもの */
export function artExtent(artworkId: string, envelope: Vec3, rotationY: number, sizeOf?: SizeOf): [number, number] {
  const art = sizeOf?.(artworkId)
  if (!art) return [envelope[0], envelope[2]]
  const [w, , d] = placedSize(art, envelope, rotationY)
  return [w, d]
}

/** 作品が場所を取る外接長方形（置いた後の寸法を作品の向きで回したもの）。Rust: art_rect */
export function artRect(object: ArtworkObject, envelope: Vec3, sizeOf?: SizeOf): Rect {
  const [w, d] = artExtent(object.artworkId, envelope, object.rotationY, sizeOf)
  return footprint(object.position[0], object.position[2], w, d, object.rotationY)
}

// =============================
// 家具の一覧（catalog）
// =============================

export function assetOf(catalog: HomeCatalog, assetId: string): CatalogAsset | undefined {
  return catalog.assets.find((a) => a.id === assetId)
}

/** 家具の id の面（省くと天板）。作品を載せられない家具や、無い面なら undefined。Rust: Asset::surface */
export function surfaceOf(asset: CatalogAsset, id?: string): CatalogSurface | undefined {
  const want = id ?? TOP_SURFACE
  return asset.surfaces.find((s) => s.id === want)
}

/** 作品が載っている面の id（省いていれば天板）。Rust: ArtworkObject::surface_id */
export function surfaceIdOf(artwork: ArtworkObject) {
  return artwork.surface ?? TOP_SURFACE
}

/**
 * 面を作品の枠で縦横に区切った数（幅方向の列, 奥行き方向の行）。置き場所の数は列 × 行。Rust: cell_grid
 * 枠（art_fit）は catalog にサーバーが計算した値が入っている。今のカタログで 2 行になるのは低い台（枠の奥行き 0.545）だけ
 * （Rust: cells_use_depth_on_deep_tops）
 */
export function cellGrid(surface: CatalogSurface): [number, number] {
  const fit = surface.art_fit
  if (fit[0] <= 0 || fit[2] <= 0) return [0, 0]
  // 0.59 m の台座（枠 0.53 m）がちょうど 1 になるよう誤差を足す
  const count = (length: number, size: number) => Math.floor(length / size + 1e-9)
  return [count(surface.size[0], fit[0]), count(surface.size[1], fit[2])]
}

/** 面の置き場所の数（列 × 行）。Rust: cell_count（capacity_counts_cells） */
export function cellCount(surface: CatalogSurface) {
  const [cols, rows] = cellGrid(surface)
  return cols * rows
}

/**
 * 区切った置き場所の中心（面の中心から見た (x, z)。両方向とも中央そろえ）。Rust: cell_centers
 * 手前（+z）の行から順に、行の中は −x から並べる（Rust: cells_use_depth_on_deep_tops）
 */
export function cellCenters(surface: CatalogSurface): [number, number][] {
  const [cols, rows] = cellGrid(surface)
  const fit = surface.art_fit
  const centers: [number, number][] = []
  for (let j = 0; j < rows; j++) {
    const z = ((rows - 1) / 2 - j) * fit[2]
    for (let i = 0; i < cols; i++) centers.push([(i - (cols - 1) / 2) * fit[0], z])
  }
  return centers
}

export function furnitureById(layout: Layout, id: string): FurnitureObject | undefined {
  for (const o of layout.objects) if (o.kind === 'furniture' && o.id === id) return o
  return undefined
}

// =============================
// 置けるかどうか（Rust: check_placement）
// =============================

export type PlaceCheck = { ok: true } | { ok: false; reason: string }

/** 理由の文言に出す物の名前を返す関数。undefined を返すと既定の名前（家具の日本語名・「作品」） */
export type NameOf = (object: LayoutObject) => string | undefined

/**
 * 判定に使う追加の情報。nameOf は理由の文言の名前、sizeOf は作品の実寸（無ければ作品は枠そのものの大きさ）、
 * house は部屋の定義（/api/museum の house）。house を渡すと、出入口の前（doorZones）にも置かせない
 * （Rust は保存のときに「新しく置いた・動かした物」だけを調べる。canPlace の candidate はいつもそれに当たる）
 */
export interface PlaceContext {
  nameOf?: NameOf
  sizeOf?: SizeOf
  house?: House | null
}

const OK: PlaceCheck = { ok: true }
const fail = (reason: string): PlaceCheck => ({ ok: false, reason })

/**
 * 理由の文言に出す名前。Rust の label は「サイドボード (home-005)」のように id を付けるが、
 * ここの文言は画面にそのまま出すので id は付けない
 */
function defaultName(catalog: HomeCatalog, object: LayoutObject) {
  if (object.kind === 'furniture') return assetOf(catalog, object.assetId)?.name_ja ?? object.assetId
  return '作品'
}

/** 飾っている作品の名前（slots の作品名）を、理由の文言に使う */
export function namesFromSlots(slots: SlotView[]): NameOf {
  const titles = new Map(slots.map((s) => [s.id, s.artwork?.title]))
  return (object) => {
    if (object.kind !== 'artwork') return undefined
    const title = titles.get(object.id)
    return title ? `「${title}」` : undefined
  }
}

/**
 * 部屋の中で場所を取る物の足元（外接長方形）と高さの範囲。天板の上の作品は場所を取らないので null、無い家具は undefined。
 * 高さの範囲は、床の家具が 0〜reach、壁の家具が底面〜底面 + reach、床置きの作品が 0〜床の枠の高さ、
 * 壁に掛けた作品が底面〜底面 + 置いた高さ（Rust: check_placement の Placed）
 */
function floorFootprint(
  catalog: HomeCatalog,
  object: LayoutObject,
  sizeOf?: SizeOf,
): { rect: Rect; span: [number, number]; decor: boolean; wall: CatalogAsset | null; wallArt: number | null } | null | undefined {
  if (object.kind === 'furniture') {
    const asset = assetOf(catalog, object.assetId)
    if (!asset) return undefined
    const wall = isWallAsset(asset)
    const base = wall ? object.position[1] : 0
    return {
      rect: furnitureRect(asset, object),
      span: [base, base + reachOf(asset)],
      // ラグ（floor_decor）はほかの物と重ねてよい
      decor: asset.layer === 'floor_decor',
      wall: wall ? asset : null,
      wallArt: null,
    }
  }
  if (object.parentId) return null
  if (object.placement === 'wall') {
    // 壁に掛けた作品は、壁の枠に収めた後の寸法で、底面から上端までの高さを取る（Rust: check_placement の Mount::WallArt）
    const height = wallArtSize(object, sizeOf)[1]
    const base = object.position[1]
    return { rect: artRect(object, WALL_ART_FIT, sizeOf), span: [base, base + height], decor: false, wall: null, wallArt: height }
  }
  // 床置きの作品は、床置きの枠（0.8 × 0.8）に収めた後の寸法の家具として扱う。実寸が分からなければ枠そのもの
  // （Rust: check_placement の床置き。rejects_furniture_overlap の最後のケース）
  return { rect: artRect(object, FLOOR_ART_FIT, sizeOf), span: [0, FLOOR_ART_FIT[1]], decor: false, wall: null, wallArt: null }
}

/**
 * candidate（新しく置く物、または同じ id の物を動かした・回した後）を layout に置けるか。
 * 同じ id の物は layout から外して考える。ほかの物どうしは置けている前提で、candidate と他の物の関係だけを調べる。
 * 家具を動かしても、その上の作品は家具から見た位置なので、作品の判定は変わらない。
 * 床の物は、candidate の部屋（roomOf）の中の位置で、その部屋の矩形・出入口の前・同じ部屋の物との重なりを調べる。
 */
export function canPlace(layout: Layout, catalog: HomeCatalog, candidate: LayoutObject, ctx: PlaceContext = {}): PlaceCheck {
  const { nameOf, sizeOf, house } = ctx
  const name = (o: LayoutObject) => nameOf?.(o) ?? defaultName(catalog, o)
  const others = layout.objects.filter((o) => o.id !== candidate.id)

  if (candidate.kind === 'artwork') {
    // 同じ作品を 2 か所に置かない（Rust: artwork_requires_support_parent の最後のケース）
    if (others.some((o) => o.kind === 'artwork' && o.artworkId === candidate.artworkId)) {
      return fail('同じ作品が 2 か所に置かれています')
    }
    if (candidate.parentId) return checkOnTop(catalog, candidate, candidate.parentId, others, name, sizeOf)
  }

  const placed = floorFootprint(catalog, candidate, sizeOf)
  if (placed === undefined) {
    return fail(`家具「${candidate.kind === 'furniture' ? candidate.assetId : ''}」はありません`)
  }
  if (placed === null) return OK
  // 床の物の部屋（家具は roomId、床の作品は roomId か省けばリビング）。position はこの部屋の中の位置
  const roomId = roomOf(layout, candidate) ?? HUB
  const room = layout.rooms[roomId]
  // 使えない部屋（古い v2 の配置の、リビング以外）には置けない（Rust: parse_layout の roomId の検証。rejects_resized_rooms_and_unknown_room_ids）
  if (!room || !room.enabled) return fail(`${name(candidate)} は「${roomName(house, roomId) ?? roomId}」に置けません`)
  const where = roomName(house, roomId)
  if (placed.wallArt !== null && candidate.kind === 'artwork') {
    // 壁に掛けた作品：写真の額縁だけ。背面を壁に付け（90° ごとの向き）、壁の内側からはみ出さず、
    // 底面は WALL_MOUNT_MIN から、上端が壁の高さまで（Rust: check_placement の Mount::WallArt。wall-frame-* の extra）
    if (!sizeOf?.(candidate.artworkId)?.frame) {
      return fail(`${name(candidate)} は壁に掛けられません (壁に掛けられるのは写真の額縁だけです)`)
    }
    if (!artWallSide(layout, roomId, candidate.rotationY, placed.rect)) {
      return fail(`${name(candidate)} は${where ? ` ${where} の` : ''}壁に背中を付けて掛けてください`)
    }
    if (!insideRoom(placed.rect, roomInnerRect(layout, roomId))) {
      return fail(`${name(candidate)} が${where ? ` ${where} の` : ''}壁からはみ出しています`)
    }
    const [lo, hi] = [WALL_MOUNT_MIN, WALL_HEIGHT - placed.wallArt]
    const y = candidate.position[1]
    if (y < lo - TOLERANCE || y > hi + TOLERANCE) {
      return fail(`${name(candidate)} の高さは ${lo.toFixed(2)}〜${hi.toFixed(2)} m にしてください`)
    }
  } else if (placed.wall && candidate.kind === 'furniture') {
    // 壁の家具：背面を壁に付け（90° ごとの向き）、壁の内側からはみ出さず、決まった高さの範囲に掛ける
    // （Rust: wall_furniture_hangs_on_a_wall、wall_furniture_height_range）
    if (!wallSideOf(layout, roomId, candidate)) {
      return fail(`${name(candidate)} は${where ? ` ${where} の` : ''}壁に背中を付けて掛けてください`)
    }
    if (!insideRoom(placed.rect, roomInnerRect(layout, roomId))) {
      return fail(`${name(candidate)} が${where ? ` ${where} の` : ''}壁からはみ出しています`)
    }
    const [lo, hi] = mountRange(placed.wall)
    const y = candidate.position[1]
    if (y < lo - TOLERANCE || y > hi + TOLERANCE) {
      return fail(`${name(candidate)} の高さは ${lo.toFixed(2)}〜${hi.toFixed(2)} m にしてください`)
    }
  } else if (!insideRoom(placed.rect, roomRect(layout, roomId))) {
    // 壁から 12 cm 空ける。ラグも同じ。矩形は部屋ごと（Rust: rejects_wall_clearance、rejects_wall_clearance_in_small_room、
    // rug_may_overlap の最後のケース）
    return fail(`${name(candidate)} が${where ? ` ${where} の` : ''}壁に近すぎます (壁から 12 cm 空けてください)`)
  }
  // 出入口の前はふさがない。ラグも同じ（Rust: check_placement の DoorPolicy::OnlyMoved。保存のときは新しく置いた・動かした物だけを
  // 調べるので、前から置いてある物が出入口の前にあっても、その物はそのまま描く。ここでは candidate がいつも「動かした物」。
  // door_zone_only_for_moved_objects、default_layout_tolerates_pieces_in_door_zones）
  if (doorZones(house, roomId).some((zone) => rectOverlap(zone, placed.rect))) {
    return fail(`${name(candidate)} は${where ? ` ${where} の` : ''}出入口の前には置けません`)
  }
  // ラグはほかの物と重なってよい（Rust: rug_may_overlap）
  if (placed.decor) return OK
  // 物どうしは、同じ部屋の中でだけ、足元と高さの範囲の両方が重なったら置けない。別の部屋の同じ部屋の中の位置は重ならない
  // （Rust: rejects_furniture_overlap、rooms_do_not_collide_across_rooms、wall_furniture_overlaps_by_height）
  for (const other of others) {
    const o = floorFootprint(catalog, other, sizeOf)
    if (!o || o.decor || roomOf(layout, other) !== roomId) continue
    if (rectOverlap(placed.rect, o.rect) && spanOverlap(placed.span, o.span)) {
      return fail(`${name(candidate)} と ${name(other)} が重なっています`)
    }
  }
  return OK
}

/** 家具の上の作品：親は面のある家具（入れ子は不可）、面からはみ出さない、同じ面の隣の作品と重ならない */
function checkOnTop(
  catalog: HomeCatalog,
  candidate: ArtworkObject,
  parentId: string,
  others: LayoutObject[],
  name: (o: LayoutObject) => string,
  sizeOf?: SizeOf,
): PlaceCheck {
  // 親は家具だけ。作品の上の作品（入れ子）や無い家具は不可（Rust: artwork_requires_support_parent）
  const parent = others.find((o): o is FurnitureObject => o.kind === 'furniture' && o.id === parentId)
  if (!parent) return fail(`${name(candidate)} の置き場所「${parentId}」がありません (作品は家具の上にだけ置けます)`)
  const support = assetOf(catalog, parent.assetId)
  // 面の無い家具（ソファなど）には載せない（Rust: artwork_requires_support_parent）
  if (!support?.support) return fail(`${name(parent)} の上には作品を置けません`)
  const surface = surfaceOf(support, candidate.surface)
  // 家具に無い面には置けない（Rust: artwork_surface_defaults_to_the_top）
  if (!surface) return fail(`${support.name_ja} には「${surfaceIdOf(candidate)}」という置き場所がありません`)

  // 作品の置いた後の寸法（面の art_fit に収めたもの。実寸が分からなければ枠そのもの）を作品の向きで回した外接長方形が、
  // 面からはみ出さない（Rust: art_rect。artwork_must_fit_top_rect、real_size_allows_90_degrees_on_narrow_tops）
  const rect = artRect(candidate, surface.art_fit, sizeOf)
  if (!rectInside(rect, topRect(surface))) {
    return fail(`${name(candidate)} が ${support.name_ja} の置き場所からはみ出しています`)
  }
  // 同じ家具の同じ面の作品どうしは重ならない。隣の作品もそれぞれの実寸で測る。段が違えば重ならない
  // （Rust: sibling_artworks_may_not_overlap、siblings_use_their_own_sizes、artworks_on_different_shelves_do_not_collide）
  for (const other of others) {
    if (other.kind !== 'artwork' || other.parentId !== parentId || surfaceIdOf(other) !== surface.id) continue
    if (rectOverlap(rect, artRect(other, surface.art_fit, sizeOf))) return fail(`${name(candidate)} と ${name(other)} が重なっています`)
  }
  return OK
}

/**
 * 配置全体を検証する（Rust: check_placement。default_layout_validates）。
 * ctx.house を渡すと、全部の物に出入口の前の判定をする（Rust の DoorPolicy::OnlyMoved に全部の id を渡したのと同じ。
 * Rust は起動時・修復時には DoorPolicy::Ignore で調べず、保存時に動かした物だけを調べる）
 */
export function validateLayout(layout: Layout, catalog: HomeCatalog, ctx: PlaceContext = {}): PlaceCheck {
  const ids = new Set<string>()
  for (const o of layout.objects) {
    if (ids.has(o.id)) return fail(`id「${o.id}」が重複しています`)
    ids.add(o.id)
  }
  for (const o of layout.objects) {
    const check = canPlace(layout, catalog, o, ctx)
    if (!check.ok) return check
  }
  return OK
}

// =============================
// 世界座標
// =============================

/**
 * 置いた物の世界座標と向き（ラジアン）。作品なら置く面の中心（家具の上なら面の高さ、床なら 0）。Rust: world_of（world_of_adds_room_origin）
 * 家具・床の作品は、部屋の中心 O（roomOrigin）+ 部屋の中の位置：世界 = (O.x + x, y, O.z + z)（y は壁の家具の高さ。床の物は 0）。
 * 親 P（部屋の中の位置 (P.x, P.y, P.z)、向き θ、面の中心 (ax, h, az)）の上の作品 (x, 0, z) は、
 * x' = (ax+x)·cosθ + (az+z)·sinθ、z' = −(ax+x)·sinθ + (az+z)·cosθ、世界 = (O.x + P.x + x', P.y + h, O.z + P.z + z')、向き = θ + rotationY
 * （wall_furniture_footprint_and_world）
 * （O は親の家具の部屋の中心。部屋の平行移動は親に 1 回だけ掛かる。
 *   Rust: world_of_rotated_parent。リビングのサイドボード (2.7, 0, 1.55)・θ = −π/2・作品 (0.5, 0, 0) → (2.7, 0.891, 2.05)）
 * house が無い（古いサーバー）ときは、どの部屋の中心も原点
 */
export function worldOf(
  layout: Layout,
  catalog: HomeCatalog,
  object: LayoutObject,
  house?: House | null,
): { position: Vec3; rotationY: number } | null {
  if (object.kind === 'furniture' || !object.parentId) {
    const [ox, oz] = roomOrigin(house, object.roomId ?? HUB)
    // 壁の家具と壁に掛けた作品は底面の高さ、床の物は 0
    const y = object.kind === 'furniture' || isWallArt(object) ? object.position[1] : 0
    return { position: [ox + object.position[0], y, oz + object.position[2]], rotationY: object.rotationY }
  }
  const parent = furnitureById(layout, object.parentId)
  const asset = parent ? assetOf(catalog, parent.assetId) : undefined
  const anchor = asset ? surfaceOf(asset, object.surface)?.anchor : undefined
  if (!parent || !anchor) return null
  const [ox, oz] = roomOrigin(house, parent.roomId)
  const [ax, h, az] = anchor
  const x = ax + object.position[0]
  const z = az + object.position[2]
  const sin = Math.sin(parent.rotationY)
  const cos = Math.cos(parent.rotationY)
  return {
    position: [ox + parent.position[0] + x * cos + z * sin, parent.position[1] + h, oz + parent.position[2] - x * sin + z * cos],
    rotationY: parent.rotationY + object.rotationY,
  }
}

/**
 * 世界の (x, z) を、親の家具から見た位置（回す前の向き・面の中心 anchor が原点）に直す。worldOf の逆。
 * origin は親の家具の部屋の中心（roomOrigin）。家具の上の作品をドラッグするときに使う
 */
export function parentLocalFromWorld(
  parent: FurnitureObject,
  world: [number, number],
  topAnchor?: Vec3 | null,
  origin: [number, number] = [0, 0],
): [number, number] {
  const dx = world[0] - origin[0] - parent.position[0]
  const dz = world[1] - origin[1] - parent.position[2]
  const sin = Math.sin(parent.rotationY)
  const cos = Math.cos(parent.rotationY)
  return [dx * cos - dz * sin - (topAnchor?.[0] ?? 0), dx * sin + dz * cos - (topAnchor?.[2] ?? 0)]
}

// =============================
// 自動で置く場所
// =============================

/** 新しい家具の仮の id（layout に無い値。findPlacement の判定だけで使う） */
const PROBE_ID = '__probe__'

/** 中心から渦巻き状に 0.5 m ごとに並べた候補の点（中心に近い順、同じ距離なら角度の順） */
function spiral(maxRing: number): [number, number][] {
  const points: [number, number][] = []
  for (let ring = 0; ring <= maxRing; ring++) {
    const onRing: [number, number][] = []
    for (let i = -ring; i <= ring; i++) {
      for (let j = -ring; j <= ring; j++) {
        if (Math.max(Math.abs(i), Math.abs(j)) === ring) onRing.push([i, j])
      }
    }
    onRing.sort((a, b) => a[0] ** 2 + a[1] ** 2 - (b[0] ** 2 + b[1] ** 2) || Math.atan2(a[1], a[0]) - Math.atan2(b[1], b[0]))
    points.push(...onRing)
  }
  return points
}

/**
 * 壁の家具を、部屋の中の点 (x, z) にいちばん近い壁に付ける（背面を壁の内側の面に、正面を部屋の中へ向ける）。
 * 壁に沿った位置は、壁の内側からはみ出さない範囲に寄せる。高さ y はそのまま。模様替えのドラッグで使う（サーバーは寄せずに判定だけする）
 */
export function snapToWall(layout: Layout, asset: CatalogAsset, roomId: RoomId, x: number, z: number, y: number): { position: Vec3; rotationY: number } {
  const inner = roomInnerRect(layout, roomId)
  const half = asset.dimensions_meters[0] / 2
  const along = (v: number, lo: number, hi: number) => (lo + half > hi - half ? (lo + hi) / 2 : Math.min(Math.max(v, lo + half), hi - half))
  const distances: [WallSide, number][] = [
    ['north', z - inner.minZ],
    ['south', inner.maxZ - z],
    ['west', x - inner.minX],
    ['east', inner.maxX - x],
  ]
  const [side] = distances.reduce((best, d) => (d[1] < best[1] ? d : best))
  const rotationY = WALL_ROTATION[side]
  switch (side) {
    case 'north':
      return { position: [along(x, inner.minX, inner.maxX), y, inner.minZ], rotationY }
    case 'south':
      return { position: [along(x, inner.minX, inner.maxX), y, inner.maxZ], rotationY }
    case 'west':
      return { position: [inner.minX, y, along(z, inner.minZ, inner.maxZ)], rotationY }
    case 'east':
      return { position: [inner.maxX, y, along(z, inner.minZ, inner.maxZ)], rotationY }
  }
}

/**
 * 壁に掛ける作品（幅 w・高さ h・奥行き d）を、部屋の中の点 (x, z) にいちばん近い壁に掛ける（背面を壁の内側の面に、正面を部屋の中へ）。
 * 位置は足元の中心なので、壁から奥行きの半分だけ部屋の中。壁に沿った位置は壁の内側からはみ出さない範囲に、
 * 高さ y は WALL_MOUNT_MIN から上端が壁の高さまでの範囲に寄せる。模様替えのドラッグで使う（サーバーは寄せずに判定だけする）
 */
export function snapArtToWall(
  layout: Layout,
  roomId: RoomId,
  [w, h, d]: Vec3,
  x: number,
  z: number,
  y: number,
): { position: Vec3; rotationY: number } {
  const inner = roomInnerRect(layout, roomId)
  const half = w / 2
  const along = (v: number, lo: number, hi: number) => (lo + half > hi - half ? (lo + hi) / 2 : Math.min(Math.max(v, lo + half), hi - half))
  const height = Math.min(Math.max(y, WALL_MOUNT_MIN), Math.max(WALL_MOUNT_MIN, WALL_HEIGHT - h))
  const distances: [WallSide, number][] = [
    ['north', z - inner.minZ],
    ['south', inner.maxZ - z],
    ['west', x - inner.minX],
    ['east', inner.maxX - x],
  ]
  const [side] = distances.reduce((best, dist) => (dist[1] < best[1] ? dist : best))
  const rotationY = WALL_ROTATION[side]
  switch (side) {
    case 'north':
      return { position: [along(x, inner.minX, inner.maxX), height, inner.minZ + d / 2], rotationY }
    case 'south':
      return { position: [along(x, inner.minX, inner.maxX), height, inner.maxZ - d / 2], rotationY }
    case 'west':
      return { position: [inner.minX + d / 2, height, along(z, inner.minZ, inner.maxZ)], rotationY }
    case 'east':
      return { position: [inner.maxX - d / 2, height, along(z, inner.minZ, inner.maxZ)], rotationY }
  }
}

/**
 * 家具を部屋 roomId に新しく置く場所を探す。その部屋の中心から 0.5 m 間隔で渦巻き状に、向き 0 で置ける最初の場所
 * （位置は部屋の中の位置）。見つからなければ null。ctx.sizeOf は床置きの作品の大きさ、ctx.house は出入口の前を避けるのに使う。
 * 壁の家具は、北・西・東・南の壁の順に、壁の中央から 0.5 m ずつ左右へ、決まった高さ（mount_height）で置ける最初の場所
 */
export function findPlacement(
  layout: Layout,
  catalog: HomeCatalog,
  assetId: string,
  roomId: RoomId = HUB,
  ctx: PlaceContext = {},
): { position: Vec3; rotationY: number } | null {
  const asset = assetOf(catalog, assetId)
  if (asset && isWallAsset(asset)) return findWallPlacement(layout, catalog, asset, roomId, ctx)
  const room = roomRect(layout, roomId)
  const maxRing = Math.ceil(Math.max(room.maxX, -room.minX, room.maxZ, -room.minZ) / SEARCH_STEP)
  for (const [i, j] of spiral(maxRing)) {
    const position: Vec3 = [i * SEARCH_STEP, 0, j * SEARCH_STEP]
    const probe: FurnitureObject = { kind: 'furniture', id: PROBE_ID, assetId, roomId, position, rotationY: 0 }
    if (canPlace(layout, catalog, probe, ctx).ok) return { position, rotationY: 0 }
  }
  return null
}

/** 壁の家具を新しく掛ける場所（findPlacement の壁の家具） */
function findWallPlacement(
  layout: Layout,
  catalog: HomeCatalog,
  asset: CatalogAsset,
  roomId: RoomId,
  ctx: PlaceContext,
): { position: Vec3; rotationY: number } | null {
  const inner = roomInnerRect(layout, roomId)
  const [lo, hi] = mountRange(asset)
  const y = Math.min(Math.max(asset.mount_height ?? lo, lo), hi)
  const half = asset.dimensions_meters[0] / 2
  for (const side of ['north', 'west', 'east', 'south'] as WallSide[]) {
    const length = side === 'north' || side === 'south' ? inner.maxX - inner.minX : inner.maxZ - inner.minZ
    const steps = Math.floor((length / 2 - half) / SEARCH_STEP)
    for (let i = 0; i <= steps * 2; i++) {
      // 0, +0.5, −0.5, +1.0, …（壁の中央から近い順）
      const offset = (i % 2 === 1 ? 1 : -1) * Math.ceil(i / 2) * SEARCH_STEP
      const x = side === 'west' ? inner.minX : side === 'east' ? inner.maxX : offset
      const z = side === 'north' ? inner.minZ : side === 'south' ? inner.maxZ : offset
      const position: Vec3 = [x, y, z]
      const rotationY = WALL_ROTATION[side]
      const probe: FurnitureObject = { kind: 'furniture', id: PROBE_ID, assetId: asset.id, roomId, position, rotationY }
      if (canPlace(layout, catalog, probe, ctx).ok) return { position, rotationY }
    }
  }
  return null
}

// =============================
// 模様替えの操作（どれも新しい Layout を返す。元の layout は書き換えない）
// =============================

/** 新しい object id（例: "home-3f9a1c2e"。Rust の new_object_id と同じ形）。layout の中で重ならないものを返す */
export function newObjectId(layout: Layout, prefix: string) {
  const used = new Set(layout.objects.map((o) => o.id))
  for (;;) {
    // crypto.randomUUID は http の LAN アドレスでは使えないので、Math.random で作る
    const hex = Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0')
    const id = `${prefix}-${hex}`
    if (!used.has(id)) return id
  }
}

/** 同じ id の物を置き換える */
export function replaceObject(layout: Layout, object: LayoutObject): Layout {
  return { ...layout, objects: layout.objects.map((o) => (o.id === object.id ? object : o)) }
}

/**
 * 物を取り除く。家具なら、その上の作品も一緒に取り除く
 * （保存すると、サーバーがその作品を「飾っていない」に戻す）
 */
export function removeObject(layout: Layout, id: string): Layout {
  return {
    ...layout,
    objects: layout.objects.filter((o) => o.id !== id && !(o.kind === 'artwork' && o.parentId === id)),
  }
}

export type EditResult = { ok: true; layout: Layout } | { ok: false; reason: string }

/**
 * 物を、その向きで置ける範囲（家具の上の作品は面、家具と床の作品は自分の部屋）の中へ寄せる（clampToRect）。
 * 範囲が分からない物（無い家具・無い面）はそのまま返す（canPlace が理由を出す）
 */
export function clampObject(layout: Layout, catalog: HomeCatalog, object: LayoutObject, sizeOf?: SizeOf): LayoutObject {
  const [x0, , z0] = object.position
  const at = (x: number, z: number): LayoutObject => ({ ...object, position: [x, 0, z] })
  if (object.kind === 'furniture') {
    const asset = assetOf(catalog, object.assetId)
    if (!asset) return object
    // 壁の家具は、いちばん近い壁に付ける（高さはそのまま）
    if (isWallAsset(asset)) return { ...object, ...snapToWall(layout, asset, object.roomId, x0, z0, object.position[1]) }
    const [w, , d] = asset.dimensions_meters
    return at(...clampToRect(roomRect(layout, object.roomId), w, d, object.rotationY, x0, z0))
  }
  // 壁に掛けた作品は、いちばん近い壁に掛け直す（高さはそのまま）
  if (object.placement === 'wall') {
    const size = wallArtSize(object, sizeOf)
    return { ...object, ...snapArtToWall(layout, object.roomId ?? HUB, size, x0, z0, object.position[1]) }
  }
  if (!object.parentId) {
    const [w, d] = artExtent(object.artworkId, FLOOR_ART_FIT, object.rotationY, sizeOf)
    return at(...clampToRect(roomRect(layout, object.roomId ?? HUB), w, d, object.rotationY, x0, z0))
  }
  const parent = furnitureById(layout, object.parentId)
  const support = parent ? assetOf(catalog, parent.assetId) : undefined
  const surface = support ? surfaceOf(support, object.surface) : undefined
  if (!surface) return object
  const [w, d] = artExtent(object.artworkId, surface.art_fit, object.rotationY, sizeOf)
  return at(...clampToRect(topRect(surface), w, d, object.rotationY, x0, z0))
}

/**
 * 物を delta（ラジアン）だけ回す。回すと外接長方形の縦横が入れ替わるので、置ける範囲の中へ寄せ直してから（clampObject）
 * ほかの物と重ならないかを調べる。置けなければ、その理由を返す
 */
export function rotateObject(layout: Layout, catalog: HomeCatalog, id: string, delta: number, ctx: PlaceContext = {}): EditResult {
  const object = layout.objects.find((o) => o.id === id)
  if (!object) return { ok: false, reason: '選んだ物が見つかりません' }
  // 壁の家具は壁に背中を付けたまま。向きは、ほかの壁へドラッグすると変わる
  if (object.kind === 'furniture' && isWallAsset(assetOf(catalog, object.assetId))) {
    return { ok: false, reason: '壁の家具は回せません。ほかの壁へはドラッグで動かせます' }
  }
  if (isWallArt(object)) return { ok: false, reason: '壁に掛けた作品は回せません。ほかの壁へはドラッグで動かせます' }
  const rotated = clampObject(layout, catalog, { ...object, rotationY: wrapAngle(object.rotationY + delta) }, ctx.sizeOf)
  const check = canPlace(layout, catalog, rotated, ctx)
  return check.ok ? { ok: true, layout: replaceObject(layout, rotated) } : check
}

/** 壁の家具・壁に掛けた作品を上げ下げするときの 1 回の幅（m） */
export const MOUNT_STEP = 0.1

/**
 * 壁の家具・壁に掛けた作品を delta（m）だけ上げ下げする。掛けられる高さの範囲（壁の家具は mountRange、
 * 作品は WALL_MOUNT_MIN から上端が壁の高さまで）に寄せ、1 cm に丸めてから、ほかの物と重ならないかを調べる。
 * 壁の物でなければ、範囲の端でもう動かないときは、その理由を返す
 */
export function raiseObject(layout: Layout, catalog: HomeCatalog, id: string, delta: number, ctx: PlaceContext = {}): EditResult {
  const object = layout.objects.find((o) => o.id === id)
  const asset = object?.kind === 'furniture' ? assetOf(catalog, object.assetId) : undefined
  let range: [number, number] | null = null
  if (object?.kind === 'furniture' && asset && isWallAsset(asset)) range = mountRange(asset)
  else if (object?.kind === 'artwork' && object.placement === 'wall') range = [WALL_MOUNT_MIN, WALL_HEIGHT - wallArtSize(object, ctx.sizeOf)[1]]
  if (!object || !range) return { ok: false, reason: '上げ下げできるのは壁に掛けた物だけです' }
  const [lo, hi] = range
  const y = Math.round(Math.min(Math.max(object.position[1] + delta, lo), hi) * 100) / 100
  if (Math.abs(y - object.position[1]) < 1e-9) return { ok: false, reason: delta > 0 ? 'これより上には掛けられません' : 'これより下には掛けられません' }
  const raised: LayoutObject = { ...object, position: [object.position[0], y, object.position[2]] }
  const check = canPlace(layout, catalog, raised, ctx)
  return check.ok ? { ok: true, layout: replaceObject(layout, raised) } : check
}

/** 家具を部屋 roomId に 1 つ足す（置ける場所は findPlacement で探す）。置く場所が無ければ null */
export function addFurniture(
  layout: Layout,
  catalog: HomeCatalog,
  assetId: string,
  roomId: RoomId = HUB,
  ctx: PlaceContext = {},
): { layout: Layout; id: string } | null {
  const spot = findPlacement(layout, catalog, assetId, roomId, ctx)
  if (!spot) return null
  const id = newObjectId(layout, 'home')
  const object: FurnitureObject = { kind: 'furniture', id, assetId, roomId, position: spot.position, rotationY: spot.rotationY }
  return { layout: { ...layout, objects: [...layout.objects, object] }, id }
}
