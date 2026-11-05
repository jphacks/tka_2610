// 期間をえらんで振り返るシアター（/map/theater?from=YYYY-MM-DD&to=YYYY-MM-DD&drawing=1）。memoria の「期間をえらんで振り返る」から push で開く。
//
// えらんだ期間に作った作品を、古い順に全部、手描きの町が回る丸い大地の上で振り返る。
//   作品 … 大地が回って奥から手前に来る（3D は TheaterScene。three/ の遅延読み込みの中）
//   写真・動画 … その作品のおもいでが、左右に写真立てとして立つ
//   メモ … 作品の少し上に、ふわっと浮かび上がる（文ごとに順に）
//   音楽 … この端末の音源ファイルを BGM にできる（サーバーへは送らない。theaterMusic.ts）
// 場面の時刻はすべて Rust（/api/recollections/theater）が決め、再生の時計と音合わせは theaterPlayback.ts。
import { Suspense, useCallback, useEffect, useMemo, useRef, useState, type ChangeEvent, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { useSearchParams } from 'react-router-dom'
import { useTheater, type TheaterData } from '../api'
import { ErrorBoundary, GlassButton, MemoryViewer, Screen } from '../components'
import { BackIcon, ChevronRight, CloseIcon, ExpandIcon, MicIcon, NoteIcon, PauseIcon, PlayIcon, ThemeIcon } from '../icons'
import { useNav } from '../nav'
import { StageShell, TheaterScene, chapterMarks, clockLabel, isTouchDevice } from '../three'
import { audioDuration, loadMusic, loadSettings, saveMusic, saveSettings, type TheaterMusic, type TheaterSettings } from './theaterMusic'
import { useTheaterPlayback } from './theaterPlayback'
import './DigestTheater.css'

/** 何もしなければ、操作の表示をこれだけ経ってから薄くする */
const HUD_IDLE_MS = 3200

function SetupPanel({
  data,
  pending,
  from,
  to,
  drawingsOnly,
  onRange,
  onDrawings,
  music,
  onMusic,
  settings,
  onSettings,
  onStart,
  onClose,
  started,
}: {
  data: TheaterData | undefined
  pending: boolean
  from: string | null
  to: string | null
  drawingsOnly: boolean
  onRange: (from: string, to: string) => void
  onDrawings: (value: boolean) => void
  music: TheaterMusic | null
  onMusic: (music: TheaterMusic | null) => void
  settings: TheaterSettings
  onSettings: (settings: TheaterSettings) => void
  onStart: () => void
  onClose: () => void
  started: boolean
}) {
  const file = useRef<HTMLInputElement>(null)
  const preview = useRef<HTMLAudioElement | null>(null)
  const [previewing, setPreviewing] = useState(false)
  const [musicError, setMusicError] = useState('')
  const available = data?.available
  const currentFrom = from ?? data?.from ?? ''
  const currentTo = to ?? data?.to ?? ''
  const activePreset = available?.presets.find((p) => p.from === currentFrom && p.to === currentTo)?.key

  const stopPreview = useCallback(() => { preview.current?.pause(); setPreviewing(false) }, [])
  useEffect(() => stopPreview, [stopPreview])

  const choose = async (event: ChangeEvent<HTMLInputElement>) => {
    const chosen = event.target.files?.[0]
    event.target.value = ''
    if (!chosen) return
    if (!chosen.type.startsWith('audio/') && !/\.(mp3|m4a|aac|wav|ogg|oga|flac|webm)$/i.test(chosen.name)) {
      setMusicError('音源ファイル（MP3・M4A・WAV など）を選んでください')
      return
    }
    setMusicError('')
    stopPreview()
    const duration = await audioDuration(chosen)
    if (duration === 0) setMusicError('この端末では再生できない形式かもしれません。別のファイルもお試しください。')
    onMusic({ blob: chosen, name: chosen.name, offset: 0, duration })
  }

  const togglePreview = () => {
    if (!music) return
    if (previewing) { stopPreview(); return }
    const audio = new Audio(URL.createObjectURL(music.blob))
    audio.volume = settings.volume
    audio.currentTime = music.offset
    preview.current?.pause()
    preview.current = audio
    audio.onended = () => setPreviewing(false)
    void audio.play().then(() => setPreviewing(true)).catch(() => setMusicError('試しに聴けませんでした'))
  }
  useEffect(() => { if (preview.current) preview.current.volume = settings.volume }, [settings.volume])

  return (
    <div className="theater-setup glass" role="dialog" aria-modal="false" aria-labelledby="theater-setup-title">
      <div className="theater-setup-head">
        <div>
          <span className="theater-eyebrow">期間をえらんで振り返る</span>
          <h1 id="theater-setup-title">{data?.title ?? '作品のシアター'}</h1>
        </div>
        {started && <button type="button" className="theater-icon-btn" aria-label="設定を閉じる" onClick={onClose}><CloseIcon size={20} /></button>}
      </div>

      <section className="theater-setup-section" aria-labelledby="theater-period">
        <h2 id="theater-period">期間</h2>
        <div className="theater-presets" role="group" aria-label="よく使う期間">
          {available?.presets.map((p) => (
            <button type="button" key={p.key} aria-pressed={activePreset === p.key} onClick={() => onRange(p.from, p.to)}>{p.label}</button>
          ))}
        </div>
        <div className="theater-dates">
          <label>
            <span>はじまり</span>
            <input type="date" value={currentFrom} min={available?.first ?? undefined} max={currentTo || available?.today} onChange={(e) => e.target.value && onRange(e.target.value, currentTo)} />
          </label>
          <span aria-hidden="true">〜</span>
          <label>
            <span>おわり</span>
            <input type="date" value={currentTo} min={currentFrom || undefined} max={available?.today} onChange={(e) => e.target.value && onRange(currentFrom, e.target.value)} />
          </label>
        </div>
        <label className="theater-switch">
          <input type="checkbox" checked={drawingsOnly} onChange={(e) => onDrawings(e.target.checked)} />
          <span>絵だけを見る</span>
        </label>
        <p className="theater-summary" aria-live="polite">
          {pending ? '作品を数えています…' : data ? (data.artwork_count > 0 ? <><strong>{data.artwork_count}点</strong>の作品 · {data.duration_label}<small>{data.period_label}</small></> : 'この期間の作品はありません') : ''}
        </p>
        {data?.truncated && <p className="theater-note">作品が多いので、はじめの {data.artwork_count} 点を流します。期間をせまくすると全部見られます。</p>}
      </section>

      <section className="theater-setup-section" aria-labelledby="theater-music">
        <h2 id="theater-music"><NoteIcon size={16} />音楽</h2>
        <input ref={file} type="file" accept="audio/*,.mp3,.m4a,.aac,.wav,.ogg,.flac" hidden onChange={choose} />
        {music ? (
          <div className="theater-music">
            <div className="theater-music-row">
              <span className="theater-music-name" title={music.name}>{music.name}</span>
              <button type="button" className="theater-chip" onClick={togglePreview} aria-pressed={previewing}>{previewing ? <PauseIcon size={14} /> : <PlayIcon size={14} />}{previewing ? '止める' : '試しに聴く'}</button>
            </div>
            {music.duration > 2 && (
              <label className="theater-slider">
                <span>曲のはじめ <output>{clockLabel(music.offset * 1000)}</output></span>
                <input type="range" min={0} max={Math.max(0, Math.floor(music.duration - 1))} step={1} value={music.offset}
                  onChange={(e) => { stopPreview(); onMusic({ ...music, offset: Number(e.target.value) }) }} />
              </label>
            )}
            <div className="theater-music-actions">
              <button type="button" className="btn-plain" onClick={() => file.current?.click()}>別の曲にする</button>
              <button type="button" className="btn-plain" onClick={() => { stopPreview(); onMusic(null) }}>音楽なしにする</button>
            </div>
          </div>
        ) : (
          <button type="button" className="theater-music-pick" onClick={() => file.current?.click()}>
            <NoteIcon size={18} /><span>好きな曲をえらぶ<small>この端末の音源ファイルを使います。どこにも送りません。</small></span>
          </button>
        )}
        {musicError && <p className="theater-note" role="status">{musicError}</p>}
        <label className="theater-slider">
          <span>音楽の大きさ <output>{Math.round(settings.volume * 100)}</output></span>
          <input type="range" min={0} max={1} step={0.05} value={settings.volume} onChange={(e) => onSettings({ ...settings, volume: Number(e.target.value) })} />
        </label>
        <label className="theater-switch">
          <input type="checkbox" checked={settings.mediaSound} onChange={(e) => onSettings({ ...settings, mediaSound: e.target.checked })} />
          <span>動画と声の音も出す<small>鳴っているあいだは音楽を小さくします</small></span>
        </label>
        <label className="theater-switch">
          <input type="checkbox" checked={settings.stopMotion} onChange={(e) => onSettings({ ...settings, stopMotion: e.target.checked })} />
          <span>コマ撮り風の動き</span>
        </label>
      </section>

      <button type="button" className="btn btn-filled theater-start" disabled={!data || data.artwork_count === 0 || pending} onClick={() => { stopPreview(); onStart() }}>
        <PlayIcon size={18} />{started ? 'この内容で最初から再生' : '再生する'}
      </button>
    </div>
  )
}

export default function DigestTheater() {
  const nav = useNav()
  const [params, setParams] = useSearchParams()
  const from = params.get('from')
  const to = params.get('to')
  const drawingsOnly = params.get('drawing') === '1'
  const query = useTheater(from, to, drawingsOnly)
  const shown = query.data

  const [settings, setSettingsState] = useState<TheaterSettings>(loadSettings)
  const setSettings = useCallback((next: TheaterSettings) => { setSettingsState(next); saveSettings(next) }, [])
  const [music, setMusicState] = useState<TheaterMusic | null>(null)
  useEffect(() => { let alive = true; void loadMusic().then((m) => { if (alive && m) setMusicState(m) }); return () => { alive = false } }, [])
  const setMusic = useCallback((next: TheaterMusic | null) => { setMusicState(next); void saveMusic(next) }, [])
  const musicUrl = useMemo(() => (music ? URL.createObjectURL(music.blob) : null), [music?.blob]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => { if (musicUrl) URL.revokeObjectURL(musicUrl) }, [musicUrl])

  const [loaded, setLoaded] = useState<Record<string, boolean>>({})
  const onModelReady = useCallback((id: string, fallback: boolean) => setLoaded((before) => (before[id] === fallback ? before : { ...before, [id]: fallback })), [])

  const playback = useTheaterPlayback(shown, { musicUrl, musicOffset: music?.offset ?? 0, volume: settings.volume, mediaSound: settings.mediaSound, loaded })
  const { clock, playing, setPlaying, seek, version, view, videoFor } = playback

  const [started, setStarted] = useState(false)
  const [setupOpen, setSetupOpen] = useState(true)
  const [sceneReady, setSceneReady] = useState(false)
  const [stageError, setStageError] = useState<Error | null>(null)
  const [viewer, setViewer] = useState<{ scene: number; index: number } | null>(null)
  const [hudVisible, setHudVisible] = useState(true)
  const [reducedMotion, setReducedMotion] = useState(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)
  const lite = useMemo(() => isTouchDevice() || window.innerWidth < 700, [])
  const memoAnchor = useRef<HTMLDivElement>(null)
  const root = useRef<HTMLDivElement>(null)

  // 期間が変わったら、はじめの作品が着いたところを見せて止める
  const revision = shown ? `${shown.from}-${shown.to}-${drawingsOnly}-${shown.artwork_count}` : ''
  useEffect(() => {
    if (!shown) return
    setPlaying(false)
    seek(shown.scenes[0]?.arrive_ms ?? 0)
    setStarted(false)
    setSetupOpen(true)
  }, [revision]) // eslint-disable-line react-hooks/exhaustive-deps

  const scene = shown?.scenes[view.index]
  const setRange = (f: string, t: string) => {
    const next = new URLSearchParams(params)
    next.set('from', f)
    next.set('to', t)
    setParams(next, { replace: true })
  }
  const setDrawings = (value: boolean) => {
    const next = new URLSearchParams(params)
    if (value) next.set('drawing', '1')
    else next.delete('drawing')
    setParams(next, { replace: true })
  }

  const start = () => {
    seek(0)
    setStarted(true)
    setSetupOpen(false)
    setPlaying(true)
  }
  const toggle = () => {
    if (!shown) return
    if (!started) { start(); return }
    if (view.ended) { seek(0); setPlaying(true); return }
    setPlaying(!playing)
  }
  const jump = (delta: number) => {
    if (!shown) return
    const target = Math.min(shown.scenes.length - 1, Math.max(0, view.index + delta))
    const s = shown.scenes[target]
    seek(delta < 0 && target === view.index ? s.arrive_ms : s.start_ms)
  }
  const openArtwork = (id: string) => { setPlaying(false); nav.push(`/artworks/${id}`) }
  const openMedia = useCallback((sceneIndex: number, index: number) => { setPlaying(false); setViewer({ scene: sceneIndex, index }) }, [setPlaying])

  // 操作が無ければ HUD を薄くする（再生中だけ）
  const idle = useRef(0)
  const wake = useCallback(() => {
    setHudVisible(true)
    window.clearTimeout(idle.current)
    idle.current = window.setTimeout(() => setHudVisible(false), HUD_IDLE_MS)
  }, [])
  useEffect(() => { if (!playing) { window.clearTimeout(idle.current); setHudVisible(true) } else wake() }, [playing, wake])
  useEffect(() => () => window.clearTimeout(idle.current), [])

  // タブを隠したら止める・動きを減らす設定の変化
  useEffect(() => {
    const hide = () => { if (document.hidden) setPlaying(false) }
    document.addEventListener('visibilitychange', hide)
    const media = window.matchMedia('(prefers-reduced-motion: reduce)')
    const changed = () => setReducedMotion(media.matches)
    media.addEventListener('change', changed)
    return () => { document.removeEventListener('visibilitychange', hide); media.removeEventListener('change', changed) }
  }, [setPlaying])

  // キーボード：スペースで再生・停止、← → で前後の作品、Esc で設定を閉じる
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (viewer) return
      const target = event.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'SELECT' || target.tagName === 'TEXTAREA')) return
      if (event.key === ' ') { event.preventDefault(); toggle(); wake() }
      else if (event.key === 'ArrowRight' && started) { jump(1); wake() }
      else if (event.key === 'ArrowLeft' && started) { jump(-1); wake() }
      else if (event.key === 'Escape' && setupOpen && started) setSetupOpen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  const fullscreen = () => {
    const el = root.current
    if (!el) return
    if (document.fullscreenElement) void document.exitFullscreen().catch(() => {})
    else void el.requestFullscreen?.().catch(() => {})
  }

  // メモ：いまの行を、消えるときも少し残してふわっと消す
  const [memo, setMemo] = useState<{ key: string; text: string; visible: boolean } | null>(null)
  useEffect(() => {
    const line = scene && view.line >= 0 ? scene.memo[view.line] : null
    if (line) setMemo({ key: `${view.index}-${view.line}`, text: line.text, visible: true })
    else setMemo((before) => (before ? { ...before, visible: false } : before))
  }, [scene, view.index, view.line])

  const marks = useMemo(() => (shown ? chapterMarks(shown) : []), [shown])
  const total = shown?.total_ms ?? 0
  const status = view.waiting ? '作品の3Dを読み込んでいます…' : null
  const fade = reducedMotion && shown && view.phase === 'rolling'
  const viewerScene = viewer ? shown?.scenes[viewer.scene] : null

  return (
    <Screen className={`theater-screen${hudVisible || !playing ? '' : ' is-idle'}`}>
      <div className="theater-root" ref={root} onPointerMove={playing ? wake : undefined} onPointerDown={playing ? wake : undefined}>
        {query.isError ? (
          <div className="theater-message" role="alert">
            <h2>シアターを開けませんでした</h2>
            <p>{query.error.message}</p>
            <div className="theater-message-actions">
              <button type="button" className="btn btn-outline" onClick={() => query.refetch()}>もう一度読み込む</button>
              <button type="button" className="btn-plain" onClick={() => nav.back('/map')}>memoriaへ戻る</button>
            </div>
          </div>
        ) : stageError ? (
          <div className="theater-message" role="alert">
            <h2>舞台を準備できませんでした</h2>
            <p>{stageError.message}</p>
            <button type="button" className="btn-plain" onClick={() => nav.back('/map')}>memoriaへ戻る</button>
          </div>
        ) : (
          <ErrorBoundary fallback={() => (
            <div className="theater-message" role="alert">
              <h2>この端末では3Dを表示できませんでした</h2>
              <p>memoriaのスライドショーでも振り返れます。</p>
              <button type="button" className="btn btn-outline" onClick={() => nav.back('/map')}>memoriaへ戻る</button>
            </div>
          )}>
            <StageShell className="theater-stage" ready={!!shown && (sceneReady || shown.scenes.length === 0)} label="舞台を準備しています…">
              {shown && shown.scenes.length > 0 && (
                <Suspense fallback={null}>
                  <TheaterScene
                    data={shown}
                    clock={clock}
                    index={view.index}
                    playing={playing}
                    version={version}
                    stopMotion={settings.stopMotion}
                    reducedMotion={reducedMotion}
                    lite={lite}
                    memoAnchor={memoAnchor}
                    videoFor={videoFor}
                    onModelReady={onModelReady}
                    onArtwork={openArtwork}
                    onMedia={openMedia}
                    onReady={() => setSceneReady(true)}
                    onStageError={setStageError}
                  />
                </Suspense>
              )}
            </StageShell>
          </ErrorBoundary>
        )}

        {/* 作品の上に浮かぶメモ（位置は 3D が毎フレーム動かす） */}
        <div className="theater-memo-anchor" ref={memoAnchor} aria-live="polite">
          {memo && started && (
            <div key={memo.key} className={`theater-memo${memo.visible ? ' is-visible' : ''}`} role="note">
              <p>{memo.text}</p>
            </div>
          )}
        </div>

        {fade && <div className="theater-fade" style={{ '--fade': String(1 - Math.abs(((view.time - (scene?.start_ms ?? 0)) / Math.max(1, (scene?.arrive_ms ?? 1) - (scene?.start_ms ?? 0))) * 2 - 1)) } as CSSProperties} />}

        {/* 上：戻る・期間・設定 */}
        <div className="stage-top theater-top theater-hud">
          <GlassButton label="memoriaへ戻る" onClick={() => { setPlaying(false); nav.back('/map') }}><BackIcon size={20} /></GlassButton>
          {shown && <div className="stage-title glass theater-title"><span>{shown.title}</span><small>{shown.period_label}</small></div>}
          <GlassButton label="期間と音楽の設定" onClick={() => { setPlaying(false); setSetupOpen(true) }}><ThemeIcon size={20} /></GlassButton>
        </div>

        {/* 下：作品の名前と、再生の操作 */}
        {started && shown && scene && !setupOpen && (
          <div className="theater-bottom theater-hud">
            <button type="button" className="theater-caption glass" onClick={() => openArtwork(scene.artwork.id)}>
              <span className="theater-caption-count">{view.index + 1} / {shown.scenes.length}</span>
              <strong>{scene.artwork.title}</strong>
              <small>{scene.artwork.date_long}{scene.artwork.age_month_label && <> · {scene.artwork.age_month_label}</>}</small>
              <ChevronRight size={14} />
            </button>
            {status && <p className="theater-status glass" role="status">{status}</p>}
            {view.mediaAudible && <p className="theater-audible glass" aria-hidden="true"><MicIcon size={13} />おもいでの音</p>}
            <div className="theater-controls glass">
              <button type="button" className="theater-icon-btn" aria-label="前の作品" disabled={view.index === 0 && view.phase !== 'hold'} onClick={() => jump(-1)}><BackIcon size={18} /></button>
              <button type="button" className="theater-play" aria-label={view.ended ? 'もう一度' : playing ? '一時停止' : '再生'} onClick={toggle}>
                {playing ? <PauseIcon size={20} /> : <PlayIcon size={20} />}
              </button>
              <button type="button" className="theater-icon-btn" aria-label="次の作品" disabled={view.index + 1 >= shown.scenes.length} onClick={() => jump(1)}><ChevronRight size={18} /></button>
              <div className="theater-seek">
                <input
                  type="range"
                  min={0}
                  max={total}
                  step={100}
                  value={Math.min(total, view.time)}
                  aria-label="再生位置"
                  aria-valuetext={`${clockLabel(view.time)} / ${clockLabel(total)}`}
                  onChange={(e) => seek(Number(e.target.value))}
                />
                <div className="theater-ticks" aria-hidden="true">
                  {marks.map((m, i) => <i key={i} style={{ left: `${m * 100}%` }} className={i <= view.index ? 'is-past' : ''} />)}
                </div>
              </div>
              <span className="theater-time">{clockLabel(view.time)}<span> / {clockLabel(total)}</span></span>
              <button type="button" className="theater-icon-btn theater-fullscreen" aria-label="全画面" onClick={fullscreen}><ExpandIcon size={18} /></button>
            </div>
          </div>
        )}

        {/* 見終わったとき */}
        {started && view.ended && !setupOpen && shown && (
          <div className="theater-end glass" role="status">
            <span className="theater-eyebrow">{shown.period_label}</span>
            <h2>{shown.artwork_count}点の作品を振り返りました</h2>
            <div className="theater-end-actions">
              <button type="button" className="btn btn-filled" onClick={() => { seek(0); setPlaying(true) }}><PlayIcon size={16} />もう一度</button>
              <button type="button" className="btn btn-outline" onClick={() => setSetupOpen(true)}>期間を変える</button>
              <button type="button" className="btn-plain" onClick={() => nav.back('/map')}>memoriaへ戻る</button>
            </div>
          </div>
        )}

        {setupOpen && (
          <SetupPanel
            data={query.data}
            pending={query.isFetching}
            from={from}
            to={to}
            drawingsOnly={drawingsOnly}
            onRange={setRange}
            onDrawings={setDrawings}
            music={music}
            onMusic={setMusic}
            settings={settings}
            onSettings={setSettings}
            onStart={start}
            onClose={() => setSetupOpen(false)}
            started={started}
          />
        )}
      </div>
      {viewer && viewerScene && createPortal(
        <MemoryViewer items={viewerScene.media.map((m) => m.memory)} index={viewer.index} onIndex={(index) => setViewer({ ...viewer, index })} onClose={() => setViewer(null)} />,
        document.querySelector('.app') ?? document.body,
      )}
    </Screen>
  )
}
