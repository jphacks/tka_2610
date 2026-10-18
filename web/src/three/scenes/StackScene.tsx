// ホームの積み上げの建物。ある年齢のおへや（/api/ages/{age} の rooms。1 階から）を、実際の 3D のおへや（建物・家具・作品）のまま縦に重ねて、
// 南東の斜め上から見る。上の階は下の階の壁の上にそのまま乗せる（本当の建物と同じ）。部屋の天井が高い（壁 4.2 m）ので、
// 浅めの角度（約 16°）で見ると、上の階の床の下から下の階の中が奥まで見える。カメラの側の壁はおへやごとにカットする。
// 階の左に「4さいのおへや 2（数）›」のラベルを出し、押すと onRoom（その階のおへやへ入る）。
// 建物・家具・作品を描くのは、ほかの画面と同じ HouseShells・HomeObjects（階ごとに高さをずらしたグループに入れるだけ）。
// 階が増えるとスマホで重くなるので、動きがあるときだけ描き（frameloop demand）、作品の数はスマホでは HomeObjects の決まり（近い 6 点）に任せる。
// 机の上の模型のように見せる仕上げ（暖かい光の影・接地の影・隅の陰・ティルトシフト・周辺減光）は DioramaEffects。
// 引いて見ると何もない床ばかりにならないよう、ここでは部屋を横方向に縮めて描き（建物のグループを [s, 1, s]）、家具と作品を中へ寄せる
// （home/compact.ts。重ならない範囲でいちばん小さく。全部の階で同じ s）。家具と作品の大きさと、保存されている配置はそのまま。
// スマホなど（タッチの端末）では、重い隅の陰を省き、影の解像度を下げる。
import { useCallback, useMemo, useRef, useState } from 'react'
import { useThree } from '@react-three/fiber'
import { Html, OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { AgeStack, Museum, StackRoom, Vec3 } from '../../api'
import { CameraFlight, type CameraGoal } from './CameraFlight'
import { DioramaLight, DioramaPost, useShadowEverything } from './DioramaEffects'
import { compactLayout, compactScale } from './home/compact'
import { HomeObjects } from './home/HomeObjects'
import { HouseShells } from './home/HouseShells'
import { sizesFromSlots } from './home/placement'
import { WALL_TOP, cornersOf, fitDistance, frameCenter, roomBounds } from './home/house'
import { Stage } from './Stage'
import { isTouchDevice } from './walk/inputMode'
import './StackScene.css'

/** 1 階分の高さ（m）。壁の高さに、床の下の土台の厚さ（建物の GLB の 0.2 m）を足す。上の階の土台が下の階の壁の上に乗る */
export const FLOOR_PITCH = WALL_TOP + 0.2
/** 見る先からカメラへの向き（南東の斜め上。水平から約 16°。壁の高さが分かり、上の階の床の下から下の階の中も見える角度） */
const DIRECTION: Vec3 = [1, 0.4, 1]
const FOV = 38
/** 建物全体を収めるときの余白（1 より小さいので、建物の角が少しだけ画面の外に出るくらいまで寄る） */
const MARGIN = 0.78
/** 階のラベルの位置（西の角から中心までのうち、角の側からどれだけ残すか） */
const LABEL_INSET = 0.25

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
function StackCamera({ stack, scale }: { stack: AgeStack; scale: number }) {
  const size = useThree((s) => s.size)
  const floors = stack.rooms.length
  const frame = useMemo(() => {
    const wall = stack.house.wall_thickness
    const points: Vec3[] = []
    for (let i = 0; i < Math.max(1, floors); i++) {
      for (const room of stack.house.rooms) {
        // 縮めて描いた建物の角（横方向だけ scale 倍）
        for (const [x, y, z] of cornersOf(roomBounds(room, wall))) points.push([x * scale, y + i * FLOOR_PITCH, z * scale])
      }
    }
    const [tx, , tz] = frameCenter(points, DIRECTION)
    const target: Vec3 = [tx, (Math.max(1, floors) * FLOOR_PITCH - (FLOOR_PITCH - WALL_TOP)) / 2, tz]
    const distance = fitDistance(points, target, DIRECTION, FOV, size.width / Math.max(1, size.height), MARGIN)
    return { target, distance }
    // 画面の大きさが変わるたびに測り直すと、見回している途中で距離が変わるので、はじめの大きさで決める
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stack, floors, scale])

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

/** 建物の下の土台の厚さ（m）。建物の GLB の床の下（y = −0.2 まで） */
const BASE_DEPTH = 0.2

/** 模型の仕上げ。建物や家具が読み込まれるたび（version）に、全部のメッシュに影を付け直す */
function Diorama({ stack, scale, version, lite }: { stack: AgeStack; scale: number; version: number; lite: boolean }) {
  useShadowEverything(version)
  const { center, radius } = useMemo(() => {
    const room = stack.house.rooms[0]
    const wall = stack.house.wall_thickness
    const width = ((room?.size[0] ?? 10) + wall * 2) * scale
    const depth = ((room?.size[1] ?? 10) + wall * 2) * scale
    const height = Math.max(1, stack.rooms.length) * FLOOR_PITCH
    const [ox, oz] = room?.origin ?? [0, 0]
    return { center: [ox, height / 2 - BASE_DEPTH, oz] as Vec3, radius: Math.hypot(width / 2, depth / 2, height / 2) }
  }, [stack, scale])
  return (
    <>
      <DioramaLight center={center} radius={radius} floorY={-BASE_DEPTH} lite={lite} />
      <DioramaPost lite={lite} />
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
  // 部屋を縮める倍率と、縮めた部屋に寄せた配置（階ごと）
  const compact = useMemo(() => {
    const floors = stack.rooms.map((floor) => ({ layout: floor.layout, sizeOf: sizesFromSlots(floor.slots) }))
    const scale = compactScale(floors, stack.catalog)
    return { scale, layouts: floors.map((f) => compactLayout(f.layout, stack.catalog, scale, f.sizeOf)) }
  }, [stack])
  // ラベルは、建物の南の壁（画面の左手前の壁）の、西の角から少し内側から右へ伸ばす。高さは各階の床の少し上
  // （カメラが寄っていて角は画面の端にかかるので、角ちょうどに置くとラベルが切れる）
  const hub = stack.house.rooms[0]
  const labelX = (hub ? -(hub.size[0] / 2 + stack.house.wall_thickness) : -5.2) * compact.scale * LABEL_INSET
  const labelZ = (hub ? hub.size[1] / 2 + stack.house.wall_thickness : 5.2) * compact.scale
  // 建物がそろった階（おへやの id）。全部の階がそろったら onReady
  const loaded = useRef(new Set<string>())
  // 建物や家具が読み込まれた回数（影を付け直すきっかけ）
  const [version, setVersion] = useState(0)
  const bump = useCallback(() => setVersion((v) => v + 1), [])
  const [lite] = useState(isTouchDevice)

  return (
    <Stage camera={{ position: [12, 9, 12], fov: FOV }} frameloop="demand" shadows>
      {stack.rooms.map((floor, i) => (
        <group key={floor.room.id} position={[0, i * FLOOR_PITCH, 0]}>
          {/* 建物は横方向だけ縮める（壁の高さはそのまま） */}
          <group scale={[compact.scale, 1, compact.scale]}>
            <HouseShells
              museum={museums[i]}
              cutaway
              onReady={() => {
                loaded.current.add(floor.room.id)
                bump()
                if (stack.rooms.every((r) => loaded.current.has(r.room.id))) onReady?.()
              }}
            />
          </group>
          <HomeObjects layout={compact.layouts[i]} catalog={stack.catalog} slots={floor.slots} house={stack.house} onReady={bump} />
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
      <StackCamera stack={stack} scale={compact.scale} />
      <Diorama stack={stack} scale={compact.scale} version={version} lite={lite} />
    </Stage>
  )
}
