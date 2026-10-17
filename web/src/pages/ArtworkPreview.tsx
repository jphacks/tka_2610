// ④ 3D プレビュー（/artworks/:id/preview）。モーダルで下から開く。
// 台座の上で作品が回る。「この作品を展示する」で博物館に飾り、⑤ 博物館の中へ進む。
import { Suspense, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useArtwork, useDisplay, useMuseum } from '../api'
import { GlassButton, Screen, useToast } from '../components'
import { CloseIcon, ExpandIcon } from '../icons'
import { useNav } from '../nav'
import { PreviewScene, StageShell } from '../three'
import './ArtworkPreview.css'

export default function ArtworkPreview() {
  const { id = '' } = useParams()
  const nav = useNav()
  const toast = useToast()
  const museum = useMuseum()
  const detail = useArtwork(id)
  const display = useDisplay()
  const [ready, setReady] = useState(false)
  const stageRef = useRef<HTMLDivElement>(null)
  const artwork = detail.data?.artwork

  const exhibit = () => {
    if (!artwork) return
    if (artwork.displayed) return nav.push(`/museum?focus=${artwork.id}`)
    display.mutate(
      { id: artwork.id, display: true },
      {
        onSuccess: (a) => {
          toast(`${a.room_name ?? '博物館'}に展示しました`)
          nav.push(`/museum?focus=${a.id}`)
        },
        onError: (e) => toast(e.message),
      },
    )
  }

  const toggleFullscreen = () => {
    if (document.fullscreenElement) document.exitFullscreen()
    else stageRef.current?.requestFullscreen?.()
  }

  return (
    <Screen>
      <div ref={stageRef} style={{ position: 'relative' }}>
        <StageShell
          className="preview-stage"
          ready={ready || (!!museum.data && !museum.data.model_url)}
          label="3Dにしています…"
          overlay={
            <div className="stage-top">
              <GlassButton label="閉じる" onClick={() => nav.dismiss(`/artworks/${id}`)}>
                <CloseIcon size={19} strokeWidth={2.2} />
              </GlassButton>
              <span className="stage-title glass">3Dプレビュー</span>
              <GlassButton label="全画面表示" onClick={toggleFullscreen}>
                <ExpandIcon size={18} />
              </GlassButton>
            </div>
          }
        >
          {museum.data && artwork && (
            <Suspense fallback={null}>
              <PreviewScene museum={museum.data} modelUrl={artwork.model_url} onReady={() => setReady(true)} />
            </Suspense>
          )}
        </StageShell>
      </div>

      {artwork && (
        <section className="caption">
          <div className="eyebrow num">
            <span>{artwork.catalog_label}</span>
            <span>{artwork.category_label}</span>
          </div>
          <div className="caption-head">
            <h2>{artwork.title}</h2>
          </div>
          <p className="author num">
            {[artwork.author_label, artwork.date_long].filter(Boolean).join('　')}
          </p>
          {artwork.memo && <p className="memo">{artwork.memo}</p>}
          <div style={{ marginTop: 24 }}>
            <button className="btn btn-filled" onClick={exhibit} disabled={display.isPending}>
              {artwork.displayed
                ? `${artwork.room_name ?? '博物館'}で見る`
                : display.isPending
                  ? '展示しています…'
                  : 'この作品を展示する'}
            </button>
          </div>
        </section>
      )}
      <div style={{ height: 28 }} />
    </Screen>
  )
}
