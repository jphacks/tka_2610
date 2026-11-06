// 画像。Rust が計算した tint（平均色）を背景に敷いておき、読み込みが終わったらふわっと表示する。
// 見た目（既定のクラス .thumb）は、ほかの画面でも使うので styles/common.css にある。
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { photoTone } from './photoTone'

export function Img({
  src,
  tint,
  alt,
  className = 'thumb',
  eager = false,
  share,
  evenTone = false,
  children,
}: {
  src: string
  tint?: string | null
  alt: string
  className?: string
  eager?: boolean
  /** 共有要素アニメーション（サムネイル → 詳細画像）の候補にする作品 ID */
  share?: string
  /** 写真の背景の明るさを測って、作品ごとの明るさの倍率を img の --tone に入れる（作品一覧。photoTone.ts） */
  evenTone?: boolean
  children?: ReactNode
}) {
  const [loaded, setLoaded] = useState(false)
  const [tone, setTone] = useState<number | null>(null)
  const ref = useRef<HTMLImageElement>(null)

  // 読み込めたら（倍率を決めてから）表示する。倍率と表示を同じ描画で切り替えるので、明るさが後から変わって見えない
  const onReady = () => {
    const img = ref.current
    if (evenTone && img) setTone(photoTone(img))
    setLoaded(true)
  }

  useEffect(() => {
    setTone(null)
    if (ref.current?.complete) onReady()
    else setLoaded(false)
  }, [src, evenTone])

  return (
    <div className={className} style={{ background: tint ?? undefined }} data-share={share}>
      <img
        ref={ref}
        src={src}
        alt={alt}
        loading={eager ? 'eager' : 'lazy'}
        decoding="async"
        className={loaded ? 'loaded' : ''}
        style={tone !== null ? ({ '--tone': String(tone) } as CSSProperties) : undefined}
        onLoad={onReady}
      />
      {children}
    </div>
  )
}
