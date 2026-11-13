// ③ 作品を追加の「3D 生成で追加」で開くシート（iPhone のアプリの中だけ）。
// 立体 / 平面を選び、平面なら紙の大きさ（アプリが教える一覧と「わからない」）、立体なら高さ（cm、任意）を入れて、
// 「撮影をはじめる」でアプリの撮影画面へ進む。撮影そのものは呼び出し側（AddArtwork）が native/bridge.ts で行う。
import { useEffect, useState, type FormEvent } from 'react'
import type { CaptureKind, CaptureRequest, NativeCapture } from '../native/bridge'
import { Segmented } from './Segmented'
import { Sheet } from './Sheet'
import './CaptureSheet.css'

const KINDS: { value: CaptureKind; label: string }[] = [
  { value: 'object', label: '立体' },
  { value: 'flat', label: '平面' },
]

const KIND_HINT: Record<CaptureKind, string> = {
  object: '工作や粘土など。まわりをぐるっと撮ります。',
  flat: '絵や貼り絵など、紙の作品。真上から撮ります。',
}

/** 「わからない」の値（紙を選ばない） */
const UNKNOWN = ''

/** 高さの入力（全角の数字・「，」「,」の小数点も読む）を数にする。空なら null、読めなければ NaN */
function parseCm(text: string): number | null {
  const half = text
    .trim()
    .replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[．，,]/g, '.')
  if (half === '') return null
  return /^\d+(\.\d+)?$|^\.\d+$/.test(half) ? Number(half) : NaN
}

/** 「0.5」「300」のように、余分な 0 を付けずに出す */
const cmText = (n: number) => String(Math.round(n * 10) / 10)

export function CaptureSheet({
  open,
  onClose,
  native,
  onStart,
}: {
  open: boolean
  onClose: () => void
  native: NativeCapture
  onStart: (request: CaptureRequest) => void
}) {
  const [kind, setKind] = useState<CaptureKind>('object')
  const [sheetId, setSheetId] = useState(UNKNOWN)
  const [height, setHeight] = useState('')

  // 開くたびに最初から
  useEffect(() => {
    if (!open) return
    setKind('object')
    setSheetId(UNKNOWN)
    setHeight('')
  }, [open])

  const { min, max } = native.heightCm
  const cm = parseCm(height)
  const heightError =
    kind === 'object' && cm !== null && (Number.isNaN(cm) || cm < min || cm > max)
      ? `高さは ${cmText(min)}〜${cmText(max)} cm の数で入れてください`
      : null

  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (heightError) return
    if (kind === 'flat') onStart({ kind, ...(sheetId ? { sheetId } : {}) })
    else onStart({ kind, ...(cm !== null ? { heightCm: cm } : {}) })
  }

  const sheets = [{ id: UNKNOWN, label: 'わからない' }, ...native.sheets]

  return (
    <Sheet open={open} onClose={onClose} title="3D 生成で追加">
      <form className="sheet-body form capture-sheet" onSubmit={submit} noValidate>
        <div className="field">
          <span className="label">作品の形</span>
          <Segmented label="作品の形" options={KINDS} value={kind} onChange={setKind} />
          <p className="hint">{KIND_HINT[kind]}</p>
        </div>

        {kind === 'flat' ? (
          <div className="field">
            <span className="label" id="capture-sheet-paper">
              紙の大きさ
            </span>
            <div className="capture-papers" role="radiogroup" aria-labelledby="capture-sheet-paper">
              {sheets.map((s) => (
                <button
                  key={s.id || 'unknown'}
                  type="button"
                  role="radio"
                  aria-checked={sheetId === s.id}
                  className={`capture-paper${sheetId === s.id ? ' active' : ''}`}
                  onClick={() => setSheetId(s.id)}
                >
                  {s.label}
                </button>
              ))}
            </div>
          </div>
        ) : (
          <div className="field">
            <label htmlFor="capture-height">
              高さ<span className="optional">任意</span>
            </label>
            <div className="with-suffix">
              <input
                id="capture-height"
                className="input"
                inputMode="decimal"
                placeholder="例）12"
                maxLength={8}
                value={height}
                onChange={(e) => setHeight(e.target.value)}
                aria-invalid={!!heightError}
              />
              <span>cm</span>
            </div>
            <p className="hint">わかれば入れてください。3D を作るときの大きさの目安になります。</p>
          </div>
        )}

        {heightError && (
          <p className="form-error" role="alert">
            {heightError}
          </p>
        )}

        <button type="submit" className="btn btn-filled" disabled={!!heightError}>
          撮影をはじめる
        </button>
      </form>
    </Sheet>
  )
}
