// 壁のカット（ドールハウスの見せ方）。カメラと部屋の中の間にある壁（手前の 2 面）の上の部分を隠して、斜め上から部屋の中が見えるようにする。
// 家のキットのビューアの「壁のカット」と同じ見え方を、どの向きから見ても出す（カメラが回ると、カットする壁も入れ替わる）。
//
// 家の GLB には、次の印が入っている（glTF の extras が three.js の userData になる）：
//   壁のノード     … userData.side（north / south / east / west）
//   その子のメッシュ … userData.role（wall_lower / wall_upper / trim_lower / trim_upper など）
//   角の柱のノード … userData.side = 'corner'
//   開いた側の印   … 6 × 6 の部屋のリビング側。userData.side（開いた向き）と open。形が無いので、隠す物は無い
// 壁のノードには userData.cutaway（南・東の壁は true）もあるが、南東からしか見なかったころの印で、今は使わない。
// どの向きの壁をカットするかは、呼ぶ側が sides で決める。
// 壁は下から 0.92 m までが wall_lower なので、カットしても腰の高さの壁と幅木は残る。
// 角の柱は、両側の壁がカットされる角のものだけを丸ごと隠す（キットと同じ。手前に柱が 1 本だけ立つのを防ぐ）。
// 当たり判定には関係しない（一人称で歩く画面ではカットしない）。
//
// 家の画面では HouseShells が毎フレーム、カメラの位置から部屋ごとに手前の 2 面を選び（facingSides）、
// 家全体を見下ろす画面ではさらに出入口のある壁（部屋どうしの間の壁）を足して、変わったときだけ applyCutaway を呼ぶ。
// カメラが部屋の中（壁の高さより下）にいるときは、位置ではなく見ている向きの逆（カメラの背中側の 2 面）を facingSides に渡す。
// 家は部屋ごとに GLB があり（house.rooms[].model_url）、どれも部屋の中心が原点。MuseumModel は部屋の中心へ
// 親のグループで動かすので、角の柱の位置（node.position）は部屋の中心から見た値のまま。角の判定は部屋ごとに正しく効く。

import type * as THREE from 'three'
import type { Side } from '../../../api'

/** カットする部分（壁の上の部分と、その上下の飾り） */
const CUT_ROLES = new Set(['wall_upper', 'trim_upper'])
/** 壁のノード（と開いた側の印）の userData.side。'corner' は角の柱 */
const WALL_SIDES: ReadonlySet<string> = new Set<Side>(['north', 'south', 'east', 'west'])
/**
 * 手前の 2 面を入れ替えるときのゆらぎ止め（m）。カメラが部屋の中心の真南などにいる（東西の差がほとんど無い）とき、
 * 少し動くたびに東と西のカットが入れ替わってちらつかないよう、反対側へこれだけ出るまでは前の向きのままにする
 */
const FACING_HYSTERESIS = 0.4

/** カメラの側にある 2 面（東か西と、南か北） */
export interface Facing {
  ew: 'east' | 'west'
  ns: 'north' | 'south'
}

/**
 * 正の向き（東・南）を選ぶか。前が無ければ offset > 0 で決める。
 * 前が正なら offset が −ゆらぎ止め を下回るまで正のまま、前が負なら +ゆらぎ止め を超えるまで負のまま
 */
function positive(offset: number, prevPositive: boolean | undefined, hysteresis: number) {
  if (prevPositive === undefined) return offset > 0
  return prevPositive ? offset >= -hysteresis : offset > hysteresis
}

/**
 * 部屋の中心から見たカメラの位置（dx = 東向き、dz = 南向き、m）から、カメラと部屋の中の間にある 2 面の壁を選ぶ。
 * dx > 0 なら東、dz > 0 なら南。prev（前のフレームの結果）を渡すと、軸の近くでちらつかないようゆらぎ止めをかける。
 * hysteresis はゆらぎ止めの幅で、dx・dz と同じ単位（位置なら m。カメラが部屋の中にいるとき、HouseShells は
 * 見ている向きの逆（長さ 1 の向き）を渡すので、そのときは向きの成分で 0.1 などを渡す）
 */
export function facingSides(dx: number, dz: number, prev?: Facing, hysteresis = FACING_HYSTERESIS): Facing {
  const east = positive(dx, prev ? prev.ew === 'east' : undefined, hysteresis)
  const south = positive(dz, prev ? prev.ns === 'south' : undefined, hysteresis)
  return { ew: east ? 'east' : 'west', ns: south ? 'south' : 'north' }
}

/** 角の柱が、カットする 2 つの壁の間の角にあるか（東 = +x、南 = +z） */
function isCutCorner(node: THREE.Object3D, cutSides: ReadonlySet<string>) {
  const ew = node.position.x > 0 ? 'east' : 'west'
  const ns = node.position.z > 0 ? 'south' : 'north'
  return cutSides.has(ew) && cutSides.has(ns)
}

/**
 * 家の建物（MuseumModel の中身。部屋 1 つ分）の壁のうち、sides の向きのものの上の部分を隠し、それ以外は元に戻す。
 * 全部の壁の上の部分と全部の角の柱を、いったん見える状態に戻してから隠すのと同じ（前に隠した向きは残らない）。
 * null や空の sides は、全部元に戻す。GLB の userData.cutaway は見ない
 */
export function applyCutaway(root: THREE.Object3D, sides: ReadonlySet<Side> | readonly Side[] | null) {
  const cut = new Set<string>(sides ?? [])
  const corners: THREE.Object3D[] = []

  root.traverse((node) => {
    const side = node.userData.side
    if (side === 'corner') {
      corners.push(node)
      return
    }
    if (typeof side !== 'string' || !WALL_SIDES.has(side)) return
    const hide = cut.has(side)
    node.traverse((child) => {
      if (child !== node && CUT_ROLES.has(child.userData.role)) child.visible = !hide
    })
  })

  for (const corner of corners) corner.visible = !isCutCorner(corner, cut)
}
