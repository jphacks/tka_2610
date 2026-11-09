// 写真から 3D を作る（試験中。Rust: backend/src/generator.rs）。
// サーバーで KT_GENERATOR_ENABLED=1 のときだけ使える。使えないサーバー（本番・Cloudflare 版・古いサーバー）では
// GET /api/generator が {"enabled": false}・404・JSON でない返事になるので、どれも「使えない」として扱い、エラーは出さない。

import { useMutation, useQuery } from '@tanstack/react-query'
import { useInvalidate } from './artworks'
import { keys, request } from './client'
import type { CaptureSession, GeneratorJob } from './types'

/** 送れる写真の数と、1 枚の上限（Rust: generator.rs の MAX_PHOTOS・MAX_PHOTO_BYTES） */
export const GENERATOR_LIMITS = { photos: 8, photoBytes: 20 * 1024 * 1024 }

/** 写真から 3D を作れるサーバーか。どんな失敗も false（エラーにしない） */
async function fetchEnabled(): Promise<boolean> {
  try {
    const response = await fetch('/api/generator')
    if (!response.ok || !response.headers.get('content-type')?.includes('application/json')) return false
    const body: unknown = await response.json()
    return typeof body === 'object' && body !== null && (body as { enabled?: unknown }).enabled === true
  } catch {
    return false
  }
}

export function useGeneratorEnabled() {
  return useQuery({
    queryKey: ['generator', 'enabled'],
    queryFn: fetchEnabled,
    staleTime: Infinity,
    retry: false,
  })
}

/** iPhone で撮った写真の一覧（新しい順）。使えないサーバー（404 など）やエラーは空にする（選ぶところを出さないだけ） */
async function fetchCaptureSessions(): Promise<CaptureSession[]> {
  try {
    const response = await fetch('/api/capture/sessions')
    if (!response.ok || !response.headers.get('content-type')?.includes('application/json')) return []
    const body: unknown = await response.json()
    return Array.isArray(body) ? (body as CaptureSession[]) : []
  } catch {
    return []
  }
}

export function useCaptureSessions() {
  return useQuery({
    queryKey: ['generator', 'capture-sessions'],
    queryFn: fetchCaptureSessions,
    staleTime: 10_000,
    retry: false,
  })
}

/**
 * 写真（1〜8 枚）か iPhone の撮影（captureSession）と、大きさ（cm、カンマ区切り。撮影を選んだときは空なら撮影の大きさ）を送って、
 * 作品の 3D を作り始める。受け付けたら job が返る（202）
 */
export function useStartGenerate(artworkId: string) {
  return useMutation({
    mutationFn: ({ photos = [], captureSession, sizeCm }: { photos?: File[]; captureSession?: string; sizeCm: string }) => {
      const form = new FormData()
      for (const photo of photos) form.append('photos', photo)
      if (captureSession) form.append('capture_session', captureSession)
      if (sizeCm.trim()) form.append('size_cm', sizeCm)
      return request<GeneratorJob>(`/api/artworks/${artworkId}/generate`, { method: 'POST', body: form })
    },
  })
}

/** job の様子。動いているあいだは 3 秒ごとに取り直す */
export function useGeneratorJob(jobId: string | null) {
  return useQuery({
    queryKey: ['generator', 'job', jobId],
    enabled: !!jobId,
    queryFn: () => request<GeneratorJob>(`/api/generator/jobs/${jobId}`),
    refetchInterval: (query) => (query.state.data?.status === 'running' ? 3000 : false),
    staleTime: 0,
    retry: false,
  })
}

/** 作り終わったら、作品の詳細（新しい model_url）と、作品を出す一覧・おへやを取り直す */
export function useRefreshAfterGenerate(artworkId: string) {
  const invalidate = useInvalidate()
  return () => invalidate([keys.artwork(artworkId)])
}
