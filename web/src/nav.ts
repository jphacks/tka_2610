// iOS 風の画面遷移 (View Transitions API)
//
// push    : 右から次の画面が重なり、前の画面は少し左へ沈む
// pop     : push の逆
// modal   : 下からシートのようにせり上がる
// dismiss : modal の逆
// tab     : タブ切り替えは素早いクロスフェード
//
// 対応していないブラウザでは普通に遷移する。
// 動きそのもの（どこからどこへ動くか）は nav.css に書いてある。
// 仕組みの全体像は docs/frontend.md の「画面遷移」を参照。

import { useLayoutEffect, useMemo } from 'react'
import { useLocation, useNavigate, type NavigateOptions, type To } from 'react-router-dom'
import './nav.css'

export type NavKind = 'push' | 'pop' | 'modal' | 'dismiss' | 'tab' | 'fade'

type StartViewTransition = (cb: () => Promise<void> | void) => { finished: Promise<void> }

let pendingResolve: (() => void) | null = null

/** 新しい画面が描画されたら呼ぶ (下の RouteRendered から) */
function notifyRouteRendered() {
  const resolve = pendingResolve
  pendingResolve = null
  resolve?.()
}

/**
 * main.tsx に 1 つだけ置く。URL が変わって新しい画面が描画された直後に、
 * 遷移アニメーションへ「描画が終わった」と知らせる。
 */
export function RouteRendered() {
  const location = useLocation()
  useLayoutEffect(() => {
    notifyRouteRendered()
  }, [location.key])
  return null
}

const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches

/**
 * 共有要素アニメーション (サムネイル → 詳細画像) の対象を、
 * タップした作品の要素だけに絞る。data-share 属性を持つ要素が候補。
 */
function applyShare(shareId: string | undefined) {
  document.querySelectorAll<HTMLElement>('[data-share]').forEach((el) => {
    el.style.viewTransitionName = shareId && el.dataset.share === shareId ? artworkTransitionName(shareId) : ''
  })
}

export function runTransition(kind: NavKind, go: () => void, shareId?: string) {
  const start = (document as Document & { startViewTransition?: StartViewTransition }).startViewTransition
  if (!start || reducedMotion()) {
    go()
    return
  }

  const root = document.documentElement
  root.dataset.nav = kind
  applyShare(shareId)

  const transition = start.call(document, () =>
    new Promise<void>((resolve) => {
      const done = () => {
        applyShare(shareId)
        resolve()
      }
      pendingResolve = done
      go()
      // 同じ画面への遷移などで描画が起きなくても固まらないように
      window.setTimeout(() => {
        if (pendingResolve === done) notifyRouteRendered()
      }, 500)
    }),
  )

  transition.finished.finally(() => {
    if (root.dataset.nav === kind) delete root.dataset.nav
    applyShare(undefined)
  })
}

const canGoBack = () => ((window.history.state as { idx?: number } | null)?.idx ?? 0) > 0

export function useNav() {
  const navigate = useNavigate()

  return useMemo(
    () => ({
      /** share に作品IDを渡すと、その作品の画像が次の画面へつながって動く */
      push: (to: To, share?: string) => runTransition('push', () => navigate(to), share),
      modal: (to: To, options?: NavigateOptions) => runTransition('modal', () => navigate(to, options)),
      tab: (to: To) => runTransition('tab', () => navigate(to)),
      /** 履歴を置き換えて進む (登録 → プレビュー など) */
      replace: (to: To, kind: NavKind = 'fade') => runTransition(kind, () => navigate(to, { replace: true })),
      back: (fallback: To = '/', share?: string) =>
        runTransition('pop', () => (canGoBack() ? navigate(-1) : navigate(fallback, { replace: true })), share),
      dismiss: (fallback: To = '/') =>
        runTransition('dismiss', () => (canGoBack() ? navigate(-1) : navigate(fallback, { replace: true }))),
    }),
    [navigate],
  )
}

/** 作品サムネイルと詳細画像をつなぐ共有要素の名前 */
export const artworkTransitionName = (id: string) => `art-${id.slice(0, 8)}`
