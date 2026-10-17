//! おうちの配置 JSON (v4) の型・検証・座標の計算。DB を使わない純粋な処理だけを置く。
//!
//! - 座標はメートル、Y-up。中央のリビング (hub) の中心が世界の原点で、床は y = 0。入口は南 (+Z) 側。
//! - 家は 4 部屋 (ROOM_DEFS)。部屋は平行移動だけで回さない。部屋ごとに世界での中心 origin を持つ。
//!   家具と床置きの作品の position は、所属する部屋 (roomId) の中心から見た位置で、世界 = origin + position。
//!   家具の上の作品は親の家具から決まる (部屋の平行移動は親に 1 回だけ掛かる)。
//! - 家具の原点は底面の中心、正面は +Z。rotationY θ で +Z は (sinθ, 0, cosθ) を向く (three.js と同じ)。
//! - 家具に載せる作品の position は、親の家具の「回す前」の向きで、載せる面 (天板・本棚の段など。surface) の中心からの位置。
//! - 置けるかどうかの判定は、家のキット (MemoryMuseum_Home の museum-kit.js の canPlace) を書き直したもの。
//!   Web の `web/src/three/scenes/home/placement.ts` と同じ計算にしておくこと (総当たり表 testdata/placement-cases.json で照合する)。
//! - この配置 JSON だけは camelCase (キットの JSON と同じ形)。ほかの API の項目は snake_case。

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    f64::consts::{PI, TAU},
    sync::LazyLock,
};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

/// 配置 JSON の版。4 は 10 × 10 と 8 × 8 の 4 部屋の家 (1〜3 は読み込むときに 4 に上げる)。
/// 3 は 8 × 8 と 6 × 6 の 4 部屋 (V3_ROOM_SIZES)、2 はリビングだけ、1 はキットの JSON
pub const SCHEMA_VERSION: u32 = 4;
pub const KIT_VERSION: &str = "1.1.0-home";

/// 中央のリビングの id。床置きの作品で roomId を省いたときもこの部屋
pub const HUB_ID: &str = "hub";
pub const FLOOR_ID: &str = "1F";

// =============================
// 部屋の定義 (家の形はここだけに書く。/api/museum の house で Web に渡す)
// =============================

/// 壁の向き。北 = −Z (入口から入って正面)、南 = +Z (入口側)、西 = −X (左)、東 = +X (右)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    North,
    South,
    West,
    East,
}

impl Side {
    /// API の値 ("north" / "south" / "east" / "west")
    pub fn as_str(self) -> &'static str {
        match self {
            Side::North => "north",
            Side::South => "south",
            Side::West => "west",
            Side::East => "east",
        }
    }
}

/// 部屋の壁の出入口 (開口)
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Door {
    pub side: Side,
    /// 壁の中心からのずれ (m)。北・南の壁は +X 向き、西・東の壁は +Z 向きが正。今の家はどれも 0 (壁の中央)
    pub offset: f64,
    /// 通れる幅 (m)
    pub clear_width: f64,
    /// 開口の高さ (m)
    pub height: f64,
}

/// 部屋 1 つの形。家具・床置きの作品の位置は origin から見たローカル座標
#[derive(Debug)]
pub struct RoomDef {
    pub id: &'static str,
    /// 画面に出す名前 (400 の文言にも使う)
    pub name: &'static str,
    /// 部屋の中心の世界座標 (x, z)
    pub origin: [f64; 2],
    /// 内寸 (幅 = X 方向, 奥行き = Z 方向, m)。壁の内側の面は origin ± size / 2
    pub size: [f64; 2],
    /// 建物の GLB のファイル名 (部屋のモデルのフォルダ。既定は static/models/rooms、HOME_ROOM_MODELS_DIR で変えられる)
    pub model: &'static str,
    pub doors: &'static [Door],
    /// 見下ろすときに切り取る壁の向き (GLB の cutaway タグと同じ)
    pub cutaway: &'static [Side],
}

/// 壁の厚さ (m)。隣の部屋は hub の壁を共有する (hub の内壁 ±5.0、外面 ±5.24 が隣の部屋の内壁)
pub const WALL_THICKNESS: f64 = 0.24;

/// 出入口 (キット v1 の portal_arch_3m: バウ 3.0 m・通れる幅 2.10 m・アーチの頂 2.60 m)
const fn portal(side: Side) -> Door {
    Door { side, offset: 0.0, clear_width: 2.10, height: 2.60 }
}

/// 家の 4 部屋 (この順に API へ出す。作品の自動配置もこの順に部屋を探す)。
///
/// - hub (中央のリビング): 10 × 10 m、世界の原点。西・東・北の壁の中央に出入口
/// - left・right・front: 8 × 8 m
/// - left (左の部屋): −X 側。hub の西の壁を共有し、出入口は hub 側 (東)
/// - right (右の部屋): +X 側。出入口は西
/// - front (前の部屋): **−Z 側** (北。南の入口から入ると正面)。出入口は南。
///   キット v1 は front を +Z (手前) に置く定義だが、この家では逆にしている
///   (v2 までの front は使っていない仮の部屋で、家具も作品も無かったので影響はない)
///
/// 隣の部屋の中心は hub の中心から 5.0 + 0.24 + 4.0 = 9.24 m。
/// 大きさを変えたら、建物の GLB (tools/home-rooms/build_rooms.py) と、保存済みの配置を上げる処理 (widen_rooms) も合わせる
pub static ROOM_DEFS: [RoomDef; 4] = [
    RoomDef {
        id: "hub",
        name: "中央のリビング",
        origin: [0.0, 0.0],
        size: [10.0, 10.0],
        model: "hub.glb",
        doors: &[portal(Side::West), portal(Side::East), portal(Side::North)],
        cutaway: &[Side::South, Side::East],
    },
    RoomDef {
        id: "left",
        name: "左の部屋",
        origin: [-9.24, 0.0],
        size: [8.0, 8.0],
        model: "left.glb",
        doors: &[portal(Side::East)],
        cutaway: &[Side::South],
    },
    RoomDef {
        id: "right",
        name: "右の部屋",
        origin: [9.24, 0.0],
        size: [8.0, 8.0],
        model: "right.glb",
        doors: &[portal(Side::West)],
        cutaway: &[Side::South, Side::East],
    },
    RoomDef {
        id: "front",
        name: "前の部屋",
        origin: [0.0, -9.24],
        size: [8.0, 8.0],
        model: "front.glb",
        doors: &[portal(Side::South)],
        cutaway: &[Side::East],
    },
];

/// v3 の部屋の内寸 (hub 8 × 8、ほかは 6 × 6)。v3 までの配置を読むときに、部屋が広がった分だけ壁ぎわの物を動かすのに使う
const V3_ROOM_SIZES: [(&str, [f64; 2]); 4] = [("hub", [8.0, 8.0]), ("left", [6.0, 6.0]), ("right", [6.0, 6.0]), ("front", [6.0, 6.0])];

fn v3_room_size(id: &str) -> [f64; 2] {
    V3_ROOM_SIZES.iter().find(|(room, _)| *room == id).map_or([0.0; 2], |(_, size)| *size)
}

/// 壁からこれより近い物を「壁ぎわの物」として、v3 から v4 に上げるときに壁といっしょに動かす (足元の外接長方形と壁の内側の面の距離, m)
const WALL_HUG: f64 = 0.6;

/// id の部屋 (hub / left / right / front)
pub fn room_def(id: &str) -> Option<&'static RoomDef> {
    ROOM_DEFS.iter().find(|d| d.id == id)
}

/// 部屋を探す順番 (hub が 0)。知らない id は最後
fn room_rank(id: &str) -> usize {
    ROOM_DEFS.iter().position(|d| d.id == id).unwrap_or(ROOM_DEFS.len())
}

/// 出入口の前の、新しく置いたり動かしたりできない場所 (キットと同じ大きさ)。
/// 幅は出入口の中心から ±1.27 m (2.54 m)、奥行きは壁の内側の面から 1.15 m
pub const DOOR_ZONE_WIDTH: f64 = 2.54;
pub const DOOR_ZONE_DEPTH: f64 = 1.15;

/// 壁紙と床材の名前 (配置 JSON の rooms.<部屋 id>.wall / floor)。キットの 4 種と 2 種のあとが内装セット (finish-pack) のもの。
/// 内装セットの名前は catalog.json の materials のキーと同じ。Web の WallFinish / FloorFinish (api/types.ts) と一緒に変える。
/// 古いサーバーはここに無い名前の配置を読めず、起動時に初期配置に戻すので、名前を足したら全員の更新を待ってから共有の DB で使う
const WALLS: [&str; 9] = [
    "plaster",
    "oak",
    "brick",
    "limestone",
    "nordic_chalk",
    "sage_limewash",
    "mushroom_limewash",
    "warm_cream",
    "soft_brick",
];
const FLOORS: [&str; 7] = ["oak", "limestone", "white_oak", "pale_ash", "warm_walnut", "carrara_marble", "nero_marble"];

const MAX_OBJECTS: usize = 120;
const MAX_ID_LEN: usize = 40;
const MAX_COORD: f64 = 15.0;
/// 壁から家具まで空ける距離 (m)
const WALL_MARGIN: f64 = 0.12;
/// 重なり・はみ出しの許容 (m)。ぴったり接するのは重なりにしない
const TOLERANCE: f64 = 0.002;
/// 天板の縁から作品の枠まで空ける距離 (m)
const TOP_INSET: f64 = 0.03;
/// 天板に載せる作品の枠 (幅・奥行きの上限と高さ)
const ART_FIT_MAX: f64 = 0.56;
const ART_FIT_HEIGHT: f64 = 0.62;
/// 面を幅・奥行き方向に 2 つ以上に分けるときの、作品の枠の幅・奥行きの下限
const ART_FIT_MIN_SIDE: f64 = 0.5;
/// 棚の段で、作品の上に空けるすき間 (m)
const SHELF_HEADROOM: f64 = 0.04;
/// 床に置く作品の枠。家具と同じく 0.8 × 0.8 の場所を取る
pub const FLOOR_ART_FIT: [f64; 3] = [0.8, 1.0, 0.8];
/// 家具の天板の面の id。作品の surface を省いたときはこの面
pub const TOP_SURFACE: &str = "top";

/// 作品を自動で置くときに探す家具の順番。本棚・ベンチ・スツールは、今までの家具が埋まってから使う
const SUPPORT_ORDER: [&str; 10] = [
    "home_display_shelf",
    "home_console",
    "home_craft_desk",
    "home_coffee_table",
    "plinth_low",
    "plinth_ivory",
    "plinth_slim",
    "home_bookshelf",
    "bench_oak",
    "home_stool",
];

// =============================
// 配置 JSON の型
// =============================

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    pub schema_version: u32,
    pub kit_version: String,
    pub rooms: Rooms,
    pub objects: Vec<LayoutObject>,
}

/// 4 部屋の仕上げ (壁紙・床材)。どの部屋も enabled: true で、大きさは ROOM_DEFS のまま
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Rooms {
    pub hub: Room,
    pub left: Room,
    pub right: Room,
    pub front: Room,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Room {
    /// 常に true (キットの JSON と同じ形にするために残している)
    pub enabled: bool,
    /// 内寸 (m)。hub は 10、ほかは 8 で変えられない
    pub width: i64,
    pub depth: i64,
    /// 壁紙 (WALLS のどれか。plaster / oak / brick / limestone と内装セットの 5 種)
    pub wall: String,
    /// 床材 (FLOORS のどれか。oak / limestone と内装セットの 5 種)
    pub floor: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LayoutObject {
    Furniture(Furniture),
    Artwork(ArtworkObject),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Furniture {
    pub id: String,
    pub asset_id: String,
    /// 置いている部屋 (hub / left / right / front)
    pub room_id: String,
    /// 部屋の中心から見た位置
    pub position: [f64; 3],
    pub rotation_y: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtworkObject {
    pub id: String,
    pub artwork_id: Uuid,
    /// 載せている家具の id。無ければ床に置く
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    /// 床に置くときだけ、置いている部屋 (hub / left / right / front)。
    /// 家具の上の作品は None (部屋は親の家具の部屋)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room_id: Option<String>,
    /// 親の家具のどの面に載せるか (本棚の段など)。天板 ("top") のときは省く
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
    pub position: [f64; 3],
    pub rotation_y: f64,
}

impl ArtworkObject {
    /// 載せている面の id (省いていれば天板)
    pub fn surface_id(&self) -> &str {
        self.surface.as_deref().unwrap_or(TOP_SURFACE)
    }
}

impl LayoutObject {
    pub fn id(&self) -> &str {
        match self {
            LayoutObject::Furniture(f) => &f.id,
            LayoutObject::Artwork(a) => &a.id,
        }
    }
}

impl Layout {
    pub fn furniture(&self, id: &str) -> Option<&Furniture> {
        self.objects.iter().find_map(|o| match o {
            LayoutObject::Furniture(f) if f.id == id => Some(f),
            _ => None,
        })
    }

    pub fn artworks(&self) -> impl Iterator<Item = &ArtworkObject> {
        self.objects.iter().filter_map(|o| match o {
            LayoutObject::Artwork(a) => Some(a),
            _ => None,
        })
    }

    pub fn artwork_for(&self, artwork_id: Uuid) -> Option<&ArtworkObject> {
        self.artworks().find(|a| a.artwork_id == artwork_id)
    }

    /// 作品の配置を外す。外したら true
    pub fn remove_artwork(&mut self, artwork_id: Uuid) -> bool {
        let before = self.objects.len();
        self.objects
            .retain(|o| !matches!(o, LayoutObject::Artwork(a) if a.artwork_id == artwork_id));
        self.objects.len() != before
    }

    /// 物のある部屋。家具と床置きの作品は自分の roomId、家具の上の作品は親の家具の部屋
    pub fn room_of(&self, obj: &LayoutObject) -> Option<&'static RoomDef> {
        match obj {
            LayoutObject::Furniture(f) => room_def(&f.room_id),
            LayoutObject::Artwork(a) => match &a.parent_id {
                Some(parent_id) => room_def(&self.furniture(parent_id)?.room_id),
                None => room_def(a.room_id.as_deref().unwrap_or(HUB_ID)),
            },
        }
    }

    /// object id の物のある部屋 (artworks.slot_id から作品の部屋を引く)
    pub fn room_of_id(&self, id: &str) -> Option<&'static RoomDef> {
        self.room_of(self.objects.iter().find(|o| o.id() == id)?)
    }
}

/// 位置・向きがこれより小さく違うだけなら「動かしていない」とみなす (m・ラジアン)。
/// Web が JSON を読み書きしたときの丸めで、動かしていない物を動かした扱いにしないため
const MOVE_EPSILON: f64 = 1e-6;

/// 保存されている配置 (before) と比べて、新しく置いた物・動かした物の object id を集める (DoorPolicy::OnlyMoved に渡す)。
/// before に同じ id の物が無いか、次のどれかが違えば「動かした」:
/// 種類 (家具 / 作品)・家具の assetId・作品の artworkId・部屋 (roomId)・載せている家具 (parentId) と面 (surface)・
/// 位置 (x, z) と向き (MOVE_EPSILON まで同じとみなす。向きは 2π の違いを同じにする)
pub fn moved_ids(before: &Layout, after: &Layout) -> HashSet<String> {
    after
        .objects
        .iter()
        .filter(|o| before.objects.iter().find(|b| b.id() == o.id()).is_none_or(|b| !same_place(b, o)))
        .map(|o| o.id().to_string())
        .collect()
}

fn same_place(a: &LayoutObject, b: &LayoutObject) -> bool {
    let near = |p: f64, q: f64| (p - q).abs() <= MOVE_EPSILON;
    let same_pose = |p: [f64; 3], r: f64, q: [f64; 3], s: f64| {
        near(p[0], q[0]) && near(p[2], q[2]) && wrap_angle(r - s).abs() <= MOVE_EPSILON
    };
    match (a, b) {
        (LayoutObject::Furniture(x), LayoutObject::Furniture(y)) => {
            x.asset_id == y.asset_id && x.room_id == y.room_id && same_pose(x.position, x.rotation_y, y.position, y.rotation_y)
        }
        (LayoutObject::Artwork(x), LayoutObject::Artwork(y)) => {
            x.artwork_id == y.artwork_id
                && x.parent_id == y.parent_id
                && x.room_id == y.room_id
                && x.surface == y.surface
                && same_pose(x.position, x.rotation_y, y.position, y.rotation_y)
        }
        _ => false,
    }
}

/// 作品を置く場所 (pick_spot が選ぶ)。家具の id・面・面の中心からの位置
#[derive(Debug, Clone, PartialEq)]
pub struct Spot {
    pub parent_id: String,
    /// 天板なら None
    pub surface: Option<String>,
    pub position: [f64; 3],
}

/// 家具の面に作品を置く配置を作る (向きは家具の正面と同じ)
pub fn artwork_on(artwork_id: Uuid, spot: Spot) -> LayoutObject {
    LayoutObject::Artwork(ArtworkObject {
        id: new_object_id("art"),
        artwork_id,
        parent_id: Some(spot.parent_id),
        room_id: None,
        surface: spot.surface,
        position: spot.position,
        rotation_y: 0.0,
    })
}

/// 新しい object id (例: "art-3f9a1c2e")
pub fn new_object_id(prefix: &str) -> String {
    format!("{prefix}-{}", &Uuid::new_v4().simple().to_string()[..8])
}

// =============================
// 家具の一覧 (static/home/catalog.json)
// =============================

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    pub kit_version: String,
    pub assets: Vec<Asset>,
    pub themes: Vec<Theme>,
    pub materials: BTreeMap<String, Material>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub id: String,
    pub name: String,
    pub name_ja: String,
    pub category: String,
    /// 幅・高さ・奥行き (m)
    pub dimensions_meters: [f64; 3],
    /// 天板の中心 (家のキットの値)。作品を載せる面は surfaces
    pub top_anchor: Option<[f64; 3]>,
    /// "floor_decor" (ラグ) はほかの家具と重ねて置ける
    pub layer: Option<String>,
    /// 作品を載せられる面 (天板・本棚の段など)。catalog.json に無く topAnchor があれば、読み込むときに天板を 1 つ作る
    #[serde(default)]
    pub surfaces: Vec<Surface>,
}

/// 家具の上で作品を載せられる平らな面
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Surface {
    /// "top" (天板)。本棚の段は "shelf1"・"shelf2"…
    pub id: String,
    /// 面の中心 (家具から見た位置、回す前。y は面の高さ)
    pub anchor: [f64; 3],
    /// 作品を置ける平らな範囲 (幅・奥行き、m)。中心は anchor
    pub size: [f64; 2],
    /// 上の棚板までのすき間 (m)。上が空いていれば無し
    #[serde(default)]
    pub clearance: Option<f64>,
}

impl Asset {
    pub fn is_support(&self) -> bool {
        !self.surfaces.is_empty()
    }

    /// id の面 (None なら天板)
    pub fn surface(&self, id: Option<&str>) -> Option<&Surface> {
        let id = id.unwrap_or(TOP_SURFACE);
        self.surfaces.iter().find(|s| s.id == id)
    }

    pub fn is_floor_decor(&self) -> bool {
        self.layer.as_deref() == Some("floor_decor")
    }

    pub fn file_name(&self) -> String {
        format!("{}.glb", self.id)
    }
}

#[derive(Debug, Deserialize)]
pub struct Theme {
    pub id: String,
    pub name: String,
    pub wall: String,
    pub floor: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Material {
    /// テクスチャ 1 枚が何 m 四方か
    pub tile_meters: [f64; 2],
    /// ファイル名 (/home-assets/textures/ からの相対)
    pub base_color: String,
    pub normal: String,
    pub orm: String,
}

pub static CATALOG: LazyLock<Catalog> = LazyLock::new(|| {
    let mut catalog: Catalog = serde_json::from_str(include_str!("../static/home/catalog.json"))
        .expect("static/home/catalog.json を読めません");
    for asset in &mut catalog.assets {
        if asset.surfaces.is_empty()
            && let Some(anchor) = asset.top_anchor
        {
            asset.surfaces.push(top_surface_from_dimensions(asset.dimensions_meters, anchor));
        }
    }
    catalog
});

/// surfaces の無い家具の天板: 家具の幅・奥行きから縁の 3 cm を除いた範囲
fn top_surface_from_dimensions([w, _, d]: [f64; 3], anchor: [f64; 3]) -> Surface {
    Surface {
        id: TOP_SURFACE.into(),
        anchor,
        size: [w - 2.0 * TOP_INSET, d - 2.0 * TOP_INSET],
        clearance: None,
    }
}

const DEFAULT_LAYOUT_JSON: &str = include_str!("../static/home/default-layout.json");

pub fn asset(id: &str) -> Option<&'static Asset> {
    CATALOG.assets.iter().find(|a| a.id == id)
}

/// 初期配置 (static/home/default-layout.json)
pub fn default_layout() -> Layout {
    let raw = serde_json::from_str(DEFAULT_LAYOUT_JSON).expect("default-layout.json が JSON ではありません");
    validate_layout(raw).unwrap_or_else(|e| panic!("default-layout.json が検証を通りません: {e}"))
}

/// 面に載せる作品を収める枠 (幅・高さ・奥行き)。
/// 幅・奥行きは、枠を 0.5 m 以上に保てる数で面を等分する (最大 0.56 m)。
/// 低い台 (奥行き 1.09 m) は 0.56 m では 2 並びに 3 cm 足りないので 0.545 m の 2 並び、
/// ベンチ (幅 1.11 m) は同じく 0.555 m の 2 列にする。
/// 高さは 0.62 m。棚の段では、上の棚板にぶつからないよう「すき間 − 4 cm」まで
pub fn art_fit(surface: &Surface) -> [f64; 3] {
    let [w, d] = surface.size;
    let split = |len: f64| (len / ART_FIT_MIN_SIDE + 1e-9).floor().max(1.0);
    let height = surface.clearance.map_or(ART_FIT_HEIGHT, |c| ART_FIT_HEIGHT.min(c - SHELF_HEADROOM));
    [ART_FIT_MAX.min(w / split(w)), height, ART_FIT_MAX.min(d / split(d))]
}

// =============================
// 作品の実寸と、置いたときの大きさ
// =============================

/// 作品の実寸 (登録時に GLB から測った幅・高さ・奥行き, m)
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ArtSize {
    /// 幅・高さ・奥行き
    pub size: [f64; 3],
    /// 実寸の GLB (model_kind = "custom")。枠より小さくても拡大しない
    pub custom: bool,
}

impl ArtSize {
    /// DB の列 (model_width / model_height / model_depth) から。3 つ揃って正の数のときだけ
    pub fn from_model(width: Option<f64>, height: Option<f64>, depth: Option<f64>, model_kind: &str) -> Option<Self> {
        let size = [width?, height?, depth?];
        size.iter()
            .all(|v| v.is_finite() && *v > 0.0)
            .then_some(ArtSize { size, custom: model_kind == "custom" })
    }
}

/// 作品 id ごとの実寸。寸法が分からない作品は入れない (枠をそのまま足元にする)
pub type Sizes = HashMap<Uuid, ArtSize>;

/// 作品を枠 (envelope: 幅・高さ・奥行き) に収める拡縮率。
/// 作品の向き rotation_y で回した後の縦横 (外接長方形) と高さが枠に収まる最大の倍率。
/// 実寸の GLB (custom) は 1 倍より大きくしない。
/// Web の `displayScale` (placement.ts) と同じ式 (総当たり表 placement-cases.json で照合)
pub fn display_scale(a: &ArtSize, envelope: [f64; 3], rotation_y: f64) -> f64 {
    let [w, h, d] = a.size;
    let (c, s) = (rotation_y.cos().abs(), rotation_y.sin().abs());
    let ex = w * c + d * s;
    let ez = w * s + d * c;
    let scale = (envelope[0] / ex).min(envelope[2] / ez).min(envelope[1] / h);
    if a.custom { scale.min(1.0) } else { scale }
}

/// 置いたときの作品の大きさ (幅・高さ・奥行き。回す前)
pub fn placed_size(a: &ArtSize, envelope: [f64; 3], rotation_y: f64) -> [f64; 3] {
    let scale = display_scale(a, envelope, rotation_y);
    a.size.map(|v| v * scale)
}

/// 作品が占める長方形 (載せている面か部屋から見た座標)。寸法が分からなければ枠をそのまま使う
fn art_rect(a: &ArtworkObject, envelope: [f64; 3], sizes: &Sizes) -> Rect {
    let [w, _, d] = match sizes.get(&a.artwork_id) {
        Some(size) => placed_size(size, envelope, a.rotation_y),
        None => envelope,
    };
    footprint(a.position[0], a.position[2], w, d, a.rotation_y)
}

/// 幅 w・奥行き d の作品を rotation_y だけ回したとき、(x, z) を rect からはみ出さない位置に寄せる。
/// その向きで rect より大きい軸は rect の中央にする。
/// Web の `clampToRect` (placement.ts。模様替えのドラッグで面や部屋の縁に吸着させる) と同じ式。
/// サーバーははみ出しを 400 にするだけで寄せないので、総当たり表 (テスト) でだけ使う
#[allow(dead_code)]
pub fn clamp_to_rect(rect: &Rect, w: f64, d: f64, rotation_y: f64, x: f64, z: f64) -> (f64, f64) {
    let frame = footprint(0.0, 0.0, w, d, rotation_y);
    let clamp = |v: f64, lo: f64, hi: f64| if lo > hi { (lo + hi) / 2.0 } else { v.clamp(lo, hi) };
    (
        clamp(x, rect.min_x - frame.min_x, rect.max_x - frame.max_x),
        clamp(z, rect.min_z - frame.min_z, rect.max_z - frame.max_z),
    )
}

// =============================
// 平面の計算
// =============================

/// 真上から見た長方形 (x と z の範囲)
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub min_x: f64,
    pub max_x: f64,
    pub min_z: f64,
    pub max_z: f64,
}

/// 幅 w・奥行き d の箱を rotation_y だけ回したときの外接長方形 (キットの objectBounds)
pub fn footprint(x: f64, z: f64, w: f64, d: f64, rotation_y: f64) -> Rect {
    let (c, s) = (rotation_y.cos().abs(), rotation_y.sin().abs());
    let hx = (w * c + d * s) / 2.0;
    let hz = (w * s + d * c) / 2.0;
    Rect { min_x: x - hx, max_x: x + hx, min_z: z - hz, max_z: z + hz }
}

/// 2 mm より深く重なっていれば true
pub fn rect_overlap(a: &Rect, b: &Rect) -> bool {
    a.min_x < b.max_x - TOLERANCE
        && a.max_x > b.min_x + TOLERANCE
        && a.min_z < b.max_z - TOLERANCE
        && a.max_z > b.min_z + TOLERANCE
}

/// inner が outer からはみ出していない (2 mm まで許す)
fn rect_inside(inner: &Rect, outer: &Rect) -> bool {
    inner.min_x >= outer.min_x - TOLERANCE
        && inner.max_x <= outer.max_x + TOLERANCE
        && inner.min_z >= outer.min_z - TOLERANCE
        && inner.max_z <= outer.max_z + TOLERANCE
}

/// 面の上で作品を置ける範囲 (面の中心から見た座標)
pub fn top_rect(surface: &Surface) -> Rect {
    let (hx, hz) = (surface.size[0] / 2.0, surface.size[1] / 2.0);
    Rect { min_x: -hx, max_x: hx, min_z: -hz, max_z: hz }
}

/// 角度を (-π, π] にそろえる
pub fn wrap_angle(angle: f64) -> f64 {
    if angle > -PI && angle <= PI {
        return angle;
    }
    let r = angle.rem_euclid(TAU);
    if r > PI { r - TAU } else { r }
}

/// ラジアンを度に (-180, 180]
pub fn yaw_degrees(angle: f64) -> f64 {
    wrap_angle(angle).to_degrees()
}

/// 部屋の中で、家具・床置きの作品を置ける範囲 (部屋の中心から見た座標)。壁の内側の面から 12 cm 空ける。
/// hub は ±4.88、8 × 8 の部屋は ±3.88
pub fn room_rect(def: &RoomDef) -> Rect {
    let (hx, hz) = (def.size[0] / 2.0 - WALL_MARGIN, def.size[1] / 2.0 - WALL_MARGIN);
    Rect { min_x: -hx, max_x: hx, min_z: -hz, max_z: hz }
}

/// 出入口の前の、新しく置いたり動かしたりできない場所 (部屋の中心から見た座標)。
/// 壁に沿って出入口の中心 (offset) から ±DOOR_ZONE_WIDTH / 2、壁の内側の面から部屋の中へ DOOR_ZONE_DEPTH。
/// 例: hub の東の出入口は x ∈ [2.85, 4.0]・z ∈ [−1.27, 1.27]、左の部屋の東の出入口は x ∈ [1.85, 3.0]
pub fn door_zone(def: &RoomDef, door: &Door) -> Rect {
    let (hw, hd) = (def.size[0] / 2.0, def.size[1] / 2.0);
    let (lo, hi) = (door.offset - DOOR_ZONE_WIDTH / 2.0, door.offset + DOOR_ZONE_WIDTH / 2.0);
    match door.side {
        Side::North => Rect { min_x: lo, max_x: hi, min_z: -hd, max_z: -hd + DOOR_ZONE_DEPTH },
        Side::South => Rect { min_x: lo, max_x: hi, min_z: hd - DOOR_ZONE_DEPTH, max_z: hd },
        Side::West => Rect { min_x: -hw, max_x: -hw + DOOR_ZONE_DEPTH, min_z: lo, max_z: hi },
        Side::East => Rect { min_x: hw - DOOR_ZONE_DEPTH, max_x: hw, min_z: lo, max_z: hi },
    }
}

// =============================
// 検証 (失敗は 400 の文言になる)
// =============================

/// 配置 JSON を検証して、正規化した配置を返す (作品の寸法は使わない。出入口の前も見ない。初期配置とテスト用)。
/// 作品の実寸で判定するときは `parse_layout` と `check_placement` を使う
pub fn validate_layout(raw: Value) -> Result<Layout, String> {
    let layout = parse_layout(raw)?;
    check_placement(&layout, &Sizes::new(), DoorPolicy::Ignore)?;
    Ok(layout)
}

/// 配置 JSON の schemaVersion (読めなければ None)。v3 に上げたかをログに出すため
pub fn raw_schema_version(raw: &Value) -> Option<u64> {
    raw.get("schemaVersion").and_then(Value::as_u64)
}

/// 配置 JSON の形を確かめて、正規化した配置 (いつも v4) を返す。位置 (重なり・はみ出し) は見ない。
///
/// - schemaVersion 1 (キットの JSON) と 2 (リビングだけの家) は 4 に上げる。
///   4 部屋とも enabled: true にし、左・右・前の部屋の大きさは決まった大きさにそろえる (v2 までは使っていない仮の値)。
///   壁紙・床材はそのまま。
/// - v3 (8 × 8 と 6 × 6 の 4 部屋) は 4 に上げる。部屋が広がった分だけ、壁ぎわの物を壁といっしょに動かす (widen_from_v3)。
/// - 部屋の大きさは版ごとに決まっている (v4 は hub 10 × 10、ほかは 8 × 8。v3 は 8 × 8 と 6 × 6)。違えば Err。
/// - 家具と床置きの作品の roomId は hub / left / right / front のどれか
pub fn parse_layout(raw: Value) -> Result<Layout, String> {
    let Value::Object(root) = raw else {
        return Err("配置データの形式が正しくありません".into());
    };
    let version = match root.get("schemaVersion").and_then(Value::as_u64) {
        Some(v @ 1..=4) => v,
        _ => return Err("配置データの版 (schemaVersion) は 1〜4 にしてください".into()),
    };
    let v1 = version == 1;
    let rooms = parse_rooms(root.get("rooms"), version)?;
    let list = root
        .get("objects")
        .and_then(Value::as_array)
        .ok_or("配置データに objects がありません")?;
    if list.len() > MAX_OBJECTS {
        return Err(format!("置けるのは {MAX_OBJECTS} 個までです"));
    }
    let mut objects = list
        .iter()
        .enumerate()
        .map(|(i, item)| parse_object(item, v1).map_err(|e| format!("{} 番目の物: {e}", i + 1)))
        .collect::<Result<Vec<_>, _>>()?;
    if version <= 3 {
        objects.iter_mut().for_each(widen_from_v3);
    }

    Ok(Layout {
        schema_version: SCHEMA_VERSION,
        kit_version: KIT_VERSION.into(),
        rooms,
        objects,
    })
}

/// v3 までの配置の物 1 つを、広げた部屋 (v4) に合わせて動かす。
///
/// 家具と床置きの作品のうち、足元が v3 の壁から WALL_HUG 以内にある物を、部屋が広がった分だけその壁の方へ動かす
/// (壁に付けて置いていた棚やソファが、広がった部屋の中で浮かないように)。それ以外の物と家具の上の作品はそのまま。
/// 物ごとに決まる (ほかの物を見ない) ので、v3 で重なっていなかった物どうしは、動かしたあとも重ならない
/// (壁ぎわの物は壁の方へ離れていくだけで、同じ壁ぎわの物はいっしょに同じだけ動く)。
/// 両側の壁に近い物 (部屋の幅に近い物) は、その向きには動かさない。床置きの作品の足元は床の枠 (FLOOR_ART_FIT) で見る
fn widen_from_v3(obj: &mut LayoutObject) {
    let (room_id, rect, position) = match obj {
        LayoutObject::Furniture(f) => {
            let Some(a) = asset(&f.asset_id) else { return };
            let [w, _, d] = a.dimensions_meters;
            (f.room_id.as_str(), footprint(f.position[0], f.position[2], w, d, f.rotation_y), &mut f.position)
        }
        LayoutObject::Artwork(a) if a.parent_id.is_none() => {
            let [w, _, d] = FLOOR_ART_FIT;
            let rect = footprint(a.position[0], a.position[2], w, d, a.rotation_y);
            (a.room_id.as_deref().unwrap_or(HUB_ID), rect, &mut a.position)
        }
        LayoutObject::Artwork(_) => return,
    };
    let Some(def) = room_def(room_id) else { return };
    let old = v3_room_size(def.id);
    // 1 つの向き (x か z) で、v3 の壁の内側の面からの距離を見て、近い側の壁へ広がった分だけ動かす
    let shift = |min: f64, max: f64, old_size: f64, new_size: f64| -> f64 {
        let (half, grow) = (old_size / 2.0, (new_size - old_size) / 2.0);
        let (near_min, near_max) = (min + half <= WALL_HUG, half - max <= WALL_HUG);
        match (near_min, near_max) {
            (true, false) => -grow,
            (false, true) => grow,
            _ => 0.0,
        }
    };
    position[0] += shift(rect.min_x, rect.max_x, old[0], def.size[0]);
    position[2] += shift(rect.min_z, rect.max_z, old[1], def.size[1]);
}

/// 配置 JSON に出てくる作品の id (形の正しくない配置からも集める。寸法を DB から読むため)
pub fn raw_artwork_ids(raw: &Value) -> Vec<Uuid> {
    let mut ids: Vec<Uuid> = raw
        .get("objects")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|o| o.get("kind").and_then(Value::as_str) == Some("artwork"))
        .filter_map(|o| o.get("artworkId").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok()))
        .collect();
    ids.sort();
    ids.dedup();
    ids
}

/// 検証に通らない配置を、作品だけ外して直す。直した配置と、外した作品の object id を返す。
///
/// 家具と部屋だけで検証し直し、通れば作品を元の順に 1 つずつ戻して、置けない作品だけを外す。
/// 別の版のサーバーが保存した配置 (知らない家具の面に載った作品など) を読んだときに、
/// 配置全体を初期配置に戻さないため。家具や部屋がおかしいときは Err (直せない)。
/// sizes は作品の実寸 (check_placement と同じ)
pub fn repair_layout(raw: Value, sizes: &Sizes) -> Result<(Layout, Vec<String>), String> {
    let Value::Object(mut root) = raw else {
        return Err("配置データの形式が正しくありません".into());
    };
    let version = root.get("schemaVersion").and_then(Value::as_u64);
    let v1 = version == Some(1);
    let list = root
        .get("objects")
        .and_then(Value::as_array)
        .cloned()
        .ok_or("配置データに objects がありません")?;
    let is_artwork = |item: &Value| !v1 && item.get("kind").and_then(Value::as_str) == Some("artwork");

    // 家具だけで検証する (順番は元のまま)
    let furniture: Vec<Value> = list.iter().filter(|item| !is_artwork(item)).cloned().collect();
    root.insert("objects".into(), Value::Array(furniture));
    let mut layout = validate_layout(Value::Object(root))?;

    // 作品を元の位置 (objects の何番目か) に戻しながら 1 つずつ足す
    let mut placed: Vec<(usize, LayoutObject)> = list
        .iter()
        .enumerate()
        .filter(|(_, item)| !is_artwork(item))
        .map(|(i, _)| i)
        .zip(layout.objects.drain(..))
        .collect();
    let mut dropped = Vec::new();
    for (i, item) in list.iter().enumerate().filter(|(_, item)| is_artwork(item)) {
        let id = item.get("id").and_then(Value::as_str).unwrap_or("?").to_string();
        let Ok(mut obj) = parse_object(item, v1) else {
            dropped.push(id);
            continue;
        };
        // 家具は validate_layout (parse_layout) で動いているので、作品も同じように動かす
        if version.is_some_and(|v| v <= 3) {
            widen_from_v3(&mut obj);
        }
        placed.push((i, obj));
        layout.objects = placed.iter().map(|(_, o)| o.clone()).collect();
        if layout.objects.len() > MAX_OBJECTS || check_placement(&layout, sizes, DoorPolicy::Ignore).is_err() {
            placed.pop();
            dropped.push(id);
        }
    }
    placed.sort_by_key(|(i, _)| *i);
    layout.objects = placed.into_iter().map(|(_, o)| o).collect();
    Ok((layout, dropped))
}

/// rooms を読む。4 部屋とも必要で、enabled は true にそろえる (false が来ても使う部屋にする)。
/// 大きさは版ごとに決まっていて (v4 は ROOM_DEFS、v3 までは V3_ROOM_SIZES)、読んだ配置はいつも ROOM_DEFS の大きさにする。
/// v1・v2 の左・右・前の部屋 (使っていなかった仮の部屋) だけは、4〜12 の整数ならどれでも読む
fn parse_rooms(value: Option<&Value>, version: u64) -> Result<Rooms, String> {
    let rooms = value.and_then(Value::as_object).ok_or("配置データに rooms がありません")?;
    let room = |def: &RoomDef| -> Result<Room, String> {
        let id = def.id;
        let r = rooms
            .get(id)
            .and_then(Value::as_object)
            .ok_or_else(|| format!("部屋 {id} がありません"))?;
        r.get("enabled")
            .and_then(Value::as_bool)
            .ok_or_else(|| format!("部屋 {id} の enabled がありません"))?;
        let fixed = [def.size[0] as i64, def.size[1] as i64];
        let expected = if version <= 3 { v3_room_size(id).map(|v| v as i64) } else { fixed };
        let size = |key: &str| {
            r.get(key)
                .and_then(Value::as_i64)
                .filter(|n| (4..=12).contains(n))
                .ok_or_else(|| format!("部屋 {id} の大きさは 4〜12 の整数にしてください"))
        };
        let size = [size("width")?, size("depth")?];
        let placeholder = version < 3 && id != HUB_ID;
        if size != expected && !placeholder {
            return Err(format!("部屋の大きさは変えられません ({} は {} × {} m)", def.name, expected[0], expected[1]));
        }
        let wall = r.get("wall").and_then(Value::as_str).filter(|w| WALLS.contains(w));
        let floor = r.get("floor").and_then(Value::as_str).filter(|f| FLOORS.contains(f));
        let (Some(wall), Some(floor)) = (wall, floor) else {
            return Err(format!("部屋 {id} の壁紙か床材の名前が正しくありません"));
        };
        Ok(Room { enabled: true, width: fixed[0], depth: fixed[1], wall: wall.into(), floor: floor.into() })
    };

    let [hub, left, right, front] = &ROOM_DEFS;
    Ok(Rooms { hub: room(hub)?, left: room(left)?, right: room(right)?, front: room(front)? })
}

/// roomId (家具は必須、床置きの作品は省くと hub) を確かめる
fn parse_room_id(o: &Map<String, Value>, default: Option<&'static str>) -> Result<&'static str, String> {
    match (str_field(o, "roomId"), default) {
        (None, Some(id)) => Ok(id),
        (None, None) => Err("roomId がありません".into()),
        (Some(id), _) => room_def(id).map(|d| d.id).ok_or_else(|| {
            let ids: Vec<&str> = ROOM_DEFS.iter().map(|d| d.id).collect();
            format!("部屋「{id}」はありません (roomId は {} のどれか)", ids.join("・"))
        }),
    }
}

fn valid_id(id: &str) -> bool {
    (1..=MAX_ID_LEN).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn parse_object(value: &Value, v1: bool) -> Result<LayoutObject, String> {
    let o = value.as_object().ok_or("形式が正しくありません")?;
    let id = o.get("id").and_then(Value::as_str).ok_or("id がありません")?;
    if !valid_id(id) {
        return Err(format!("id「{id}」は 1〜{MAX_ID_LEN} 文字の英数字・-・_ にしてください"));
    }
    let position = parse_position(o.get("position"))?;
    let rotation_y = o
        .get("rotationY")
        .and_then(Value::as_f64)
        .filter(|r| r.is_finite())
        .map(wrap_angle)
        .ok_or("rotationY が正しくありません")?;

    // v1 (キットの JSON) はすべて家具。キットの見本の作品 (artworkId) は捨てる
    let kind = if v1 { "furniture" } else { o.get("kind").and_then(Value::as_str).unwrap_or("furniture") };
    match kind {
        "furniture" => {
            let asset_id = o.get("assetId").and_then(Value::as_str).unwrap_or_default();
            if asset(asset_id).is_none_or(|a| a.category != "furniture") {
                return Err(format!("家具「{asset_id}」はありません"));
            }
            let room_id = parse_room_id(o, None)?;
            Ok(LayoutObject::Furniture(Furniture {
                id: id.into(),
                asset_id: asset_id.into(),
                room_id: room_id.into(),
                position,
                rotation_y,
            }))
        }
        "artwork" => {
            let artwork_id = str_field(o, "artworkId")
                .and_then(|s| Uuid::parse_str(s).ok())
                .ok_or("作品の artworkId が正しくありません")?;
            let parent_id = match o.get("parentId") {
                None | Some(Value::Null) => None,
                Some(Value::String(p)) if valid_id(p) => Some(p.clone()),
                Some(_) => return Err("作品の parentId が正しくありません".into()),
            };
            let room_id = match &parent_id {
                // 家具の上の作品は親の部屋に入る (書いてあっても使わない)
                Some(_) => None,
                None => Some(parse_room_id(o, Some(HUB_ID))?.to_string()),
            };
            // 天板 ("top") は省いた形にそろえる。床に置く作品には面が無い
            let surface = match (o.get("surface"), &parent_id) {
                (None | Some(Value::Null), _) => None,
                (Some(Value::String(s)), Some(_)) if s == TOP_SURFACE => None,
                (Some(Value::String(s)), Some(_)) if valid_id(s) => Some(s.clone()),
                _ => return Err("作品の surface が正しくありません".into()),
            };
            Ok(LayoutObject::Artwork(ArtworkObject {
                id: id.into(),
                artwork_id,
                parent_id,
                room_id,
                surface,
                position,
                rotation_y,
            }))
        }
        other => Err(format!("kind「{other}」には対応していません")),
    }
}

fn str_field<'a>(o: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    o.get(key).and_then(Value::as_str)
}

fn parse_position(value: Option<&Value>) -> Result<[f64; 3], String> {
    let numbers: Option<Vec<f64>> = value
        .and_then(Value::as_array)
        .filter(|a| a.len() == 3)
        .map(|a| a.iter().filter_map(Value::as_f64).filter(|n| n.is_finite()).collect());
    match numbers.as_deref() {
        Some(&[x, _, z]) if x.abs() <= MAX_COORD && z.abs() <= MAX_COORD => Ok([x, 0.0, z]),
        _ => Err(format!("position は ±{MAX_COORD} m 以内の数 3 つにしてください")),
    }
}

/// エラーの文言に出す名前 (例: "サイドボード (home-005)")
fn label(obj: &LayoutObject) -> String {
    match obj {
        LayoutObject::Furniture(f) => {
            let name = asset(&f.asset_id).map_or(f.asset_id.as_str(), |a| a.name_ja.as_str());
            format!("{name} ({})", f.id)
        }
        LayoutObject::Artwork(a) => format!("作品 ({})", a.id),
    }
}

/// check_placement で、出入口の前 (door_zone) を見る物
#[derive(Debug, Clone, Copy)]
pub enum DoorPolicy<'a> {
    /// 見ない。起動時・直すとき・読むとき・初期配置 (保存済みの配置が出入口の前にかかっていても読めるように)
    Ignore,
    /// この object id の物だけ見る。保存するときに、新しく置いた物・動かした物 (moved_ids) を渡す
    OnlyMoved(&'a HashSet<String>),
}

impl DoorPolicy<'_> {
    fn applies(&self, id: &str) -> bool {
        match self {
            DoorPolicy::Ignore => false,
            DoorPolicy::OnlyMoved(ids) => ids.contains(id),
        }
    }
}

/// 位置の検証。床の物 (家具と床置きの作品) は、所属する部屋のローカル座標で次を見る:
/// 1. 部屋の壁から 12 cm 空ける (room_rect。2 mm まで許す)
/// 2. doors が見る物は、その部屋の出入口の前 (door_zone) にかからない (2 mm まで許す)。ラグもここは見る
/// 3. 同じ部屋の床の物どうしが重ならない (ラグはほかと重なってよい。別の部屋の物とは比べない)
///
/// 家具の上の作品は、載せている面からはみ出さず、同じ面の作品と重ならない (部屋や出入口は見ない)。
/// 作品の足元は実寸 (sizes) を枠に収めた大きさ。寸法の分からない作品は枠 (art_fit・FLOOR_ART_FIT) をそのまま使う
pub fn check_placement(layout: &Layout, sizes: &Sizes, doors: DoorPolicy) -> Result<(), String> {
    let mut ids = HashSet::new();
    let mut artwork_ids = HashSet::new();
    for obj in &layout.objects {
        if !ids.insert(obj.id()) {
            return Err(format!("id「{}」が重複しています", obj.id()));
        }
        if let LayoutObject::Artwork(a) = obj
            && !artwork_ids.insert(a.artwork_id)
        {
            return Err("同じ作品が 2 か所に置かれています".into());
        }
    }

    // 床に置く物 (家具と床置きの作品): 物・部屋・部屋の中の足元・ラグか。ラグ (floor_decor) はほかと重なってよい
    let mut on_floor: Vec<(&LayoutObject, &RoomDef, Rect, bool)> = Vec::new();
    for obj in &layout.objects {
        let (rect, decor) = match obj {
            LayoutObject::Furniture(f) => {
                let a = asset(&f.asset_id).ok_or_else(|| format!("家具「{}」はありません", f.asset_id))?;
                let [w, _, d] = a.dimensions_meters;
                (footprint(f.position[0], f.position[2], w, d, f.rotation_y), a.is_floor_decor())
            }
            LayoutObject::Artwork(a) if a.parent_id.is_none() => (art_rect(a, FLOOR_ART_FIT, sizes), false),
            LayoutObject::Artwork(_) => continue,
        };
        let room = layout.room_of(obj).ok_or_else(|| format!("{} の部屋がありません", label(obj)))?;
        on_floor.push((obj, room, rect, decor));
    }
    for (i, (obj, room, rect, decor)) in on_floor.iter().enumerate() {
        // 模様替えは壁ぎりぎり (12 cm) に寄せた位置を送ってくるので、重なりと同じ 2 mm だけ許す
        // (寸法や三角関数の丸めの違いで、ぴったりの位置がはみ出し扱いにならないように)
        if !rect_inside(rect, &room_rect(room)) {
            return Err(format!("{} が {} の壁に近すぎます (壁から 12 cm 空けてください)", label(obj), room.name));
        }
        if doors.applies(obj.id()) && room.doors.iter().any(|door| rect_overlap(&door_zone(room, door), rect)) {
            return Err(format!("{} は {} の出入口の前には置けません", label(obj), room.name));
        }
        if *decor {
            continue;
        }
        for (other, other_room, other_rect, other_decor) in &on_floor[i + 1..] {
            if other_room.id == room.id && !*other_decor && rect_overlap(rect, other_rect) {
                return Err(format!("{} と {} が重なっています", label(obj), label(other)));
            }
        }
    }

    // 家具の上の作品: 親は面のある家具 (入れ子は不可)、面からはみ出さない、同じ面の隣の作品と重ならない
    let mut on_top: HashMap<(&str, &str), Vec<(&LayoutObject, Rect)>> = HashMap::new();
    for obj in &layout.objects {
        let LayoutObject::Artwork(a) = obj else { continue };
        let Some(parent_id) = &a.parent_id else { continue };
        let Some(parent) = layout.furniture(parent_id) else {
            return Err(format!("{} の置き場所「{parent_id}」がありません (作品は家具の上にだけ置けます)", label(obj)));
        };
        let support = asset(&parent.asset_id).filter(|s| s.is_support());
        let Some(support) = support else {
            return Err(format!("{} の上には作品を置けません", label(&LayoutObject::Furniture(parent.clone()))));
        };
        let Some(surface) = support.surface(a.surface.as_deref()) else {
            return Err(format!("{} には「{}」という置き場所がありません", support.name_ja, a.surface_id()));
        };
        let rect = art_rect(a, art_fit(surface), sizes);
        if !rect_inside(&rect, &top_rect(surface)) {
            return Err(format!("{} が {} の置き場所からはみ出しています", label(obj), support.name_ja));
        }
        let siblings = on_top.entry((parent_id.as_str(), a.surface_id())).or_default();
        if let Some((other, _)) = siblings.iter().find(|(_, r)| rect_overlap(r, &rect)) {
            return Err(format!("{} と {} が重なっています", label(obj), label(other)));
        }
        siblings.push((obj, rect));
    }
    Ok(())
}

// =============================
// 世界座標・自動配置・置き場所の数
// =============================

/// 部屋のローカル座標 (x, z) を世界座標に: 部屋の origin を足すだけ (部屋は回さない)
fn room_to_world(room_id: &str, position: [f64; 3]) -> Option<[f64; 3]> {
    let [ox, oz] = room_def(room_id)?.origin;
    Some([ox + position[0], 0.0, oz + position[2]])
}

/// 置いた物の世界座標と向き (ラジアン)。作品なら置く面の中心 (家具の上なら面の高さ、床なら 0)。
///
/// - 家具・床置きの作品: 世界 = (部屋の origin.x + x, 0, origin.z + z)、向き = rotationY
/// - 親 P (世界 (Px, 0, Pz) は上の式、向き θ、面の中心 (ax, h, az)) の上の作品 (x, 0, z) は、x̂ = ax + x、ẑ = az + z として
///   x' = x̂·cosθ + ẑ·sinθ、z' = −x̂·sinθ + ẑ·cosθ、世界 = (Px + x', h, Pz + z')、向き = θ + rotationY
pub fn world_of(layout: &Layout, obj: &LayoutObject) -> Option<([f64; 3], f64)> {
    match obj {
        LayoutObject::Furniture(f) => Some((room_to_world(&f.room_id, f.position)?, f.rotation_y)),
        LayoutObject::Artwork(a) => {
            let Some(parent_id) = &a.parent_id else {
                let world = room_to_world(a.room_id.as_deref().unwrap_or(HUB_ID), a.position)?;
                return Some((world, a.rotation_y));
            };
            let parent = layout.furniture(parent_id)?;
            let [px, _, pz] = room_to_world(&parent.room_id, parent.position)?;
            let [ax, h, az] = asset(&parent.asset_id)?.surface(a.surface.as_deref())?.anchor;
            let (x, z) = (ax + a.position[0], az + a.position[2]);
            let (sin, cos) = parent.rotation_y.sin_cos();
            let world = [px + x * cos + z * sin, h, pz - x * sin + z * cos];
            Some((world, parent.rotation_y + a.rotation_y))
        }
    }
}

/// 面を作品の枠で縦横に区切った数 (幅方向の列, 奥行き方向の行)
fn cell_grid(surface: &Surface) -> (usize, usize) {
    let [fit_w, _, fit_d] = art_fit(surface);
    if fit_w <= 0.0 || fit_d <= 0.0 {
        return (0, 0);
    }
    let [w, d] = surface.size;
    // 0.59 m の台座 (枠 0.53 m) がちょうど 1 になるよう誤差を足す
    let count = |len: f64, fit: f64| (len / fit + 1e-9).floor() as usize;
    (count(w, fit_w), count(d, fit_d))
}

/// 面の置き場所の数 (列 × 行)
fn cell_count(surface: &Surface) -> usize {
    let (cols, rows) = cell_grid(surface);
    cols * rows
}

/// 区切った置き場所の中心 (親から見た (x, z)。両方向とも中央そろえ)。
/// 手前 (+z) の行から順に、行の中は −x から並べる。
/// 手前の行から埋めるのは、作品が少ないうちは見る人に近い縁に並んで、奥の空いた所の陰にならないようにするため
fn cell_centers(surface: &Surface) -> impl Iterator<Item = (f64, f64)> {
    let (cols, rows) = cell_grid(surface);
    let [w, _, d] = art_fit(surface);
    let offset = |i: usize, n: usize| i as f64 - (n as f64 - 1.0) / 2.0;
    (0..rows).flat_map(move |j| {
        // -offset にすると 1 行のとき -0.0 になるので、引く順を逆にする
        let z = ((rows as f64 - 1.0) / 2.0 - j as f64) * d;
        (0..cols).map(move |i| (offset(i, cols) * w, z))
    })
}

/// 面の置き場所のうち、置く作品の足元 ([幅, 奥行き]。置き場所の中心に置く) が
/// 載っている作品 (children) と重ならない最初の場所 (面の中心から見た (x, z))
fn free_cell(surface: &Surface, children: &[Rect], [w, d]: [f64; 2]) -> Option<(f64, f64)> {
    cell_centers(surface).find(|&(x, z)| {
        let cell = footprint(x, z, w, d, 0.0);
        !children.iter().any(|c| rect_overlap(c, &cell))
    })
}

/// 作品を自動で置く場所を探す。いっぱいなら None。
///
/// - prefer_room に部屋の id を渡すと、その部屋の家具だけを探す (空きが無ければ None。ほかの部屋には置かない)。
///   省くと全部屋から、部屋は ROOM_DEFS の順 (hub が先) に探す。
/// - 部屋の中では家具を SUPPORT_ORDER の順、1 つの家具の中は面の順 (catalog.json の順) に探す。
/// - prefer_parent に家具の id を渡すと、その家具を先に探す (いっぱいならほかの家具を探す)。
///
/// 置き場所の区切り方 (cell_grid) は枠のまま。載っている作品は実寸 (sizes)、
/// 置く作品 (new) は実寸を枠に収めた大きさで重なりを見る (寸法が分からなければ枠)
pub fn pick_spot(
    layout: &Layout,
    sizes: &Sizes,
    new: Option<&ArtSize>,
    prefer_room: Option<&str>,
    prefer_parent: Option<&str>,
) -> Option<Spot> {
    let mut supports: Vec<(&Furniture, &Asset)> = layout
        .objects
        .iter()
        .filter_map(|o| match o {
            LayoutObject::Furniture(f) => asset(&f.asset_id).filter(|a| a.is_support()).map(|a| (f, a)),
            _ => None,
        })
        .filter(|(f, _)| prefer_room.is_none_or(|room| f.room_id == room))
        .collect();
    // 同じ順位の中では配置 JSON の順 (安定ソート)
    supports.sort_by_key(|(f, a)| {
        let rank = SUPPORT_ORDER.iter().position(|id| *id == a.id).unwrap_or(SUPPORT_ORDER.len());
        (prefer_parent != Some(f.id.as_str()), room_rank(&f.room_id), rank)
    });

    for (furniture, support) in supports {
        for surface in &support.surfaces {
            let fit = art_fit(surface);
            let children: Vec<Rect> = layout
                .artworks()
                .filter(|a| a.parent_id.as_deref() == Some(furniture.id.as_str()) && a.surface_id() == surface.id)
                .map(|a| art_rect(a, fit, sizes))
                .collect();
            let [w, _, d] = new.map_or(fit, |n| placed_size(n, fit, 0.0));
            if let Some((x, z)) = free_cell(surface, &children, [w, d]) {
                return Some(Spot {
                    parent_id: furniture.id.clone(),
                    surface: (surface.id != TOP_SURFACE).then(|| surface.id.clone()),
                    position: [x, 0.0, z],
                });
            }
        }
    }
    None
}

/// 部屋ごとの、作品を飾れる場所の数 (その部屋の家具の面の置き場所の合計)。4 部屋とも入る (家具が無ければ 0)
pub fn capacity_by_room(layout: &Layout) -> HashMap<&'static str, usize> {
    let mut by_room: HashMap<&'static str, usize> = ROOM_DEFS.iter().map(|d| (d.id, 0)).collect();
    for obj in &layout.objects {
        let LayoutObject::Furniture(f) = obj else { continue };
        if let (Some(room), Some(a)) = (room_def(&f.room_id), asset(&f.asset_id)) {
            *by_room.entry(room.id).or_default() += a.surfaces.iter().map(cell_count).sum::<usize>();
        }
    }
    by_room
}

/// 作品を飾れる場所の数 (全部屋の合計)
pub fn capacity(layout: &Layout) -> usize {
    capacity_by_room(layout).values().sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::f64::consts::{FRAC_1_SQRT_2, FRAC_PI_2, FRAC_PI_4};

    const ART_A: &str = "00000000-0000-4000-8000-00000000000a";
    const ART_B: &str = "00000000-0000-4000-8000-00000000000b";
    const ART_C: &str = "00000000-0000-4000-8000-00000000000c";

    /// 4 部屋 (hub が hub_size、ほかは size。仕上げは初期配置と同じ)
    fn rooms_sized(hub_size: i64, size: i64) -> Value {
        let room = |size: i64, wall: &str, floor: &str| {
            json!({ "enabled": true, "width": size, "depth": size, "wall": wall, "floor": floor })
        };
        json!({
            "hub": room(hub_size, "plaster", "oak"),
            "left": room(size, "oak", "oak"),
            "right": room(size, "plaster", "oak"),
            "front": room(size, "brick", "limestone"),
        })
    }

    /// v4 の 4 部屋 (hub 10 × 10、ほかは 8 × 8)
    fn rooms() -> Value {
        rooms_sized(10, 8)
    }

    /// v3 の 4 部屋 (hub 8 × 8、ほかは 6 × 6)
    fn rooms_v3() -> Value {
        rooms_sized(8, 6)
    }

    /// v2 (リビングだけの家) の rooms。左・右・前は使っていない仮の部屋
    fn rooms_v2() -> Value {
        let mut rooms = rooms_v3();
        for id in ["left", "right", "front"] {
            rooms[id]["enabled"] = json!(false);
        }
        rooms
    }

    fn layout_of(objects: Value) -> Result<Layout, String> {
        validate_layout(raw_layout(objects))
    }

    fn furniture(id: &str, asset_id: &str, x: f64, z: f64, rotation_y: f64) -> Value {
        furniture_in("hub", id, asset_id, x, z, rotation_y)
    }

    fn furniture_in(room: &str, id: &str, asset_id: &str, x: f64, z: f64, rotation_y: f64) -> Value {
        json!({ "kind": "furniture", "id": id, "assetId": asset_id, "roomId": room, "position": [x, 0, z], "rotationY": rotation_y })
    }

    fn on_floor(room: &str, id: &str, artwork: &str, x: f64, z: f64) -> Value {
        json!({ "kind": "artwork", "id": id, "artworkId": artwork, "roomId": room, "position": [x, 0, z], "rotationY": 0 })
    }

    fn on_top(id: &str, artwork: &str, parent: &str, x: f64, z: f64, rotation_y: f64) -> Value {
        json!({ "kind": "artwork", "id": id, "artworkId": artwork, "parentId": parent, "position": [x, 0, z], "rotationY": rotation_y })
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    /// 長方形 r が [min_x, max_x, min_z, max_z] と (1e-9 まで) 同じ
    fn assert_rect(r: Rect, want: [f64; 4]) {
        let got = [r.min_x, r.max_x, r.min_z, r.max_z];
        assert!(got.iter().zip(want).all(|(g, w)| close(*g, w)), "{got:?} != {want:?}");
    }

    #[test]
    fn default_layout_validates() {
        let layout = default_layout();
        assert_eq!(layout.schema_version, SCHEMA_VERSION);
        assert!(layout.objects.iter().all(|o| matches!(o, LayoutObject::Furniture(_))));
        let capacity = capacity(&layout);
        assert!(capacity >= 13, "capacity = {capacity}");
        // 低い台が 2 並びになって 3 + 3 (cells_use_depth_on_deep_tops)
        assert_eq!(capacity, 17);
        // 家具はすべて中央のリビング。ほかの部屋は空室
        let by_room = capacity_by_room(&layout);
        assert_eq!(by_room.len(), 4);
        assert_eq!((by_room["hub"], by_room["left"], by_room["right"], by_room["front"]), (17, 0, 0, 0));
        // 4 部屋とも使う部屋で、仕上げは部屋ごと
        let rooms = &layout.rooms;
        assert!([&rooms.hub, &rooms.left, &rooms.right, &rooms.front].iter().all(|r| r.enabled));
        assert_eq!((rooms.hub.width, rooms.left.width, rooms.right.depth, rooms.front.depth), (10, 8, 8, 8));
        assert_eq!((rooms.front.wall.as_str(), rooms.front.floor.as_str()), ("brick", "limestone"));
        assert_eq!((rooms.left.wall.as_str(), rooms.right.wall.as_str()), ("oak", "plaster"));
    }

    /// v3 (8 × 8 と 6 × 6 の 4 部屋) のころの初期配置
    fn v3_default_layout() -> Value {
        serde_json::from_str(include_str!("testdata/default-layout-v3.json")).unwrap()
    }

    #[test]
    fn v3_layout_widens_rooms_and_moves_wall_side_objects() {
        let raw = v3_default_layout();
        assert_eq!(raw_schema_version(&raw), Some(3));
        let layout = validate_layout(raw).unwrap();
        assert_eq!(layout.schema_version, SCHEMA_VERSION);
        assert_eq!((layout.rooms.hub.width, layout.rooms.hub.depth, layout.rooms.left.width), (10, 10, 8));
        let position = |id: &str| match layout.objects.iter().find(|o| o.id() == id) {
            Some(LayoutObject::Furniture(f)) => f.position,
            _ => panic!("{id}"),
        };
        // 壁から 0.6 m 以内の物は、広がった分 (1 m) だけその壁の方へ動く。角の植木は 2 方向に
        assert_eq!(position("home-007"), [-4.08, 0.0, -3.99]);
        assert_eq!(position("home-008"), [0.0, 0.0, 4.4]);
        assert_eq!(position("home-009"), [-2.5, 0.0, 4.25]);
        assert_eq!(position("home-011"), [-4.4, 0.0, -0.9]);
        // 部屋の真ん中の物と、壁から離して置いた物はそのまま
        assert_eq!(position("home-001"), [0.05, 0.0, -0.6]);
        assert_eq!(position("home-002"), [0.0, 0.0, -2.45]);
        assert_eq!(position("home-004"), [-2.82, 0.0, 1.45]);
        // v3 の大きさのままの部屋は読めない。v4 の大きさの v3 も読めない
        let mut raw = v3_default_layout();
        raw["schemaVersion"] = json!(4);
        assert!(validate_layout(raw).unwrap_err().contains("部屋の大きさは変えられません"));
        let mut raw = v3_default_layout();
        raw["rooms"] = rooms();
        assert!(validate_layout(raw).unwrap_err().contains("部屋の大きさは変えられません"));
    }

    #[test]
    fn v3_floor_artworks_move_with_the_walls() {
        // 床置きの作品も足元 (枠 0.8 × 0.8) で見る。家具の上の作品は親といっしょに動く (位置は面から見たまま)
        let raw = json!({
            "schemaVersion": 3,
            "kitVersion": KIT_VERSION,
            "rooms": rooms_v3(),
            "objects": [
                furniture_in("left", "desk", "home_craft_desk", 0.0, 2.4, PI),
                on_top("art-1", ART_A, "desk", 0.1, 0.0, 0.0),
                on_floor("left", "art-2", ART_B, 2.3, -2.3),
                on_floor("front", "art-3", ART_C, 0.0, 0.0),
            ],
        });
        let layout = validate_layout(raw.clone()).unwrap();
        let LayoutObject::Furniture(desk) = &layout.objects[0] else { panic!() };
        assert_eq!(desk.position, [0.0, 0.0, 3.4]);
        let LayoutObject::Artwork(on_desk) = &layout.objects[1] else { panic!() };
        assert_eq!(on_desk.position, [0.1, 0.0, 0.0]);
        let LayoutObject::Artwork(corner) = &layout.objects[2] else { panic!() };
        assert_eq!(corner.position, [3.3, 0.0, -3.3]);
        let LayoutObject::Artwork(middle) = &layout.objects[3] else { panic!() };
        assert_eq!(middle.position, [0.0, 0.0, 0.0]);
        // 直すとき (repair_layout) も、作品を同じように動かす
        let (repaired, dropped) = repair_layout(raw, &Sizes::new()).unwrap();
        assert!(dropped.is_empty());
        assert_eq!(repaired, layout);
    }

    /// 出入口の前にかかっている家具 (保存するときに見るのは、新しく置いた物・動かした物だけ)
    fn door_blockers(layout: &Layout) -> Vec<String> {
        layout
            .objects
            .iter()
            .filter(|o| {
                let all = HashSet::from([o.id().to_string()]);
                let alone = Layout { objects: vec![(*o).clone()], ..layout.clone() };
                matches!(o, LayoutObject::Furniture(_))
                    && check_placement(&alone, &Sizes::new(), DoorPolicy::OnlyMoved(&all)).is_err()
            })
            .map(|o| o.id().to_string())
            .collect()
    }

    #[test]
    fn default_layout_keeps_doorways_clear() {
        // 初期配置 (v4) の家具は、どれも出入口の前にかからない
        let layout = default_layout();
        assert!(door_blockers(&layout).is_empty(), "{:?}", door_blockers(&layout));
        // v3 の初期配置は、ソファ (北)・飾り棚 (西)・サイドボード (東)・白い台座 (西) が出入口の前にかかっていた。
        // v4 に上げると出入口の前も壁といっしょに動くので、かかるのは壁ぎわの白い台座 (西) だけになる。
        // 動かさなければそのまま読めて、保存もできる
        let layout = validate_layout(v3_default_layout()).unwrap();
        assert_eq!(door_blockers(&layout), vec!["home-011"]);
        let unchanged = moved_ids(&layout, &layout);
        assert!(unchanged.is_empty());
        check_placement(&layout, &Sizes::new(), DoorPolicy::OnlyMoved(&unchanged)).unwrap();
    }

    #[test]
    fn v2_layout_upgrades_keeping_hub_objects() {
        let raw = json!({
            "schemaVersion": 2,
            "kitVersion": KIT_VERSION,
            "rooms": rooms_v2(),
            "objects": [
                furniture("console", "home_console", 0.0, 2.0, 0.0),
                on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0),
                { "kind": "artwork", "id": "art-2", "artworkId": ART_B, "position": [-2.0, 0, -2.0], "rotationY": 0 },
            ],
        });
        assert_eq!(raw_schema_version(&raw), Some(2));
        let layout = validate_layout(raw).unwrap();
        assert_eq!(layout.schema_version, SCHEMA_VERSION);
        // 4 部屋とも使う部屋になり、壁紙・床材はそのまま
        let rooms = &layout.rooms;
        assert!([&rooms.hub, &rooms.left, &rooms.right, &rooms.front].iter().all(|r| r.enabled));
        assert_eq!(rooms.front.wall, "brick");
        // 物はそのまま (すべて hub。壁から離れているので動かない)。roomId を省いた床の作品は hub
        let ids: Vec<&str> = layout.objects.iter().map(LayoutObject::id).collect();
        assert_eq!(ids, vec!["console", "art-1", "art-2"]);
        assert!(layout.objects.iter().all(|o| layout.room_of(o).unwrap().id == "hub"));
        let value = serde_json::to_value(&layout).unwrap();
        assert_eq!(value["schemaVersion"], SCHEMA_VERSION);
        assert_eq!(value["rooms"]["left"]["enabled"], true);
        assert_eq!(value["objects"][2]["roomId"], "hub");
        // 保存し直した v4 も同じ配置として読める
        assert_eq!(validate_layout(value).unwrap(), layout);

        // v2 までの左・右・前の大きさは仮の値なので、今の大きさ (8 × 8) にそろえる。hub は 8 × 8 (v2 の大きさ) から 10 × 10 に
        let mut odd = rooms_v2();
        odd["left"]["width"] = json!(7);
        let layout = validate_layout(json!({ "schemaVersion": 2, "rooms": odd, "objects": [] })).unwrap();
        assert_eq!((layout.rooms.left.width, layout.rooms.left.depth), (8, 8));
        assert_eq!((layout.rooms.hub.width, layout.rooms.hub.depth), (10, 10));
    }

    #[test]
    fn rejects_resized_rooms_and_unknown_room_ids() {
        // 部屋の大きさは版ごとに決まっている (v4 は 10 × 10 と 8 × 8、v3 は 8 × 8 と 6 × 6)
        for (version, base) in [(4, rooms()), (3, rooms_v3())] {
            for (id, key) in [("hub", "width"), ("left", "depth"), ("front", "width")] {
                let mut room = base.clone();
                room[id][key] = json!(9);
                let err = validate_layout(json!({ "schemaVersion": version, "rooms": room, "objects": [] })).unwrap_err();
                assert!(err.contains("部屋の大きさは変えられません"), "v{version} {id}: {err}");
            }
        }
        // 版が 5 以上なら読まない
        assert!(validate_layout(json!({ "schemaVersion": 5, "rooms": rooms(), "objects": [] })).is_err());
        // 家具・床置きの作品の roomId は 4 部屋のどれか
        let err = layout_of(json!([furniture_in("attic", "f", "home_stool", 0.0, 0.0, 0.0)])).unwrap_err();
        assert!(err.contains("attic"), "{err}");
        let err = layout_of(json!([on_floor("back", "art-1", ART_A, 0.0, 0.0)])).unwrap_err();
        assert!(err.contains("back"), "{err}");
        let mut no_room = furniture("f", "home_stool", 0.0, 0.0, 0.0);
        no_room.as_object_mut().unwrap().remove("roomId");
        assert!(layout_of(json!([no_room])).is_err());
        // 家具の上の作品の roomId は使わない (親の家具の部屋)
        let layout = layout_of(json!([
            furniture_in("left", "stool", "home_stool", 0.0, 0.0, 0.0),
            { "kind": "artwork", "id": "art-1", "artworkId": ART_A, "parentId": "stool", "roomId": "front", "position": [0, 0, 0], "rotationY": 0 },
        ]))
        .unwrap();
        let LayoutObject::Artwork(a) = &layout.objects[1] else { panic!() };
        assert_eq!(a.room_id, None);
        assert_eq!(layout.room_of(&layout.objects[1]).unwrap().id, "left");
    }

    #[test]
    fn v1_layout_upgrades() {
        let mut room = rooms_v2();
        room["left"]["enabled"] = json!(true);
        let layout = validate_layout(json!({
            "schemaVersion": 1,
            "kitVersion": "1.0.0",
            "rooms": room,
            "objects": [
                { "id": "home-001", "assetId": "home_sofa", "roomId": "hub", "position": [0, 0, -2.45], "rotationY": 0 },
                { "id": "home-002", "assetId": "plinth_ivory", "roomId": "hub", "position": [2, 0.0005, 2], "rotationY": 0, "artworkId": "art_vase" },
            ],
        }))
        .unwrap();
        assert_eq!(layout.schema_version, SCHEMA_VERSION);
        assert_eq!(layout.kit_version, KIT_VERSION);
        assert!(layout.rooms.left.enabled && layout.rooms.front.enabled);
        assert_eq!(layout.objects.len(), 2);
        assert!(layout.objects.iter().all(|o| matches!(o, LayoutObject::Furniture(_))));
        let value = serde_json::to_value(&layout).unwrap();
        assert_eq!(value["schemaVersion"], SCHEMA_VERSION);
        assert_eq!(value["objects"][1]["kind"], "furniture");
        assert_eq!(value["objects"][1]["position"], json!([2.0, 0.0, 2.0]));
        assert!(value["objects"][1].get("artworkId").is_none());
    }

    #[test]
    fn rejects_wall_clearance() {
        // ソファの奥行き 0.9 m。z = -4.43 で背面が -4.88 (壁から 12 cm)
        assert!(layout_of(json!([furniture("sofa", "home_sofa", 0.0, -4.43, 0.0)])).is_ok());
        let err = layout_of(json!([furniture("sofa", "home_sofa", 0.0, -4.5, 0.0)])).unwrap_err();
        assert!(err.contains("壁"), "{err}");
        // 90° 回すと幅 2.36 m が z 方向になる
        assert!(layout_of(json!([furniture("sofa", "home_sofa", 0.0, -3.8, PI / 2.0)])).is_err());
        assert!(err.contains("中央のリビング の壁"), "{err}");
        // v2 のリビングは 8 × 8 m だけ (v2 のころの大きさ)
        let mut room = rooms_v2();
        room["hub"]["width"] = json!(10);
        assert!(validate_layout(json!({ "schemaVersion": 2, "rooms": room, "objects": [] })).is_err());
    }

    #[test]
    fn rejects_wall_clearance_in_small_room() {
        // 8 × 8 の部屋の置ける範囲は ±3.88。スツール (0.52) は中心 ±3.62 まで
        for room in ["left", "right", "front"] {
            assert!(layout_of(json!([furniture_in(room, "s", "home_stool", -3.62, -3.62, 0.0)])).is_ok(), "{room}");
            let err = layout_of(json!([furniture_in(room, "s", "home_stool", -3.7, -3.62, 0.0)])).unwrap_err();
            let name = room_def(room).unwrap().name;
            assert!(err.contains(&format!("{name} の壁に近すぎます")), "{room}: {err}");
            // hub なら同じ位置に置ける
            assert!(layout_of(json!([furniture("s", "home_stool", -3.7, -3.62, 0.0)])).is_ok());
        }
        // 床置きの作品 (枠 0.8) は中心 ±3.48 まで
        assert!(layout_of(json!([on_floor("left", "art-1", ART_A, 3.48, -3.48)])).is_ok());
        let err = layout_of(json!([on_floor("left", "art-1", ART_A, 3.5, -3.48)])).unwrap_err();
        assert!(err.contains("左の部屋 の壁"), "{err}");
        assert_rect(room_rect(room_def("left").unwrap()), [-3.88, 3.88, -3.88, 3.88]);
        assert_rect(room_rect(room_def("hub").unwrap()), [-4.88, 4.88, -4.88, 4.88]);
    }

    #[test]
    fn rooms_do_not_collide_across_rooms() {
        // 同じローカル座標でも部屋が違えば重ならない
        let layout = layout_of(json!([
            furniture("hub-plinth", "plinth_ivory", 1.0, 1.0, 0.0),
            furniture_in("left", "left-plinth", "plinth_ivory", 1.0, 1.0, 0.0),
            furniture_in("right", "right-plinth", "plinth_ivory", 1.0, 1.0, 0.0),
            on_floor("front", "art-1", ART_A, 1.0, 1.0),
        ]))
        .unwrap();
        assert_eq!(layout.objects.len(), 4);
        // 同じ部屋なら重なる
        let err = layout_of(json!([
            furniture_in("left", "a", "plinth_ivory", 1.0, 1.0, 0.0),
            on_floor("left", "art-1", ART_A, 1.2, 1.0),
        ]))
        .unwrap_err();
        assert!(err.contains("重なって"), "{err}");
        // ラグは同じ部屋でも重なってよい
        assert!(layout_of(json!([
            furniture_in("front", "rug", "home_rug", 0.0, 0.0, 0.0),
            furniture_in("front", "table", "home_coffee_table", 0.0, 0.0, 0.0),
        ]))
        .is_ok());
    }

    #[test]
    fn door_zones_follow_room_defs() {
        let hub = room_def("hub").unwrap();
        let zones: Vec<Rect> = hub.doors.iter().map(|d| door_zone(hub, d)).collect();
        assert_eq!(zones.len(), 3);
        // 西・東・北 (キットと同じ: 幅 2.54、壁から 1.15)
        assert_rect(zones[0], [-5.0, -3.85, -1.27, 1.27]);
        assert_rect(zones[1], [3.85, 5.0, -1.27, 1.27]);
        assert_rect(zones[2], [-1.27, 1.27, -5.0, -3.85]);
        let one = |id: &str| {
            let room = room_def(id).unwrap();
            assert_eq!(room.doors.len(), 1, "{id}");
            door_zone(room, &room.doors[0])
        };
        assert_rect(one("left"), [2.85, 4.0, -1.27, 1.27]);
        assert_rect(one("right"), [-4.0, -2.85, -1.27, 1.27]);
        assert_rect(one("front"), [-1.27, 1.27, 2.85, 4.0]);
        // 隣の部屋は hub の壁を共有する: 隣の部屋の内壁 = hub の外壁 (5.0 + 0.24)
        for id in ["left", "right", "front"] {
            let room = room_def(id).unwrap();
            let distance = room.origin[0].abs().max(room.origin[1].abs());
            assert!(close(distance - room.size[0] / 2.0, hub.size[0] / 2.0 + WALL_THICKNESS), "{id}");
        }
    }

    #[test]
    fn door_zone_only_for_moved_objects() {
        // 東の出入口 (x 3.85〜5.0、z ±1.27) にかかるサイドボード
        let stored = layout_of(json!([
            furniture("console", "home_console", 3.7, 1.55, -FRAC_PI_2),
            furniture("sofa", "home_sofa", 0.0, 2.5, 0.0),
        ]))
        .unwrap();
        // 保存済みの物は読めて、動かさなければ保存もできる
        let check = |after: &Layout| check_placement(after, &Sizes::new(), DoorPolicy::OnlyMoved(&moved_ids(&stored, after)));
        assert!(check(&stored).is_ok());
        // ソファだけ動かしてもよい (サイドボードは見ない)
        let mut after = stored.clone();
        let LayoutObject::Furniture(sofa) = &mut after.objects[1] else { panic!() };
        sofa.position[0] = 0.5;
        assert_eq!(moved_ids(&stored, &after), HashSet::from(["sofa".to_string()]));
        assert!(check(&after).is_ok());
        // ゾーンの中でサイドボードを動かすと置けない
        let mut after = stored.clone();
        let LayoutObject::Furniture(console) = &mut after.objects[0] else { panic!() };
        console.position[2] = 1.4;
        let err = check(&after).unwrap_err();
        assert!(err.contains("中央のリビング の出入口の前には置けません"), "{err}");
        // 回すだけでも動かした扱い。2π 回したのは同じ向き
        let mut after = stored.clone();
        let turn = |after: &mut Layout, rotation_y: f64| {
            let LayoutObject::Furniture(console) = &mut after.objects[0] else { panic!() };
            console.rotation_y = rotation_y;
        };
        turn(&mut after, wrap_angle(-FRAC_PI_2 + TAU));
        assert!(moved_ids(&stored, &after).is_empty());
        turn(&mut after, FRAC_PI_2);
        assert!(check(&after).is_err());
        // ゾーンの外へ動かすのはよい
        let mut after = stored.clone();
        let LayoutObject::Furniture(console) = &mut after.objects[0] else { panic!() };
        console.position[2] = 2.4;
        assert!(check(&after).is_ok());
        // 新しく置く物がゾーンにかかれば置けない (家具も床置きの作品も)
        for new in [furniture("stool", "home_stool", 4.3, 0.0, 0.0), on_floor("hub", "art-1", ART_A, -4.3, 0.0)] {
            let mut raw = serde_json::to_value(&stored).unwrap();
            raw["objects"].as_array_mut().unwrap().push(new);
            let after = parse_layout(raw).unwrap();
            assert!(check(&after).unwrap_err().contains("出入口の前"));
            // 起動時・読むとき (Ignore) は見ない
            assert!(check_placement(&after, &Sizes::new(), DoorPolicy::Ignore).is_ok());
        }
        // 左・右・前の部屋の出入口 (左の部屋は東、x 2.85〜4.0)
        let mut raw = serde_json::to_value(&stored).unwrap();
        raw["objects"].as_array_mut().unwrap().push(furniture_in("left", "stool", "home_stool", 3.0, 0.5, 0.0));
        let err = check(&parse_layout(raw).unwrap()).unwrap_err();
        assert!(err.contains("左の部屋 の出入口の前"), "{err}");
        // 別の部屋へ移すのも動かした扱い
        let mut after = stored.clone();
        let LayoutObject::Furniture(sofa) = &mut after.objects[1] else { panic!() };
        sofa.room_id = "front".into();
        assert_eq!(moved_ids(&stored, &after), HashSet::from(["sofa".to_string()]));
    }

    #[test]
    fn rejects_furniture_overlap() {
        let err = layout_of(json!([
            furniture("sofa", "home_sofa", 0.0, 0.0, 0.0),
            furniture("table", "home_coffee_table", 0.5, 0.2, 0.0),
        ]))
        .unwrap_err();
        assert!(err.contains("重なって"), "{err}");
        // ぴったり接するのはよい (ソファの奥行き 0.9、ローテーブルの奥行き 0.78)
        assert!(layout_of(json!([
            furniture("sofa", "home_sofa", 0.0, 0.0, 0.0),
            furniture("table", "home_coffee_table", 0.0, 0.84, 0.0),
        ]))
        .is_ok());
        // 床置きの作品も 0.8 × 0.8 の家具として扱う
        assert!(layout_of(json!([
            furniture("sofa", "home_sofa", 0.0, 0.0, 0.0),
            { "kind": "artwork", "id": "art-1", "artworkId": ART_A, "roomId": "hub", "position": [1.0, 0, 0.5], "rotationY": 0 },
        ]))
        .is_err());
    }

    #[test]
    fn rug_may_overlap() {
        assert!(layout_of(json!([
            furniture("rug", "home_rug", 0.0, 0.0, 0.0),
            furniture("table", "home_coffee_table", 0.0, 0.0, 0.0),
            furniture("sofa", "home_sofa", 0.0, -1.0, 0.0),
        ]))
        .is_ok());
        // ラグも壁からは離す (幅 3.0 m。x = 3.5 で端が 5.0)
        assert!(layout_of(json!([furniture("rug", "home_rug", 3.5, 0.0, 0.0)])).is_err());
    }

    #[test]
    fn artwork_requires_support_parent() {
        let base = || vec![furniture("sofa", "home_sofa", 0.0, -2.0, 0.0), furniture("console", "home_console", 0.0, 2.0, 0.0)];

        let mut objects = base();
        objects.push(on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0));
        assert!(layout_of(json!(objects)).is_ok());

        // 天板の無い家具
        let mut objects = base();
        objects.push(on_top("art-1", ART_A, "sofa", 0.0, 0.0, 0.0));
        assert!(layout_of(json!(objects)).is_err());

        // 無い家具
        let mut objects = base();
        objects.push(on_top("art-1", ART_A, "nothing", 0.0, 0.0, 0.0));
        assert!(layout_of(json!(objects)).is_err());

        // 作品の上の作品 (入れ子) は不可
        let mut objects = base();
        objects.push(on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0));
        objects.push(on_top("art-2", ART_B, "art-1", 0.0, 0.0, 0.0));
        assert!(layout_of(json!(objects)).is_err());

        // 同じ作品を 2 か所に置くのは不可
        let mut objects = base();
        objects.push(on_top("art-1", ART_A, "console", -0.56, 0.0, 0.0));
        objects.push(on_top("art-2", ART_A, "console", 0.56, 0.0, 0.0));
        assert!(layout_of(json!(objects)).is_err());
    }

    #[test]
    fn artwork_must_fit_top_rect() {
        // ローテーブル: 縁が丸いので平らな所は幅 1.13 (置ける範囲 ±0.565)、作品の枠 0.56 → 中心は ±0.285 まで。
        // 家具の外形 (幅 1.37) までは置けない (丸い縁に載ると浮いて見える)
        let table = furniture("table", "home_coffee_table", 0.0, 0.0, 0.0);
        assert!(layout_of(json!([table.clone(), on_top("art-1", ART_A, "table", 0.28, 0.0, 0.0)])).is_ok());
        let err = layout_of(json!([table.clone(), on_top("art-1", ART_A, "table", 0.30, 0.0, 0.0)])).unwrap_err();
        assert!(err.contains("はみ出し"), "{err}");

        // サイドボード: 平らな所の奥行き 0.48 → 枠の奥行き 0.48 がちょうど収まる。
        // 寸法が分からない作品は枠のまま回すので、90° で 0.56 になり収まらない (実寸なら置ける: real_size_allows_90_degrees_on_narrow_tops)
        let console = furniture("console", "home_console", 0.0, 2.0, 0.0);
        assert!(layout_of(json!([console.clone(), on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0)])).is_ok());
        assert!(layout_of(json!([console, on_top("art-1", ART_A, "console", 0.0, 0.0, PI / 2.0)])).is_err());
    }

    #[test]
    fn sibling_artworks_may_not_overlap() {
        let console = furniture("console", "home_console", 0.0, 2.0, 0.0);
        let err = layout_of(json!([
            console.clone(),
            on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0),
            on_top("art-2", ART_B, "console", 0.3, 0.0, 0.0),
        ]))
        .unwrap_err();
        assert!(err.contains("重なって"), "{err}");
        // 枠 0.56 m の間隔なら接するだけ
        assert!(layout_of(json!([
            console,
            on_top("art-1", ART_A, "console", -0.56, 0.0, 0.0),
            on_top("art-2", ART_B, "console", 0.0, 0.0, 0.0),
            on_top("art-3", ART_C, "console", 0.56, 0.0, 0.0),
        ]))
        .is_ok());
    }

    #[test]
    fn rotation_wraps() {
        assert!(close(wrap_angle(3.0 * PI / 2.0), -PI / 2.0));
        assert!(close(wrap_angle(-PI), PI));
        assert!(close(wrap_angle(PI), PI));
        assert!(close(wrap_angle(7.0), 7.0 - TAU));
        assert!(close(wrap_angle(-7.0), -7.0 + TAU));
        // 範囲内の値はそのまま (キットの -π/2 を書き換えない)
        assert_eq!(wrap_angle(-std::f64::consts::FRAC_PI_2), -std::f64::consts::FRAC_PI_2);

        let layout = layout_of(json!([furniture("sofa", "home_sofa", 0.0, 0.0, 3.0 * PI)])).unwrap();
        let LayoutObject::Furniture(f) = &layout.objects[0] else { panic!() };
        assert!(close(f.rotation_y, PI));
        assert!(close(yaw_degrees(-PI / 2.0), -90.0));
        assert!(close(yaw_degrees(3.0 * PI / 2.0), -90.0));
    }

    #[test]
    fn world_of_rotated_parent() {
        // サイドボード (2.7, 0, 1.55)・θ = -π/2・作品 (0.5, 0, 0) → 世界 (2.7, 0.891, 2.05)、向き -90°
        let layout = layout_of(json!([
            furniture("home-005", "home_console", 2.7, 1.55, -std::f64::consts::FRAC_PI_2),
            on_top("art-1", ART_A, "home-005", 0.5, 0.0, 0.0),
            { "kind": "artwork", "id": "art-2", "artworkId": ART_B, "roomId": "hub", "position": [-1.0, 0, 1.0], "rotationY": 0.3 },
        ]))
        .unwrap();
        let (pos, yaw) = world_of(&layout, &layout.objects[1]).unwrap();
        assert!(close(pos[0], 2.7) && close(pos[1], 0.891) && close(pos[2], 2.05), "{pos:?}");
        assert!(close(yaw_degrees(yaw), -90.0), "{yaw}");

        let (pos, yaw) = world_of(&layout, &layout.objects[2]).unwrap();
        assert_eq!(pos, [-1.0, 0.0, 1.0]);
        assert!(close(yaw, 0.3));
    }

    #[test]
    fn world_of_adds_room_origin() {
        let layout = layout_of(json!([
            furniture_in("right", "desk", "home_craft_desk", 1.0, 2.0, 0.0),
            on_top("art-1", ART_A, "desk", 0.1, 0.0, 0.0),
            on_floor("front", "art-2", ART_B, 0.0, 1.0),
            furniture_in("left", "console", "home_console", 0.5, -1.0, -FRAC_PI_2),
            on_top("art-3", ART_C, "console", 0.5, 0.0, 0.0),
        ]))
        .unwrap();
        let world = |i: usize| world_of(&layout, &layout.objects[i]).unwrap();
        let near = |p: [f64; 3], want: [f64; 3]| p.iter().zip(want).all(|(a, b)| close(*a, b));
        // 右の部屋の家具 (1, 0, 2) → 世界 (9.24 + 1, 0, 2)
        let (pos, yaw) = world(0);
        assert!(near(pos, [10.24, 0.0, 2.0]) && yaw == 0.0, "{pos:?}");
        // その上の作品 = 家具の世界座標 + 面の中心 + 作品の位置 (工作机の天板の高さ 0.795)
        let (pos, _) = world(1);
        assert!(near(pos, [10.34, 0.795, 2.0]), "{pos:?}");
        // 前の部屋の床の作品 (0, 0, 1) → 世界 (0, 0, −9.24 + 1)
        let (pos, _) = world(2);
        assert!(near(pos, [0.0, 0.0, -8.24]), "{pos:?}");
        // 左の部屋で -90° 回したサイドボードの上の作品: 家具の世界座標 (−8.74, 0, −1) + 回した (0.5, 0) = (0, 0.5)
        let (pos, yaw) = world(4);
        assert!(near(pos, [-8.74, 0.891, -0.5]), "{pos:?}");
        assert!(close(yaw_degrees(yaw), -90.0));
        // 作品の部屋は親の家具の部屋
        assert_eq!(layout.room_of(&layout.objects[1]).unwrap().id, "right");
        assert_eq!(layout.room_of_id("art-2").unwrap().name, "前の部屋");
        assert_eq!(layout.room_of_id("art-3").unwrap().id, "left");
    }

    #[test]
    fn pick_spot_prefers_room_and_fails_when_full() {
        // hub の飾り棚 (2 か所)・左の部屋の細い台座 (1 か所)。右の部屋は家具なし
        let mut layout = layout_of(json!([
            furniture_in("left", "slim", "plinth_slim", 0.0, 0.0, 0.0),
            furniture("shelf", "home_display_shelf", 0.0, 0.0, 0.0),
        ]))
        .unwrap();
        // 部屋を指定しなければ hub から (配置 JSON では左の部屋の台座が先でも)
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, None).unwrap().parent_id, "shelf");
        // 左の部屋を指定すると左の部屋の家具だけ
        let spot = pick_spot(&layout, &Sizes::new(), None, Some("left"), None).unwrap();
        assert_eq!(spot.parent_id, "slim");
        // 家具の無い部屋はいっぱい (ほかの部屋には置かない)
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, Some("right"), None), None);
        // 左の部屋が埋まると、左の部屋を指定したときは None。指定しなければ hub に置ける
        layout.objects.push(artwork_on(Uuid::from_u128(1), spot));
        let layout = validate_layout(serde_json::to_value(&layout).unwrap()).unwrap();
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, Some("left"), None), None);
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, None).unwrap().parent_id, "shelf");
        // 指定した部屋に無い家具を prefer_parent にしても、その部屋の中だけを探す
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, Some("left"), Some("shelf")), None);
        assert_eq!(capacity_by_room(&layout)["left"], 1);
        assert_eq!(capacity_by_room(&layout)["hub"], 2);
        assert_eq!(capacity(&layout), 3);

        // hub が埋まると左の部屋へ (部屋は hub → left → right → front の順)
        let mut layout = layout_of(json!([
            furniture_in("front", "front-slim", "plinth_slim", 0.0, 0.0, 0.0),
            furniture_in("left", "left-slim", "plinth_slim", 0.0, 0.0, 0.0),
            furniture("hub-slim", "plinth_slim", 0.0, 0.0, 0.0),
        ]))
        .unwrap();
        for (i, want) in ["hub-slim", "left-slim", "front-slim"].iter().enumerate() {
            let spot = pick_spot(&layout, &Sizes::new(), None, None, None).unwrap();
            assert_eq!(spot.parent_id, *want, "{i}");
            layout.objects.push(artwork_on(Uuid::from_u128(i as u128 + 1), spot));
        }
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, None), None);
    }

    #[test]
    fn pick_spot_fills_cells_in_order_and_none_when_full() {
        // 飾り棚 (2 か所) → サイドボード (3 か所) の順に埋まる。ソファは天板が無いので使わない
        let mut layout = layout_of(json!([
            furniture("console", "home_console", 0.0, 2.0, 0.0),
            furniture("sofa", "home_sofa", 0.0, -2.0, 0.0),
            furniture("shelf", "home_display_shelf", 0.0, 0.0, 0.0),
        ]))
        .unwrap();
        // どちらも奥行きは 1 行分なので z は 0
        let expected = [
            ("shelf", -0.28, 0.0),
            ("shelf", 0.28, 0.0),
            ("console", -0.56, 0.0),
            ("console", 0.0, 0.0),
            ("console", 0.56, 0.0),
        ];
        for (i, (parent, x, z)) in expected.iter().enumerate() {
            let spot = pick_spot(&layout, &Sizes::new(), None, None, None).unwrap();
            assert_eq!(spot.parent_id, *parent, "{i}");
            assert_eq!(spot.surface, None, "{i}");
            let pos = spot.position;
            assert!(close(pos[0], *x) && pos[1] == 0.0 && close(pos[2], *z), "{i}: {pos:?}");
            layout.objects.push(artwork_on(Uuid::from_u128(i as u128 + 1), spot));
            layout = validate_layout(serde_json::to_value(&layout).unwrap()).unwrap();
        }
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, None), None);
    }

    #[test]
    fn pick_spot_prefers_and_skips_occupied_cells() {
        // 手で置いた作品が真ん中をふさいでいると、そこは飛ばす
        let layout = layout_of(json!([
            furniture("shelf", "home_display_shelf", 0.0, 0.0, 0.0),
            furniture("console", "home_console", 0.0, 2.0, 0.0),
            on_top("art-1", ART_A, "console", -0.4, 0.0, 0.0),
        ]))
        .unwrap();
        let spot = pick_spot(&layout, &Sizes::new(), None, None, Some("console")).unwrap();
        assert_eq!(spot.parent_id, "console");
        let pos = spot.position;
        assert!(close(pos[0], 0.56) && pos[2] == 0.0, "{pos:?}");
        // 天板の無い家具を指定しても順番どおりに探す
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, Some("nothing")).unwrap().parent_id, "shelf");
    }

    #[test]
    fn capacity_counts_cells() {
        let one = |asset_id: &str| capacity(&layout_of(json!([furniture("f", asset_id, 0.0, 0.0, 0.0)])).unwrap());
        assert_eq!(one("home_display_shelf"), 2);
        assert_eq!(one("home_console"), 3);
        assert_eq!(one("home_coffee_table"), 2);
        assert_eq!(one("home_craft_desk"), 2);
        // 低い台 (1.8 × 1.15) は枠の奥行きを 1.09 / 2 = 0.545 にして 3 列 × 2 並び
        assert_eq!(one("plinth_low"), 6);
        assert_eq!(one("plinth_ivory"), 1);
        assert_eq!(one("plinth_slim"), 1);
        // ベンチは 2 列、スツールは 1、本棚は 3 つの段に 1 つずつと天板に 2
        assert_eq!(one("bench_oak"), 2);
        assert_eq!(one("home_stool"), 1);
        assert_eq!(one("home_bookshelf"), 5);
        assert_eq!(one("home_sofa"), 0);
        assert_eq!(one("home_rug"), 0);
        // 作品を置いても数は変わらない (置ける場所の合計)
        let layout = layout_of(json!([
            furniture("console", "home_console", 0.0, 2.0, 0.0),
            on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0),
        ]))
        .unwrap();
        assert_eq!(capacity(&layout), 3);
    }

    /// 天板の大きさだけを変えた、カタログに無い家具の天板 (家具の幅・奥行きから縁の 3 cm を除く)
    fn top_of(w: f64, d: f64) -> Surface {
        top_surface_from_dimensions([w, 0.4, d], [0.0, 0.4, 0.0])
    }

    /// カタログの家具の天板
    fn top(asset_id: &str) -> &'static Surface {
        asset(asset_id).and_then(|a| a.surface(None)).unwrap()
    }

    #[test]
    fn cells_use_depth_on_deep_tops() {
        // 今のカタログで 2 並びになるのは低い台だけ。枠の奥行きは 1.09 / 2 = 0.545
        for a in CATALOG.assets.iter().filter(|a| a.is_support()) {
            for s in &a.surfaces {
                assert_eq!(cell_grid(s).1, if a.id == "plinth_low" { 2 } else { 1 }, "{} {}", a.id, s.id);
            }
        }
        let low = top("plinth_low");
        assert_eq!(cell_grid(low), (3, 2));
        assert!(close(art_fit(low)[2], 0.545), "{:?}", art_fit(low));
        // ほかの家具の枠の奥行きは、平らな所の奥行き (最大 0.56)
        assert!(close(art_fit(top("home_coffee_table"))[2], 0.56));
        assert!(close(art_fit(top("home_console"))[2], 0.48));

        // 奥行き 0.56 × 2 + 0.06 = 1.18 m なら 2 行。手前 (+z) の行から、行の中は -x から並ぶ
        let deep = top_of(1.8, 1.18);
        assert_eq!(cell_grid(&deep), (3, 2));
        assert_eq!(cell_count(&deep), 6);
        let cells: Vec<(f64, f64)> = cell_centers(&deep).collect();
        let expected = [(-0.56, 0.28), (0.0, 0.28), (0.56, 0.28), (-0.56, -0.28), (0.0, -0.28), (0.56, -0.28)];
        assert_eq!(cells.len(), expected.len());
        for (got, want) in cells.iter().zip(expected) {
            assert!(close(got.0, want.0) && close(got.1, want.1), "{got:?} != {want:?}");
        }
        // どの置き場所も天板からはみ出さず、隣どうしは接するだけ
        let [w, _, d] = art_fit(&deep);
        let rects: Vec<Rect> = cells.iter().map(|&(x, z)| footprint(x, z, w, d, 0.0)).collect();
        for (i, r) in rects.iter().enumerate() {
            assert!(rect_inside(r, &top_rect(&deep)), "{i}");
            assert!(rects[i + 1..].iter().all(|o| !rect_overlap(r, o)), "{i}");
        }

        // 手前の行が埋まると奥の行へ。真ん中に手で置いた作品が両方の行をふさぐと、そこは飛ばす
        let at = |x: f64, z: f64| footprint(x, z, w, d, 0.0);
        let near = |got: Option<(f64, f64)>, x: f64, z: f64| got.is_some_and(|g| close(g.0, x) && close(g.1, z));
        let front: Vec<Rect> = [-0.56, 0.0, 0.56].iter().map(|&x| at(x, 0.28)).collect();
        assert!(near(free_cell(&deep, &front, [w, d]), -0.56, -0.28));
        let middle = [at(-0.56, 0.28), at(0.0, 0.0)];
        assert!(near(free_cell(&deep, &middle, [w, d]), 0.56, 0.28));
        let all: Vec<Rect> = cells.iter().map(|&(x, z)| at(x, z)).collect();
        assert_eq!(free_cell(&deep, &all, [w, d]), None);
    }

    #[test]
    fn supports_with_top_anchor_have_a_top_surface() {
        for a in CATALOG.assets.iter().filter(|a| a.top_anchor.is_some()) {
            let top = a.surface(None).unwrap_or_else(|| panic!("{} に天板がありません", a.id));
            assert_eq!(top.id, TOP_SURFACE);
            assert_eq!(Some(top.anchor), a.top_anchor, "{}", a.id);
        }
    }

    #[test]
    fn artwork_surface_defaults_to_the_top() {
        let console = furniture("console", "home_console", 0.0, 2.0, 0.0);
        let with_surface = |surface: Value| {
            let mut art = on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0);
            art["surface"] = surface;
            layout_of(json!([console.clone(), art]))
        };
        // 省いても "top" と書いても天板。保存するときは省いた形にそろえる
        let implicit = layout_of(json!([console.clone(), on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0)])).unwrap();
        let explicit = with_surface(json!("top")).unwrap();
        assert_eq!(implicit, explicit);
        let saved = serde_json::to_value(&explicit).unwrap();
        assert!(saved["objects"][1].get("surface").is_none(), "{saved}");
        // 家具に無い面には置けない
        let err = with_surface(json!("shelf9")).unwrap_err();
        assert!(err.contains("shelf9"), "{err}");
        assert!(with_surface(json!(3)).is_err());
    }

    fn on_surface(id: &str, artwork: &str, parent: &str, surface: &str, x: f64, z: f64) -> Value {
        let mut art = on_top(id, artwork, parent, x, z, 0.0);
        art["surface"] = json!(surface);
        art
    }

    #[test]
    fn fits_follow_each_surface() {
        let shelf = asset("home_bookshelf").unwrap();
        // 棚の段は、上の棚板までのすき間から 4 cm 引いた高さまで
        for (id, height) in [("shelf1", 0.34), ("shelf2", 0.35), ("shelf3", 0.36)] {
            let s = shelf.surface(Some(id)).unwrap();
            assert!(close(art_fit(s)[1], height), "{id}: {:?}", art_fit(s));
            assert_eq!(cell_count(s), 1, "{id}");
        }
        // 本棚の天板は上が空いているので普通の高さで 2 列
        let top_of_shelf = shelf.surface(None).unwrap();
        assert!(close(art_fit(top_of_shelf)[1], ART_FIT_HEIGHT));
        assert_eq!(cell_grid(top_of_shelf), (2, 1));
        // ベンチ (幅 1.11) は 0.555 の 2 列、スツールは平らな所 0.3 にちょうど 1 つ
        assert!(close(art_fit(top("bench_oak"))[0], 0.555), "{:?}", art_fit(top("bench_oak")));
        assert_eq!(cell_grid(top("bench_oak")), (2, 1));
        assert_eq!(art_fit(top("home_stool")), [0.3, ART_FIT_HEIGHT, 0.3]);
    }

    #[test]
    fn artworks_on_different_shelves_do_not_collide() {
        let shelf = furniture("shelf", "home_bookshelf", 0.0, -3.0, 0.0);
        // 同じ (x, z) でも段が違えば重ならない
        assert!(layout_of(json!([
            shelf.clone(),
            on_surface("art-1", ART_A, "shelf", "shelf1", 0.0, 0.0),
            on_surface("art-2", ART_B, "shelf", "shelf2", 0.0, 0.0),
            on_top("art-3", ART_C, "shelf", -0.28, 0.0, 0.0),
        ]))
        .is_ok());
        // 同じ段の 2 つは重なる (段には 1 つしか置けない)
        let err = layout_of(json!([
            shelf.clone(),
            on_surface("art-1", ART_A, "shelf", "shelf1", 0.0, 0.0),
            on_surface("art-2", ART_B, "shelf", "shelf1", 0.0, 0.0),
        ]))
        .unwrap_err();
        assert!(err.contains("重なって"), "{err}");
        // 段の平らな所 (本の無い右側) からはみ出すと置けない
        let err = layout_of(json!([shelf, on_surface("art-1", ART_A, "shelf", "shelf1", -0.3, 0.0)])).unwrap_err();
        assert!(err.contains("はみ出し"), "{err}");
    }

    #[test]
    fn world_of_uses_the_surface_anchor() {
        // 本棚を 90° 回すと、段の中心 (x 0.2775, z 0.005) も一緒に回る
        let layout = layout_of(json!([
            furniture("shelf", "home_bookshelf", 1.0, -3.0, PI / 2.0),
            on_surface("art-1", ART_A, "shelf", "shelf1", 0.0, 0.0),
        ]))
        .unwrap();
        let (pos, yaw) = world_of(&layout, &layout.objects[1]).unwrap();
        // x' = x·cos θ + z·sin θ = 0.005、z' = −x·sin θ + z·cos θ = −0.2775
        assert!(close(pos[0], 1.005) && close(pos[1], 0.535) && close(pos[2], -3.2775), "{pos:?}");
        assert!(close(yaw, PI / 2.0));
    }

    #[test]
    fn pick_spot_uses_shelves_after_the_usual_supports() {
        let mut layout = layout_of(json!([
            furniture("shelf", "home_bookshelf", 0.0, -3.0, 0.0),
            furniture("slim", "plinth_slim", 2.0, 0.0, 0.0),
        ]))
        .unwrap();
        // 細い台座 → 本棚の段 (中・上・下) → 本棚の天板
        let expected = [("slim", None), ("shelf", Some("shelf2")), ("shelf", Some("shelf3")), ("shelf", Some("shelf1"))];
        for (i, (parent, surface)) in expected.iter().enumerate() {
            let spot = pick_spot(&layout, &Sizes::new(), None, None, None).unwrap();
            assert_eq!((spot.parent_id.as_str(), spot.surface.as_deref()), (*parent, *surface), "{i}");
            layout.objects.push(artwork_on(Uuid::from_u128(i as u128 + 1), spot));
            layout = validate_layout(serde_json::to_value(&layout).unwrap()).unwrap();
        }
        let spot = pick_spot(&layout, &Sizes::new(), None, None, None).unwrap();
        assert_eq!((spot.parent_id.as_str(), spot.surface), ("shelf", None));
        assert_eq!(capacity(&layout), 6);
    }

    fn raw_layout(objects: Value) -> Value {
        json!({ "schemaVersion": SCHEMA_VERSION, "kitVersion": KIT_VERSION, "rooms": rooms(), "objects": objects })
    }

    #[test]
    fn repair_drops_only_artworks_that_do_not_fit() {
        // 別の版のサーバーが保存した配置: この版の本棚に無い段の作品と、天板からはみ出した作品
        let raw = raw_layout(json!([
            furniture("console", "home_console", 0.0, 2.0, 0.0),
            on_top("art-1", ART_A, "console", -0.56, 0.0, 0.0),
            furniture("shelf", "home_bookshelf", -2.5, -3.0, 0.0),
            { "kind": "artwork", "id": "art-2", "artworkId": ART_B, "parentId": "shelf", "surface": "shelf9", "position": [0, 0, 0], "rotationY": 0 },
            on_top("art-3", ART_C, "console", 5.0, 0.0, 0.0),
        ]));
        assert!(validate_layout(raw.clone()).is_err());

        let (layout, dropped) = repair_layout(raw, &Sizes::new()).unwrap();
        assert_eq!(dropped, vec!["art-2".to_string(), "art-3".to_string()]);
        // 家具と置ける作品は元の順のまま残る
        let ids: Vec<&str> = layout.objects.iter().map(LayoutObject::id).collect();
        assert_eq!(ids, vec!["console", "art-1", "shelf"]);
        // 直した配置はそのまま検証に通る
        let value = serde_json::to_value(&layout).unwrap();
        assert_eq!(validate_layout(value).unwrap(), layout);
    }

    #[test]
    fn repair_keeps_a_valid_layout_as_is() {
        let raw = raw_layout(json!([
            furniture("console", "home_console", 0.0, 2.0, 0.0),
            on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0),
            { "kind": "artwork", "id": "art-2", "artworkId": ART_B, "position": [-2.0, 0, -2.0], "rotationY": 0 },
        ]));
        let (layout, dropped) = repair_layout(raw.clone(), &Sizes::new()).unwrap();
        assert!(dropped.is_empty());
        assert_eq!(layout, validate_layout(raw).unwrap());
    }

    #[test]
    fn repair_gives_up_when_furniture_is_broken() {
        // 家具どうしが重なっていたら直せない (呼び出し側が初期配置に戻す)
        let raw = raw_layout(json!([
            furniture("a", "home_console", 0.0, 2.0, 0.0),
            furniture("b", "home_console", 0.1, 2.0, 0.0),
            on_top("art-1", ART_A, "a", 0.0, 0.0, 0.0),
        ]));
        assert!(repair_layout(raw, &Sizes::new()).is_err());
    }

    /// 以前に共有のデータベースに保存されていた配置 (家具 12・作品 13)。
    /// 置ける範囲や置き方の決まりを変えたときに、今の配置が読めなくならない (初期配置に戻らない) ことを確かめる
    #[test]
    fn shared_layout_fixture_validates() {
        let raw: Value = serde_json::from_str(include_str!("testdata/shared-layout.json")).unwrap();
        // v2 の配置 (リビングだけの家) を v4 に上げても、家具 12・作品 13 はそのまま (すべて hub)
        assert_eq!(raw_schema_version(&raw), Some(2));
        let layout = validate_layout(raw.clone()).unwrap();
        assert_eq!(layout.schema_version, SCHEMA_VERSION);
        assert_eq!(layout.objects.len(), 25);
        assert_eq!(layout.artworks().filter(|a| a.parent_id.is_some()).count(), 13);
        let ids: Vec<&str> = layout.objects.iter().map(LayoutObject::id).collect();
        let raw_ids: Vec<&str> = raw["objects"].as_array().unwrap().iter().map(|o| o["id"].as_str().unwrap()).collect();
        assert_eq!(ids, raw_ids);
        // 家具の上の作品の位置はそのまま。壁ぎわの家具だけ、広がった分 (1 m) 壁の方へ動く
        let mut moved = Vec::new();
        for (obj, raw_obj) in layout.objects.iter().zip(raw["objects"].as_array().unwrap()) {
            assert_eq!(layout.room_of(obj).unwrap().id, HUB_ID, "{}", obj.id());
            let value = serde_json::to_value(obj).unwrap();
            if matches!(obj, LayoutObject::Artwork(_)) {
                assert_eq!(value["position"], raw_obj["position"], "{}", obj.id());
                continue;
            }
            let delta: Vec<f64> =
                (0..3).map(|k| value["position"][k].as_f64().unwrap() - raw_obj["position"][k].as_f64().unwrap()).collect();
            assert!(delta.iter().all(|d| [0.0, 1.0, -1.0].iter().any(|v| (d - v).abs() < 1e-9)), "{}: {delta:?}", obj.id());
            if delta.iter().any(|d| d.abs() > 0.5) {
                moved.push(obj.id());
            }
        }
        assert_eq!(moved, vec!["home-007", "home-008", "home-009", "home-011"]);
        assert_eq!(capacity_by_room(&layout)["hub"], capacity(&layout));
        // 出入口の前にかかる家具があっても、動かさなければ保存できる
        assert_eq!(door_blockers(&layout), vec!["home-011"]);
        check_placement(&layout, &Sizes::new(), DoorPolicy::OnlyMoved(&moved_ids(&layout, &layout))).unwrap();

        // アトリエの 13 点の実寸でも通り、どれも 1 倍以下で置かれる
        let sizes = atelier_sizes();
        check_placement(&layout, &sizes, DoorPolicy::Ignore).unwrap();
        for a in layout.artworks() {
            let size = sizes.get(&a.artwork_id).unwrap_or_else(|| panic!("{} の寸法がありません", a.id));
            let parent = layout.furniture(a.parent_id.as_deref().unwrap()).unwrap();
            let surface = asset(&parent.asset_id).unwrap().surface(a.surface.as_deref()).unwrap();
            let scale = display_scale(size, art_fit(surface), a.rotation_y);
            assert!(scale > 0.0 && scale <= 1.0, "{}: {scale}", a.id);
        }
    }

    #[test]
    fn catalog_has_fourteen_furniture_with_japanese_names() {
        assert_eq!(CATALOG.assets.len(), 14);
        assert!(CATALOG.assets.iter().all(|a| a.category == "furniture" && !a.name_ja.is_empty()));
        assert_eq!(CATALOG.assets.iter().filter(|a| a.is_support()).count(), 10);
        assert_eq!(CATALOG.themes.len(), 9);
        assert_eq!(CATALOG.materials.len(), 16);
    }

    /// 内装セット (finish-pack) の壁紙・床材の名前。素材の id と同じ
    const FINISH_PACK_WALLS: [&str; 5] = ["nordic_chalk", "sage_limewash", "mushroom_limewash", "warm_cream", "soft_brick"];
    const FINISH_PACK_FLOORS: [&str; 5] = ["white_oak", "pale_ash", "warm_walnut", "carrara_marble", "nero_marble"];

    #[test]
    fn catalog_themes_use_known_finishes_and_existing_textures() {
        // キットの 3 テーマのあとに内装セットの 6 テーマ (並びは catalog.json のまま)
        let ids: Vec<&str> = CATALOG.themes.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(
            ids,
            ["natural", "timber", "brick", "nordic_oak", "sage_ash", "white_marble", "dark_marble", "brick_oak", "walnut_cream"]
        );
        let mut seen = HashSet::new();
        for theme in &CATALOG.themes {
            assert!(WALLS.contains(&theme.wall.as_str()), "{}: 壁紙 {}", theme.id, theme.wall);
            assert!(FLOORS.contains(&theme.floor.as_str()), "{}: 床材 {}", theme.id, theme.floor);
            // 模様替えの「使用中」は壁紙と床材の組で決めるので、同じ組のテーマを作らない
            assert!(seen.insert((theme.wall.as_str(), theme.floor.as_str())), "{}: 同じ組のテーマがあります", theme.id);
        }
        // 内装セットの名前は素材の id と同じ (theme.ts の WALL_TEXTURE / FLOOR_TEXTURE)
        for id in FINISH_PACK_WALLS.iter().chain(&FINISH_PACK_FLOORS) {
            assert!(WALLS.contains(id) || FLOORS.contains(id), "{id} が許可リストにありません");
            let m = CATALOG.materials.get(*id).unwrap_or_else(|| panic!("素材 {id} がありません"));
            for file in [&m.base_color, &m.normal, &m.orm] {
                assert!(file.starts_with(&format!("finish-pack/{id}/")), "{id}: {file}");
            }
        }
        assert!(FINISH_PACK_WALLS.iter().all(|id| WALLS.contains(id) && !FLOORS.contains(id)));
        assert!(FINISH_PACK_FLOORS.iter().all(|id| FLOORS.contains(id) && !WALLS.contains(id)));
        // 素材の画像はすべて static/home/textures にある (/home-assets/textures/ で配信する)
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("static/home/textures");
        for (id, m) in &CATALOG.materials {
            assert!(m.tile_meters.iter().all(|t| *t > 0.0), "{id}: tileMeters");
            for file in [&m.base_color, &m.normal, &m.orm] {
                assert!(dir.join(file).is_file(), "{id}: {file} がありません");
            }
        }
    }

    #[test]
    fn finish_pack_wall_and_floor_round_trip_in_every_room() {
        // 内装セットの壁紙・床材を、どの部屋にも保存して読み直せる (物はそのまま)
        let theme = |wall: &str, floor: &str| {
            let mut raw = raw_layout(json!([furniture("sofa", "home_sofa", 0.0, 2.0, 0.0)]));
            for id in ["hub", "left", "right", "front"] {
                raw["rooms"][id]["wall"] = json!(wall);
                raw["rooms"][id]["floor"] = json!(floor);
            }
            raw
        };
        for (wall, floor) in FINISH_PACK_WALLS.iter().zip(&FINISH_PACK_FLOORS) {
            let layout = validate_layout(theme(wall, floor)).unwrap_or_else(|e| panic!("{wall} / {floor}: {e}"));
            for room in [&layout.rooms.hub, &layout.rooms.left, &layout.rooms.right, &layout.rooms.front] {
                assert_eq!((room.wall.as_str(), room.floor.as_str()), (*wall, *floor));
            }
            assert_eq!(layout.objects.len(), 1);
            let again = validate_layout(serde_json::to_value(&layout).unwrap()).unwrap();
            assert_eq!(again, layout);
        }
        // 部屋ごとに別の仕上げも持てる
        let mut raw = raw_layout(json!([]));
        raw["rooms"]["left"]["wall"] = json!("soft_brick");
        raw["rooms"]["front"]["floor"] = json!("nero_marble");
        let layout = validate_layout(raw).unwrap();
        assert_eq!((layout.rooms.left.wall.as_str(), layout.rooms.left.floor.as_str()), ("soft_brick", "oak"));
        assert_eq!((layout.rooms.front.wall.as_str(), layout.rooms.front.floor.as_str()), ("brick", "nero_marble"));
        assert_eq!(layout.rooms.hub.wall, "plaster");
        // 壁紙の名前は床に使えない (逆も)。知らない名前は今までどおり 400 の文言になる
        for (key, value) in [("floor", "soft_brick"), ("wall", "white_oak"), ("wall", "marble")] {
            let mut raw = raw_layout(json!([]));
            raw["rooms"]["hub"][key] = json!(value);
            let error = validate_layout(raw).unwrap_err();
            assert!(error.contains("壁紙か床材の名前"), "{key} = {value}: {error}");
        }
    }

    // =============================
    // 作品の実寸での判定
    // =============================

    /// アトリエの 13 点の寸法 (幅・高さ・奥行き)。static/atelier/catalog.json の dimensionsMeters を mm に丸めた値
    /// (GLB を測った値とも 1 mm 以内: glb::tests::measures_atelier_models_like_the_kit_catalog)
    const ATELIER: [(&str, [f64; 3]); 13] = [
        ("06_starbound_rocket", [0.381, 0.576, 0.3]),
        ("07_rainbow_sailboat", [0.56, 0.582, 0.34]),
        ("08_cardboard_stegosaurus", [0.622, 0.363, 0.34]),
        ("09_shoebox_aquarium", [0.524, 0.439, 0.27]),
        ("10_pocket_solar_system", [0.6, 0.598, 0.29]),
        ("11_butterfly_meadow", [0.48, 0.49, 0.32]),
        ("12_rainbow_express", [0.66, 0.465, 0.3]),
        ("13_forest_birdhouse", [0.47, 0.428, 0.366]),
        ("14_tulip_windmill", [0.47, 0.481, 0.354]),
        ("15_memory_camera", [0.42, 0.41, 0.3]),
        ("16_little_fire_engine", [0.6, 0.297, 0.34]),
        ("17_little_bakery", [0.466, 0.421, 0.34]),
        ("18_wishwheel", [0.57, 0.525, 0.34]),
    ];

    fn seed_id(asset_id: &str) -> Uuid {
        crate::seed::seed_id(asset_id)
    }

    /// アトリエの 13 点の寸法 (作品 id は seed と同じ)
    fn atelier_sizes() -> Sizes {
        ATELIER.iter().map(|(asset_id, size)| (seed_id(asset_id), ArtSize { size: *size, custom: true })).collect()
    }

    /// 実寸で検証した配置
    fn sized(objects: Value, sizes: &Sizes) -> Result<Layout, String> {
        let layout = parse_layout(raw_layout(objects))?;
        check_placement(&layout, sizes, DoorPolicy::Ignore)?;
        Ok(layout)
    }

    #[test]
    fn atelier_sizes_match_the_kit_catalog() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/static/atelier/catalog.json");
        let Ok(text) = std::fs::read_to_string(path) else {
            // フォルダが無い構成でも動くようにしてある (seed は何もしない)
            return;
        };
        let items: Vec<Value> = serde_json::from_str(&text).unwrap();
        assert_eq!(items.len(), ATELIER.len());
        for (asset_id, size) in ATELIER {
            let item = items.iter().find(|i| i["assetId"] == asset_id).unwrap_or_else(|| panic!("{asset_id} がありません"));
            for (k, want) in size.iter().enumerate() {
                let got = item["dimensionsMeters"][k].as_f64().unwrap();
                assert!((got - want).abs() <= 5e-4, "{asset_id}: {got} != {want}");
            }
        }
    }

    #[test]
    fn display_scale_fits_rotated_extents() {
        let boat = ArtSize { size: [0.56, 0.582, 0.34], custom: true };
        let fit = art_fit(top("home_console"));
        assert!(close(fit[0], 0.56) && close(fit[1], 0.62) && close(fit[2], 0.48), "{fit:?}");
        // 帆船 × サイドボード: 0° は実寸、90° は奥行き 0.48 に幅 0.56 を収める、45° は外接長方形 0.9·√½ を 0.48 に
        assert!(close(display_scale(&boat, fit, 0.0), 1.0));
        let right = display_scale(&boat, fit, PI / 2.0);
        assert!(close(right, 0.48 / 0.56) && (right - 0.857142).abs() < 1e-6, "{right}");
        let diagonal = display_scale(&boat, fit, PI / 4.0);
        assert!(close(diagonal, 0.48 / (0.9 * FRAC_1_SQRT_2)) && (diagonal - 0.7542).abs() < 1e-4, "{diagonal}");
        // どの向きでも、置いた後の大きさを回した外接長方形と高さは枠に収まる
        for rotation in [0.0, PI / 4.0, PI / 2.0, 1.0, -2.5, PI] {
            let [w, h, d] = placed_size(&boat, fit, rotation);
            let r = footprint(0.0, 0.0, w, d, rotation);
            assert!(r.max_x - r.min_x <= fit[0] + 1e-12 && r.max_z - r.min_z <= fit[2] + 1e-12 && h <= fit[1] + 1e-12);
        }
        // 仮生成の額縁 (800 × 600) は custom でないので、枠に合わせて縮める (サイドボードで 0.56 / 1.35 ≈ 0.415)
        let frame = ArtSize { size: [1.35, 1.08, 0.28], custom: false };
        let scale = display_scale(&frame, fit, 0.0);
        assert!(close(scale, 0.56 / 1.35) && (scale - 0.415).abs() < 1e-3, "{scale}");
        // custom でない小さな作品は枠まで大きくする (1 倍の上限なし)。custom は 1 倍まで
        let small = ArtSize { size: [0.1, 0.1, 0.1], custom: false };
        assert!(close(display_scale(&small, fit, 0.0), 4.8));
        assert!(close(display_scale(&ArtSize { custom: true, ..small }, fit, 0.0), 1.0));
    }

    #[test]
    fn art_size_from_model_needs_all_three() {
        let size = ArtSize::from_model(Some(0.5), Some(0.4), Some(0.3), "custom").unwrap();
        assert_eq!(size, ArtSize { size: [0.5, 0.4, 0.3], custom: true });
        assert!(!ArtSize::from_model(Some(0.5), Some(0.4), Some(0.3), "frame").unwrap().custom);
        assert_eq!(ArtSize::from_model(Some(0.5), None, Some(0.3), "custom"), None);
        assert_eq!(ArtSize::from_model(Some(0.5), Some(0.0), Some(0.3), "custom"), None);
        assert_eq!(ArtSize::from_model(Some(f64::NAN), Some(0.4), Some(0.3), "custom"), None);
    }

    #[test]
    fn real_size_allows_90_degrees_on_narrow_tops() {
        let sizes = atelier_sizes();
        let boat = seed_id("07_rainbow_sailboat").to_string();
        // サイドボード (奥行き 0.48) と飾り棚 (0.43)
        for (parent, asset_id) in [("console", "home_console"), ("shelf", "home_display_shelf")] {
            let objects = json!([furniture(parent, asset_id, 0.0, 2.0, 0.0), on_top("art-1", &boat, parent, 0.0, 0.0, PI / 2.0)]);
            assert!(sized(objects.clone(), &sizes).is_ok(), "{parent}");
            // 寸法が分からなければ枠 (幅 0.56) を回すので、奥行きからはみ出す
            let err = sized(objects, &Sizes::new()).unwrap_err();
            assert!(err.contains("はみ出し"), "{parent}: {err}");
        }
    }

    #[test]
    fn siblings_use_their_own_sizes() {
        let sizes = atelier_sizes();
        let camera = seed_id("15_memory_camera");
        // カメラ (幅 0.42) とロケット (0.381) を ±0.21 に並べると、実寸では重ならない
        let objects = json!([
            furniture("console", "home_console", 0.0, 2.0, 0.0),
            on_top("art-1", &camera.to_string(), "console", -0.21, 0.0, 0.0),
            on_top("art-2", &seed_id("06_starbound_rocket").to_string(), "console", 0.21, 0.0, 0.0),
        ]);
        assert!(sized(objects.clone(), &sizes).is_ok());
        // 枠 (0.56) どうしなら重なる
        let err = sized(objects.clone(), &Sizes::new()).unwrap_err();
        assert!(err.contains("重なって"), "{err}");
        // 寸法の分からないロケットは枠のまま (カメラの実寸と重なる)
        let only_camera: Sizes = sizes.iter().filter(|(id, _)| **id == camera).map(|(id, s)| (*id, *s)).collect();
        assert!(sized(objects, &only_camera).is_err());
    }

    #[test]
    fn pick_spot_uses_real_footprints() {
        let sizes = atelier_sizes();
        // 手で置いたカメラ (幅 0.42) が左の置き場所に、ロケット (幅 0.381) が右寄り (x 0.45、0.2595〜0.6405) にある
        let layout = sized(
            json!([
                furniture("console", "home_console", 0.0, 2.0, 0.0),
                on_top("art-1", &seed_id("15_memory_camera").to_string(), "console", -0.56, 0.0, 0.0),
                on_top("art-2", &seed_id("06_starbound_rocket").to_string(), "console", 0.45, 0.0, 0.0),
            ]),
            &sizes,
        )
        .unwrap();
        // 枠どうしでは、真ん中の置き場所 (±0.28) がロケットの枠 (0.17〜0.73) と重なって空きが無い
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, None), None);
        // 載っている作品が実寸でも、置く作品の寸法が分からなければ枠 (±0.28) がロケットと重なる
        assert_eq!(pick_spot(&layout, &sizes, None, None, None), None);
        // 帆船 (幅 0.56) も重なる。ちょうちょ (幅 0.48 → ±0.24) なら真ん中が空いている
        assert_eq!(pick_spot(&layout, &sizes, Some(&sizes[&seed_id("07_rainbow_sailboat")]), None, None), None);
        let meadow = seed_id("11_butterfly_meadow");
        let spot = pick_spot(&layout, &sizes, Some(&sizes[&meadow]), None, None).unwrap();
        assert_eq!((spot.parent_id.as_str(), spot.surface.as_deref()), ("console", None));
        assert!(close(spot.position[0], 0.0) && spot.position[2] == 0.0, "{:?}", spot.position);
        // 選んだ場所は実寸の検証に通る
        let mut layout = layout;
        layout.objects.push(artwork_on(meadow, spot));
        assert!(check_placement(&layout, &sizes, DoorPolicy::Ignore).is_ok());
    }

    #[test]
    fn clamp_to_rect_clamps_and_centres_when_too_big() {
        // サイドボードの平らな所 (±0.87 × ±0.24)
        let rect = top_rect(top("home_console"));
        let near = |(x, z): (f64, f64), want_x: f64, want_z: f64| close(x, want_x) && close(z, want_z);
        // 中なら動かさない
        assert!(near(clamp_to_rect(&rect, 0.56, 0.34, 0.0, 0.1, -0.02), 0.1, -0.02));
        // 縁まで寄せる
        assert!(near(clamp_to_rect(&rect, 0.56, 0.34, 0.0, 10.0, 10.0), 0.59, 0.07));
        assert!(near(clamp_to_rect(&rect, 0.56, 0.34, 0.0, -10.0, -10.0), -0.59, -0.07));
        // 90° 回すと幅と奥行きが入れ替わる。奥行き 0.48 に幅 0.56 は収まらないので z は中央
        assert!(near(clamp_to_rect(&rect, 0.56, 0.34, PI / 2.0, 10.0, 10.0), 0.70, 0.0));
        // 寄せた位置は面からはみ出さない
        let (x, z) = clamp_to_rect(&rect, 0.4, 0.2, PI / 4.0, 10.0, -10.0);
        assert!(rect_inside(&footprint(x, z, 0.4, 0.2, PI / 4.0), &rect), "{x} {z}");
        // 面より大きければ両方とも中央
        assert!(near(clamp_to_rect(&rect, 2.0, 1.0, 0.0, 10.0, -10.0), 0.0, 0.0));
    }

    // =============================
    // 総当たり表 (testdata/placement-cases.json)。
    // Web の検査 (npm run check:placement) も同じ表を読んで、placement.ts で同じ値になるかを確かめる
    // =============================

    /// 45° も入れるとファイルが大きくなりすぎるので、0° と 90° だけ。45° は extra の pair-at-45-on-console と
    /// display_scale_fits_rotated_extents で確かめる
    const ROTATIONS: [f64; 2] = [0.0, FRAC_PI_2];
    /// 家具の面で寄せる目標 (面の中心から見た位置。clamp_to_rect で面の中へ寄せる)
    const TARGETS: [(&str, [f64; 2]); 4] =
        [("centre", [0.0, 0.0]), ("+x", [10.0, 0.0]), ("-z", [0.0, -10.0]), ("+x+z", [10.0, 10.0])];
    /// 床で寄せる目標 (部屋の中心から見た位置)。面の 4 つに、西と南の出入口の前へ寄せる -x・+z を足す
    const FLOOR_TARGETS: [(&str, [f64; 2]); 6] = [
        ("centre", [0.0, 0.0]),
        ("+x", [10.0, 0.0]),
        ("-z", [0.0, -10.0]),
        ("+x+z", [10.0, 10.0]),
        ("-x", [-10.0, 0.0]),
        ("+z", [0.0, 10.0]),
    ];
    const POSITION_TOLERANCE: f64 = 1e-9;
    const SCALE_TOLERANCE: f64 = 1e-6;
    /// 表で、新しく置く物 (出入口の前を見る物) の object id
    const CANDIDATE_ID: &str = "cand";

    /// 表の作品: 名前・作品 id・寸法 (None は寸法なし)。アトリエの 13 点、仮生成の額縁、寸法の分からない作品
    fn case_arts() -> Vec<(String, Uuid, Option<ArtSize>)> {
        let mut arts: Vec<_> = ATELIER
            .iter()
            .map(|(asset_id, size)| (asset_id.to_string(), seed_id(asset_id), Some(ArtSize { size: *size, custom: true })))
            .collect();
        let fixed = |s: &str| Uuid::parse_str(s).unwrap();
        let frame = ArtSize { size: [1.35, 1.08, 0.28], custom: false };
        arts.push(("frame_800x600".into(), fixed("00000000-0000-4000-8000-000000000800"), Some(frame)));
        arts.push(("unknown".into(), fixed("00000000-0000-4000-8000-0000000000ff"), None));
        arts
    }

    /// 作品を載せられる家具を 1 つずつ hub に並べた配置 (家具の id は "f-<assetId>"、向きは 0)
    fn supports_layout() -> Value {
        let at = [
            ("home_console", -2.5, -3.0),
            ("home_display_shelf", 0.0, -3.0),
            ("home_bookshelf", 2.5, -3.0),
            ("home_coffee_table", -2.5, -1.5),
            ("home_craft_desk", 0.0, -1.5),
            ("bench_oak", 2.5, -1.5),
            ("plinth_low", -2.5, 0.5),
            ("plinth_ivory", 0.0, 0.5),
            ("plinth_slim", 1.5, 0.5),
            ("home_stool", 2.8, 0.5),
        ];
        assert_eq!(at.len(), CATALOG.assets.iter().filter(|a| a.is_support()).count());
        let objects: Vec<Value> =
            at.iter().map(|(asset_id, x, z)| furniture(&format!("f-{asset_id}"), asset_id, *x, *z, 0.0)).collect();
        let raw = raw_layout(json!(objects));
        validate_layout(raw.clone()).unwrap();
        raw
    }

    /// layouts.rooms の白い台座の位置 (部屋のローカル座標。台座は 0.87 四方なので 1.765〜2.635)
    const ROOMS_PLINTH_AT: [f64; 2] = [3.2, 3.2];

    /// 左・右・前の部屋に、白い台座 ("f-<部屋>") を同じローカル座標 ROOMS_PLINTH_AT に置いた配置。hub は空。
    /// 部屋が違えば同じローカル座標でも重ならないので、3 つとも置ける。どの部屋の出入口の前にもかからない
    fn rooms_layout() -> Value {
        let [x, z] = ROOMS_PLINTH_AT;
        let objects: Vec<Value> = ["left", "right", "front"]
            .iter()
            .map(|room| furniture_in(room, &format!("f-{room}"), "plinth_ivory", x, z, 0.0))
            .collect();
        let raw = raw_layout(json!(objects));
        validate_layout(raw.clone()).unwrap();
        raw
    }

    /// 表の作品をどこに置くか
    #[derive(Clone, Copy)]
    enum On<'a> {
        /// (家具の id, 面の id)
        Surface(&'a str, &'a str),
        /// 部屋の床
        Floor(&'a str),
    }

    /// 表の作品の配置 JSON
    fn art_object(id: &str, artwork: Uuid, on: On, x: f64, z: f64, rotation: f64) -> Value {
        let mut o = json!({ "kind": "artwork", "id": id, "artworkId": artwork, "position": [x, 0.0, z], "rotationY": rotation });
        match on {
            On::Surface(parent, surface) => {
                o["parentId"] = json!(parent);
                if surface != TOP_SURFACE {
                    o["surface"] = json!(surface);
                }
            }
            On::Floor(room) => o["roomId"] = json!(room),
        }
        o
    }

    /// layout に objects を足した配置が検証に通るか。moved なら id "cand" の物だけ出入口の前を見る (保存済みの物は見ない)
    fn fits(layout: &Value, objects: &[Value], sizes: &Sizes, moved: bool) -> bool {
        let mut raw = layout.clone();
        raw["objects"].as_array_mut().unwrap().extend(objects.iter().cloned());
        let candidate: HashSet<String> = moved.then(|| CANDIDATE_ID.to_string()).into_iter().collect();
        check_placement(&parse_layout(raw).unwrap(), sizes, DoorPolicy::OnlyMoved(&candidate)).is_ok()
    }

    /// 表の上の段に書く説明 (Web の check-placement.mjs を書く人向け)
    const NOTES: [&str; 8] = [
        "配置 JSON は schemaVersion 4 (10 × 10 と 8 × 8 の 4 部屋)。家具と床置きの作品の position は、所属する部屋 (roomId) の中心から見たローカル座標。部屋は回さない",
        "house は /api/museum の house と同じ形 (model_url は null)。部屋の置ける範囲は ±(size / 2 − wall_margin)、はみ出しは 2 mm (tolerance ではなく home.rs の TOLERANCE = 0.002) まで許す",
        "door_zone: 出入口の前の置けない場所。壁に沿って出入口の中心 (offset) から ±width / 2、壁の内側の面から部屋の中へ depth。重なりと同じく 2 mm より深くかかったら置けない",
        "layouts.supports = 作品を載せられる家具を hub に 1 つずつ。layouts.floor = 空の家。layouts.rooms = 左・右・前の部屋に白い台座 (f-left・f-right・f-front) を同じローカル座標 (3.2, 0, 3.2) に置いた家 (hub は空)",
        "cases: surface が \"floor\" の行は room (hub・left・right・front) の床に layouts.rooms で置く (候補の roomId = room)。それ以外の行は \"<assetId>/<面の id>\" の面に layouts.supports で置く (parentId = \"f-<assetId>\")",
        "cases の target: 面は centre・+x・-z・+x+z の 4 つ、床はそれに -x・+z を足した 6 つ (targets の座標を、面または部屋の矩形へ clamp_to_rect で寄せた位置が position)",
        "cases の候補 (id \"cand\") は新しく置いた物として判定する (DoorPolicy::OnlyMoved({cand}))。床の候補は所属する部屋の出入口の前にかかると ok: false。layouts の家具は保存済みの物なので出入口の前を見ない",
        "extra: layout に objects (保存済みの物) を足して candidate (id \"cand\") を置けるか。moved が true なら候補の出入口の前を見る、false なら見ない (動かしていない保存済みの物と同じ扱い)",
    ];

    fn placement_cases() -> Value {
        let arts = case_arts();
        let sizes: Sizes = arts.iter().filter_map(|(_, id, size)| size.map(|s| (*id, s))).collect();
        let supports = supports_layout();
        let floor = raw_layout(json!([]));
        let rooms = rooms_layout();
        let layout_of_name = |name: &str| match name {
            "floor" => &floor,
            "rooms" => &rooms,
            _ => &supports,
        };

        // 置く場所: 配置の名前・表の名前・置き方・枠・置ける範囲・目標
        struct Place<'a> {
            layout: &'static str,
            surface: String,
            on: On<'a>,
            fit: [f64; 3],
            rect: Rect,
            targets: &'static [(&'static str, [f64; 2])],
        }
        let mut places: Vec<Place> = Vec::new();
        for f in supports["objects"].as_array().unwrap() {
            let (furniture_id, asset_id) = (f["id"].as_str().unwrap(), f["assetId"].as_str().unwrap());
            for s in &asset(asset_id).unwrap().surfaces {
                places.push(Place {
                    layout: "supports",
                    surface: format!("{asset_id}/{}", s.id),
                    on: On::Surface(furniture_id, &s.id),
                    fit: art_fit(s),
                    rect: top_rect(s),
                    targets: &TARGETS,
                });
            }
        }
        for room in &ROOM_DEFS {
            places.push(Place {
                layout: "rooms",
                surface: "floor".into(),
                on: On::Floor(room.id),
                fit: FLOOR_ART_FIT,
                rect: room_rect(room),
                targets: &FLOOR_TARGETS,
            });
        }

        let mut cases = Vec::new();
        for place in &places {
            for (art_name, artwork, size) in &arts {
                for rotation in ROTATIONS {
                    for (target_name, [tx, tz]) in place.targets {
                        let [w, _, d] = size.map_or(place.fit, |s| placed_size(&s, place.fit, rotation));
                        let (x, z) = clamp_to_rect(&place.rect, w, d, rotation, *tx, *tz);
                        let candidate = art_object(CANDIDATE_ID, *artwork, place.on, x, z, rotation);
                        let mut case = json!({
                            "layout": place.layout,
                            "surface": place.surface,
                            "art": art_name,
                            "rotation": rotation,
                            "target": target_name,
                            "position": [x, z],
                            "scale": size.map(|s| display_scale(&s, place.fit, rotation)),
                            "ok": fits(layout_of_name(place.layout), &[candidate], &sizes, true),
                        });
                        if let On::Floor(room) = place.on {
                            case["room"] = json!(room);
                        }
                        cases.push(case);
                    }
                }
            }
        }

        // 置いてある作品との重なり・壁・床の額縁・寸法の分からない作品・部屋・出入口
        let id_of = |name: &str| arts.iter().find(|a| a.0 == name).unwrap().1;
        let console = On::Surface("f-home_console", TOP_SURFACE);
        let floor_of = |room: &'static str| On::Floor(room);
        let (boat, rocket) = (id_of("07_rainbow_sailboat"), id_of("06_starbound_rocket"));
        // 45° の帆船をサイドボードの左端に寄せた位置 (外接長方形 0.48 四方)
        let console_top = top("home_console");
        let [w, _, d] = placed_size(&sizes[&boat], art_fit(console_top), FRAC_PI_4);
        let (left_x, left_z) = clamp_to_rect(&top_rect(console_top), w, d, FRAC_PI_4, -10.0, 0.0);
        // 床の帆船 (1 倍。幅 0.56・奥行き 0.34)
        let boat_on = |room: &'static str, x: f64, z: f64| art_object(CANDIDATE_ID, boat, floor_of(room), x, z, 0.0);
        let extra_cases = [
            // 帆船 (-0.58〜-0.02) とロケット (-0.0905〜0.2905) が重なる
            (
                "overlap-pair",
                "supports",
                vec![art_object("art-1", boat, console, -0.3, 0.0, 0.0)],
                art_object(CANDIDATE_ID, rocket, console, 0.1, 0.0, 0.0),
                true,
            ),
            // 床の帆船を x 4.7 に置くと壁から 12 cm 空かない
            ("floor-near-wall", "floor", vec![], boat_on("hub", 4.7, 0.0), true),
            // 額縁 (幅 1.35) は床の枠 0.8 に縮むので、壁ぎわ (4.08〜4.88) にも置ける。床の帆船 (2.22〜2.78) とも重ならない
            // (z 2.5 なので東の出入口 (z ±1.27) にはかからない)
            (
                "frame-on-floor",
                "floor",
                vec![art_object("art-1", boat, floor_of("hub"), 2.5, 2.5, 0.0)],
                art_object(CANDIDATE_ID, id_of("frame_800x600"), floor_of("hub"), 4.48, 2.5, 0.0),
                true,
            ),
            // 寸法が分からなければ枠 (0.56 × 0.48) を 90° 回すので、サイドボードの奥行きからはみ出す
            (
                "unknown-size-90-on-console",
                "supports",
                vec![],
                art_object(CANDIDATE_ID, id_of("unknown"), console, 0.0, 0.0, FRAC_PI_2),
                true,
            ),
            // 45° でも実寸を縮めて奥行き 0.48 に収める。左端の帆船 (-0.87〜-0.39) と中央のロケット (±0.24) は重ならない
            // (枠のまま回すと 0.735 四方になり、どちらもはみ出す)
            (
                "pair-at-45-on-console",
                "supports",
                vec![art_object("art-1", boat, console, left_x, left_z, FRAC_PI_4)],
                art_object(CANDIDATE_ID, rocket, console, 0.0, 0.0, FRAC_PI_4),
                true,
            ),
            // 左・右・前の台座 (3.2, 3.2) に近い (2.8, 2.8) でも、hub なら重ならない。左の部屋なら台座と重なる
            ("cross-room-same-local-position", "rooms", vec![], boat_on("hub", 2.8, 2.8), true),
            ("same-room-overlap-left", "rooms", vec![], boat_on("left", 2.8, 2.8), true),
            // 8 × 8 の部屋の壁 (置ける範囲 ±3.88): x 3.6 なら帆船の端がちょうど 3.88、x 3.7 ははみ出す
            ("small-room-wall-edge", "floor", vec![], boat_on("left", 3.6, -1.8), true),
            ("small-room-wall", "floor", vec![], boat_on("left", 3.7, -1.8), true),
            // hub の東の出入口 (x 3.85〜5.0、z ±1.27)。新しく置く・動かすなら置けない。動かしていない保存済みの物なら読める
            ("door-zone-moved", "floor", vec![], boat_on("hub", 4.3, 0.0), true),
            ("door-zone-existing", "floor", vec![], boat_on("hub", 4.3, 0.0), false),
            // 帆船の端 (3.85) がゾーンの縁にちょうど接するだけなら置ける (2 mm まで許す)
            ("door-zone-touching", "floor", vec![], boat_on("hub", 3.57, 0.0), true),
            // 8 × 8 の部屋の出入口: 左は東 (x 2.85〜4.0)、右は西 (x −4.0〜−2.85)、前は南 (z 2.85〜4.0)
            ("door-zone-left", "floor", vec![], boat_on("left", 3.3, 0.5), true),
            ("door-zone-right", "floor", vec![], boat_on("right", -3.3, -0.5), true),
            ("door-zone-front", "floor", vec![], boat_on("front", 0.5, 3.3), true),
            // 家具の候補も同じ。細い台座 (0.59) を左の部屋の出入口の前に置くと置けない
            (
                "furniture-door-zone-left",
                "floor",
                vec![],
                furniture_in("left", CANDIDATE_ID, "plinth_slim", 3.3, 0.0, 0.0),
                true,
            ),
            // 白い台座を台座と同じ (3.2, 3.2) に: hub なら置ける、右の部屋なら f-right と重なる
            (
                "furniture-cross-room",
                "rooms",
                vec![],
                furniture_in("hub", CANDIDATE_ID, "plinth_ivory", 3.2, 3.2, 0.0),
                true,
            ),
            (
                "furniture-same-room-right",
                "rooms",
                vec![],
                furniture_in("right", CANDIDATE_ID, "plinth_ivory", 3.2, 3.2, 0.0),
                true,
            ),
            // ラグ (3.0 × 2.26) は台座と重なってよい (右の部屋の f-right の上。西の出入口にはかからない) が、
            // 出入口の前は見る (前の部屋の南の出入口)
            (
                "rug-over-plinth",
                "rooms",
                vec![],
                furniture_in("right", CANDIDATE_ID, "home_rug", 2.0, 2.5, 0.0),
                true,
            ),
            (
                "rug-in-door-zone",
                "rooms",
                vec![],
                furniture_in("front", CANDIDATE_ID, "home_rug", 0.0, 2.6, 0.0),
                true,
            ),
        ];
        let extra: Vec<Value> = extra_cases
            .into_iter()
            .map(|(id, layout_name, objects, candidate, moved)| {
                let mut all = objects.clone();
                all.push(candidate.clone());
                let ok = fits(layout_of_name(layout_name), &all, &sizes, moved);
                json!({ "id": id, "layout": layout_name, "objects": objects, "candidate": candidate, "moved": moved, "ok": ok })
            })
            .collect();

        let catalog: Vec<Value> = CATALOG
            .assets
            .iter()
            .map(|a| {
                let surfaces: Vec<Value> = a
                    .surfaces
                    .iter()
                    .map(|s| json!({ "id": s.id, "anchor": s.anchor, "size": s.size, "art_fit": art_fit(s) }))
                    .collect();
                json!({
                    "id": a.id,
                    "name_ja": a.name_ja,
                    "dimensions_meters": a.dimensions_meters,
                    "layer": a.layer,
                    "support": a.is_support(),
                    "surfaces": surfaces,
                })
            })
            .collect();
        let arts_json: Map<String, Value> = arts
            .iter()
            .map(|(name, id, size)| {
                let value = json!({ "artwork_id": id, "size": size.map(|s| s.size), "custom": size.is_none_or(|s| s.custom) });
                (name.clone(), value)
            })
            .collect();
        let targets: Map<String, Value> = FLOOR_TARGETS.iter().map(|(name, t)| (name.to_string(), json!(t))).collect();
        // API と同じ文字列 (f32 は "7.24" のように短く書かれる) を経由して、Web が受け取る値と同じにする
        let house: Value =
            serde_json::from_str(&serde_json::to_string(&crate::museum_api::house_view(|_| None)).unwrap()).unwrap();

        json!({
            "generated_by": "cargo test regen_placement_cases -- --ignored",
            "notes": NOTES,
            "tolerance": { "position": POSITION_TOLERANCE, "scale": SCALE_TOLERANCE },
            "floor_art_fit": FLOOR_ART_FIT,
            "wall_margin": WALL_MARGIN,
            "door_zone": { "width": DOOR_ZONE_WIDTH, "depth": DOOR_ZONE_DEPTH },
            "house": house,
            "catalog": { "assets": catalog },
            "layouts": { "supports": supports, "floor": floor, "rooms": rooms },
            "arts": arts_json,
            "targets": targets,
            "cases": cases,
            "extra": extra,
        })
    }

    /// 総当たり表のファイルの中身。上の段の項目は決まった順に、cases・extra などは 1 件 1 行で書く (差分を読みやすく)
    fn placement_cases_text(value: &Value) -> String {
        const KEYS: [&str; 13] = [
            "generated_by",
            "notes",
            "tolerance",
            "floor_art_fit",
            "wall_margin",
            "door_zone",
            "house",
            "catalog",
            "layouts",
            "arts",
            "targets",
            "cases",
            "extra",
        ];
        assert_eq!(value.as_object().unwrap().len(), KEYS.len());
        let compact = |v: &Value| serde_json::to_string(v).unwrap();
        let nested = |v: &Value| matches!(v, Value::Object(_) | Value::Array(_));
        let mut out = String::from("{\n");
        for (i, key) in KEYS.iter().enumerate() {
            let value = &value[*key];
            let body = match value {
                Value::Array(items) if items.iter().any(nested) || *key == "notes" => {
                    let lines: Vec<String> = items.iter().map(|v| format!("    {}", compact(v))).collect();
                    format!("[\n{}\n  ]", lines.join(",\n"))
                }
                Value::Object(map) if map.values().any(nested) => {
                    let lines: Vec<String> =
                        map.iter().map(|(k, v)| format!("    {}: {}", compact(&json!(k)), compact(v))).collect();
                    format!("{{\n{}\n  }}", lines.join(",\n"))
                }
                _ => compact(value),
            };
            let comma = if i + 1 < KEYS.len() { "," } else { "" };
            out += &format!("  {}: {body}{comma}\n", compact(&json!(key)));
        }
        out += "}\n";
        out
    }

    /// 2 つの表の違い (数は許容の範囲で比べる。scale は 1e-6、ほかは 1e-9)
    fn compare_cases(path: &str, a: &Value, b: &Value, diffs: &mut Vec<String>) {
        match (a, b) {
            (Value::Number(x), Value::Number(y)) => {
                let tolerance = if path.ends_with("/scale") { SCALE_TOLERANCE } else { POSITION_TOLERANCE };
                if (x.as_f64().unwrap() - y.as_f64().unwrap()).abs() > tolerance {
                    diffs.push(format!("{path}: {x} != {y}"));
                }
            }
            (Value::Array(x), Value::Array(y)) if x.len() == y.len() => {
                for (i, (p, q)) in x.iter().zip(y).enumerate() {
                    compare_cases(&format!("{path}/{i}"), p, q, diffs);
                }
            }
            (Value::Object(x), Value::Object(y)) if x.len() == y.len() && x.keys().all(|k| y.contains_key(k)) => {
                for (k, v) in x {
                    compare_cases(&format!("{path}/{k}"), v, &y[k], diffs);
                }
            }
            _ if a == b => {}
            _ => diffs.push(format!("{path}: {a} != {b}")),
        }
    }

    /// 総当たり表を作り直す: cargo test regen_placement_cases -- --ignored
    #[test]
    #[ignore]
    fn regen_placement_cases() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/src/testdata/placement-cases.json");
        std::fs::write(path, placement_cases_text(&placement_cases())).unwrap();
    }

    /// 置き方の決まりを変えたら、総当たり表を作り直して Web の検査 (npm run check:placement) も通す
    #[test]
    fn placement_cases_match() {
        let saved: Value = serde_json::from_str(include_str!("testdata/placement-cases.json")).unwrap();
        let mut diffs = Vec::new();
        compare_cases("", &saved, &placement_cases(), &mut diffs);
        assert!(
            diffs.is_empty(),
            "総当たり表が今の計算と違います ({} か所。cargo test regen_placement_cases -- --ignored で作り直す):\n{}",
            diffs.len(),
            diffs[..diffs.len().min(20)].join("\n")
        );
    }

    /// 受け入れ条件: アトリエの 13 点すべてが、どの面の中央にも (どの部屋の床の中央にも) 0° でも 90° でも置ける
    #[test]
    fn every_atelier_artwork_fits_every_surface_at_0_and_90_degrees() {
        let cases = placement_cases();
        let mut checked = 0;
        for c in cases["cases"].as_array().unwrap() {
            let rotation = c["rotation"].as_f64().unwrap();
            let atelier = ATELIER.iter().any(|(asset_id, _)| c["art"] == *asset_id);
            if atelier && c["target"] == "centre" && (rotation == 0.0 || rotation == FRAC_PI_2) {
                assert_eq!(c["ok"], true, "{c}");
                checked += 1;
            }
        }
        // (面 13 (本棚は段 3 つと天板) + 4 部屋の床) × 13 点 × 2 つの向き
        let surfaces: usize = CATALOG.assets.iter().map(|a| a.surfaces.len()).sum();
        assert_eq!(surfaces, 13);
        assert_eq!(checked, (surfaces + ROOM_DEFS.len()) * ATELIER.len() * 2);
    }
}
