// 3D の入口。画面からは `import { HomeScene, StageShell } from '../three'` のように、必ずここから読み込む。
//
// three.js はとても大きいので、scenes/ の中身は必要になったときに別ファイル（チャンク）として読み込む。
// 画面から scenes/ を直接 import すると、three.js が最初の読み込みに混ざって表示が遅くなる。
// ホーム表示後の空き時間に、家の建物（部屋ごとの GLB。shellUrlsOf）と家具の GLB・3D のコードを先読みして（warmUp3D）、3D 画面への移動を速くする。
// scenes/ の中でも three.js を使わない小さなファイル（house.ts）は、ここからそのまま渡している。

import { lazy } from 'react'
import type { Museum } from '../api'

export { StageShell } from './StageShell'
// 家の建物（部屋の定義）。three.js を使わない。部屋の一覧（house が無い古いサーバーではリビング 1 部屋）・
// 建物の GLB の URL（先読み用）・建物の GLB があるか（無ければ 3D の代わりに説明を出す）
export { hasHouseModel, houseRoomsOf, shellUrlsOf } from './scenes/home/house'

const load = () => import('./scenes')

export const HomeScene = lazy(() => load().then((m) => ({ default: m.HomeScene })))
export const MuseumScene = lazy(() => load().then((m) => ({ default: m.MuseumScene })))
export const MapScene = lazy(() => load().then((m) => ({ default: m.MapScene })))
export const PreviewScene = lazy(() => load().then((m) => ({ default: m.PreviewScene })))

const idle = (fn: () => void) => {
  if (typeof window.requestIdleCallback === 'function') window.requestIdleCallback(fn, { timeout: 2000 })
  else setTimeout(fn, 300)
}

/**
 * 家の建物の GLB（部屋ごと。shellUrlsOf）と、ほかの GLB（家具は furnitureUrlsOf、作品の詳細画面では作品のモデル）、
 * 3D のコードを先にダウンロードしておく
 */
export function warmUp3D(modelUrls: string | string[] | null | undefined, extraModels: string[] = []) {
  const shells = Array.isArray(modelUrls) ? modelUrls : modelUrls ? [modelUrls] : []
  idle(() => {
    load().then((m) => {
      shells.forEach((url) => m.preloadModel(url))
      extraModels.forEach((url) => m.preloadModel(url))
    })
  })
}

/** 配置 JSON で使っている家具の GLB の URL（重複なし）。warmUp3D に渡す */
export function furnitureUrlsOf(museum: Museum): string[] {
  const urls = new Map(museum.catalog.assets.map((a) => [a.id, a.file_url]))
  const used = new Set<string>()
  for (const o of museum.layout.objects) {
    const url = o.kind === 'furniture' ? urls.get(o.assetId) : undefined
    if (url) used.add(url)
  }
  return [...used]
}
