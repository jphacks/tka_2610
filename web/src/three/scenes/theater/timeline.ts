// シアターの時間割を、再生位置の時刻 t（ミリ秒）から読む。three.js を使わない純粋な関数だけを置く
// （画面の DigestTheater も three/index.tsx 経由で使う。時刻は Rust の theater.rs が決めたもの）。
//
// 大地（球）は X 軸のまわりに回る。作品 i は球の角度 i × SLOT_ANGLE に立っていて、
// 大地の回転が i × SLOT_ANGLE になったとき、ちょうど手前の頂上に来る。
// 大地は作品ごとに止まらず、映像のように回り続ける（globeAngleAt）。作品は奥の稜線から現れ、頂上でゆっくりになり、手前の下へ流れていく。
import type { TheaterData, TheaterScene } from '../../../api'

/** 作品と作品のあいだの、大地の角度（球を 14 等分。家や木の並びは 14 場面ごとにくり返す） */
export const SLOTS = 14
export const SLOT_ANGLE = (Math.PI * 2) / SLOTS
/** 写真立てが立ち上がる・倒れる長さ */
export const STAND_RISE_MS = 520
export const STAND_FALL_MS = 380
/** コマ撮り風のときの、作品のゆれと写真立ての動きのコマ数（1 秒あたり）。大地の流れはいつもなめらか（参照の映像と同じ） */
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

/**
 * 作品の滞在（arrive_ms 〜 arrive_ms + hold_ms。メモと写真立てが出ている間）に、大地がゆっくり一定の速さで回る範囲（SLOT_ANGLE に対する割合）。
 * 着いたときは頂上より HOLD_FROM だけ奥にいて、滞在の終わりに頂上を HOLD_TO だけ過ぎる。
 * 頂上より奥のほうが画面に収まりやすい（手前に来るほど大きく、下へ切れていく）ので、奥を長めにしている。
 * 残り（1 − HOLD_FROM − HOLD_TO）は、作品と作品のあいだ（transition_ms）に少し速く流れる。どちらも止まらない。
 */
export const HOLD_FROM = 0.4
export const HOLD_TO = 0.15
/** 最後の作品の滞在のあと、流れ去って止まるまでに回る角度（SLOT_ANGLE に対する割合） */
export const OUTRO_TRAVEL = 0.4

/** 大地の角度の曲線の節点（時刻・角度・その時刻の傾き）。時間割ごとに 1 度だけ作る */
interface GlobeCurve {
  times: number[]
  angles: number[]
  slopes: number[]
}
const curves = new WeakMap<TheaterData, GlobeCurve>()

function globeCurve(data: TheaterData): GlobeCurve {
  const cached = curves.get(data)
  if (cached) return cached
  const times = [0]
  const angles = [-SLOT_ANGLE]
  const slopes = [0]
  const push = (time: number, angle: number, slope: number) => {
    times.push(Math.max(times[times.length - 1] + 1, time))
    angles.push(angle)
    slopes.push(slope)
  }
  // 節点：はじめ（見えない奥・止まっている） → 各作品の滞在のはじめと終わり（その間は一定の速さ） → 終わり（止まる）。
  // 滞在のあいだは両端の傾きが同じなので直線になり、あいだの区間は前後の滞在の速さになめらかにつながる。
  // 端の傾きは、あいだの区間の平均の傾きより十分小さいので、曲線は逆戻りしない（単調）。
  data.scenes.forEach((scene, i) => {
    const from = (i - HOLD_FROM) * SLOT_ANGLE
    const to = (i + HOLD_TO) * SLOT_ANGLE
    const slope = (to - from) / Math.max(1, scene.hold_ms)
    push(scene.arrive_ms, from, slope)
    push(scene.arrive_ms + scene.hold_ms, to, slope)
  })
  push(data.total_ms, angles[angles.length - 1] + OUTRO_TRAVEL * SLOT_ANGLE, 0)
  const curve = { times, angles, slopes }
  curves.set(data, curve)
  return curve
}

/**
 * t のときの大地の角度（3 次エルミート補間のなめらかな曲線）。作品 i は滞在の途中で頂上（i × SLOT_ANGLE）を通る。
 * 止まるのは、はじめと終わりだけ。作品が見えている間はゆっくり、作品と作品のあいだは少し速く、止まらずに流れる。
 */
export function globeAngleAt(data: TheaterData, t: number): number {
  if (data.scenes.length === 0) return 0
  const { times, angles, slopes } = globeCurve(data)
  if (t <= times[0]) return angles[0]
  const lastK = times.length - 1
  if (t >= times[lastK]) return angles[lastK]
  let lo = 0
  let hi = lastK
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1
    if (times[mid] <= t) lo = mid
    else hi = mid
  }
  const h = times[hi] - times[lo]
  const u = (t - times[lo]) / h
  const u2 = u * u
  const u3 = u2 * u
  return (2 * u3 - 3 * u2 + 1) * angles[lo] + (u3 - 2 * u2 + u) * h * slopes[lo] + (-2 * u3 + 3 * u2) * angles[hi] + (u3 - u2) * h * slopes[hi]
}

/** コマ撮り風のときの時刻（1 秒に STOP_MOTION_FPS コマに丸める） */
export const stopMotionTime = (t: number) => Math.floor((t / 1000) * STOP_MOTION_FPS) * (1000 / STOP_MOTION_FPS)

/**
 * t のときの場面・段階・大地の角度。
 * 大地はコマ撮り風のときもコマ送りにしない（止まらずに流れる大地をコマ送りにすると、全体がカクついて見える）
 */
export function frameAt(data: TheaterData, t: number): TheaterFrame {
  const scenes = data.scenes
  const index = sceneIndexAt(scenes, t)
  if (index < 0) return { index: -1, phase: 'intro', local: 0, angle: 0, travel: 0 }
  const scene = scenes[index]
  const angle = globeAngleAt(data, t)
  const local = t - scene.arrive_ms
  if (t < scene.arrive_ms) {
    const travel = (t - scene.start_ms) / Math.max(1, scene.arrive_ms - scene.start_ms)
    return { index, phase: index === 0 ? 'intro' : 'rolling', local, angle, travel: Math.min(1, Math.max(0, travel)) }
  }
  if (index === scenes.length - 1 && t >= sceneEnd(scene)) return { index, phase: 'outro', local, angle, travel: 1 }
  return { index, phase: 'hold', local, angle, travel: 1 }
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

/** 選べる進む速さ（1 がふつう。2 なら全体が半分の長さになる） */
export const THEATER_SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4] as const

/** 「約3分53秒」（theater.rs の duration_label と同じ書き方） */
export function durationLabel(ms: number): string {
  const seconds = Math.ceil(Math.max(0, ms) / 1000)
  if (seconds < 60) return `約${seconds}秒`
  const minutes = Math.floor(seconds / 60)
  const rest = seconds % 60
  return rest === 0 ? `約${minutes}分` : `約${minutes}分${rest}秒`
}

/**
 * 進む速さに合わせて、時間割の時刻をすべて 1/speed 倍にする（大地が回る長さ・作品の滞在・写真の切り替え・メモ）。
 * 作品・おもいでのオブジェクトはそのまま使い回す（3D の読み込みをやり直さないため）。
 * 動画と声はいつもの速さで流すので、速くすると途中まで、遅くすると流し終えたあとも写真立ては立ったままになる。
 */
export function scaleTheater(data: TheaterData, speed: number): TheaterData {
  if (!(speed > 0) || speed === 1) return data
  const s = (ms: number) => Math.round(ms / speed)
  const total = s(data.total_ms)
  return {
    ...data,
    transition_ms: s(data.transition_ms),
    outro_ms: s(data.outro_ms),
    total_ms: total,
    duration_label: durationLabel(total),
    scenes: data.scenes.map((scene) => ({
      ...scene,
      start_ms: s(scene.start_ms),
      arrive_ms: s(scene.arrive_ms),
      hold_ms: s(scene.arrive_ms + scene.hold_ms) - s(scene.arrive_ms),
      media: scene.media.map((m) => ({ ...m, show_ms: s(m.show_ms), hide_ms: s(m.hide_ms), play_ms: m.play_ms === null ? null : s(m.play_ms) })),
      memo: scene.memo.map((line) => ({ ...line, show_ms: s(line.show_ms), hide_ms: s(line.hide_ms) })),
      voice_at_ms: s(scene.voice_at_ms),
      voice_ms: s(scene.voice_ms),
    })),
  }
}

/** 「1:05」 */
export function clockLabel(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  const m = Math.floor(total / 60)
  const s = total % 60
  return `${m}:${String(s).padStart(2, '0')}`
}
