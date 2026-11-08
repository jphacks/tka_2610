// ⑦ memoria（/map）。作品・写真・声を手がかりに振り返る。作品の選択はRust。
import { useEffect, useRef, useState, type SyntheticEvent } from 'react'
import { useRecollections, type DigestScope, type Memory, type RecallCard } from '../api'
import { DigestPlayer, Img, NavBar, Screen, ThumbSkeletons, TLink } from '../components'
import { ChevronRight, GalleryIcon, MicIcon, PlayIcon } from '../icons'
import { useNav } from '../nav'
import DigestTheater from './DigestTheater'
import './MapView.css'

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

export default function MapView() {
  const [theaterExpanded, setTheaterExpanded] = useState(false)
  const [digestScope, setDigestScope] = useState<DigestScope | null>(null)
  const recalls = useRecollections()
  const nav = useNav()
  const data = recalls.data
  const featured = data?.featured
  const playing = useRef<HTMLAudioElement | null>(null)
  useEffect(() => () => { playing.current?.pause() }, [])
  useEffect(() => { if (recalls.isError) playing.current?.pause() }, [recalls.isError])
  const onPlay = (event: SyntheticEvent<HTMLAudioElement>) => {
    if (playing.current && playing.current !== event.currentTarget) playing.current.pause()
    playing.current = event.currentTarget
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
            <DigestTheater embedded onExpandedChange={setTheaterExpanded} suspended={digestScope !== null} onStart={() => playing.current?.pause()} />
            <details className="recall-slideshow"><summary>スライドショーで振り返る</summary>
            <section className="recall-digest" aria-labelledby="recall-digest-title">
              <div><span className="recall-digest-mark"><PlayIcon size={17} /></span><h1 id="recall-digest-title">作品のダイジェスト</h1></div>
              <p>昔から今へ。作品とおもいでを、続けて振り返る。</p>
              <div className="recall-digest-buttons">
                <button type="button" onClick={() => { playing.current?.pause(); setDigestScope('all') }}><PlayIcon size={15} />これまで</button>
                <button type="button" onClick={() => { playing.current?.pause(); setDigestScope('year') }}><PlayIcon size={15} />この1年</button>
              </div>
            </section>
            </details>
            {featured && (
              <section className="recall-section" aria-labelledby="recall-moment-title">
                <div className="recall-section-head"><h2 id="recall-moment-title">{data.moment_title}</h2><span>今日のひとつ</span></div>
                <article className="recall-hero">
                  <TLink to={`/artworks/${featured.artwork.id}`} className={`recall-hero-images${featured.photo ? ' with-photo' : ''}`}>
                    <Img src={featured.artwork.image_url} tint={featured.artwork.tint} alt={featured.artwork.title} eager />
                    {featured.photo && <div className="recall-photo"><Img src={featured.photo.thumb_url ?? featured.photo.url} alt={featured.photo.caption || '作品に残したおもいでの写真'} eager /><span>おもいでの写真</span></div>}
                  </TLink>
                  <div className="recall-hero-caption">
                    <p className="recall-date">{featured.artwork.date_long}{featured.artwork.age_month_label && <span>{featured.artwork.age_month_label}</span>}</p>
                    <h2><TLink to={`/artworks/${featured.artwork.id}`}>{featured.artwork.title}</TLink></h2>
                    {featured.artwork.memo && <p className="recall-hero-memo">{featured.artwork.memo}</p>}
                    {featured.voice && <RecallVoice memory={featured.voice} title={featured.artwork.title} onPlay={onPlay} />}
                    <TLink to={`/artworks/${featured.artwork.id}`} className="recall-open">作品とおもいでを見る<ChevronRight size={15} /></TLink>
                  </div>
                </article>
                <p className="recall-selection-note">{data.moment_note}</p>
                {data.moments.length > 0 && <div className="recall-strip" aria-label="同じころの作品">{data.moments.map(card => <RecallTile key={card.artwork.id} card={card} onPlay={onPlay} />)}</div>}
              </section>
            )}

            <section className="recall-section" aria-labelledby="recall-voices-title">
              <div className="recall-section-head"><h2 id="recall-voices-title"><MicIcon size={18} />声が残っている作品</h2></div>
              {data.voices.length > 0 ? (
                <div className="recall-strip recall-voice-strip">{data.voices.map(card => <RecallTile key={card.artwork.id} card={card} voice onPlay={onPlay} />)}</div>
              ) : <div className="recall-voice-empty"><p>声の記録はまだありません</p><span>作品の詳細の「おもいで」から、声を録音して残せます。</span></div>}
            </section>

          </>
        )}

      </div>
      {digestScope && <DigestPlayer initialScope={digestScope} onClose={() => setDigestScope(null)} onOpenArtwork={id => { setDigestScope(null); nav.push(`/artworks/${id}`) }} />}
    </Screen>
  )
}
