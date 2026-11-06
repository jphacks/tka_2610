// アルバムの取得と変更（Rust: backend/src/albums.rs）。作品を自分で好きなグループにまとめる。
// id は UUID か "favorites"（最初からあるお気に入り。作品を入れる・外すと、お気に入りの印が付く・外れる）。
// アルバムの作品の並びは、作品一覧と同じ GET /api/artworks に album を付けて取る（useArtworks({ album })）。

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { jsonInit, keys, request } from './client'
import type { Album, AlbumList } from './types'

/** お気に入りのアルバムの id */
export const FAVORITES_ALBUM = 'favorites'

/** アルバムの一覧（先頭はお気に入り）。artworkId を渡すと、各アルバムにその作品が入っているか（contains）付き */
export function useAlbums(artworkId?: string) {
  return useQuery({
    queryKey: keys.albumsOf(artworkId),
    queryFn: () => request<AlbumList>(`/api/albums${artworkId ? `?artwork=${encodeURIComponent(artworkId)}` : ''}`),
  })
}

export function useAlbum(id: string | undefined) {
  const client = useQueryClient()
  return useQuery({
    queryKey: keys.album(id ?? ''),
    enabled: !!id,
    queryFn: () => request<Album>(`/api/albums/${encodeURIComponent(id ?? '')}`),
    // 棚で取得済みなら、待たずに名前を出す
    placeholderData: () => client.getQueryData<AlbumList>(keys.albumsOf())?.items.find((a) => a.id === id),
  })
}

/** アルバムが変わったら、アルバムと作品の一覧を取り直す（お気に入りなら作品の詳細のハートも） */
function useAlbumsChanged() {
  const client = useQueryClient()
  return (favorites = false) =>
    Promise.all([
      client.invalidateQueries({ queryKey: keys.albums }),
      client.invalidateQueries({ queryKey: ['artworks'] }),
      ...(favorites
        ? [client.invalidateQueries({ queryKey: ['artwork'] }), client.invalidateQueries({ queryKey: keys.recollections })]
        : []),
    ])
}

/** アルバムを作る。artworkIds を渡すと、作ると同時にその作品を入れる */
export function useCreateAlbum() {
  const changed = useAlbumsChanged()
  return useMutation({
    mutationFn: ({ name, artworkIds = [] }: { name: string; artworkIds?: string[] }) =>
      request<Album>('/api/albums', jsonInit('POST', { name, artwork_ids: artworkIds })),
    onSuccess: () => changed(),
  })
}

export function useRenameAlbum(id: string) {
  const changed = useAlbumsChanged()
  return useMutation({
    mutationFn: (name: string) => request<Album>(`/api/albums/${encodeURIComponent(id)}`, jsonInit('PATCH', { name })),
    onSuccess: () => changed(),
  })
}

/** アルバムを消す。入っていた作品は残る */
export function useDeleteAlbum() {
  const client = useQueryClient()
  const changed = useAlbumsChanged()
  return useMutation({
    mutationFn: (id: string) => request<void>(`/api/albums/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    onSuccess: (_, id) => {
      client.removeQueries({ queryKey: keys.album(id) })
      return changed()
    },
  })
}

/** アルバム albumId に作品を入れる（add）・外す（remove） */
export function useAlbumArtworks() {
  const changed = useAlbumsChanged()
  return useMutation({
    mutationFn: ({ albumId, add = [], remove = [] }: { albumId: string; add?: string[]; remove?: string[] }) =>
      request<Album>(`/api/albums/${encodeURIComponent(albumId)}/artworks`, jsonInit('PUT', { add, remove })),
    onSuccess: (_, { albumId }) => changed(albumId === FAVORITES_ALBUM),
  })
}
