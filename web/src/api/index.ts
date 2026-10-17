// サーバー（Rust）とのやりとりの入口。画面からは `import { useMuseum } from '../api'` のように読み込む。
// 加工・計算はすべて Rust 側で済ませ、ここでは受け取って表示するだけにする。
//
//   types.ts     API の型（Rust の DTO と同じ形）
//   client.ts    通信の共通処理（fetch・エラー・キャッシュの設定）
//   museum.ts    おうちの全体像（/api/museum）と設定
//   home.ts      おへやの配置 JSON の読み書き（模様替え）
//   ages.ts      年齢ごとのおへや（ホームの年齢のチップ・積み上げ・マップ）
//   artworks.ts  作品の一覧・詳細・登録・編集・削除・お気に入り・飾る

export type {
  AgeRoom,
  AgeRoomSummary,
  Ages,
  AgeStack,
  AgeView,
  Artwork,
  ArtworkDetail,
  ArtworkList,
  ArtworkObject,
  CatalogAsset,
  CatalogSurface,
  Category,
  CategoryCount,
  FloorFinish,
  FloorView,
  FurnitureObject,
  HomeCatalog,
  HomeMaterial,
  HomeTheme,
  House,
  HouseDoor,
  HouseRoom,
  Layout,
  LayoutObject,
  LayoutRoom,
  ListParams,
  Museum,
  RoomId,
  RoomView,
  SavedLayout,
  Settings,
  Side,
  SlotView,
  StackRoom,
  Vec3,
  WallFinish,
} from './types'
export { ApiError, queryClient } from './client'
export { useMuseum, useSettings, useUpdateSettings } from './museum'
export { saveLayoutOnLeave, useLayout, useSaveLayout } from './home'
export { useAddRoom, useAgeStack, useAges, useDeleteRoom } from './ages'
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
