// ② ホーム。画面いっぱいに、カメラの側の壁と部屋どうしの間の壁をカットした家（今はリビングだけ）を出す。
// はじめは、リビングの中を東のやや南・壁の上から見下ろす近景（手前に床ランプ、中央にソファとローテーブル、奥に棚）。
// 距離は START_DISTANCE で決まっていて、画面の縦横では変えない。
// ピンチやホイールで引けば家全体まで見える（いちばん離れた距離は、家全体が画面に収まる距離 fit。部屋の定義 house.rooms から fitDistance で決める）。
// ドラッグでぐるりと見回せる（OrbitControls。上下の角度は ⑤ おうちの中と同じ、平行移動はしない。
// 視点の中心は家の外形の中（home/ClampTarget）。カットする壁は、カメラに合わせて HouseShells が入れ替える）。
// 放っておくと、ゆっくり自動で回る（IdleRotate。触ると止まり、最後の操作から 6 秒で再開する）。
// 作品をタップすると onSelect（画面が ⑥ 作品の詳細へ進める）。家具や床のタップは何もしない。
import { useEffect, useLayoutEffect, useMemo, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import { OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import type { Museum, Vec3 } from '../../api'
import { ClampTarget } from './home/ClampTarget'
import { HomeObjects } from './home/HomeObjects'
import { HouseShells } from './home/HouseShells'
import { cornersOf, fitDistance, hasHouseModel, houseBounds, houseRoomsOf, roomBounds, wallThicknessOf } from './home/house'
import { Stage } from './Stage'

/** 見る先（リビングの中心の少し北＝ソファ寄り。ローテーブルとソファが画面の真ん中に来る。カメラはここを中心に回る） */
const LOOK_AT: Vec3 = [0, 0.6, -0.4]
/** はじめの、見る先からカメラへの向き（東のやや南の、壁より上から、約 37° 見下ろす。長さは使わない） */
const DIRECTION: Vec3 = [0.78, 0.62, 0.25]
/** 縦の画角（度）。縦長の画面（スマホ）でも、ソファからサイドボードまでが横に入る広さ */
const FOV = 56
/** はじめの、見る先からカメラまでの距離（m）。家全体を収める距離 fit とは関係なく、画面の縦横でも変えない */
const START_DISTANCE = 8
/** 近づける距離（m）。作品を大きく見られるところまで寄れる */
const MIN_DISTANCE = 3.5
/** いちばん離れたときに家全体を収める余白（fitDistance の margin。1 でぴったり） */
const FRAME = 1
/**
 * 自動で回る速さ（OrbitControls の autoRotateSpeed の、60 fps のときの値）。1 で 1 周 60 秒なので、0.25 で 1 周 240 秒。
 * 近景では画面の上の動きが大きく見えるので、家全体を見ていたころ（0.35）より遅くしている。
 * 正の値なので、カメラは真上から見て（北が上）時計回りに回る
 */
const AUTO_ROTATE_SPEED = 0.25
/** 最後の操作から、自動で回り始めるまで（ms） */
const IDLE_RESUME_MS = 6000

const target = new THREE.Vector3(...LOOK_AT)
/** はじめのカメラの位置（見る先から DIRECTION の向きに START_DISTANCE 離れた所） */
const startEye = new THREE.Vector3(...DIRECTION).normalize().multiplyScalar(START_DISTANCE).add(target)
/** Canvas の camera に渡す、はじめの位置（startEye と同じ。最初のコマからこの構図になる） */
const START_EYE = startEye.toArray() as Vec3

/**
 * OrbitControls。カメラは、はじめの 1 回だけ startEye（リビングの中の近景）に置き、その後は置き直さない。
 * 離れられる距離は、家全体が画面に収まる距離 fit（向きは DIRECTION で測る）。引けば家全体まで見える。
 * 画面（Canvas）の大きさが変わったら fit を測り直して、離れられる距離とカメラの far だけを変える
 * （カメラは動かさない。範囲の外にいるときだけ、OrbitControls が範囲の端まで寄せる）
 */
function HomeControls({ museum }: { museum: Museum }) {
  const size = useThree((s) => s.size)
  const camera = useThree((s) => s.camera)
  const controls = useRef<OrbitControlsImpl>(null)

  const { fit, reach } = useMemo(() => {
    const wall = wallThicknessOf(museum)
    const points = houseRoomsOf(museum).flatMap((room) => cornersOf(roomBounds(room, wall)))
    return {
      fit: fitDistance(points, LOOK_AT, DIRECTION, FOV, size.width / Math.max(1, size.height), FRAME),
      // 見る先から、いちばん遠い家の角まで（m）
      reach: Math.max(...points.map((p) => target.distanceTo(new THREE.Vector3(...p)))),
    }
  }, [museum, size.width, size.height])

  // はじめの 1 回だけ、カメラを startEye に置く（画面の大きさが変わっても、自動で回った向きや人が変えた距離はそのまま）
  useLayoutEffect(() => {
    camera.position.copy(startEye)
    controls.current?.update()
  }, [camera])

  useLayoutEffect(() => {
    // いちばん離れたとき（距離 fit）にも、家の奥の角まで描く（見る先までの距離 + 見る先から家の角まで + 余白）。
    // 縦長のスマホでは fit が 45 m ほどになる
    if (camera instanceof THREE.PerspectiveCamera) {
      camera.far = fit + reach + 2
      camera.updateProjectionMatrix()
    }
  }, [camera, fit, reach])

  return (
    <OrbitControls
      ref={controls}
      makeDefault
      target={LOOK_AT}
      enableDamping
      dampingFactor={0.08}
      enablePan={false}
      minPolarAngle={0.15 * Math.PI}
      maxPolarAngle={0.5 * Math.PI}
      minDistance={MIN_DISTANCE}
      maxDistance={fit}
    />
  )
}

/**
 * 放っておくと、ゆっくり自動で回す（OrbitControls の autoRotate）。
 * 触ると（controls の start）止め、指やマウスを離して（end）から IDLE_RESUME_MS たつと再開する。
 * ページが隠れている間は止める（電池のため）。端末で「視差効果を減らす」が有効なら回さない
 */
function IdleRotate() {
  const controls = useThree((s) => s.controls) as unknown as OrbitControlsImpl | null

  useEffect(() => {
    if (!controls) return
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return
    /** 最後の操作から IDLE_RESUME_MS たったか（はじめは操作していないので true） */
    let idle = true
    let timer = 0
    const apply = () => {
      controls.autoRotate = idle && document.visibilityState === 'visible'
    }
    const onStart = () => {
      window.clearTimeout(timer)
      idle = false
      apply()
    }
    const onEnd = () => {
      window.clearTimeout(timer)
      timer = window.setTimeout(() => {
        idle = true
        apply()
      }, IDLE_RESUME_MS)
    }
    apply()
    controls.addEventListener('start', onStart)
    controls.addEventListener('end', onEnd)
    document.addEventListener('visibilitychange', apply)
    return () => {
      window.clearTimeout(timer)
      controls.removeEventListener('start', onStart)
      controls.removeEventListener('end', onEnd)
      document.removeEventListener('visibilitychange', apply)
      controls.autoRotate = false
    }
  }, [controls])

  // autoRotateSpeed は 1 コマあたりの角度で決まる（120 Hz の画面では 2 倍の速さになる）ので、前のコマからの時間に合わせて直す。
  // 長く止まっていた後（タブを戻したときなど）に大きく飛ばないよう、3 コマ分までにする
  useFrame((_, delta) => {
    if (controls) controls.autoRotateSpeed = AUTO_ROTATE_SPEED * Math.min(delta * 60, 3)
  })
  return null
}

export function HomeScene({
  museum,
  onSelect,
  onReady,
}: {
  museum: Museum
  /** 作品をタップしたとき（作品の id） */
  onSelect?: (artworkId: string) => void
  /** 家の建物が全部そろったとき（1 回だけ） */
  onReady?: () => void
}) {
  const rooms = houseRoomsOf(museum)
  const wall = wallThicknessOf(museum)
  const bounds = useMemo(() => houseBounds(rooms, wall), [rooms, wall])

  if (!hasHouseModel(museum)) return null

  return (
    <Stage camera={{ position: START_EYE, fov: FOV }}>
      <HouseShells museum={museum} cutaway="house" onReady={onReady} />
      <HomeObjects layout={museum.layout} catalog={museum.catalog} slots={museum.slots} house={museum.house} onSelect={onSelect} memoryBadges />
      <HomeControls museum={museum} />
      <ClampTarget bounds={bounds} />
      <IdleRotate />
    </Stage>
  )
}
