// ③ 作品を追加（/add）。モーダルで下から開く。
// 登録が終わると ④ 3D プレビューへ進む。登録した作品はサーバーが、作ったときの年齢のおへやに飾る
// （空きが無ければ家具を足して。それでも飾れなければ飾っていないまま。プレビューの「おうちに飾る」が残る）。
// iPhone のアプリの中（native/bridge.ts の橋渡しがあるとき）だけ、フォームの上に「3D 生成で追加」を出す。
// アプリの撮影画面で撮った写真と種類（平面 → 絵画、立体 → 工作）がフォームに入り、登録できたらアプリに作品の id を知らせる。
// 橋渡しが無いブラウザでは、今までと同じフォームだけ。
import { useEffect, useMemo, useRef, useState } from 'react'
import { useCreateArtwork, useMuseum } from '../api'
import { ArtworkForm, Busy, CaptureSheet, NavBar, Screen, useToast, type ArtworkSeed } from '../components'
import { ChevronRight, CubeIcon } from '../icons'
import { artworkCreated, nativeCapture, pendingCapture, startCapture, type CaptureRequest, type CaptureResult } from '../native/bridge'
import { useNav } from '../nav'
import { shellUrlsOf, warmUp3D, warmUpArtwork } from '../three'
import './AddArtwork.css'

const seedOf = (result: CaptureResult): ArtworkSeed => ({
  file: result.file,
  category: result.kind === 'flat' ? 'drawing' : 'craft',
})

export default function AddArtwork() {
  const nav = useNav()
  const create = useCreateArtwork()
  const museum = useMuseum()
  const toast = useToast()
  // 橋渡しがあるか（画面を開いたときに 1 回だけ読む）
  const native = useMemo(() => nativeCapture(), [])
  const [choosing, setChoosing] = useState(false)
  const [capturing, setCapturing] = useState(false)
  const [seed, setSeed] = useState<ArtworkSeed | null>(null)
  // フォームに入れた写真を撮った撮影の番号（登録できたらアプリに知らせる）
  const sessionId = useRef<string | null>(null)

  // 入力している間に 3D の準備をしておき、次のプレビュー画面をすぐ出す
  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data))
  }, [museum.data])

  // 撮影中に画面が読み込み直されて渡しそびれた結果があれば、フォームに入れる
  useEffect(() => {
    if (!native) return
    pendingCapture()
      .then((result) => {
        // 開発の StrictMode では 2 回呼ばれ、同じ結果が 2 回返る（bridge.ts が 1 回の問い合わせにまとめる）
        if (!result || sessionId.current === result.sessionId) return
        sessionId.current = result.sessionId
        setSeed(seedOf(result))
        toast('撮った写真をフォームに入れました')
      })
      .catch(() => {
        // 確かめられなくても、いつものフォームは使える（エラーは bridge.ts がコンソールに出す）
      })
  }, [native, toast])

  const capture = async (request: CaptureRequest) => {
    setChoosing(false)
    setCapturing(true)
    try {
      const outcome = await startCapture(request)
      if (outcome.cancelled) return
      sessionId.current = outcome.sessionId
      setSeed(seedOf(outcome))
    } catch (e) {
      toast(e instanceof Error ? e.message : '撮影できませんでした')
    } finally {
      setCapturing(false)
    }
  }

  return (
    <Screen>
      <NavBar
        title="作品を追加"
        left={
          <button className="btn-plain" onClick={() => nav.dismiss('/')}>
            キャンセル
          </button>
        }
      />
      <div className="page" style={{ paddingTop: 6 }}>
        {native && (
          <button
            type="button"
            className="add-capture-entry pressable"
            onClick={() => setChoosing(true)}
            disabled={capturing || create.isPending}
          >
            <span className="add-capture-icon">
              <CubeIcon size={22} />
            </span>
            <span className="add-capture-text">
              <strong>3D 生成で追加</strong>
              <small>{capturing ? '撮影しています…' : 'アプリのカメラで撮って、そのまま登録します'}</small>
            </span>
            <ChevronRight size={16} strokeWidth={2.2} className="add-capture-chev" />
          </button>
        )}
        <ArtworkForm
          variant="add"
          submitLabel="作品を登録する"
          busy={create.isPending}
          error={create.error?.message}
          seed={seed}
          onSubmit={(form) =>
            create.mutate(form, {
              onSuccess: (artwork) => {
                warmUpArtwork(artwork.model_url)
                if (artwork.displayed) toast(`${artwork.room_name ?? 'おうち'}に飾りました`)
                // アプリに作品の id を知らせる（届かなくても、登録とプレビューへの移動は止めない）
                if (sessionId.current) {
                  artworkCreated({ sessionId: sessionId.current, artworkId: artwork.id, title: artwork.title }).catch(() => {})
                  sessionId.current = null
                }
                nav.replace(`/artworks/${artwork.id}/preview`, 'fade')
              },
            })
          }
        />
      </div>
      {native && <CaptureSheet open={choosing} onClose={() => setChoosing(false)} native={native} onStart={capture} />}
      {create.isPending && <Busy label="写真から3Dを作っています" />}
    </Screen>
  )
}
