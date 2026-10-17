// 3D の入口。画面からは `import { HeroScene, StageShell } from '../three'` のように、必ずここから読み込む。
//
// three.js はとても大きいので、scenes/ の中身は必要になったときに別ファイル（チャンク）として読み込む。
// 画面から scenes/ を直接 import すると、three.js が最初の読み込みに混ざって表示が遅くなる。
// ホーム表示後の空き時間に先読みして（warmUp3D）、3D 画面への移動を速くする。

import { lazy } from 'react'

export { StageShell } from './StageShell'

const load = () => import('./scenes')

export const HeroScene = lazy(() => load().then((m) => ({ default: m.HeroScene })))
export const MuseumScene = lazy(() => load().then((m) => ({ default: m.MuseumScene })))
export const MapScene = lazy(() => load().then((m) => ({ default: m.MapScene })))
export const PreviewScene = lazy(() => load().then((m) => ({ default: m.PreviewScene })))

const idle = (fn: () => void) => {
  if (typeof window.requestIdleCallback === 'function') window.requestIdleCallback(fn, { timeout: 2000 })
  else setTimeout(fn, 300)
}

/** 博物館 GLB と 3D コードを先にダウンロードしておく */
export function warmUp3D(museumUrl: string | null | undefined, extraModels: string[] = []) {
  idle(() => {
    load().then((m) => {
      if (museumUrl) m.preloadModel(museumUrl)
      extraModels.forEach((url) => m.preloadModel(url))
    })
  })
}
