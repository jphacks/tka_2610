// ⑪ 鑑賞モード（/museum/walk）。② ホームの「歩く」・⑤ おうちの中の「⋯」などから push で開く。PC とスマホ（タッチ）の両方で使える。
// 家の中を一人称で歩き、飾っている作品を見る。
//   PC：クリックで歩き始め、WASD で歩き、マウスで見回す。照準を作品に合わせて E かクリックで作品カードを開く。Esc でやめる
//   スマホ：「歩き始める」を押し、左の親指（仮想スティック）で歩き、右の指でなぞって見回す。照準を作品に合わせて「見る」
//           （か右側をタップ）で作品カードを開く。「やめる」で止まる。スティックの見た目はこの画面が DOM で描く（WalkStick）
// 作品カードから、作品の詳細画面（⑥）へ進める。
// どちらの操作にするかは three/ の isTouchDevice で 1 回だけ決め、WalkScene にも touch で渡す（画面と 3D の判定をそろえる）。
// 開発用に、PC でも URL に ?input=touch を付けるとタッチの操作になる（docs/walk.md）。
// 飾る作品の変更（ほかの端末で飾った・外した）は 3 秒ごとに取り直して反映する（Unity 版と同じ間隔）。
// 3D の中身は WalkScene（three/ の遅延読み込みの中）。この画面は、読み込み中・操作の説明・照準・仮想スティック・作品カード・エラーの表示を受け持つ。
import { Suspense, useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { useArtwork, useMuseum } from '../api'
import { ErrorBoundary, GlassButton, Img, Screen, Spinner } from '../components'
import { BackIcon } from '../icons'
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

export default function MuseumWalk() {
  const museum = useMuseum({ refetchInterval: REFRESH_MS })
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

  const back = (
    <GlassButton
      label="戻る"
      onClick={() => {
        // 次に開いたときは、はじめの位置から歩き始める
        clearWalkPose()
        nav.back('/museum')
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
                        <span>「{aimedTitle}」</span>
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
                        「{aimedTitle}」
                        <small>E またはクリックで見る</small>
                      </p>
                    ))}
                  {!touch && <p className="walk-hint">Esc で操作をやめる</p>}
                </>
              )}

              {touch && <WalkStick listener={stickListener} />}

              {selected && (
                <WalkArtworkCard id={selected} onClose={closeCard} onOpen={() => nav.push(`/artworks/${selected}`, selected)} />
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
function WalkArtworkCard({ id, onClose, onOpen }: { id: string; onClose: () => void; onOpen: () => void }) {
  const artwork = useArtwork(id).data?.artwork

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
            {artwork.room_name && (
              <p className="walk-card-meta">
                <span className="on-view" /> {artwork.room_name}
              </p>
            )}
            <div className="walk-card-actions">
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
