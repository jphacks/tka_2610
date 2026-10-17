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
  museum: ['museum'] as const,
  settings: ['settings'] as const,
  artworks: (params: ListParams) => ['artworks', params] as const,
  artwork: (id: string) => ['artwork', id] as const,
}
