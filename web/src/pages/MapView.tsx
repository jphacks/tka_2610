// ⑦ memoria（/map）。作品・写真・声を手がかりに振り返る。作品の選択はRust。
import { Suspense, useCallback, useEffect, useRef, useState, type ReactNode, type SyntheticEvent } from 'react'
import { useRecollections, type Memory, type RecallCard } from '../api'
import { DigestPlayer, ErrorBoundary, Img, NavBar, Screen, ThumbSkeletons, TLink } from '../components'
import { ArtworkViewerScene, StageShell } from '../three'
import { BackIcon, GalleryIcon, MicIcon, PlayIcon, VideoIcon } from '../icons'
import { useNav } from '../nav'
import DigestTheater from './DigestTheater'
import './MapView.css'

function RecallModel({ card }: { card: RecallCard }) {
  const [ready, setReady] = useState(false)
  const onReady = useCallback(() => setReady(true), [])
  const a = card.artwork
  const image = <div><Img src={a.image_url} tint={a.tint} alt={a.title} eager /></div>
  if (!a.model_url) return image
  return (
    <ErrorBoundary fallback={() => image}>
      <StageShell className="recall-model" ready={ready}>
        <Suspense fallback={null}>
          <ArtworkViewerScene modelUrl={a.model_url} onReady={onReady} />
        </Suspense>
      </StageShell>
    </ErrorBoundary>
  )
}

function RecallVoice({ memory, title, onPlay }: { memory: Memory; title: string; onPlay: (event: SyntheticEvent<HTMLAudioElement>) => void }) {
  return (
    <div className="recall-voice">
      <span><MicIcon size={14} />{memory.caption || '残してある声'}</span>
      <audio controls preload="none" src={memory.url} aria-label={`「${title}」に残っている声`} onPlay={onPlay} />
    </div>
  )
}

function RecallTile({ card, voice = false, onPlay }: { card: RecallCard; voice?: boolean; onPlay: (event: SyntheticEvent<HTMLAudioElement>) => void }) {
  const a = card.artwork
  return (
    <article className="recall-tile">
      <TLink to={`/artworks/${a.id}`}>
        <Img src={a.image_url} tint={a.tint} alt={a.title} />
        <div className="recall-tile-caption">
          <p className="recall-date">{a.age_month_label ?? a.date_short}</p>
          <h3>{a.title}</h3>
          {a.memo && <p className="recall-tile-memo">{a.memo}</p>}
        </div>
      </TLink>
      {voice && card.voice && <RecallVoice memory={card.voice} title={a.title} onPlay={onPlay} />}
    </article>
  )
}

/** 段をたたんだかを覚える（この端末の localStorage。読めなくても、開いたまま使える） */
function readFolded(key: string) {
  try {
    return localStorage.getItem(key) === '1'
  } catch {
    return false
  }
}

function writeFolded(key: string, folded: boolean) {
  try {
    localStorage.setItem(key, folded ? '1' : '0')
  } catch {
    /* 覚えられなくても、今の画面ではたためる */
  }
}

/**
 * 作品一覧のアルバムの棚と同じように、見出しの横の矢印でたたむ・開く段。
 * 最初は開いていて、たたんだかはこの端末に覚える。たたむときは、中で鳴っている声を止める。
 */
function FoldSection({ id, storageKey, icon, title, count, onFold, children }: {
  id: string
  storageKey: string
  icon: ReactNode
  title: string
  count: number
  onFold: (body: HTMLElement) => void
  children: ReactNode
}) {
  const [folded, setFolded] = useState(() => readFolded(storageKey))
  const body = useRef<HTMLDivElement>(null)
  const toggle = () => {
    if (!folded && body.current) onFold(body.current)
    setFolded(!folded)
    writeFolded(storageKey, !folded)
  }
  return (
    <section className={`recall-section recall-fold${folded ? ' is-folded' : ''}`} aria-labelledby={`${id}-title`}>
      <div className="recall-section-head">
        <h2 id={`${id}-title`}>
          <button type="button" className="recall-fold-toggle" aria-expanded={!folded} aria-controls={`${id}-body`} onClick={toggle}>
            {icon}{title}
            {count > 0 && <span className="recall-fold-count num" aria-label={`${count}こ`}>{count}</span>}
            <BackIcon size={16} strokeWidth={2.4} className="recall-fold-arrow" aria-hidden="true" />
          </button>
        </h2>
      </div>
      <div id={`${id}-body`} ref={body} className="recall-fold-body" aria-hidden={folded} inert={folded}>
        <div>{children}</div>
      </div>
    </section>
  )
}

export default function MapView() {
  const [todayOpen, setTodayOpen] = useState(false)
  const [theaterExpanded, setTheaterExpanded] = useState(false)
  const recalls = useRecollections()
  const nav = useNav()
  const data = recalls.data
  const featured = data?.featured
  const videos = data?.videos ?? []
  const playing = useRef<HTMLAudioElement | null>(null)
  useEffect(() => () => { playing.current?.pause() }, [])
  useEffect(() => { if (recalls.isError) playing.current?.pause() }, [recalls.isError])
  const onPlay = (event: SyntheticEvent<HTMLAudioElement>) => {
    if (playing.current && playing.current !== event.currentTarget) playing.current.pause()
    playing.current = event.currentTarget
  }
  const pauseInside = (body: HTMLElement) => {
    if (playing.current && body.contains(playing.current)) playing.current.pause()
  }

  return (
    <Screen tabbar className={`recall-screen${theaterExpanded ? ' is-viewing-theater' : ''}`}>
      <NavBar title="memoria" />
      <div className="page recall-page">
        {recalls.isPending ? (
          <div className="recall-loading" aria-busy="true" aria-label="Loading…"><div className="recall-hero-placeholder skeleton" /><div className="recall-loading-grid"><ThumbSkeletons count={4} /></div></div>
        ) : recalls.isError ? (
          <div className="recall-empty" role="alert"><h2>思い出を読み込めませんでした</h2><p>{recalls.error.message}</p><button type="button" className="btn btn-outline" onClick={() => recalls.refetch()}>もう一度読み込む</button></div>
        ) : data?.total === 0 ? (
          <div className="recall-empty"><GalleryIcon size={30} /><h2>まだ振り返る作品がありません</h2><p>作品と一緒に、写真や声も残せます。登録した作品がここに並びます。</p><button type="button" className="btn btn-filled" onClick={() => nav.modal('/add')}>作品を追加</button></div>
        ) : data && (
          <>
            {featured && (
              <section className="recall-section" aria-labelledby="recall-moment-title">
                <div className="recall-section-head"><h2 id="recall-moment-title">今日の作品</h2><span>{data.moment_title}</span></div>
                <article className="recall-hero">
                  <div className={`recall-hero-images${featured.photo ? ' with-photo' : ''}`}>
                    <RecallModel key={`${featured.artwork.id}:${featured.artwork.model_url}`} card={featured} />
                    {featured.photo && <div className="recall-photo"><Img src={featured.photo.thumb_url ?? featured.photo.url} alt={featured.photo.caption || '作品に残したおもいでの写真'} eager /><span>おもいでの写真</span></div>}
                  </div>
                  <div className="recall-hero-caption">
                    <p className="recall-date">{featured.artwork.date_long}{featured.artwork.age_month_label && <span>{featured.artwork.age_month_label}</span>}</p>
                    {featured.voice && <RecallVoice memory={featured.voice} title={featured.artwork.title} onPlay={onPlay} />}
                    <button type="button" className="recall-open" aria-label="今日の作品を再生" onClick={() => { playing.current?.pause(); setTodayOpen(true) }}><PlayIcon size={22} /></button>
                  </div>
                </article>
                <p className="recall-selection-note">{data.moment_note}</p>
                {data.moments.length > 0 && <div className="recall-strip" aria-label="同じころの作品">{data.moments.map(card => <RecallTile key={card.artwork.id} card={card} onPlay={onPlay} />)}</div>}
              </section>
            )}
            <DigestTheater embedded onExpandedChange={setTheaterExpanded} suspended={todayOpen} onStart={() => playing.current?.pause()} />
            <FoldSection id="recall-voices" storageKey="memoria.voices-folded" icon={<MicIcon size={18} />} title="音声が残ってる作品" count={data.voices.length} onFold={pauseInside}>
              {data.voices.length > 0 ? (
                <div className="recall-strip recall-voice-strip">{data.voices.map(card => <RecallTile key={card.artwork.id} card={card} voice onPlay={onPlay} />)}</div>
              ) : <div className="recall-voice-empty"><p>声の記録はまだありません</p><span>作品の詳細の「おもいで」から、声を録音して残せます。</span></div>}
            </FoldSection>
            <FoldSection id="recall-videos" storageKey="memoria.videos-folded" icon={<VideoIcon size={18} />} title="作品にまつわる動画" count={videos.length} onFold={pauseInside}>
              {videos.length > 0 ? (
                <div className="recall-strip recall-video-strip">
                  {videos.map(({ artwork, video }) => (
                    <article className="recall-tile" key={video.id}>
                      <TLink to={`/artworks/${artwork.id}`} className="recall-video-link" aria-label={`「${artwork.title}」の作品を見る`} onClick={() => playing.current?.pause()}>
                        <video src={`${video.url}#t=0.1`} poster={video.thumb_url ?? undefined} preload="metadata" muted playsInline tabIndex={-1} aria-hidden="true" />
                      </TLink>
                    </article>
                  ))}
                </div>
              ) : <div className="recall-voice-empty"><p>動画の記録はまだありません</p><span>作品の詳細の「おもいで」から、動画を残せます。</span></div>}
            </FoldSection>
          </>
        )}

      </div>
      {todayOpen && <DigestPlayer initialScope="all" threeD onClose={() => setTodayOpen(false)} onOpenArtwork={id => { setTodayOpen(false); nav.push(`/artworks/${id}`) }} />}
    </Screen>
  )
}
