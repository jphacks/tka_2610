// 作品のサムネイル（一覧・ホーム・関連作品で共通）と、読み込み中の仮表示。
import type { CSSProperties } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { prefetchArtwork, type Artwork } from '../api'
import { Img } from './Img'
import { TLink } from './TLink'
import './ArtworkThumb.css'

export function ArtworkThumb({
  artwork,
  showBadge = false,
  index = 0,
}: {
  artwork: Artwork
  /** 展示中の作品に緑の点を付ける */
  showBadge?: boolean
  /** 並び順。表示アニメーションを少しずつずらすのに使う */
  index?: number
}) {
  const client = useQueryClient()
  return (
    <TLink
      to={`/artworks/${artwork.id}`}
      share={artwork.id}
      className="thumb-card pressable"
      style={{ '--i': Math.min(index, 12) } as CSSProperties}
      // 指を置いた時点で詳細データを先読みしておく
      onPointerEnter={() => prefetchArtwork(client, artwork.id)}
      onTouchStart={() => prefetchArtwork(client, artwork.id)}
    >
      <Img src={artwork.thumb_url} tint={artwork.tint} alt={artwork.title} share={artwork.id} />
      <p className="thumb-title">{artwork.title}</p>
      <p className="thumb-meta">
        {showBadge && artwork.displayed && <span className="on-view" title="展示中" aria-label="展示中" />}
        {artwork.date_short}
      </p>
    </TLink>
  )
}

export function ThumbSkeletons({ count = 3 }: { count?: number }) {
  return (
    <>
      {Array.from({ length: count }, (_, i) => (
        <div key={i}>
          <div className="thumb skeleton" />
          <div className="skeleton" style={{ height: 12, marginTop: 9, borderRadius: 6, width: '70%' }} />
        </div>
      ))}
    </>
  )
}
