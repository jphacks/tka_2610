// 丸いガラスのボタン（iOS 26 のツールバーボタン風）。
// ガラスは 3D や画像の上に浮かぶ部品だけに使う。紙の上では .icon-btn を使う。
import type { MouseEvent, ReactNode } from 'react'
import './GlassButton.css'

export function GlassButton({
  label,
  onClick,
  children,
  className = '',
}: {
  /** 読み上げ用のラベル（アイコンだけのボタンなので必須） */
  label: string
  onClick?: (e: MouseEvent<HTMLButtonElement>) => void
  children: ReactNode
  className?: string
}) {
  return (
    <button type="button" className={`glass-btn glass ${className}`} aria-label={label} onClick={onClick}>
      {children}
    </button>
  )
}
