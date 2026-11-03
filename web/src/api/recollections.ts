import { useQuery } from '@tanstack/react-query'
import { ApiError, keys, request } from './client'
import type { ArtworkDigest, DigestScope, MiniatureDigestData, Recollections } from './types'

export function useRecollections(age?: string | null) {
  const search = new URLSearchParams()
  if (age) search.set('age', age)
  return useQuery({
    placeholderData: (previous) => previous,
    queryKey: [...keys.recollections, age ?? 'all'],
    queryFn: async () => {
      try {
        return await request<Recollections>(`/api/recollections?${search}`)
      } catch (error) {
        // 古いbackendは未対応のAPIにもReactのHTMLを返すため、JSONとして読めない。
        if (error instanceof SyntaxError) {
          throw new ApiError(502, '振り返り機能のAPIを読み込めませんでした。backendを再起動して、もう一度お試しください。')
        }
        throw error
      }
    },
  })
}


export function useArtworkDigest(scope: DigestScope, drawingsOnly: boolean) {
  const search = new URLSearchParams({ scope })
  if (drawingsOnly) search.set('category', 'drawing')
  return useQuery({
    queryKey: [...keys.recollections, 'digest', scope, drawingsOnly],
    queryFn: async () => {
      try { return await request<ArtworkDigest>(`/api/recollections/digest?${search}`) }
      catch (error) {
        if (error instanceof SyntaxError) throw new ApiError(502, 'ダイジェストのAPIを読み込めませんでした。backendを再起動してください。')
        throw error
      }
    },
    staleTime: 0,
    refetchOnWindowFocus: false,
  })
}


export function useMiniatureDigest(scope: DigestScope, drawingsOnly: boolean) {
  const search = new URLSearchParams({ scope })
  if (drawingsOnly) search.set('category', 'drawing')
  return useQuery({
    placeholderData: previous => previous,
    queryKey: [...keys.recollections, 'miniature', scope, drawingsOnly],
    staleTime: 0,
    refetchOnWindowFocus: false,
    queryFn: async () => {
      try { return await request<MiniatureDigestData>(`/api/recollections/miniature?${search}`) }
      catch (error) {
        if (error instanceof SyntaxError) throw new ApiError(502, '3D鑑賞のAPIを読み込めませんでした。backendを再起動してください。')
        throw error
      }
    },
  })
}
