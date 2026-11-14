// おへやの配置 JSON の読み書き（Rust: backend/src/home_api.rs）。おへやは ?room= で選ぶ（省くと今の年齢のおへや）。
// 配置 JSON は /api/museum の layout にも入っている。ここは模様替えモードで、配置だけを読み書きするときに使う。
// 保存すると、作品の「飾っている・いない」も変わることがあるので、おうちの全体像と作品の一覧も取り直す。

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { jsonInit, keys, request } from './client'
import type { Layout, Museum, SavedLayout } from './types'

const layoutUrl = (roomId?: string | null, allFloor?: string | null) =>
  allFloor != null ? `/api/ages/all/${encodeURIComponent(allFloor)}/layout` : roomId ? `/api/home/layout?room=${encodeURIComponent(roomId)}` : '/api/home/layout'

export function useLayout(roomId?: string | null) {
  return useQuery({
    queryKey: [...keys.layout, roomId ?? 'default'],
    queryFn: () => request<SavedLayout>(layoutUrl(roomId)),
  })
}

/**
 * 画面を閉じる・再読み込みするときに、まだ保存していない配置を送る（pagehide から呼ぶ）。
 * keepalive にすると、ページが消えた後も送信が続く。結果は待たない
 */
export function saveLayoutOnLeave(roomId: string | null | undefined, layout: Layout, allFloor?: string | null) {
  fetch(layoutUrl(roomId, allFloor), { ...jsonInit('PUT', { layout }), keepalive: true }).catch(() => {})
}

/**
 * 配置 JSON を保存する（PUT。最後に保存したものが勝つ）。
 * 形や置き方がおかしいと 400 になり、Rust の日本語のメッセージで ApiError を投げる
 */
export function useSaveLayout(roomId?: string | null, allFloor?: string | null) {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (layout: Layout) => request<SavedLayout>(layoutUrl(roomId, allFloor), jsonInit('PUT', { layout })),
    onSuccess: (saved) => {
      client.setQueryData(allFloor != null ? [...keys.layout, 'all', allFloor] : [...keys.layout, roomId ?? 'default'], saved)
      // 3D はすぐに新しい配置で描き、作品の置き場所（slots）などはこのあと取り直した値で揃える
      client.setQueryData<Museum>(allFloor != null ? [...keys.museum, 'all', allFloor] : keys.museumOf(roomId), (old) => (old ? { ...old, layout: saved.layout } : old))
      return Promise.all([
        client.invalidateQueries({ queryKey: keys.museum }),
        client.invalidateQueries({ queryKey: keys.ages }),
        client.invalidateQueries({ queryKey: ['artworks'] }),
        client.invalidateQueries({ queryKey: ['artwork'] }),
      ])
    },
  })
}

/** 「すべて」で外した作品を飾り直す。年齢別の展示先には触れない。 */
export function useDisplayAll() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ floor, id }: { floor: string; id: string }) =>
      request<SavedLayout>(`/api/ages/all/${encodeURIComponent(floor)}/artworks/${encodeURIComponent(id)}`, { method: 'POST' }),
    onSuccess: () => Promise.all([
      client.invalidateQueries({ queryKey: keys.museum }),
      client.invalidateQueries({ queryKey: keys.ages }),
      client.invalidateQueries({ queryKey: keys.layout }),
    ]),
  })
}
