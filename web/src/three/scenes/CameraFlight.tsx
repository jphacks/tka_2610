// カメラを目的地へなめらかに移動させる（おうちの中で、作品や部屋へ寄る）。

import { useEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'

export interface CameraGoal {
  position: THREE.Vector3
  target: THREE.Vector3
  /** 値が変わったときだけ移動を始める */
  key: string
}

const easeInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)

/** カメラを目的地へ 1.3 秒かけてなめらかに移動させる（OrbitControls と併用） */
export function CameraFlight({ goal }: { goal: CameraGoal | null }) {
  const { camera, controls, invalidate } = useThree()
  const flight = useRef<{
    fromPos: THREE.Vector3
    fromTarget: THREE.Vector3
    toPos: THREE.Vector3
    toTarget: THREE.Vector3
    t: number
  } | null>(null)

  useEffect(() => {
    const orbit = controls as unknown as OrbitControlsImpl | null
    if (!goal || !orbit) return
    flight.current = {
      fromPos: camera.position.clone(),
      fromTarget: orbit.target.clone(),
      toPos: goal.position.clone(),
      toTarget: goal.target.clone(),
      t: 0,
    }
    invalidate()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [goal?.key, controls])

  useFrame((_, delta) => {
    const f = flight.current
    const orbit = controls as unknown as OrbitControlsImpl | null
    if (!f || !orbit) return
    f.t = Math.min(1, f.t + delta / 1.3)
    const k = easeInOut(f.t)
    camera.position.lerpVectors(f.fromPos, f.toPos, k)
    orbit.target.lerpVectors(f.fromTarget, f.toTarget, k)
    orbit.update()
    if (f.t >= 1) flight.current = null
    invalidate()
  })

  return null
}
