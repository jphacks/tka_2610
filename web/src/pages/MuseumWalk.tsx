// ⑪ 鑑賞モード（/museum/walk?room=おへやの id）。おへやの「歩く」・⑤ おうちの中の「⋯」などから push で開く。PC とスマホ（タッチ）の両方で使える。
// おへや（年齢ごとの部屋）の中を一人称で歩き、飾っている作品を見る。おへやは ?room= で選ぶ（省くと今の年齢のおへや）。
//   PC：クリックで歩き始め、WASD で歩き、マウスで見回す。照準を作品に合わせて E かクリックで作品カードを開く。Esc でやめる
//   スマホ：「歩き始める」を押し、左の親指（仮想スティック）で歩き、右の指でなぞって見回す。照準を作品に合わせて「見る」
//           （か右側をタップ）で作品カードを開く。「やめる」で止まる。スティックの見た目はこの画面が DOM で描く（WalkStick）
// 作品カードから、作品の詳細画面（⑥）へ進める。
// どちらの操作にするかは three/ の isTouchDevice で 1 回だけ決め、WalkScene にも touch で渡す（画面と 3D の判定をそろえる）。
// 開発用に、PC でも URL に ?input=touch を付けるとタッチの操作になる（docs/walk.md）。
// 飾る作品の変更（ほかの端末で飾った・外した）は 3 秒ごとに取り直して反映する（Unity 版と同じ間隔）。
// 3D の中身は WalkScene（three/ の遅延読み込みの中）。この画面は、読み込み中・操作の説明・照準・仮想スティック・作品カード・エラーの表示を受け持つ。
// 声のおもいで：声のある作品を照準で 1 秒見ていると、その作品の最初の声を 1 回流す（useWalkVoice。同じ作品は、開いている間に 1 回だけ）。
// 目をそらすと小さくして止める。右上の音符のボタンで入・切（localStorage に覚える。はじめは入）。作品カードにも「声をきく」を出す。
// 歩き始めのクリック・タッチのあとに流すので、ブラウザの自動再生の制限にはかからない。
import { Suspense, useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { useSearchParams } from 'react-router-dom'
import { fetchArtworkDetail, useArtwork, useMuseum, type Memory, type MemoryCounts, type SlotView } from '../api'
import { ErrorBoundary, GlassButton, Img, Screen, Spinner } from '../components'
import { BackIcon, NoteIcon, PauseIcon, PlayIcon, StopIcon } from '../icons'
import { useNav } from '../nav'
import {
  StageShell,
  TOUCH_STICK_RADIUS,
  WalkScene,
  clearWalkPose,
  isTouchDevice,
  shellUrlsOf,
  type TouchStick,
  type WalkStatus,
} from '../three'
import './MuseumWalk.css'

const KEYS: [string, string][] = [
  ['W A S D', '歩く'],
  ['マウス', '見回す'],
  ['Shift', '速く歩く'],
  ['E / クリック', '照準の先の作品を見る'],
  ['Esc', '操作をやめる'],
]

/** タッチの端末での操作の説明 */
const TOUCH_STEPS = ['左の親指で歩く', '右の指で見回す', '作品を狙って「見る」']

/** 仮想スティックの状態を受け取る関数（WalkStick が入れる） */
type StickListener = (stick: TouchStick | null) => void

/** 飾る作品の変更を取り直す間隔（Unity 版の MuseumApiClient と同じ 3 秒） */
const REFRESH_MS = 3000

/** 声の自動再生の入・切を覚えるキー（値は 'off' のときだけ切） */
const AUTO_VOICE_KEY = 'walk-auto-voice'
/** 照準を合わせてから声を流すまで（ミリ秒） */
const VOICE_DWELL_MS = 1000
/** 目をそらしたときに小さくしていく長さ（ミリ秒） */
const VOICE_FADE_MS = 400

const readAutoVoice = () => {
  try {
    return localStorage.getItem(AUTO_VOICE_KEY) !== 'off'
  } catch {
    return true
  }
}

/** 「写真 2・動画 1・声 1」 */
const memoryLabel = (c: MemoryCounts) =>
  [
    ['写真', c.photo],
    ['動画', c.video],
    ['声', c.audio],
  ]
    .filter(([, n]) => Number(n) > 0)
    .map(([label, n]) => `${label} ${n}`)
    .join('・')

/**
 * 照準の先（作品カードを開いていればその作品）に声のおもいでがあれば、1 秒後にその作品の最初の声を 1 回流す。
 * 目をそらす・切にすると、小さくして止める。流しているものを返す（画面の下に出す）
 */
function useWalkVoice(targetId: string | null, slots: SlotView[] | undefined, enabled: boolean) {
  const audio = useRef<HTMLAudioElement | null>(null)
  const played = useRef(new Set<string>())
  const fade = useRef<number | null>(null)
  // 作品カードの「声をきく」で流したか（自動再生を切にしていても流す）
  const manual = useRef(false)
  const [playing, setPlaying] = useState<{ artworkId: string; title: string } | null>(null)
  const playingId = playing?.artworkId ?? null

  const stop = useCallback((smooth: boolean) => {
    const a = audio.current
    if (fade.current !== null) clearInterval(fade.current)
    fade.current = null
    setPlaying(null)
    if (!a || a.paused) return
    if (!smooth) return a.pause()
    const step = a.volume / (VOICE_FADE_MS / 50)
    fade.current = window.setInterval(() => {
      a.volume = Math.max(0, a.volume - step)
      if (a.volume > 0) return
      a.pause()
      if (fade.current !== null) clearInterval(fade.current)
      fade.current = null
    }, 50)
  }, [])

  // 目をそらした・ほかの作品へ移った・切にしたら止める（作品カードで流した声は、カードを開いている間は止めない）
  useEffect(() => {
    if (playingId && (playingId !== targetId || (!enabled && !manual.current))) stop(true)
  }, [targetId, enabled, playingId, stop])

  /** 作品の最初の声を流す（作品カードの「声をきく」からも呼ぶ） */
  const play = useCallback((artworkId: string, voice: Memory, title: string, byHand = false) => {
    manual.current = byHand
    played.current.add(artworkId)
    if (fade.current !== null) clearInterval(fade.current)
    fade.current = null
    const a = audio.current ?? (audio.current = new Audio())
    a.src = voice.url
    a.volume = 1
    a.onended = () => setPlaying(null)
    a.play()
      .then(() => setPlaying({ artworkId, title }))
      .catch(() => setPlaying(null))
  }, [])

  // 照準を合わせて 1 秒たったら流す
  useEffect(() => {
    if (!enabled || !targetId || played.current.has(targetId)) return
    const slot = slots?.find((s) => s.artwork.id === targetId)
    if (!slot || slot.artwork.memory_counts.audio === 0) return
    let cancelled = false
    const timer = setTimeout(async () => {
      const detail = await fetchArtworkDetail(targetId).catch(() => null)
      const voice = detail?.memories.find((m) => m.kind === 'audio')
      if (!cancelled && voice) play(targetId, voice, slot.artwork.title)
    }, VOICE_DWELL_MS)
    return () => {
      cancelled = true
      clearTimeout(timer)
    }
  }, [targetId, enabled, slots, play])

  // 画面を離れたら止める
  useEffect(() => () => stop(false), [stop])

  return { playing, play, stop: () => stop(true) }
}

export default function MuseumWalk() {
  const [params] = useSearchParams()
  const museum = useMuseum({ roomId: params.get('room'), refetchInterval: REFRESH_MS })
  const ageRoomId = museum.data?.room.id ?? params.get('room')
  const nav = useNav()
  const [status, setStatus] = useState<WalkStatus>({ phase: 'loading', walking: false, aimedArtworkId: null })
  const [selected, setSelected] = useState<string | null>(null)
  // タッチの端末（スマホなど）か。開いている間は変えない（WalkScene の作り方も変わるため）
  const [touch] = useState(isTouchDevice)
  // タッチのとき、歩いているか（「歩き始める」と「やめる」で切り替える。PC はクリックで歩き始めるので使わない）
  const [touchWalking, setTouchWalking] = useState(false)
  // 仮想スティックの状態は、WalkStick だけに渡す（指の動きのたびに、この画面全体と 3D を描き直さないように）
  const stickListener = useRef<StickListener | null>(null)
  const onStick = useCallback((stick: TouchStick | null) => stickListener.current?.(stick), [])
  // 家の建物の GLB（部屋ごと。リビングは歩く画面用の GLB があればそれ。WalkScene と同じ）。1 つも無ければ null
  const modelUrls = museum.data ? shellUrlsOf(museum.data, { walk: true }) : undefined
  const modelUrl = modelUrls ? (modelUrls.length > 0 ? modelUrls.join(', ') : null) : undefined
  const ready = status.phase === 'ready'
  const aimedId = status.aimedArtworkId
  const aimedTitle = aimedId ? museum.data?.slots.find((s) => s.artwork?.id === aimedId)?.artwork?.title : null
  // 歩き始める前の説明。タッチは画面の walking で決める（作品カードを閉じた直後に、説明が一瞬出ないように）
  const showGuide = ready && !selected && (touch ? !touchWalking : !status.walking)

  const closeCard = useCallback(() => setSelected(null), [])
  const [autoVoice, setAutoVoice] = useState(readAutoVoice)
  const voice = useWalkVoice(selected ?? aimedId, museum.data?.slots, autoVoice && ready)
  const toggleAutoVoice = () => {
    const next = !autoVoice
    setAutoVoice(next)
    try {
      localStorage.setItem(AUTO_VOICE_KEY, next ? 'on' : 'off')
    } catch {
      /* 覚えられなくても、開いている間は切り替わる */
    }
  }
  const aimedHasVoice = !!aimedId && !!museum.data?.slots.find((s) => s.artwork.id === aimedId && s.artwork.memory_counts.audio > 0)

  const back = (
    <GlassButton
      label="戻る"
      onClick={() => {
        // 次に開いたときは、はじめの位置から歩き始める
        clearWalkPose()
        nav.back(ageRoomId ? `/rooms/${ageRoomId}` : '/')
      }}
    >
      <BackIcon size={20} strokeWidth={2.2} />
    </GlassButton>
  )

  return (
    <Screen className={`walk-screen${touch ? ' walk-touch' : ''}`}>
      <ErrorBoundary fallback={(error) => <WalkError error={error} modelUrl={modelUrl} back={back} />}>
        <StageShell
          className="walk-stage"
          ready={ready || modelUrl === null}
          label="おうちを読み込んでいます…"
          overlay={
            <>
              <div className="stage-top">
                {back}
                <span className="stage-title glass">鑑賞モード</span>
                {/* タッチで歩いている間は「やめる」を置く（タイトルの位置を変えないよう、空きの中から左へはみ出させる） */}
                <span className="walk-top-spacer">
                  {touch && status.walking && (
                    <button type="button" className="walk-stop glass" onClick={() => setTouchWalking(false)}>
                      やめる
                    </button>
                  )}
                  <GlassButton
                    label={autoVoice ? '作品の声を自動で流さない' : '作品の声を自動で流す'}
                    className={`walk-voice-toggle${autoVoice ? ' on' : ''}`}
                    onClick={toggleAutoVoice}
                  >
                    <NoteIcon size={18} />
                  </GlassButton>
                </span>
              </div>

              {showGuide &&
                (touch ? (
                  <div className="walk-guide walk-guide-touch glass-dark">
                    <p className="walk-guide-title">スマホで歩けます</p>
                    <ul className="walk-touch-steps">
                      {TOUCH_STEPS.map((step) => (
                        <li key={step}>{step}</li>
                      ))}
                    </ul>
                    <button type="button" className="btn btn-small walk-start" onClick={() => setTouchWalking(true)}>
                      歩き始める
                    </button>
                  </div>
                ) : (
                  <div className="walk-guide glass-dark">
                    <p className="walk-guide-title">クリックして歩き始める</p>
                    <dl className="walk-keys">
                      {KEYS.map(([key, action]) => (
                        <div key={key}>
                          <dt>
                            <kbd>{key}</kbd>
                          </dt>
                          <dd>{action}</dd>
                        </div>
                      ))}
                    </dl>
                  </div>
                ))}

              {status.walking && (
                <>
                  <div className={`walk-crosshair${aimedTitle ? ' on' : ''}`} />
                  {aimedTitle &&
                    (touch ? (
                      // タッチでは照準を合わせたまま押せるよう、作品の名前の下に大きな「見る」を出す
                      <div className="walk-aim walk-aim-touch">
                        <span>
                          「{aimedTitle}」{aimedHasVoice && <NoteIcon size={14} className="walk-aim-voice" />}
                        </span>
                        <button
                          type="button"
                          className="btn btn-filled btn-small walk-look"
                          onClick={() => aimedId && setSelected(aimedId)}
                        >
                          見る
                        </button>
                      </div>
                    ) : (
                      <p className="walk-aim">
                        <span>
                          「{aimedTitle}」{aimedHasVoice && <NoteIcon size={14} className="walk-aim-voice" />}
                        </span>
                        <small>E またはクリックで見る</small>
                      </p>
                    ))}
                  {!touch && <p className="walk-hint">Esc で操作をやめる</p>}
                </>
              )}

              {touch && <WalkStick listener={stickListener} />}

              {voice.playing && !selected && (
                <div className="walk-voice-now glass-dark" role="status">
                  <NoteIcon size={15} />
                  <span>「{voice.playing.title}」の声</span>
                  <button type="button" className="walk-voice-stop" aria-label="声を止める" onClick={voice.stop}>
                    <StopIcon size={14} />
                  </button>
                </div>
              )}

              {selected && (
                <WalkArtworkCard
                  id={selected}
                  onClose={closeCard}
                  onOpen={() => nav.push(`/artworks/${selected}`, selected)}
                  voicePlaying={voice.playing?.artworkId === selected}
                  onVoice={(memory, title) => (voice.playing?.artworkId === selected ? voice.stop() : voice.play(selected, memory, title, true))}
                />
              )}

              {museum.data && modelUrl === null && (
                <div className="stage-fallback">
                  家の 3D モデル（GLB）が見つかりません。サーバーの部屋の GLB（HOME_ROOM_MODELS_DIR）か MUSEUM_MODEL_PATH を確認してください
                </div>
              )}
            </>
          }
        >
          {museum.data && modelUrl && (
            <Suspense fallback={null}>
              <WalkScene
                museum={museum.data}
                paused={!!selected}
                touch={touch}
                walking={touchWalking}
                onStatus={setStatus}
                onSelectArtwork={setSelected}
                onStick={onStick}
              />
            </Suspense>
          )}
        </StageShell>
      </ErrorBoundary>
    </Screen>
  )
}

/**
 * 仮想スティック（タッチで歩いている間、画面の左側に指を置いている間だけ出す）。指を置いた所に輪を出し、つまみを指に合わせて動かす。
 * 位置は WalkScene（TouchControls）から 1 フレームに 1 回まで届く。状態はこの部品だけが持ち、画面全体と 3D は描き直さない
 */
function WalkStick({ listener }: { listener: RefObject<StickListener | null> }) {
  const [stick, setStick] = useState<TouchStick | null>(null)
  useLayoutEffect(() => {
    listener.current = setStick
    return () => {
      listener.current = null
    }
  }, [listener])

  if (!stick) return null
  const size = TOUCH_STICK_RADIUS * 2
  return (
    <div className="walk-stick" style={{ left: stick.x, top: stick.y, width: size, height: size }} aria-hidden="true">
      <div className="walk-stick-knob" style={{ transform: `translate(${stick.dx}px, ${stick.dy}px)` }} />
    </div>
  )
}

/** 照準の先の作品の情報（Unity 版の作品カードと同じ役目）。ここから作品の詳細画面へ進める */
function WalkArtworkCard({
  id,
  onClose,
  onOpen,
  voicePlaying,
  onVoice,
}: {
  id: string
  onClose: () => void
  onOpen: () => void
  /** この作品の声を流しているか */
  voicePlaying: boolean
  /** 「声をきく」・「止める」 */
  onVoice: (voice: Memory, title: string) => void
}) {
  const detail = useArtwork(id).data
  const artwork = detail?.artwork
  const voice = detail?.memories?.find((m) => m.kind === 'audio')

  // Esc でも閉じる
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.code === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <div className="walk-card" role="dialog" aria-label="作品の情報">
      {artwork ? (
        <>
          <Img src={artwork.thumb_url} tint={artwork.tint} alt={artwork.title} className="thumb walk-card-thumb" eager />
          <div className="walk-card-body">
            <p className="eyebrow num">
              {artwork.catalog_label}・{artwork.category_label}
            </p>
            <h2>{artwork.title}</h2>
            <p className="walk-card-meta num">{[artwork.author_label, artwork.date_long].filter(Boolean).join('　')}</p>
            {artwork.memo && <p className="walk-card-memo">{artwork.memo}</p>}
            {artwork.memory_counts && memoryLabel(artwork.memory_counts) && (
              <p className="walk-card-meta">おもいで　{memoryLabel(artwork.memory_counts)}</p>
            )}
            {artwork.room_name && (
              <p className="walk-card-meta">
                <span className="on-view" /> {artwork.room_name}
              </p>
            )}
            <div className="walk-card-actions">
              {voice && (
                <button className="btn btn-outline btn-small walk-card-voice" onClick={() => onVoice(voice, artwork.title)}>
                  {voicePlaying ? <PauseIcon size={14} /> : <PlayIcon size={14} />}
                  {voicePlaying ? '止める' : '声をきく'}
                </button>
              )}
              <button className="btn btn-filled btn-small" onClick={onOpen}>
                詳しく見る
              </button>
              <button className="btn btn-gray btn-small" onClick={onClose}>
                閉じる
              </button>
            </div>
          </div>
        </>
      ) : (
        <div className="walk-card-loading">
          <Spinner />
        </div>
      )}
    </div>
  )
}

/** 3D を表示できなかったときの説明。原因の見当と、エラーの文言をそのまま出す */
function WalkError({ error, modelUrl, back }: { error: Error; modelUrl: string | null | undefined; back: ReactNode }) {
  const message = error.message || String(error)
  let reason = '3D の表示中に問題が起きました。'
  if (/WebGL/i.test(message)) {
    reason = 'このブラウザでは 3D（WebGL）を使えません。ほかのブラウザで開くか、ハードウェアアクセラレーションの設定を確認してください。'
  } else if (/dynamically imported module|Loading chunk|Importing a module script/i.test(message)) {
    reason = '3D の表示に必要なファイルを読み込めませんでした。ページを再読み込みしてください。'
  } else if (/Could not load|fetch|glTF|GLB|JSON/i.test(message)) {
    reason = `家の 3D モデル（${modelUrl ?? 'GLB'}）を読み込めませんでした。サーバーが起動しているか、部屋の GLB（HOME_ROOM_MODELS_DIR）や MUSEUM_MODEL_PATH の GLB が正しいかを確認してください。`
  }

  return (
    <div className="walk-error">
      <div className="stage-top">{back}</div>
      <div className="walk-error-card">
        <h2>おうちを表示できませんでした</h2>
        <p>{reason}</p>
        <code>{message}</code>
        <button className="btn btn-filled btn-small" onClick={() => window.location.reload()}>
          再読み込み
        </button>
      </div>
    </div>
  )
}
