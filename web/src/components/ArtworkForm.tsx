// ③ 作品を追加する / ⑨ 作品の登録 (詳細入力) で共通のフォーム
// 写真は一覧のサムネイルや詳細の画像に使うので必須。3Dモデル(.glb)だけを選んで写真が無いときは、モデルを撮った画像
// (three の snapshotModel) を写真の代わりにする。あとから写真を選べば、そちらに置き換わる
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useGenerateMemoFromImage, type Artwork, type Category } from '../api'
import { CalendarIcon, CameraIcon, ChevronRight } from '../icons'
import { removeShadow } from '../photoFix'
import { snapshotModel } from '../three'
import { GlassButton } from './GlassButton'
import { PhotoEditor } from './PhotoEditor'
import { Segmented } from './Segmented'
import './ArtworkForm.css'

/** 絵の写真の見た目の選択（「影をとる」は photoFix.ts。作品の種類が「絵画」のときだけ出す） */
const PHOTO_LOOKS: { value: 'original' | 'fixed'; label: string }[] = [
  { value: 'original', label: '元の写真' },
  { value: 'fixed', label: '影をとる' },
]

const CATEGORIES: { value: Category; label: string }[] = [
  { value: 'drawing', label: '絵画' },
  { value: 'craft', label: '工作' },
  { value: 'photo', label: '写真' },
  { value: 'other', label: 'その他' },
]

const CATEGORY_HINT: Record<Category, string> = {
  drawing: '額縁に入れて「絵画の部屋」に飾ります。',
  craft: 'アクリルスタンド風の立体にして「工作の部屋」に飾ります。',
  photo: '額縁に入れて「思い出の部屋」に飾ります。',
  other: '額縁に入れて「思い出の部屋」に飾ります。',
}

const today = () => {
  const d = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export function ArtworkForm({
  initial,
  submitLabel,
  busy,
  error,
  onSubmit,
  variant,
}: {
  initial?: Artwork
  submitLabel: string
  busy: boolean
  error?: string | null
  onSubmit: (form: FormData) => void
  variant: 'add' | 'edit'
}) {
  const formRef = useRef<HTMLFormElement>(null)
  const generateImageMemo = useGenerateMemoFromImage()
  const generatingMemo = generateImageMemo.isPending
  const [memo, setMemo] = useState(initial?.memo ?? '')
  const [memoError, setMemoError] = useState<string | null>(null)
  const [file, setFile] = useState<File | null>(null)
  // 選んだままの写真 (向きをなおす・切り取るは、いつもこの写真から始める)。直したあとの写真は file に入る
  const [picked, setPicked] = useState<File | null>(null)
  const [editing, setEditing] = useState(false)
  const [edited, setEdited] = useState(false)
  const [preview, setPreview] = useState<string | null>(null)
  const [model, setModel] = useState<File | null>(null)
  // 写真 (file) が、3Dモデルを撮った画像か。撮っている間は true の snapshotting
  const [fromModel, setFromModel] = useState(false)
  const [snapshotting, setSnapshotting] = useState(false)
  // いちばん新しく選んだモデルの番号 (続けて選び直したとき、古いモデルの画像で上書きしない)
  const modelTurn = useRef(0)
  const [category, setCategory] = useState<Category>(initial?.category ?? 'drawing')
  const [localError, setLocalError] = useState<string | null>(null)
  const [advanced, setAdvanced] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)
  // 「影をとる」：補正した写真 (fixedFile) と、それを使うか (useFixed)。補正している間は fixing
  const [fixedFile, setFixedFile] = useState<File | null>(null)
  const [fixedPreview, setFixedPreview] = useState<string | null>(null)
  const [useFixed, setUseFixed] = useState(false)
  const [fixing, setFixing] = useState(false)
  // いちばん新しい補正の番号 (写真を選び直したあと、古い写真の補正結果で上書きしない)
  const fixTurn = useRef(0)

  useEffect(() => {
    if (!file) {
      setPreview(null)
      return
    }
    const url = URL.createObjectURL(file)
    setPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [file])

  useEffect(() => {
    if (!fixedFile) {
      setFixedPreview(null)
      return
    }
    const url = URL.createObjectURL(fixedFile)
    setFixedPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [fixedFile])

  // 「影をとる」を出すのは、新しく選んだ絵の写真だけ (3Dモデルを撮った画像と、工作などは対象にしない)
  const canFix = category === 'drawing' && !!file && !fromModel
  const showFixed = canFix && useFixed && !!fixedFile
  const shownImage = (showFixed ? fixedPreview : null) ?? preview ?? initial?.image_url ?? null

  const choosePhoto = (photo: File | null) => {
    fixTurn.current++
    setFixedFile(null)
    setUseFixed(false)
    setFixing(false)
    setFile(photo)
    setPicked(photo)
    setEdited(false)
    setFromModel(false)
  }

  /** 「向きをなおす・切り取る」で直した写真に置き換える (選び直しではないので、picked は変えない。影の補正はやり直し) */
  const applyEdit = (fixed: File) => {
    fixTurn.current++
    setFixedFile(null)
    setUseFixed(false)
    setFixing(false)
    setFile(fixed)
    setEdited(true)
  }

  /** 「元の写真」「影をとる」を切り替える。初めて「影をとる」を選んだときに補正する (補正した写真は取っておく) */
  const chooseLook = async (look: 'original' | 'fixed') => {
    if (look === 'original') return setUseFixed(false)
    setUseFixed(true)
    if (fixedFile || !file) return
    const turn = ++fixTurn.current
    setFixing(true)
    setLocalError(null)
    try {
      const fixed = await removeShadow(file, file.name.replace(/\.[^.]+$/, '') || 'photo')
      if (turn !== fixTurn.current) return
      setFixedFile(fixed)
    } catch {
      if (turn !== fixTurn.current) return
      setUseFixed(false)
      setLocalError('写真を補正できませんでした。元の写真のまま登録できます')
    } finally {
      if (turn === fixTurn.current) setFixing(false)
    }
  }

  /** 3Dモデルを選んだ。写真がまだ無い (か、前のモデルを撮った画像) なら、このモデルを撮って写真の代わりにする */
  const chooseModel = (next: File | null) => {
    setModel(next)
    const turn = ++modelTurn.current
    const needsPhoto = fromModel || (!file && !initial?.image_url)
    if (!next) {
      if (fromModel) choosePhoto(null)
      return
    }
    if (!needsPhoto) return
    setSnapshotting(true)
    snapshotModel(next)
      .then((photo) => {
        if (turn !== modelTurn.current) return
        setFile(photo)
        setFromModel(true)
        setLocalError(null)
      })
      .catch(() => turn === modelTurn.current && setLocalError('3Dモデルを読み込めませんでした。写真を撮るか選んでください'))
      .finally(() => turn === modelTurn.current && setSnapshotting(false))
  }

  const generateMemo = async () => {
    if (generatingMemo || busy || fixing || snapshotting) return
    const image = showFixed && fixedFile ? fixedFile : file
    if (!image) return setMemoError('先に作品の写真を選んでください')
    setMemoError(null)
    try {
      const form = new FormData(formRef.current!)
      const input = new FormData()
      for (const name of ['title', 'made_on', 'memo']) input.set(name, String(form.get(name) ?? ''))
      input.set('image', image)
      const draft = await generateImageMemo.mutateAsync(input)
      setMemo(draft.memo)
    } catch (e) {
      setMemoError(e instanceof Error ? e.message : '下書きを作れませんでした')
    }
  }

  const submit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (generatingMemo || busy) return
    const data = new FormData(e.currentTarget)
    data.set('category', category)
    data.delete('image')
    data.delete('model')
    // 「影をとる」を選んでいて、補正した写真があるときは、そちらを送る
    if (file) data.set('image', showFixed && fixedFile ? fixedFile : file)
    if (model) data.set('model', model)

    if (variant === 'add' && !file) {
      return setLocalError(snapshotting ? '3Dモデルを撮っています。少し待ってから追加してください' : '写真を撮るか選んでください')
    }
    if (fixing) return setLocalError('写真を補正しています。少し待ってから追加してください')
    if (!String(data.get('title') ?? '').trim()) return setLocalError('作品のタイトルを入力してください')
    setLocalError(null)
    onSubmit(data)
  }

  const message = localError ?? error

  return (
    <form ref={formRef} className="form" onSubmit={submit} noValidate>
      <fieldset disabled={busy || generatingMemo} style={{ display: 'contents' }}>
      <input
        ref={fileInput}
        className="visually-hidden"
        type="file"
        name="image"
        accept="image/*"
        onChange={(e) => choosePhoto(e.target.files?.[0] ?? null)}
      />

      {shownImage ? (
        <div className="photo-picker filled">
          <img src={shownImage} alt="選んだ作品の写真" />
          <GlassButton label="写真を変更" className="photo-change" onClick={() => fileInput.current?.click()}>
            <CameraIcon size={20} />
          </GlassButton>
        </div>
      ) : (
        <button type="button" className="photo-picker" onClick={() => fileInput.current?.click()}>
          <span className="inner">
            <CameraIcon size={30} strokeWidth={1.5} />
            {snapshotting ? '3Dモデルを撮っています…' : '写真を撮る・選ぶ'}
            <small>絵や工作をまっすぐ撮ると、きれいに飾れます</small>
          </span>
        </button>
      )}
      {fromModel && <p className="hint photo-note">3Dモデルを撮った画像を、写真の代わりに使います。写真を選ぶと置き換わります</p>}
      {picked && !fromModel && (
        <div className="photo-edit">
          <button type="button" className="btn btn-outline btn-small" onClick={() => setEditing(true)} disabled={fixing}>
            向きをなおす・切り取る
          </button>
          {edited && <p className="hint">向きや切り取りを直しました</p>}
        </div>
      )}
      {canFix && (
        <div className="photo-look">
          <Segmented label="写真の見た目" options={PHOTO_LOOKS} value={useFixed ? 'fixed' : 'original'} onChange={chooseLook} />
          {fixing && <p className="hint">影をとっています…</p>}
        </div>
      )}

      <div className="field">
        <label htmlFor="title">作品のタイトル</label>
        <input id="title" name="title" className="input" placeholder="例）にじ" maxLength={40} defaultValue={initial?.title} />
      </div>

      <div className="field">
        <span className="label">作品の種類</span>
        <Segmented label="作品の種類" options={CATEGORIES} value={category} onChange={setCategory} />
        <p className="hint">{CATEGORY_HINT[category]}</p>
      </div>

      <div className="row">
        <div className="field">
          <label htmlFor="child_name">つくった人</label>
          <input id="child_name" name="child_name" className="input" placeholder="例）はるか" maxLength={30} defaultValue={initial?.child_name} />
        </div>
        <div className="field">
          <label htmlFor="age">年齢</label>
          <div className="with-suffix">
            <input
              id="age"
              name="age"
              className="input"
              inputMode="numeric"
              pattern="[0-9]*"
              maxLength={3}
              placeholder="5"
              defaultValue={initial?.age ?? ''}
            />
            <span>歳</span>
          </div>
        </div>
      </div>

      <div className="field">
        <label htmlFor="made_on">作成年月日</label>
        <div className="with-icon">
          <CalendarIcon size={18} />
          <input id="made_on" name="made_on" type="date" className="input" max={today()} defaultValue={initial?.made_on ?? today()} />
        </div>
      </div>

      <div className="field">
        <label htmlFor="memo">
          メモ・エピソード<span className="optional">任意</span>
        </label>
        <textarea
          id="memo"
          name="memo"
          className="textarea"
          maxLength={500}
          placeholder={'例）おかあさんの誕生日に描いたよ。\n虹がきれいにかけてうれしそうだった。'}
          value={memo}
          onChange={(e) => setMemo(e.target.value)}
        />
        {variant === 'add' && (
          <>
            <button type="button" className="btn btn-outline btn-small"
              disabled={busy || generatingMemo || fixing || snapshotting || !file}
              onClick={generateMemo}>
              {generatingMemo ? 'AIでメモを作成しています…' : 'AIでメモの下書きをつくる'}
            </button>
            <p className="hint">作品の画像から下書きをつくります。画像と入力中の作品情報をGoogleのGemini APIへ送ります。内容を確認・編集してから登録できます。</p>
            {memoError && <p role="alert" className="form-error">{memoError}</p>}
          </>
        )}
      </div>

      <div>
        <button type="button" className="disclosure" onClick={() => setAdvanced((v) => !v)} aria-expanded={advanced}>
          <ChevronRight
            size={14}
            strokeWidth={2.4}
            style={{ transform: advanced ? 'rotate(90deg)' : 'none', transition: 'transform .35s var(--spring)' }}
          />
          3Dモデル(.glb)を持っている場合
        </button>
        {advanced && (
          <div className="field" style={{ marginTop: 10 }}>
            <input type="file" accept=".glb,model/gltf-binary" onChange={(e) => chooseModel(e.target.files?.[0] ?? null)} />
            <p className="hint">指定すると、写真から作る3Dの代わりにこのモデルを展示します。写真が無ければ、このモデルを撮った画像を写真の代わりに使います。</p>
          </div>
        )}
      </div>

      {message && <div className="form-error">{message}</div>}

      <PhotoEditor file={picked} open={editing} onClose={() => setEditing(false)} onDone={applyEdit} />

      <button type="submit" className="btn btn-filled" disabled={busy || snapshotting || fixing}>
        {submitLabel}
      </button>
      </fieldset>
    </form>
  )
}
