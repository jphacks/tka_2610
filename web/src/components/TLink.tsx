// 画面遷移アニメーション付きのリンク。kind で遷移の種類を選ぶ（nav.ts を参照）。
// Ctrl / Cmd / Shift クリックや中クリックは、ブラウザ標準の動き（新しいタブなど）のまま。
import type { AnchorHTMLAttributes, MouseEvent } from 'react'
import { useNav, type NavKind } from '../nav'

export function TLink({
  to,
  kind = 'push',
  share,
  onClick,
  children,
  ...rest
}: AnchorHTMLAttributes<HTMLAnchorElement> & {
  to: string
  kind?: NavKind
  /** 作品 ID を渡すと、その作品の画像が次の画面へつながって動く */
  share?: string
}) {
  const nav = useNav()
  return (
    <a
      href={to}
      {...rest}
      onClick={(e: MouseEvent<HTMLAnchorElement>) => {
        onClick?.(e)
        if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
        e.preventDefault()
        if (kind === 'modal') nav.modal(to)
        else if (kind === 'tab') nav.tab(to)
        else nav.push(to, share)
      }}
    >
      {children}
    </a>
  )
}
