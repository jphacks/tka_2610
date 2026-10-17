// おうちの全体像（家の建物・配置 JSON・飾っている作品）と設定（Rust: backend/src/museum_api.rs）。

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { jsonInit, keys, request } from './client'
import type { Museum, Settings } from './types'

/** /api/museum の URL（roomId を渡すとそのおへや） */
export const museumUrl = (roomId?: string | null) => (roomId ? `/api/museum?room=${encodeURIComponent(roomId)}` : '/api/museum')

/**
 * おへや roomId のおうちの全体像（省くと今の年齢のおへや）。refetchInterval（ミリ秒）を渡すと、その間隔で取り直す
 * （鑑賞モードで、ほかの端末で飾った・外した作品をすぐ反映するため）
 */
export function useMuseum({ roomId, refetchInterval }: { roomId?: string | null; refetchInterval?: number } = {}) {
  return useQuery({
    queryKey: keys.museumOf(roomId),
    refetchInterval,
    queryFn: () => request<Museum>(museumUrl(roomId)),
  })
}

export function useSettings() {
  return useQuery({ queryKey: keys.settings, queryFn: () => request<Settings>('/api/settings') })
}

export function useUpdateSettings() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (settings: Settings) => request<Settings>('/api/settings', jsonInit('PUT', settings)),
    onSuccess: (settings) => {
      client.setQueryData(keys.settings, settings)
      // 誕生日が変わると、作品の年齢とおへやが変わる
      return Promise.all([
        client.invalidateQueries({ queryKey: keys.museum }),
        client.invalidateQueries({ queryKey: keys.ages }),
        client.invalidateQueries({ queryKey: keys.layout }),
        client.invalidateQueries({ queryKey: ['artworks'] }),
        client.invalidateQueries({ queryKey: ['artwork'] }),
      ])
    },
  })
}
