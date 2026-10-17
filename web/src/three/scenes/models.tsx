// GLB を読み込んで置く部品。博物館の建物（MuseumModel）と、展示台の上の作品（SlotArtworks・FittedModel）。
// 博物館 GLB は 1 度だけダウンロード・解析し、各画面では clone して使い回す。

import { Suspense, useEffect, useLayoutEffect, useMemo } from 'react'
import type { ThreeEvent } from '@react-three/fiber'
import { useGLTF } from '@react-three/drei'
import * as THREE from 'three'
import type { SlotView } from '../../api'

/** 展示台に収める範囲（幅・高さ・奥行き, m） */
const DISPLAY_VOLUME: [number, number, number] = [0.85, 0.9, 0.76]

/** GLB を先にダウンロード・解析しておく（three/index.tsx の warmUp3D から呼ぶ） */
export function preloadModel(url: string) {
  useGLTF.preload(url, false, false)
}

/**
 * 博物館の建物。hide に渡した接頭辞で始まる名前のノードを隠す
 * （作品を置いた展示台のサンプル展示物や、見取り図で上の階を隠すのに使う）。
 */
export function MuseumModel({ url, hide, onReady }: { url: string; hide: string[]; onReady?: () => void }) {
  const gltf = useGLTF(url, false, false)

  const scene = useMemo(() => {
    const clone = gltf.scene.clone(true)
    // 建物は動かないので、毎フレームの行列計算を省く
    clone.traverse((o) => {
      o.updateMatrix()
      o.matrixAutoUpdate = false
    })
    clone.updateMatrixWorld(true)
    return clone
  }, [gltf.scene])

  const hideKey = hide.join('|')
  useLayoutEffect(() => {
    scene.traverse((o) => {
      if (o === scene || !o.name) return
      o.visible = !hide.some((prefix) => o.name.startsWith(prefix))
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scene, hideKey])

  useEffect(() => {
    onReady?.()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return <primitive object={scene} />
}

/** 作品のモデルを、展示台の範囲（volume）に収まる大きさにして置く */
export function FittedModel({ url, volume = DISPLAY_VOLUME }: { url: string; volume?: [number, number, number] }) {
  const { scene } = useGLTF(url, false, false)
  const [vx, vy, vz] = volume

  const object = useMemo(() => {
    const clone = scene.clone(true)
    const box = new THREE.Box3().setFromObject(clone)
    const size = box.getSize(new THREE.Vector3())
    const center = box.getCenter(new THREE.Vector3())
    // 回転しても範囲からはみ出さないよう、水平方向は対角線の長さで合わせる
    const diameter = Math.max(0.001, Math.hypot(size.x, size.z))
    const scale = Math.min(vx / diameter, vz / diameter, vy / Math.max(0.001, size.y)) * 0.9
    clone.position.set(-center.x, -box.min.y, -center.z)
    const group = new THREE.Group()
    group.add(clone)
    group.scale.setScalar(scale)
    return group
  }, [scene, vx, vy, vz])

  return <primitive object={object} />
}

/** 展示中の作品を、Rust が返した展示台の位置と向き（yaw）に置く */
export function SlotArtworks({
  slots,
  onSelect,
}: {
  slots: SlotView[]
  /** 渡すと作品をクリックできるようになる */
  onSelect?: (artworkId: string) => void
}) {
  const hover = (on: boolean) => (e: ThreeEvent<PointerEvent>) => {
    e.stopPropagation()
    if (onSelect) document.body.style.cursor = on ? 'pointer' : ''
  }

  useEffect(() => () => void (document.body.style.cursor = ''), [])

  return (
    <>
      {slots.map((slot) =>
        slot.artwork ? (
          <group
            key={`${slot.id}-${slot.artwork.id}`}
            position={slot.position}
            rotation-y={THREE.MathUtils.degToRad(slot.yaw)}
            onClick={(e) => {
              e.stopPropagation()
              onSelect?.(slot.artwork!.id)
            }}
            onPointerOver={hover(true)}
            onPointerOut={hover(false)}
          >
            {/* 作品ごとに Suspense を分け、博物館は先に表示する */}
            <Suspense fallback={null}>
              <FittedModel url={slot.artwork.model_url} />
            </Suspense>
          </group>
        ) : null,
      )}
    </>
  )
}
