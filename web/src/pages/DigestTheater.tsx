// memoria内に埋め込むシアター。再生するとアプリ全体に広げる。/map/theater から単独でも開ける。
//
// えらんだ期間に作った作品を、古い順に全部、手描きの町が回る丸い大地の上で振り返る。
// 「ダイジェスト」（?digest=種）では、年齢ごとにランダムで 2 点ずつだけを古い順に流す（えらぶのは Rust。種が同じなら同じ作品）。
//   作品 … 大地が回って奥から手前に来る（3D は TheaterScene。three/ の遅延読み込みの中）
//   写真・動画 … その作品のおもいでが、左右に写真立てとして立つ
//   メモ … 作品の少し上に、ふわっと浮かび上がる（文ごとに順に）
//   音楽 … この端末の音源ファイルを BGM にできる（サーバーへは送らない。theaterMusic.ts）
// 場面の時刻はすべて Rust（/api/recollections/theater）が決め、再生の時計と音合わせは theaterPlayback.ts。
import { Fragment, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ChangeEvent, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { useNavigationType, useSearchParams } from 'react-router-dom'
import { useTheater, type TheaterData } from '../api'
import { ErrorBoundary, GlassButton, MemoryViewer } from '../components'
import { BackIcon, CalendarIcon, ChevronRight, CloseIcon, ExpandIcon, MicIcon, NoteIcon, PauseIcon, PlayIcon, ShuffleIcon, ThemeIcon } from '../icons'
import { useNav } from '../nav'
import { StageShell, THEATER_SPEEDS, TheaterScene, chapterMarks, clockLabel, isTouchDevice, jumpTimeAt, scaleTheater } from '../three'
import { audioDuration, loadMusic, loadSettings, saveMusic, saveSettings, type TheaterMusic, type TheaterSettings } from './theaterMusic'
import { useTheaterPlayback } from './theaterPlayback'
import './DigestTheater.css'

/** 「1.5×」 */
const speedLabel = (speed: number) => `${speed}×`
/** 下の操作列の速さボタン：押すたびに次の速さへ（いちばん速いあとは、いちばん遅いへ戻る） */
const nextSpeed = (speed: number) => {
  const i = THEATER_SPEEDS.findIndex((s) => s === speed)
  return THEATER_SPEEDS[(i + 1) % THEATER_SPEEDS.length]
}
const speedHint = (speed: number) =>
  speed < 1 ? 'ゆっくり進みます。メモをじっくり読めます。'
  : speed >= 3 ? 'ざっと流して見ます。メモは読みきれず、動画や声は途中までになります。'
  : speed > 1 ? '早く進みます。動画は途中までになることがあります。'
  : 'ふつうの速さです。再生中も下の「1×」から変えられます。'

/** ダイジェストのチップ（「これまで」のすぐあとに出す）。年齢ごとにランダムで 2 点ずつ */
const DIGEST_LABEL = 'ダイジェスト'
/** ダイジェストの作品のえらび方の種（URL の ?digest=。0〜2^31-1） */
const newDigestSeed = () => Math.floor(Math.random() * 0x7fffffff)
const parseDigestSeed = (value: string | null) => (value && /^\d{1,10}$/.test(value) && Number(value) <= 0xffffffff ? Number(value) : null)

/** 何もしなければ、操作の表示をこれだけ経ってから薄くする */
const HUD_IDLE_MS = 3200
/** 作品の名前の字幕を、作品が去りはじめる（滞在が終わる）この長さ前に消しはじめる */
const CAPTION_LEAD_MS = 450
/** メモの雲を、作品が去りはじめるこの長さ前に消しはじめる。消える動き（.theater-cloud.is-leaving の 1 秒）が、作品が動き出す 1 秒前に終わる */
const MEMO_LEAD_MS = 2000

/**
 * 作品を押して詳細へ行くときに覚える、戻ってきたときの続きの位置（このタブの sessionStorage。1 回読んだら消す）。
 * at はふつうの速さ（1×）での時刻なので、詳細にいる間に速さを変えても同じ場面から続く。
 */
interface TheaterResume {
  revision: string
  at: number
  playing: boolean
}
const RESUME_KEY = 'theater-resume'
/** 戻ってきたとき、これより前に覚えた位置は使わない（ずっと後に開き直したときは最初から） */
const RESUME_TTL_MS = 30 * 60 * 1000

function saveResume(resume: TheaterResume) {
  try { sessionStorage.setItem(RESUME_KEY, JSON.stringify({ ...resume, savedAt: Date.now() })) } catch { /* 覚えられなくても、最初から見られる */ }
}

/**
 * 作品の詳細へ行く直前に撮った 3D の 1 コマ（ImageBitmap。GPU の中の絵なので、写すのも描くのも軽い）。
 * 戻ってきたとき、3D の準備ができるまで同じ絵を見せる。メモリに置くだけ（再読み込みすると消えるが、そのときは画面遷移も無い）
 */
let freezeFrame: { revision: string; bitmap: ImageBitmap } | null = null
function takeFreeze(cameBack: boolean) {
  const frame = freezeFrame
  freezeFrame = null
  if (frame && !cameBack) { frame.bitmap.close(); return null }
  return frame
}
function keepFreeze(frame: { revision: string; bitmap: ImageBitmap } | null) {
  freezeFrame?.bitmap.close()
  freezeFrame = frame
}

/** 撮っておいた絵を、画面いっぱいのキャンバスに描く（描くのは最初の 1 回だけ。描いたら絵は手放す） */
function FreezeFrame({ bitmap, fading }: { bitmap: ImageBitmap; fading: boolean }) {
  const canvas = useRef<HTMLCanvasElement>(null)
  // 描画の前に描く（戻る画面遷移の、新しい画面の写しに間に合わせる）。
  // 手放した絵は幅が 0 になるので、2 回目（StrictMode など）は何もしない（キャンバスの大きさを変えると、描いた絵が消える）
  useLayoutEffect(() => {
    const el = canvas.current
    if (!el || bitmap.width === 0) return
    el.width = bitmap.width
    el.height = bitmap.height
    el.getContext('2d')?.drawImage(bitmap, 0, 0)
    bitmap.close()
  }, [bitmap])
  return <canvas ref={canvas} className={`theater-freeze${fading ? ' is-fading' : ''}`} aria-hidden="true" />
}

/** 撮った絵を出したまま待つ、いちばん長い時間（3D がなかなか出なくても、いつかは消す） */
const FREEZE_MAX_MS = 10_000
/** 3D の準備ができてから、撮った絵を薄くして消す長さ（DigestTheater.css の .theater-freeze と同じ） */
const FREEZE_FADE_MS = 400

/** 覚えた位置を取り出して消す。戻ってきたとき（cameBack）で、同じ期間・同じ作品の並びのときだけ返す */
function takeResume(revision: string, cameBack: boolean): TheaterResume | null {
  try {
    const raw = sessionStorage.getItem(RESUME_KEY)
    if (!raw) return null
    sessionStorage.removeItem(RESUME_KEY)
    if (!cameBack) return null
    const value = JSON.parse(raw) as Partial<TheaterResume & { savedAt: number }>
    if (value.revision !== revision || typeof value.at !== 'number' || !(value.at >= 0)) return null
    if (typeof value.savedAt !== 'number' || Date.now() - value.savedAt > RESUME_TTL_MS) return null
    return { revision, at: value.at, playing: value.playing === true }
  } catch {
    return null
  }
}

function SetupPanel({
  data,
  pending,
  from,
  to,
  drawingsOnly,
  onRange,
  onDrawings,
  digest,
  onDigest,
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
  digest: boolean
  onDigest: () => void
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
  const activePreset = digest ? 'digest' : available?.presets.find((p) => p.from === currentFrom && p.to === currentTo)?.key

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
          <span className="theater-eyebrow">設定</span>
          <h1 id="theater-setup-title">期間・速さ・音楽</h1>
        </div>
        <button type="button" className="theater-icon-btn" aria-label="設定を閉じる" onClick={() => { stopPreview(); onClose() }}><CloseIcon size={20} /></button>
      </div>

      {/* 中身だけをスクロールする（下のボタンが中身に重ならないように） */}
      <div className="theater-setup-body">
      <section className="theater-setup-section" aria-labelledby="theater-period">
        <h2 id="theater-period">期間</h2>
        <div className="theater-presets" role="group" aria-label="よく使う期間">
          {available?.presets.map((p, i) => (
            <Fragment key={p.key}>
              <button type="button" aria-pressed={activePreset === p.key} onClick={() => onRange(p.from, p.to)}>{p.label}</button>
              {i === 0 && <button type="button" aria-pressed={digest} onClick={onDigest}>{DIGEST_LABEL}</button>}
            </Fragment>
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
          {pending ? 'Loading…' : data ? (data.artwork_count > 0 ? <><strong>{data.artwork_count}点</strong>の作品 · {data.duration_label}<small>{data.period_label}</small></> : 'この期間の作品はありません') : ''}
        </p>
        {data?.truncated && <p className="theater-note">作品が多いので、はじめの {data.artwork_count} 点を流します。期間をせまくすると全部見られます。</p>}
        {digest && <p className="theater-note">年齢ごとに、ランダムで 2 点ずつえらんで古い順に流します。もう一度押すと、ほかの作品になります。</p>}
      </section>

      <section className="theater-setup-section" aria-labelledby="theater-speed">
        <h2 id="theater-speed">進む速さ</h2>
        <div className="theater-presets" role="group" aria-label="進む速さ">
          {THEATER_SPEEDS.map((speed) => (
            <button type="button" key={speed} aria-pressed={settings.speed === speed} onClick={() => onSettings({ ...settings, speed })}>{speedLabel(speed)}</button>
          ))}
        </div>
        <p className="theater-note">{speedHint(settings.speed)}</p>
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
          <span>コマ撮り風の動き<small>作品が人形のように小さくゆれます</small></span>
        </label>
      </section>
      </div>

      <div className="theater-setup-foot">
        <button type="button" className="btn btn-filled theater-start" disabled={!data || data.artwork_count === 0 || pending} onClick={() => { stopPreview(); onStart() }}>
          <PlayIcon size={18} />{started ? 'この内容で最初から再生' : '再生する'}
        </button>
      </div>
    </div>
  )
}

/**
 * はじめの画面（再生する前）。設定を並べず、映画のポスターのように「何を・どれだけ見るか」と大きな再生ボタンだけを出す。
 * 後ろでは 3D の大地がゆっくりゆれている（TheaterScene の attract）。日付・速さ・音楽は「設定」のシートで変える
 */
function TheaterPoster({
  data,
  pending,
  from,
  to,
  onRange,
  digest,
  onDigest,
  settings,
  music,
  onStart,
  onOpenSettings,
}: {
  data: TheaterData | undefined
  pending: boolean
  from: string | null
  to: string | null
  onRange: (from: string, to: string) => void
  /** ダイジェストを見ているか。onDigest は、ダイジェストにする（見ているときは、ほかの作品にえらび直す） */
  digest: boolean
  onDigest: () => void
  settings: TheaterSettings
  music: TheaterMusic | null
  onStart: () => void
  onOpenSettings: () => void
}) {
  const currentFrom = from ?? data?.from ?? ''
  const currentTo = to ?? data?.to ?? ''
  const presets = data?.available.presets ?? []
  const activePreset = digest ? 'digest' : presets.find((p) => p.from === currentFrom && p.to === currentTo)?.key
  const empty = !!data && data.artwork_count === 0
  // えらんでいるチップが列の外（右のぼかしの向こう）にあれば、見える所まで横にすべらせる
  const chips = useRef<HTMLDivElement>(null)
  // 端のぼかしは、その向こうにまだチップがある側だけに付ける（全部見えているときは、どのチップもぼかさない）
  const [more, setMore] = useState({ left: false, right: false })
  const updateMore = useCallback(() => {
    const row = chips.current
    if (!row) return
    const left = row.scrollLeft > 1
    const right = row.scrollLeft + row.clientWidth < row.scrollWidth - 1
    setMore((m) => (m.left === left && m.right === right ? m : { left, right }))
  }, [])
  useEffect(() => {
    const row = chips.current
    if (!row) return
    updateMore()
    const observer = new ResizeObserver(updateMore)
    observer.observe(row)
    return () => observer.disconnect()
  }, [updateMore, presets.length])
  useEffect(() => {
    const row = chips.current
    const chip = row?.querySelector<HTMLElement>('[aria-pressed="true"]')
    if (!row || !chip) return
    const fade = 24
    const left = chip.offsetLeft - row.offsetLeft
    const right = left + chip.offsetWidth
    if (left < row.scrollLeft + fade) row.scrollTo({ left: Math.max(0, left - fade), behavior: 'smooth' })
    else if (right > row.scrollLeft + row.clientWidth - fade) row.scrollTo({ left: right - row.clientWidth + fade, behavior: 'smooth' })
  }, [activePreset])
  return (
    <section className="theater-poster" aria-labelledby="theater-poster-title">
      <span className="theater-eyebrow">{digest ? '年齢ごとに 2 点ずつ振り返る' : '期間をえらんで振り返る'}</span>
      <h1 id="theater-poster-title">{data?.title ?? '作品のシアター'}</h1>
      <p className="theater-poster-meta" aria-live="polite">
        {pending ? 'Loading…'
          : !data ? ''
          : empty ? 'この期間の作品はありません'
          : <><strong>{data.artwork_count}点</strong><span>{data.duration_label}</span><span>{data.period_label}</span></>}
      </p>
      {data?.truncated && <p className="theater-poster-note">作品が多いので、はじめの {data.artwork_count} 点を流します</p>}
      {digest && (
        <button type="button" className="theater-poster-reroll" disabled={pending} onClick={onDigest}>
          <ShuffleIcon size={14} /><span>ほかの作品にする</span>
        </button>
      )}
      {/* 「これまで」と年齢は横にすべる列、「日付をえらぶ」は右端にいつも出す（年齢が増えても外へ押し出されない） */}
      <div className="theater-poster-periods">
        <div
          className={`theater-poster-chips${more.left ? ' more-left' : ''}${more.right ? ' more-right' : ''}`}
          ref={chips}
          role="group"
          aria-label="よく使う期間"
          onScroll={updateMore}
        >
          {presets.map((p, i) => (
            <Fragment key={p.key}>
              <button type="button" aria-pressed={activePreset === p.key} onClick={() => onRange(p.from, p.to)}>{p.label}</button>
              {i === 0 && <button type="button" aria-pressed={digest} onClick={onDigest}>{DIGEST_LABEL}</button>}
            </Fragment>
          ))}
        </div>
        <button
          type="button"
          className="theater-poster-date"
          aria-label="日付をえらぶ"
          title="日付をえらぶ"
          aria-pressed={!activePreset && presets.length > 0}
          onClick={onOpenSettings}
        >
          <CalendarIcon size={18} />
        </button>
      </div>
      <button type="button" className="btn btn-filled theater-poster-play" aria-label="再生する" disabled={!data || empty || pending} onClick={onStart}>
        <PlayIcon size={16} /><span className="theater-poster-play-label">再生する</span>
      </button>
      <button type="button" className="theater-poster-settings" onClick={onOpenSettings}>
        <NoteIcon size={14} />
        <span>{speedLabel(settings.speed)} · {music ? music.name : '音楽なし'}{settings.stopMotion ? ' · コマ撮り風' : ''}</span>
        <ChevronRight size={14} />
      </button>
    </section>
  )
}

export default function DigestTheater({ embedded = false, onExpandedChange, suspended = false, onStart }: {
  embedded?: boolean
  onExpandedChange?: (expanded: boolean) => void
  suspended?: boolean
  onStart?: () => void
} = {}) {
  const [expanded, setExpanded] = useState(false)
  const compact = embedded && !expanded
  useEffect(() => { onExpandedChange?.(expanded); return () => onExpandedChange?.(false) }, [expanded, onExpandedChange])
  const nav = useNav()
  const [params, setParams] = useSearchParams()
  const from = params.get('from')
  const to = params.get('to')
  const drawingsOnly = params.get('drawing') === '1'
  const digest = parseDigestSeed(params.get('digest'))
  const query = useTheater(from, to, drawingsOnly, digest)

  const [settings, setSettingsState] = useState<TheaterSettings>(loadSettings)
  const setSettings = useCallback((next: TheaterSettings) => { setSettingsState(next); saveSettings(next) }, [])
  // 進む速さに合わせて時間割を縮める（3D・音・シークバーはすべてこちらを使う）
  const shown = useMemo(() => (query.data ? scaleTheater(query.data, settings.speed) : undefined), [query.data, settings.speed])
  const [music, setMusicState] = useState<TheaterMusic | null>(null)
  useEffect(() => { let alive = true; void loadMusic().then((m) => { if (alive && m) setMusicState(m) }); return () => { alive = false } }, [])
  const setMusic = useCallback((next: TheaterMusic | null) => { setMusicState(next); void saveMusic(next) }, [])
  const musicUrl = useMemo(() => (music ? URL.createObjectURL(music.blob) : null), [music?.blob]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => { if (musicUrl) URL.revokeObjectURL(musicUrl) }, [musicUrl])

  const [loaded, setLoaded] = useState<Record<string, boolean>>({})
  const onModelReady = useCallback((id: string, fallback: boolean) => setLoaded((before) => (before[id] === fallback ? before : { ...before, [id]: fallback })), [])

  const playback = useTheaterPlayback(shown, { musicUrl, musicOffset: music?.offset ?? 0, volume: settings.volume, mediaSound: settings.mediaSound, loaded, speed: settings.speed })
  const { clock, playing, setPlaying, seek, version, view, videoFor } = playback

  const [started, setStarted] = useState(false)
  // 設定のシート（期間をくわしく・速さ・音楽）。はじめはポスター（TheaterPoster）だけを見せ、シートは閉じておく
  const [setupOpen, setSetupOpen] = useState(false)
  const [sceneReady, setSceneReady] = useState(false)
  const [stageError, setStageError] = useState<Error | null>(null)
  const [viewer, setViewer] = useState<{ scene: number; index: number } | null>(null)
  const [hudVisible, setHudVisible] = useState(true)
  const [reducedMotion, setReducedMotion] = useState(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)
  const lite = useMemo(() => isTouchDevice() || window.innerWidth < 700, [])
  const memoAnchor = useRef<HTMLDivElement>(null)
  const root = useRef<HTMLDivElement>(null)

  // 期間が変わったら、はじめの作品が着いたところを見せて止める。
  // 作品を押して詳細へ行き、戻ってきたときは、押したところから続ける（takeResume）
  const revision = shown ? `${shown.from}-${shown.to}-${drawingsOnly}-${shown.digest ?? ''}-${shown.artwork_count}` : ''
  // 戻る操作でこの画面に来たか（メニューから開き直したときや、期間を変えたときは続きから始めない）
  const navigationType = useNavigationType()
  const cameBack = useRef(navigationType === 'POP')
  // 戻ってきたときは、最初の描画から撮っておいた絵を出す（戻る画面遷移の新しい画面の写しにも、この絵が写る）
  const [freeze, setFreeze] = useState(() => takeFreeze(navigationType === 'POP'))
  const [freezeFading, setFreezeFading] = useState(false)
  useEffect(() => {
    if (!shown) return
    const resume = takeResume(revision, cameBack.current)
    cameBack.current = false
    if (!resume || freeze?.revision !== revision) setFreeze(null)
    if (resume) {
      seek(Math.min(shown.total_ms, resume.at / settings.speed))
      setStarted(true)
      if (embedded) setExpanded(true)
      setSetupOpen(false)
      setPlaying(resume.playing)
      return
    }
    // 期間を変えたら、はじめの作品が着いたところでポスターに戻る（シートで変えたときは、シートは開いたまま）
    setPlaying(false)
    seek(shown.scenes[0]?.arrive_ms ?? 0)
    setStarted(false)
  }, [revision]) // eslint-disable-line react-hooks/exhaustive-deps

  const scene = shown?.scenes[view.index]
  // 撮っておいた絵は、舞台と、いまの作品の 3D が出たら薄くして消す（それまでは時計も作品の読み込みを待って止まっている）
  const sceneArtworkReady = !!scene && sceneReady && loaded[scene.artwork.id] !== undefined
  useEffect(() => {
    if (!freeze || freezeFading) return
    if (sceneArtworkReady) { setFreezeFading(true); return }
    const t = window.setTimeout(() => setFreezeFading(true), FREEZE_MAX_MS)
    return () => window.clearTimeout(t)
  }, [freeze, freezeFading, sceneArtworkReady])
  useEffect(() => {
    if (!freezeFading) return
    const t = window.setTimeout(() => { setFreeze(null); setFreezeFading(false) }, FREEZE_FADE_MS)
    return () => window.clearTimeout(t)
  }, [freezeFading])
  const setRange = (f: string, t: string) => {
    const next = new URLSearchParams(params)
    next.set('from', f)
    next.set('to', t)
    next.delete('digest')
    setParams(next, { replace: true })
  }
  /** ダイジェストにする（作品のある全期間から。もう見ているときは、新しい種でほかの作品にえらび直す） */
  const pickDigest = () => {
    const next = new URLSearchParams(params)
    next.delete('from')
    next.delete('to')
    let seed = newDigestSeed()
    if (seed === digest) seed = (seed + 1) % 0x7fffffff
    next.set('digest', String(seed))
    setParams(next, { replace: true })
  }
  const setDrawings = (value: boolean) => {
    const next = new URLSearchParams(params)
    if (value) next.set('drawing', '1')
    else next.delete('drawing')
    setParams(next, { replace: true })
  }

  const start = () => {
    if (embedded) setExpanded(true)
    onStart?.()
    seek(0)
    setStarted(true)
    setSetupOpen(false)
    setPlaying(true)
  }
  const close = () => {
    setPlaying(false)
    setSetupOpen(false)
    if (document.fullscreenElement === root.current) void document.exitFullscreen().catch(() => {})
    if (embedded) { setExpanded(false); setStarted(false) }
    else nav.back('/map')
  }
  // memoria の小さい枠では設定のシートが収まらないので、開くときは画面全体へ広げ、閉じたら（再生していなければ）枠に戻す
  const openSettings = () => {
    if (embedded) setExpanded(true)
    setSetupOpen(true)
  }
  const closeSettings = () => {
    setSetupOpen(false)
    if (embedded && !started) setExpanded(false)
  }
  useEffect(() => { if (suspended) { setPlaying(false); setExpanded(false); setStarted(false); setSetupOpen(false) } }, [suspended, setPlaying])
  const toggle = () => {
    if (!shown) return
    if (!started) { start(); return }
    if (view.ended) { seek(0); setPlaying(true); return }
    setPlaying(!playing)
  }
  // 前後の作品へ飛ぶ：作品が着いた時刻（arrive_ms）へ。飛ぶ先は jumpTimeAt（timeline.ts）が決める。
  // いまの位置は view（React の state。フレームごとにしか変わらない）ではなく時計そのものを読む（続けて押しても、前の押した分から数える）
  const jump = (delta: number) => {
    if (!shown) return
    const target = jumpTimeAt(shown, clock.current ?? 0, delta)
    if (target !== null) seek(target)
  }
  // jumpTimeAt が null のときだけ押せなくする（view の段階で読む。シークバーの time は 0.25 秒ごとに丸めてあるので使わない）。
  // 「次の作品」は、最後の作品が着いたあと（滞在中・最後の余韻）だけ押せない（最後の作品へ流れている途中は押すと、その前に着く）。
  // 「前の作品」は、最初の作品が着く前（はじめ）だけ押せない
  const canNext = !!shown && !(view.index + 1 >= shown.scenes.length && (view.phase === 'hold' || view.phase === 'outro'))
  const canPrev = !(view.index === 0 && view.phase === 'intro')
  // 作品を押した所（画面の座標）。詳細は、ここから丸く広がって開く（nav.zoom）
  const tapPoint = useRef<{ x: number; y: number } | null>(null)
  const captureRef = useRef<(() => Promise<ImageBitmap | null>) | null>(null)
  const leaving = useRef(false)
  const openArtwork = (id: string) => {
    if (leaving.current) return
    leaving.current = true
    // 戻ってきたら続きから見られるよう、いまの位置（ふつうの速さでの時刻）と再生中だったかを覚えておく
    if (started) saveResume({ revision, at: (clock.current ?? 0) * settings.speed, playing })
    setPlaying(false)
    const point = tapPoint.current ?? { x: window.innerWidth / 2, y: window.innerHeight / 2 }
    // 止めたコマを撮ってから移る（1 コマ分だけ待つ。撮れなくても移る）
    void (captureRef.current?.() ?? Promise.resolve(null)).then((bitmap) => {
      if (bitmap && !started) bitmap.close()
      keepFreeze(bitmap && started ? { revision, bitmap } : null)
      leaving.current = false
      nav.zoom(`/artworks/${id}`, point)
    })
  }
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
      if (embedded && !expanded) return
      if (event.key === ' ') { event.preventDefault(); toggle(); wake() }
      else if (event.key === 'ArrowRight' && started) { jump(1); wake() }
      else if (event.key === 'ArrowLeft' && started) { jump(-1); wake() }
      else if (event.key === 'Escape') { if (setupOpen) closeSettings(); else if (embedded && expanded) close() }
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

  // メモ：作品のメモ全体を 1 つの雲にして、一度に出す（最初の行が出る時刻から、作品が去りはじめる MEMO_LEAD_MS 前まで）。
  // 消えるときは上へ流れて消え（消え終わったら外す）、次の作品の新しい雲がその下でふくらむ
  const [clouds, setClouds] = useState<MemoCloud[]>([])
  const memoText = scene ? (scene.artwork.memo.trim() || scene.memo.map((l) => l.text).join('')) : ''
  // 速く進めて場面が短いときは、雲が出ている時間の半分は残す
  const memoLeft = !!scene && scene.memo.length > 0 && view.time >= Math.max(
    scene.arrive_ms + scene.hold_ms - MEMO_LEAD_MS,
    scene.arrive_ms + (scene.memo[0].show_ms + scene.hold_ms) / 2,
  )
  useEffect(() => {
    const key = memoText && view.line >= 0 && !memoLeft ? `${view.index}` : null
    setClouds((before) => {
      if (key && before.some((c) => c.key === key && !c.leaving)) return before
      const fading = before.map((c) => (c.leaving ? c : { ...c, leaving: true }))
      const changed = fading.some((c, i) => c !== before[i])
      if (!key) return changed ? fading : before
      return [...fading.filter((c) => c.key !== key).slice(-2), { key, text: memoText, leaving: false }]
    })
  }, [memoText, memoLeft, view.index, view.line])
  const dropCloud = useCallback((key: string) => setClouds((before) => before.filter((c) => c.key !== key)), [])

  const marks = useMemo(() => (shown ? chapterMarks(shown) : []), [shown])
  const total = shown?.total_ms ?? 0
  const status = view.waiting ? 'Loading…' : null
  // 下の再生の操作列だけ、本物の Liquid Glass（3D の絵を操作列の形の中で屈折させる。liquidGlass.ts）。
  // 3D が出ていて、撮っておいた絵を重ねていないときだけ。それ以外（準備中・戻った直後・3D を出せない端末）は、ふつうのすりガラス
  const liquid = sceneReady && !freeze && !stageError && !!shown && shown.scenes.length > 0
  // 字幕は、作品が着いてから、去りはじめる少し前まで
  const captionShown = !!scene && view.phase === 'hold' && view.time < scene.arrive_ms + scene.hold_ms - CAPTION_LEAD_MS
  const fade = reducedMotion && shown && view.phase === 'rolling'
  const viewerScene = viewer ? shown?.scenes[viewer.scene] : null

  return (
    <div className={embedded ? 'theater-embed-slot' : 'theater-page'}>
    <div className={`${embedded ? 'theater-embedded' : 'screen'} theater-screen${compact ? ' is-compact' : ''}${embedded && expanded ? ' is-expanded' : ''}${hudVisible || !playing ? '' : ' is-idle'}`}>
      <div className={`theater-root${liquid ? ' is-liquid' : ''}`} ref={root} onPointerMove={playing ? wake : undefined} onPointerDown={playing ? wake : undefined} onPointerDownCapture={(e) => { tapPoint.current = { x: e.clientX, y: e.clientY } }}>
        {query.isError ? (
          <div className="theater-message" role="alert">
            <h2>シアターを開けませんでした</h2>
            <p>{query.error.message}</p>
            <div className="theater-message-actions">
              <button type="button" className="btn btn-outline" onClick={() => query.refetch()}>もう一度読み込む</button>
              <button type="button" className="btn-plain" onClick={close}>memoriaへ戻る</button>
            </div>
          </div>
        ) : stageError ? (
          <div className="theater-message" role="alert">
            <h2>舞台を準備できませんでした</h2>
            <p>{stageError.message}</p>
            <button type="button" className="btn-plain" onClick={close}>memoriaへ戻る</button>
          </div>
        ) : (
          <ErrorBoundary fallback={() => (
            <div className="theater-message" role="alert">
              <h2>この端末では3Dを表示できませんでした</h2>
              <p>memoriaのスライドショーでも振り返れます。</p>
              <button type="button" className="btn btn-outline" onClick={close}>memoriaへ戻る</button>
            </div>
          )}>
            <StageShell className="theater-stage" ready={!!shown && (sceneReady || shown.scenes.length === 0)} label="Loading…">
              {shown && shown.scenes.length > 0 && (
                <Suspense fallback={null}>
                  <TheaterScene
                    data={shown}
                    clock={clock}
                    index={view.index}
                    playing={playing}
                    attract={!started}
                    glassRoot={root}
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
                    captureRef={captureRef}
                  />
                </Suspense>
              )}
            </StageShell>
            {freeze && <FreezeFrame bitmap={freeze.bitmap} fading={freezeFading} />}
          </ErrorBoundary>
        )}

        {/* 作品の上に浮かぶメモ（位置は 3D が毎フレーム動かす） */}
        <div className="theater-memo-anchor" ref={memoAnchor} aria-live="polite">
          {started && clouds.map((c) => <MemoCloudView key={c.key} cloud={c} onGone={dropCloud} />)}
        </div>

        {fade && <div className="theater-fade" style={{ '--fade': String(1 - Math.abs(((view.time - (scene?.start_ms ?? 0)) / Math.max(1, (scene?.arrive_ms ?? 1) - (scene?.start_ms ?? 0))) * 2 - 1)) } as CSSProperties} />}

        {/* 上：戻る・期間・設定 */}
        {!compact && <div className="stage-top theater-top theater-hud">
          <GlassButton label="memoriaへ戻る" onClick={close}><BackIcon size={20} /></GlassButton>
          {shown && started && <div className="stage-title glass theater-title"><span>{shown.title}</span><small>{shown.period_label}</small></div>}
          <GlassButton label="期間と音楽の設定" onClick={() => { setPlaying(false); setSetupOpen(true) }}><ThemeIcon size={20} /></GlassButton>
        </div>}

        {/* 作品の名前（映画の字幕のように、映像の上に直接出す）。作品が見えている間だけ出て、去るときに消える。
            操作が薄くなっても残り、操作の分だけ下へ下がる。押すと作品の詳細へ */}
        {started && shown && scene && !setupOpen && (
          <button
            type="button"
            key={scene.artwork.id}
            className={`theater-subtitle${captionShown ? ' is-shown' : ''}`}
            onClick={() => openArtwork(scene.artwork.id)}
            aria-hidden={!captionShown}
            tabIndex={captionShown ? 0 : -1}
          >
            <span className="theater-subtitle-count">{view.index + 1} / {shown.scenes.length}</span>
            <strong>{scene.artwork.title}</strong>
            <small>{scene.artwork.date_long}{scene.artwork.age_month_label && <> · {scene.artwork.age_month_label}</>}<ChevronRight size={13} /></small>
          </button>
        )}

        {/* 上のタイトルの下：読み込み中・おもいでの音の知らせ */}
        {started && !setupOpen && (status || view.mediaAudible) && (
          <div className="theater-notices theater-hud">
            {status && <p className="theater-status glass" role="status">{status}</p>}
            {view.mediaAudible && <p className="theater-audible glass" aria-hidden="true"><MicIcon size={13} />おもいでの音</p>}
          </div>
        )}

        {/* 下：再生の操作 */}
        {started && shown && scene && !setupOpen && (
          <div className="theater-bottom theater-hud">
            <div className="theater-controls glass" data-liquid="clear">
              <button type="button" className="theater-icon-btn" aria-label="前の作品" disabled={!canPrev} onClick={() => jump(-1)}><BackIcon size={18} /></button>
              <button type="button" className="theater-play" data-liquid="tint" aria-label={view.ended ? 'もう一度' : playing ? '一時停止' : '再生'} onClick={toggle}>
                {playing ? <PauseIcon size={20} /> : <PlayIcon size={20} />}
              </button>
              <button type="button" className="theater-icon-btn" aria-label="次の作品" disabled={!canNext} onClick={() => jump(1)}><ChevronRight size={18} /></button>
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
              <button type="button" className="theater-speed" aria-label={`進む速さ ${speedLabel(settings.speed)}（押すと変わります）`} onClick={() => setSettings({ ...settings, speed: nextSpeed(settings.speed) })}>
                {speedLabel(settings.speed)}
              </button>
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
              {digest !== null && <button type="button" className="btn btn-outline" onClick={pickDigest}><ShuffleIcon size={16} />ほかの作品で見る</button>}
              <button type="button" className={digest !== null ? 'btn-plain' : 'btn btn-outline'} onClick={() => setSetupOpen(true)}>期間を変える</button>
              <button type="button" className="btn-plain" onClick={close}>memoriaへ戻る</button>
            </div>
          </div>
        )}

        {!started && !query.isError && !stageError && (
          <TheaterPoster
            data={shown}
            pending={query.isFetching}
            from={from}
            to={to}
            onRange={setRange}
            digest={digest !== null}
            onDigest={pickDigest}
            settings={settings}
            music={music}
            onStart={start}
            onOpenSettings={openSettings}
          />
        )}

        {setupOpen && (
          <SetupPanel
            data={shown}
            pending={query.isFetching}
            from={from}
            to={to}
            drawingsOnly={drawingsOnly}
            onRange={setRange}
            onDrawings={setDrawings}
            digest={digest !== null}
            onDigest={pickDigest}
            music={music}
            onMusic={setMusic}
            settings={settings}
            onSettings={setSettings}
            onStart={start}
            onClose={closeSettings}
            started={started}
          />
        )}
      </div>
      {viewer && viewerScene && createPortal(
        <MemoryViewer items={viewerScene.media.map((m) => m.memory)} index={viewer.index} onIndex={(index) => setViewer({ ...viewer, index })} onClose={() => setViewer(null)} />,
        document.querySelector('.app') ?? document.body,
      )}
    </div>
    </div>
  )
}

interface MemoCloud {
  key: string
  text: string
  leaving: boolean
}

function MemoCloudView({ cloud, onGone }: { cloud: MemoCloud; onGone: (key: string) => void }) {
  return (
    <div className="theater-memo">
      <div
        className={`theater-cloud${cloud.text.length > 60 ? ' is-long' : ''}${cloud.leaving ? ' is-leaving' : ''}`}
        role="note"
        aria-hidden={cloud.leaving || undefined}
        onAnimationEnd={(e) => { if (cloud.leaving && e.target === e.currentTarget) onGone(cloud.key) }}
      >
        <div className="theater-cloud-drift" aria-hidden="true">
          <div className="theater-cloud-shape" />
        </div>
        <p>{cloud.text}</p>
      </div>
    </div>
  )
}
