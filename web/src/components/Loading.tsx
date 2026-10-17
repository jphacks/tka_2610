// 読み込み中の表示。
// Spinner: iOS 風のくるくる / Busy: 画面全体を覆う処理中カード / StageFallback: 3D が出るまでの仮表示
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

export function StageFallback({ label = '博物館を準備しています…' }: { label?: string }) {
  return (
    <div className="stage-fallback">
      <div className="stage-fallback-inner">
        <Spinner />
        {label}
      </div>
    </div>
  )
}
