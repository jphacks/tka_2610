// API の型。Rust が返す JSON と同じ形にしてある（Rust 側の構造体名をコメントに書いている）。
// Rust の DTO に項目を足したら、ここにも足す。

export type Category = 'drawing' | 'craft' | 'photo' | 'other'

// ---------- 作品（backend/src/artworks.rs） ----------

/** 作品 1 件。Rust: ArtworkDto */
export interface Artwork {
  id: string
  catalog_no: number
  catalog_label: string
  title: string
  child_name: string
  age: number | null
  age_label: string
  author_label: string
  made_on: string
  date_short: string
  date_long: string
  memo: string
  category: Category
  category_label: string
  image_url: string
  thumb_url: string
  model_url: string
  model_kind: 'frame' | 'stand' | 'custom'
  image_width: number
  image_height: number
  tint: string
  favorite: boolean
  displayed: boolean
  slot_id: string | null
  room_id: string | null
  room_name: string | null
  floor: string | null
  created_at: string
}

/** 種類ごとの作品数（一覧のタブ用）。Rust: CategoryCount */
export interface CategoryCount {
  id: Category | 'all'
  label: string
  count: number
}

/** GET /api/artworks。Rust: ArtworkList */
export interface ArtworkList {
  items: Artwork[]
  total: number
  categories: CategoryCount[]
}

/** GET /api/artworks/:id。Rust: ArtworkDetail */
export interface ArtworkDetail {
  artwork: Artwork
  related: Artwork[]
}

/** 作品一覧の絞り込み条件（GET /api/artworks のクエリ） */
export interface ListParams {
  category?: Category | 'all'
  sort?: 'recent' | 'made'
  limit?: number
}

// ---------- 博物館（backend/src/museum_api.rs） ----------

/** 展示台 1 つ。位置と向きは博物館 GLB と同じ座標。Rust: SlotView */
export interface SlotView {
  id: string
  position: [number, number, number]
  yaw: number
  floor: '1F' | '2F'
  room_id: string | null
  /** Rust: SlotArtwork */
  artwork: {
    id: string
    title: string
    thumb_url: string
    model_url: string
    tint: string
  } | null
}

/** 展示室。Rust: RoomView */
export interface RoomView {
  id: string
  name: string
  description: string
  capacity: number
  count: number
  floors: string[]
  thumbs: string[]
  tint: string | null
}

/** 見取り図のフロア。Rust: FloorView（backend/src/museum.rs） */
export interface FloorView {
  id: '1F' | '2F'
  label: string
  hide_prefixes: string[]
}

/** GET /api/museum。Rust: MuseumOverview */
export interface Museum {
  today_label: string
  name: string
  owner_name: string
  model_url: string | null
  total_artworks: number
  displayed_count: number
  capacity: number
  floors: FloorView[]
  rooms: RoomView[]
  slots: SlotView[]
  hidden_node_prefixes: string[]
}

/** GET / PUT /api/settings。Rust: Settings */
export interface Settings {
  museum_name: string
  owner_name: string
}
