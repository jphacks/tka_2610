// ⑦ 見取り図。斜め上から見下ろし、フロアごとに上の階や屋根を隠す（Rust の floors.hide_prefixes）。
import { Suspense, useMemo } from 'react'
import { Html, OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { Museum } from '../../api'
import { CameraFlight } from './CameraFlight'
import { MuseumModel, SlotArtworks } from './models'
import { Stage } from './Stage'
import './MapScene.css'

type Floor = '1F' | '2F'

/** 部屋の名前と展示数のラベル。その階の展示台の中心の少し上に出す */
function RoomLabels({ museum, floor, onRoom }: { museum: Museum; floor: Floor; onRoom?: (roomId: string) => void }) {
  const labels = useMemo(
    () =>
      museum.rooms
        .map((room) => {
          const slots = museum.slots.filter((s) => s.room_id === room.id && s.floor === floor)
          if (slots.length === 0) return null
          const c = new THREE.Vector3()
          slots.forEach((s) => c.add(new THREE.Vector3(...s.position)))
          c.divideScalar(slots.length)
          const count = slots.filter((s) => s.artwork).length
          return { room, position: [c.x, c.y + 1.4, c.z] as [number, number, number], count }
        })
        .filter((x) => x !== null),
    [museum, floor],
  )

  return (
    <>
      {labels.map(({ room, position, count }) => (
        <Html key={room.id} position={position} center zIndexRange={[10, 0]}>
          <button className="room-label" onClick={() => onRoom?.(room.id)}>
            {room.name}
            <small>{count}</small>
          </button>
        </Html>
      ))}
    </>
  )
}

/** フロアを切り替えたら、カメラをその階の高さへ移す */
function FloorTarget({ floor }: { floor: Floor }) {
  const goal = useMemo(() => {
    const y = floor === '2F' ? 4.2 : 0
    return {
      position: new THREE.Vector3(20, 28 + y, -30),
      target: new THREE.Vector3(0, y, 0.5),
      key: `floor-${floor}`,
    }
  }, [floor])
  return <CameraFlight goal={goal} />
}

export function MapScene({
  museum,
  floor,
  onRoom,
  onReady,
}: {
  museum: Museum
  floor: Floor
  onRoom?: (roomId: string) => void
  onReady?: () => void
}) {
  const hide = useMemo(() => {
    const view = museum.floors.find((f) => f.id === floor)
    return [...(view?.hide_prefixes ?? []), ...museum.hidden_node_prefixes]
  }, [museum, floor])

  // 1F を見るときは 2 階の作品を出さない
  const slots = useMemo(
    () => (floor === '1F' ? museum.slots.filter((s) => s.floor === '1F') : museum.slots),
    [museum.slots, floor],
  )

  if (!museum.model_url) return null

  return (
    <Stage camera={{ position: [20, 28, -30], fov: 30 }} frameloop="demand">
      <Suspense fallback={null}>
        <MuseumModel url={museum.model_url} hide={hide} onReady={onReady} />
        <SlotArtworks slots={slots} />
        <RoomLabels museum={museum} floor={floor} onRoom={onRoom} />
      </Suspense>
      <OrbitControls
        makeDefault
        target={[0, 0, 0.5]}
        enableDamping
        enablePan={false}
        minDistance={18}
        maxDistance={60}
        maxPolarAngle={0.42 * Math.PI}
      />
      <FloorTarget floor={floor} />
    </Stage>
  )
}
