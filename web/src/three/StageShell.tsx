// 3D を表示する枠。3D が描画されるまで「準備しています…」を重ね、描画されたらふわっと消す。
// 画面遷移のアニメーション中は、3D（children）をまだ置かない（nav.ts の useNavSettled）。キャンバス（WebGL）を作る・
// GLB を複製する・シェーダーを作る・テクスチャを送るといった重い処理がアニメーションと重なると、コマ落ちして
// 前の画面が残っているように見えるため。その間は「準備しています…」が見えている。
// 遷移なしで開いた画面（URL を直接開いた・ブラウザの戻るボタン）では、すぐに置く。
// 一度置いた 3D は、その後に遷移が始まっても外さない（同じ画面のまま URL だけ変わったときに、キャンバスを作り直さないように）。
// three.js は使っていないので、最初の読み込みに含まれても軽い。
import { useEffect, useState, type ReactNode } from 'react'
import { StageFallback } from '../components'
import { useNavSettled } from '../nav'
import './StageShell.css'

export function StageShell({
  className,
  ready,
  label,
  children,
  overlay,
}: {
  /** 画面ごとの大きさや角丸を付けるクラス（.home-stage など） */
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

  // 遷移が終わったら 3D を置く。一度置いたら、次の遷移が始まっても置いたまま
  const settled = useNavSettled()
  const [mounted, setMounted] = useState(settled)
  if (settled && !mounted) setMounted(true)

  return (
    <div className={`stage ${className}`}>
      <div style={{ position: 'absolute', inset: 0 }}>{mounted ? children : null}</div>
      {showFallback && (
        <div style={{ position: 'absolute', inset: 0, transition: 'opacity .45s', opacity: ready ? 0 : 1, pointerEvents: 'none' }}>
          <StageFallback label={label} />
        </div>
      )}
      {overlay}
    </div>
  )
}
