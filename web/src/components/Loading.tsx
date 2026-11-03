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

/**
 * 虹の線が 1 本ずつ増えていく読み込み表示（色は文字の色。動きは Loading.css）。
 * 3D を読み込んでいる間は、ブラウザのメインの処理がふさがる。そのとき止まらないよう、動かすのは transform と opacity だけにしている
 * （SVG の線を描く動き stroke-dashoffset は、メインの処理で動くので、止まってしまう）。
 * 線は、半円の窓（overflow: hidden）の中で、輪を回して、左から右へ描く。
 */
export function RainbowLoader() {
  return (
    <span className="rainbow-loader" aria-hidden="true">
      {[26, 20, 14, 8].map((r, i) => (
        <span key={r} className={`rainbow-arc a${i}`} style={{ width: r * 2, height: r, marginLeft: -r }}>
          <i style={{ width: r * 2, height: r * 2 }} />
        </span>
      ))}
    </span>
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

export function StageFallback({ label = 'Loading…' }: { label?: string }) {
  return (
    <div className="stage-fallback">
      <div className="stage-fallback-inner">
        <RainbowLoader />
        {label}
      </div>
    </div>
  )
}
