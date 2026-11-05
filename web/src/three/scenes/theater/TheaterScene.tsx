// 期間をえらんで振り返るシアターの 3D（/map/theater の DigestTheater が three/index.tsx 経由で使う）。
//
// 舞台：手描きの家・木・低木・丘が立つ、大きな球の大地（globe.ts・stageProps.ts）。カメラは動かさず、大地が止まらずに回り続けて、
//       作品が奥の稜線から現れ、頂上でゆっくりになり、手前の下へ流れていく（timeline.ts の globeAngleAt）。
// 作品：いまの場面と、前の作品・次の 2 つの作品だけを置く（ShowcaseArtwork。GLB を読めなければ写真）。
// 写真立て：いまの場面の作品の左右に、おもいでの写真・動画を立てる（MediaStand）。
// メモ：3D の中には描かず、作品の上の位置を画面の座標にして memoAnchor（画面の要素）を動かす。
//
// 時刻は画面が持つ clock（ミリ秒）を毎フレーム読む。場面・段階・大地の角度はすべて timeline.ts の frameAt から決まるので、
// シークしても止めても、3D と音（画面が合わせる）がずれない。
import { Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type MutableRefObject, type RefObject } from 'react'
import { Canvas, useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js'
import type { Artwork, TheaterData } from '../../../api'
import { DioramaPost } from '../DioramaEffects'
import { ShowcaseArtwork } from '../home/HomeObjects'
import { RADIUS, VISIBLE_FROM, VISIBLE_TO, backdropLayout, decorLayout, flowerLayout, placeOnGlobe, relativeAngle } from './globe'
import { MediaStand, standSize } from './MediaStand'
import { StageKit, loadStageManifest } from './stageProps'
import { SLOT_ANGLE, frameAt, standLift, stopMotionTime } from './timeline'

export interface TheaterSceneProps {
  data: TheaterData
  /** 再生位置（ミリ秒）。画面が書き換え、ここでは毎フレーム読むだけ */
  clock: RefObject<number>
  /** いまの場面（画面が clock から求めたもの。前後の作品を置き直すのに使う） */
  index: number
  playing: boolean
  /** シークしたときなどに増やす（止まっているときに描き直す） */
  version: number
  stopMotion: boolean
  reducedMotion: boolean
  /** スマホなど。影と仕上げを軽くする */
  lite: boolean
  /** メモを置く画面の要素。作品の上に来るよう、毎フレーム transform を書き換える */
  memoAnchor: RefObject<HTMLDivElement | null>
  videoFor: (memoryId: string) => HTMLVideoElement | null
  onModelReady: (id: string, fallback: boolean) => void
  onArtwork: (id: string) => void
  onMedia: (sceneIndex: number, mediaIndex: number) => void
  onReady: () => void
  onStageError: (error: Error) => void
  /**
   * いまの 3D の 1 コマを ImageBitmap にする関数を入れてもらう入れ物。
   * 作品の詳細へ行くときに撮っておき、戻ってきたら 3D の準備ができるまでその絵を見せる（画面がからっぽにならないように）
   */
  captureRef?: MutableRefObject<(() => Promise<ImageBitmap | null>) | null>
}

/** 作品を収める箱（ShowcaseArtwork の FittedModel と同じ値） */
const FIT = 2.8

/**
 * 作品が画面に入る、大地の上の角度の範囲（頂上からの角度。正が奥）。framing のカメラ（横長・縦長）から求めた値に少し余裕を足したもの。
 * 奥：カメラから見た地平線は頂上の約 0.23 奥で、高さ 2.8 m（FIT）の作品の頭も約 0.70 より奥では沈んで見えない。
 * 手前：約 −0.40 より手前では、作品の頭まで画面の下へ抜けている（影は奥へ落ちるので、画面に残らない）。
 * 家や木（VISIBLE_FROM / VISIBLE_TO）は背が高いので、もっと広い範囲で描く
 */
const ART_VISIBLE_FROM = -0.5
const ART_VISIBLE_TO = 0.75

/** 作品を置いたときの見た目の半分の幅と高さ（FittedModel と同じ計算。実寸が無ければ目安） */
export function displayedSize(artwork: Artwork): { halfWidth: number; height: number } {
  const size = artwork.model_size
  if (!size || size.some((v) => !(v > 0))) return { halfWidth: 1.05, height: 2.1 }
  const [w, h, d] = size
  const diameter = Math.max(0.001, Math.hypot(w, d))
  const scale = Math.min(FIT / diameter, FIT / Math.max(0.001, h)) * 0.9
  return { halfWidth: (w * scale) / 2, height: h * scale }
}

/** 画面の縦横比から、カメラの距離と、写真立ての置き方を決める */
function framing(aspect: number) {
  const portrait = aspect < 0.95
  const fov = 18
  const tan = Math.tan(THREE.MathUtils.degToRad(fov / 2))
  // 見せたい幅と高さ（作品 + 写真立て + 上のメモの余白）
  const needWidth = portrait ? 3.45 : 7.6
  const needHeight = portrait ? 5.4 : 5.2
  const distance = Math.max(needHeight / 2 / tan, needWidth / 2 / (tan * aspect))
  const elevation = THREE.MathUtils.degToRad(portrait ? 11 : 9.5)
  const target = new THREE.Vector3(0, portrait ? 1.75 : 1.55, 0)
  const position = new THREE.Vector3(0, target.y + Math.sin(elevation) * distance, Math.cos(elevation) * distance)
  return { portrait, fov, distance, target, position }
}

/** 写真立ての大きさと置き場所（作品の幅に合わせて、重ならないように） */
function standPlacement(portrait: boolean, halfWidth: number, side: 'left' | 'right', size: [number, number]) {
  const s = side === 'left' ? -1 : 1
  const [w] = size
  if (portrait) {
    // 縦長の画面では、作品の手前の左右に、少し重ねて置く
    return { x: s * (Math.min(halfWidth, 1.0) + w * 0.05), z: 1.75 }
  }
  return { x: s * (halfWidth + 0.38 + w / 2), z: 0.45 }
}

function World(props: TheaterSceneProps & { kit: StageKit }) {
  const { data, clock, index, kit, lite, stopMotion, reducedMotion, memoAnchor, version } = props
  const globe = useRef<THREE.Group>(null)
  const camera = useThree((s) => s.camera) as THREE.PerspectiveCamera
  const size = useThree((s) => s.size)
  const invalidate = useThree((s) => s.invalidate)
  const scene = useThree((s) => s.scene)
  const gl = useThree((s) => s.gl)
  const view = useMemo(() => framing(size.width / Math.max(1, size.height)), [size.width, size.height])
  const shadows = true

  // 空（画面いっぱいに、縦横比を保って切り抜く）と、部屋の光の映り込み
  const sky = useMemo(() => kit.texture(kit.manifest.sky), [kit])
  useLayoutEffect(() => {
    const imageAspect = 1.5
    const aspect = size.width / Math.max(1, size.height)
    if (aspect < imageAspect) {
      sky.repeat.set(aspect / imageAspect, 1)
      sky.offset.set((1 - aspect / imageAspect) / 2, 0)
    } else {
      sky.repeat.set(1, imageAspect / aspect)
      sky.offset.set(0, (1 - imageAspect / aspect) * 0.15)
    }
    scene.background = sky
    invalidate()
  }, [sky, scene, size.width, size.height, invalidate])
  useEffect(() => {
    const pmrem = new THREE.PMREMGenerator(gl)
    const env = pmrem.fromScene(new RoomEnvironment(), 0.04).texture
    scene.environment = env
    scene.environmentIntensity = 0.22
    return () => { scene.environment = null; env.dispose(); pmrem.dispose() }
  }, [gl, scene])

  useLayoutEffect(() => {
    camera.fov = view.fov
    camera.near = 0.5
    camera.far = 140
    camera.position.copy(view.position)
    camera.lookAt(view.target)
    camera.updateProjectionMatrix()
    invalidate()
  }, [camera, view, invalidate])

  // 地面
  const ground = useMemo(() => {
    const geometry = new THREE.SphereGeometry(RADIUS, 160, 96).rotateZ(Math.PI / 2)
    const map = kit.texture(kit.manifest.ground)
    map.wrapS = map.wrapT = THREE.RepeatWrapping
    map.repeat.set(26, 13)
    const normal = kit.texture(kit.manifest.paint_normal, false)
    normal.wrapS = normal.wrapT = THREE.RepeatWrapping
    normal.repeat.set(60, 30)
    const material = new THREE.MeshStandardMaterial({ color: '#fffaf0', map, normalMap: normal, normalScale: new THREE.Vector2(0.5, 0.5), roughness: 0.96, metalness: 0 })
    return { geometry, material }
  }, [kit])
  useEffect(() => () => { ground.geometry.dispose(); ground.material.dispose() }, [ground])

  // 家・木・低木・丘
  const decor = useMemo(() => {
    const props = kit.manifest.props
    return decorLayout(props).flatMap((place) => {
      const prop = props.find((p) => p.name === place.prop)
      if (!prop) return []
      const anchor = new THREE.Group()
      placeOnGlobe(anchor, place.phi, place.x, -0.02)
      const mesh = kit.mesh(prop, prop.kind !== 'hill')
      mesh.rotation.y = place.yaw
      mesh.scale.setScalar(place.scale)
      anchor.add(mesh)
      return [{ anchor, phi: place.phi }]
    })
  }, [kit])

  // 奥の、動かない丘。カメラから大地の縁（地平線）をかすめる線の上に、頭だけ出るように置く
  const backdrop = useMemo(() => {
    const props = kit.manifest.props
    const group = new THREE.Group()
    const cy = view.position.y
    const cz = view.position.z
    const centerDistance = Math.hypot(cz, cy + RADIUS)
    const below = Math.atan2(cy + RADIUS, cz) - Math.asin(RADIUS / centerDistance)
    const depth = 17
    const horizonY = cy - (cz + depth) * Math.tan(below)
    backdropLayout(props).forEach((place, i) => {
      const prop = props.find((p) => p.name === place.prop)
      if (!prop) return
      const mesh = kit.mesh(prop, false)
      mesh.scale.setScalar(place.scale)
      mesh.rotation.y = place.yaw
      mesh.position.set(place.x * 0.55, horizonY - prop.height * place.scale * 0.55, -depth - (i % 3) * 1.6)
      group.add(mesh)
    })
    return group
  }, [kit, view])

  // 小さな花（インスタンスでまとめて描く）
  const flowers = useMemo(() => {
    const list = flowerLayout()
    const head = new THREE.InstancedMesh(new THREE.SphereGeometry(0.05, 10, 8).scale(1, 0.6, 1), new THREE.MeshStandardMaterial({ roughness: 0.8 }), list.length)
    const stem = new THREE.InstancedMesh(new THREE.CylinderGeometry(0.008, 0.011, 1, 5).translate(0, 0.5, 0), new THREE.MeshStandardMaterial({ color: '#7FA68B', roughness: 0.9 }), list.length)
    const holder = new THREE.Object3D()
    const color = new THREE.Color()
    list.forEach((f, i) => {
      placeOnGlobe(holder, f.phi, f.x, -0.01)
      holder.scale.set(1, f.height, 1)
      holder.updateMatrix()
      stem.setMatrixAt(i, holder.matrix)
      placeOnGlobe(holder, f.phi, f.x, f.height - 0.01)
      holder.scale.set(1, 1, 1)
      holder.updateMatrix()
      head.setMatrixAt(i, holder.matrix)
      head.setColorAt(i, color.set(f.color))
    })
    head.castShadow = stem.castShadow = !lite
    return { head, stem }
  }, [lite])
  useEffect(() => () => {
    for (const m of [flowers.head, flowers.stem]) { m.geometry.dispose(); (m.material as THREE.Material).dispose(); m.dispose() }
  }, [flowers])

  // いまの場面と、流れ去る前の作品・稜線から出てくる次の 2 つ（先に置いて、3D の読み込みを早めに始める）
  const nearby = useMemo(() => [index - 1, index, index + 1, index + 2].filter((i) => i >= 0 && i < data.scenes.length), [index, data.scenes.length])
  const slots = useRef(new Map<number, THREE.Group>())
  const stands = useRef(new Map<number, THREE.Group>())
  const art = useRef(new Map<number, THREE.Group>())
  const anchorPoint = useRef(new THREE.Vector3())
  const scene0 = data.scenes[index]
  const artSize = useMemo(() => (scene0 ? displayedSize(scene0.artwork) : { halfWidth: 1, height: 2 }), [scene0])

  useEffect(() => { invalidate() }, [version, invalidate, index])
  const scene0Arrive = (i: number) => data.scenes[i]?.arrive_ms ?? 0

  useFrame(() => {
    const g = globe.current
    if (!g) return
    const t = clock.current ?? 0
    const frame = frameAt(data, t)
    // コマ撮り風：大地はなめらかに流したまま、作品のゆれと写真立ての動きだけを 1 秒 12 コマにする
    const step = stopMotion && !reducedMotion
    const poseT = step ? stopMotionTime(t) : t
    let angle = frame.angle
    if (reducedMotion) {
      // 動きを減らす設定では、流さずに作品ごとに切り替える（画面がふわっと白くして隠す）
      angle = (frame.phase === 'hold' || frame.phase === 'outro' || frame.travel >= 0.5 ? frame.index : frame.index - 1) * SLOT_ANGLE
    }
    g.rotation.x = angle

    for (const d of decor) {
      const rel = relativeAngle(d.phi, angle)
      d.anchor.visible = rel > VISIBLE_FROM && rel < VISIBLE_TO
    }

    // 作品：大地と一緒に流れる。画面に入らない作品（地平線の向こうに沈んでいる・画面の下へ抜けた）は、影も含めて描かない。
    // 次の次の作品は、読み込みを早めるために置いているだけで、ふつうは地平線の向こうにいる
    const current = data.scenes[frame.index]
    for (const [i, group] of slots.current) {
      const rel = relativeAngle(i * SLOT_ANGLE, angle)
      group.visible = rel > ART_VISIBLE_FROM && rel < ART_VISIBLE_TO
    }
    // コマ撮り風のときだけ、作品が人形のように小さくゆれる（作品ごとに少しずらす）。それ以外は止まったまま
    for (const [i, group] of art.current) {
      if (!step) { group.rotation.set(0, 0, 0); group.position.y = 0; continue }
      const s = (poseT / 1000) * Math.PI * 2 * 0.55 + i * 1.7
      group.rotation.set(0, Math.sin(s) * 0.045, Math.sin(s * 0.5 + 0.8) * 0.018)
      group.position.y = Math.max(0, Math.sin(s * 2)) * 0.025
    }

    // 写真立て：底辺を軸に、後ろへ倒れた状態から起こす
    if (current) {
      for (const [m, group] of stands.current) {
        const slot = current.media[m]
        if (!slot) continue
        const local = poseT - scene0Arrive(frame.index)
        const lift = frame.phase === 'hold' || frame.phase === 'outro' ? standLift(slot.show_ms, slot.hide_ms, local) : 0
        const eased = reducedMotion ? (lift > 0.01 ? 1 : 0) : 1 - (1 - lift) ** 3
        group.visible = lift > 0.001
        group.rotation.x = -(1 - eased) * Math.PI * 0.5
        group.scale.setScalar(0.85 + eased * 0.15)
      }
    }

    // メモの位置（作品の上）を画面の座標にする
    const memo = memoAnchor.current
    const slot = slots.current.get(frame.index)
    if (memo && slot) {
      anchorPoint.current.set(0, artSize.height + 0.25, 0)
      slot.localToWorld(anchorPoint.current)
      anchorPoint.current.project(camera)
      // 画面の端と、上の操作列に重ならないようにする（メモの雲の幅は最大 420px）
      const half = Math.min(210, size.width / 2 - 16)
      const x = THREE.MathUtils.clamp((anchorPoint.current.x * 0.5 + 0.5) * size.width, 16 + half, size.width - 16 - half)
      const y = THREE.MathUtils.clamp((-anchorPoint.current.y * 0.5 + 0.5) * size.height, 150, size.height - 220)
      memo.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`
    }
  })

  const bindSlot = useCallback((i: number) => (group: THREE.Group | null) => {
    if (group) {
      placeOnGlobe(group, i * SLOT_ANGLE, 0, -0.02)
      slots.current.set(i, group)
    } else slots.current.delete(i)
  }, [])
  const bindArt = useCallback((i: number) => (group: THREE.Group | null) => {
    if (group) art.current.set(i, group)
    else art.current.delete(i)
  }, [])
  const bindStand = useCallback((m: number) => (group: THREE.Group | null) => {
    if (group) stands.current.set(m, group)
    else stands.current.delete(m)
  }, [])
  const standReady = useCallback(() => invalidate(), [invalidate])

  return (
    <>
      <hemisphereLight args={['#fff9e8', '#c9c3a6', 1.05]} />
      <directionalLight
        position={[-9, 16, 12]}
        intensity={2.2}
        color="#fff1d8"
        castShadow
        shadow-mapSize={lite ? [1024, 1024] : [2048, 2048]}
        shadow-bias={-0.0002}
        shadow-normalBias={0.035}
        shadow-camera-left={-13}
        shadow-camera-right={13}
        shadow-camera-top={13}
        shadow-camera-bottom={-13}
        shadow-camera-near={0.5}
        shadow-camera-far={60}
        onUpdate={(light: THREE.DirectionalLight) => { light.target.position.set(0, 0, -2); light.target.updateMatrixWorld(); light.shadow.camera.updateProjectionMatrix() }}
      />
      <directionalLight position={[10, 7, 2]} intensity={0.45} color="#d4efff" />
      <group ref={globe} position={[0, -RADIUS, 0]}>
        <mesh geometry={ground.geometry} material={ground.material} receiveShadow />
        {decor.map((d, i) => <primitive key={i} object={d.anchor} />)}
        <primitive object={flowers.stem} />
        <primitive object={flowers.head} />
        {nearby.map((i) => {
          const s = data.scenes[i]
          const isCurrent = i === index
          const size = isCurrent ? artSize : displayedSize(s.artwork)
          return (
            <group key={s.artwork.id} ref={bindSlot(i)}>
              <group ref={bindArt(i)}>
                <ShowcaseArtwork artwork={s.artwork} onReady={props.onModelReady} onSelect={props.onArtwork} />
              </group>
              {isCurrent && s.media.map((slot, m) => {
                const dims = standSize(slot.memory, view.portrait ? 0.92 : 1.35)
                const place = standPlacement(view.portrait, size.halfWidth, slot.side, dims)
                return (
                  <group key={slot.memory.id} position={[place.x, -0.02, place.z]} rotation={[0, slot.side === 'left' ? 0.28 : -0.28, 0]}>
                    <MediaStand
                      memory={slot.memory}
                      width={dims[0]}
                      height={dims[1]}
                      video={slot.memory.kind === 'video' ? props.videoFor(slot.memory.id) : null}
                      shadows={shadows}
                      paintNormal={kit.paintNormal}
                      onReady={standReady}
                      onSelect={() => props.onMedia(i, m)}
                      bind={bindStand(m)}
                    />
                  </group>
                )
              })}
            </group>
          )
        })}
      </group>
      <primitive object={backdrop} />
      <DioramaPost lite={lite} tilt={1.1} band={0.28} />
      <FirstFrame onReady={props.onReady} />
      {props.captureRef && <FrameCapture captureRef={props.captureRef} />}
    </>
  )
}

/** 最初の 1 枚を描いたら知らせる（「準備しています…」を消す） */
function FirstFrame({ onReady }: { onReady: () => void }) {
  const done = useRef(false)
  useFrame(() => {
    if (done.current) return
    done.current = true
    requestAnimationFrame(() => onReady())
  })
  return null
}

/**
 * 頼まれたら、次に描いたコマを ImageBitmap にする。
 * 仕上げ（DioramaPost の composer.render。優先度 1）のあとの優先度 2 で、描き終えた絵をそのまま写す
 * （preserveDrawingBuffer なしでも、描いた直後の同じフレームの中なら写せる）。止めているとき（frameloop demand）は invalidate で 1 コマ描かせる。
 * toDataURL（JPEG にする）は GPU から読み戻して CPU で圧縮するので、押してから画面が変わるまで止まってしまう。createImageBitmap は GPU の中で写すだけで軽い
 */
function FrameCapture({ captureRef }: { captureRef: MutableRefObject<(() => Promise<ImageBitmap | null>) | null> }) {
  const gl = useThree((s) => s.gl)
  const invalidate = useThree((s) => s.invalidate)
  const waiting = useRef<((bitmap: Promise<ImageBitmap | null>) => void)[]>([])
  useEffect(() => {
    captureRef.current = () => new Promise<ImageBitmap | null>((resolve) => {
      let settled = false
      const done = (bitmap: Promise<ImageBitmap | null>) => {
        if (settled) return
        settled = true
        window.clearTimeout(timer)
        void bitmap.then(resolve, () => resolve(null))
      }
      // 描かれないまま待ち続けないように
      const timer = window.setTimeout(() => {
        waiting.current = waiting.current.filter((w) => w !== done)
        done(Promise.resolve(null))
      }, 250)
      waiting.current.push(done)
      invalidate()
    })
    return () => { captureRef.current = null }
  }, [captureRef, invalidate])
  useFrame(() => {
    if (waiting.current.length === 0) return
    const list = waiting.current
    waiting.current = []
    let bitmap: Promise<ImageBitmap | null>
    try { bitmap = createImageBitmap(gl.domElement) } catch { bitmap = Promise.resolve(null) }
    // 1 枚を、待っている全員で使う
    list.forEach((resolve) => resolve(bitmap))
  }, 2)
  return null
}

/** 舞台の絵（stage.json と画像）を読んでから World を置く */
function StageLoader(props: TheaterSceneProps) {
  const gl = useThree((s) => s.gl)
  const invalidate = useThree((s) => s.invalidate)
  const [kit, setKit] = useState<StageKit | null>(null)
  const { onStageError } = props
  useEffect(() => {
    let alive = true
    let made: StageKit | null = null
    loadStageManifest()
      .then((manifest) => {
        if (!alive) return
        made = new StageKit(manifest, gl.capabilities.getMaxAnisotropy(), () => invalidate())
        setKit(made)
      })
      .catch((error: Error) => { if (alive) onStageError(error) })
    return () => { alive = false; made?.close() }
  }, [gl, invalidate, onStageError])
  if (!kit) return null
  return <World {...props} kit={kit} />
}

export function TheaterScene(props: TheaterSceneProps) {
  return (
    <Canvas
      shadows={{ type: THREE.PCFShadowMap }}
      dpr={props.lite ? [1, 1.25] : [1, 1.6]}
      frameloop={props.playing ? 'always' : 'demand'}
      gl={{ antialias: false, powerPreference: 'high-performance' }}
      camera={{ fov: 18, near: 0.5, far: 140, position: [0, 8, 45] }}
      onCreated={({ gl }) => {
        // 紙の淡い色をそのまま出す（ACES は色がくすむ）
        gl.toneMapping = THREE.NeutralToneMapping
        gl.toneMappingExposure = 0.95
      }}
    >
      <Suspense fallback={null}>
        <StageLoader {...props} />
      </Suspense>
    </Canvas>
  )
}
