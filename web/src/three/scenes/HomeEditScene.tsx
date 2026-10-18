// ⑫ 模様替えの 3D。カメラの側の壁（手前の 2 面）と部屋どうしの間の壁をカットした家（今はリビングだけ）を斜め上から見下ろし、家具や作品をドラッグで動かす。
// 見回す向きに制限は無い（どの向きから見ても、カットする壁はカメラに合わせて HouseShells が入れ替える）。
//
//   部屋 … 画面で選んだ部屋（roomId。house.rooms の部屋。今はリビングだけ）へカメラが寄る（見る先は部屋の中心 house.rooms[].origin）。
//          はじめは南東の斜め上から。切り替えたときは、そのとき見ている向きのまま寄る（RoomCamera）。
//          どの部屋の物も選べてドラッグできるが、物は自分の部屋（roomOf）から出ない（部屋をまたぐ移動はしない）。
//          家具と床の作品の位置は部屋の中の位置（部屋の中心が原点）。ポインタの先（世界座標）から部屋の中心を引いて求める。
//          出入口の前（placement.ts の doorZones）には置けない（板が赤になり、離すと元に戻る）。ドラッグ中はその部屋の出入口の前を薄い赤で示す。
//
//   押す   … 物を選ぶ（page の onSelect）。そのまま 5 px 以上動かすとドラッグになる
//   ドラッグ … ポインタが動くたびに置き先を決め、置けるかどうか（placement.ts の canPlace）で板が緑・赤に変わる。
//            離したとき、置けるなら onCommit（新しい配置）、置けないなら元の位置に戻す
//   床を押す … 何もない床をタップすると選択を外す（ドラッグで見回したときは外さない）
//   キー   … R で 90° 回す、Delete / Backspace で消す、Esc で選択を外す（この画面を表示している間だけ window で受ける）
//
// ドラッグの置き先（ポインタが動くたびに計算する）：
//   家具 … 押した点の高さの水平な面（THREE.Plane）との交点。自分の部屋の中（壁から 12 cm）に寄せる（clampToRect）。
//          上の作品は家具のグループの子なので一緒に動く。
//          壁の家具は、その点にいちばん近い壁に背中を付けて、壁に沿って動かす（snapToWall。ほかの壁へ移ると向きも変わる）。高さは変えない
//   作品 … ポインタの先の家具（同じ部屋の FURN_ のグループだけにレイを当てる。作品 ARTWORK_ の当たりは飛ばす）に面があれば、
//          当たった高さ以下でいちばん高い面（天板・本棚の段）に載せ換える。面の高さの水平な面との交点を、親から見た位置に直し、
//          面の中へ寄せる（作品の置いた後の寸法で）。家具に当たらなければ（面の無い家具・ラグに当たったときも）床：
//          y = 0 の面との交点を、作品の部屋の中へ寄せる。ほかの家具・本棚の段・床へ載せ換えた配置は、離したときにそのまま確定する
//   押した点と物の中心のずれ（offset）は、押したときと同じ家具・面の上にいる間だけ保つ（ほかの面へ移ったらポインタの真下に置く）。
//   寄せる前に 1 cm に丸める（丸めてから寄せるので、丸めてはみ出すことはない）。
// 選んだ物の印は、物の下に敷く板（Footprint）で出す。GLB のマテリアルは全部の物・全部の画面で共有しているので、
// 物そのものに色を付けてはいけない。
// ドラッグの間は OrbitControls を止める（指で物を動かしたときにカメラが回らないように）。

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useThree, type ThreeEvent } from '@react-three/fiber'
import { OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import type {
  ArtworkObject,
  CatalogSurface,
  FurnitureObject,
  HomeCatalog,
  House,
  Layout,
  LayoutObject,
  Museum,
  RoomId,
  Vec3,
} from '../../api'
import { CameraFlight, type CameraGoal } from './CameraFlight'
import { HomeObjects, type PreviewTransform } from './home/HomeObjects'
import { HouseShells } from './home/HouseShells'
import { hasHouseModel, houseBounds, houseRoomsOf, wallThicknessOf } from './home/house'
import {
  FLOOR_ART_FIT,
  HUB,
  TOP_SURFACE,
  artExtent,
  assetOf,
  canPlace,
  clampToRect,
  doorZones,
  footprint,
  furnitureById,
  furnitureRect,
  isWallAsset,
  namesFromSlots,
  parentLocalFromWorld,
  replaceObject,
  roomOf,
  roomOrigin,
  roomRect,
  sizesFromSlots,
  snapToWall,
  surfaceIdOf,
  surfaceOf,
  topRect,
  worldOf,
  type NameOf,
  type PlaceCheck,
  type SizeOf,
} from './home/placement'
import { Stage } from './Stage'

/** 見下ろす角度の範囲（真上からの角度）。水平の向きは制限しない */
const MIN_POLAR = 0.2 * Math.PI
const MAX_POLAR = 0.42 * Math.PI
/**
 * はじめの位置（南東の斜め上。リビングの中心から約 14 m）と、見る先（部屋の中心から見た値）。
 * ほかの部屋へは、そのとき見ている向きのまま寄る（RoomCamera）
 */
const EYE: Vec3 = [8, 8.2, 8]
const TARGET: Vec3 = [0, 0.3, 0]
/** EYE を決めたときの部屋の大きさ（m。リビング）。小さい部屋には、大きさに比例して近づく */
const EYE_ROOM_SIZE = 8
/** これ以上（px）動かしたらドラッグにする。それまではタップ（選ぶだけ） */
const DRAG_START_PX = 5
/** 床のタップとみなす動きの大きさ（px）。これより動いたら見回しなので、選択を外さない */
const TAP_PX = 6
/** ドラッグ中に物を持ち上げる高さ（m）。持ち上げたことが分かるように */
const LIFT = 0.04
/** 位置を丸める単位（m）。配置 JSON の数字を短くする */
const GRID = 0.01
/** 床の板の高さ。ラグ（厚さ 0.023 m）の上に出す */
const FLOOR_OVERLAY_Y = 0.03
/** 天板の上の板の高さ（天板からの距離） */
const TOP_OVERLAY_Y = 0.004
/** 出入口の前の板の高さ（選んだ物の板より下） */
const DOOR_OVERLAY_Y = 0.02
/** 板を物よりひと回り大きくする幅（m）。物の陰に隠れず縁が見えるように */
const OVERLAY_PAD = 0.06
/** 作品の載せ換えで、ポインタが当たった高さよりこれだけ（m）上の面まで選ぶ（棚板の縁を指したときに、その段に載せられるように） */
const SURFACE_PICK_SLACK = 0.05
const UP = new THREE.Vector3(0, 1, 0)

const round = (n: number) => Math.round(n / GRID) * GRID

/** CSS の色の変数（styles/tokens.css）。読めなければ fallback */
function cssColor(name: string, fallback: string) {
  try {
    const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
    return /^#[0-9a-f]{3,8}$/i.test(value) ? value : fallback
  } catch {
    return fallback
  }
}

/** 床の板の形（1 m 四方。大きさは scale で変える）。全部の板で使い回す */
const UNIT_PLANE = new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2)
const UNIT_EDGES = new THREE.EdgesGeometry(UNIT_PLANE)

/** 選んだ物の下に敷く板。置けるときは緑（--green）、置けないときは赤（--red） */
function Footprint({ center, size, rotationY, ok }: { center: Vec3; size: [number, number]; rotationY: number; ok: boolean }) {
  const colors = useMemo(() => ({ ok: cssColor('--green', '#4caf6e'), bad: cssColor('--red', '#c4402f') }), [])
  const color = ok ? colors.ok : colors.bad
  return (
    <group position={center} rotation-y={rotationY} scale={[size[0] + OVERLAY_PAD * 2, 1, size[1] + OVERLAY_PAD * 2]}>
      <mesh geometry={UNIT_PLANE} renderOrder={1}>
        <meshBasicMaterial color={color} transparent opacity={0.32} depthWrite={false} toneMapped={false} />
      </mesh>
      {/* 縁の線は物の手前にも描く（物の真下の板は、上から見ると物に隠れるため） */}
      <lineSegments geometry={UNIT_EDGES} renderOrder={2}>
        <lineBasicMaterial color={color} transparent opacity={0.95} depthTest={false} depthWrite={false} toneMapped={false} />
      </lineSegments>
    </group>
  )
}

/** 出入口の前の、物を置けない場所（世界座標の中心と大きさ）。ドラッグ中に薄い赤で示す */
function DoorZones({ zones }: { zones: { center: Vec3; size: [number, number] }[] }) {
  const color = useMemo(() => cssColor('--red', '#c4402f'), [])
  return (
    <>
      {zones.map((zone, i) => (
        <mesh key={i} geometry={UNIT_PLANE} position={zone.center} scale={[zone.size[0], 1, zone.size[1]]} renderOrder={1}>
          <meshBasicMaterial color={color} transparent opacity={0.16} depthWrite={false} toneMapped={false} />
        </mesh>
      ))}
    </>
  )
}

/**
 * 選んだ物の板を置く場所と大きさ（世界座標）。置けるかどうかの判定と同じ外接長方形にする
 * （作品は置いた後の寸法。実寸が分からなければ枠そのもの。placement.ts の artRect と同じ）
 */
function footprintOf(layout: Layout, catalog: HomeCatalog, object: LayoutObject, sizeOf: SizeOf, house: House | null | undefined) {
  const world = worldOf(layout, catalog, object, house)
  if (!world) return null
  const onFloor = (w: number, d: number) => {
    const r = footprint(0, 0, w, d, object.rotationY)
    return { center: [world.position[0], FLOOR_OVERLAY_Y, world.position[2]] as Vec3, size: [r.maxX - r.minX, r.maxZ - r.minZ] as [number, number], rotationY: 0 }
  }
  if (object.kind === 'furniture') {
    const asset = assetOf(catalog, object.assetId)
    if (!asset) return null
    // 足元（壁の家具は原点が背面なので、中心は正面の方へずれる）を床に敷く
    const r = furnitureRect(asset, object)
    const [ox, oz] = roomOrigin(house, object.roomId)
    return {
      center: [ox + (r.minX + r.maxX) / 2, FLOOR_OVERLAY_Y, oz + (r.minZ + r.maxZ) / 2] as Vec3,
      size: [r.maxX - r.minX, r.maxZ - r.minZ] as [number, number],
      rotationY: 0,
    }
  }
  if (!object.parentId) return onFloor(...artExtent(object.artworkId, FLOOR_ART_FIT, object.rotationY, sizeOf))
  // 家具の上の作品：載せている面の枠に収めた寸法で、親から見た外接長方形を作り、親の向きで回して置く
  const parent = furnitureById(layout, object.parentId)
  const support = parent ? assetOf(catalog, parent.assetId) : undefined
  const fit = support ? surfaceOf(support, object.surface)?.art_fit : undefined
  if (!parent || !fit) return null
  const [w, d] = artExtent(object.artworkId, fit, object.rotationY, sizeOf)
  const r = footprint(0, 0, w, d, object.rotationY)
  return {
    center: [world.position[0], world.position[1] + TOP_OVERLAY_Y, world.position[2]] as Vec3,
    size: [r.maxX - r.minX, r.maxZ - r.minZ] as [number, number],
    rotationY: parent.rotationY,
  }
}

/** 祖先（自分を含む）に、名前が prefix で始まるものがあれば、いちばん近いものを返す */
function ancestorNamed(object: THREE.Object3D | null, prefix: string): THREE.Object3D | null {
  for (let o = object; o; o = o.parent) if (o.name.startsWith(prefix)) return o
  return null
}

/**
 * 作品を載せ換える面を選ぶ：当たった高さ（世界の y。家具の原点は床にある）+ 5 cm 以下で、いちばん高い面。
 * どの面よりも低い所に当たったら、いちばん低い面
 */
function pickSurface(surfaces: CatalogSurface[], hitY: number): CatalogSurface | null {
  let below: CatalogSurface | null = null
  let lowest: CatalogSurface | null = null
  for (const s of surfaces) {
    if (s.anchor[1] <= hitY + SURFACE_PICK_SLACK && (!below || s.anchor[1] > below.anchor[1])) below = s
    if (!lowest || s.anchor[1] < lowest.anchor[1]) lowest = s
  }
  return below ?? lowest
}

/** 家具の上の作品（配置 JSON の形）。天板なら surface を省く。roomId は付けない（親の家具の部屋になる） */
function artworkOn(object: ArtworkObject, parentId: string, surfaceId: string, position: Vec3): ArtworkObject {
  const next: ArtworkObject = { kind: 'artwork', id: object.id, artworkId: object.artworkId, parentId, position, rotationY: object.rotationY }
  if (surfaceId !== TOP_SURFACE) next.surface = surfaceId
  return next
}

/** 部屋 roomId の床の作品（配置 JSON の形。position は部屋の中の位置）。parentId・surface は付けない */
function artworkOnFloor(object: ArtworkObject, position: Vec3, roomId: RoomId): ArtworkObject {
  return { kind: 'artwork', id: object.id, artworkId: object.artworkId, roomId, position, rotationY: object.rotationY }
}

/** ドラッグ中の状態（ポインタが動くたびに変わるので ref に持つ） */
interface Drag {
  id: string
  pointerId: number
  /** 押したときの物（配置 JSON の値） */
  object: LayoutObject
  /** 物の部屋（押したとき）。ドラッグの間、物はこの部屋から出ない */
  roomId: RoomId
  /** 家具：押した点の高さ（この高さの水平な面の上で動かす） */
  grabY: number
  /**
   * 物の世界 XZ − 押したときのポインタの XZ（押した点と物の中心のずれを保つ）。
   * 家具は押した点の高さ、作品は載せている面（床なら y = 0）の高さで、ポインタの先の点を測る
   */
  offset: [number, number]
  /** 作品：レイを当てる家具のグループ（同じ部屋の FURN_）。ドラッグの間は家具が変わらないので、最初に動かしたときに 1 回だけ集める */
  groups: THREE.Object3D[] | null
  startX: number
  startY: number
  moved: boolean
  candidate: LayoutObject | null
  check: PlaceCheck | null
}

export interface HomeEditSceneProps {
  /** 家の建物（house）・家具の一覧（catalog）・作品のモデル（slots）を使う */
  museum: Museum
  /** 表示する配置（画面の下書き） */
  layout: Layout
  /** 画面で選んでいる部屋。カメラがこの部屋へ寄る。変わったら、ドラッグの途中ならやめる */
  roomId: RoomId
  selectedId: string | null
  /** true の間は物を押しても・キーを押しても何もしない（追加のシートを開いている間・通信中） */
  locked?: boolean
  onSelect: (objectId: string | null) => void
  /** ドラッグして置ける場所で離したとき。動かした後の配置 */
  onCommit: (next: Layout) => void
  /** ドラッグ中、置けない場所ならその理由、置けるなら null（ドラッグが終わったときも null） */
  onPreview?: (reason: string | null) => void
  /** 置けない場所で離したとき（物は元の位置に戻る） */
  onReject?: (reason: string) => void
  /** R キー */
  onRotate?: () => void
  /** Delete / Backspace キー */
  onDelete?: () => void
  onReady?: () => void
}

/**
 * 選んだ部屋へカメラを寄せる（見る先は部屋の中心の少し上。距離は部屋の大きさに比例）。
 *   はじめ（OrbitControls ができる前に決まる最初の部屋）… EYE の向き（南東の斜め上）から
 *   部屋を切り替えたとき … そのとき見ている向き（見る先からカメラへの向き）と距離のまま、新しい部屋の中心へ移る。
 *                         距離は、前の部屋と新しい部屋の大きさの比で伸び縮みさせ、OrbitControls の距離の範囲に収める
 *                         （範囲の外へ飛ぶと、移動の途中で OrbitControls に引き戻されるため）
 */
function RoomCamera({ museum, roomId }: { museum: Museum; roomId: RoomId }) {
  const camera = useThree((s) => s.camera)
  const controls = useThree((s) => s.controls) as unknown as OrbitControlsImpl | null
  const rooms = houseRoomsOf(museum)
  const room = rooms.find((r) => r.id === roomId) ?? rooms[0]
  const origin = room?.origin[0] ?? 0
  const originZ = room?.origin[1] ?? 0
  const scale = room ? Math.max(room.size[0], room.size[1]) / EYE_ROOM_SIZE : 1
  // いま見ている部屋の大きさの倍率（切り替えたときの距離の比に使う）。目的地を決めた後に新しい部屋の値にする
  const shownScale = useRef(scale)
  useEffect(() => {
    shownScale.current = scale
  }, [scale])

  const goal = useMemo<CameraGoal>(() => {
    const target = new THREE.Vector3(origin + TARGET[0], TARGET[1], originZ + TARGET[2])
    let offset: THREE.Vector3
    if (controls) {
      // 部屋を切り替えた：今のカメラの向きと距離のまま
      offset = camera.position.clone().sub(controls.target)
      const distance = offset.length() * (scale / shownScale.current)
      offset.setLength(THREE.MathUtils.clamp(distance, controls.minDistance, controls.maxDistance))
    } else {
      offset = new THREE.Vector3(EYE[0] - TARGET[0], EYE[1] - TARGET[1], EYE[2] - TARGET[2]).multiplyScalar(scale)
    }
    return { target, position: target.clone().add(offset), key: `room-${roomId}-${origin},${originZ}` }
    // controls は依存に入れない。OrbitControls ができたとき（最初の描画の後）に目的地を決め直すと、
    // はじめの部屋が EYE の向きにならないため。部屋が変わったときだけ、そのときのカメラから決める
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roomId, origin, originZ, scale, camera])
  return <CameraFlight goal={goal} />
}

export function HomeEditScene(props: HomeEditSceneProps) {
  const { museum, layout, roomId, onReady } = props
  if (!hasHouseModel(museum)) return null
  return (
    <Stage camera={{ position: EYE, fov: 45 }}>
      {/* 壁紙と床材は下書きの配置から（テーマを選ぶと、保存を待たずにその場で変わる。部屋ごと） */}
      <HouseShells museum={museum} layout={layout} cutaway="house" onReady={onReady} />
      <Editor {...props} />
      <OrbitControls
        makeDefault
        target={TARGET}
        enableDamping
        dampingFactor={0.08}
        enablePan={false}
        minDistance={6}
        maxDistance={16}
        minPolarAngle={MIN_POLAR}
        maxPolarAngle={MAX_POLAR}
      />
      <RoomCamera museum={museum} roomId={roomId} />
    </Stage>
  )
}

/** ドラッグ中の仮の置き場所。HomeObjects に渡す位置と向き、置けるかどうか、板を作るための候補（配置 JSON の形） */
type Preview = PreviewTransform & { ok: boolean; candidate: LayoutObject }

function Editor({
  museum,
  layout,
  roomId,
  selectedId,
  locked = false,
  onSelect,
  onCommit,
  onPreview,
  onReject,
  onRotate,
  onDelete,
}: HomeEditSceneProps) {
  const camera = useThree((s) => s.camera)
  const gl = useThree((s) => s.gl)
  const scene = useThree((s) => s.scene)
  const controls = useThree((s) => s.controls) as unknown as OrbitControlsImpl | null
  const catalog = museum.catalog
  const house = museum.house
  const nameOf: NameOf = useMemo(() => namesFromSlots(museum.slots), [museum.slots])
  const sizeOf: SizeOf = useMemo(() => sizesFromSlots(museum.slots), [museum.slots])
  // 何もない所のタップを受ける板は、家全体（全部の部屋の外形）を覆う
  const rooms = houseRoomsOf(museum)
  const wall = wallThicknessOf(museum)
  const floor = useMemo(() => {
    const b = houseBounds(rooms, wall)
    return { center: [(b.minX + b.maxX) / 2, 0.002, (b.minZ + b.maxZ) / 2] as Vec3, size: [b.maxX - b.minX, b.maxZ - b.minZ] as [number, number] }
  }, [rooms, wall])

  const [preview, setPreview] = useState<Preview | null>(null)
  const drag = useRef<Drag | null>(null)
  const floorRef = useRef<THREE.Mesh>(null)
  /** ドラッグをやめる（元の位置に戻す）。window のイベントを受ける effect の中で作る */
  const cancelDrag = useRef<(() => void) | null>(null)

  // window のイベントから最新の値を読むため、毎回の描画で ref に入れておく
  const latest = useRef({ layout, catalog, house, nameOf, sizeOf, locked, controls, onSelect, onCommit, onPreview, onReject, onRotate, onDelete })
  useLayoutEffect(() => {
    latest.current = { layout, catalog, house, nameOf, sizeOf, locked, controls, onSelect, onCommit, onPreview, onReject, onRotate, onDelete }
  })

  // ドラッグ（window で受ける。指が 3D の外へ出ても続けられるように）とキー操作
  useEffect(() => {
    // R3F が共有している raycaster（ポインタのイベント用）は触らず、ドラッグ専用のものを使う
    const raycaster = new THREE.Raycaster()
    const ndc = new THREE.Vector2()
    const hit = new THREE.Vector3()
    const plane = new THREE.Plane()

    /** レイと高さ y の水平な面の交点（XZ）。交わらなければ null */
    const onPlane = (y: number): [number, number] | null => {
      plane.set(UP, -y)
      return raycaster.ray.intersectPlane(plane, hit) ? [hit.x, hit.z] : null
    }

    /** 家具：押した点の高さの面の上で動かし、自分の部屋の中へ寄せる（世界座標から部屋の中心を引いて、部屋の中の位置にする） */
    const moveFurniture = (d: Drag, object: FurnitureObject): LayoutObject | null => {
      const l = latest.current
      const asset = assetOf(l.catalog, object.assetId)
      const at = onPlane(d.grabY)
      if (!asset || !at) return null
      const [w, , depth] = asset.dimensions_meters
      const [ox, oz] = roomOrigin(l.house, d.roomId)
      if (isWallAsset(asset)) {
        const snapped = snapToWall(l.layout, asset, d.roomId, round(at[0] + d.offset[0] - ox), round(at[1] + d.offset[1] - oz), object.position[1])
        return { ...object, ...snapped }
      }
      const [x, z] = clampToRect(
        roomRect(l.layout, d.roomId),
        w,
        depth,
        object.rotationY,
        round(at[0] + d.offset[0] - ox),
        round(at[1] + d.offset[1] - oz),
      )
      return { ...object, position: [x, 0, z] }
    }

    /**
     * 作品：ポインタの先の家具の面（無ければ床）に載せる。
     * offset は、押したときと同じ家具・面（床なら床）の上にいる間だけ足す
     */
    const moveArtwork = (d: Drag, object: ArtworkObject): LayoutObject | null => {
      const l = latest.current
      const grabbedOn = object.parentId ? `${object.parentId}/${surfaceIdOf(object)}` : ''
      const offsetOn = (key: string): [number, number] => (key === grabbedOn ? d.offset : [0, 0])

      // 家具のグループだけにレイを当てる（見えない床の板などは混ぜない。three の Raycaster は visible = false を飛ばさない）。
      // 作品は自分の部屋から出さないので、同じ部屋の家具だけ
      if (!d.groups) {
        d.groups = []
        for (const o of l.layout.objects) {
          const group = o.kind === 'furniture' && o.roomId === d.roomId ? scene.getObjectByName(`FURN_${o.id}`) : undefined
          if (group) d.groups.push(group)
        }
      }
      // 家具の上の作品（動かしている作品も）の当たりは飛ばして、その奥の家具を見る
      const first = raycaster.intersectObjects(d.groups, true).find((h) => !ancestorNamed(h.object, 'ARTWORK_'))
      const furnitureId = first ? ancestorNamed(first.object, 'FURN_')?.userData.objectId : undefined
      const parent = typeof furnitureId === 'string' ? furnitureById(l.layout, furnitureId) : undefined
      const support = parent ? assetOf(l.catalog, parent.assetId) : undefined
      const surface = first && support?.support ? pickSurface(support.surfaces, first.point.y) : null

      if (parent && surface) {
        const at = onPlane(surface.anchor[1])
        if (!at) return null
        const [ox, oz] = offsetOn(`${parent.id}/${surface.id}`)
        const [lx, lz] = parentLocalFromWorld(parent, [at[0] + ox, at[1] + oz], surface.anchor, roomOrigin(l.house, parent.roomId))
        const [w, depth] = artExtent(object.artworkId, surface.art_fit, object.rotationY, l.sizeOf)
        const [x, z] = clampToRect(topRect(surface), w, depth, object.rotationY, round(lx), round(lz))
        return artworkOn(object, parent.id, surface.id, [x, 0, z])
      }

      // 家具に当たらない（面の無い家具・ラグを含む）：作品の部屋の床に置く（部屋の中の位置）
      const at = onPlane(0)
      if (!at) return null
      const [ox, oz] = offsetOn('')
      const [rx, rz] = roomOrigin(l.house, d.roomId)
      const [w, depth] = artExtent(object.artworkId, FLOOR_ART_FIT, object.rotationY, l.sizeOf)
      const [x, z] = clampToRect(roomRect(l.layout, d.roomId), w, depth, object.rotationY, round(at[0] + ox - rx), round(at[1] + oz - rz))
      return artworkOnFloor(object, [x, 0, z], d.roomId)
    }

    const finish = (cancelled: boolean) => {
      const d = drag.current
      if (!d) return
      drag.current = null
      const l = latest.current
      if (l.controls) l.controls.enabled = true
      try {
        gl.domElement.releasePointerCapture(d.pointerId)
      } catch {
        /* すでに外れている */
      }
      document.body.style.cursor = ''
      setPreview(null)
      if (!d.moved) return
      l.onPreview?.(null)
      if (!cancelled && d.candidate && d.check?.ok) l.onCommit(replaceObject(l.layout, d.candidate))
      else if (!cancelled && d.check && !d.check.ok) l.onReject?.(d.check.reason)
    }

    const onMove = (e: PointerEvent) => {
      const d = drag.current
      if (!d || e.pointerId !== d.pointerId) return
      if (!d.moved) {
        if (Math.hypot(e.clientX - d.startX, e.clientY - d.startY) < DRAG_START_PX) return
        d.moved = true
        document.body.style.cursor = 'grabbing'
      }
      const rect = gl.domElement.getBoundingClientRect()
      ndc.set(((e.clientX - rect.left) / rect.width) * 2 - 1, -((e.clientY - rect.top) / rect.height) * 2 + 1)
      raycaster.setFromCamera(ndc, camera)
      // 家具と床の作品の位置は部屋の中の位置（部屋の中心が原点）、家具の上の作品は親から見た位置
      const candidate = d.object.kind === 'furniture' ? moveFurniture(d, d.object) : moveArtwork(d, d.object)
      if (!candidate) return
      const l = latest.current
      // house を渡すので、出入口の前も置けない場所になる
      const check = canPlace(l.layout, l.catalog, candidate, { nameOf: l.nameOf, sizeOf: l.sizeOf, house: l.house })
      d.candidate = candidate
      d.check = check
      const [x, , z] = candidate.position
      // 家具は持ち上げた高さ（壁の家具は掛けている高さから）、作品は持ち上げる分だけ（高さは載せる面で決まる）
      const lift = candidate.kind === 'furniture' ? candidate.position[1] + LIFT : LIFT
      setPreview({
        id: d.id,
        // 作品は載せ換え先（床なら null と部屋）も渡す。HomeObjects がその家具のグループ（床なら部屋のグループ）の下に描く
        ...(candidate.kind === 'artwork'
          ? { parentId: candidate.parentId ?? null, surface: candidate.surface ?? null, roomId: candidate.roomId }
          : {}),
        position: [x, lift, z],
        rotationY: candidate.rotationY,
        ok: check.ok,
        candidate,
      })
      l.onPreview?.(check.ok ? null : check.reason)
    }

    const onUp = (e: PointerEvent) => {
      if (drag.current && e.pointerId === drag.current.pointerId) finish(e.type === 'pointercancel')
    }

    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.isComposing) return
      const target = e.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return
      const l = latest.current
      if (e.key === 'Escape') {
        if (drag.current) finish(true)
        else l.onSelect(null)
        return
      }
      if (l.locked || drag.current?.moved) return
      if (e.key === 'r' || e.key === 'R') {
        e.preventDefault()
        l.onRotate?.()
      } else if (e.key === 'Delete' || e.key === 'Backspace') {
        e.preventDefault()
        l.onDelete?.()
      }
    }

    cancelDrag.current = () => finish(true)
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onUp)
    window.addEventListener('keydown', onKey)
    return () => {
      cancelDrag.current = null
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      window.removeEventListener('pointercancel', onUp)
      window.removeEventListener('keydown', onKey)
      // ドラッグの途中で画面を離れたとき
      if (drag.current) {
        if (latest.current.controls) latest.current.controls.enabled = true
        drag.current = null
      }
      document.body.style.cursor = ''
    }
  }, [camera, gl, scene])

  // 部屋を切り替えたら、ドラッグの途中ならやめる（物は元の位置に戻る。選択は画面が外す）
  useEffect(() => {
    cancelDrag.current?.()
  }, [roomId])

  /** 物を押した：選んで、ドラッグの準備をする（動かすまではドラッグにしない） */
  const onObjectPointerDown = (objectId: string, e: ThreeEvent<PointerEvent>) => {
    const l = latest.current
    if (l.locked || drag.current) return
    // マウスは左ボタンだけ（右ボタンなどは OrbitControls に任せる）
    if (e.pointerType === 'mouse' && e.button !== 0) return
    const object = l.layout.objects.find((o) => o.id === objectId)
    const world = object ? worldOf(l.layout, l.catalog, object, l.house) : null
    const objectRoom = object ? roomOf(l.layout, object) : undefined
    if (!object || !world || !objectRoom) return
    l.onSelect(objectId)

    // 押した点と物の中心のずれ。作品は、ドラッグ中と同じく載せている面（床なら y = 0）の高さでポインタの先を測る
    // （押した点そのもの（作品の側面など）で測ると、動かし始めに作品が跳ぶ）
    let pointer: [number, number] = [e.point.x, e.point.z]
    if (object.kind === 'artwork') {
      const at = e.ray.intersectPlane(new THREE.Plane(UP.clone(), -world.position[1]), new THREE.Vector3())
      if (at) pointer = [at.x, at.z]
    }
    // OrbitControls より先にこのイベントを受けるので、ここで止めればカメラは回らない
    if (l.controls) l.controls.enabled = false
    try {
      gl.domElement.setPointerCapture(e.pointerId)
    } catch {
      /* 対応していない環境では window のイベントだけで続ける */
    }
    drag.current = {
      id: objectId,
      pointerId: e.pointerId,
      object,
      roomId: objectRoom,
      grabY: e.point.y,
      offset: [world.position[0] - pointer[0], world.position[2] - pointer[1]],
      groups: null,
      startX: e.nativeEvent.clientX,
      startY: e.nativeEvent.clientY,
      moved: false,
      candidate: null,
      check: null,
    }
  }

  /** 何もない床をタップしたら選択を外す。物の上のタップや、ドラッグで見回したときは外さない */
  const onFloorClick = (e: ThreeEvent<MouseEvent>) => {
    if (latest.current.locked || e.delta > TAP_PX) return
    if (e.intersections[0]?.eventObject !== floorRef.current) return
    onSelect(null)
  }

  // 選んだ物の板。ドラッグ中はその候補（載せ換え先の家具・面・床を含む）で
  const overlay = useMemo(() => {
    const selected = selectedId ? layout.objects.find((o) => o.id === selectedId) : undefined
    if (!selected) return null
    const moving = preview && preview.id === selected.id ? preview : null
    const at = footprintOf(layout, catalog, moving ? moving.candidate : selected, sizeOf, house)
    return at ? { ...at, ok: moving ? moving.ok : true } : null
  }, [selectedId, layout, catalog, preview, sizeOf, house])

  // ドラッグ中の床の物（家具・床の作品）の部屋の、出入口の前（世界座標）。家具の上へ載せている作品のときは出さない
  const doors = useMemo(() => {
    const candidate = preview?.candidate
    if (!candidate || (candidate.kind === 'artwork' && candidate.parentId)) return []
    const room = roomOf(layout, candidate) ?? HUB
    const [ox, oz] = roomOrigin(house, room)
    return doorZones(house, room).map((r) => ({
      center: [ox + (r.minX + r.maxX) / 2, DOOR_OVERLAY_Y, oz + (r.minZ + r.maxZ) / 2] as Vec3,
      size: [r.maxX - r.minX, r.maxZ - r.minZ] as [number, number],
    }))
  }, [preview, layout, house])

  return (
    <>
      <HomeObjects
        layout={layout}
        catalog={catalog}
        slots={museum.slots}
        house={house}
        // 模様替えでは、スマホでも全部の作品を置く（置いていない作品は選べないため）
        maxArtworks={Infinity}
        onObjectPointerDown={onObjectPointerDown}
        previewTransform={preview}
      />
      {/* 家全体の床の見えない板（何もない所のタップを受ける）。家の床（y = 0）のすぐ上 */}
      <mesh ref={floorRef} visible={false} rotation-x={-Math.PI / 2} position={floor.center} onClick={onFloorClick}>
        <planeGeometry args={floor.size} />
      </mesh>
      {doors.length > 0 && <DoorZones zones={doors} />}
      {overlay && <Footprint center={overlay.center} size={overlay.size} rotationY={overlay.rotationY} ok={overlay.ok} />}
    </>
  )
}
