// 読み込み中の表示。
// Spinner: iOS 風のくるくる / Busy: 画面全体を覆う処理中カード / StageFallback: 3D が出るまでの仮表示（虹の線が 1 本ずつ増える RainbowLoader）
import type { CSSProperties } from 'react'
import './Loading.css'

export function Spinner() {
  return (
    <span className="spinner" aria-hidden="true">
      {Array.from({ length: 8 }, (_, i) => (
        <i key={i} style={{ '--i': i } as CSSProperties} />
      ))}
    </span>
  )
}

/** 虹の線が 1 本ずつ増えていく読み込み表示（色は文字の色。動きは Loading.css。動きを減らす設定のときは止めて、虹を出したままにする） */
export function RainbowLoader() {
  return (
    <svg className="rainbow-loader" viewBox="0 0 56 32" width="56" height="32" aria-hidden="true">
      {[24, 18, 12, 6].map((r, i) => (
        <path key={r} className={`rainbow-arc a${i}`} pathLength={1} d={`M${28 - r} 30A${r} ${r} 0 0 1 ${28 + r} 30`} />
      ))}
    </svg>
  )
}

export function Busy({ label }: { label: string }) {
  return (
    <div className="busy" role="alert" aria-busy="true">
      <div className="busy-card">
        <Spinner />
        {label}
      </div>
    </div>
  )
}

export function StageFallback({ label = 'おうちを準備しています…' }: { label?: string }) {
  return (
    <div className="stage-fallback">
      <div className="stage-fallback-inner">
        <RainbowLoader />
        {label}
      </div>
    </div>
  )
}
