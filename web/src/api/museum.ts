// 博物館の全体像と設定（Rust: backend/src/museum_api.rs）。

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ApiError, jsonInit, keys, request } from './client'
import type { Museum, Settings } from './types'

// index.html で先読みしている /api/museum を最初の 1 回だけ再利用する
let preloadedMuseum: Promise<Museum> | null = fetch('/api/museum').then((r) => {
  if (!r.ok) throw new ApiError(r.status, '博物館の情報を取得できません')
  return r.json()
})

/** データを変更したら、古くなった先読みの結果は使わない */
export function forgetPreloadedMuseum() {
  preloadedMuseum = null
}

export function useMuseum() {
  return useQuery({
    queryKey: keys.museum,
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
