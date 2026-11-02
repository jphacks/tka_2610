// 写真の「向きをなおす・切り取る」シート（ArtworkForm から開く）。
// 左右に 90° 回す・四隅の丸をドラッグして切り取る・枠の中をドラッグして動かす。「この形にする」で、直した写真（JPEG）を返す。
// 計算は photoEdit.ts。サーバーには送らず、ブラウザの中だけで処理する。
import { useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import { RotateIcon } from '../icons'
import { cropToFile, FULL_RECT, isFull, loadWork, rotateCanvas, shrinkCanvas, type CropRect } from '../photoEdit'
import { Sheet } from './Sheet'
import './PhotoEditor.css'

/** 切り取りの枠の、いちばん小さい大きさ（写真全体を 1 とした割合） */
const MIN = 0.1
/** 画面に出す写真の大きさ（長い辺） */
const VIEW_MAX = 900

type Drag = 'move' | 'nw' | 'ne' | 'sw' | 'se'

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v))

export function PhotoEditor({
  file,
  open,
  onClose,
  onDone,
}: {
  /** 直す写真（選んだままの写真） */
  file: File | null
  open: boolean
  onClose: () => void
  /** 直した写真を渡す */
  onDone: (fixed: File) => void
}) {
  const [work, setWork] = useState<HTMLCanvasElement | null>(null)
  const [quarter, setQuarter] = useState(0)
  const [rect, setRect] = useState<CropRect>(FULL_RECT)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const view = useRef<HTMLCanvasElement>(null)
  const box = useRef<HTMLDivElement>(null)
  const drag = useRef<{ mode: Drag; x: number; y: number; rect: CropRect } | null>(null)

  // 開くたびに、写真を読み直して最初の状態にする
  useEffect(() => {
    if (!open || !file) return
    let alive = true
    setWork(null)
    setQuarter(0)
    setRect(FULL_RECT)
    setError(null)
    loadWork(file)
      .then((canvas) => alive && setWork(canvas))
      .catch(() => alive && setError('写真を読み込めませんでした'))
    return () => {
      alive = false
    }
  }, [open, file])

  const rotated = useMemo(() => (work ? rotateCanvas(work, quarter) : null), [work, quarter])

  // 回した写真を、画面用の小さいキャンバスに描く
  useEffect(() => {
    const canvas = view.current
    if (!canvas || !rotated) return
    const small = shrinkCanvas(rotated, VIEW_MAX)
    canvas.width = small.width
    canvas.height = small.height
    canvas.getContext('2d')?.drawImage(small, 0, 0)
  }, [rotated])

  const turn = (step: number) => {
    setQuarter((q) => q + step)
    setRect(FULL_RECT)
  }

  const reset = () => {
    setQuarter(0)
    setRect(FULL_RECT)
  }

  const onDown = (mode: Drag) => (e: ReactPointerEvent) => {
    e.stopPropagation()
    drag.current = { mode, x: e.clientX, y: e.clientY, rect }
    ;(e.currentTarget as Element).setPointerCapture?.(e.pointerId)
  }

  const onMove = (e: ReactPointerEvent) => {
    const d = drag.current
    const el = box.current
    if (!d || !el) return
    const bounds = el.getBoundingClientRect()
    if (bounds.width === 0 || bounds.height === 0) return
    const dx = (e.clientX - d.x) / bounds.width
    const dy = (e.clientY - d.y) / bounds.height
    const o = d.rect
    if (d.mode === 'move') {
      const w = o.r - o.l
      const h = o.b - o.t
      const l = clamp(o.l + dx, 0, 1 - w)
      const t = clamp(o.t + dy, 0, 1 - h)
      return setRect({ l, t, r: l + w, b: t + h })
    }
    const next = { ...o }
    if (d.mode === 'nw' || d.mode === 'sw') next.l = clamp(o.l + dx, 0, o.r - MIN)
    if (d.mode === 'ne' || d.mode === 'se') next.r = clamp(o.r + dx, o.l + MIN, 1)
    if (d.mode === 'nw' || d.mode === 'ne') next.t = clamp(o.t + dy, 0, o.b - MIN)
    if (d.mode === 'sw' || d.mode === 'se') next.b = clamp(o.b + dy, o.t + MIN, 1)
    setRect(next)
  }

  const onUp = () => {
    drag.current = null
  }

  const done = async () => {
    if (!file || !rotated) return
    if (quarter % 4 === 0 && isFull(rect)) return onClose()
    setBusy(true)
    setError(null)
    try {
      const fixed = await cropToFile(rotated, rect, file.name.replace(/\.[^.]+$/, '') || 'photo')
      onDone(fixed)
      onClose()
    } catch {
      setError('写真を作れませんでした。もう一度ためしてください')
    } finally {
      setBusy(false)
    }
  }

  const style = {
    left: `${rect.l * 100}%`,
    top: `${rect.t * 100}%`,
    width: `${(rect.r - rect.l) * 100}%`,
    height: `${(rect.b - rect.t) * 100}%`,
  }

  return (
    <Sheet open={open} onClose={onClose} title="写真を整える">
      <div className="photo-editor">
        <div className="photo-editor-stage">
          {rotated ? (
            <div className="photo-editor-box" ref={box}>
              <div className="photo-editor-clip">
                <canvas ref={view} />
                <div className="photo-editor-shade" style={style} />
              </div>
              <div className="photo-editor-crop" style={style} onPointerDown={onDown('move')} onPointerMove={onMove} onPointerUp={onUp} onPointerCancel={onUp}>
                {(['nw', 'ne', 'sw', 'se'] as const).map((h) => (
                  <span
                    key={h}
                    className={`photo-editor-handle ${h}`}
                    onPointerDown={onDown(h)}
                    onPointerMove={onMove}
                    onPointerUp={onUp}
                    onPointerCancel={onUp}
                  />
                ))}
              </div>
            </div>
          ) : (
            <p className="hint">{error ?? '写真を読み込んでいます…'}</p>
          )}
        </div>

        <p className="hint photo-editor-hint">四隅の丸をドラッグして、いらないところを切り取れます。</p>

        <div className="photo-editor-tools">
          <button type="button" className="btn btn-outline btn-small" onClick={() => turn(-1)} disabled={!rotated}>
            <RotateIcon size={16} className="flip" /> 左
          </button>
          <button type="button" className="btn btn-outline btn-small" onClick={() => turn(1)} disabled={!rotated}>
            <RotateIcon size={16} /> 右
          </button>
          <button type="button" className="btn btn-plain btn-small" onClick={reset} disabled={!rotated}>
            もとにもどす
          </button>
        </div>

        {error && rotated && <div className="form-error">{error}</div>}

        <div className="sheet-body">
          <button type="button" className="btn btn-filled" onClick={done} disabled={!rotated || busy}>
            {busy ? '作っています…' : 'この形にする'}
          </button>
          <button type="button" className="btn btn-gray" onClick={onClose}>
            キャンセル
          </button>
        </div>
      </div>
    </Sheet>
  )
}
