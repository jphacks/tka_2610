// 下部タブ（浮いたガラスのカプセル）と、右の「作品を追加」ボタン。
// main.tsx で全画面共通に置いてあり、TABS に当てはまる画面でだけ表示される。
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
  )
}
