// 「⋯」ボタンから開くコンテキストメニュー（右上からガラスのパネルが広がる）。
import type { ReactNode } from 'react'
import { usePresence } from './usePresence'
import './ActionMenu.css'

export interface MenuItem {
  label: string
  icon?: ReactNode
  /** 削除など、取り消せない操作は赤字にする */
  destructive?: boolean
  onSelect: () => void
}

export function ActionMenu({
  open,
  onClose,
  items,
}: {
  open: boolean
  onClose: () => void
  items: MenuItem[]
}) {
  const { mounted, visible } = usePresence(open, 200)
  if (!mounted) return null
  return (
    <>
      <div className="scrim clear" onClick={onClose} />
      <div className={`context-menu glass${visible ? ' in' : ''}`} role="menu">
        {items.map((item) => (
          <button
            key={item.label}
            role="menuitem"
            className={item.destructive ? 'destructive' : ''}
            onClick={() => {
              onClose()
              item.onSelect()
            }}
          >
            <span>{item.label}</span>
            {item.icon}
          </button>
        ))}
      </div>
    </>
  )
}
