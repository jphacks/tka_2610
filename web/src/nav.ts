// iOS 風の画面遷移 (View Transitions API)
//
// push    : 右から次の画面が重なり、前の画面は少し左へ沈む
// pop     : push の逆
// modal   : 下からシートのようにせり上がる
// dismiss : modal の逆
// tab     : タブ切り替えは素早いクロスフェード
//
// 対応していないブラウザでは普通に遷移する。
// 動きそのもの（どこからどこへ動くか・長さ）は nav.css に書いてある。
// 遷移が動いている間は useNavSettled が false を返す。3D の枠（three/StageShell.tsx）はこれを見て、
// アニメーションが終わってからキャンバスを置く（重い処理がアニメーションと重なってコマ落ちしないように）。
// 仕組みの全体像は docs/frontend.md の「画面遷移」を参照。

import { useLayoutEffect, useMemo, useSyncExternalStore } from 'react'
import { useLocation, useNavigate, type NavigateOptions, type To } from 'react-router-dom'
import './nav.css'

export type NavKind = 'push' | 'pop' | 'modal' | 'dismiss' | 'tab' | 'fade'

type ViewTransitionLike = { finished: Promise<void>; skipTransition: () => void }
type StartViewTransition = (cb: () => Promise<void> | void) => ViewTransitionLike

/**
 * finished を待たずに「遷移は終わった」とみなすまでの時間（ms）。
 * タブが裏に回ったときなど、finished がなかなか来なくても 3D が出ないままにならないように
 */
const SETTLE_TIMEOUT = 1200

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

// ---------- 動いている遷移（useNavSettled が読む小さなストア） ----------

interface ActiveTransition {
  transition: ViewTransitionLike
  /** SETTLE_TIMEOUT のタイマー */
  timer: number
  /** タイマーが切れて、finished を待たずに終わったとみなしたら true */
  timedOut: boolean
}

/** いちばん新しい遷移。終わったら null。<html> の data-nav と共有要素の名前も、この遷移のもの */
let active: ActiveTransition | null = null
const listeners = new Set<() => void>()

function emit() {
  listeners.forEach((listener) => listener())
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

const isSettled = () => active === null || active.timedOut

/**
 * 画面遷移のアニメーションが動いていなければ true。
 * View Transitions に対応していないブラウザ・「視差効果を減らす」の端末・遷移なしで開いた画面では、いつも true
 */
export function useNavSettled(): boolean {
  return useSyncExternalStore(subscribe, isSettled, () => true)
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

  // 前の遷移がまだ動いていたら、終わりまで飛ばす（2 つの遷移が重なると、古い画面の写しが残ったように見えるため）。
  // 飛ばした遷移の後始末（data-nav と共有要素の名前を消す）は、下の finished で active を見て行わない
  active?.transition.skipTransition()

  const root = document.documentElement
  root.dataset.nav = kind
  applyShare(shareId)

  const transition = start.call(document, () =>
    new Promise<void>((resolve) => {
      // 前の遷移が新しい画面の描画を待ったままなら、先に終わらせる（重なったときに固まらないように）
      notifyRouteRendered()
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

  const entry: ActiveTransition = { transition, timer: 0, timedOut: false }
  entry.timer = window.setTimeout(() => {
    entry.timedOut = true
    if (active === entry) emit()
  }, SETTLE_TIMEOUT)
  active = entry
  emit()

  const settle = () => {
    window.clearTimeout(entry.timer)
    // 新しい遷移に替わっている：印はそちらのもの
    if (active !== entry) return
    active = null
    delete root.dataset.nav
    applyShare(undefined)
    emit()
  }
  transition.finished.then(settle, settle)
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
