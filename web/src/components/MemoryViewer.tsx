// おもいでの写真と動画を、画面いっぱいで見る（⑥ 作品の詳細のタイルを押すと出る）。
// 左右の矢印・横になぞる・← → キーで送り、Esc か × で閉じる。下にひとことと足した日、右上の「⋯」で onMenu（ひとことを変える・消す）。
// 動画は送られたまま置いているので、この端末で再生できない形式（Chrome での iPhone の HEVC の .mov など）のときは、その旨とダウンロードのリンクを出す。
// 後ろのシート（Sheet。z-index 50）を上に重ねられるよう、z-index は 40。
import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import type { Memory } from '../api'
import { BackIcon, ChevronRight, CloseIcon, MoreIcon } from '../icons'
import { GlassButton } from './GlassButton'
import './MemoryViewer.css'

export function MemoryViewer({
  items,
  index,
  onIndex,
  onClose,
  onMenu,
}: {
  /** 写真と動画（声は入れない） */
  items: Memory[]
  index: number
  onIndex: (index: number) => void
  onClose: () => void
  onMenu: (memory: Memory) => void
}) {
  const memory = items[index]
  const swipe = useRef<number | null>(null)
  // 再生できなかった動画（id）
  const [failed, setFailed] = useState<string | null>(null)
  const prev = () => index > 0 && onIndex(index - 1)
  const next = () => index < items.length - 1 && onIndex(index + 1)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
      if (e.key === 'ArrowLeft') prev()
      if (e.key === 'ArrowRight') next()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  if (!memory) return null

  const onDown = (e: ReactPointerEvent) => {
    swipe.current = e.clientX
  }
  const onUp = (e: ReactPointerEvent) => {
    if (swipe.current === null) return
    const dx = e.clientX - swipe.current
    swipe.current = null
    if (dx > 60) prev()
    if (dx < -60) next()
  }

  return (
    <div className="memory-viewer" role="dialog" aria-modal="true" aria-label="おもいで">
      <div className="memory-viewer-top">
        <GlassButton label="閉じる" onClick={onClose}>
          <CloseIcon size={19} strokeWidth={2.2} />
        </GlassButton>
        <span className="memory-viewer-count num">
          {index + 1} / {items.length}
        </span>
        <GlassButton label="メニュー" onClick={() => onMenu(memory)}>
          <MoreIcon size={20} />
        </GlassButton>
      </div>

      <div className="memory-viewer-media" onPointerDown={onDown} onPointerUp={onUp} onPointerCancel={() => (swipe.current = null)}>
        {memory.kind === 'photo' ? (
          <img key={memory.id} src={memory.url} alt={memory.caption || '写真'} draggable={false} />
        ) : failed === memory.id ? (
          <div className="memory-viewer-failed">
            <p>この端末では、この動画を再生できません。</p>
            <a className="btn btn-gray btn-small" href={memory.url} download>
              ダウンロード
            </a>
          </div>
        ) : (
          <video key={memory.id} src={memory.url} controls playsInline autoPlay onError={() => setFailed(memory.id)} />
        )}
      </div>

      {index > 0 && (
        <button type="button" className="memory-viewer-nav prev" aria-label="前へ" onClick={prev}>
          <BackIcon size={22} strokeWidth={2.2} />
        </button>
      )}
      {index < items.length - 1 && (
        <button type="button" className="memory-viewer-nav next" aria-label="次へ" onClick={next}>
          <ChevronRight size={22} strokeWidth={2.2} />
        </button>
      )}

      <div className="memory-viewer-caption">
        {memory.caption && <p>{memory.caption}</p>}
        <small className="num">
          {[memory.date_label, memory.duration_label].filter(Boolean).join('・')}
        </small>
      </div>
    </div>
  )
}
