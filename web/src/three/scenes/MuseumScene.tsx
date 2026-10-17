// ⑤ おうちの中。カメラの側の壁（手前の 2 面）と部屋どうしの間の壁をカットした家（4 部屋）を、ドラッグでぐるりと見回す
// （どの向きからでも見られる。カットする壁はカメラに合わせて HouseShells が入れ替える）。作品をクリックすると詳細へ。
// ?focus=作品ID ならその作品の正面へ、?room=部屋ID ならその部屋（house.rooms の origin）へカメラが移動する。
// はじめはリビングを南東の斜め上から見渡す位置。視点の中心は家の外形（house.rooms から決める）の中だけを動く（home/ClampTarget）。
import { useMemo } from 'react'
import { OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { HouseRoom, Museum, SlotView } from '../../api'
import { CameraFlight, type CameraGoal } from './CameraFlight'
import { ClampTarget } from './home/ClampTarget'
import { HomeObjects } from './home/HomeObjects'
import { HouseShells } from './home/HouseShells'
import { hasHouseModel, houseBounds, houseRoomsOf, wallThicknessOf } from './home/house'
import { Stage } from './Stage'

/** はじめの位置と、部屋全体を見渡す位置（部屋の中心から見た値。リビングの中心が原点） */
const OVERVIEW_EYE = new THREE.Vector3(5.2, 4.2, 5.2)
const OVERVIEW_TARGET = new THREE.Vector3(0, 1, 0)
/** OVERVIEW_EYE を決めたときの部屋の大きさ（m）。部屋の大きさに比例して離れる（10 m のリビングなら 1.25 倍） */
const OVERVIEW_ROOM_SIZE = 8

/** 部屋を見渡すカメラの位置（部屋の中心から見た値）。部屋が無ければ OVERVIEW_EYE のまま */
function overviewEye(room: HouseRoom | undefined): THREE.Vector3 {
  const scale = room ? Math.max(room.size[0], room.size[1]) / OVERVIEW_ROOM_SIZE : 1
  return OVERVIEW_EYE.clone().multiplyScalar(scale)
}

/**
 * 作品の正面から見る位置。北や西を向いた作品も、その正面から見る
 * （どの向きからでも見回せて、カメラの側の壁はカットされるので、作品の手前の壁に隠れない）
 */
function slotGoal(slot: SlotView): CameraGoal {
  const [x, y, z] = slot.position
  // 下部のメッセージに隠れないよう、作品が画面のやや上に来る位置から見る
  const target = new THREE.Vector3(x, y + 0.1, z)
  // 作品の正面は +Z を yaw だけ回した向き。OrbitControls の水平の角度と同じ測り方
  const azimuth = THREE.MathUtils.degToRad(slot.yaw)
  const front = new THREE.Vector3(Math.sin(azimuth), 0, Math.cos(azimuth))
  const position = target.clone().add(front.multiplyScalar(2.3)).add(new THREE.Vector3(0, 0.75, 0))
  return { position, target, key: `slot-${slot.id}` }
}

/** 部屋全体を見渡す位置（部屋の中心 house.rooms[].origin を、南東の斜め上から） */
function roomGoal(rooms: HouseRoom[], roomId: string): CameraGoal | null {
  const room = rooms.find((r) => r.id === roomId)
  if (!room) return null
  const center = new THREE.Vector3(room.origin[0], 0, room.origin[1])
  return {
    position: center.clone().add(overviewEye(room)),
    target: center.clone().add(OVERVIEW_TARGET),
    key: `room-${roomId}`,
  }
}

export function MuseumScene({
  museum,
  focusId,
  roomId,
  onSelect,
  onReady,
}: {
  museum: Museum
  focusId?: string | null
  roomId?: string | null
  onSelect?: (artworkId: string) => void
  onReady?: () => void
}) {
  const rooms = houseRoomsOf(museum)
  const wall = wallThicknessOf(museum)
  const bounds = useMemo(() => houseBounds(rooms, wall), [rooms, wall])
  // はじめはリビングを見渡す（リビングの中心が原点）
  const startEye = overviewEye(rooms.find((r) => r.id === 'hub') ?? rooms[0])
  const goal = useMemo(() => {
    const slot = focusId ? museum.slots.find((s) => s.artwork?.id === focusId) : undefined
    if (slot) return slotGoal(slot)
    if (roomId) return roomGoal(rooms, roomId)
    return null
  }, [museum.slots, focusId, roomId, rooms])

  if (!hasHouseModel(museum)) return null

  return (
    <Stage camera={{ position: startEye.toArray(), fov: 50 }}>
      <HouseShells museum={museum} cutaway="house" onReady={onReady} />
      <HomeObjects layout={museum.layout} catalog={museum.catalog} slots={museum.slots} house={museum.house} onSelect={onSelect} />
      <OrbitControls
        makeDefault
        target={OVERVIEW_TARGET.toArray()}
        enableDamping
        dampingFactor={0.08}
        minDistance={1}
        maxDistance={12}
        minPolarAngle={0.15 * Math.PI}
        maxPolarAngle={0.5 * Math.PI}
        screenSpacePanning={false}
      />
      <ClampTarget bounds={bounds} />
      <CameraFlight goal={goal} />
    </Stage>
  )
}
