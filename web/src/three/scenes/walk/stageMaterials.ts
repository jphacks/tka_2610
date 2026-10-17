// 鑑賞モード（一人称で歩く画面）のために、ステージ（家の建物と家具）の材質と影を整える。
//
// 材質はこの画面用に複製してから変える。GLB の材質はほかの 3D 画面（ホーム・おうちの中・マップ）と
// 共有しているので、そのまま変えるとそちらの見た目まで変わってしまうため。
// 家具は後から 1 つずつ読み込まれるので、まだ整えていないメッシュだけを、読み込まれるたびに整える（apply）。
// 壁紙と床材（テーマ）を変えると、建物の壁と床の材質が home/theme.ts で差し替わる。そのメッシュは
// こちらで当てた複製ではなくなるので、もう一度整える（材質が自分で当てた複製のままのメッシュだけを飛ばす）。
// 作品（HomeObjects の ARTWORK_）は、ほかの画面と同じ見た目のままにする（触らない）。
//
//   1. 色：legacyUnityColors のときだけ、材質の色（baseColorFactor）を sRGB として読み直す。
//      博物館の GLB には Unity で指定した sRGB の色がそのまま入っていて、glTF ではリニアとして扱うため白っぽく見えたので直していた。
//      家の GLB は glTF の決まりどおりなので、そのまま使う。
//   2. 発光：GLB に発光の強さが残っていない材質は、stagePreset.ts の emissive の値にする（家では使っていない）。
//   3. 映り込み：Unity では反射プローブは映り込み（鏡面反射）にだけ効き、拡散光は環境光（Trilight）だけ。
//      three.js では環境マップが拡散光にも効くので、ステージの材質では映り込みだけに効くようにする。
//   4. ガラス：半透明の板は、日や照明が当たると板が白く光るので、板自体は光らせず（拡散光なし）、映り込みだけを足す。
//   5. 影：半透明のもの以外は影を落とし、すべて影を受ける。

import * as THREE from 'three'
import type { StagePreset } from './stagePreset'

/** 名前がこれで始まるノード（とその子）は整えない（作品） */
const KEEP_AS_IS = ['ARTWORK_']

// シェーダーから外す行。three.js の版が変わって見つからないときは、そのまま使う
const IBL_DIFFUSE_LINE = 'iblIrradiance += getIBLIrradiance( geometryNormal );'
const SPECULAR_ONLY_ENV = THREE.ShaderChunk.lights_fragment_maps.replace(IBL_DIFFUSE_LINE, '')

/** 3（環境マップは映り込みだけ）のためにシェーダーを書き換える */
function patchShader(material: THREE.MeshStandardMaterial) {
  material.onBeforeCompile = (shader) => {
    shader.fragmentShader = shader.fragmentShader.replace('#include <lights_fragment_maps>', SPECULAR_ONLY_ENV)
  }
  material.customProgramCacheKey = () => 'walk'
}

/** 1〜4 を材質（この画面用の複製）に当てる */
function adjust(m: THREE.MeshStandardMaterial, preset: StagePreset) {
  const { r, g, b } = m.color

  // 1. 色（テクスチャのある材質は色が白なので、そのままでよい）
  if (preset.legacyUnityColors && !m.map) m.color.setRGB(r, g, b, THREE.SRGBColorSpace)

  // 2. 発光（sRGB の色 × 強さ をリニアに直す）
  const glow = preset.emissive.find((e) => e.material === m.name)
  if (glow) {
    m.emissive.setRGB(r * glow.strength, g * glow.strength, b * glow.strength, THREE.SRGBColorSpace)
    m.emissiveIntensity = 1
  }

  // 3. 間接光は映り込みだけにする
  patchShader(m)

  // 4. ガラス：色（拡散光）をなくし、映り込みは薄めずに足す（奥の景色は不透明度の分だけ暗くなる）
  if (m.transparent) {
    m.color.setRGB(0, 0, 0)
    m.blending = THREE.CustomBlending
    m.blendSrc = THREE.OneFactor
    m.blendDst = THREE.OneMinusSrcAlphaFactor
    m.depthWrite = false
  }
}

export interface WalkMaterials {
  /** root の中で、まだ整えていないメッシュ（材質が差し替わったものも）を整える。家具が載るたび・テーマが変わるたびに呼んでよい */
  apply(root: THREE.Object3D): void
  /** 複製した材質を片付ける */
  dispose(): void
}

/** ステージを歩く画面用に整える道具を作る。画面 1 つにつき 1 つ */
export function createWalkMaterials(preset: StagePreset): WalkMaterials {
  /** 元の材質 → この画面用の複製（同じ家具が 2 つあれば、複製も共有する） */
  const copies = new Map<THREE.Material, THREE.Material>()
  /** メッシュ → こちらで当てた材質（複製）。今の材質がこれと違えば（テーマで差し替わった・まだ整えていない）整える */
  const assigned = new WeakMap<THREE.Mesh, THREE.Material | THREE.Material[]>()

  const copy = (m: THREE.Material) => {
    let c = copies.get(m)
    if (!c) {
      c = m.clone()
      copies.set(m, c)
      if ((c as THREE.MeshStandardMaterial).isMeshStandardMaterial) adjust(c as THREE.MeshStandardMaterial, preset)
    }
    return c
  }

  const visit = (obj: THREE.Object3D) => {
    if (KEEP_AS_IS.some((prefix) => obj.name.startsWith(prefix))) return
    const mesh = obj as THREE.Mesh
    if (mesh.isMesh && assigned.get(mesh) !== mesh.material) {
      // 5. 半透明（ガラス）は影を落とさない。窓から日が差すようにするため
      const materials = Array.isArray(mesh.material) ? mesh.material : [mesh.material]
      mesh.castShadow = materials.every((m) => !m.transparent)
      mesh.receiveShadow = true
      mesh.material = Array.isArray(mesh.material) ? mesh.material.map(copy) : copy(mesh.material)
      assigned.set(mesh, mesh.material)
    }
    obj.children.forEach(visit)
  }

  return {
    apply: visit,
    dispose: () => {
      copies.forEach((m) => m.dispose())
      copies.clear()
    },
  }
}
