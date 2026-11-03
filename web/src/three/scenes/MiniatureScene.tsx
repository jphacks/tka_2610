import { useEffect, useLayoutEffect, useMemo, useRef } from 'react'
import { Canvas, useFrame, useThree } from '@react-three/fiber'
import { Html } from '@react-three/drei'
import * as THREE from 'three'
import type { Memory, MiniatureEntry } from '../../api'
import { ShowcaseArtwork } from './home/HomeObjects'
import { nearbyIndices, smoothTurn } from './miniature/motion'

interface Props {
  revision: string
  entries: MiniatureEntry[]
  turn: number
  playing: boolean
  showPhotos: boolean
  transitionMs: number
  onArrive: (turn: number) => void
  onModelReady: (id: string, fallback: boolean) => void
  onArtwork: (id: string) => void
  onPhoto: (index: number) => void
  onReady: () => void
  reducedMotion: boolean
  palette: { paper: string; surface: string; earth: string; ink: string }
}

const RADIUS = 3.15
const RING = 1.7
const LATITUDE = Math.asin(RING / RADIUS)

function World(props: Props) {
  const { entries, turn, playing, onArrive, transitionMs, reducedMotion, palette } = props
  const globe = useRef<THREE.Group>(null)
  const works = useRef(new Map<number, THREE.Group>())
  const invalidate = useThree(state => state.invalidate)
  const camera = useThree(state => state.camera)
  const motion = useRef({ turn: Number.NaN, from: 0, to: 0, elapsed: 0, lastTime: 0, settled: false })
  const index = ((turn % entries.length) + entries.length) % entries.length
  const step = entries.length > 1 ? Math.PI * 2 / entries.length : 0
  const selected = nearbyIndices(index, entries.length)

  useLayoutEffect(() => {
    camera.position.set(0, 4.3, 9)
    camera.lookAt(0, -1.8, 0)
    camera.updateProjectionMatrix()
    props.onReady()
    invalidate()
  }, [camera, invalidate, props.onReady])

  useLayoutEffect(() => {
    motion.current.turn = Number.NaN
    motion.current.settled = false
    motion.current.elapsed = 0
    if (globe.current) globe.current.rotation.y = 0
    invalidate()
  }, [props.revision, invalidate])

  useLayoutEffect(() => { motion.current.lastTime = performance.now(); invalidate() }, [turn, playing, props.showPhotos, invalidate])
  useFrame(() => {
    const group = globe.current
    if (!group) return
    const m = motion.current
    const now = performance.now()
    if (m.turn !== turn) {
      m.turn = turn
      m.from = group.rotation.y
      m.to = -turn * step
      m.elapsed = 0
      m.lastTime = now
      m.settled = false
      // 停止中に次を押した場合と、視差効果を減らす設定では選択位置へ直接移る。
      if (!playing || reducedMotion || Math.abs(m.to - m.from) < 0.0001) m.elapsed = transitionMs / 1000
    }
    for (const [i, work] of works.current) {
      const front = Math.max(0, Math.cos(group.rotation.y + i * step))
      work.scale.setScalar(0.65 + 0.35 * front ** 8)
    }
    if (reducedMotion && !m.settled) m.elapsed = transitionMs / 1000
    if (!m.settled && (playing || m.elapsed >= transitionMs / 1000)) {
      m.elapsed = Math.min(transitionMs / 1000, m.elapsed + Math.max(0, now - m.lastTime) / 1000)
      m.lastTime = now
      group.rotation.y = THREE.MathUtils.lerp(m.from, m.to, smoothTurn(m.elapsed * 1000 / transitionMs))
      if (m.elapsed * 1000 >= transitionMs) { m.settled = true; onArrive(turn) }
      else invalidate()
    }
  })

  const ground = useMemo(() => {
    const geometry = new THREE.SphereGeometry(RADIUS, 64, 40)
    const positions = geometry.attributes.position
    const colors = new Float32Array(positions.count * 3)
    const earth = new THREE.Color(palette.earth)
    const paper = new THREE.Color(palette.paper)
    const point = new THREE.Vector3()
    const color = new THREE.Color()
    for (let i = 0; i < positions.count; i++) {
      point.fromBufferAttribute(positions, i)
      const height = point.y / RADIUS
      const ripple = 1 + 0.0025 * Math.sin(point.x * 6) * Math.cos(point.z * 5)
      positions.setXYZ(i, point.x * ripple, point.y * ripple, point.z * ripple)
      color.copy(paper).lerp(earth, THREE.MathUtils.smoothstep(height, 0.15, 0.8))
      color.toArray(colors, i * 3)
    }
    geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3))
    geometry.computeVertexNormals()
    return geometry
  }, [palette.paper, palette.earth])
  const grain = useMemo(() => {
    const data = new Uint8Array(128 * 128 * 4)
    let seed = 17
    for (let i = 0; i < 128 * 128; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) | 0
      const value = 128 + ((seed >>> 24) - 128) * 0.3
      data.set([value, value, value, 255], i * 4)
    }
    const texture = new THREE.DataTexture(data, 128, 128)
    texture.wrapS = texture.wrapT = THREE.RepeatWrapping
    texture.repeat.set(10, 6)
    texture.needsUpdate = true
    return texture
  }, [])
  useEffect(() => () => { ground.dispose(); grain.dispose() }, [ground, grain])
  const active = entries[index]
  return (
    <>
      <color attach="background" args={[palette.paper]} />
      <hemisphereLight args={[palette.surface, palette.earth, 1.15]} />
      <directionalLight position={[-4, 7, 6]} color={palette.surface} intensity={2} castShadow shadow-mapSize={[1024, 1024]} shadow-camera-left={-5} shadow-camera-right={5} shadow-camera-top={5} shadow-camera-bottom={-5} shadow-normalBias={0.025} />
      <directionalLight position={[4, 2, -3]} intensity={0.5} color={palette.paper} />
      <group ref={globe} position={[0, -RADIUS + 0.25, 0]}>
        <mesh geometry={ground} receiveShadow><meshStandardMaterial vertexColors roughness={1} bumpMap={grain} bumpScale={0.035} /></mesh>
        {selected.map(i => (
          <group key={entries[i].artwork.id} rotation-y={i * step}>
            <group ref={node => { if (node) works.current.set(i, node); else works.current.delete(i) }} position={[0, Math.cos(LATITUDE) * RADIUS + 0.02, RING]} rotation-x={LATITUDE}>
              <ShowcaseArtwork artwork={entries[i].artwork} onReady={props.onModelReady} onSelect={props.onArtwork} />
            </group>
          </group>
        ))}
      </group>
      {props.showPhotos && active.photos.map((photo: Memory, i: number) => (
        <Html key={`${active.artwork.id}-${photo.id}`} center position={i === 0 ? [-1.65, 1.25, 1.3] : i === 1 ? [1.65, 1.05, 1.2] : [-1.55, -0.4, 1.5]} zIndexRange={[5, 0]}>
          <button type="button" className={`miniature-memory-photo photo-${i}`} onClick={() => props.onPhoto(i)} aria-label={photo.caption || `${active.artwork.title}のおもいでの写真${i + 1}を見る`}>
            <img src={photo.thumb_url ?? photo.url} alt={photo.caption || 'おもいでの写真'} />
            <span>{photo.caption || 'おもいでの写真'}</span>
          </button>
        </Html>
      ))}
    </>
  )
}

/** memoriaに埋め込む独立Canvas。既存の家・鑑賞モードのカメラや材質は触らない。 */
export function MiniatureScene(props: Props) {
  return (
    <Canvas dpr={[1, 1.35]} frameloop="demand" shadows="soft" camera={{ fov: 44, near: 0.1, far: 40 }} gl={{ antialias: true, powerPreference: 'low-power' }}
      onCreated={({ gl }) => { gl.toneMapping = THREE.NeutralToneMapping; gl.toneMappingExposure = 1 }}>
      <World {...props} />
    </Canvas>
  )
}
