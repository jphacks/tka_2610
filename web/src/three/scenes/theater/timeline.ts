// シアターの時間割を、再生位置の時刻 t（ミリ秒）から読む。three.js を使わない純粋な関数だけを置く
// （画面の DigestTheater も three/index.tsx 経由で使う。時刻は Rust の theater.rs が決めたもの）。
//
// 大地（球）は X 軸のまわりに回る。作品 i は球の角度 i × SLOT_ANGLE に立っていて、
// 大地の回転が i × SLOT_ANGLE になったとき、ちょうど手前の頂上に来る。
import type { TheaterData, TheaterScene } from '../../../api'

/** 作品と作品のあいだの、大地の角度（球を 14 等分。家や木の並びは 14 場面ごとにくり返す） */
export const SLOTS = 14
export const SLOT_ANGLE = (Math.PI * 2) / SLOTS
/** 写真立てが立ち上がる・倒れる長さ */
export const STAND_RISE_MS = 520
export const STAND_FALL_MS = 380
/** コマ撮り風のときの、大地の回転のコマ数（1 秒あたり） */
export const STOP_MOTION_FPS = 12

export type TheaterPhase = 'intro' | 'rolling' | 'hold' | 'outro'

/** t のときの場面（大地が回りはじめてから、次の場面が始まるまで）。作品が無ければ -1 */
export function sceneIndexAt(scenes: TheaterScene[], t: number): number {
  if (scenes.length === 0) return -1
  let lo = 0
  let hi = scenes.length - 1
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (scenes[mid].start_ms <= t) lo = mid
    else hi = mid - 1
  }
  return lo
}

/** 場面の終わり（次の場面が始まる時刻） */
export const sceneEnd = (scene: TheaterScene) => scene.arrive_ms + scene.hold_ms

const smootherstep = (x: number) => {
  const p = Math.min(1, Math.max(0, x))
  return p * p * p * (p * (p * 6 - 15) + 10)
}
const easeInOut = (x: number) => {
  const p = Math.min(1, Math.max(0, x))
  return p < 0.5 ? 2 * p * p : 1 - (-2 * p + 2) ** 2 / 2
}

export interface TheaterFrame {
  index: number
  phase: TheaterPhase
  /** 作品が着いてからの時刻（着く前は負） */
  local: number
  /** 大地の回転の角度 */
  angle: number
  /** 移動の進み具合 0〜1（hold では 1） */
  travel: number
}

/** t のときの場面・段階・大地の角度。stopMotion のときは大地の回転をコマ送りにする */
export function frameAt(data: TheaterData, t: number, stopMotion = false): TheaterFrame {
  const scenes = data.scenes
  const index = sceneIndexAt(scenes, t)
  if (index < 0) return { index: -1, phase: 'intro', local: 0, angle: 0, travel: 0 }
  const scene = scenes[index]
  const at = stopMotion ? Math.floor((t / 1000) * STOP_MOTION_FPS) * (1000 / STOP_MOTION_FPS) : t
  const local = t - scene.arrive_ms
  if (t < scene.arrive_ms) {
    const travel = (at - scene.start_ms) / Math.max(1, scene.arrive_ms - scene.start_ms)
    const from = (index - 1) * SLOT_ANGLE
    return { index, phase: index === 0 ? 'intro' : 'rolling', local, angle: from + SLOT_ANGLE * smootherstep(travel), travel: Math.min(1, Math.max(0, travel)) }
  }
  const end = sceneEnd(scene)
  if (index === scenes.length - 1 && t >= end) {
    // 最後の作品のあと、大地をゆっくり少しだけ回して余韻を残す
    const p = (at - end) / Math.max(1, data.outro_ms)
    return { index, phase: 'outro', local, angle: index * SLOT_ANGLE + SLOT_ANGLE * 0.32 * easeInOut(p), travel: 1 }
  }
  return { index, phase: 'hold', local, angle: index * SLOT_ANGLE, travel: 1 }
}

/** 写真立てが立っている度合い 0〜1（立ち上がり → 立つ → 倒れる）。local は作品が着いてからの時刻 */
export function standLift(show: number, hide: number, local: number): number {
  if (local < show || local > hide + STAND_FALL_MS) return 0
  if (local < show + STAND_RISE_MS) return (local - show) / STAND_RISE_MS
  if (local <= hide) return 1
  return 1 - (local - hide) / STAND_FALL_MS
}

/** メモの、いま見えている行（無ければ -1） */
export function memoLineAt(scene: TheaterScene, local: number): number {
  return scene.memo.findIndex((line) => local >= line.show_ms && local < line.hide_ms)
}

/** シークバーの目盛り（各作品が着く時刻の割合） */
export function chapterMarks(data: TheaterData): number[] {
  if (data.total_ms <= 0) return []
  return data.scenes.map((s) => s.arrive_ms / data.total_ms)
}

/** 「1:05」 */
export function clockLabel(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  const m = Math.floor(total / 60)
  const s = total % 60
  return `${m}:${String(s).padStart(2, '0')}`
}
