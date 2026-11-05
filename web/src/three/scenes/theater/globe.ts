// シアターの大地（大きな球）の上に、物を立てる計算と、場面ごとの家や木の並び。
// 球の中心は (0, -RADIUS, 0)。球は X 軸のまわりに回り、角度 φ の場所は、大地の回転が φ のとき頂上（手前）に来る。
// φ が大きいほど奥（カメラから遠い側）にある。x は横（左右）のずれ。
import * as THREE from 'three'
import { SLOTS, SLOT_ANGLE } from './timeline'
import { seeded, type PropKind, type StageProp } from './stageProps'

export const RADIUS = 24

const X_AXIS = new THREE.Vector3(1, 0, 0)
const Z_AXIS = new THREE.Vector3(0, 0, 1)

/** 球の角度 phi・横 x・地面からの高さ offset に、地面に垂直に立てる位置と向き（球のローカル座標） */
export function placeOnGlobe(target: THREE.Object3D, phi: number, x: number, offset = 0) {
  const clampedX = THREE.MathUtils.clamp(x, -RADIUS * 0.9, RADIUS * 0.9)
  const radial = Math.sqrt(Math.max(1, RADIUS * RADIUS - clampedX * clampedX))
  const normal = new THREE.Vector3(clampedX, radial * Math.cos(phi), -radial * Math.sin(phi)).normalize()
  target.position.copy(normal).multiplyScalar(RADIUS + offset)
  target.quaternion
    .setFromAxisAngle(X_AXIS, -phi)
    .multiply(new THREE.Quaternion().setFromAxisAngle(Z_AXIS, -Math.asin(clampedX / RADIUS)))
}

/** phi の場所が、いまの回転 angle で頂上からどれだけ離れているか（-π〜π。正なら奥） */
export function relativeAngle(phi: number, angle: number) {
  const d = phi - angle
  return Math.atan2(Math.sin(d), Math.cos(d))
}

/** カメラから見える範囲（頂上の少し手前から、地平線の向こうの少し先まで） */
export const VISIBLE_FROM = -0.95
export const VISIBLE_TO = 1.15

export interface DecorPlacement {
  prop: string
  phi: number
  x: number
  /** 板の向き（Y 軸まわり）。少しだけ斜めにすると手作りらしい */
  yaw: number
  scale: number
}

/**
 * 14 の場面それぞれのまわりに、家・木・低木を並べる（シードで毎回同じ）。
 * 場面 k の物は、k の角度から ±SLOT_ANGLE/2 の中にだけ置く（それより先は、となりの場面の手前になってしまう）。
 *   奥の左右    … 家と木（作品の後ろに町が見える）。横 3.4 m より外
 *   手前の左右  … 低木と木（大地が回るときに手前を通り過ぎる）。横 4.5 m より外
 *   あいだの真ん中 … 低い低木だけ（次の場面では作品の手前になるので、作品を隠さない高さ）
 * 遠くの丘は大地に乗せず、TheaterScene が奥に動かない背景として置く。
 */
export function decorLayout(props: StageProp[]): DecorPlacement[] {
  const byKind = (kind: PropKind) => props.filter((p) => p.kind === kind).map((p) => p.name)
  const houses = byKind('house')
  const trees = byKind('tree')
  const shrubs = byKind('shrub')
  const out: DecorPlacement[] = []
  const pick = (list: string[], r: () => number) => list[Math.floor(r() * list.length) % Math.max(1, list.length)]
  const widthOf = (name: string) => props.find((p) => p.name === name)?.width ?? 1.5
  for (let slot = 0; slot < SLOTS; slot++) {
    const r = seeded(9001 + slot * 7919)
    const base = slot * SLOT_ANGLE
    for (const side of [-1, 1]) {
      // 奥の左右に、家と木
      let x = 3.4 + r() * 0.6
      const count = 3 + Math.floor(r() * 2)
      for (let k = 0; k < count && x < 11; k++) {
        const isHouse = houses.length > 0 && (k === 0 || r() < 0.45)
        const name = isHouse ? pick(houses, r) : pick(trees, r)
        const scale = 0.9 + r() * 0.2
        const half = (widthOf(name) * scale) / 2
        x += half
        out.push({ prop: name, phi: base + 0.07 + r() * 0.12, x: side * x, yaw: side * (-0.1 - r() * 0.2), scale })
        x += half + 0.1 + r() * 0.6
      }
      // 手前の左右に、低木や小さな木
      let fx = 4.6 + r() * 0.8
      for (let k = 0; k < 2; k++) {
        const name = r() < 0.6 && shrubs.length ? pick(shrubs, r) : pick(trees, r)
        const scale = 0.8 + r() * 0.25
        out.push({ prop: name, phi: base - 0.1 - r() * 0.09, x: side * (fx + (widthOf(name) * scale) / 2), yaw: side * (r() * 0.2), scale })
        fx += widthOf(name) * scale + 0.6 + r() * 1.5
      }
    }
    // あいだの真ん中は低木だけ
    if (shrubs.length) out.push({ prop: pick(shrubs, r), phi: base + SLOT_ANGLE / 2 + (r() - 0.5) * 0.03, x: (r() - 0.5) * 2, yaw: (r() - 0.5) * 0.3, scale: 0.8 })
  }
  return out
}

/** 奥の、動かない丘（大地の地平線の向こうに頭だけ見える） */
export function backdropLayout(props: StageProp[]): DecorPlacement[] {
  const hills = props.filter((p) => p.kind === 'hill').map((p) => p.name)
  if (!hills.length) return []
  const r = seeded(777)
  const out: DecorPlacement[] = []
  for (let i = 0; i < 9; i++) {
    const x = -26 + i * 6.5 + (r() - 0.5) * 3
    out.push({ prop: hills[i % hills.length], phi: 0, x, yaw: (r() - 0.5) * 0.2, scale: 2.2 + r() * 0.9 })
  }
  return out
}

export interface FlowerPlacement {
  phi: number
  x: number
  color: string
  height: number
}

/** 地面の小さな花（作品の前と写真立ての場所は避ける） */
export function flowerLayout(): FlowerPlacement[] {
  const r = seeded(4242)
  const colors = ['#F59FB0', '#FFFDF8', '#F6DC9A', '#E8726B', '#B9D8F0']
  const out: FlowerPlacement[] = []
  for (let i = 0; i < SLOTS * 46; i++) {
    const phi = r() * Math.PI * 2
    const x = (r() - 0.5) * 18
    const nearest = Math.round(phi / SLOT_ANGLE) * SLOT_ANGLE
    // 作品のまわり（横 ±4 m・前後 ±2.4 m）は空ける
    if (Math.abs(x) < 4 && Math.abs(phi - nearest) * RADIUS < 2.4) continue
    out.push({ phi, x, color: colors[Math.floor(r() * colors.length)], height: 0.08 + r() * 0.1 })
  }
  return out
}
