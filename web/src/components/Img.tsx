// 画像。Rust が計算した tint（平均色）を背景に敷いておき、読み込みが終わったらふわっと表示する。
// 見た目（既定のクラス .thumb）は、ほかの画面でも使うので styles/common.css にある。
import { useEffect, useRef, useState, type ReactNode } from 'react'

export function Img({
  src,
  tint,
  alt,
  className = 'thumb',
  eager = false,
  share,
  children,
}: {
  src: string
  tint?: string | null
  alt: string
  className?: string
  eager?: boolean
  /** 共有要素アニメーション（サムネイル → 詳細画像）の候補にする作品 ID */
  share?: string
  children?: ReactNode
}) {
  const [loaded, setLoaded] = useState(false)
  const ref = useRef<HTMLImageElement>(null)

  useEffect(() => {
    setLoaded(!!ref.current?.complete)
  }, [src])

  return (
    <div className={className} style={{ background: tint ?? undefined }} data-share={share}>
      <img
        ref={ref}
        src={src}
        alt={alt}
        loading={eager ? 'eager' : 'lazy'}
        decoding="async"
        className={loaded ? 'loaded' : ''}
        onLoad={() => setLoaded(true)}
      />
      {children}
    </div>
  )
}
