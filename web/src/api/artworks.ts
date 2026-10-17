// 作品の取得と変更（Rust: backend/src/artworks.rs）。
// 変更が成功すると、関係する一覧と博物館の情報を自動で取り直す（useInvalidate）。

import { QueryClient, useMutation, useQuery, useQueryClient, type QueryKey } from '@tanstack/react-query'
import { jsonInit, keys, request } from './client'
import { forgetPreloadedMuseum } from './museum'
import type { Artwork, ArtworkDetail, ArtworkList, ListParams } from './types'

// ---------- 取得 ----------

function listUrl(params: ListParams) {
  const search = new URLSearchParams()
  if (params.category && params.category !== 'all') search.set('category', params.category)
  if (params.sort) search.set('sort', params.sort)
  if (params.limit) search.set('limit', String(params.limit))
  const qs = search.toString()
  return `/api/artworks${qs ? `?${qs}` : ''}`
}

export function useArtworks(params: ListParams) {
  return useQuery({
    queryKey: keys.artworks(params),
    queryFn: () => request<ArtworkList>(listUrl(params)),
    placeholderData: (previous) => previous,
  })
}

/** 一覧で取得済みのデータを使って、詳細画面を待たずに表示する */
function findCachedArtwork(client: QueryClient, id: string): Artwork | undefined {
  for (const [, data] of client.getQueriesData<ArtworkList>({ queryKey: ['artworks'] })) {
    const hit = data?.items.find((a) => a.id === id)
    if (hit) return hit
  }
  return undefined
}

export function useArtwork(id: string | undefined) {
  const client = useQueryClient()
  return useQuery({
    queryKey: keys.artwork(id ?? ''),
    enabled: !!id,
    queryFn: () => request<ArtworkDetail>(`/api/artworks/${id}`),
    placeholderData: () => {
      const artwork = id ? findCachedArtwork(client, id) : undefined
      return artwork ? { artwork, related: [] } : undefined
    },
  })
}

export function prefetchArtwork(client: QueryClient, id: string) {
  return client.prefetchQuery({
    queryKey: keys.artwork(id),
    queryFn: () => request<ArtworkDetail>(`/api/artworks/${id}`),
    staleTime: 30_000,
  })
}

// ---------- 変更 ----------

function useInvalidate() {
  const client = useQueryClient()
  return (extra: QueryKey[] = []) => {
    forgetPreloadedMuseum()
    return Promise.all([
      client.invalidateQueries({ queryKey: ['artworks'] }),
      client.invalidateQueries({ queryKey: keys.museum }),
      ...extra.map((queryKey) => client.invalidateQueries({ queryKey })),
    ])
  }
}

/** 作品を保存したら、詳細キャッシュも最新にしておく */
function useStoreArtwork() {
  const client = useQueryClient()
  return (artwork: Artwork) => {
    client.setQueryData<ArtworkDetail>(keys.artwork(artwork.id), (old) => ({
      artwork,
      related: old?.related ?? [],
    }))
  }
}

export function useCreateArtwork() {
  const invalidate = useInvalidate()
  const store = useStoreArtwork()
  return useMutation({
    mutationFn: (form: FormData) =>
      request<Artwork>('/api/artworks', { method: 'POST', body: form }),
    onSuccess: (artwork) => {
      store(artwork)
      return invalidate()
    },
  })
}

export function useUpdateArtwork(id: string) {
  const invalidate = useInvalidate()
  const store = useStoreArtwork()
  return useMutation({
    mutationFn: (form: FormData) =>
      request<Artwork>(`/api/artworks/${id}`, { method: 'PATCH', body: form }),
    onSuccess: (artwork) => {
      store(artwork)
      return invalidate([keys.artwork(id)])
    },
  })
}

export function useDeleteArtwork() {
  const invalidate = useInvalidate()
  const client = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => request<void>(`/api/artworks/${id}`, { method: 'DELETE' }),
    onSuccess: (_, id) => {
      client.removeQueries({ queryKey: keys.artwork(id) })
      return invalidate()
    },
  })
}

export function useFavorite() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ id, favorite }: { id: string; favorite: boolean }) =>
      request<Artwork>(`/api/artworks/${id}/favorite`, jsonInit('PUT', { favorite })),
    // ハートは押した瞬間に反映する
    onMutate: ({ id, favorite }) => {
      client.setQueryData<ArtworkDetail>(keys.artwork(id), (old) =>
        old ? { ...old, artwork: { ...old.artwork, favorite } } : old,
      )
    },
    onSettled: (_, __, { id }) => {
      client.invalidateQueries({ queryKey: keys.artwork(id) })
      client.invalidateQueries({ queryKey: ['artworks'] })
    },
  })
}

export function useDisplay() {
  const invalidate = useInvalidate()
  const store = useStoreArtwork()
  return useMutation({
    mutationFn: ({ id, display }: { id: string; display: boolean }) =>
      request<Artwork>(`/api/artworks/${id}/display`, { method: display ? 'POST' : 'DELETE' }),
    onSuccess: (artwork) => {
      store(artwork)
      return invalidate()
    },
  })
}
