// ⑥ 作品の詳細（/artworks/:id）。一覧などから push で開く。
// 額縁に入った作品とキャプション。3D で見る・おうちに飾る・編集・削除ができる。
import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useArtwork, useDeleteArtwork, useDisplay, useFavorite } from '../api'
import { ActionMenu, ArtworkThumb, GlassButton, Screen, Sheet, useToast } from '../components'
import {
  BackIcon,
  CloseIcon,
  DocIcon,
  HeartIcon,
  MoreIcon,
  MuseumIcon,
  ShareIcon,
} from '../icons'
import { useNav } from '../nav'
import { warmUp3D } from '../three'
import './ArtworkDetail.css'

export default function ArtworkDetail() {
  const { id = '' } = useParams()
  const nav = useNav()
  const toast = useToast()
  const detail = useArtwork(id)
  const favorite = useFavorite()
  const display = useDisplay()
  const remove = useDeleteArtwork()
  const [menu, setMenu] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)

  const artwork = detail.data?.artwork
  const related = detail.data?.related ?? []

  // 「3Dで見る」をすぐ開けるようにモデルを先読み
  useEffect(() => {
    if (artwork) warmUp3D(null, [artwork.model_url])
  }, [artwork?.model_url]) // eslint-disable-line react-hooks/exhaustive-deps

  if (detail.isError) {
    return (
      <Screen>
        <div className="page" style={{ paddingTop: 90 }}>
          <div className="empty">
            <p>作品が見つかりませんでした。</p>
            <button className="btn btn-outline btn-small" onClick={() => nav.tab('/collection')}>
              作品一覧へ
            </button>
          </div>
        </div>
      </Screen>
    )
  }

  const share = async () => {
    if (!artwork) return
    const url = window.location.href
    try {
      if (navigator.share) await navigator.share({ title: artwork.title, text: `${artwork.author_label}の作品「${artwork.title}」`, url })
      else {
        await navigator.clipboard.writeText(url)
        toast('リンクをコピーしました')
      }
    } catch {
      /* 共有をキャンセルした */
    }
  }

  const toggleDisplay = () => {
    if (!artwork) return
    display.mutate(
      { id: artwork.id, display: !artwork.displayed },
      {
        onSuccess: (a) => toast(a.displayed ? `${a.room_name ?? 'おうち'}に飾りました` : '飾るのをやめました'),
        // 飾る場所がいっぱいのとき（409）なども、Rust が返す日本語のメッセージをそのまま出す
        onError: (e) => toast(e.message),
      },
    )
  }

  return (
    <Screen>
      <div className="detail-stage">
        <div className="stage-top">
          <GlassButton label="戻る" onClick={() => nav.back('/collection', artwork?.id)}>
            <BackIcon size={20} strokeWidth={2.2} />
          </GlassButton>
          <div className="stage-actions">
            <GlassButton label="共有" onClick={share}>
              <ShareIcon size={18} />
            </GlassButton>
            <GlassButton label="メニュー" onClick={() => setMenu(true)}>
              <MoreIcon size={20} />
            </GlassButton>
          </div>
        </div>
        {artwork && (
          <div className="framed" data-share={artwork.id}>
            {/* 大きい画像が届くまでは、一覧で読み込み済みのサムネイルを敷いておく */}
            <img
              src={artwork.image_url}
              alt={artwork.title}
              decoding="async"
              width={artwork.image_width}
              height={artwork.image_height}
              style={{ background: `${artwork.tint} url(${artwork.thumb_url}) center / cover no-repeat` }}
            />
          </div>
        )}
      </div>

      {artwork && (
        <section className="caption">
          <div className="eyebrow num">
            <span>{artwork.catalog_label}</span>
            <span>{artwork.category_label}</span>
          </div>
          <div className="caption-head">
            <h2>{artwork.title}</h2>
            <button
              className={`heart${artwork.favorite ? ' on' : ''}`}
              aria-label={artwork.favorite ? 'お気に入りを外す' : 'お気に入りにする'}
              aria-pressed={artwork.favorite}
              onClick={() => favorite.mutate({ id: artwork.id, favorite: !artwork.favorite })}
            >
              <HeartIcon size={24} filled={artwork.favorite} />
            </button>
          </div>
          {artwork.author_label && <p className="author">{artwork.author_label}</p>}
          {artwork.memo && <p className="memo">{artwork.memo}</p>}

          <dl className="spec">
            <div>
              <dt>制作日</dt>
              <dd className="num">{artwork.date_long}</dd>
            </div>
            <div>
              <dt>飾る場所</dt>
              <dd>
                {artwork.displayed ? (
                  <>
                    <span className="on-view" />
                    {artwork.room_name}
                  </>
                ) : (
                  <span style={{ color: 'var(--ink-2)' }}>まだ飾っていません</span>
                )}
              </dd>
            </div>
          </dl>
        </section>
      )}

      <div className="page">
        {artwork && (
          <div className="btn-stack" style={{ marginTop: 24 }}>
            <button className="btn btn-filled" onClick={() => nav.modal(`/artworks/${artwork.id}/preview`)}>
              3Dで見る
            </button>
            {artwork.displayed ? (
              <button className="btn btn-outline" onClick={() => nav.push(`/museum?room=${artwork.room_id}&focus=${artwork.id}`)}>
                おうちで見る
              </button>
            ) : (
              <button className="btn btn-outline" onClick={toggleDisplay} disabled={display.isPending}>
                おうちに飾る
              </button>
            )}
          </div>
        )}

        {related.length > 0 && (
          <>
            <div className="section-head">
              <h2>関連する作品</h2>
            </div>
            <div className="grid-3">
              {related.slice(0, 3).map((a, i) => (
                <ArtworkThumb key={a.id} artwork={a} index={i} />
              ))}
            </div>
          </>
        )}
      </div>

      <ActionMenu
        open={menu}
        onClose={() => setMenu(false)}
        items={[
          { label: '編集', icon: <DocIcon size={19} />, onSelect: () => nav.modal(`/artworks/${id}/edit`) },
          {
            label: artwork?.displayed ? '飾るのをやめる' : 'おうちに飾る',
            icon: <MuseumIcon size={19} />,
            onSelect: toggleDisplay,
          },
          { label: '削除', icon: <CloseIcon size={19} />, destructive: true, onSelect: () => setConfirmDelete(true) },
        ]}
      />

      <Sheet open={confirmDelete && !!artwork} onClose={() => setConfirmDelete(false)} title={`「${artwork?.title ?? ''}」を削除しますか？`}>
        <p className="hint" style={{ textAlign: 'center', margin: '4px 8px 0' }}>
          写真と3Dモデルも削除され、おうちからも外れます。この操作は取り消せません。
        </p>
        <div className="sheet-body">
          <button
            className="btn btn-destructive"
            disabled={remove.isPending}
            onClick={() =>
              artwork &&
              remove.mutate(artwork.id, {
                onSuccess: () => {
                  toast('作品を削除しました')
                  setConfirmDelete(false)
                  nav.back('/collection')
                },
                onError: (e) => toast(e.message),
              })
            }
          >
            作品を削除
          </button>
          <button className="btn btn-gray" onClick={() => setConfirmDelete(false)}>
            キャンセル
          </button>
        </div>
      </Sheet>
    </Screen>
  )
}
