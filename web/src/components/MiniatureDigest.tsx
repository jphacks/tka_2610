import { Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useMiniatureDigest, type DigestScope, type MiniatureDigestData } from '../api'
import { BackIcon, ChevronRight, CloseIcon, MicIcon, PauseIcon, PlayIcon } from '../icons'
import { MiniatureScene, StageShell } from '../three'
import { ErrorBoundary } from './ErrorBoundary'
import { MemoryViewer } from './MemoryViewer'
import { Segmented } from './Segmented'
import './MiniatureDigest.css'

function MiniaturePlayback({ data, onOpenArtwork, onAudioPlay, onStart, suspended, revision }: { revision: string; data: MiniatureDigestData; onOpenArtwork: (id: string) => void; onAudioPlay: (audio: HTMLAudioElement) => void; onStart: () => void; suspended: boolean }) {
  const [turn, setTurn] = useState(0)
  const [started, setStarted] = useState(false)
  const [playing, setPlaying] = useState(false)
  const [arrived, setArrived] = useState(false)
  const [finished, setFinished] = useState(false)
  const [sceneReady, setSceneReady] = useState(false)
  const [fullscreen, setFullscreen] = useState(false)
  const [loaded, setLoaded] = useState<Record<string, boolean>>({})
  const [progress, setProgress] = useState(0)
  const [voicePlaying, setVoicePlaying] = useState(false)
  const [voiceError, setVoiceError] = useState('')
  const [photoIndex, setPhotoIndex] = useState<number | null>(null)
  const [photoArtworkId, setPhotoArtworkId] = useState<string | null>(null)
  const [reducedMotion, setReducedMotion] = useState(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)
  const container = useRef<HTMLDialogElement>(null)
  const audio = useRef<HTMLAudioElement>(null)
  const elapsed = useRef(0)
  const currentTurn = useRef(turn)
  currentTurn.current = turn
  const count = data.entries.length
  const index = ((turn % count) + count) % count
  const active = data.entries[index]
  const photoEntry = data.entries.find(entry => entry.artwork.id === photoArtworkId)
  const modelReady = loaded[active.artwork.id] !== undefined
  const palette = useMemo(() => {
    const style = getComputedStyle(document.documentElement)
    const color = (name: string) => style.getPropertyValue(name).trim()
    return { paper: color('--paper'), surface: color('--surface'), earth: color('--sage'), ink: color('--ink') }
  }, [])

  const modelSettled = useCallback((id: string, fallback: boolean) => setLoaded(before => before[id] === fallback ? before : { ...before, [id]: fallback }), [])
  const sceneMounted = useCallback(() => setSceneReady(true), [])
  const onArrive = useCallback((value: number) => { if (value === currentTurn.current) setArrived(true) }, [])
  const stopVoice = useCallback(() => { audio.current?.pause(); setVoicePlaying(false) }, [])
  const closeFullscreen = useCallback(() => {
    stopVoice()
    setPlaying(false)
    setFullscreen(false)
    setPhotoIndex(null)
    const dialog = container.current
    if (dialog?.matches(':modal')) { dialog.close(); dialog.show() }
    dialog?.querySelector<HTMLButtonElement>('.miniature-play')?.focus({ preventScroll: true })
  }, [stopVoice])
  const enterFullscreen = () => {
    const dialog = container.current
    if (!dialog || dialog.matches(':modal')) return
    // 同じCanvasを維持したままブラウザの最前面へ移す。iPhoneでも使える。
    dialog.close()
    dialog.showModal()
    setFullscreen(true)
  }
  useEffect(() => {
    if (!fullscreen) return
    const before = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = before }
  }, [fullscreen])
  useLayoutEffect(() => {
    stopVoice()
    elapsed.current = 0
    setTurn(0)
    setStarted(false)
    setPlaying(false)
    setArrived(false)
    setFinished(false)
    setProgress(0)
    setVoiceError('')
    setPhotoIndex(null)
  }, [revision, stopVoice])
  useEffect(() => { if (suspended) { setPlaying(false); stopVoice() } }, [suspended, stopVoice])
  const move = useCallback((delta: number) => {
    stopVoice()
    elapsed.current = 0
    setProgress(0)
    setArrived(false)
    setFinished(false)
    setVoiceError('')
    setTurn(before => before + delta)
  }, [stopVoice])
  const openArtwork = useCallback((id: string) => { closeFullscreen(); onOpenArtwork(id) }, [closeFullscreen, onOpenArtwork])
  const openPhoto = useCallback((artworkId: string, photo: number) => { stopVoice(); setPlaying(false); setPhotoArtworkId(artworkId); setPhotoIndex(photo) }, [stopVoice])

  useEffect(() => {
    if (!playing || !arrived || !modelReady || voicePlaying || finished || photoIndex !== null) return
    const before = elapsed.current
    const start = performance.now()
    const timer = window.setInterval(() => {
      elapsed.current = Math.min(active.hold_ms, before + performance.now() - start)
      setProgress(elapsed.current / active.hold_ms)
      if (elapsed.current >= active.hold_ms) {
        window.clearInterval(timer)
        if (index + 1 < count) move(1)
        else { stopVoice(); setPlaying(false); setFinished(true) }
      }
    }, 80)
    return () => window.clearInterval(timer)
  }, [playing, arrived, modelReady, voicePlaying, finished, photoIndex, active.hold_ms, index, count, move, stopVoice])

  useEffect(() => {
    const element = audio.current
    const pause = () => { setPlaying(false); element?.pause() }
    const hide = () => { if (document.hidden) pause() }
    const observer = new IntersectionObserver(entries => { if (!entries[0].isIntersecting) pause() }, { threshold: 0.05 })
    if (container.current) observer.observe(container.current)
    document.addEventListener('visibilitychange', hide)
    const media = window.matchMedia('(prefers-reduced-motion: reduce)')
    const changed = () => setReducedMotion(media.matches)
    media.addEventListener('change', changed)
    return () => { observer.disconnect(); document.removeEventListener('visibilitychange', hide); media.removeEventListener('change', changed); element?.pause() }
  }, [])

  const toggle = () => {
    if (!fullscreen) enterFullscreen()
    if (!playing) onStart()
    if (finished) { move(count - index); setStarted(true); setPlaying(true); return }
    setStarted(true)
    if (playing) stopVoice()
    setPlaying(before => !before)
  }
  const playVoice = () => {
    const element = audio.current
    if (!element) return
    if (voicePlaying) { stopVoice(); return }
    setVoiceError('')
    setVoicePlaying(true)
    void element.play().catch(() => { setVoicePlaying(false); setVoiceError('この声を再生できませんでした。作品の詳細からもお試しください。') })
  }
  const status = finished ? '見終わりました' : !started ? 'タップして再生' : !playing ? '一時停止中' : !arrived ? '次の作品へ' : !modelReady ? '3Dを読み込み中' : voicePlaying ? '声を聴いています' : 'おもいでを振り返っています'

  return (
    <dialog open className="miniature-playback" ref={container} role={fullscreen ? 'dialog' : 'region'} aria-modal={fullscreen || undefined} aria-label="作品と思い出の3D鑑賞"
      onKeyDown={event => { if (event.key === 'Escape' && photoIndex !== null) { event.preventDefault(); event.stopPropagation(); setPhotoIndex(null) } }}
      onCancel={event => { event.preventDefault(); if (photoIndex !== null) setPhotoIndex(null); else closeFullscreen() }}>
      {fullscreen && <div className="miniature-fullscreen-heading"><span>作品と思い出</span><button type="button" aria-label="全画面を閉じる" onClick={closeFullscreen}><CloseIcon size={24} /></button></div>}
      <div className="miniature-period"><span>{data.title}</span><small>{data.duration_label} · {index + 1} / {count}点</small></div>
      <ErrorBoundary fallback={() => <div className="miniature-error"><p>この端末では3Dを表示できませんでした。</p><button type="button" className="btn btn-outline btn-small" onClick={() => openArtwork(active.artwork.id)}>作品を開く</button></div>}>
        <StageShell className="miniature-stage" ready={sceneReady} label="ミニチュアを準備しています…">
          <Suspense fallback={null}>
            <MiniatureScene revision={revision} entries={data.entries} turn={turn} playing={playing && !voicePlaying} transitionMs={data.transition_ms}
              onArrive={onArrive} onModelReady={modelSettled} onArtwork={openArtwork} onPhoto={openPhoto} onReady={sceneMounted} reducedMotion={reducedMotion} palette={palette} />
          </Suspense>
          {!fullscreen && sceneReady && <button type="button" className="miniature-start" aria-label="3Dダイジェストを全画面で再生" onClick={() => { if (!playing) toggle() }}><span><PlayIcon size={24} /></span><strong>タップして全画面で再生</strong></button>}
        </StageShell>
      </ErrorBoundary>
      <div className="miniature-progress" role="progressbar" aria-label="3Dダイジェストの進み具合" aria-valuemin={0} aria-valuemax={count} aria-valuenow={index + progress}>
        {data.entries.map((entry, i) => <span key={entry.artwork.id}><i style={{ transform: `scaleX(${i < index ? 1 : i === index ? progress : 0})` }} /></span>)}
      </div>
      <div className="miniature-caption"><p className="miniature-status" aria-live="polite">{status}</p><button type="button" onClick={() => openArtwork(active.artwork.id)}><strong>{active.artwork.title}</strong><ChevronRight size={14} /></button><small>{active.artwork.age_month_label ?? active.artwork.date_short}<span>{active.artwork.date_long}</span></small></div>
      <div className="miniature-controls">
        <button type="button" className="miniature-arrow" aria-label="前の作品" disabled={index === 0} onClick={() => { enterFullscreen(); setStarted(true); move(-1) }}><BackIcon size={20} /></button>
        <button type="button" className="miniature-play" onClick={toggle} aria-label={finished ? '3Dダイジェストをもう一度' : !started ? '3Dダイジェストを再生' : playing ? '3Dダイジェストを一時停止' : '3Dダイジェストを再開'}>{playing ? <PauseIcon size={18} /> : <PlayIcon size={18} />}{finished ? 'もう一度' : playing ? '一時停止' : started ? '再開' : '再生'}</button>
        <button type="button" className="miniature-arrow" aria-label="次の作品" disabled={index + 1 === count} onClick={() => { enterFullscreen(); setStarted(true); move(1) }}><ChevronRight size={20} /></button>
        {active.voice && <button type="button" className="miniature-voice" onClick={playVoice} aria-pressed={voicePlaying}><MicIcon size={15} />{voicePlaying ? '声を止める' : '声をきく'}</button>}
      </div>
      <audio ref={audio} src={active.voice?.url} preload="none" onPlay={event => { setVoicePlaying(true); onAudioPlay(event.currentTarget) }} onEnded={() => setVoicePlaying(false)} onPause={() => setVoicePlaying(false)} onError={() => { if (voicePlaying) { setVoicePlaying(false); setVoiceError('声を再生できませんでした。') } }} />
      {loaded[active.artwork.id] && <p className="miniature-note">3Dを読み込めない作品は写真で表示しています。</p>}
      {voiceError && <p className="miniature-note" role="status">{voiceError}</p>}
      {photoIndex !== null && photoEntry && <MemoryViewer items={photoEntry.photos} index={photoIndex} onIndex={setPhotoIndex} onClose={() => setPhotoIndex(null)} />}
    </dialog>
  )
}

/** memoriaの中に常時見える3Dプレビュー。タップするまでは自動で動かさない。 */
export function MiniatureDigest({ onOpenArtwork, onAudioPlay, onStart, suspended = false }: { onOpenArtwork: (id: string) => void; onAudioPlay: (audio: HTMLAudioElement) => void; onStart: () => void; suspended?: boolean }) {
  const [scope, setScope] = useState<DigestScope>('all')
  const [drawingsOnly, setDrawingsOnly] = useState(false)
  const query = useMiniatureDigest(scope, drawingsOnly)
  return (
    <section className="miniature-digest" aria-labelledby="miniature-heading">
      <div className="miniature-heading"><h1 id="miniature-heading">3Dで振り返る</h1><span>作品と思い出</span></div>
      <div className="miniature-options"><Segmented<DigestScope> label="3D鑑賞の期間" options={[{ value: 'all', label: 'これまで' }, { value: 'year', label: 'この1年' }]} value={scope} onChange={setScope} /><button type="button" className="miniature-filter" aria-pressed={drawingsOnly} onClick={() => setDrawingsOnly(before => !before)}>絵画だけ</button></div>
      {query.isPending ? <div className="miniature-placeholder skeleton" aria-busy="true" aria-label="3D作品を読み込み中" /> : query.isError ? <div className="miniature-error" role="alert"><p>{query.error.message}</p><button type="button" className="btn btn-outline btn-small" onClick={() => query.refetch()}>もう一度読み込む</button></div> : query.data?.entries.length ? <MiniaturePlayback revision={`${scope}-${drawingsOnly}-${query.dataUpdatedAt}`} data={query.data} onOpenArtwork={onOpenArtwork} onAudioPlay={onAudioPlay} onStart={onStart} suspended={suspended || query.isPlaceholderData} /> : <div className="miniature-error"><p>この条件の作品はまだありません。</p><span>期間や「絵画だけ」の選択を変えてお試しください。</span></div>}
    </section>
  )
}
