// おうちの全体像（家の建物・配置 JSON・飾っている作品）と設定（Rust: backend/src/museum_api.rs）。

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ApiError, jsonInit, keys, request } from './client'
import type { Museum, Settings } from './types'

// index.html で先読みしている /api/museum を最初の 1 回だけ再利用する
let preloadedMuseum: Promise<Museum> | null = fetch('/api/museum').then((r) => {
  if (!r.ok) throw new ApiError(r.status, 'おうちの情報を取得できません')
  return r.json()
})

/** データを変更したら、古くなった先読みの結果は使わない */
export function forgetPreloadedMuseum() {
  preloadedMuseum = null
}

/**
 * おうちの全体像。refetchInterval（ミリ秒）を渡すと、その間隔で取り直す
 * （鑑賞モードで、ほかの端末で飾った・外した作品をすぐ反映するため。Unity 版の 3 秒ごとの確認と同じ）
 */
export function useMuseum({ refetchInterval }: { refetchInterval?: number } = {}) {
  return useQuery({
    queryKey: keys.museum,
    refetchInterval,
    queryFn: () => {
      if (preloadedMuseum) {
        const p = preloadedMuseum
        preloadedMuseum = null
        return p
      }
      return request<Museum>('/api/museum')
    },
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
      forgetPreloadedMuseum()
      client.setQueryData(keys.settings, settings)
      return client.invalidateQueries({ queryKey: keys.museum })
    },
  })
}
