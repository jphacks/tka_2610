// 画面の仕上げ（ポストプロセス）。three.js に付属のものだけを使う。
//   1. 描く（MSAA でふちのギザギザを消す）
//   2. 隅の陰（GTAO）：壁と床の境目、展示台の足もと、ベンチの下などをうっすら暗くする
//   3. 光のにじみ（ブルーム）：電球や、日の当たった明るいところが少しにじむ
//   4. 色の仕上げ（OutputPass）：トーンマッピングと sRGB への変換（Canvas の設定を使う）
// 描画は R3F に任せず、ここで毎フレーム composer.render() する（useFrame の優先度 1）。

import { useEffect, useMemo } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js'
import { GTAOPass } from 'three/addons/postprocessing/GTAOPass.js'
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js'
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js'
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js'

/**
 * 隅の陰の計算から、半透明のもの（ガラス）を外した GTAO。
 * 外さないと、展示ケースの中の作品に陰がつかず、ガラスの枠に沿って暗い線が出る。
 */
class StageAOPass extends GTAOPass {
  private hidden: THREE.Object3D[] = []

  _overrideVisibility() {
    this.scene.traverse((object) => {
      const mesh = object as THREE.Mesh
      const materials = mesh.isMesh ? (Array.isArray(mesh.material) ? mesh.material : [mesh.material]) : []
      const skip =
        (object as THREE.Points).isPoints ||
        (object as THREE.Line).isLine ||
        materials.some((m) => m.transparent)
      if (skip && object.visible) {
        object.visible = false
        this.hidden.push(object)
      }
    })
  }

  _restoreVisibility() {
    for (const object of this.hidden) object.visible = true
    this.hidden.length = 0
  }
}

export interface PostEffectsSettings {
  /** 隅の陰の届く範囲（m）と濃さ（0〜1） */
  aoRadius: number
  aoIntensity: number
  /** 光のにじみの強さ・広がり・にじみ始める明るさ */
  bloomStrength: number
  bloomRadius: number
  bloomThreshold: number
}

export const DEFAULT_POST_EFFECTS: PostEffectsSettings = {
  aoRadius: 0.5,
  aoIntensity: 0.85,
  bloomStrength: 0.22,
  bloomRadius: 0.45,
  bloomThreshold: 1.1,
}

export function PostEffects({ settings = DEFAULT_POST_EFFECTS }: { settings?: PostEffectsSettings }) {
  const gl = useThree((s) => s.gl)
  const scene = useThree((s) => s.scene)
  const camera = useThree((s) => s.camera)
  const size = useThree((s) => s.size)
  const dpr = useThree((s) => s.viewport.dpr)

  const { composer, ao, bloom } = useMemo(() => {
    // 明るいところ（1 を超える値）を残したまま仕上げるため、半精度の浮動小数点で描く
    const target = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples: 4 })
    const composer = new EffectComposer(gl, target)
    composer.addPass(new RenderPass(scene, camera))
    const ao = new StageAOPass(scene, camera, 1, 1)
    composer.addPass(ao)
    const bloom = new UnrealBloomPass(new THREE.Vector2(1, 1), 0, 0, 0)
    composer.addPass(bloom)
    composer.addPass(new OutputPass())
    return { composer, ao, bloom }
  }, [gl, scene, camera])

  useEffect(() => {
    ao.updateGtaoMaterial({ radius: settings.aoRadius, distanceExponent: 1, thickness: 1, scale: 1, samples: 16 })
    ao.updatePdMaterial({ lumaPhi: 10, depthPhi: 2, normalPhi: 3, radius: 6, rings: 2, samples: 16 })
    ao.blendIntensity = settings.aoIntensity
    bloom.strength = settings.bloomStrength
    bloom.radius = settings.bloomRadius
    bloom.threshold = settings.bloomThreshold
  }, [ao, bloom, settings])

  useEffect(() => {
    composer.setPixelRatio(dpr)
    composer.setSize(size.width, size.height)
  }, [composer, size.width, size.height, dpr])

  // composer.dispose() は自分の描画用バッファしか片付けないので、隅の陰と光のにじみも片付ける
  useEffect(
    () => () => {
      ao.dispose()
      bloom.dispose()
      composer.dispose()
    },
    [composer, ao, bloom],
  )

  // 優先度 1 の useFrame があると、R3F は自分では描かない
  useFrame(() => composer.render(), 1)
  return null
}
