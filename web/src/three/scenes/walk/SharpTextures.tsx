// 床や作品を斜めから見たときに、模様がぼやけないようにする（テクスチャの異方性フィルタ）。
// 歩いて目の高さから見ると、床の木目や作品の絵を浅い角度で見ることが多いので効果が大きい。
// 作品はあとから 1 つずつ読み込まれるので、ときどきシーン全体を見直して設定する。
// テクスチャはほかの 3D 画面と共有しているので、そちらも少しくっきりする（負荷はほとんど増えない）。

import { useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import type * as THREE from 'three'

const MAP_KEYS = ['map', 'normalMap', 'roughnessMap', 'metalnessMap', 'aoMap', 'emissiveMap'] as const
/** 何フレームに 1 回見直すか */
const CHECK_EVERY_FRAMES = 120

export function SharpTextures() {
  const gl = useThree((s) => s.gl)
  const scene = useThree((s) => s.scene)
  const frame = useRef(0)

  useFrame(() => {
    if (frame.current++ % CHECK_EVERY_FRAMES !== 0) return
    const max = gl.capabilities.getMaxAnisotropy()
    scene.traverse((obj) => {
      const mesh = obj as THREE.Mesh
      if (!mesh.isMesh) return
      for (const material of Array.isArray(mesh.material) ? mesh.material : [mesh.material]) {
        for (const key of MAP_KEYS) {
          const texture = (material as THREE.MeshStandardMaterial)[key]
          if (texture && texture.anisotropy < max) {
            texture.anisotropy = max
            texture.needsUpdate = true
          }
        }
      }
    })
  })

  return null
}
