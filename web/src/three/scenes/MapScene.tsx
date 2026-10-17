// ⑦ マップ。家全体（4 部屋）を真上に近い斜め上から見下ろす（カメラの側の壁と部屋どうしの間の壁はカット。ぐるりと回しても入れ替わる）。
// はじめは家全体が収まる距離から見る。部屋の名前のラベルを押すと（画面の onRoom → focusRoom）、カメラがその部屋へ寄る。
// 部屋の位置と大きさは /api/museum の house.rooms、ラベルの作品の数は rooms（RoomView）の count。
import { useLayoutEffect, useMemo, useRef } from 'react'
import { useThree } from '@react-three/fiber'
import { Html, OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import type { HouseRoom, Museum, Vec3 } from '../../api'
import { CameraFlight, type CameraGoal } from './CameraFlight'
import { HomeObjects } from './home/HomeObjects'
import { HouseShells } from './home/HouseShells'
import { cornersOf, fitDistance, frameCenter, hasHouseModel, houseRoomsOf, roomBounds, wallThicknessOf } from './home/house'
import { Stage } from './Stage'
import './MapScene.css'

/** ラベルを出す高さ（壁の上の少し上, m） */
const LABEL_Y = 3.6
/** 見る先からカメラへの向き（真上に近い南東の斜め上） */
const DIRECTION: Vec3 = [3, 13, 3]
const FOV = 40
/** 家全体を収めるときの余白 */
const HOUSE_MARGIN = 1.08
/** 部屋に寄ったときの距離。8 m の部屋で 13.7 m（今までのマップと同じ）、部屋の大きさに比例させる */
const ROOM_DISTANCE_PER_METER = Math.hypot(...DIRECTION) / 8
/** 寄れる距離の下限と、家全体の距離に対する離れられる距離の倍率 */
const MIN_DISTANCE = 6
const MAX_DISTANCE_SCALE = 1.25

const unit = new THREE.Vector3(...DIRECTION).normalize()

/** 部屋の名前と飾っている作品の数のラベル。部屋の中心の上に出す。寄っている部屋のラベルは印を付ける */
function RoomLabels({
  rooms,
  museum,
  focusRoom,
  onRoom,
}: {
  rooms: HouseRoom[]
  museum: Museum
  focusRoom?: string | null
  onRoom?: (roomId: string) => void
}) {
  return (
    <>
      {rooms.map((room) => {
        const view = museum.rooms.find((r) => r.id === room.id)
        return (
          <Html key={room.id} position={[room.origin[0], LABEL_Y, room.origin[1]]} center zIndexRange={[10, 0]}>
            <button
              className={`room-label${focusRoom === room.id ? ' focused' : ''}`}
              aria-pressed={focusRoom === room.id}
              onClick={() => onRoom?.(room.id)}
            >
              {view?.name ?? room.name}
              <small>{view?.count ?? 0}</small>
            </button>
          </Html>
        )
      })}
    </>
  )
}

/**
 * カメラ：はじめは家全体（全部の部屋の外形の角）が収まる距離に置き、focusRoom があればその部屋へ寄る（CameraFlight）。
 * 寄った後に focusRoom が外れたら、家全体へ戻る
 */
function MapCamera({ rooms, wall, focusRoom }: { rooms: HouseRoom[]; wall: number; focusRoom?: string | null }) {
  const camera = useThree((s) => s.camera)
  const size = useThree((s) => s.size)
  const controls = useThree((s) => s.controls) as unknown as OrbitControlsImpl | null
  const invalidate = useThree((s) => s.invalidate)

  const house = useMemo(() => {
    const points = rooms.flatMap((room) => cornersOf(roomBounds(room, wall)))
    const target = frameCenter(points, DIRECTION)
    const distance = fitDistance(points, target, DIRECTION, FOV, size.width / Math.max(1, size.height), HOUSE_MARGIN)
    return { target, distance }
    // 画面の大きさが変わるたびに測り直すと、見回している途中で距離の上限が変わるので、はじめの大きさで決める
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rooms, wall])

  // はじめの位置（家全体）。OrbitControls ができてから 1 回だけ
  const placed = useRef(false)
  useLayoutEffect(() => {
    if (!controls || placed.current) return
    placed.current = true
    const target = new THREE.Vector3(...house.target)
    camera.position.copy(target).addScaledVector(unit, house.distance)
    controls.target.copy(target)
    controls.update()
    invalidate()
  }, [controls, camera, house, invalidate])

  // 一度でも部屋に寄ったら、focusRoom が外れたときに家全体へ戻る
  const focused = useRef(false)
  if (focusRoom) focused.current = true
  const goal = useMemo<CameraGoal | null>(() => {
    const room = focusRoom ? rooms.find((r) => r.id === focusRoom) : undefined
    if (room) {
      const target = new THREE.Vector3(room.origin[0], 0, room.origin[1])
      const distance = Math.max(room.size[0], room.size[1]) * ROOM_DISTANCE_PER_METER
      return { target, position: target.clone().addScaledVector(unit, distance), key: `room-${room.id}` }
    }
    if (!focused.current) return null
    const target = new THREE.Vector3(...house.target)
    return { target, position: target.clone().addScaledVector(unit, house.distance), key: 'house' }
  }, [focusRoom, rooms, house])

  return (
    <>
      <OrbitControls
        makeDefault
        enableDamping
        enablePan={false}
        minDistance={MIN_DISTANCE}
        maxDistance={house.distance * MAX_DISTANCE_SCALE}
        maxPolarAngle={0.3 * Math.PI}
      />
      <CameraFlight goal={goal} />
    </>
  )
}

export function MapScene({
  museum,
  focusRoom,
  onRoom,
  onReady,
}: {
  museum: Museum
  /** カメラを寄せる部屋（house.rooms の id）。null なら家全体 */
  focusRoom?: string | null
  /** 部屋の名前のラベルを押したとき */
  onRoom?: (roomId: string) => void
  onReady?: () => void
}) {
  const rooms = houseRoomsOf(museum)
  if (!hasHouseModel(museum)) return null

  return (
    <Stage camera={{ position: DIRECTION, fov: FOV }} frameloop="demand">
      <HouseShells museum={museum} cutaway="house" onReady={onReady} />
      <HomeObjects layout={museum.layout} catalog={museum.catalog} slots={museum.slots} house={museum.house} />
      <RoomLabels rooms={rooms} museum={museum} focusRoom={focusRoom} onRoom={onRoom} />
      <MapCamera rooms={rooms} wall={wallThicknessOf(museum)} focusRoom={focusRoom} />
    </Stage>
  )
}
