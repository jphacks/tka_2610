// サーバー（Rust）とのやりとりの入口。画面からは `import { useMuseum } from '../api'` のように読み込む。
// 加工・計算はすべて Rust 側で済ませ、ここでは受け取って表示するだけにする。
//
//   types.ts     API の型（Rust の DTO と同じ形）
//   client.ts    通信の共通処理（fetch・エラー・キャッシュの設定）
//   museum.ts    おうちの全体像（/api/museum）と設定
//   home.ts      おへやの配置 JSON の読み書き（模様替え）
//   ages.ts      年齢ごとのおへや（ホームの年齢のチップ・積み上げ・マップ）
//   artworks.ts  作品の一覧・詳細・登録・編集・削除・お気に入り・飾る
//   memories.ts  作品のおもいで（写真・動画・声の記録）の追加・ひとこと・削除
//   albums.ts    アルバム（作品を自分で好きなグループにまとめる）の一覧・作成・名前の変更・削除・作品の出し入れ
//   generator.ts 写真から 3D を作る（試験中。使えるサーバーのときだけ）

export type {
  AgeRoom,
  Album,
  AlbumList,
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
  GeneratorJob,
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
  Memory,
  MemoryCounts,
  MemoryKind,
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
export { MEMORY_LIMITS, hasMemories, kindOfFile, probeMedia, useDeleteMemory, useUpdateMemory, useUploadMemory } from './memories'
export type { UploadMemoryInput } from './memories'
export {
  fetchArtworkDetail,
  prefetchArtwork,
  useArtwork,
  useArtworks,
  useCreateArtwork,
  useDeleteArtwork,
  useDisplay,
  useFavorite,
  useGenerateMemo,
  useGenerateMemoFromImage,
  useUpdateArtwork,
} from './artworks'

export { GENERATOR_LIMITS, useGeneratorEnabled, useGeneratorJob, useRefreshAfterGenerate, useStartGenerate } from './generator'

export { FAVORITES_ALBUM, useAlbum, useAlbumArtworks, useAlbums, useCreateAlbum, useDeleteAlbum, useRenameAlbum } from './albums'

export { useRecollections } from './recollections'
export type { RecallCard, Recollections } from './types'

export { useArtworkDigest } from './recollections'
export type { ArtworkDigest, DigestSlide, DigestScope } from './types'

export { useMiniatureDigest } from './recollections'
export type { MiniatureEntry, MiniatureDigestData } from './types'

export { useTheater } from './recollections'
export type { TheaterData, TheaterMediaSlot, TheaterMemoLine, TheaterPreset, TheaterScene, TheaterSide } from './types'
