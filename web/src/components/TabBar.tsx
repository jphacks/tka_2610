// 下部タブ（浮いたガラスのカプセル）と、右の「作品を追加」ボタン。
// main.tsx で全画面共通に置いてあり、TABS に当てはまる画面でだけ表示される。
// ホーム以外のタブでは、右上にクレヨン風の虹を出す。
import type { CSSProperties } from 'react'
import { useLocation } from 'react-router-dom'
import { GalleryIcon, HomeIcon, MuseumIcon, PlusIcon, UserIcon } from '../icons'
import { useNav } from '../nav'
import './TabBar.css'

const TABS = [
  { to: '/', label: 'ホーム', icon: HomeIcon, match: (p: string) => p === '/' },
  { to: '/collection', label: '作品', icon: GalleryIcon, match: (p: string) => p.startsWith('/collection') },
  { to: '/map', label: 'ミュージアム', icon: MuseumIcon, match: (p: string) => p.startsWith('/map') },
  { to: '/settings', label: 'マイページ', icon: UserIcon, match: (p: string) => p.startsWith('/settings') },
]

export function TabBar() {
  const { pathname } = useLocation()
  const nav = useNav()
  const active = TABS.findIndex((t) => t.match(pathname))
  if (active < 0) return null

  return (
    <>
      {active > 0 && (
        <div className="tab-rainbow" aria-hidden="true">
          <svg viewBox="0 -28 190 150">
            <defs>
              {/* クレヨンのかすれ：線をゆらして、細かい粒で塗り残しを作る */}
              <filter id="crayon-rainbow" filterUnits="userSpaceOnUse" x="-10" y="-40" width="215" height="175">
                <feTurbulence type="fractalNoise" baseFrequency="0.04" numOctaves="2" seed="4" result="wobble" />
                <feDisplacementMap in="SourceGraphic" in2="wobble" scale="4" xChannelSelector="R" yChannelSelector="G" result="shape" />
                <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="8" result="grain" />
                <feColorMatrix in="grain" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  -2.8 0 0 0 2.2" result="holes" />
                <feComposite in="shape" in2="holes" operator="in" />
              </filter>
            </defs>
            <g fill="none" strokeWidth="10" strokeLinecap="round" filter="url(#crayon-rainbow)">
              <path d="M10 70A90 90 0 1 1 177.9 115" stroke="#f0a39a" />
              <path d="M22 70A78 78 0 1 1 167.5 109" stroke="#f6c98f" />
              <path d="M34 70A66 66 0 1 1 157.2 103" stroke="#f3dc8e" />
              <path d="M46 70A54 54 0 1 1 146.8 97" stroke="#b7d6a5" />
              <path d="M58 70A42 42 0 1 1 136.4 91" stroke="#a9cbe6" />
            </g>
          </svg>
        </div>
      )}
      <div className="tabbar-wrap">
        {/* --active で、選択中のタブの背景（.tab-lens）を横に動かす */}
        <nav className="tabbar glass" aria-label="メインメニュー" style={{ '--active': active } as CSSProperties}>
          <span className="tab-lens" aria-hidden="true" />
          {TABS.map((tab, i) => {
            const Icon = tab.icon
            return (
              <a
                key={tab.to}
                href={tab.to}
                className={`tab${i === active ? ' active' : ''}`}
                aria-current={i === active ? 'page' : undefined}
                onClick={(e) => {
                  e.preventDefault()
                  if (i !== active) nav.tab(tab.to)
                }}
              >
                <Icon size={23} strokeWidth={i === active ? 2.1 : 1.8} />
                <span>{tab.label}</span>
              </a>
            )
          })}
        </nav>
        <button className="tab-add" aria-label="作品を追加" onClick={() => nav.modal('/add')}>
          <PlusIcon size={26} strokeWidth={2.4} />
        </button>
      </div>
    </>
  )
}