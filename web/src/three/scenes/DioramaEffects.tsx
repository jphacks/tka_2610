// ホームの積み上げの建物（StackScene）を、机の上の模型（ドールハウス）のように見せる仕上げ。
//   光 … 南西の斜め上から差す暖かい光（DioramaLight）。家具・壁・上の階の床が、部屋の床に影を落とす。
//         建物の下には、机に置いた模型のようなうっすらした接地の影（drei の ContactShadows）。
//   仕上げ（DioramaPost。描画は R3F に任せず、ここで composer.render() する。useFrame の優先度 1）
//     1. 描く（MSAA）
//     2. 隅の陰（GTAO）：壁と床の境目・家具の足もとをうっすら暗くする。スマホなど（lite）では重いので省く
//     3. ティルトシフト：画面の上下だけをぼかし、精巧な模型を覗き込んでいるように見せる（真ん中の帯はぼかさない）
//     4. 周辺減光：四隅をほんのり暗くする
//     5. 色の仕上げ（OutputPass）：トーンマッピングと sRGB への変換（Canvas の設定を使う）
// 影は、Stage の shadows で Canvas の影を有効にしたときだけ出る。建物（HouseShells）は影を受けない作りなので、
// 読み込んだら（version が変わったら）場面の全部のメッシュに影を落とし・受けさせる（useShadowEverything）。
// three.js に付属のものだけを使う（鑑賞モードの walk/PostEffects.tsx と同じ作り）。

import { useEffect, useMemo } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import { ContactShadows } from '@react-three/drei'
import * as THREE from 'three'
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js'
import { GTAOPass } from 'three/addons/postprocessing/GTAOPass.js'
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js'
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js'
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js'
import { VignetteShader } from 'three/addons/shaders/VignetteShader.js'
import type { Vec3 } from '../../api'

/** 光の色と強さ。夕方の窓から差すような、少し橙がかった光 */
const KEY_COLOR = '#ffd9a8'
/** まわりの光（Stage の HomeLights の dim）を弱めた分、こちらを強くする。影の所がはっきり暗くなる */
const KEY_INTENSITY = 2.4
/** 建物の中心から見た、光の来る向き（南西の斜め上） */
const KEY_DIRECTION = new THREE.Vector3(-0.55, 1, 0.45).normalize()

/**
 * 建物を照らして影を落とす光と、建物の下の接地の影。
 * center は建物の真ん中、radius は建物を包む球の半径、floorY は建物のいちばん下（土台の下）
 */
export function DioramaLight({ center, radius, floorY, lite }: { center: Vec3; radius: number; floorY: number; lite: boolean }) {
  const target = useMemo(() => new THREE.Object3D(), [])
  const position = useMemo(() => new THREE.Vector3(...center).addScaledVector(KEY_DIRECTION, radius * 2), [center, radius])
  useEffect(() => {
    target.position.set(...center)
    target.updateMatrixWorld()
  }, [target, center])

  return (
    <>
      <primitive object={target} />
      <directionalLight
        position={position}
        target={target}
        color={KEY_COLOR}
        intensity={KEY_INTENSITY}
        castShadow
        shadow-mapSize={lite ? [1024, 1024] : [2048, 2048]}
        shadow-bias={-0.0004}
        shadow-normalBias={0.03}
        shadow-camera-left={-radius}
        shadow-camera-right={radius}
        shadow-camera-top={radius}
        shadow-camera-bottom={-radius}
        shadow-camera-near={0.5}
        shadow-camera-far={radius * 4}
        // 影のカメラの範囲を変えたら、投影を作り直す
        onUpdate={(light: THREE.DirectionalLight) => light.shadow.camera.updateProjectionMatrix()}
      />
      {/* 建物の下の、机に置いた模型のような影。建物の幅より少し広く */}
      <ContactShadows
        position={[center[0], floorY - 0.01, center[2]]}
        scale={radius * 1.9}
        far={3}
        blur={2.6}
        opacity={0.42}
        color="#5a4632"
        resolution={lite ? 256 : 512}
      />
    </>
  )
}

/** 場面の全部のメッシュに影を落とし・受けさせる（version が変わるたびに。建物や家具が読み込まれたとき） */
export function useShadowEverything(version: unknown) {
  const scene = useThree((s) => s.scene)
  const invalidate = useThree((s) => s.invalidate)
  useEffect(() => {
    scene.traverse((o) => {
      const mesh = o as THREE.Mesh
      if (!mesh.isMesh) return
      // 半透明（ガラスなど）は影を落とさない
      const materials = Array.isArray(mesh.material) ? mesh.material : [mesh.material]
      mesh.castShadow = !materials.some((m) => m?.transparent)
      mesh.receiveShadow = true
    })
    invalidate()
  }, [scene, version, invalidate])
}

/**
 * ティルトシフト（片方向のぼかし）。真ん中の帯（focus ± band）はぼかさず、そこから離れるほど強くぼかす。
 * 縦と横に 1 回ずつかける（delta が 1 画素の向きと大きさ）
 */
const TiltShiftShader = {
  name: 'DioramaTiltShift',
  uniforms: {
    tDiffuse: { value: null as THREE.Texture | null },
    delta: { value: new THREE.Vector2() },
    focus: { value: 0.5 },
    band: { value: 0.2 },
    amount: { value: 2.2 },
  },
  vertexShader: /* glsl */ `
    varying vec2 vUv;
    void main() {
      vUv = uv;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse;
    uniform vec2 delta;
    uniform float focus;
    uniform float band;
    uniform float amount;
    varying vec2 vUv;
    void main() {
      float t = smoothstep(band, band + 0.32, abs(vUv.y - focus)) * amount;
      vec4 sum = vec4(0.0);
      float weight = 0.0;
      for (int i = -4; i <= 4; i++) {
        float k = exp(-float(i * i) / 8.0);
        sum += texture2D(tDiffuse, vUv + delta * float(i) * t) * k;
        weight += k;
      }
      gl_FragColor = sum / weight;
    }
  `,
}

/** 仕上げ。lite（タッチの端末）では隅の陰を省く */
export function DioramaPost({ lite }: { lite: boolean }) {
  const gl = useThree((s) => s.gl)
  const scene = useThree((s) => s.scene)
  const camera = useThree((s) => s.camera)
  const size = useThree((s) => s.size)
  const dpr = useThree((s) => s.viewport.dpr)

  const { composer, ao, tiltX, tiltY } = useMemo(() => {
    // 明るいところを残したまま仕上げるため、半精度の浮動小数点で描く
    const target = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples: 4 })
    const composer = new EffectComposer(gl, target)
    composer.addPass(new RenderPass(scene, camera))
    let ao: GTAOPass | null = null
    if (!lite) {
      ao = new GTAOPass(scene, camera, 1, 1)
      ao.updateGtaoMaterial({ radius: 0.6, distanceExponent: 1, thickness: 1, scale: 1, samples: 16 })
      ao.updatePdMaterial({ lumaPhi: 10, depthPhi: 2, normalPhi: 3, radius: 6, rings: 2, samples: 16 })
      ao.blendIntensity = 0.75
      composer.addPass(ao)
    }
    const tiltX = new ShaderPass(TiltShiftShader)
    const tiltY = new ShaderPass(TiltShiftShader)
    composer.addPass(tiltX)
    composer.addPass(tiltY)
    const vignette = new ShaderPass(VignetteShader)
    vignette.uniforms.offset.value = 1.05
    vignette.uniforms.darkness.value = 0.55
    composer.addPass(vignette)
    composer.addPass(new OutputPass())
    return { composer, ao, tiltX, tiltY }
  }, [gl, scene, camera, lite])

  useEffect(() => {
    composer.setPixelRatio(dpr)
    composer.setSize(size.width, size.height)
    const w = size.width * dpr
    const h = size.height * dpr
    tiltX.uniforms.delta.value.set(1 / w, 0)
    tiltY.uniforms.delta.value.set(0, 1 / h)
  }, [composer, tiltX, tiltY, size.width, size.height, dpr])

  // composer.dispose() は自分の描画用バッファしか片付けないので、隅の陰も片付ける
  useEffect(
    () => () => {
      ao?.dispose()
      composer.dispose()
    },
    [composer, ao],
  )

  // 優先度 1 の useFrame があると、R3F は自分では描かない（frameloop demand でも、描くときだけ呼ばれる）
  useFrame(() => composer.render(), 1)
  return null
}
