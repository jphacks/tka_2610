import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react'
import { useArtworkDigest, type ArtworkDigest, type DigestScope, type DigestSlide } from '../api'
import { BackIcon, ChevronRight, CloseIcon, GalleryIcon, MicIcon, PauseIcon, PlayIcon } from '../icons'
import { Segmented } from './Segmented'
import './DigestPlayer.css'

function SlideMedia({ slide, onReady, onError, onOpen }: { slide: DigestSlide; onReady: () => void; onError: () => void; onOpen: (id: string) => void }) {
  const settled = useRef(new Set<string>())
  const [failed, setFailed] = useState<string[]>([])
  const sources = slide.kind === 'comparison' ? [slide.first.image_url, slide.last.image_url] : [slide.kind === 'photo' ? slide.photo.url : slide.artwork.image_url]
  const done = (src: string) => {
    settled.current.add(src)
    if (settled.current.size === new Set(sources).size) onReady()
  }
  const media = (src: string, alt: string) => failed.includes(src)
    ? <div className="digest-image-failed"><GalleryIcon size={30} /><span>画像を読み込めませんでした</span></div>
    : <img className="digest-image" src={src} alt={alt} draggable={false} onLoad={() => done(src)} onError={() => { setFailed(list => [...list, src]); done(src); onError() }} />
  if (slide.kind === 'comparison') {
    return (
      <div className="digest-comparison">
        {[{ label: 'はじめの作品', a: slide.first }, { label: '最近の作品', a: slide.last }].map(({ label, a }) => (
          <button type="button" key={a.id} className="digest-compare-work" onClick={() => onOpen(a.id)}>
            <span>{label}</span><div className="digest-compare-image">{media(a.image_url, a.title)}</div>
            <strong>{a.title}</strong><small>{a.age_month_label ?? a.date_short}</small>
          </button>
        ))}
      </div>
    )
  }
  return <div className="digest-single">{media(sources[0], slide.kind === 'photo' ? slide.photo.caption || 'おもいでの写真' : slide.artwork.title)}</div>
}

function Playback({ digest, onOpen }: { digest: ArtworkDigest; onOpen: (id: string) => void }) {
  const [index, setIndex] = useState(0)
  const [playing, setPlaying] = useState(true)
  const [ready, setReady] = useState(false)
  const [finished, setFinished] = useState(false)
  const [voiceEnabled, setVoiceEnabled] = useState(false)
  const [voiceError, setVoiceError] = useState('')
  const [progress, setProgress] = useState(0)
  const elapsed = useRef(0)
  const audio = useRef<HTMLAudioElement>(null)
  const slide = digest.slides[index]
  const voice = slide.kind === 'artwork' ? slide.voice : null
  const advance = useCallback((next: number) => {
    audio.current?.pause()
    elapsed.current = 0
    setProgress(0)
    setReady(false)
    setFinished(false)
    setVoiceError('')
    setIndex(next)
  }, [])
  const onReady = useCallback(() => setReady(true), [])
  const onImageError = useCallback(() => setPlaying(false), [])

  useEffect(() => {
    if (!playing || !ready || finished) return
    const started = performance.now()
    const before = elapsed.current
    const timer = window.setInterval(() => {
      elapsed.current = Math.min(before + performance.now() - started, slide.duration_ms)
      setProgress(elapsed.current / slide.duration_ms)
      if (elapsed.current >= slide.duration_ms) {
        window.clearInterval(timer)
        if (index + 1 < digest.slides.length) advance(index + 1)
        else { setPlaying(false); setFinished(true); audio.current?.pause() }
      }
    }, 50)
    return () => window.clearInterval(timer)
  }, [playing, ready, finished, index, slide.duration_ms, digest.slides.length, advance])

  useEffect(() => {
    const element = audio.current
    if (!element) return
    let active = true
    if (voiceEnabled && voice && playing && ready && !finished) {
      void element.play().catch(() => { if (active) setVoiceError('声を流すには「声を再生」を押してください。') })
    } else element.pause()
    return () => { active = false; element.pause() }
  }, [voiceEnabled, voice?.url, playing, ready, finished])

  useEffect(() => {
    const element = audio.current
    const hide = () => { if (document.hidden) { setPlaying(false); element?.pause() } }
    document.addEventListener('visibilitychange', hide)
    return () => { document.removeEventListener('visibilitychange', hide); element?.pause() }
  }, [])

  useEffect(() => {
    const next = digest.slides[index + 1]
    if (!next) return
    const image = new Image()
    image.src = next.kind === 'comparison' ? next.first.image_url : next.kind === 'photo' ? next.photo.url : next.artwork.image_url
  }, [index, digest])

  const togglePlaying = () => {
    if (finished) { advance(0); setPlaying(true); return }
    if (playing) audio.current?.pause()
    else if (voiceEnabled && voice && ready) void audio.current?.play().catch(() => setVoiceError('声を流すには「声を再生」を押してください。'))
    setPlaying(!playing)
  }
  const toggleVoice = () => {
    const next = !voiceEnabled
    setVoiceEnabled(next)
    setVoiceError('')
    if (!next) audio.current?.pause()
    else if (voice && playing && ready) void audio.current?.play().catch(() => setVoiceError('声を流すには「声を再生」を押してください。'))
  }
  const artwork = slide.kind === 'comparison' ? slide.last : slide.artwork
  return (
    <div className={`digest-playback${playing ? ' playing' : ' paused'}`} style={{ '--digest-duration': `${slide.duration_ms}ms` } as CSSProperties}
      onKeyDown={event => {
        if (event.key === 'ArrowLeft' && index > 0) { event.preventDefault(); advance(index - 1) }
        if (event.key === 'ArrowRight' && index + 1 < digest.slides.length) { event.preventDefault(); advance(index + 1) }
      }}>
      <div className="digest-progress" role="progressbar" aria-label="ダイジェストの進み具合" aria-valuemin={0} aria-valuemax={digest.slides.length} aria-valuenow={index + progress}>
        {digest.slides.map((_, i) => <span key={i}><i style={{ transform: `scaleX(${i < index ? 1 : i === index ? progress : 0})` }} /></span>)}
      </div>
      <div className="digest-heading"><div><h2>{digest.title}</h2><p>{digest.period_label}</p></div><span className="num">{index + 1} / {digest.slides.length}</span></div>
      <div className="digest-stage" aria-busy={!ready}>
        <SlideMedia key={index} slide={slide} onReady={onReady} onError={onImageError} onOpen={onOpen} />
        {!ready && <span className="digest-loading-label">Loading…</span>}
      </div>
      <div className="digest-caption" aria-live="polite">
        <p className="digest-slide-label">{slide.kind === 'comparison' ? 'はじめと最近' : slide.kind === 'photo' ? 'おもいでの写真' : artwork.age_month_label ?? artwork.date_short}</p>
        <h3>{slide.kind === 'comparison' ? '並べて振り返る' : artwork.title}</h3>
        {slide.kind !== 'comparison' && <p className="digest-date">{artwork.date_long}</p>}
        {slide.kind === 'photo' && slide.photo.caption && <p className="digest-memo">{slide.photo.caption}</p>}
        {slide.kind === 'artwork' && artwork.memo && <p className="digest-memo">{artwork.memo}</p>}
      </div>
      <audio ref={audio} src={voice?.url} preload="none" />
      <div className="digest-controls">
        <button type="button" className="digest-round" aria-label="前の場面" disabled={index === 0} onClick={() => advance(index - 1)}><BackIcon size={21} /></button>
        <button type="button" className="digest-play" onClick={togglePlaying} aria-label={finished ? 'もう一度再生' : playing ? '一時停止' : '再生'}>{playing ? <PauseIcon size={23} /> : <PlayIcon size={23} />}<span>{finished ? 'もう一度' : playing ? '一時停止' : '再生'}</span></button>
        <button type="button" className="digest-round" aria-label="次の場面" disabled={index + 1 === digest.slides.length} onClick={() => advance(index + 1)}><ChevronRight size={21} /></button>
      </div>
      <div className="digest-actions">
        <button type="button" className="digest-voice-toggle" aria-pressed={voiceEnabled} onClick={toggleVoice}><MicIcon size={16} />{voiceEnabled ? '声あり' : '声なし'}</button>
        <button type="button" className="digest-open" onClick={() => { setPlaying(false); audio.current?.pause(); onOpen(artwork.id) }}>この作品のおもいで<ChevronRight size={14} /></button>
      </div>
      {voiceEnabled && <p className="digest-voice-note">声のある作品では、録音の冒頭を流します。</p>}
      {voiceError && <div className="digest-voice-error" role="status"><span>{voiceError}</span><button type="button" onClick={() => { void audio.current?.play().then(() => { setVoiceError(''); setPlaying(true) }).catch(() => setVoiceError('この声を再生できませんでした。作品の詳細からもお試しください。')) }}>声を再生</button></div>}
    </div>
  )
}

export function DigestPlayer({ initialScope, onClose, onOpenArtwork }: { initialScope: DigestScope; onClose: () => void; onOpenArtwork: (id: string) => void }) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [scope, setScope] = useState<DigestScope>(initialScope)
  const [drawingsOnly, setDrawingsOnly] = useState(false)
  const query = useArtworkDigest(scope, drawingsOnly)
  useEffect(() => {
    const element = dialog.current
    element?.showModal()
    return () => element?.close()
  }, [])
  return (
    <dialog ref={dialog} className="digest-dialog" aria-label="作品のダイジェスト" onCancel={event => { event.preventDefault(); onClose() }}>
      <div className="digest-top"><span>作品のダイジェスト</span><button type="button" className="digest-round" aria-label="ダイジェストを閉じる" onClick={onClose}><CloseIcon size={21} /></button></div>
      <div className="digest-options"><Segmented<DigestScope> label="ダイジェストの期間" options={[{ value: 'all', label: 'これまで' }, { value: 'year', label: 'この1年' }]} value={scope} onChange={setScope} /><button type="button" className="digest-drawing-filter" aria-pressed={drawingsOnly} onClick={() => setDrawingsOnly(!drawingsOnly)}>絵画だけ</button></div>
      {query.isPending ? <div className="digest-state" aria-busy="true"><PlayIcon size={30} /><p>Loading…</p></div>
        : query.isError ? <div className="digest-state" role="alert"><p>{query.error.message}</p><button type="button" onClick={() => query.refetch()}>もう一度読み込む</button></div>
          : query.data?.slides.length ? <Playback key={`${scope}-${drawingsOnly}-${query.dataUpdatedAt}`} digest={query.data} onOpen={onOpenArtwork} />
            : <div className="digest-state"><GalleryIcon size={32} /><h2>この条件の作品はまだありません</h2><p>期間や「絵画だけ」の選択を変えてお試しください。</p></div>}
    </dialog>
  )
}
