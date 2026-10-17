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
  /** 登録時に入れた年齢（任意）。表示用 */
  age: number | null
  age_label: string
  /** 作ったときの年齢（子どもの誕生日と作成日から。誕生日が無ければ age、それも無ければ 0）。作品はこの年齢のおへやに飾る */
  age_at_made: number
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
  /** モデルの実寸（幅・高さ・奥行き, m）。登録時に GLB から読み取った値。読み取れなかった作品は null */
  model_size: Vec3 | null
  image_width: number
  image_height: number
  tint: string
  favorite: boolean
  displayed: boolean
  slot_id: string | null
  /** 飾っているおへやの id（AgeRoom.id）。飾っていなければ null */
  room_id: string | null
  /** 飾っているおへやの名前（「4さいのおへや 2」など） */
  room_name: string | null
  floor: string | null
  /** おもいで（写真・動画・声の記録）の数 */
  memory_counts: MemoryCounts
  created_at: string
}

// ---------- おもいで（backend/src/memories.rs） ----------

export type MemoryKind = 'photo' | 'video' | 'audio'

/** 作品ごとの、おもいでの数。Rust: MemoryCounts */
export interface MemoryCounts {
  photo: number
  video: number
  audio: number
}

/** 作品に付けた写真・動画・声の記録 1 つ。Rust: MemoryDto */
export interface Memory {
  id: string
  artwork_id: string
  kind: MemoryKind
  url: string
  /** 写真の小さい画像（動画と声は null） */
  thumb_url: string | null
  mime: string
  bytes: number
  /** 動画と声の長さ（ミリ秒。分からなければ null） */
  duration_ms: number | null
  /** 長さの表示（「0:12」。分からなければ null） */
  duration_label: string | null
  width: number | null
  height: number | null
  /** ひとこと（80 文字まで） */
  caption: string
  created_at: string
  /** 足した日（「2026年10月18日」） */
  date_label: string
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
  /** おもいで（足した順） */
  memories: Memory[]
}

/** 作品一覧の絞り込み条件（GET /api/artworks のクエリ） */
export interface ListParams {
  category?: Category | 'all'
  sort?: 'recent' | 'made'
  limit?: number
}

// ---------- おうちの配置（backend/src/home.rs・home_api.rs） ----------

export type Vec3 = [number, number, number]
/**
 * 部屋の名前。今の家は中央のリビング（hub、10 × 10 m）だけ。
 * left・right・front は以前あった部屋（hub の西・東・北）。部屋を戻したときのために型に残している（API には出てこない）
 */
export type RoomId = 'hub' | 'left' | 'right' | 'front'
/** 壁の向き（north = −Z、south = +Z、west = −X、east = +X） */
export type Side = 'north' | 'south' | 'east' | 'west'
/**
 * 壁紙・床材のプリセット名。Rust: home.rs の WALLS / FLOORS（一緒に変える）。
 * 前半は家のキットの素材名、後半は内装セット（finish-pack）の素材名（catalog.materials のキーと同じ）
 */
export type WallFinish =
  | 'plaster'
  | 'oak'
  | 'brick'
  | 'limestone'
  | 'nordic_chalk'
  | 'sage_limewash'
  | 'mushroom_limewash'
  | 'warm_cream'
  | 'soft_brick'
export type FloorFinish = 'oak' | 'limestone' | 'white_oak' | 'pale_ash' | 'warm_walnut' | 'carrara_marble' | 'nero_marble'

/** 配置 JSON の部屋 1 つ。Rust: home.rs の Room */
export interface LayoutRoom {
  enabled: boolean
  /** 幅・奥行き（m）。リビングは 10 × 10、ほかの部屋は 8 × 8 で固定（違えばサーバーが 400） */
  width: number
  depth: number
  wall: WallFinish
  floor: FloorFinish
}

/**
 * 配置 JSON の家具 1 つ。Rust: home.rs の LayoutObject::Furniture
 * position は所属する部屋（roomId）の中の位置（m。その部屋の中心が原点、y は常に 0）。
 * 世界座標は部屋の中心（house.rooms[].origin）+ position（回転はなく、平行移動だけ）。rotationY は向き（ラジアン。正面は +Z）
 */
export interface FurnitureObject {
  kind: 'furniture'
  id: string
  /** catalog.assets の id */
  assetId: string
  roomId: RoomId
  position: Vec3
  rotationY: number
}

/**
 * 配置 JSON の作品 1 つ。Rust: home.rs の LayoutObject::Artwork
 * parentId があれば、その家具の面（surface。省くと天板）の上に置く。position は親の家具の「回す前」の向きで、
 * 面の中心（catalog の surfaces[].anchor）を原点にした位置（部屋は親の家具の部屋）。
 * parentId が無ければ床に置く（家具と同じく、roomId の部屋の中心を原点にした位置）
 */
export interface ArtworkObject {
  kind: 'artwork'
  id: string
  artworkId: string
  parentId?: string
  /** 載せている面（本棚の段 "shelf1" など）。天板（"top"）のときは省く */
  surface?: string
  /** 床に置く作品の部屋。家具の上の作品には付けない（親の家具の部屋になる） */
  roomId?: RoomId
  position: Vec3
  rotationY: number
}

export type LayoutObject = FurnitureObject | ArtworkObject

/**
 * おうちの配置 JSON（v5）。家具と作品をどこに置くかの、ただ 1 つの正。Rust: home.rs の Layout
 * rooms は house.rooms にある部屋だけ（今はリビングの hub だけ）。enabled: true で、壁紙・床材（wall / floor）は部屋ごと。
 * v1〜v4 はサーバーが v5 に上げて返す（v4 までの左・右・前の部屋の物は外し、v3 までは壁ぎわの物を広がった壁の方へ動かす）
 * 注意：API の中で、この配置 JSON（Layout とその中身）だけは camelCase。
 * 家のキットの JSON と同じ形にしておくため。ほかの API の項目はすべて snake_case のまま。
 */
export interface Layout {
  schemaVersion: 5
  kitVersion: string
  rooms: { hub: LayoutRoom } & Partial<Record<RoomId, LayoutRoom>>
  objects: LayoutObject[]
}

/** GET / PUT /api/home/layout の応答。Rust: home_api.rs */
/** 年齢ごとのおへや 1 つ。Rust: home_api.rs の RoomInfo */
export interface AgeRoom {
  id: string
  /** 作品を作ったときの年齢 */
  age: number
  /** その年齢の中での階（0 が 1 階） */
  floor: number
  /** 「4さいのおへや」「4さいのおへや 2」 */
  name: string
}

/** おへやのリストの 1 つ。Rust: ages_api.rs の RoomSummary */
export interface AgeRoomSummary extends AgeRoom {
  count: number
  capacity: number
  thumbs: string[]
  tint: string | null
}

/** 年齢 1 つ。Rust: ages_api.rs の AgeView */
export interface AgeView {
  age: number
  /** 「4さい」 */
  label: string
  artwork_count: number
  displayed_count: number
  /** 1 階から */
  rooms: AgeRoomSummary[]
}

/** GET /api/ages。Rust: ages_api.rs の AgesOverview */
export interface Ages {
  name: string
  child_birthday: string | null
  current_age: number | null
  total_artworks: number
  /** 年齢の小さい順 */
  ages: AgeView[]
}

/** 積み上げの建物の 1 階分。Rust: ages_api.rs の StackRoom */
export interface StackRoom {
  room: AgeRoom
  count: number
  capacity: number
  layout: Layout
  slots: SlotView[]
}

/** GET /api/ages/{age}。Rust: ages_api.rs の AgeStack */
export interface AgeStack {
  age: number
  label: string
  house: House
  catalog: HomeCatalog
  /** 1 階から */
  rooms: StackRoom[]
}

export interface SavedLayout {
  /** 配置のおへや */
  room: AgeRoom
  layout: Layout
  updated_at: string
}

/** 家具 1 種類。Rust: museum_api.rs の catalog.assets（home.rs の Asset から作る。catalog は snake_case） */
export interface CatalogAsset {
  id: string
  name: string
  name_ja: string
  /** GLB の URL（/home-assets/modules/〇〇.glb） */
  file_url: string
  category: string
  /** 幅・高さ・奥行き（m）。原点は底面の中心、正面は +Z */
  dimensions_meters: Vec3
  /** 天板の中心（家のキットの値）。作品を載せる面は surfaces */
  top_anchor: Vec3 | null
  /** 'floor_decor'（ラグ）はほかの家具と重ねて置ける・上を歩ける */
  layer: 'floor_decor' | null
  /** 作品を載せられるか（面が 1 つ以上ある） */
  support: boolean
  /** 作品を載せられる面（天板・本棚の段など）。載せられない家具は空 */
  surfaces: CatalogSurface[]
}

/** 家具の上で作品を載せられる面。Rust: museum_api.rs の SurfaceView（home.rs の Surface から作る） */
export interface CatalogSurface {
  /** "top"（天板）。本棚の段は "shelf1"・"shelf2"… */
  id: string
  /** 面の中心（家具から見た位置、回す前。y は面の高さ） */
  anchor: Vec3
  /** 作品を置ける平らな範囲（幅・奥行き, m）。中心は anchor */
  size: [number, number]
  /** この面に載せる作品を収める範囲（幅・高さ・奥行き, m）。棚の段では上の棚板にぶつからない高さ */
  art_fit: Vec3
}

/** 壁紙と床材の組み合わせ。Rust: home.rs の Theme */
export interface HomeTheme {
  id: string
  name: string
  wall: WallFinish
  floor: FloorFinish
}

/** 素材のテクスチャ。Rust: museum_api.rs の catalog.materials（home.rs の Material から作る） */
export interface HomeMaterial {
  /** テクスチャ 1 枚が何 m 四方か（幅・高さ） */
  tile_meters: [number, number]
  base_url: string
  normal_url: string
  orm_url: string
}

/** 置ける家具・テーマ・素材の一覧（サーバーの定数）。Rust: museum_api.rs の catalog（home.rs の Catalog から作る） */
export interface HomeCatalog {
  kit_version: string
  assets: CatalogAsset[]
  themes: HomeTheme[]
  materials: Record<string, HomeMaterial>
}

// ---------- 家の建物（部屋の定義。backend/src/home.rs の ROOM_DEFS → museum_api.rs の house） ----------

/** 部屋の壁の出入口（開口）。Rust: museum_api.rs の DoorView（home.rs の Door） */
export interface HouseDoor {
  /** 出入口のある壁 */
  side: Side
  /** 壁の中心から出入口の中心までのずれ（m。north / south の壁は +X、east / west の壁は +Z が正。今の家はどれも 0） */
  offset: number
  /** 通れる幅（m） */
  clear_width: number
  /** 通れる高さ（m） */
  height: number
}

/**
 * 部屋 1 つの定義。Rust: museum_api.rs の RoomDefView（home.rs の ROOM_DEFS から作る）
 * 部屋どうしは平行移動だけ（回転なし）。部屋の中の位置（配置 JSON の position）+ origin が世界座標
 */
export interface HouseRoom {
  id: RoomId
  /** 部屋の名前（「中央のリビング」など。400 の文言にも使われる） */
  name: string
  /** 部屋の中心の世界座標（x, z, m）。床は y = 0 */
  origin: [number, number]
  /** 内寸（幅 x・奥行き z, m） */
  size: [number, number]
  /** 部屋の建物（壁・床・出入口）の GLB。部屋の中心が原点。ファイルが無ければ null（その部屋の建物は描かない） */
  model_url: string | null
  doors: HouseDoor[]
  /**
   * 南東から見るときに上の部分をカットする壁（GLB の cutaway の印と同じ向き）。
   * 今の Web は使わない（カットする壁はカメラの位置から決める。three/scenes/home/cutaway.ts）
   */
  cutaway: Side[]
}

/** 家の建物（部屋の定義一式）。Rust: museum_api.rs の HouseView */
export interface House {
  rooms: HouseRoom[]
  /** 壁の厚さ（m）。隣の部屋とは hub の壁を共有する */
  wall_thickness: number
}

// ---------- おうちの全体像（backend/src/museum_api.rs） ----------

/** 飾っている作品の情報。Rust: SlotArtwork */
export interface SlotArtwork {
  id: string
  title: string
  thumb_url: string
  model_url: string
  tint: string
  /** 'custom'（実寸の工作の GLB）は、置き場所より小さくても拡大しない */
  model_kind: 'frame' | 'stand' | 'custom'
  /** モデルの実寸（幅・高さ・奥行き, m。拡縮する前）。分からない作品は null（枠 fit に合わせて表示する） */
  model_size: Vec3 | null
  /** おもいでの数（3D の印・鑑賞モードの声） */
  memory_counts: MemoryCounts
}

/**
 * 飾っている作品 1 つの置き場所。配置 JSON の作品から Rust が計算したもの。Rust: SlotView
 * （名前は博物館の「展示台」のころのまま。中身は作品の配置だけ）
 */
export interface SlotView {
  /** 配置 JSON の作品の id（object id） */
  id: string
  /** 作品を置く面の中心（世界座標, m。部屋の中心 origin 込み。天板の上なら天板の高さ、床なら 0） */
  position: Vec3
  /** 作品の向き（度）。0 で正面が +Z */
  yaw: number
  floor: '1F'
  /** 作品が実際にある部屋（家具の上なら親の家具の部屋） */
  room_id: string | null
  in_main_model: boolean
  /** 作品を収める範囲（幅・高さ・奥行き, m）。載せている面の art_fit、床なら床置きの枠 */
  fit: Vec3
  /**
   * 作品を表示する拡縮率。fit と作品の向き（配置 JSON の rotationY）から Rust の display_scale で決めた値
   * （placement.ts の displayScale と同じ式）。実寸（artwork.model_size）が分からない作品は null
   */
  scale: number | null
  /** 載せている家具の object id。床置きは null */
  parent_id: string | null
  /** 載せている面（"top"・"shelf1" など）。床置きは null */
  surface: string | null
  artwork: SlotArtwork
}

/** 部屋。Rust: RoomView */
export interface RoomView {
  id: string
  name: string
  description: string
  /** 博物館の別館のころの項目。家では常に false。部屋ごとの作品の数は capacity・count */
  annex: boolean
  capacity: number
  count: number
  floors: string[]
  thumbs: string[]
  tint: string | null
}

/** フロア。家は 1F だけ（博物館のころの項目を残している）。Rust: FloorView */
export interface FloorView {
  id: '1F'
  label: string
  hide_prefixes: string[]
}

/** GET /api/museum。Rust: MuseumOverview */
export interface Museum {
  /** このおへや（?room= のおへや。省いたら今の年齢のおへや）。layout・slots・capacity はこのおへやのもの */
  room: AgeRoom
  today_label: string
  name: string
  owner_name: string
  /**
   * 1 つの GLB の家の建物（壁・床だけ。8 × 8 m のリビング、中心が原点、床が y = 0）。
   * 部屋ごとの建物は house.rooms[].model_url。house が無い古いサーバーのときだけ、Web はこちらを使う
   */
  model_url: string | null
  /** 一人称で歩く画面用の別の GLB（リビングの建物の代わりに使う）。ふだんは null */
  walk_model_url: string | null
  /** 家の建物（部屋の定義と部屋ごとの GLB。今はリビングだけ）。古いサーバーには無い（そのときは model_url のリビング 1 部屋） */
  house?: House | null
  total_artworks: number
  displayed_count: number
  /** 作品を飾れる場所の数（作品を載せられる家具の置き場所の合計） */
  capacity: number
  floors: FloorView[]
  rooms: RoomView[]
  /** 飾っている作品の置き場所（作品の配置だけ） */
  slots: SlotView[]
  /** 博物館のころの項目（建物のノードを名前で隠す）。家では常に空 */
  hidden_node_prefixes: string[]
  /** 配置 JSON（camelCase） */
  layout: Layout
  catalog: HomeCatalog
}

/** GET / PUT /api/settings。Rust: Settings */
export interface Settings {
  museum_name: string
  owner_name: string
  /** 子どもの誕生日（"2021-06-01"）。作品を作ったときの年齢（おへや）を決める。送るときに省くと今のまま */
  child_birthday?: string | null
}
