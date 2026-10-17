// 視点の中心（OrbitControls の target）が家の外へ出ないようにする部品。⑤ おうちの中（MuseumScene）と ② ホーム（HomeScene）で使う。
// 毎フレーム、target を家の外形（house.ts の houseBounds）から TARGET_INSET だけ内側、高さ 0.4〜2.5 m の中に収める。
// OrbitControls は makeDefault で置いておく（useThree の controls から読む）。

import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import type { Bounds2 } from './house'

/** 視点の中心を、家の外形からこれだけ（m）内側に収める */
const TARGET_INSET = 0.5

/** 視点の中心が家の外へ出ないようにする（bounds は家の外形） */
export function ClampTarget({ bounds }: { bounds: Bounds2 }) {
  const { controls } = useThree()
  useFrame(() => {
    const orbit = controls as unknown as OrbitControlsImpl | null
    if (!orbit) return
    const t = orbit.target
    t.x = THREE.MathUtils.clamp(t.x, bounds.minX + TARGET_INSET, bounds.maxX - TARGET_INSET)
    t.y = THREE.MathUtils.clamp(t.y, 0.4, 2.5)
    t.z = THREE.MathUtils.clamp(t.z, bounds.minZ + TARGET_INSET, bounds.maxZ - TARGET_INSET)
  })
  return null
}
