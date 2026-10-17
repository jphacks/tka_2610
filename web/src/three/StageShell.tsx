// 3D を表示する枠。3D が描画されるまで「準備しています…」を重ね、描画されたらふわっと消す。
// three.js は使っていないので、最初の読み込みに含まれても軽い。
import { useEffect, useState, type ReactNode } from 'react'
import { StageFallback } from '../components'
import './StageShell.css'

export function StageShell({
  className,
  ready,
  label,
  children,
  overlay,
}: {
  /** 画面ごとの大きさや角丸を付けるクラス（.home-hero など） */
  className: string
  /** 3D の最初の描画が終わったら true */
  ready: boolean
  label?: string
  children: ReactNode
  /** 3D の上に重ねるボタンや文字 */
  overlay?: ReactNode
}) {
  const [showFallback, setShowFallback] = useState(!ready)
  useEffect(() => {
    if (!ready) {
      setShowFallback(true)
      return
    }
    const t = window.setTimeout(() => setShowFallback(false), 450)
    return () => window.clearTimeout(t)
  }, [ready])

  return (
    <div className={`stage ${className}`}>
      <div style={{ position: 'absolute', inset: 0 }}>{children}</div>
      {showFallback && (
        <div style={{ position: 'absolute', inset: 0, transition: 'opacity .45s', opacity: ready ? 0 : 1, pointerEvents: 'none' }}>
          <StageFallback label={label} />
        </div>
      )}
      {overlay}
    </div>
  )
}
