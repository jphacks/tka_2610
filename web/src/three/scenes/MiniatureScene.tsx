import { useEffect, useLayoutEffect, useMemo, useRef, type RefObject } from 'react'
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
  focusedArtworkId: string | null
  transitionMs: number
  onArrive: (turn: number) => void
  onModelReady: (id: string, fallback: boolean) => void
  onArtwork: (id: string) => void
  onArtworkBottom: (bottom: number) => void
  onPhoto: (artworkId: string, index: number) => void
  onReady: () => void
  reducedMotion: boolean
  palette: { paper: string; surface: string; earth: string; ink: string }
}

// 大きな球の上面だけを写し、地面を緩やかな丘として見せる。
const RADIUS = 9
// 鑑賞位置は球の頂点。到着時は作品の上方向と世界の上方向が一致する。
const RING = 0
const LATITUDE = 0

/** 写真も地面に立て、作品と一緒に回す。球の裏側では地面に隠れる。 */
function GroundPhoto({ photo, index, artworkId, title, ground, focused, onPhoto }: { photo: Memory; index: number; artworkId: string; title: string; ground: RefObject<THREE.Mesh | null>; focused: boolean; onPhoto: Props['onPhoto'] }) {
  const x = index === 1 ? 1.35 : -1.35
  const z = index === 2 ? 0.9 : -0.35
  const position = new THREE.Vector3(x, RADIUS, z).normalize().multiplyScalar(RADIUS + 0.025)
  const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), position.clone().normalize())
  return (
    <group position={position} quaternion={rotation}>
      <Html transform position={[0, 0.55, 0]} rotation-x={-LATITUDE} distanceFactor={2.3} occlude={[ground as RefObject<THREE.Object3D>]} zIndexRange={[5, 0]}>
        <button type="button" className={`miniature-memory-photo${focused ? ' is-focused' : ''}`} onClick={event => { event.stopPropagation(); onPhoto(artworkId, index) }} aria-label={photo.caption || `${title}のおもいでの写真${index + 1}を見る`}>
          <img src={photo.thumb_url ?? photo.url} alt={photo.caption || 'おもいでの写真'} draggable={false} />
          <span>{photo.caption || 'おもいでの写真'}</span>
        </button>
      </Html>
    </group>
  )
}

function World(props: Props) {
  const { entries, turn, playing, onArrive, transitionMs, reducedMotion, palette } = props
  const globe = useRef<THREE.Group>(null)
  const groundMesh = useRef<THREE.Mesh>(null)
  const works = useRef(new Map<number, THREE.Group>())
  const bounds = useRef(new THREE.Box3())
  const corner = useRef(new THREE.Vector3())
  const invalidate = useThree(state => state.invalidate)
  const camera = useThree(state => state.camera)
  const size = useThree(state => state.size)
  const motion = useRef({ turn: Number.NaN, from: 0, to: 0, elapsed: 0, lastTime: 0, settled: false })
  const index = ((turn % entries.length) + entries.length) % entries.length
  const step = entries.length > 1 ? Math.PI * 2 / entries.length : 0
  const selected = nearbyIndices(index, entries.length)

  useLayoutEffect(() => {
    // 縦画面は作品を横幅いっぱいに寄せ、横画面は背の高い作品も収める。
    const aspect = size.width / Math.max(1, size.height)
    const distance = Math.max(3.3 / aspect, 4) / (2 * Math.tan(THREE.MathUtils.degToRad(44 / 2)))
    camera.position.set(0, 0.9 + distance * 0.08, distance)
    camera.lookAt(0, 0.9, 0)
    camera.updateProjectionMatrix()
    props.onReady()
    invalidate()
  }, [camera, invalidate, props.onReady, size.width, size.height])

  useLayoutEffect(() => {
    motion.current.turn = Number.NaN
    motion.current.settled = false
    motion.current.elapsed = 0
    if (globe.current) globe.current.rotation.x = 0
    invalidate()
  }, [props.revision, invalidate])

  useLayoutEffect(() => { motion.current.lastTime = performance.now(); invalidate() }, [turn, playing, invalidate])
  useFrame(() => {
    const group = globe.current
    if (!group) return
    const m = motion.current
    const now = performance.now()
    if (m.turn !== turn) {
      m.turn = turn
      m.from = group.rotation.x
      // +X 回転で地面の上が手前（+Z）へ進む。次の作品は奥から現れる。
      m.to = turn * step
      m.elapsed = 0
      m.lastTime = now
      m.settled = false
      // 停止中に次を押した場合と、視差効果を減らす設定では選択位置へ直接移る。
      if (!playing || reducedMotion || Math.abs(m.to - m.from) < 0.0001) m.elapsed = transitionMs / 1000
    }
    for (const [i, work] of works.current) {
      const front = Math.max(0, Math.cos(group.rotation.x - i * step))
      work.scale.setScalar(0.8 + 0.2 * front ** 8)
    }
    if (reducedMotion && !m.settled) m.elapsed = transitionMs / 1000
    if (!m.settled && (playing || m.elapsed >= transitionMs / 1000)) {
      m.elapsed = Math.min(transitionMs / 1000, m.elapsed + Math.max(0, now - m.lastTime) / 1000)
      m.lastTime = now
      group.rotation.x = THREE.MathUtils.lerp(m.from, m.to, smoothTurn(m.elapsed * 1000 / transitionMs))
      if (m.elapsed * 1000 >= transitionMs) { m.settled = true; onArrive(turn) }
      else invalidate()
    }
    if (m.settled) {
      const work = works.current.get(index)
      if (work) {
        // 実際のGLBを画面へ投影して下端を求める。メモを作品に重ねないための表示座標。
        group.updateWorldMatrix(true, true)
        camera.updateMatrixWorld()
        bounds.current.setFromObject(work)
        const box = bounds.current
        let bottom = 0
        if (box.isEmpty()) bottom = 0.72
        else for (const x of [box.min.x, box.max.x]) for (const y of [box.min.y, box.max.y]) for (const z of [box.min.z, box.max.z]) {
          corner.current.set(x, y, z).project(camera)
          bottom = Math.max(bottom, (1 - corner.current.y) / 2)
        }
        props.onArtworkBottom(Math.min(1, Math.max(0, bottom)))
      }
    }
  })

  const ground = useMemo(() => {
    const geometry = new THREE.SphereGeometry(RADIUS, 96, 64)
    const positions = geometry.attributes.position
    const colors = new Float32Array(positions.count * 3)
    const earth = new THREE.Color(palette.earth)
    const paper = new THREE.Color(palette.paper)
    const point = new THREE.Vector3()
    const color = new THREE.Color()
    for (let i = 0; i < positions.count; i++) {
      point.fromBufferAttribute(positions, i)
      const ripple = 1 + 0.0007 * Math.sin(point.x * 6) * Math.cos(point.z * 5)
      positions.setXYZ(i, point.x * ripple, point.y * ripple, point.z * ripple)
      // どの作品まで回っても同じ草色。回転で白い裏側に切り替わらない。
      color.copy(paper).lerp(earth, 0.8 + 0.1 * Math.sin(point.x * 1.2) * Math.cos(point.z * 0.8))
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
  return (
    <>
      <color attach="background" args={[palette.paper]} />
      <hemisphereLight args={[palette.surface, palette.earth, 1.15]} />
      <directionalLight position={[-4, 7, 6]} color={palette.surface} intensity={2} castShadow shadow-mapSize={[1024, 1024]} shadow-camera-left={-5} shadow-camera-right={5} shadow-camera-top={5} shadow-camera-bottom={-5} shadow-normalBias={0.025} />
      <directionalLight position={[4, 2, -3]} intensity={0.5} color={palette.paper} />
      <group ref={globe} position={[0, -RADIUS + 0.25, 0]}>
        <mesh ref={groundMesh} geometry={ground} receiveShadow><meshStandardMaterial vertexColors roughness={1} bumpMap={grain} bumpScale={0.035} /></mesh>
        {selected.map(i => (
          <group key={entries[i].artwork.id} rotation-x={-i * step}>
            <group ref={node => { if (node) works.current.set(i, node); else works.current.delete(i) }} position={[0, Math.cos(LATITUDE) * RADIUS + 0.02, RING]} rotation-x={LATITUDE}>
              <ShowcaseArtwork artwork={entries[i].artwork} onReady={props.onModelReady} onSelect={props.onArtwork} />
            </group>
            <group rotation-x={LATITUDE}>
              {entries[i].photos.map((photo, photoIndex) => <GroundPhoto key={photo.id} photo={photo} index={photoIndex} artworkId={entries[i].artwork.id} title={entries[i].artwork.title} ground={groundMesh} focused={props.focusedArtworkId === entries[i].artwork.id} onPhoto={props.onPhoto} />)}
            </group>
          </group>
        ))}
      </group>
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
