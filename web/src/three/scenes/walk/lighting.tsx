// 鑑賞モード（一人称で歩く画面）の照明。Unity 版の博物館（MuseumBuilder.cs の CreateDaylight・CreateGalleryLights）と同じ構成：
//   - 太陽（影を落とす平行光源。家の天井の板は影を落とさないので、天窓から差すように床を照らす）
//   - 環境光（Trilight：上・横・下から来る光の色）
//   - 天井のスポットライト（影なし。家ではダウンライト）
//   - 空（壁の上の切れ目などから見える）
//   - 映り込み（部屋の中央から部屋の中を 1 度だけ撮って、金属やガラスに映す。Unity の反射プローブ）
//
// 強さは stagePreset.ts に Unity の値のまま書き、ここで three.js の単位に換算する。
//   - Unity（Built-in・リニア色空間・lightsUseLinearIntensity=false）は、sRGB の色 × 強さ をリニアに直した値を光の色にする
//   - Unity の Standard シェーダーは拡散光を π で割らないが、three.js は割る。そのため直接光は π 倍する
//   - 環境光は、どちらも「一様な色 C の環境光で、白い面が C になる」ので換算しない

import { useEffect, useLayoutEffect, useMemo } from 'react'
import { useThree } from '@react-three/fiber'
import { Sky } from '@react-three/drei'
import * as THREE from 'three'
import type { SpotLightSpec, StagePreset, Vec3 } from './stagePreset'

const DEG = Math.PI / 180
/** Unity の拡散光の強さを three.js の強さにする倍率 */
const UNITY_DIRECT_LIGHT_SCALE = Math.PI

/** Unity の光の色（sRGB の色 × 強さ をリニアに直したもの） */
function unityLightColor(color: Vec3, power: number) {
  return new THREE.Color().setRGB(color[0] * power, color[1] * power, color[2] * power, THREE.SRGBColorSpace)
}

/** Unity の Euler 角（x: 見下ろす角度, y: 水平の向き）の光が進む向き。Unity の forward(+Z) を x → y の順に回したもの */
export function sunDirection([x, y]: [number, number]) {
  return new THREE.Vector3(Math.cos(x * DEG) * Math.sin(y * DEG), -Math.sin(x * DEG), Math.cos(x * DEG) * Math.cos(y * DEG))
}

// ---------- 太陽 ----------

/** 太陽の影を、ステージ全体（bounds）がちょうど入る範囲で作る */
function fitSunShadow(light: THREE.DirectionalLight, direction: THREE.Vector3, bounds: THREE.Box3) {
  const center = bounds.getCenter(new THREE.Vector3())
  const radius = bounds.getSize(new THREE.Vector3()).length() / 2
  light.position.copy(center).addScaledVector(direction, -radius * 2)
  light.target.position.copy(center)
  light.target.updateMatrixWorld()

  // 光から見た向きで、ステージの 8 つの角がどこに来るかを調べて範囲を決める
  const view = new THREE.Matrix4().lookAt(light.position, center, new THREE.Vector3(0, 1, 0))
  const toLight = new THREE.Matrix4().makeTranslation(light.position.x, light.position.y, light.position.z).multiply(view).invert()
  const box = new THREE.Box3()
  for (let i = 0; i < 8; i++) {
    const corner = new THREE.Vector3(
      i & 1 ? bounds.max.x : bounds.min.x,
      i & 2 ? bounds.max.y : bounds.min.y,
      i & 4 ? bounds.max.z : bounds.min.z,
    )
    box.expandByPoint(corner.applyMatrix4(toLight))
  }
  const camera = light.shadow.camera
  camera.left = box.min.x - 0.5
  camera.right = box.max.x + 0.5
  camera.bottom = box.min.y - 0.5
  camera.top = box.max.y + 0.5
  camera.near = Math.max(0.1, -box.max.z - 1)
  camera.far = -box.min.z + 1
  camera.updateProjectionMatrix()
}

/** ステージを読み込むまでの影の範囲（リビング 10 × 10 m、高さ 4.2 m くらい）。MuseumDaylight に initialBounds が無いとき */
const DEFAULT_INITIAL_BOUNDS = new THREE.Box3(new THREE.Vector3(-5.5, 0, -5.5), new THREE.Vector3(5.5, 4.4, 5.5))

/** 太陽の影の細かさ（影の画像の 1 辺の px）。スマホなどの軽い表示では MuseumDaylight に半分の値を渡す */
const SHADOW_MAP_SIZE = 2048

function Sun({
  preset,
  bounds,
  initialBounds,
  shadowMapSize,
}: {
  preset: StagePreset
  bounds: THREE.Box3 | null
  initialBounds: THREE.Box3
  shadowMapSize: number
}) {
  const { sun } = preset
  const light = useMemo(() => {
    const l = new THREE.DirectionalLight(unityLightColor(sun.color, sun.power), UNITY_DIRECT_LIGHT_SCALE)
    l.castShadow = true
    l.shadow.mapSize.set(shadowMapSize, shadowMapSize)
    l.shadow.intensity = sun.shadowStrength
    l.shadow.bias = -0.0004
    l.shadow.normalBias = 0.03
    l.shadow.radius = 3
    return l
  }, [sun, shadowMapSize])

  useLayoutEffect(() => {
    // ステージを読み込むまでは、家の外形（initialBounds）くらいの範囲にしておく
    fitSunShadow(light, sunDirection(sun.eulerDeg), bounds ?? initialBounds)
  }, [light, sun, bounds, initialBounds])

  useEffect(() => () => light.dispose(), [light])
  return <primitive object={light} />
}

// ---------- 環境光 ----------

/** Unity の Trilight（上・横・下の 3 色のグラデーション）を、three.js の LightProbe（球面調和関数）にする */
function trilightProbe({ sky, equator, ground }: StagePreset['ambient']) {
  const top = new THREE.Color().setRGB(...sky, THREE.SRGBColorSpace)
  const side = new THREE.Color().setRGB(...equator, THREE.SRGBColorSpace)
  const bottom = new THREE.Color().setRGB(...ground, THREE.SRGBColorSpace)

  // 球の上にまんべんなく並べた向きで、その向きから来る光の色を足し合わせる
  const sh = new THREE.SphericalHarmonics3()
  const basis = Array.from({ length: 9 }, () => 0)
  const direction = new THREE.Vector3()
  const color = new THREE.Color()
  const samples = 2048
  for (let i = 0; i < samples; i++) {
    const y = 1 - (2 * (i + 0.5)) / samples
    const r = Math.sqrt(1 - y * y)
    const phi = i * Math.PI * (3 - Math.sqrt(5))
    direction.set(Math.cos(phi) * r, y, Math.sin(phi) * r)
    if (y >= 0) color.copy(side).lerp(top, y)
    else color.copy(side).lerp(bottom, -y)
    THREE.SphericalHarmonics3.getBasisAt(direction, basis)
    for (let j = 0; j < 9; j++) {
      sh.coefficients[j].x += color.r * basis[j]
      sh.coefficients[j].y += color.g * basis[j]
      sh.coefficients[j].z += color.b * basis[j]
    }
  }
  for (const c of sh.coefficients) c.multiplyScalar((4 * Math.PI) / samples)
  return new THREE.LightProbe(sh, 1)
}

function Ambient({ preset }: { preset: StagePreset }) {
  const probe = useMemo(() => trilightProbe(preset.ambient), [preset.ambient])
  useEffect(() => () => probe.dispose(), [probe])
  return <primitive object={probe} />
}

// ---------- スポットライト ----------

/** Unity のスポットライトの距離による弱まり方（Built-in の 1 / (1 + 25 (d / range)²)） */
const unityAttenuation = (distance: number, range: number) => 1 / (1 + 25 * (distance / range) ** 2)
/** three.js の物理的な弱まり方（距離の 2 乗に反比例し、range で 0 になる） */
const threeAttenuation = (distance: number, range: number) =>
  (1 / distance ** 2) * Math.max(0, 1 - (distance / range) ** 4) ** 2
/** 弱まり方の形は少し違うので、照明器具から床までくらいの距離（3.5m。家の天井は 3.15m）で明るさをそろえる */
const MATCH_DISTANCE = 3.5

function GallerySpot({ spec }: { spec: SpotLightSpec }) {
  const light = useMemo(() => {
    const [x, y, z] = spec.position
    const scale = unityAttenuation(MATCH_DISTANCE, spec.range) / threeAttenuation(MATCH_DISTANCE, spec.range)
    const l = new THREE.SpotLight(
      unityLightColor(spec.color, spec.power),
      UNITY_DIRECT_LIGHT_SCALE * scale,
      spec.range,
      (spec.angleDeg / 2) * DEG,
      0.5,
      2,
    )
    l.position.set(x, y, z)
    // Unity と同じく真下に向ける。ターゲットはシーンに入れないので、ここで位置を確定させる
    l.target.position.set(x, y - 1, z)
    l.target.updateMatrixWorld()
    return l
  }, [spec])
  useEffect(() => () => light.dispose(), [light])
  return <primitive object={light} />
}

// ---------- まとめ ----------

/**
 * Unity 版と同じ構成の照明一式。bounds はステージの範囲（太陽の影の範囲を決める。読み込むまでは null で、その間は initialBounds）。
 * spotLights は点けるスポットライト（既定は stagePreset の spotLights。鑑賞モードは部屋ごとのダウンライト）
 */
export function MuseumDaylight({
  preset,
  bounds,
  initialBounds = DEFAULT_INITIAL_BOUNDS,
  spotLights = preset.spotLights,
  shadowMapSize = SHADOW_MAP_SIZE,
}: {
  preset: StagePreset
  bounds: THREE.Box3 | null
  /** 読み込むまでの影の範囲（家の外形。WalkScene が house.rooms から作る） */
  initialBounds?: THREE.Box3
  spotLights?: SpotLightSpec[]
  /** 太陽の影の細かさ（px）。スマホなどの軽い表示では小さくする */
  shadowMapSize?: number
}) {
  const sunPosition = useMemo(() => sunDirection(preset.sun.eulerDeg).multiplyScalar(-100).toArray(), [preset.sun])
  return (
    <>
      <Sky sunPosition={sunPosition} turbidity={6} rayleigh={1.2} mieCoefficient={0.004} mieDirectionalG={0.8} />
      <Sun preset={preset} bounds={bounds} initialBounds={initialBounds} shadowMapSize={shadowMapSize} />
      <Ambient preset={preset} />
      {spotLights.map((spec, i) => (
        <GallerySpot key={i} spec={spec} />
      ))}
    </>
  )
}

// ---------- 影と映り込みの更新 ----------

/**
 * 影は動かない建物・家具・作品の分だけなので、毎フレームではなく version が変わったときだけ描き直す
 * （Canvas の shadows で autoUpdate を false にしておく）。
 */
export function StaticShadows({ version }: { version: number }) {
  const gl = useThree((s) => s.gl)
  const invalidate = useThree((s) => s.invalidate)
  useEffect(() => {
    gl.shadowMap.needsUpdate = true
    invalidate()
  }, [gl, invalidate, version])
  return null
}

/** 映り込みを撮るときの、立方体の 1 面の細かさ（px） */
const REFLECTION_SIZE = 128

/**
 * 部屋の中を position から 1 度だけ撮って、映り込み（scene.environment）にする。
 * version が変わったら撮り直す（ステージや家具を読み込んだあとなど）。0 の間は撮らない。
 * size は立方体の 1 面の細かさ（スマホなどの軽い表示では半分にする）
 */
export function ReflectionCapture({
  position,
  intensity,
  version,
  size = REFLECTION_SIZE,
}: {
  position: Vec3
  intensity: number
  version: number
  size?: number
}) {
  const gl = useThree((s) => s.gl)
  const scene = useThree((s) => s.scene)
  const invalidate = useThree((s) => s.invalidate)

  useEffect(() => {
    if (version === 0) return
    let environment: THREE.Texture | null = null
    // 照明や影が反映されたあとに撮るため、1 フレーム待つ
    const frame = requestAnimationFrame(() => {
      const target = new THREE.WebGLCubeRenderTarget(size, { type: THREE.HalfFloatType })
      const camera = new THREE.CubeCamera(0.2, 100, target)
      camera.position.set(...position)
      camera.updateMatrixWorld()
      scene.environment = null
      camera.update(gl, scene)
      const pmrem = new THREE.PMREMGenerator(gl)
      environment = pmrem.fromCubemap(target.texture).texture
      pmrem.dispose()
      target.dispose()
      scene.environment = environment
      scene.environmentIntensity = intensity
      invalidate()
    })
    return () => {
      cancelAnimationFrame(frame)
      if (environment && scene.environment === environment) scene.environment = null
      environment?.dispose()
    }
  }, [gl, scene, invalidate, position, intensity, version, size])

  return null
}
