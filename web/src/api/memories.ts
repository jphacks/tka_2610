// 作品のおもいで（写真・動画・声の記録）の追加・ひとことの変更・削除（Rust: backend/src/memories.rs）。
// 送るのは XMLHttpRequest（fetch では送っている途中の進み具合が取れないため。動画は 100 MB まである）。
// 成功すると、作品の詳細・一覧・おへや（3D の印に使う数）を取り直す。

import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ApiError, jsonInit, keys, request } from './client'
import type { Memory, MemoryCounts, MemoryKind } from './types'

/** 種類ごとの送れる大きさの上限（バイト。Rust の MemoryKind::max_bytes と同じ） */
export const MEMORY_LIMITS: Record<MemoryKind, number> = {
  photo: 20 * 1024 * 1024,
  video: 100 * 1024 * 1024,
  audio: 20 * 1024 * 1024,
}

/** おもいでが 1 つでもあるか */
export const hasMemories = (c: MemoryCounts | undefined) => !!c && c.photo + c.video + c.audio > 0

/** 拡張子から種類を決めるとき（Content-Type の無いファイル。サーバーの memories.rs の ACCEPTED と同じ並び） */
const KIND_OF_EXT: Record<string, MemoryKind> = {
  jpg: 'photo',
  jpeg: 'photo',
  png: 'photo',
  webp: 'photo',
  gif: 'photo',
  mp4: 'video',
  m4v: 'video',
  mov: 'video',
  webm: 'video',
  m4a: 'audio',
  aac: 'audio',
  mp3: 'audio',
  ogg: 'audio',
  oga: 'audio',
  opus: 'audio',
  wav: 'audio',
}

/** 選んだファイルの種類（ブラウザが教える Content-Type から。無ければ拡張子から。分からなければ null で、サーバーが断る） */
export function kindOfFile(file: Blob): MemoryKind | null {
  if (file.type.startsWith('image/')) return 'photo'
  if (file.type.startsWith('video/')) return 'video'
  if (file.type.startsWith('audio/')) return 'audio'
  const ext = file instanceof File ? (file.name.split('.').pop() ?? '').toLowerCase() : ''
  return KIND_OF_EXT[ext] ?? null
}

export interface UploadMemoryInput {
  file: Blob
  /** 録音した声など、名前の無い Blob のときのファイル名 */
  fileName?: string
  caption?: string
  durationMs?: number
  width?: number
  height?: number
}

/** 動画と声の長さ・大きさを、ブラウザで読んで測る（読めなければ空。サーバーは無くても受け付ける） */
export function probeMedia(file: Blob): Promise<Pick<UploadMemoryInput, 'durationMs' | 'width' | 'height'>> {
  const kind = kindOfFile(file)
  if (kind !== 'video' && kind !== 'audio') return Promise.resolve({})
  return new Promise((resolve) => {
    const el = document.createElement(kind === 'video' ? 'video' : 'audio')
    const url = URL.createObjectURL(file)
    const done = (value: Pick<UploadMemoryInput, 'durationMs' | 'width' | 'height'>) => {
      URL.revokeObjectURL(url)
      el.removeAttribute('src')
      resolve(value)
    }
    el.preload = 'metadata'
    el.onloadedmetadata = () => {
      const duration = Number.isFinite(el.duration) ? Math.round(el.duration * 1000) : undefined
      const video = el instanceof HTMLVideoElement ? el : null
      done({
        durationMs: duration,
        width: video?.videoWidth || undefined,
        height: video?.videoHeight || undefined,
      })
    }
    el.onerror = () => done({})
    // 読めない形式（Chrome での HEVC の .mov など）で待ち続けないように
    setTimeout(() => done({}), 5000)
    el.src = url
  })
}

function uploadMemory(artworkId: string, input: UploadMemoryInput, onProgress?: (ratio: number) => void) {
  const form = new FormData()
  if (input.caption) form.append('caption', input.caption)
  if (input.durationMs !== undefined) form.append('duration_ms', String(input.durationMs))
  if (input.width !== undefined) form.append('width', String(input.width))
  if (input.height !== undefined) form.append('height', String(input.height))
  // ファイルは最後に送る（サーバーはファイルを流しながら書くので、先にひとことなどを受け取っておく）
  if (input.fileName) form.append('file', input.file, input.fileName)
  else form.append('file', input.file)

  return new Promise<Memory>((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', `/api/artworks/${artworkId}/memories`)
    xhr.responseType = 'json'
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) onProgress?.(e.loaded / e.total)
    }
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) return resolve(xhr.response as Memory)
      const message =
        (xhr.response as { error?: string } | null)?.error ??
        (xhr.status === 413 ? 'ファイルが大きすぎます' : `送れませんでした (${xhr.status})`)
      reject(new ApiError(xhr.status, message))
    }
    xhr.onerror = () => reject(new ApiError(0, '通信に失敗しました'))
    xhr.send(form)
  })
}

/** おもいでが変わったら、作品の詳細・一覧・おへや（3D の印に使う数）を取り直す */
function useRefresh() {
  const client = useQueryClient()
  return (artworkId: string) =>
    Promise.all([
      client.invalidateQueries({ queryKey: keys.artwork(artworkId) }),
      client.invalidateQueries({ queryKey: ['artworks'] }),
      client.invalidateQueries({ queryKey: keys.museum }),
      client.invalidateQueries({ queryKey: keys.ages }),
    ])
}

/** おもいでを 1 つ足す。onProgress に送った割合（0〜1）を渡す */
export function useUploadMemory(artworkId: string) {
  const refresh = useRefresh()
  return useMutation({
    mutationFn: ({ input, onProgress }: { input: UploadMemoryInput; onProgress?: (ratio: number) => void }) =>
      uploadMemory(artworkId, input, onProgress),
    onSuccess: () => refresh(artworkId),
  })
}

/** ひとことを変える */
export function useUpdateMemory(artworkId: string) {
  const refresh = useRefresh()
  return useMutation({
    mutationFn: ({ id, caption }: { id: string; caption: string }) =>
      request<Memory>(`/api/artworks/${artworkId}/memories/${id}`, jsonInit('PATCH', { caption })),
    onSuccess: () => refresh(artworkId),
  })
}

/** おもいでを消す（ファイルも消える） */
export function useDeleteMemory(artworkId: string) {
  const refresh = useRefresh()
  return useMutation({
    mutationFn: (id: string) => request<void>(`/api/artworks/${artworkId}/memories/${id}`, { method: 'DELETE' }),
    onSuccess: () => refresh(artworkId),
  })
}
