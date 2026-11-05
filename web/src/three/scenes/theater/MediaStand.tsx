// 作品の隣に立つ、写真立て（おもいでの写真・動画）。厚みのある紙の枠に、写真か動画を貼る。
// 立ち上がり・倒れるのは、親（TheaterScene）が毎フレーム lift（0〜1）を渡して、底辺を軸に起こす。
// 動画の要素は画面（DigestTheater）が持っていて、再生・停止・位置合わせもそちらで行う（音を BGM と合わせるため）。
import { useEffect, useMemo, useRef } from 'react'
import * as THREE from 'three'
import type { Memory } from '../../../api'

/** 枠の外寸（幅・高さ）。写真の向きに合わせ、長い辺を maxSize にする */
export function standSize(memory: Memory, maxSize: number): [number, number] {
  const w = memory.width ?? 0
  const h = memory.height ?? 0
  const aspect = w > 0 && h > 0 ? THREE.MathUtils.clamp(w / h, 0.56, 1.8) : memory.kind === 'video' ? 16 / 9 : 4 / 3
  return aspect >= 1 ? [maxSize, maxSize / aspect + 0.12] : [maxSize * aspect + 0.12, maxSize]
}

const FRAME_DEPTH = 0.06
const BORDER = 0.07

function roundedFrame(width: number, height: number): THREE.ExtrudeGeometry {
  const r = Math.min(width, height) * 0.06
  const shape = new THREE.Shape()
  const x = -width / 2
  shape.moveTo(x + r, 0)
  shape.lineTo(x + width - r, 0)
  shape.quadraticCurveTo(x + width, 0, x + width, r)
  shape.lineTo(x + width, height - r)
  shape.quadraticCurveTo(x + width, height, x + width - r, height)
  shape.lineTo(x + r, height)
  shape.quadraticCurveTo(x, height, x, height - r)
  shape.lineTo(x, r)
  shape.quadraticCurveTo(x, 0, x + r, 0)
  const geometry = new THREE.ExtrudeGeometry(shape, { depth: FRAME_DEPTH, bevelEnabled: true, bevelThickness: 0.012, bevelSize: 0.012, bevelSegments: 2, curveSegments: 6 })
  geometry.translate(0, 0, -FRAME_DEPTH / 2)
  return geometry
}

/** 動画が読めないとき（この端末で再生できない形式など）の、紙に「動画」と書いた絵 */
function videoPlaceholder(): THREE.CanvasTexture {
  const canvas = document.createElement('canvas')
  canvas.width = 512
  canvas.height = 288
  const ctx = canvas.getContext('2d')!
  ctx.fillStyle = '#e9eef0'
  ctx.fillRect(0, 0, 512, 288)
  ctx.fillStyle = '#6E98B5'
  ctx.beginPath()
  ctx.moveTo(220, 104)
  ctx.lineTo(300, 144)
  ctx.lineTo(220, 184)
  ctx.closePath()
  ctx.fill()
  const texture = new THREE.CanvasTexture(canvas)
  texture.colorSpace = THREE.SRGBColorSpace
  return texture
}

export function MediaStand({
  memory,
  width,
  height,
  video,
  shadows,
  paintNormal,
  onReady,
  onSelect,
  bind,
}: {
  memory: Memory
  width: number
  height: number
  video: HTMLVideoElement | null
  shadows: boolean
  paintNormal: THREE.Texture
  onReady: () => void
  onSelect: () => void
  /** 親が毎フレーム起こす角度を入れるための、外側の group を渡す */
  bind: (group: THREE.Group | null) => void
}) {
  const picture = useRef<THREE.Mesh>(null)
  const frame = useMemo(() => roundedFrame(width, height), [width, height])
  const strut = useMemo(() => new THREE.BoxGeometry(0.08, height * 0.75, 0.03), [height])
  const paper = useMemo(
    () => new THREE.MeshStandardMaterial({ color: '#FBF6EA', roughness: 0.9, metalness: 0, normalMap: paintNormal, normalScale: new THREE.Vector2(0.35, 0.35) }),
    [paintNormal],
  )
  const plane = useMemo(() => new THREE.PlaneGeometry(width - BORDER * 2, height - BORDER * 2), [width, height])
  const material = useMemo(() => new THREE.MeshStandardMaterial({ color: '#ffffff', roughness: 0.62, metalness: 0 }), [])

  useEffect(() => {
    let texture: THREE.Texture | null = null
    let cancelled = false
    if (memory.kind === 'video') {
      if (video) {
        texture = new THREE.VideoTexture(video)
        texture.colorSpace = THREE.SRGBColorSpace
        const failed = () => {
          if (cancelled) return
          material.map = videoPlaceholder()
          material.needsUpdate = true
        }
        if (video.error) failed()
        else video.addEventListener('error', failed, { once: true })
      } else {
        texture = videoPlaceholder()
      }
      material.map = texture
      material.needsUpdate = true
      onReady()
    } else {
      new THREE.TextureLoader().load(
        memory.url,
        (loaded) => {
          if (cancelled) { loaded.dispose(); return }
          loaded.colorSpace = THREE.SRGBColorSpace
          loaded.anisotropy = 4
          // 枠の形と写真の形が少し違うときは、真ん中を切り抜いて貼る（object-fit: cover と同じ）
          const image = loaded.image as { width: number; height: number }
          const planeAspect = (width - BORDER * 2) / (height - BORDER * 2)
          const imageAspect = image.width / Math.max(1, image.height)
          if (imageAspect > planeAspect) {
            loaded.repeat.set(planeAspect / imageAspect, 1)
            loaded.offset.set((1 - planeAspect / imageAspect) / 2, 0)
          } else {
            loaded.repeat.set(1, imageAspect / planeAspect)
            loaded.offset.set(0, (1 - imageAspect / planeAspect) / 2)
          }
          texture = loaded
          material.map = loaded
          material.needsUpdate = true
          onReady()
        },
        undefined,
        () => { if (!cancelled) onReady() },
      )
    }
    return () => {
      cancelled = true
      material.map?.dispose()
      material.map = null
      texture?.dispose()
    }
  }, [memory.kind, memory.url, video, material, width, height, onReady])

  useEffect(() => () => { frame.dispose(); strut.dispose(); plane.dispose(); paper.dispose(); material.dispose() }, [frame, strut, plane, paper, material])

  return (
    <group ref={bind} visible={false}>
      <group
        onClick={(event) => { event.stopPropagation(); onSelect() }}
        onPointerOver={() => { document.body.style.cursor = 'pointer' }}
        onPointerOut={() => { document.body.style.cursor = '' }}
      >
        <mesh geometry={frame} material={paper} castShadow={shadows} receiveShadow={shadows} />
        <mesh ref={picture} geometry={plane} material={material} position={[0, height / 2, FRAME_DEPTH / 2 + 0.014]} />
        {/* 後ろの支え（写真立ての足） */}
        <mesh geometry={strut} material={paper} position={[0, height * 0.36, -0.2]} rotation={[-0.42, 0, 0]} castShadow={shadows} />
      </group>
    </group>
  )
}
