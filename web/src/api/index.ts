// サーバー（Rust）とのやりとりの入口。画面からは `import { useMuseum } from '../api'` のように読み込む。
// 加工・計算はすべて Rust 側で済ませ、ここでは受け取って表示するだけにする。
//
//   types.ts     API の型（Rust の DTO と同じ形）
//   client.ts    通信の共通処理（fetch・エラー・キャッシュの設定）
//   museum.ts    博物館の全体像と設定
//   artworks.ts  作品の一覧・詳細・登録・編集・削除・お気に入り・展示

export type {
  Artwork,
  ArtworkDetail,
  ArtworkList,
  Category,
  CategoryCount,
  FloorView,
  ListParams,
  Museum,
  RoomView,
  Settings,
  SlotView,
} from './types'
export { ApiError, queryClient } from './client'
export { useMuseum, useSettings, useUpdateSettings } from './museum'
export {
  prefetchArtwork,
  useArtwork,
  useArtworks,
  useCreateArtwork,
  useDeleteArtwork,
  useDisplay,
  useFavorite,
  useUpdateArtwork,
} from './artworks'
