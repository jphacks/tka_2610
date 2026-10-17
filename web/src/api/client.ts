// 通信の共通処理。fetch の呼び方、エラーの形、TanStack Query の設定とキャッシュのキー。

import { QueryClient } from '@tanstack/react-query'
import type { ListParams } from './types'

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

/** API を呼ぶ。失敗したら Rust が返した `{ "error": "..." }` の文言で ApiError を投げる */
export async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, init)
  if (!response.ok) {
    let message = `通信に失敗しました (${response.status})`
    try {
      const body = await response.json()
      if (body?.error) message = body.error
    } catch {
      /* JSON でないエラーはそのまま */
    }
    throw new ApiError(response.status, message)
  }
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export const jsonInit = (method: string, body: unknown): RequestInit => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
})

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 10 * 60_000,
      refetchOnWindowFocus: false,
      retry: 1,
    },
  },
})

/** キャッシュのキー。取り直すときもこのキーで指定する */
export const keys = {
  /** おへやごとのおうちの全体像の、共通の先頭（取り直すときはこれで全部のおへや） */
  museum: ['museum'] as const,
  /** おへや roomId のおうちの全体像（GET /api/museum?room=）。省くと「今の年齢のおへや」 */
  museumOf: (roomId?: string | null) => ['museum', roomId ?? 'default'] as const,
  /** おへやの配置 JSON（GET /api/home/layout?room=） */
  layout: ['home', 'layout'] as const,
  /** 年齢ごとのおへやの一覧（GET /api/ages）と、年齢ごとの積み上げ（GET /api/ages/{age}） */
  ages: ['ages'] as const,
  ageStack: (age: number) => ['ages', age] as const,
  settings: ['settings'] as const,
  artworks: (params: ListParams) => ['artworks', params] as const,
  artwork: (id: string) => ['artwork', id] as const,
}
