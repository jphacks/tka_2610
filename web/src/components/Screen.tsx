// 各画面の外枠（縦スクロールする領域）。下部タブがある画面では tabbar を付けて、
// タブに隠れないよう下に余白を取る。
import type { ReactNode } from 'react'
import './Screen.css'

export function Screen({
  children,
  tabbar = false,
  className = '',
}: {
  children: ReactNode
  tabbar?: boolean
  className?: string
}) {
  return <main className={`screen${tabbar ? ' with-tabbar' : ''} ${className}`}>{children}</main>
}
