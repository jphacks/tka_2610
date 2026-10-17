// 一人称で歩く人の動き（歩く・向きを変える・重力・壁や床との当たり判定・段差）。
// React や描画には触らない処理だけを置く（ブラウザの外のテストでも動く）。
// 動き方は Unity 版の MuseumWalker.cs と CharacterController に合わせている：
//   - 移動は入力に合わせてすぐ速さが決まる（慣性なし）
//   - 床にいるときは下向きに -2 m/秒、空中では重力で加速し、落ちる速さには上限がある
//   - stepHeight より低い段差は上がれる、slopeLimit より急な面は壁として扱う
//   - 下に落ちすぎたら、はじめの位置に戻す

import * as THREE from 'three'
import { Capsule } from 'three/addons/math/Capsule.js'
import type { CollisionWorld } from './collision'
import type { PlayerSpec, Vec3 } from './stagePreset'

/** 1 フレーム分の入力。forward・right は -1〜1 */
export interface MoveInput {
  forward: number
  right: number
  run: boolean
}

const DEG = Math.PI / 180
/** 床にいるときの下向きの速さ（Unity の MuseumWalker と同じ） */
const GROUNDED_FALL_SPEED = -2
/** 1 フレームが長すぎるとき（タブの切り替え直後など）に、すり抜けないよう区切る上限 */
const MAX_FRAME_SECONDS = 0.05

const _forward = new THREE.Vector3()
const _right = new THREE.Vector3()
const _delta = new THREE.Vector3()
const _before = new THREE.Vector3()
const _probe = new Capsule()
const _lifted = new Capsule()

export class Player {
  readonly spec: PlayerSpec
  /** 体の当たり判定。start が足もと側、end が頭側の球の中心 */
  readonly capsule = new Capsule()
  readonly velocity = new THREE.Vector3()
  /** 水平の向き（ラジアン）。0 で -Z を向く（three.js のカメラと同じ） */
  yaw = 0
  /** 上下の向き（ラジアン）。上が正 */
  pitch = 0
  onFloor = false

  private world: CollisionWorld | null = null
  /** 入力どおりに進みたい水平の速さ（壁に沿って滑らせる前の値） */
  private readonly walk = new THREE.Vector3()
  private readonly spawn: THREE.Vector3
  private readonly spawnYaw: number
  private readonly floorNormalY: number

  constructor(spec: PlayerSpec, spawn: Vec3, lookAt: Vec3) {
    this.spec = spec
    this.spawn = new THREE.Vector3(...spawn)
    // lookAt の方向を向く yaw（-Z が 0 なので、水平の方向 (dx, dz) に対して atan2(-dx, -dz)）
    this.spawnYaw = Math.atan2(-(lookAt[0] - spawn[0]), -(lookAt[2] - spawn[2]))
    this.floorNormalY = Math.cos(spec.slopeLimitDeg * DEG)
    this.reset()
  }

  /** 当たり判定を設定する。null の間は動かない（ステージの準備中） */
  setWorld(world: CollisionWorld | null) {
    this.world = world
  }

  /** はじめの位置と向きに戻す */
  reset() {
    const { radius, height } = this.spec
    const { x, y, z } = this.spawn
    this.capsule.start.set(x, y + radius, z)
    this.capsule.end.set(x, y + height - radius, z)
    this.capsule.radius = radius
    this.velocity.set(0, 0, 0)
    this.yaw = this.spawnYaw
    this.pitch = 0
    this.onFloor = false
  }

  /** 足もとの位置と向きを決める（作品の詳細画面から戻ったときに、前の場所から歩き続けるため） */
  setPose(feet: Vec3, yaw: number, pitch: number) {
    const { radius, height } = this.spec
    const [x, y, z] = feet
    this.capsule.start.set(x, y + radius, z)
    this.capsule.end.set(x, y + height - radius, z)
    this.velocity.set(0, 0, 0)
    this.yaw = yaw
    this.pitch = pitch
    this.onFloor = false
  }

  /** マウスの移動量（px）で向きを変える */
  look(dx: number, dy: number) {
    const k = this.spec.lookDegPerPixel * DEG
    const limit = this.spec.pitchLimitDeg * DEG
    this.yaw -= dx * k
    this.pitch = THREE.MathUtils.clamp(this.pitch - dy * k, -limit, limit)
  }

  /** 足もとの位置 */
  feet(target: THREE.Vector3) {
    return target.set(this.capsule.start.x, this.capsule.start.y - this.spec.radius, this.capsule.start.z)
  }

  /** 目の位置（カメラを置く場所） */
  eye(target: THREE.Vector3) {
    this.feet(target)
    target.y += this.spec.eyeHeight
    return target
  }

  /** dt 秒ぶん動かす */
  update(dtSeconds: number, input: MoveInput) {
    if (!this.world) return
    const dt = Math.min(dtSeconds, MAX_FRAME_SECONDS)
    const { walkSpeed, runSpeed, gravity, maxFallSpeed, radius, rescueBelowY } = this.spec

    // 水平の速さ：向いている方向に対して前後左右（斜めでも速くならないよう長さを 1 までにする）
    _forward.set(-Math.sin(this.yaw), 0, -Math.cos(this.yaw))
    _right.set(Math.cos(this.yaw), 0, -Math.sin(this.yaw))
    this.walk.set(0, 0, 0).addScaledVector(_forward, input.forward).addScaledVector(_right, input.right)
    if (this.walk.lengthSq() > 1) this.walk.normalize()
    this.walk.multiplyScalar(input.run ? runSpeed : walkSpeed)
    this.velocity.x = this.walk.x
    this.velocity.z = this.walk.z

    // 縦の速さ：床にいれば軽く押しつけ、空中なら重力で加速する
    if (this.onFloor && this.velocity.y < 0) this.velocity.y = GROUNDED_FALL_SPEED
    else this.velocity.y = Math.max(this.velocity.y - gravity * dt, -maxFallSpeed)

    // 1 回に動く距離が体の太さの半分を超えないよう、細かく分けて動かす（壁のすり抜け防止）。
    // 水平に動く → 壁から押し戻す（段差なら上がる）→ 縦に動く → 床から押し戻す、の順に分けると、
    // 壁に押しつけたままでも「床に立っている」が正しく分かる
    const distance = this.velocity.length() * dt
    const steps = Math.max(1, Math.ceil(distance / (radius * 0.5)))
    const h = dt / steps
    const wasOnFloor = this.onFloor
    for (let i = 0; i < steps; i++) {
      this.onFloor = false
      _before.copy(this.capsule.start)
      this.capsule.translate(_delta.set(this.velocity.x * h, 0, this.velocity.z * h))
      if (this.resolveHorizontal() && this.velocity.y <= 0) this.tryStepUp(_before, h)
      this.capsule.translate(_delta.set(0, this.velocity.y * h, 0))
      this.resolveVertical()
    }
    // 段を降りるときに一段ずつ落ちて視点が揺れないよう、足もとの近くに床があれば吸いつける
    if (wasOnFloor && !this.onFloor && this.velocity.y <= 0) this.snapDown()

    if (this.capsule.start.y - radius < rescueBelowY) this.reset()
  }

  /** 水平に動いたあと、壁にめり込んだ分を押し戻し、壁に沿って横に滑らせる。壁に当たったら true */
  private resolveHorizontal() {
    const result = this.world!.capsuleIntersect(this.capsule)
    if (!result) return false
    const { normal, depth } = result
    const isFloor = normal.y > this.floorNormalY
    if (isFloor) {
      // 坂を上っている
      this.onFloor = true
    } else {
      const slide = _delta.set(normal.x, 0, normal.z).normalize()
      this.velocity.addScaledVector(slide, -slide.dot(this.velocity))
    }
    this.capsule.translate(normal.multiplyScalar(depth))
    return !isFloor
  }

  /** 縦に動いたあと、床や天井にめり込んだ分を押し戻す。床に立っているかもここで決まる */
  private resolveVertical() {
    const result = this.world!.capsuleIntersect(this.capsule)
    if (!result) return
    const { normal, depth } = result
    if (normal.y > this.floorNormalY) {
      this.onFloor = true
      this.capsule.translate(normal.multiplyScalar(depth))
    } else if (normal.y > 0 && this.velocity.y <= 0) {
      // 段の角に上から乗った：後ろに押し戻すと階段を上がれないので、真上に持ち上げて立たせる
      this.onFloor = true
      this.capsule.translate(_delta.set(0, Math.min(depth / normal.y, this.spec.stepHeight), 0))
    } else {
      // 天井や、空中でぶつかった壁：その向きの速さを消して押し戻す
      this.velocity.addScaledVector(normal, -normal.dot(this.velocity))
      this.capsule.translate(normal.multiplyScalar(depth))
    }
  }

  /**
   * 段差を上がる（Unity の CharacterController の stepOffset と同じ考え方）。
   * 壁に当たって入力どおりに進めなかったとき、動く前の位置から stepHeight だけ持ち上げて同じだけ進み、
   * ぶつかる直前まで下ろす。下ろした先が元より高ければ、そこに立たせる。
   */
  private tryStepUp(before: THREE.Vector3, h: number) {
    const wanted = Math.hypot(this.walk.x, this.walk.z) * h
    const moved = Math.hypot(this.capsule.start.x - before.x, this.capsule.start.z - before.z)
    if (wanted < 1e-6 || moved > wanted * 0.9) return

    const { stepHeight } = this.spec
    // 動く前の位置で持ち上げてから、入力どおりに進める。ここでぶつかるなら段差ではなく壁
    _probe.copy(this.capsule)
    _probe.translate(_delta.set(before.x - _probe.start.x, before.y - _probe.start.y + stepHeight, before.z - _probe.start.z))
    _probe.translate(_delta.set(this.walk.x * h, 0, this.walk.z * h))
    if (this.world!.capsuleIntersect(_probe)) return
    _lifted.copy(_probe)

    // ぶつかる直前まで下ろす（どこまで下ろせるかを二分探索）。最後まで下ろしても何もなければ段差ではない
    if (!this.intersectsLowered(stepHeight)) return
    let free = 0
    let blocked = stepHeight
    for (let i = 0; i < 10; i++) {
      const mid = (free + blocked) / 2
      if (this.intersectsLowered(mid)) blocked = mid
      else free = mid
    }
    _probe.copy(_lifted).translate(_delta.set(0, -free, 0))
    if (_probe.start.y <= before.y + 1e-3) return

    this.capsule.copy(_probe)
    this.velocity.x = this.walk.x
    this.velocity.z = this.walk.z
    this.onFloor = true
  }

  /** 足もとから stepHeight 以内に床があれば、そこまで下ろして床に立たせる */
  private snapDown() {
    _lifted.copy(this.capsule)
    if (!this.intersectsLowered(this.spec.stepHeight)) return
    let free = 0
    let blocked = this.spec.stepHeight
    for (let i = 0; i < 10; i++) {
      const mid = (free + blocked) / 2
      if (this.intersectsLowered(mid)) blocked = mid
      else free = mid
    }
    this.capsule.translate(_delta.set(0, -free, 0))
    this.velocity.y = GROUNDED_FALL_SPEED
    this.onFloor = true
  }

  /** 持ち上げた位置（_lifted）から drop だけ下ろしたとき、何かにぶつかるか */
  private intersectsLowered(drop: number) {
    _probe.copy(_lifted).translate(_delta.set(0, -drop, 0))
    return this.world!.capsuleIntersect(_probe) !== false
  }
}
