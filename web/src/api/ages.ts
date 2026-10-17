// 年齢ごとのおへや（Rust: backend/src/ages_api.rs）。ホームの年齢のチップ・積み上げの建物・マップのリストで使う。

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys, request } from './client'
import { forgetPreloadedMuseum } from './museum'
import type { AgeRoom, Ages, AgeStack } from './types'

/** 年齢の一覧（年齢ごとの作品の数とおへや） */
export function useAges() {
  return useQuery({ queryKey: keys.ages, queryFn: () => request<Ages>('/api/ages') })
}

/** その年齢のおへやを積み上げて描くための、おへやごとの配置と飾っている作品。age が null のあいだは取りに行かない */
export function useAgeStack(age: number | null) {
  return useQuery({
    queryKey: keys.ageStack(age ?? -1),
    queryFn: () => request<AgeStack>(`/api/ages/${age}`),
    enabled: age !== null,
  })
}

/** その年齢のいちばん上におへやを足す */
export function useAddRoom() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (age: number) => request<AgeRoom>(`/api/ages/${age}/rooms`, { method: 'POST' }),
    onSuccess: () => {
      forgetPreloadedMuseum()
      return Promise.all([
        client.invalidateQueries({ queryKey: keys.ages }),
        client.invalidateQueries({ queryKey: keys.museum }),
      ])
    },
  })
}

/** 作品の無い、その年齢のいちばん上のおへやを消す */
export function useDeleteRoom() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => request<void>(`/api/rooms/${id}`, { method: 'DELETE' }),
    onSuccess: () => {
      forgetPreloadedMuseum()
      return Promise.all([
        client.invalidateQueries({ queryKey: keys.ages }),
        client.invalidateQueries({ queryKey: keys.museum }),
      ])
    },
  })
}
