import { useQuery } from '@tanstack/react-query'
import { ApiError, keys, request } from './client'
import type { Recollections } from './types'

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
