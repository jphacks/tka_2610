// 下から出るシート。上部のつまみ（grabber）を下へ 90px 以上ドラッグすると閉じる。
import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from 'react'
import { usePresence } from './usePresence'
import './Sheet.css'

export function Sheet({
  open,
  onClose,
  title,
  children,
}: {
  open: boolean
  onClose: () => void
  title?: ReactNode
  children: ReactNode
}) {
  const { mounted, visible } = usePresence(open, 320)
  const [drag, setDrag] = useState(0)
  const start = useRef<number | null>(null)

  useEffect(() => {
    if (!open) setDrag(0)
  }, [open])

  if (!mounted) return null

  const onDown = (e: ReactPointerEvent) => {
    start.current = e.clientY
    ;(e.target as Element).setPointerCapture?.(e.pointerId)
  }
  const onMove = (e: ReactPointerEvent) => {
    if (start.current === null) return
    setDrag(Math.max(0, e.clientY - start.current))
  }
  const onUp = () => {
    if (start.current === null) return
    start.current = null
    if (drag > 90) onClose()
    else setDrag(0)
  }

  return (
    <>
      <div className={`scrim${visible ? ' in' : ''}`} onClick={onClose} />
      <div
        className={`sheet${visible ? ' in' : ''}${drag ? ' dragging' : ''}`}
        role="dialog"
        aria-modal="true"
        style={drag ? { transform: `translateY(${drag}px)` } : undefined}
      >
        <div className="sheet-grabber-area" onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp} onPointerCancel={onUp}>
          <span className="sheet-grabber" />
          {title && <h3>{title}</h3>}
        </div>
        {children}
      </div>
    </>
  )
}
