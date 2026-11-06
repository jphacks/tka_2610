// ⑥ 作品の詳細（/artworks/:id）。一覧などから push で開く。
// 上は作品の 3D（触って回せる）とキャプション。3D を読み込むまでと、「写真」に切り替えたときは額縁に入った写真を出す。
// おうちで見る・おうちに飾る・編集・削除ができる。
// その下の「おもいで」（MemorySection）に、作品に付けた写真・動画・声の記録を並べ、足す・消すができる。



import { Suspense, useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import {
  useArtwork,
  useDeleteArtwork,
  useDisplay,
  useFavorite,
} from '../api'
import {
  ActionMenu,
  AlbumSheet,
  ArtworkThumb,
  ErrorBoundary,
  GlassButton,
  MemorySection,
  Screen,
  Sheet,
  useToast,
} from '../components'
import {
  BackIcon,
  CloseIcon,
  DocIcon,
  GalleryIcon,
  HeartIcon,
  MoreIcon,
  RainbowIcon,
  ShareIcon,
} from '../icons'
import { useNav } from '../nav'
import { ArtworkViewerScene, isTouchDevice, warmUp3D } from '../three'
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
  const [albumSheet, setAlbumSheet] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)

  const artwork = detail.data?.artwork
  const related = detail.data?.related ?? []

  // 上の 3D：開いたらすぐ置く（画面の移動を待つと、そのぶん 3D が出るのが遅れる。移動のアニメーションは
  // View Transitions が合成側で動かすので、ここで 3D を作ってもすべりは止まらない）。読めなければ写真を出す。
  // 戻るときも外さない（外すと、遷移が写す前に 3D が消えてしまう）
  const [view, setView] = useState<'3d' | 'photo'>('3d')
  const [viewerReady, setViewerReady] = useState(false)
  const [viewerFailed, setViewerFailed] = useState(false)
  const [touched, setTouched] = useState(false)
  useEffect(() => { setViewerReady(false); setViewerFailed(false); setTouched(false) }, [artwork?.model_url])
  const onViewerReady = useCallback(() => setViewerReady(true), [])
  const onViewerTouch = useCallback(() => setTouched(true), [])
  // 拡大：3D の上のホイール・ピンチだけ（OrbitControls）。拡大しているあいだは「元の大きさ」を出す
  const [zoomed, setZoomed] = useState(false)
  const [resetKey, setResetKey] = useState(0)
  const resetZoom = useCallback(() => setResetKey((k) => k + 1), [])
  const [touchUi] = useState(isTouchDevice)
  // 3D の上で 2 本指のときは、画面のスクロールを止めて、ピンチを 3D の拡大に使う
  // （touch-action: pan-y のままだと、2 本指を縦に動かしたときに画面がスクロールしてピンチが途切れる）
  const viewerBox = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = viewerBox.current
    if (!el) return
    const stop = (e: TouchEvent) => { if (e.touches.length >= 2) e.preventDefault() }
    el.addEventListener('touchstart', stop, { passive: false })
    el.addEventListener('touchmove', stop, { passive: false })
    return () => { el.removeEventListener('touchstart', stop); el.removeEventListener('touchmove', stop) }
  })
  const show3d = !!artwork?.model_url && !viewerFailed && view === '3d'
  const showing3d = show3d && viewerReady

  useEffect(() => {
    if (artwork?.model_url) {
      warmUp3D(null, [artwork.model_url])
    }
  }, [artwork?.model_url])

  const share = async () => {
    if (!artwork) return

    const url = window.location.href

    try {
      if (navigator.share) {
        await navigator.share({
          title: artwork.title,
          text: `${artwork.author_label}の作品「${artwork.title}」`,
          url,
        })
      } else {
        await navigator.clipboard.writeText(url)
        toast('リンクをコピーしました')
      }
    } catch {
      // 共有をキャンセルした場合
    }
  }

  const toggleDisplay = () => {
    if (!artwork) return

    display.mutate(
      {
        id: artwork.id,
        display: !artwork.displayed,
      },
      {
        onSuccess: (a) =>
          toast(
            a.displayed
              ? `${a.room_name ?? 'おうち'}に飾りました`
              : '飾るのをやめました',
          ),
        onError: (e) => toast(e.message),
      },
    )
  }

  if (detail.isError) {
    return (
      <Screen>
        <div className="page" style={{ paddingTop: 90 }}>
          <div className="empty">
            <p>作品が見つかりませんでした。</p>
            <button
              className="btn btn-outline btn-small"
              onClick={() => nav.tab('/collection')}
            >
              作品一覧へ
            </button>
          </div>
        </div>
      </Screen>
    )
  }

  return (
    <Screen>
      {/* ===== 作品画像 ===== */}
      <div className="detail-stage">
        <div className="stage-top">
          <GlassButton
            label="戻る"
            // 写真を出しているときだけ、一覧のサムネイルへつながって縮む。3D のときはつなぐ相手が無いので、
            // 一覧ごとまとめて動かす（サムネイルだけが別に浮いて見えないように）
            onClick={() =>
              nav.back('/collection', show3d ? undefined : artwork?.id)
            }
          >
            <BackIcon size={20} strokeWidth={2.2} />
          </GlassButton>

          <div className="stage-actions">
            <GlassButton label="共有" onClick={share}>
              <ShareIcon size={18} />
            </GlassButton>

            <GlassButton
              label="メニュー"
              onClick={() => setMenu(true)}
            >
              <MoreIcon size={20} />
            </GlassButton>
          </div>
        </div>

        {artwork && (
          // 3D で見るときは、読み込み中も写真は出さない（写真がちらっと見えてから 3D に変わらないように）。
          // 画面の移動で一覧のサムネイルから伸びる動き（data-share）も、写真を出すときだけにする
          <div className={`framed${show3d ? ' is-hidden' : ''}`} data-share={show3d ? undefined : artwork.id}>
            <img
              src={artwork.image_url}
              alt={artwork.title}
              decoding="async"
              width={artwork.image_width}
              height={artwork.image_height}
              style={{
                background: `${artwork.tint} url(${artwork.thumb_url}) center / cover no-repeat`,
              }}
            />
          </div>
        )}

        {/* 触って回せる 3D（読み込めたらふわっと出す） */}
        {artwork && show3d && (
          <div
            ref={viewerBox}
            className={`detail-viewer${viewerReady ? ' is-ready' : ''}`}
            aria-label={`${artwork.title}の3D。ドラッグで回せます。${touchUi ? '2本指で' : 'ホイールで'}拡大できます`}
            role="img"
            onDoubleClick={resetZoom}
          >
            <ErrorBoundary fallback={() => <ViewerFailed onFail={() => setViewerFailed(true)} />}>
              <Suspense fallback={null}>
                <ArtworkViewerScene
                  key={artwork.model_url}
                  modelUrl={artwork.model_url}
                  onReady={onViewerReady}
                  onInteract={onViewerTouch}
                  onZoomChange={setZoomed}
                  resetKey={resetKey}
                />
              </Suspense>
            </ErrorBoundary>
          </div>
        )}

        {artwork && show3d && !viewerReady && (
          <p className="detail-viewer-status" role="status">Loading…</p>
        )}
        {showing3d && !touched && (
          <p className="detail-viewer-hint" aria-hidden="true">{touchUi ? '指で回す・2本指で拡大' : 'ドラッグで回す・ホイールで拡大'}</p>
        )}
        {showing3d && zoomed && (
          <button type="button" className="detail-viewer-reset glass" onClick={resetZoom}>元の大きさ</button>
        )}

        {/* 3D と写真の切り替え */}
        {artwork?.model_url && !viewerFailed && (
          <div className="detail-view-switch glass" role="group" aria-label="表示の切り替え">
            <button type="button" aria-pressed={view === '3d'} onClick={() => setView('3d')}>3D</button>
            <button type="button" aria-pressed={view === 'photo'} onClick={() => setView('photo')}>写真</button>
          </div>
        )}
      </div>

      {/* ===== 作品情報 ===== */}
      {artwork && (
        <section className="caption memory-artwork-info">
          <div className="eyebrow num">
            <span>{artwork.catalog_label}</span>
            <span>{artwork.category_label}</span>
          </div>

          <div className="caption-head">
            <h2>{artwork.title}</h2>

            <button
              className={`heart${artwork.favorite ? ' on' : ''}`}
              aria-label={
                artwork.favorite
                  ? 'お気に入りを外す'
                  : 'お気に入りにする'
              }
              aria-pressed={artwork.favorite}
              onClick={() =>
                favorite.mutate({
                  id: artwork.id,
                  favorite: !artwork.favorite,
                })
              }
            >
              <HeartIcon
                size={24}
                filled={artwork.favorite}
              />
            </button>
          </div>

          {artwork.author_label && (
            <p className="author">
              {artwork.author_label}
            </p>
          )}

          <p className="memory-date num">
            {artwork.date_long}
          </p>
        </section>
      )}

      <div className="page memory-detail-body">
        {/* ===== 写真・動画・声・メモ ===== */}
        {artwork && (
          <MemorySection
            artworkId={artwork.id}
            memories={detail.data?.memories ?? []}
            memo={artwork.memo}
          />
        )}

        {/* ===== 展示 ===== */}
        {artwork && (
          <div className="memory-detail-actions">
            {artwork.displayed ? (
              <button
                className="btn btn-outline"
                onClick={() =>
                  nav.push(
                    `/museum?room=${artwork.room_id}&focus=${artwork.id}`,
                  )
                }
              >
                おうちで見る
              </button>
            ) : (
              <button
                className="btn btn-outline"
                onClick={toggleDisplay}
                disabled={display.isPending}
              >
                おうちに飾る
              </button>
            )}
          </div>
        )}

        {/* ===== 関連作品 ===== */}
        {related.length > 0 && (
          <section className="memory-related">
            <div className="section-head">
              <h2>関連する作品</h2>
            </div>

            <div className="grid-3">
              {related.slice(0, 3).map((a, i) => (
                <ArtworkThumb
                  key={a.id}
                  artwork={a}
                  index={i}
                />
              ))}
            </div>
          </section>
        )}
      </div>

      {/* ===== 作品メニュー ===== */}
      <ActionMenu
        open={menu}
        onClose={() => setMenu(false)}
        items={[
          {
            label: '編集',
            icon: <DocIcon size={19} />,
            onSelect: () =>
              nav.modal(`/artworks/${id}/edit`),
          },
          {
            label: artwork?.displayed
              ? '飾るのをやめる'
              : 'おうちに飾る',
            icon: <RainbowIcon size={19} />,
            onSelect: toggleDisplay,
          },
          {
            label: 'アルバムに入れる',
            icon: <GalleryIcon size={19} />,
            onSelect: () => setAlbumSheet(true),
          },
          {
            label: '削除',
            icon: <CloseIcon size={19} />,
            destructive: true,
            onSelect: () => setConfirmDelete(true),
          },
        ]}
      />

      {/* ===== アルバムに入れる ===== */}
      {artwork && <AlbumSheet open={albumSheet} onClose={() => setAlbumSheet(false)} artworkId={artwork.id} />}

      {/* ===== 削除確認 ===== */}
      <Sheet
        open={confirmDelete && !!artwork}
        onClose={() => setConfirmDelete(false)}
        title={`「${artwork?.title ?? ''}」を削除しますか？`}
      >
        <p
          className="hint"
          style={{
            textAlign: 'center',
            margin: '4px 8px 0',
          }}
        >
          写真と3Dモデルも削除され、
          おうちからも外れます。
          この操作は取り消せません。
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

          <button
            className="btn btn-gray"
            onClick={() => setConfirmDelete(false)}
          >
            キャンセル
          </button>
        </div>
      </Sheet>
    </Screen>
  )
}

/** 3D を表示できなかったとき：写真に戻す（描画中に親の state を変えないよう、effect で知らせる） */
function ViewerFailed({ onFail }: { onFail: () => void }) {
  useEffect(() => { onFail() }, [onFail])
  return null
}
