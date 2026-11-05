// ⑥ 作品の詳細（/artworks/:id）の上の 3D。作品のモデルだけを、背景なし（画面のグラデーションが透ける）で置く。
// 触ると（ドラッグ）そのまま回せる（自動では回さない）。平行移動はしない。
// 拡大は、3D の上にカーソルがあるときのホイール（カーソルの所へ寄る）と、3D の上での 2 本指のピンチだけ
// （3D の外ではふつうに画面がスクロール・拡大する）。拡大した所は、引くほど作品の中心へ戻る。
// タッチでは、縦のスワイプは画面のスクロールに使い、横のドラッグで回す（CSS の touch-action: pan-y。ArtworkDetail.css）。
// 2 本指のときは画面がスクロールしないように、画面側（ArtworkDetail）で touchmove を止める。
// カメラは、読み込んだモデルの大きさ（外接球）から、縦横どちらにも収まる距離に置く。
import { Suspense, useEffect, useLayoutEffect, useRef, type MutableRefObject, type ReactNode } from 'react'
import { Canvas, useFrame, useThree } from '@react-three/fiber'
import { ContactShadows, Environment, Lightformer, OrbitControls } from '@react-three/drei'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import * as THREE from 'three'
import { FittedModel } from './models'

/** はじめのカメラの向き（正面から少し右・少し上） */
const VIEW_DIR = new THREE.Vector3(0.32, 0.26, 1).normalize()
const FOV = 32
/** いちばん寄ったとき・いちばん引いたときの距離（はじめの距離に対する割合） */
const ZOOM_IN = 0.3
const ZOOM_OUT = 1.35

/** 置いたモデルの大きさとはじめのカメラの距離（Framed が決め、ZoomKeeper が使う） */
interface Fit {
  center: THREE.Vector3
  radius: number
  distance: number
}

export function ArtworkViewerScene({
  modelUrl,
  onReady,
  onInteract,
  onZoomChange,
  resetKey = 0,
}: {
  modelUrl: string
  /** モデルを置いて、カメラを合わせ終わったとき */
  onReady?: () => void
  /** はじめて触ったとき（説明の文字を消すのに使う） */
  onInteract?: () => void
  /** 拡大しているか（「元の大きさ」ボタンを出すのに使う） */
  onZoomChange?: (zoomed: boolean) => void
  /** 変えると、向きはそのままで、はじめの大きさと中心へなめらかに戻る */
  resetKey?: number
}) {
  const fit = useRef<Fit | null>(null)
  return (
    <Canvas
      dpr={[1, 2]}
      camera={{ position: [0, 0.8, 4], fov: FOV, near: 0.05, far: 50 }}
      // preserveDrawingBuffer：画面を離れるときの遷移（View Transitions）が、描いた 3D をそのまま写せるように
      // （無いと、写す瞬間にキャンバスが空になって、作品が消えてから画面が動いて見える）
      gl={{ antialias: true, alpha: true, powerPreference: 'high-performance', preserveDrawingBuffer: true }}
      onCreated={({ gl }) => {
        gl.setClearColor(0x000000, 0)
        gl.toneMapping = THREE.NeutralToneMapping
        gl.toneMappingExposure = 1.05
      }}
    >
      <ViewerLights />
      <Suspense fallback={null}>
        <Framed fit={fit} onReady={onReady}>
          <FittedModel url={modelUrl} fit={[1.4, 1.4, 1.4]} />
        </Framed>
        {/* 足もとのやわらかい影（モデルの底は y = 0） */}
        {/* モデルは動かない（回るのはカメラ）ので、影は 1 回だけ描けばよい */}
        <ContactShadows frames={1} position={[0, 0.001, 0]} scale={3} blur={2.6} far={1.6} opacity={0.32} resolution={512} color="#5b4630" />
      </Suspense>
      <Controls onInteract={onInteract} />
      <ZoomKeeper fit={fit} resetKey={resetKey} onZoomChange={onZoomChange} />
    </Canvas>
  )
}

function ViewerLights() {
  return (
    <>
      <hemisphereLight args={['#fff8ee', '#d8c6ad', 1.0]} />
      <directionalLight position={[3, 5, 4]} intensity={1.5} color="#fff0db" />
      <directionalLight position={[-4, 3, -3]} intensity={0.5} color="#ffe6cc" />
      {/* 外部 HDR を読まずに、まわりの柔らかい明かりを作る（立体の作品の面の向きが分かるように） */}
      <Environment resolution={64} frames={1}>
        <Lightformer form="rect" intensity={2} position={[0, 4, 0]} rotation-x={Math.PI / 2} scale={[8, 8, 1]} color="#fff6e8" />
        <Lightformer form="rect" intensity={0.8} position={[0, 1, 5]} rotation-y={Math.PI} scale={[8, 2.5, 1]} color="#ffe5c7" />
        <Lightformer form="rect" intensity={0.8} position={[0, 1, -5]} scale={[8, 2.5, 1]} color="#ffe5c7" />
      </Environment>
    </>
  )
}

function Controls({ onInteract }: { onInteract?: () => void }) {
  const touched = useRef(false)
  return (
    <OrbitControls
      makeDefault
      enableDamping
      dampingFactor={0.08}
      enablePan={false}
      enableZoom
      zoomToCursor
      zoomSpeed={0.9}
      rotateSpeed={0.8}
      // 真上・真下からは見ない（作品の底や天井で迷わないように）
      minPolarAngle={0.12 * Math.PI}
      maxPolarAngle={0.62 * Math.PI}
      onStart={() => {
        if (!touched.current) { touched.current = true; onInteract?.() }
      }}
    />
  )
}

/** 中のモデルが置かれたら、その大きさに合わせてカメラの距離と回す中心を決める */
function Framed({ children, fit, onReady }: { children: ReactNode; fit: MutableRefObject<Fit | null>; onReady?: () => void }) {
  const group = useRef<THREE.Group>(null)
  const camera = useThree((s) => s.camera) as THREE.PerspectiveCamera
  const controls = useThree((s) => s.controls) as OrbitControlsImpl | null
  const size = useThree((s) => s.size)
  const invalidate = useThree((s) => s.invalidate)
  const reported = useRef(false)

  useLayoutEffect(() => {
    const object = group.current
    if (!object) return
    const box = new THREE.Box3().setFromObject(object)
    if (box.isEmpty()) return
    const sphere = box.getBoundingSphere(new THREE.Sphere())
    const vHalf = THREE.MathUtils.degToRad(camera.fov / 2)
    const hHalf = Math.atan(Math.tan(vHalf) * (size.width / Math.max(1, size.height)))
    // 縦・横のどちらにも収まる距離。外接球は見た目より大きいので、少し寄せる（回しても端が切れない程度）
    const distance = (sphere.radius / Math.sin(Math.min(vHalf, hHalf))) * 0.9
    const target = sphere.center
    // 触ったあとの向きは保つ（画面の大きさが変わったときは距離だけ合わせ直す）
    const dir = reported.current ? camera.position.clone().sub(controls?.target ?? target).normalize() : VIEW_DIR
    camera.position.copy(target).addScaledVector(dir, distance)
    camera.near = Math.max(0.01, distance / 100)
    camera.far = distance * 10
    camera.updateProjectionMatrix()
    fit.current = { center: target.clone(), radius: sphere.radius, distance }
    if (controls) {
      controls.minDistance = distance * ZOOM_IN
      controls.maxDistance = distance * ZOOM_OUT
      controls.target.copy(target)
      controls.update()
    } else camera.lookAt(target)
    invalidate()
    if (!reported.current && controls) {
      reported.current = true
      onReady?.()
    }
  }, [camera, controls, size.width, size.height, invalidate, onReady, fit])

  return <group ref={group}>{children}</group>
}

/**
 * 拡大のあとしまつ（毎フレーム）。
 * - カーソルの所へ寄ると回す中心（target）が作品の中心からずれる。引くほど中心へ戻し、はじめの距離まで引いたらぴったり中心にする
 *   （ずれたまま回すと、作品が画面の外へ回っていってしまう）。target とカメラを同じだけ動かすので、見え方はとばない
 * - resetKey が変わったら、向きはそのままで、はじめの距離と中心へなめらかに戻す
 * - 拡大しているかを onZoomChange で知らせる
 */
function ZoomKeeper({ fit, resetKey, onZoomChange }: { fit: MutableRefObject<Fit | null>; resetKey: number; onZoomChange?: (zoomed: boolean) => void }) {
  const camera = useThree((s) => s.camera)
  const controls = useThree((s) => s.controls) as OrbitControlsImpl | null
  const resetting = useRef(false)
  const zoomed = useRef(false)
  const first = useRef(true)
  useEffect(() => {
    if (first.current) { first.current = false; return }
    resetting.current = true
  }, [resetKey])

  const off = useRef(new THREE.Vector3())
  const dir = useRef(new THREE.Vector3())
  useFrame((_, dt) => {
    const f = fit.current
    if (!f || !controls) return
    const target = controls.target
    if (resetting.current) {
      const k = 1 - Math.exp(-Math.min(0.1, dt) * 9)
      dir.current.copy(camera.position).sub(target).normalize()
      const distance = camera.position.distanceTo(target)
      target.lerp(f.center, k)
      camera.position.copy(target).addScaledVector(dir.current, THREE.MathUtils.lerp(distance, f.distance, k))
      if (target.distanceTo(f.center) < f.radius * 0.002 && Math.abs(distance - f.distance) < f.distance * 0.002) {
        target.copy(f.center)
        camera.position.copy(target).addScaledVector(dir.current, f.distance)
        resetting.current = false
      }
    } else {
      // 寄っているほど、中心からずれてよい量を大きくする
      const distance = camera.position.distanceTo(target)
      const minD = f.distance * ZOOM_IN
      const t = THREE.MathUtils.clamp((distance - minD) / Math.max(1e-6, f.distance - minD), 0, 1)
      const allowed = f.radius * 0.75 * (1 - t * t * (3 - 2 * t))
      off.current.copy(target).sub(f.center)
      const length = off.current.length()
      if (length > allowed + 1e-6) {
        const shift = off.current.multiplyScalar((allowed - length) / Math.max(1e-6, length))
        target.add(shift)
        camera.position.add(shift)
      }
    }
    const now = camera.position.distanceTo(target) < f.distance * 0.95 || target.distanceTo(f.center) > f.radius * 0.04
    if (now !== zoomed.current) {
      zoomed.current = now
      onZoomChange?.(now)
    }
  })
  return null
}
