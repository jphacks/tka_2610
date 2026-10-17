// GLB を読み込んで置く部品。家の建物 1 部屋分（MuseumModel）と、作品を置き場所に収める部品（FittedModel）、先読み（preloadModel）。
// GLB は 1 度だけダウンロード・解析し、各画面では clone して使い回す。
// 家具と作品を配置 JSON のとおりに並べるのは home/HomeObjects.tsx。

import { useEffect, useLayoutEffect, useMemo } from 'react'
import { useThree } from '@react-three/fiber'
import { useGLTF } from '@react-three/drei'
import * as THREE from 'three'
import type { Side } from '../../api'
import { applyCutaway } from './home/cutaway'
import { applyTheme, preloadTheme, type FaceRoomFinishes, type HomeFinish, type HomeMaterials } from './home/theme'

/** GLB を先にダウンロード・解析しておく（three/index.tsx の warmUp3D から呼ぶ） */
export function preloadModel(url: string) {
  useGLTF.preload(url, false, false)
}

const NO_HIDE: string[] = []
const NO_SIDES: readonly Side[] = []

/**
 * 家の建物（壁と床）。部屋 1 つ分の GLB（部屋の中心が原点）を 1 つ置く。部屋ごとに並べるのは home/HouseShells.tsx。
 * 壁のカットは、ふだんは HouseShells がカメラに合わせて当てる（home/cutaway.ts）ので、ここでは cutaway = false で何もしない。
 * cutaway = true にすると、cutSides の向きの壁の上の部分を固定で隠す（今はどの画面も使っていない）。
 * theme で壁紙と床材を変える（home/theme.ts。materials は catalog.materials）。隣の部屋に向いた壁の面は faceThemes のその部屋のもの。
 * hide に渡した接頭辞で始まる名前のノードも隠せる（博物館のころの仕組み。家では使っていない）。
 * hide の処理は、名前のあるノードの visible を全部決め直す（壁のカットも見える状態に戻る）。その後に onLoaded を呼ぶので、
 * カットを当てる HouseShells は onLoaded のたびに当て直す。
 * 複製した建物は行列を固定する（matrixAutoUpdate = false）ので、部屋の位置へは親のグループで動かす（この部品の中では動かさない）。
 */
export function MuseumModel({
  url,
  hide = NO_HIDE,
  cutaway = false,
  cutSides = NO_SIDES,
  theme,
  faceThemes,
  materials,
  onReady,
  onLoaded,
}: {
  url: string
  hide?: string[]
  /** true のとき、cutSides の向きの壁を固定でカットする。false（ふだん）は壁のカットに触らない（HouseShells がカメラに合わせて当てる） */
  cutaway?: boolean
  /** cutaway のとき、カットする壁の向き */
  cutSides?: readonly Side[]
  /** 壁紙と床材（配置 JSON の rooms[部屋]）。無ければ GLB のまま */
  theme?: HomeFinish
  /**
   * 部屋の id → 壁紙と床材（配置 JSON の rooms）。共有する壁の、隣の部屋に向いた面（GLB の userData.faceRoom）に当てる。
   * 無ければその面も theme のまま
   */
  faceThemes?: FaceRoomFinishes
  /** テーマのテクスチャ（catalog.materials）。theme と一緒に渡す */
  materials?: HomeMaterials
  onReady?: () => void
  /**
   * 読み込んだ建物（この画面用に複製したもの）を受け取る。隠すノードやテーマが変わったとき、
   * テーマの画像を待ってから材質を差し替えたときにも呼ばれる。
   * 当たり判定や影の設定など、画面ごとに建物へ手を加えるときに使う（一人称で歩く画面。HouseShells の壁のカット）
   */
  onLoaded?: (root: THREE.Object3D) => void
}) {
  // GLB を待つ間に、テーマの画像も読み込み始める（GLB が届いたときに、すぐ差し替えられるように）
  if (theme && materials) preloadTheme(theme, materials)
  if (faceThemes && materials) for (const face of Object.values(faceThemes)) if (face) preloadTheme(face, materials)
  const gltf = useGLTF(url, false, false)
  const gl = useThree((s) => s.gl)
  const invalidate = useThree((s) => s.invalidate)

  const scene = useMemo(() => {
    const clone = gltf.scene.clone(true)
    // 建物は動かないので、毎フレームの行列計算を省く
    clone.traverse((o) => {
      o.updateMatrix()
      o.matrixAutoUpdate = false
    })
    clone.updateMatrixWorld(true)
    return clone
  }, [gltf.scene])

  const hideKey = hide.join('|')
  const cutKey = cutSides.join('|')
  const wall = theme?.wall
  const floor = theme?.floor
  // 隣の部屋の壁紙・床材は中身の値で比べる（模様替えの下書きは家具を動かすたびに新しい物になるので、参照では比べない）
  const faceKey = faceThemes
    ? Object.entries(faceThemes)
        .map(([id, f]) => (f ? `${id}:${f.wall}:${f.floor}` : id))
        .join('|')
    : ''
  useLayoutEffect(() => {
    scene.traverse((o) => {
      if (o === scene || !o.name) return
      o.visible = !hide.some((prefix) => o.name.startsWith(prefix))
    })
    // 固定のカットは cutaway のときだけ当てる。false のときは、上の hide の処理で見える状態に戻った壁を、
    // 下の onLoaded を受けた HouseShells がカメラに合わせて当て直す（applyTheme は材質を替えるだけで、visible は触らない）
    if (cutaway) applyCutaway(scene, cutSides)
    let alive = true
    if (wall && floor && materials) {
      applyTheme(scene, { wall, floor }, materials, {
        anisotropy: gl.capabilities.getMaxAnisotropy(),
        faceRooms: faceThemes,
        // 画像を待ってから差し替えた：描き直し（マップは変化があるときだけ描く）、歩く画面には材質が変わったことを知らせる
        onLate: () => {
          if (!alive) return
          invalidate()
          onLoaded?.(scene)
        },
      })
    }
    onLoaded?.(scene)
    return () => {
      alive = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scene, hideKey, cutKey, cutaway, wall, floor, faceKey, materials])

  useEffect(() => {
    onReady?.()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return <primitive object={scene} />
}

/**
 * 作品のモデルを置き場所に収める。底面の中心を原点に置く。
 * scale を渡したときはその倍率で置く（家の中の作品。実寸と置き場所の枠から決めた値。placement.ts の displayScale、Rust の display_scale）。
 * 渡さないときは範囲 fit（幅・高さ・奥行き, m）に収める：回しても範囲からはみ出さないよう、水平方向は対角線の長さで合わせる
 * （3D プレビューと、実寸が分からない作品）。
 * noUpscale のときは縮めるだけで拡大しない（実寸で作った工作の GLB を、本物より大きく見せないため。scale を渡したときは使わない）。
 * shadows のときは影を落とし・受ける（家の中に置くとき）。
 */
export function FittedModel({
  url,
  fit,
  scale: fixedScale,
  noUpscale = false,
  shadows = false,
  onMount,
}: {
  url: string
  fit: [number, number, number]
  /** 拡縮率。渡すと fit と noUpscale は使わない */
  scale?: number
  noUpscale?: boolean
  shadows?: boolean
  /** 読み込んで置いたとき・外したときに呼ぶ（HomeObjects が、歩く画面の影の描き直しに使う） */
  onMount?: () => void
}) {
  const { scene } = useGLTF(url, false, false)
  const [fx, fy, fz] = fit

  const object = useMemo(() => {
    const clone = scene.clone(true)
    clone.traverse((o) => {
      const mesh = o as THREE.Mesh
      if (mesh.isMesh) {
        mesh.castShadow = shadows
        mesh.receiveShadow = shadows
      }
    })
    const box = new THREE.Box3().setFromObject(clone)
    const size = box.getSize(new THREE.Vector3())
    const center = box.getCenter(new THREE.Vector3())
    clone.position.set(-center.x, -box.min.y, -center.z)
    const group = new THREE.Group()
    group.add(clone)
    if (fixedScale !== undefined && Number.isFinite(fixedScale) && fixedScale > 0) {
      group.scale.setScalar(fixedScale)
    } else {
      const diameter = Math.max(0.001, Math.hypot(size.x, size.z))
      const scale = Math.min(fx / diameter, fz / diameter, fy / Math.max(0.001, size.y)) * 0.9
      group.scale.setScalar(noUpscale ? Math.min(1, scale) : scale)
    }
    return group
  }, [scene, fx, fy, fz, fixedScale, noUpscale, shadows])

  useLayoutEffect(() => {
    if (!onMount) return
    onMount()
    return onMount
  }, [object, onMount])

  return <primitive object={object} />
}
