// おうちの配置 JSON の読み書き（Rust: backend/src/home_api.rs）。
// 配置 JSON は /api/museum の layout にも入っている。ここは模様替えモードで、配置だけを読み書きするときに使う。
// 保存すると、作品の「飾っている・いない」も変わることがあるので、おうちの全体像と作品の一覧も取り直す。

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { jsonInit, keys, request } from './client'
import { forgetPreloadedMuseum } from './museum'
import type { Layout, Museum, SavedLayout } from './types'

export function useLayout() {
  return useQuery({
    queryKey: keys.layout,
    queryFn: () => request<SavedLayout>('/api/home/layout'),
  })
}

/**
 * 画面を閉じる・再読み込みするときに、まだ保存していない配置を送る（pagehide から呼ぶ）。
 * keepalive にすると、ページが消えた後も送信が続く。結果は待たない
 */
export function saveLayoutOnLeave(layout: Layout) {
  fetch('/api/home/layout', { ...jsonInit('PUT', { layout }), keepalive: true }).catch(() => {})
}

/**
 * 配置 JSON を保存する（PUT。最後に保存したものが勝つ）。
 * 形や置き方がおかしいと 400 になり、Rust の日本語のメッセージで ApiError を投げる
 */
export function useSaveLayout() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (layout: Layout) => request<SavedLayout>('/api/home/layout', jsonInit('PUT', { layout })),
    onSuccess: (saved) => {
      forgetPreloadedMuseum()
      client.setQueryData(keys.layout, saved)
      // 3D はすぐに新しい配置で描き、作品の置き場所（slots）などはこのあと取り直した値で揃える
      client.setQueryData<Museum>(keys.museum, (old) => (old ? { ...old, layout: saved.layout } : old))
      return Promise.all([
        client.invalidateQueries({ queryKey: keys.museum }),
        client.invalidateQueries({ queryKey: ['artworks'] }),
        client.invalidateQueries({ queryKey: ['artwork'] }),
      ])
    },
  })
}
