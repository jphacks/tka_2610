// 作品のサムネイル（一覧・関連作品・模様替えの「追加」のシート・アルバムの「作品を選ぶ」で共通）と、読み込み中の仮表示。
import type { CSSProperties } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { prefetchArtwork, type Artwork } from '../api'
import { GalleryIcon, HeartIcon, MicIcon, VideoIcon } from '../icons'
import { Img } from './Img'
import { TLink } from './TLink'
import './ArtworkThumb.css'

export function ArtworkThumb({
  artwork,
  showBadge = false,
  meta = 'date',
  index = 0,
  gallery = false,
  onSelect,
  selected,
}: {
  artwork: Artwork
  /** 展示中の作品に緑の点を付ける */
  showBadge?: boolean
  /** 作品名の下に出すもの。'age' は作ったときの年齢（「4さい 3か月」。誕生日が無ければ日付）。作品一覧で使う */
  meta?: 'date' | 'age'
  /** 並び順。表示アニメーションを少しずつずらすのに使う */
  index?: number
  /** 一覧用。作品全体の画像と、飾っている印・おもいでを表示する */
  gallery?: boolean
  /** 渡すと、詳細画面へのリンクではなく、押すとこれを呼ぶボタンになる（模様替えの「追加」のシート） */
  onSelect?: () => void
  /** onSelect のときだけ。渡すと選ぶボタンになり、true なら選んだ印（右上のチェック）を付ける（アルバムの「作品を選ぶ」） */
  selected?: boolean
}) {
  const client = useQueryClient()
  const metaText = (meta === 'age' && artwork.age_month_label) || artwork.date_short
  if (onSelect) {
    return (
      <button
        type="button"
        className={`thumb-card thumb-button pressable${selected ? ' is-selected' : ''}`}
        style={{ '--i': Math.min(index, 12) } as CSSProperties}
        aria-pressed={selected}
        onClick={onSelect}
      >
        <Img src={artwork.thumb_url} tint={artwork.tint} alt={artwork.title}>
          {selected !== undefined && <span className="thumb-check" aria-hidden="true" />}
        </Img>
        <p className="thumb-title">{artwork.title}</p>
        <p className="thumb-meta">{metaText}</p>
      </button>
    )
  }
  return (
    <TLink
      to={`/artworks/${artwork.id}`}
      share={artwork.id}
      // 作品一覧で長押ししてアルバムへ運ぶとき（pages/AlbumDrag.tsx）に、どの作品かを見分ける
      data-artwork-id={artwork.id}
      className={`thumb-card pressable${gallery ? ' artwork-gallery-card' : ''}`}
      style={{ '--i': Math.min(index, 12) } as CSSProperties}
      // 指を置いた時点で詳細データを先読みしておく
      onPointerEnter={() => prefetchArtwork(client, artwork.id)}
      onTouchStart={() => prefetchArtwork(client, artwork.id)}
      onFocus={() => prefetchArtwork(client, artwork.id)}
    >
      <Img src={gallery ? artwork.image_url : artwork.thumb_url} tint={gallery ? undefined : artwork.tint} alt={artwork.title} share={artwork.id} eager={gallery && index < 4}>
        {gallery && artwork.favorite && <span className="artwork-gallery-favorite" aria-label="お気に入り"><HeartIcon size={13} filled /></span>}
      </Img>
      {gallery && <p className="artwork-gallery-category">{artwork.category_label}</p>}
      <p className="thumb-title">{artwork.title}</p>
      <p className="thumb-meta">
        {showBadge && artwork.displayed && !gallery && <span className="on-view" title="展示中" aria-label="展示中" />}
        {metaText}
      </p>
      {gallery && (
        <div className="artwork-gallery-foot">
          {artwork.displayed && <span className="artwork-gallery-display"><span className="on-view" />飾っている</span>}
          <span className="artwork-gallery-memories">
            {artwork.memory_counts.photo > 0 && <span aria-label={`おもいでの写真${artwork.memory_counts.photo}件`}><GalleryIcon size={12} />{artwork.memory_counts.photo}</span>}
            {artwork.memory_counts.video > 0 && <span aria-label={`おもいでの動画${artwork.memory_counts.video}件`}><VideoIcon size={12} />{artwork.memory_counts.video}</span>}
            {artwork.memory_counts.audio > 0 && <span aria-label={`おもいでの音声${artwork.memory_counts.audio}件`}><MicIcon size={12} />{artwork.memory_counts.audio}</span>}
          </span>
        </div>
      )}
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
