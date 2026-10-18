// ホームの積み上げの建物。ある年齢のおへや（/api/ages/{age} の rooms。1 階から）を、実際の 3D のおへや（建物・家具・作品）のまま縦に重ねて、
// 南東の斜め上から見る。階と階の間を大きく空け（浮いた積み木のように）、角度は浅め（約 17°）にするので、下の階の中も奥の壁まで見え、
// 壁も低い縁のようには見えない（上の階がすぐ上に乗っていた以前は、下の階がほとんど隠れていた）。カメラの側の壁はおへやごとにカットする。
// 階の左に「4さいのおへや 2（数）›」のラベルを出し、押すと onRoom（その階のおへやへ入る）。
// 建物・家具・作品を描くのは、ほかの画面と同じ HouseShells・HomeObjects（階ごとに高さをずらしたグループに入れるだけ）。
// 階が増えるとスマホで重くなるので、動きがあるときだけ描き（frameloop demand）、作品の数はスマホでは HomeObjects の決まり（近い 6 点）に任せる。
import { useMemo, useRef } from 'react'
import { useThree } from '@react-three/fiber'
import { Html, OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { AgeStack, Museum, StackRoom, Vec3 } from '../../api'
import { CameraFlight, type CameraGoal } from './CameraFlight'
import { HomeObjects } from './home/HomeObjects'
import { HouseShells } from './home/HouseShells'
import { WALL_TOP, cornersOf, fitDistance, frameCenter, roomBounds } from './home/house'
import { Stage } from './Stage'
import './StackScene.css'

/** 1 階分の高さ（m）。壁の高さに、上の階の床の下までのすき間（3.6 m。下の階の奥の壁が上の階に隠れないくらい）を足す */
export const FLOOR_PITCH = WALL_TOP + 3.6
/** 見る先からカメラへの向き（南東の斜め上。水平から約 17°。壁の高さが分かり、各階の中も見えるくらいの浅い角度） */
const DIRECTION: Vec3 = [1, 0.42, 1]
const FOV = 38
/** 建物全体を収めるときの余白 */
const MARGIN = 1.12

const unit = new THREE.Vector3(...DIRECTION).normalize()

/** HouseShells・HomeObjects に渡すための、1 階分のおうちの全体像（家の形と家具の一覧は年齢で共通） */
function museumOf(stack: AgeStack, floor: StackRoom): Museum {
  return {
    room: floor.room,
    today_label: '',
    name: floor.room.name,
    owner_name: '',
    model_url: null,
    walk_model_url: null,
    house: stack.house,
    total_artworks: floor.count,
    displayed_count: floor.count,
    capacity: floor.capacity,
    floors: [],
    rooms: [],
    slots: floor.slots,
    hidden_node_prefixes: [],
    layout: floor.layout,
    catalog: stack.catalog,
  }
}

/** 全部の階が入るように、カメラを置く（階の数や年齢が変わったら、そこへ飛ぶ） */
function StackCamera({ stack }: { stack: AgeStack }) {
  const size = useThree((s) => s.size)
  const floors = stack.rooms.length
  const frame = useMemo(() => {
    const wall = stack.house.wall_thickness
    const points: Vec3[] = []
    for (let i = 0; i < Math.max(1, floors); i++) {
      for (const room of stack.house.rooms) {
        for (const [x, y, z] of cornersOf(roomBounds(room, wall))) points.push([x, y + i * FLOOR_PITCH, z])
      }
    }
    const [tx, , tz] = frameCenter(points, DIRECTION)
    const target: Vec3 = [tx, (Math.max(1, floors) * FLOOR_PITCH - (FLOOR_PITCH - WALL_TOP)) / 2, tz]
    const distance = fitDistance(points, target, DIRECTION, FOV, size.width / Math.max(1, size.height), MARGIN)
    return { target, distance }
    // 画面の大きさが変わるたびに測り直すと、見回している途中で距離が変わるので、はじめの大きさで決める
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stack, floors])

  const goal = useMemo<CameraGoal>(() => {
    const target = new THREE.Vector3(...frame.target)
    return { target, position: target.clone().addScaledVector(unit, frame.distance), key: `stack-${stack.age}-${floors}` }
  }, [frame, stack.age, floors])

  return (
    <>
      <OrbitControls
        makeDefault
        enableDamping
        enablePan={false}
        minDistance={frame.distance * 0.45}
        maxDistance={frame.distance * 1.3}
        minPolarAngle={0.2 * Math.PI}
        maxPolarAngle={0.47 * Math.PI}
      />
      <CameraFlight goal={goal} />
    </>
  )
}

export function StackScene({
  stack,
  onRoom,
  onReady,
}: {
  stack: AgeStack
  /** 階のラベルを押したとき（おへやの id） */
  onRoom?: (roomId: string) => void
  /** どの階の建物もそろったとき */
  onReady?: () => void
}) {
  const museums = useMemo(() => stack.rooms.map((floor) => museumOf(stack, floor)), [stack])
  // ラベルは、建物の南西の角（画面の左手前）から右へ伸ばす。高さは各階の床の少し上
  const hub = stack.house.rooms[0]
  const labelX = hub ? -(hub.size[0] / 2 + stack.house.wall_thickness) : -5.2
  const labelZ = hub ? hub.size[1] / 2 + stack.house.wall_thickness : 5.2
  // 建物がそろった階（おへやの id）。全部の階がそろったら onReady
  const loaded = useRef(new Set<string>())

  return (
    <Stage camera={{ position: [12, 9, 12], fov: FOV }} frameloop="demand">
      {stack.rooms.map((floor, i) => (
        <group key={floor.room.id} position={[0, i * FLOOR_PITCH, 0]}>
          <HouseShells
            museum={museums[i]}
            cutaway
            onReady={() => {
              loaded.current.add(floor.room.id)
              if (stack.rooms.every((r) => loaded.current.has(r.room.id))) onReady?.()
            }}
          />
          <HomeObjects layout={floor.layout} catalog={stack.catalog} slots={floor.slots} house={stack.house} />
          <Html position={[labelX, WALL_TOP * 0.35, labelZ]} zIndexRange={[10, 0]}>
            <button type="button" className="stack-label" onClick={() => onRoom?.(floor.room.id)}>
              {floor.room.name}
              <small>{floor.count}</small>
              <span className="stack-chevron" aria-hidden="true">
                ›
              </span>
            </button>
          </Html>
        </group>
      ))}
      <StackCamera stack={stack} />
    </Stage>
  )
}
