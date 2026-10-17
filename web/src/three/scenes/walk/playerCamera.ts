// 歩く人（player.ts の Player）とカメラをつなぐ、PC の操作（FirstPersonControls）とタッチの操作（TouchControls）で共通の処理。

import type * as THREE from 'three'
import type { Player } from './player'

/** 何も入力しないで動かす回数（はじめに床へ足をつけるため。1/60 秒ずつで 0.5 秒ぶん） */
const SETTLE_STEPS = 30
const NO_INPUT = { forward: 0, right: 0, run: false }

/** カメラを目の位置に置き、歩く人と同じ向きにする */
export function syncCameraToPlayer(camera: THREE.Camera, player: Player) {
  player.eye(camera.position)
  camera.rotation.set(player.pitch, player.yaw, 0, 'YXZ')
}

/** 何も入力せずに少しだけ時間を進めて、床に足をつけた状態にする（ステージの準備ができたとき） */
export function settleOnFloor(player: Player) {
  for (let i = 0; i < SETTLE_STEPS; i++) player.update(1 / 60, NO_INPUT)
}
