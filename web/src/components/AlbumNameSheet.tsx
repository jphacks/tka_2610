// アルバムの名前を入れるシート（作品一覧の棚の「新しく作る」・アルバムの画面の「名前を変える」・作品の詳細の「アルバムに入れる」）。
import { useEffect, useState, type FormEvent } from 'react'
import { Sheet } from './Sheet'

/** アルバムの名前の長さ（Rust の albums.rs の NAME_MAX と同じ） */
const NAME_MAX = 30

export function AlbumNameSheet({
  open,
  onClose,
  title,
  initial = '',
  submitLabel,
  busy = false,
  error,
  onSubmit,
}: {
  open: boolean
  onClose: () => void
  title: string
  initial?: string
  submitLabel: string
  busy?: boolean
  /** 保存に失敗したときの文言（Rust が返したもの） */
  error?: string
  onSubmit: (name: string) => void
}) {
  const [name, setName] = useState(initial)
  // 開くたびに、最初の名前から入れ直す
  useEffect(() => {
    if (open) setName(initial)
  }, [open, initial])

  const trimmed = name.trim()
  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (trimmed && !busy) onSubmit(trimmed)
  }

  return (
    <Sheet open={open} onClose={onClose} title={title}>
      <form className="sheet-body" onSubmit={submit}>
        <input
          className="input"
          aria-label="アルバムの名前"
          placeholder="例：4さいの夏、おじいちゃんにあげた"
          maxLength={NAME_MAX}
          value={name}
          onChange={(e) => setName(e.target.value)}
          autoFocus
          enterKeyHint="done"
        />
        {error && <p className="form-error" role="alert">{error}</p>}
        <button type="submit" className="btn btn-filled" disabled={!trimmed || busy}>
          {submitLabel}
        </button>
        <button type="button" className="btn btn-gray" onClick={onClose}>
          キャンセル
        </button>
      </form>
    </Sheet>
  )
}
