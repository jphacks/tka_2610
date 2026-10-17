// 家の建物（壁・床・柱）を部屋ごとに置く部品。家の建物を描くのは、どの 3D 画面でもここだけ（家具と作品は HomeObjects）。
//
//   部屋の定義は /api/museum の house.rooms（Rust: home.rs の ROOM_DEFS）。部屋ごとに 1 つの GLB（model_url。部屋の中心が原点）を
//   MuseumModel で読み込み、部屋の中心（origin）へ平行移動したグループ `SHELL_<部屋>` の中に置く。
//   MuseumModel は複製した建物の行列を固定する（matrixAutoUpdate = false）ので、建物そのものは動かさず、親のグループで動かす。
//   壁紙と床材は配置 JSON の rooms[部屋]（部屋ごと。模様替えでは下書き）。テーマの材質は theme.ts が建物ごと（MuseumModel の複製ごと）に
//   当てるので、1 部屋のテーマを変えてもほかの部屋には移らない。
//   ただし、部屋どうしの間の壁はリビングの GLB だけが持っていて、隣の部屋に向いた面には印（userData.faceRoom）がある。
//   その面には印の部屋の rooms[] を当てる（どの建物にも faceThemes = rooms を渡し、theme.ts が印を見て選ぶ）。
//   なので、ほかの部屋のテーマを変えると、その部屋から見える 4 面目の壁（リビングの建物の一部）も一緒に変わる。
//   model_url が null の部屋は描かない（1 回だけ console に出す）。house が無い古いサーバーでは、model_url のリビング 1 部屋。
//
// 壁のカット（cutaway が false でないとき）は、カメラに合わせてここで当てる（MuseumModel には cutaway = false を渡す）：
//   CutawayFollower が毎フレーム、部屋ごとにカメラの位置（部屋の中心から見た向き）から手前の 2 面を選び（cutaway.ts の facingSides）、
//   'house' ならさらに出入口のある壁（house.ts の doorSidesOf）を足して、前と変わった部屋だけ applyCutaway で当て直す。
//   なので、どの向きから見ても、カメラの側の壁が隠れて部屋の中が見える。
//   カメラが部屋の中（床の範囲の内側で、壁の高さ WALL_TOP より下）にいるときは、位置では見ている壁を切ってしまうので、
//   見ている向きの逆（カメラの背中側の 2 面）をカットする。ゆらぎ止めの前の結果（RoomCut.facing）は、どちらの決め方でも共有する。
//   建物が読み込まれたとき・テーマを当て直したとき（MuseumModel の onLoaded。名前のあるノードの visible が戻る）は、その場で当て直す
//   （最初のフレームから正しく見えるように）。一人称で歩く画面（cutaway = false）では CutawayFollower を置かず、カットには触らない。
//
// onReady は、描く建物が全部そろったときに 1 回だけ呼ぶ（画面の「準備しています…」を消す。鑑賞モードでは歩き始められるようにする）。

import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import type { HouseRoom, Layout, Museum, RoomId, Side } from '../../../api'
import { MuseumModel } from '../models'
import { applyCutaway, facingSides, type Facing } from './cutaway'
import { WALL_TOP, doorSidesOf, houseRoomsOf, shellsOf, type Shell } from './house'

/** model_url の無い部屋を知らせたか（同じ部屋を何度も出さない） */
const warnedMissing = new Set<string>()

/** カメラの見ている向き（updateCut で毎フレーム使い回す） */
const viewDir = new THREE.Vector3()
/**
 * カメラが部屋の中にいるときのゆらぎ止め（見ている向きの成分。長さ 1 の向きの x・z なので単位は無い）。
 * ほぼ軸に沿って見ているとき、少し首を振るたびに背中側の壁が入れ替わらないようにする
 */
const INSIDE_HYSTERESIS = 0.1

/**
 * 描く建物の一覧。HouseShells と同じもの（鑑賞モードが、いくつ読み込めばそろうかを数えるのに使う）。
 * walk のときは、walk_model_url があればリビングの建物の代わりに使う
 */
export function useShells(museum: Museum, walk = false): Shell[] {
  const shells = useMemo(() => shellsOf(museum, { walk }), [museum, walk])
  useEffect(() => {
    for (const room of houseRoomsOf(museum)) {
      if (room.model_url || warnedMissing.has(room.id)) continue
      warnedMissing.add(room.id)
      console.warn(`部屋「${room.name}」(${room.id}) の建物の GLB (model_url) がありません。この部屋の建物は描きません`)
    }
  }, [museum])
  return shells
}

/** 部屋 1 つの壁のカットの状態 */
interface RoomCut {
  /** 読み込んだ建物（MuseumModel の複製） */
  root: THREE.Object3D
  /** 最後に当てたカットの向き（並べて | でつないだもの）。変わったときだけ当て直す。'' はまだ当てていない */
  key: string
  /** 最後に選んだ手前の 2 面（facingSides のゆらぎ止めに渡す） */
  facing?: Facing
}

/**
 * カメラの位置から、部屋 room の建物に当てるカットの向きを決めて当てる。withDoors なら出入口のある壁も足す。
 * カメラが部屋の中にいるときは、位置の代わりに見ている向きの逆（背中側の 2 面）で決める（西を見ていれば東の壁を切る）。
 * force でなければ、前と同じ向きなら何もしない。当てたら true
 */
function updateCut(cut: RoomCut, room: HouseRoom, camera: THREE.Camera, withDoors: boolean, force: boolean): boolean {
  const dx = camera.position.x - room.origin[0]
  const dz = camera.position.z - room.origin[1]
  const inside = Math.abs(dx) < room.size[0] / 2 && Math.abs(dz) < room.size[1] / 2 && camera.position.y < WALL_TOP
  let facing: Facing
  if (inside) {
    camera.getWorldDirection(viewDir)
    facing = facingSides(-viewDir.x, -viewDir.z, cut.facing, INSIDE_HYSTERESIS)
  } else {
    facing = facingSides(dx, dz, cut.facing)
  }
  cut.facing = facing
  const sides = new Set<Side>([facing.ew, facing.ns])
  if (withDoors) for (const side of doorSidesOf(room)) sides.add(side)
  const key = [...sides].sort().join('|')
  if (!force && key === cut.key) return false
  cut.key = key
  applyCutaway(cut.root, sides)
  return true
}

/**
 * カメラに合わせて壁のカットを入れ替える（cutaway が false でないときだけ置く）。
 * 毎フレーム、読み込めた部屋ごとに向きを決め直し、変わった部屋だけ当て直す。
 * マップは変化があるときだけ描く（frameloop="demand"）ので、当て直したら描き直しを頼む
 */
function CutawayFollower({ shells, cuts, withDoors }: { shells: Shell[]; cuts: Map<string, RoomCut>; withDoors: boolean }) {
  const invalidate = useThree((s) => s.invalidate)
  useFrame(({ camera }) => {
    let changed = false
    for (const { room } of shells) {
      const cut = cuts.get(room.id)
      if (cut && updateCut(cut, room, camera, withDoors, false)) changed = true
    }
    if (changed) invalidate()
  })
  // 外したとき（cutaway が false に変わったとき）は、カットを全部元に戻す
  useEffect(
    () => () => {
      for (const cut of cuts.values()) {
        applyCutaway(cut.root, null)
        cut.key = ''
      }
    },
    [cuts],
  )
  return null
}

export function HouseShells({
  museum,
  layout = museum.layout,
  cutaway = false,
  walk = false,
  onReady,
  onLoaded,
}: {
  museum: Museum
  /** 壁紙と床材を読む配置（rooms[部屋]）。模様替えでは下書き。省くと museum.layout */
  layout?: Layout
  /**
   * 壁のカット。true はカメラの側の 2 面（部屋ごとに、カメラの位置から毎フレーム決める）、'house' はさらに
   * 部屋どうしの間の壁（出入口のある壁）もいつもカットする（家全体を見下ろす画面）。一人称で歩く画面では false
   */
  cutaway?: boolean | 'house'
  /** 鑑賞モード：walk_model_url があれば、リビングの建物の代わりに使う */
  walk?: boolean
  /** 描く建物が全部そろったとき（1 回だけ） */
  onReady?: () => void
  /** 建物を読み込んだとき・テーマの材質を差し替えたとき（MuseumModel の onLoaded）。部屋の id も渡す */
  onLoaded?: (root: THREE.Object3D, roomId: RoomId) => void
}) {
  const shells = useShells(museum, walk)
  const materials = museum.catalog.materials
  const camera = useThree((s) => s.camera)
  const invalidate = useThree((s) => s.invalidate)

  // 読み込んだ建物の部屋。全部そろったら onReady を 1 回だけ呼ぶ
  const loaded = useRef(new Set<string>())
  const reported = useRef(false)
  const latestReady = useRef(onReady)
  useEffect(() => {
    latestReady.current = onReady
  })
  const markLoaded = useCallback(
    (roomId: string) => {
      loaded.current.add(roomId)
      if (reported.current || !shells.every((s) => loaded.current.has(s.room.id))) return
      reported.current = true
      latestReady.current?.()
    },
    [shells],
  )

  // 部屋の id → 壁のカットの状態（CutawayFollower と共有する。中身だけを書き換える）
  const [cuts] = useState(() => new Map<string, RoomCut>())
  /** 建物を読み込んだ・visible を戻されたとき：今のカメラで、その場で当て直す（前と同じ向きでも当てる） */
  const followNow = useCallback(
    (room: HouseRoom, root: THREE.Object3D, withDoors: boolean) => {
      let cut = cuts.get(room.id)
      if (!cut || cut.root !== root) {
        cut = { root, key: '', facing: cut?.facing }
        cuts.set(room.id, cut)
      }
      updateCut(cut, room, camera, withDoors, true)
      invalidate()
    },
    [cuts, camera, invalidate],
  )

  return (
    <>
      {cutaway !== false && <CutawayFollower shells={shells} cuts={cuts} withDoors={cutaway === 'house'} />}
      {shells.map(({ room, url }) => (
        <group key={room.id} name={`SHELL_${room.id}`} position={[room.origin[0], 0, room.origin[1]]}>
          {/* 部屋ごとに分けて、読み込めた部屋から出す */}
          <Suspense fallback={null}>
            <MuseumModel
              url={url}
              cutaway={false}
              theme={layout.rooms[room.id]}
              faceThemes={layout.rooms}
              materials={materials}
              onReady={() => markLoaded(room.id)}
              onLoaded={(root) => {
                if (cutaway !== false) followNow(room, root, cutaway === 'house')
                onLoaded?.(root, room.id)
              }}
            />
          </Suspense>
        </group>
      ))}
    </>
  )
}
