// ③ 作品を追加する / ⑨ 作品の登録 (詳細入力) で共通のフォーム
// 写真は一覧のサムネイルや詳細の画像に使うので必須。3Dモデル(.glb)だけを選んで写真が無いときは、モデルを撮った画像
// (three の snapshotModel) を写真の代わりにする。あとから写真を選べば、そちらに置き換わる
import { useEffect, useRef, useState, type FormEvent } from 'react'
import type { Artwork, Category } from '../api'
import { CalendarIcon, CameraIcon, ChevronRight } from '../icons'
import { snapshotModel } from '../three'
import { GlassButton } from './GlassButton'
import { Segmented } from './Segmented'
import './ArtworkForm.css'

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
  const [file, setFile] = useState<File | null>(null)
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

  useEffect(() => {
    if (!file) {
      setPreview(null)
      return
    }
    const url = URL.createObjectURL(file)
    setPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [file])

  const shownImage = preview ?? initial?.image_url ?? null

  const choosePhoto = (photo: File | null) => {
    setFile(photo)
    setFromModel(false)
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

  const submit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    const data = new FormData(e.currentTarget)
    data.set('category', category)
    data.delete('image')
    data.delete('model')
    if (file) data.set('image', file)
    if (model) data.set('model', model)

    if (variant === 'add' && !file) {
      return setLocalError(snapshotting ? '3Dモデルを撮っています。少し待ってから追加してください' : '写真を撮るか選んでください')
    }
    if (!String(data.get('title') ?? '').trim()) return setLocalError('作品のタイトルを入力してください')
    setLocalError(null)
    onSubmit(data)
  }

  const message = localError ?? error

  return (
    <form className="form" onSubmit={submit} noValidate>
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
          defaultValue={initial?.memo}
        />
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

      <button type="submit" className="btn btn-filled" disabled={busy || snapshotting}>
        {submitLabel}
      </button>
    </form>
  )
}
