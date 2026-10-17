/**
 * 画面上部のナビゲーションバー。
 * large のときは iOS のように大きなタイトルを表示し、スクロールすると
 * バー中央の小さなタイトルに切り替わる。スクロール量は親の .screen から取る。
 */
import { useEffect, useRef, useState, type ReactNode } from 'react'
import './NavBar.css'

export function NavBar({
  title,
  large = false,
  eyebrow,
  left,
  right,
}: {
  title: ReactNode
  large?: boolean
  /** 大きなタイトルの上に出す小さな文字（日付など） */
  eyebrow?: ReactNode
  left?: ReactNode
  right?: ReactNode
}) {
  const barRef = useRef<HTMLDivElement>(null)
  const [scrolled, setScrolled] = useState(false)
  const [collapsed, setCollapsed] = useState(!large)

  useEffect(() => {
    const scroller = barRef.current?.closest('.screen')
    if (!scroller) return
    let raf = 0
    const onScroll = () => {
      cancelAnimationFrame(raf)
      raf = requestAnimationFrame(() => {
        const y = scroller.scrollTop
        setScrolled(y > 2)
        if (large) setCollapsed(y > 40)
      })
    }
    onScroll()
    scroller.addEventListener('scroll', onScroll, { passive: true })
    return () => {
      cancelAnimationFrame(raf)
      scroller.removeEventListener('scroll', onScroll)
    }
  }, [large])

  return (
    <>
      <div ref={barRef} className={`navbar${scrolled ? ' scrolled' : ''}`}>
        <div className="navbar-side">{left}</div>
        <div className={`navbar-title${collapsed ? ' show' : ''}`}>{title}</div>
        <div className="navbar-side right">{right}</div>
      </div>
      {large && (
        <div className="large-title">
          {eyebrow && <div className="eyebrow">{eyebrow}</div>}
          <h1>{title}</h1>
        </div>
      )}
    </>
  )
}
