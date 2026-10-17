// ⑤ 博物館の中。ドラッグで見回し、作品をクリックすると詳細へ。
// ?focus=作品ID ならその作品へ、?room=部屋ID ならその部屋へカメラが移動する。
import { Suspense, useMemo } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import { OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import type { Museum, SlotView } from '../../api'
import { CameraFlight, type CameraGoal } from './CameraFlight'
import { MuseumModel, SlotArtworks } from './models'
import { Stage } from './Stage'

/** 作品の正面から見る位置 */
function slotGoal(slot: SlotView): CameraGoal {
  const [x, y, z] = slot.position
  // 下部のメッセージに隠れないよう、作品が画面のやや上に来る位置から見る
  const target = new THREE.Vector3(x, y + 0.1, z)
  const yaw = THREE.MathUtils.degToRad(slot.yaw)
  const front = new THREE.Vector3(Math.sin(yaw), 0, Math.cos(yaw))
  const position = target.clone().add(front.multiplyScalar(2.3)).add(new THREE.Vector3(0, 0.75, 0))
  return { position, target, key: `slot-${slot.id}` }
}

/** 部屋全体を見渡す位置（1 階の展示台の中心から、通路側へ下がる） */
function roomGoal(slots: SlotView[], roomId: string): CameraGoal | null {
  const inRoom = slots.filter((s) => s.room_id === roomId && s.in_main_model && s.floor === '1F')
  if (inRoom.length === 0) return null
  const c = new THREE.Vector3()
  inRoom.forEach((s) => c.add(new THREE.Vector3(...s.position)))
  c.divideScalar(inRoom.length)
  const target = new THREE.Vector3(c.x, 1.3, c.z)
  const position = new THREE.Vector3(c.x * 0.25, 3.2, c.z - 6.5)
  return { position, target, key: `room-${roomId}` }
}

/** 視点の中心が建物の外へ出ないようにする */
function ClampTarget() {
  const { controls } = useThree()
  useFrame(() => {
    const orbit = controls as unknown as OrbitControlsImpl | null
    if (!orbit) return
    const t = orbit.target
    t.x = THREE.MathUtils.clamp(t.x, -12, 12)
    t.y = THREE.MathUtils.clamp(t.y, 0.4, 7)
    t.z = THREE.MathUtils.clamp(t.z, -13.5, 13.5)
  })
  return null
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
  const goal = useMemo(() => {
    const slot = focusId ? museum.slots.find((s) => s.artwork?.id === focusId) : undefined
    if (slot) return slotGoal(slot)
    if (roomId) return roomGoal(museum.slots, roomId)
    return null
  }, [museum.slots, focusId, roomId])

  if (!museum.model_url) return null

  return (
    <Stage camera={{ position: [0, 2.6, -12.4], fov: 55 }}>
      <Suspense fallback={null}>
        <MuseumModel url={museum.model_url} hide={museum.hidden_node_prefixes} onReady={onReady} />
        <SlotArtworks slots={museum.slots} onSelect={onSelect} />
      </Suspense>
      <OrbitControls
        makeDefault
        target={[0, 1.7, -2]}
        enableDamping
        dampingFactor={0.08}
        minDistance={0.8}
        maxDistance={16}
        minPolarAngle={0.15 * Math.PI}
        maxPolarAngle={0.53 * Math.PI}
        screenSpacePanning={false}
      />
      <ClampTarget />
      <CameraFlight goal={goal} />
    </Stage>
  )
}
