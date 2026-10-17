// 照準（画面の中心）の先にある作品を見つける（Unity 版の作品カードを開くときと同じ考え方）。
// 歩いている人から REACH m 以内で、手前に壁や家具などがない作品だけを選ぶ。ガラスは通り抜ける。
// 作品は home/HomeObjects.tsx が userData.artworkId を付けて置いている（家具の上の作品は家具のグループの子）。

import { useEffect, useMemo, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'

/** 作品を選べる距離（m）。棚や机の前に立って手を伸ばすくらい */
const REACH = 3.5
/** 何フレームに 1 回調べるか（毎フレームでなくてよい） */
const CHECK_EVERY_FRAMES = 6
const CENTER = new THREE.Vector2(0, 0)

/** 自分か親が隠されていたら、見えていない（Raycaster は隠れた物にも当たるので、ここで外す） */
function isVisible(object: THREE.Object3D) {
  for (let o: THREE.Object3D | null = object; o; o = o.parent) if (!o.visible) return false
  return true
}

function isGlass(object: THREE.Object3D) {
  const material = (object as THREE.Mesh).material
  return (Array.isArray(material) ? material : [material]).some((m) => m?.transparent)
}

function artworkIdOf(object: THREE.Object3D): string | null {
  for (let o: THREE.Object3D | null = object; o; o = o.parent) {
    if (typeof o.userData.artworkId === 'string') return o.userData.artworkId
  }
  return null
}

export function ArtworkPicker({ active, onAim }: { active: boolean; onAim: (artworkId: string | null) => void }) {
  const camera = useThree((s) => s.camera)
  const scene = useThree((s) => s.scene)
  const raycaster = useMemo(() => {
    const r = new THREE.Raycaster()
    r.far = REACH
    return r
  }, [])
  const aimed = useRef<string | null>(null)
  const frame = useRef(0)

  const setAimed = (id: string | null) => {
    if (aimed.current === id) return
    aimed.current = id
    onAim(id)
  }

  useEffect(() => {
    if (!active) setAimed(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active])

  useFrame(() => {
    if (!active || frame.current++ % CHECK_EVERY_FRAMES !== 0) return
    raycaster.setFromCamera(CENTER, camera)
    let id: string | null = null
    for (const hit of raycaster.intersectObjects(scene.children, true)) {
      if (!(hit.object as THREE.Mesh).isMesh || !isVisible(hit.object) || isGlass(hit.object)) continue
      id = artworkIdOf(hit.object)
      break
    }
    setAimed(id)
  })

  return null
}
