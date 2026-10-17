// 鑑賞モードの操作の種類（PC のキーボードとマウスか、スマホのタッチか）を決める。
// three.js を使わないので、画面（pages/MuseumWalk.tsx）も three/index.tsx から読む。
//   ふだんは端末で決める：ホバーできず、指で触る端末（(hover: none) and (pointer: coarse)）ならタッチ
//   開発用に PC でタッチの操作を試すときは、URL に ?input=touch を付けるか、localStorage.walkInput を 'touch' にする。
//   'pointer' にすると、タッチの端末でも PC の操作になる。両方あれば URL のほうを使う
// 画面が 1 回だけ isTouchDevice() を呼び、結果を WalkScene に props（touch）で渡す（画面と 3D の判定を食い違わせないため）。
// タッチの仮想スティックの大きさ（TOUCH_STICK_RADIUS）と、画面に知らせるスティックの状態（TouchStick）もここに置く
// （TouchControls が計算し、画面が DOM で描く）。

/** 操作の種類。touch：指（仮想スティックとなぞる操作）、pointer：キーボードとマウス */
export type WalkInput = 'touch' | 'pointer'

/** 仮想スティックの半径（CSS の px）。指をこれだけ動かすと、いちばん速く歩く */
export const TOUCH_STICK_RADIUS = 56

/** 仮想スティックの状態（TouchControls → 画面）。座標は 3D の画面（キャンバス）の左上からの CSS の px */
export interface TouchStick {
  /** 指を置いた所（スティックの中心） */
  x: number
  y: number
  /** 中心からつまみまで（半径 TOUCH_STICK_RADIUS までに収めた値） */
  dx: number
  dy: number
}

const isWalkInput = (value: string | null): value is WalkInput => value === 'touch' || value === 'pointer'

/** 開発用の指定（?input=… か localStorage.walkInput）。無ければ null */
function forcedInput(): WalkInput | null {
  try {
    const fromUrl = new URLSearchParams(window.location.search).get('input')
    if (isWalkInput(fromUrl)) return fromUrl
  } catch {
    // URL を読めないときは指定なしとして扱う
  }
  try {
    // プライベートブラウズなどで localStorage を読めないときは、例外になることがある
    const stored = window.localStorage.getItem('walkInput')
    if (isWalkInput(stored)) return stored
  } catch {
    // 読めないときは指定なしとして扱う
  }
  return null
}

/** タッチで操作する端末か（開発用の指定があればそちらを使う） */
export function isTouchDevice(): boolean {
  if (typeof window === 'undefined') return false
  const forced = forcedInput()
  if (forced) return forced === 'touch'
  return !!window.matchMedia?.('(hover: none) and (pointer: coarse)').matches
}
