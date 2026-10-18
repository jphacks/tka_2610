// ホームの積み上げの建物（StackScene）で、部屋を狭く見せるための配置。表示だけに使い、保存はしない。
// 10 × 10 m の部屋に家具が少ないと、引いて見たときに何もない床ばかりになるので、
// 部屋の床と壁を横方向に s 倍（StackScene が建物のグループを [s, 1, s] にする）に縮め、家具と作品をその中へ寄せる。
// 家具と作品の大きさは変えない。おへやに入ったとき（ほかの画面）は今の広さのまま。
//
// 寄せ方：
//   床の物（家具・床の作品）… 位置を s 倍し、縮めた部屋の壁から 12 cm の内側に収まるよう寄せる（壁ぎわの物は壁ぎわのまま）
//   壁の家具 … 付いている壁を縮めた壁に移し、壁に沿った位置は s 倍して壁からはみ出さないよう寄せる。高さはそのまま
//   家具の上の作品 … 家具から見た位置なので、そのまま（家具と一緒に動く）
// どの s にするかは compactScale：小さい方から試して、寄せた配置が置き方の決まり（validateLayout。重なり・壁・壁の家具）に
// 通る、いちばん小さい s。全部の階を同じ s にする（階ごとに建物の大きさが変わらないように）。
// three.js を使わない純粋な関数だけ。

import type { HomeCatalog, Layout, LayoutObject } from '../../../api/types'
import {
  FLOOR_ART_FIT,
  HUB,
  WALL_MARGIN,
  artExtent,
  assetOf,
  footprint,
  furnitureRect,
  isWallAsset,
  validateLayout,
  wallSideOf,
  type Rect,
  type SizeOf,
} from './placement'

/** 試す縮め方（小さい順）。これより小さくすると、家具ばかりで部屋らしく見えない */
const SCALES = [0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95]

/** lo〜hi に収める。範囲が逆なら（物が部屋より大きい）真ん中 */
const clamp = (v: number, lo: number, hi: number) => (lo > hi ? (lo + hi) / 2 : Math.min(Math.max(v, lo), hi))

/** 床の物の足元の、位置（原点）から見た外接長方形。家具の上の作品と、無い家具は null */
function extentOf(catalog: HomeCatalog, object: LayoutObject, sizeOf?: SizeOf): Rect | null {
  if (object.kind === 'furniture') {
    const asset = assetOf(catalog, object.assetId)
    return asset ? furnitureRect(asset, { position: [0, 0, 0], rotationY: object.rotationY }) : null
  }
  if (object.parentId) return null
  const [w, d] = artExtent(object.artworkId, FLOOR_ART_FIT, object.rotationY, sizeOf)
  return footprint(0, 0, w, d, object.rotationY)
}

/** 部屋を s 倍に縮めた配置（部屋の大きさも s 倍。物の大きさはそのまま） */
export function compactLayout(layout: Layout, catalog: HomeCatalog, s: number, sizeOf?: SizeOf): Layout {
  const rooms = Object.fromEntries(
    Object.entries(layout.rooms).map(([id, room]) => [id, { ...room, width: room.width * s, depth: room.depth * s }]),
  ) as Layout['rooms']
  const objects = layout.objects.map((object): LayoutObject => {
    const e = extentOf(catalog, object, sizeOf)
    if (!e) return object
    const roomId = object.kind === 'furniture' ? object.roomId : (object.roomId ?? HUB)
    const room = layout.rooms[roomId] ?? layout.rooms.hub
    const hw = (room.width * s) / 2
    const hd = (room.depth * s) / 2
    const [x, y, z] = object.position

    if (object.kind === 'furniture' && isWallAsset(assetOf(catalog, object.assetId))) {
      // 壁の家具：縮めた壁に付け直す（付いている壁は元の配置で決める）
      const along = (v: number, lo: number, hi: number, min: number, max: number) => clamp(v * s, lo - min, hi - max)
      switch (wallSideOf(layout, roomId, object)) {
        case 'north':
          return { ...object, position: [along(x, -hw, hw, e.minX, e.maxX), y, -hd] }
        case 'south':
          return { ...object, position: [along(x, -hw, hw, e.minX, e.maxX), y, hd] }
        case 'west':
          return { ...object, position: [-hw, y, along(z, -hd, hd, e.minZ, e.maxZ)] }
        case 'east':
          return { ...object, position: [hw, y, along(z, -hd, hd, e.minZ, e.maxZ)] }
        default:
          return object
      }
    }
    // 床の物：s 倍して、縮めた部屋の壁から 12 cm の内側へ
    const cx = clamp(x * s, -hw + WALL_MARGIN - e.minX, hw - WALL_MARGIN - e.maxX)
    const cz = clamp(z * s, -hd + WALL_MARGIN - e.minZ, hd - WALL_MARGIN - e.maxZ)
    return { ...object, position: [cx, y, cz] }
  })
  return { ...layout, rooms, objects }
}

/** 全部の階を同じだけ縮めるときの、置き方の決まりに通るいちばん小さい s（どれも通らなければ 1 = 縮めない） */
export function compactScale(floors: { layout: Layout; sizeOf?: SizeOf }[], catalog: HomeCatalog): number {
  for (const s of SCALES) {
    const fits = floors.every(({ layout, sizeOf }) => validateLayout(compactLayout(layout, catalog, s, sizeOf), catalog, { sizeOf }).ok)
    if (fits) return s
  }
  return 1
}
