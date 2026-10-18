//! おうちの配置 JSON (v5) の型・検証・座標の計算。DB を使わない純粋な処理だけを置く。
//!
//! - 座標はメートル、Y-up。中央のリビング (hub) の中心が世界の原点で、床は y = 0。入口は南 (+Z) 側。
//! - 家の部屋は ROOM_DEFS (今は中央のリビング hub だけ)。部屋は平行移動だけで回さない。部屋ごとに世界での中心 origin を持つ。
//!   家具と床置きの作品の position は、所属する部屋 (roomId) の中心から見た位置で、世界 = origin + position。
//!   家具の上の作品は親の家具から決まる (部屋の平行移動は親に 1 回だけ掛かる)。
//! - 家具の原点は底面の中心、正面は +Z。rotationY θ で +Z は (sinθ, 0, cosθ) を向く (three.js と同じ)。
//!   壁に掛ける家具 (catalog の placement が "wall") だけは、原点が背面の底の中心で、背面を部屋の壁の内側の面に付ける。
//!   position の y はその家具の底面の高さ (模様替えで上げ下げできる)。床の家具と作品の y はいつも 0。
//! - 家具に載せる作品の position は、親の家具の「回す前」の向きで、載せる面 (天板・本棚の段など。surface) の中心からの位置。
//! - 置けるかどうかの判定は、家のキット (MemoryMuseum_Home の museum-kit.js の canPlace) を書き直したもの。
//!   Web の `web/src/three/scenes/home/placement.ts` と同じ計算にしておくこと (総当たり表 testdata/placement-cases.json で照合する)。
//! - この配置 JSON だけは camelCase (キットの JSON と同じ形)。ほかの API の項目は snake_case。

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    f64::consts::{FRAC_PI_2, PI, TAU},
    sync::LazyLock,
};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

/// 配置 JSON の版。5 は中央のリビング (10 × 10) だけの家 (1〜4 は読み込むときに 5 に上げる)。
/// 4 は 10 × 10 と 8 × 8 の 4 部屋、3 は 8 × 8 と 6 × 6 の 4 部屋 (V3_HUB_SIZE)、2 はリビングだけ、1 はキットの JSON
pub const SCHEMA_VERSION: u32 = 5;
pub const KIT_VERSION: &str = "1.1.0-home";

/// 中央のリビングの id。床置きの作品で roomId を省いたときもこの部屋
pub const HUB_ID: &str = "hub";
pub const FLOOR_ID: &str = "1F";

// =============================
// 部屋の定義 (家の形はここだけに書く。/api/museum の house で Web に渡す)
// =============================

/// 壁の向き。北 = −Z (入口から入って正面)、南 = +Z (入口側)、西 = −X (左)、東 = +X (右)。
/// 今の家 (リビングだけ・出入口なし) では使わない向きもある (出入口の判定のテストで使う)
#[allow(dead_code)]
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

/// 壁の厚さ (m)。hub の内壁は ±5.0、外面は ±5.24
pub const WALL_THICKNESS: f64 = 0.24;

/// 出入口 (キット v1 の portal_arch_3m: バウ 3.0 m・通れる幅 2.10 m・アーチの頂 2.60 m)。
/// 今の家には出入口が無い (部屋を戻すときと、出入口の判定のテストで使う)
#[allow(dead_code)]
const fn portal(side: Side) -> Door {
    Door { side, offset: 0.0, clear_width: 2.10, height: 2.60 }
}

/// 家の部屋 (この順に API へ出す。作品の自動配置もこの順に部屋を探す)。
///
/// 今は中央のリビング (hub) の 1 部屋だけ。10 × 10 m、世界の原点。出入口は無い (壁はふさがっている)。
/// 以前は hub の西・東・北に左・右・前の部屋 (8 × 8 m、中心は hub から 9.24 m) があり、hub の壁の中央の出入口でつながっていた
/// (v4 まで。消した部屋の id は LEGACY_ROOM_IDS)。部屋を戻すときは、ここに RoomDef を足し、hub の doors に出入口を足して、
/// 建物の GLB (tools/home-rooms/build_rooms.py)・配置の版の引き上げ・初期配置・総当たり表を合わせる (git の履歴に前の値がある)
pub static ROOM_DEFS: [RoomDef; 1] = [RoomDef {
    id: "hub",
    name: "中央のリビング",
    origin: [0.0, 0.0],
    size: [10.0, 10.0],
    model: "hub.glb",
    doors: &[],
    cutaway: &[Side::South, Side::East],
}];

/// v4 まであった左・右・前の部屋の id。v4 までの配置にあるこの部屋の物は、読むときに外す
const LEGACY_ROOM_IDS: [&str; 3] = ["left", "right", "front"];

/// v3 までの hub の内寸。v3 までの配置を読むときに、部屋が広がった分だけ壁ぎわの物を動かすのに使う
const V3_HUB_SIZE: [f64; 2] = [8.0, 8.0];

/// 壁からこれより近い物を「壁ぎわの物」として、v3 から v4 に上げるときに壁といっしょに動かす (足元の外接長方形と壁の内側の面の距離, m)
const WALL_HUG: f64 = 0.6;

/// id の部屋 (今は hub だけ)
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
/// 部屋の壁の高さ (m)。建物の GLB (tools/home-rooms/build_rooms.py の H) と Web の house.ts の WALL_TOP と同じ。
/// 壁の家具は、上に飾る作品の枠まで含めてこれより下に掛ける。キットは 3.2 m だが、積み上げの建物で壁が低く見えないよう 4.2 m にした
pub const WALL_HEIGHT: f64 = 4.2;
/// 壁の家具を掛けられるいちばん低い高さ (底面の y, m)
pub const WALL_MOUNT_MIN: f64 = 0.3;
/// 壁の家具の向きの許容 (ラジアン)。90° ごとの向きにだけ掛けられる
const ANGLE_EPSILON: f64 = 1e-6;
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
/// 壁に掛ける作品 (写真の額縁) の枠。幅と奥行きを同じにして、どの壁に掛けても (90° ごとのどの向きでも) 同じ大きさにする
pub const WALL_ART_FIT: [f64; 3] = [0.9, 0.9, 0.9];
/// 作品の placement の値 (壁に掛ける)。catalog.json の家具の placement と同じ言葉
pub const WALL_PLACEMENT: &str = "wall";
/// 壁に作品を自動で掛けるときの、作品の中心の高さ (m)。1 段目の壁が埋まったら 2 段目
const WALL_ART_CENTERS: [f64; 2] = [1.6, 2.75];
/// 壁に作品を自動で掛けるときの、作品どうしの間と、壁の角から空ける距離 (m)
const WALL_ART_GAP: f64 = 0.3;
/// 壁に作品を自動で掛けるときに、前をふさぐ家具が無いかを見る、壁から部屋の中への奥行き (m)
const WALL_ART_VIEW: f64 = 0.8;
/// 家具の天板の面の id。作品の surface を省いたときはこの面
pub const TOP_SURFACE: &str = "top";

/// 作品を自動で置くときに探す家具の順番。本棚・ベンチ・スツールは、今までの家具が埋まってから使う。
/// 壁の家具 (利用者が模様替えで足したときだけある) は最後
const SUPPORT_ORDER: [&str; 13] = [
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
    "wall_floating_shelf_french_oak",
    "wall_picture_ledge_french_oak",
    "wall_cabinet_french_oak",
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

/// 部屋の仕上げ (壁紙・床材)。今は中央のリビング (hub) だけ。enabled: true で、大きさは ROOM_DEFS のまま
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Rooms {
    pub hub: Room,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Room {
    /// 常に true (キットの JSON と同じ形にするために残している)
    pub enabled: bool,
    /// 内寸 (m)。hub は 10 で変えられない
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
    /// 置いている部屋 (今は hub だけ)
    pub room_id: String,
    /// 部屋の中心から見た位置。y は壁の家具の底面の高さ (床の家具は 0)
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
    /// 床に置くときだけ、置いている部屋 (今は hub だけ)。
    /// 家具の上の作品は None (部屋は親の家具の部屋)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room_id: Option<String>,
    /// 親の家具のどの面に載せるか (本棚の段など)。天板 ("top") のときは省く
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
    /// 壁に掛ける作品は "wall" (写真の額縁だけ。家具には載せない)。
    /// position の (x, z) は足元の中心、y は作品の底面の高さで、背面を壁の内側の面に付ける。家具の上と床の作品は省く
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placement: Option<String>,
    pub position: [f64; 3],
    pub rotation_y: f64,
}

impl ArtworkObject {
    /// 載せている面の id (省いていれば天板)
    pub fn surface_id(&self) -> &str {
        self.surface.as_deref().unwrap_or(TOP_SURFACE)
    }

    /// 壁に掛けている作品か
    pub fn on_wall(&self) -> bool {
        self.placement.as_deref() == Some(WALL_PLACEMENT)
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

    /// object id の物のある部屋 (テストで使う。作品のおへやは artworks.house_room_id で引く)
    #[cfg(test)]
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
    // y は壁の家具の高さ (上げ下げも動かしたことにする。床の物はいつも 0)
    let same_pose = |p: [f64; 3], r: f64, q: [f64; 3], s: f64| {
        near(p[0], q[0]) && near(p[1], q[1]) && near(p[2], q[2]) && wrap_angle(r - s).abs() <= MOVE_EPSILON
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
                && x.placement == y.placement
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
        placement: None,
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
    /// "floor" (床に置く) か "wall" (壁に掛ける)。壁の家具は原点が背面の底の中心で、背面を部屋の壁に付ける
    #[serde(default = "floor_placement")]
    pub placement: String,
    /// 壁の家具を足したときに掛ける高さ (底面の y, m)。模様替えで上げ下げできる
    #[serde(default)]
    pub mount_height: Option<f64>,
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

    /// 壁に掛ける家具か
    pub fn is_wall(&self) -> bool {
        self.placement == "wall"
    }

    /// 家具が上に場所を取る高さ (底面から, m): 家具の高さか、面に飾る作品の枠の上のどちらか高いほう。
    /// 壁の家具とその下・上の物が重なるかを、この高さで見る (サイドボードの上の壁に棚を掛けるなら、作品の枠より上)
    pub fn reach(&self) -> f64 {
        self.surfaces
            .iter()
            .map(|s| s.anchor[1] + art_fit(s)[1])
            .fold(self.dimensions_meters[1], f64::max)
    }

    pub fn file_name(&self) -> String {
        format!("{}.glb", self.id)
    }
}

fn floor_placement() -> String {
    "floor".into()
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
    /// 写真の額縁 (model_kind = "frame")。壁に掛けられるのはこれだけ
    pub frame: bool,
}

impl ArtSize {
    /// DB の列 (model_width / model_height / model_depth) から。3 つ揃って正の数のときだけ
    pub fn from_model(width: Option<f64>, height: Option<f64>, depth: Option<f64>, model_kind: &str) -> Option<Self> {
        let size = [width?, height?, depth?];
        size.iter()
            .all(|v| v.is_finite() && *v > 0.0)
            .then_some(ArtSize { size, custom: model_kind == "custom", frame: model_kind == "frame" })
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

/// 部屋の壁の内側の面で囲まれた範囲 (部屋の中心から見た座標)。壁の家具はこの中に収める
pub fn room_inner_rect(def: &RoomDef) -> Rect {
    let (hx, hz) = (def.size[0] / 2.0, def.size[1] / 2.0);
    Rect { min_x: -hx, max_x: hx, min_z: -hz, max_z: hz }
}

/// 家具の足元 (真上から見た外接長方形、部屋の中の座標)。床の家具は原点が底面の中心。
/// 壁の家具は原点が背面なので、正面 (+Z を rotation_y で回した (sinθ, cosθ)) の向きへ奥行きの半分ずらした所が中心
pub fn furniture_rect(f: &Furniture, a: &Asset) -> Rect {
    let [w, _, d] = a.dimensions_meters;
    let (mut x, mut z) = (f.position[0], f.position[2]);
    if a.is_wall() {
        let (sin, cos) = f.rotation_y.sin_cos();
        x += d / 2.0 * sin;
        z += d / 2.0 * cos;
    }
    footprint(x, z, w, d, f.rotation_y)
}

/// 壁の家具の背面が付いている壁。向きが 90° ごとで、背面 (正面の逆) が壁の内側の面にあるときだけ Some。
/// rotation_y 0 は正面 +Z で北の壁 (z = −奥行き / 2)、π は南の壁、π/2 は正面 +X で西の壁、−π/2 は東の壁
pub fn wall_side(f: &Furniture, def: &RoomDef) -> Option<Side> {
    let quarter = (f.rotation_y / FRAC_PI_2).round();
    if (f.rotation_y - quarter * FRAC_PI_2).abs() > ANGLE_EPSILON {
        return None;
    }
    let (hw, hd) = (def.size[0] / 2.0, def.size[1] / 2.0);
    let [x, _, z] = f.position;
    let (side, gap) = match (quarter as i64).rem_euclid(4) {
        0 => (Side::North, z + hd),
        2 => (Side::South, z - hd),
        1 => (Side::West, x + hw),
        _ => (Side::East, x - hw),
    };
    (gap.abs() <= TOLERANCE).then_some(side)
}

/// 壁に掛けた作品の背面が付いている壁。向きが 90° ごとで、足元 (rect) の背面の側が壁の内側の面にあるときだけ Some。
/// rotation_y 0 は正面 +Z で北の壁、π は南の壁、π/2 は正面 +X で西の壁、−π/2 は東の壁 (壁の家具の wall_side と同じ向き)
pub fn art_wall_side(rotation_y: f64, rect: &Rect, def: &RoomDef) -> Option<Side> {
    let quarter = (rotation_y / FRAC_PI_2).round();
    if (rotation_y - quarter * FRAC_PI_2).abs() > ANGLE_EPSILON {
        return None;
    }
    let inner = room_inner_rect(def);
    let (side, gap) = match (quarter as i64).rem_euclid(4) {
        0 => (Side::North, rect.min_z - inner.min_z),
        2 => (Side::South, rect.max_z - inner.max_z),
        1 => (Side::West, rect.min_x - inner.min_x),
        _ => (Side::East, rect.max_x - inner.max_x),
    };
    (gap.abs() <= TOLERANCE).then_some(side)
}

/// 壁の家具を掛けられる高さ (底面の y の下限と上限, m)。上に飾る作品の枠まで壁の高さに収める
pub fn mount_range(a: &Asset) -> (f64, f64) {
    (WALL_MOUNT_MIN, WALL_HEIGHT - a.reach())
}

/// 2 つの高さの範囲 (下, 上) が 2 mm より深く重なっていれば true
fn span_overlap(a: (f64, f64), b: (f64, f64)) -> bool {
    a.0 < b.1 - TOLERANCE && a.1 > b.0 + TOLERANCE
}

/// 出入口の前の、新しく置いたり動かしたりできない場所 (部屋の中心から見た座標)。
/// 壁に沿って出入口の中心 (offset) から ±DOOR_ZONE_WIDTH / 2、壁の内側の面から部屋の中へ DOOR_ZONE_DEPTH。
/// 例: 10 × 10 の部屋の東の出入口は x ∈ [3.85, 5.0]・z ∈ [−1.27, 1.27] (今の家には出入口が無い)
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

/// 配置 JSON の形を確かめて、正規化した配置 (いつも v5) を返す。位置 (重なり・はみ出し) は見ない。
///
/// - schemaVersion 1 (キットの JSON)・2 (リビングだけの家)・3 (8 × 8 と 6 × 6 の 4 部屋)・4 (10 × 10 と 8 × 8 の 4 部屋) は 5 に上げる。
///   リビングの壁紙・床材はそのまま。左・右・前の部屋とそこにあった物 (家具・床の作品・その家具の上の作品) は外す (drop_legacy_rooms)。
/// - v3 までは hub が 8 × 8 だったので、部屋が広がった分だけ、壁ぎわの物を壁といっしょに動かす (widen_from_v3)。
/// - hub の大きさは版ごとに決まっている (v4・v5 は 10 × 10、v3 までは 8 × 8)。違えば Err。
/// - v5 の rooms は hub だけ。家具と床置きの作品の roomId は hub
pub fn parse_layout(raw: Value) -> Result<Layout, String> {
    let Value::Object(root) = raw else {
        return Err("配置データの形式が正しくありません".into());
    };
    let version = match root.get("schemaVersion").and_then(Value::as_u64) {
        Some(v @ 1..=5) => v,
        _ => return Err("配置データの版 (schemaVersion) は 1〜5 にしてください".into()),
    };
    let v1 = version == 1;
    let rooms = parse_rooms(root.get("rooms"), version)?;
    let list = root
        .get("objects")
        .and_then(Value::as_array)
        .ok_or("配置データに objects がありません")?;
    let list = if version <= 4 { drop_legacy_rooms(list) } else { list.clone() };
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

/// v4 までの配置から、消した部屋 (LEGACY_ROOM_IDS) にある物を外す: その部屋の家具・床置きの作品と、その家具の上の作品。
/// 外した作品は配置から無くなるので、起動時の reconcile が空いている所へ置き直す (空きが無ければ「飾っていない」に戻る)
fn drop_legacy_rooms(list: &[Value]) -> Vec<Value> {
    let in_legacy_room =
        |item: &Value| item.get("roomId").and_then(Value::as_str).is_some_and(|id| LEGACY_ROOM_IDS.contains(&id));
    let is_furniture = |item: &Value| item.get("kind").and_then(Value::as_str) != Some("artwork");
    let dropped: HashSet<&str> = list
        .iter()
        .filter(|item| is_furniture(item) && in_legacy_room(item))
        .filter_map(|item| item.get("id").and_then(Value::as_str))
        .collect();
    list.iter()
        .filter(|item| {
            let on_dropped = item.get("parentId").and_then(Value::as_str).is_some_and(|p| dropped.contains(p));
            let floor_in_legacy = item.get("parentId").is_none() && in_legacy_room(item);
            !on_dropped && !floor_in_legacy
        })
        .cloned()
        .collect()
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
    let old = V3_HUB_SIZE;
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
    // 消した部屋の物は、家具も作品も先に外す (parse_layout と同じ)
    let list = if version.is_some_and(|v| v <= 4) { drop_legacy_rooms(&list) } else { list };
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

/// rooms を読む。hub が必要で、enabled は true にそろえる (false が来ても使う部屋にする)。
/// hub の大きさは版ごとに決まっていて (v4・v5 は ROOM_DEFS、v3 までは V3_HUB_SIZE)、読んだ配置はいつも ROOM_DEFS の大きさにする。
/// v4 までの左・右・前の部屋は読まずに外す。v5 に hub 以外の部屋があれば Err
fn parse_rooms(value: Option<&Value>, version: u64) -> Result<Rooms, String> {
    let rooms = value.and_then(Value::as_object).ok_or("配置データに rooms がありません")?;
    if version >= 5
        && let Some(other) = rooms.keys().find(|id| room_def(id).is_none())
    {
        return Err(format!("部屋「{other}」はありません (rooms は hub だけ)"));
    }
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
        let expected = if version <= 3 { V3_HUB_SIZE.map(|v| v as i64) } else { fixed };
        let size = |key: &str| {
            r.get(key)
                .and_then(Value::as_i64)
                .filter(|n| (4..=12).contains(n))
                .ok_or_else(|| format!("部屋 {id} の大きさは 4〜12 の整数にしてください"))
        };
        let size = [size("width")?, size("depth")?];
        if size != expected {
            return Err(format!("部屋の大きさは変えられません ({} は {} × {} m)", def.name, expected[0], expected[1]));
        }
        let wall = r.get("wall").and_then(Value::as_str).filter(|w| WALLS.contains(w));
        let floor = r.get("floor").and_then(Value::as_str).filter(|f| FLOORS.contains(f));
        let (Some(wall), Some(floor)) = (wall, floor) else {
            return Err(format!("部屋 {id} の壁紙か床材の名前が正しくありません"));
        };
        Ok(Room { enabled: true, width: fixed[0], depth: fixed[1], wall: wall.into(), floor: floor.into() })
    };

    let [hub] = &ROOM_DEFS;
    Ok(Rooms { hub: room(hub)? })
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
    let mut position = parse_position(o.get("position"))?;
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
            let Some(a) = asset(asset_id).filter(|a| a.category == "furniture") else {
                return Err(format!("家具「{asset_id}」はありません"));
            };
            // 床の家具は床に置く (高さは壁の家具だけ)
            if !a.is_wall() {
                position[1] = 0.0;
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
            // 壁に掛けるのは、家具に載せていない作品だけ
            let placement = match (o.get("placement"), &parent_id) {
                (None | Some(Value::Null), _) => None,
                (Some(Value::String(p)), None) if p == WALL_PLACEMENT => Some(p.clone()),
                _ => return Err(format!("作品の placement は、壁に掛けるときだけ \"{WALL_PLACEMENT}\" にしてください")),
            };
            // 作品の高さは、載せている面か床で決まる。壁に掛ける作品だけ y が底面の高さ
            if placement.is_none() {
                position[1] = 0.0;
            }
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
                placement,
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
    // y は壁の家具の高さにだけ使う (parse_object が床の物を 0 にする)
    match numbers.as_deref() {
        Some(&[x, y, z]) if x.abs() <= MAX_COORD && y.abs() <= MAX_COORD && z.abs() <= MAX_COORD => Ok([x, y, z]),
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

/// 位置の検証。床の物 (家具と床置きの作品)・壁の家具・壁に掛けた作品は、所属する部屋のローカル座標で次を見る:
/// 1. 床の物は、部屋の壁から 12 cm 空ける (room_rect。2 mm まで許す)。
///    壁の家具は、90° ごとの向きで背面を壁の内側の面に付け (wall_side)、壁の内側からはみ出さず (room_inner_rect)、
///    高さ (底面の y) は WALL_MOUNT_MIN から、上に飾る作品の枠まで壁の高さに収まるところまで (mount_range)。
///    壁に掛けた作品は写真の額縁だけ (sizes の frame)。大きさは WALL_ART_FIT に収めたもので、壁の家具と同じく
///    背面を壁に付け (art_wall_side)、壁の内側からはみ出さず、底面の y は WALL_MOUNT_MIN から、作品の上端が壁の高さまで
/// 2. doors が見る物は、その部屋の出入口の前 (door_zone) にかからない (2 mm まで許す)。ラグもここは見る
/// 3. 同じ部屋の物どうしが、足元 (真上から見た外接長方形) と高さの範囲の両方で重ならない
///    (ラグはほかと重なってよい。別の部屋の物とは比べない)。高さの範囲は、床の家具が 0 から reach (家具の高さか、
///    面に飾る作品の枠の上)、壁の家具が底面から reach、床置きの作品が 0 から床の枠の高さ、壁に掛けた作品が底面から上端。
///    床の物どうしはどれも 0 から始まるので、足元が重なれば重なる (壁の家具を足す前と同じ)
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

    // どこに付いているか: 床・壁の家具 (家具と種類)・壁に掛けた作品 (作品と、置いた後の高さ)
    enum Mount<'a> {
        Floor,
        WallFurniture(&'a Furniture, &'static Asset),
        WallArt(&'a ArtworkObject, f64),
    }
    // 部屋の中で場所を取る物 (家具・床置きの作品・壁に掛けた作品): 物・部屋・部屋の中の足元・高さの範囲・ラグか・どこに付いているか。
    // ラグ (floor_decor) はほかと重なってよい
    struct Placed<'a> {
        obj: &'a LayoutObject,
        room: &'static RoomDef,
        rect: Rect,
        span: (f64, f64),
        decor: bool,
        mount: Mount<'a>,
    }
    let mut placed: Vec<Placed> = Vec::new();
    for obj in &layout.objects {
        let (rect, span, decor, mount) = match obj {
            LayoutObject::Furniture(f) => {
                let a = asset(&f.asset_id).ok_or_else(|| format!("家具「{}」はありません", f.asset_id))?;
                let base = if a.is_wall() { f.position[1] } else { 0.0 };
                let mount = if a.is_wall() { Mount::WallFurniture(f, a) } else { Mount::Floor };
                (furniture_rect(f, a), (base, base + a.reach()), a.is_floor_decor(), mount)
            }
            LayoutObject::Artwork(a) if a.on_wall() => {
                let Some(size) = sizes.get(&a.artwork_id).filter(|s| s.frame) else {
                    return Err(format!("{} は壁に掛けられません (壁に掛けられるのは写真の額縁だけです)", label(obj)));
                };
                let height = placed_size(size, WALL_ART_FIT, a.rotation_y)[1];
                let base = a.position[1];
                (art_rect(a, WALL_ART_FIT, sizes), (base, base + height), false, Mount::WallArt(a, height))
            }
            LayoutObject::Artwork(a) if a.parent_id.is_none() => {
                (art_rect(a, FLOOR_ART_FIT, sizes), (0.0, FLOOR_ART_FIT[1]), false, Mount::Floor)
            }
            LayoutObject::Artwork(_) => continue,
        };
        let room = layout.room_of(obj).ok_or_else(|| format!("{} の部屋がありません", label(obj)))?;
        placed.push(Placed { obj, room, rect, span, decor, mount });
    }
    for (i, p) in placed.iter().enumerate() {
        let (obj, room, rect) = (p.obj, p.room, &p.rect);
        match p.mount {
            Mount::WallArt(a, height) => {
                if art_wall_side(a.rotation_y, rect, room).is_none() {
                    return Err(format!("{} は {} の壁に背中を付けて掛けてください", label(obj), room.name));
                }
                if !rect_inside(rect, &room_inner_rect(room)) {
                    return Err(format!("{} が {} の壁からはみ出しています", label(obj), room.name));
                }
                let (lo, hi) = (WALL_MOUNT_MIN, WALL_HEIGHT - height);
                if a.position[1] < lo - TOLERANCE || a.position[1] > hi + TOLERANCE {
                    return Err(format!("{} の高さは {lo:.2}〜{hi:.2} m にしてください", label(obj)));
                }
            }
            Mount::WallFurniture(f, a) => {
                if wall_side(f, room).is_none() {
                    return Err(format!("{} は {} の壁に背中を付けて掛けてください", label(obj), room.name));
                }
                if !rect_inside(rect, &room_inner_rect(room)) {
                    return Err(format!("{} が {} の壁からはみ出しています", label(obj), room.name));
                }
                let (lo, hi) = mount_range(a);
                if f.position[1] < lo - TOLERANCE || f.position[1] > hi + TOLERANCE {
                    return Err(format!("{} の高さは {lo:.2}〜{hi:.2} m にしてください", label(obj)));
                }
            }
            // 模様替えは壁ぎりぎり (12 cm) に寄せた位置を送ってくるので、重なりと同じ 2 mm だけ許す
            // (寸法や三角関数の丸めの違いで、ぴったりの位置がはみ出し扱いにならないように)
            Mount::Floor if !rect_inside(rect, &room_rect(room)) => {
                return Err(format!("{} が {} の壁に近すぎます (壁から 12 cm 空けてください)", label(obj), room.name));
            }
            Mount::Floor => {}
        }
        if doors.applies(obj.id()) && room.doors.iter().any(|door| rect_overlap(&door_zone(room, door), rect)) {
            return Err(format!("{} は {} の出入口の前には置けません", label(obj), room.name));
        }
        if p.decor {
            continue;
        }
        for other in &placed[i + 1..] {
            if other.room.id == room.id && !other.decor && rect_overlap(rect, &other.rect) && span_overlap(p.span, other.span) {
                return Err(format!("{} と {} が重なっています", label(obj), label(other.obj)));
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

/// 部屋のローカル座標 (x, z) を世界座標に: 部屋の origin を足すだけ (部屋は回さない)。y はそのまま (壁の家具の高さ。床の物は 0)
fn room_to_world(room_id: &str, position: [f64; 3]) -> Option<[f64; 3]> {
    let [ox, oz] = room_def(room_id)?.origin;
    Some([ox + position[0], position[1], oz + position[2]])
}

/// 置いた物の世界座標と向き (ラジアン)。作品なら置く面の中心 (家具の上なら面の高さ、床なら 0)。
///
/// - 家具・床置きの作品: 世界 = (部屋の origin.x + x, y, origin.z + z)、向き = rotationY (y は壁の家具の高さ。床の物は 0)
/// - 親 P (世界 (Px, Py, Pz) は上の式、向き θ、面の中心 (ax, h, az)) の上の作品 (x, 0, z) は、x̂ = ax + x、ẑ = az + z として
///   x' = x̂·cosθ + ẑ·sinθ、z' = −x̂·sinθ + ẑ·cosθ、世界 = (Px + x', Py + h, Pz + z')、向き = θ + rotationY
pub fn world_of(layout: &Layout, obj: &LayoutObject) -> Option<([f64; 3], f64)> {
    match obj {
        LayoutObject::Furniture(f) => Some((room_to_world(&f.room_id, f.position)?, f.rotation_y)),
        LayoutObject::Artwork(a) => {
            let Some(parent_id) = &a.parent_id else {
                let world = room_to_world(a.room_id.as_deref().unwrap_or(HUB_ID), a.position)?;
                return Some((world, a.rotation_y));
            };
            let parent = layout.furniture(parent_id)?;
            let [px, py, pz] = room_to_world(&parent.room_id, parent.position)?;
            let [ax, h, az] = asset(&parent.asset_id)?.surface(a.surface.as_deref())?.anchor;
            let (x, z) = (ax + a.position[0], az + a.position[2]);
            let (sin, cos) = parent.rotation_y.sin_cos();
            let world = [px + x * cos + z * sin, py + h, pz - x * sin + z * cos];
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

/// 作品を自動で置く (配置に足す物を返す。いっぱいなら None)。
/// 写真の額縁 (new.frame) は、家具を指定していなければ先に壁に掛ける場所を探し (pick_wall_spot)、
/// 壁がいっぱいなら家具の面に置く。ほかの作品は家具の面だけ (pick_spot)
pub fn pick_place(
    layout: &Layout,
    sizes: &Sizes,
    artwork_id: Uuid,
    new: Option<&ArtSize>,
    prefer_parent: Option<&str>,
) -> Option<LayoutObject> {
    if prefer_parent.is_none()
        && let Some(frame) = new.filter(|n| n.frame)
        && let Some(object) = pick_wall_spot(layout, sizes, artwork_id, frame)
    {
        return Some(object);
    }
    pick_spot(layout, sizes, new, None, prefer_parent).map(|spot| artwork_on(artwork_id, spot))
}

/// 写真の額縁を壁に掛ける場所を探す (リビングの壁)。いっぱいなら None。
///
/// 壁は北・西・東・南の順 (積み上げの建物でも、おへやに入ったはじめの向きでも見える北と西が先)、高さは WALL_ART_CENTERS の段の順、
/// 1 つの壁の中は中央から左右へ、作品の幅 + WALL_ART_GAP ずつ (壁の角から WALL_ART_GAP 空ける)。
/// 置ける (check_placement に通る) うえに、作品の前 (壁から WALL_ART_VIEW) に作品の下端より高い床の家具が無い最初の場所
fn pick_wall_spot(layout: &Layout, sizes: &Sizes, artwork_id: Uuid, frame: &ArtSize) -> Option<LayoutObject> {
    let def = room_def(HUB_ID)?;
    let (hw, hd) = (def.size[0] / 2.0, def.size[1] / 2.0);
    let mut sizes = sizes.clone();
    sizes.insert(artwork_id, *frame);
    // 前をふさぐかを見る床の家具 (ラグは見ない): 足元と高さ
    let blockers: Vec<(Rect, f64)> = layout
        .objects
        .iter()
        .filter_map(|o| match o {
            LayoutObject::Furniture(f) => asset(&f.asset_id)
                .filter(|a| !a.is_wall() && !a.is_floor_decor())
                .map(|a| (furniture_rect(f, a), a.reach())),
            _ => None,
        })
        .collect();

    let walls = [(Side::North, 0.0), (Side::West, FRAC_PI_2), (Side::East, -FRAC_PI_2), (Side::South, PI)];
    for center in WALL_ART_CENTERS {
        for (side, rotation_y) in walls {
            let [w, h, d] = placed_size(frame, WALL_ART_FIT, rotation_y);
            let y = (center - h / 2.0).max(WALL_MOUNT_MIN);
            let length = match side {
                Side::North | Side::South => def.size[0],
                Side::West | Side::East => def.size[1],
            };
            let limit = length / 2.0 - WALL_ART_GAP - w / 2.0;
            let step = w + WALL_ART_GAP;
            // 壁の中央から 0, +1, −1, +2, … 個分
            let offsets = (0..).map(|i: i32| f64::from((i + 1) / 2) * step * if i % 2 == 1 { 1.0 } else { -1.0 });
            for along in offsets.take_while(|o| o.abs() <= limit + 1e-9) {
                let (position, view) = match side {
                    Side::North => ([along, y, -hd + d / 2.0], footprint(along, -hd + WALL_ART_VIEW / 2.0, w, WALL_ART_VIEW, 0.0)),
                    Side::South => ([along, y, hd - d / 2.0], footprint(along, hd - WALL_ART_VIEW / 2.0, w, WALL_ART_VIEW, 0.0)),
                    Side::West => ([-hw + d / 2.0, y, along], footprint(-hw + WALL_ART_VIEW / 2.0, along, WALL_ART_VIEW, w, 0.0)),
                    Side::East => ([hw - d / 2.0, y, along], footprint(hw - WALL_ART_VIEW / 2.0, along, WALL_ART_VIEW, w, 0.0)),
                };
                if blockers.iter().any(|(rect, top)| *top > y + TOLERANCE && rect_overlap(rect, &view)) {
                    continue;
                }
                let object = LayoutObject::Artwork(ArtworkObject {
                    id: new_object_id("art"),
                    artwork_id,
                    parent_id: None,
                    room_id: Some(HUB_ID.to_string()),
                    surface: None,
                    placement: Some(WALL_PLACEMENT.to_string()),
                    position,
                    rotation_y,
                });
                let mut candidate = layout.clone();
                candidate.objects.push(object.clone());
                if check_placement(&candidate, &sizes, DoorPolicy::Ignore).is_ok() {
                    return Some(object);
                }
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

    /// 4 部屋 (v4 まで。hub が hub_size、ほかは size。仕上げは v4 の初期配置と同じ)
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

    /// v5 の rooms (中央のリビング 10 × 10 だけ)
    fn rooms() -> Value {
        json!({ "hub": { "enabled": true, "width": 10, "depth": 10, "wall": "plaster", "floor": "oak" } })
    }

    /// v4 の 4 部屋 (hub 10 × 10、ほかは 8 × 8)
    fn rooms_v4() -> Value {
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

    /// 壁の家具 (y は底面の高さ)
    fn on_wall(id: &str, asset_id: &str, x: f64, y: f64, z: f64, rotation_y: f64) -> Value {
        json!({ "kind": "furniture", "id": id, "assetId": asset_id, "roomId": "hub", "position": [x, y, z], "rotationY": rotation_y })
    }

    const CABINET: &str = "wall_cabinet_french_oak";
    const SHELF: &str = "wall_floating_shelf_french_oak";
    const LEDGE: &str = "wall_picture_ledge_french_oak";

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
        // 部屋は中央のリビングだけ
        let by_room = capacity_by_room(&layout);
        assert_eq!(by_room.len(), 1);
        assert_eq!(by_room["hub"], 17);
        let hub = &layout.rooms.hub;
        assert!(hub.enabled);
        assert_eq!((hub.width, hub.depth, hub.wall.as_str(), hub.floor.as_str()), (10, 10, "plaster", "oak"));
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
        assert_eq!((layout.rooms.hub.width, layout.rooms.hub.depth), (10, 10));
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
                furniture("desk", "home_craft_desk", 0.0, 3.4, PI),
                on_top("art-1", ART_A, "desk", 0.1, 0.0, 0.0),
                on_floor("hub", "art-2", ART_B, 3.3, -3.3),
                on_floor("hub", "art-3", ART_C, 0.0, 0.0),
            ],
        });
        let layout = validate_layout(raw.clone()).unwrap();
        let LayoutObject::Furniture(desk) = &layout.objects[0] else { panic!() };
        assert_eq!(desk.position, [0.0, 0.0, 4.4]);
        let LayoutObject::Artwork(on_desk) = &layout.objects[1] else { panic!() };
        assert_eq!(on_desk.position, [0.1, 0.0, 0.0]);
        let LayoutObject::Artwork(corner) = &layout.objects[2] else { panic!() };
        assert_eq!(corner.position, [4.3, 0.0, -4.3]);
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
    fn house_has_no_doorways() {
        // 今の家 (リビングだけ) には出入口が無いので、新しく置く物・動かした物でも出入口の判定に掛からない
        let layout = default_layout();
        assert!(ROOM_DEFS.iter().all(|d| d.doors.is_empty()));
        assert!(door_blockers(&layout).is_empty());
        // v3 のころの初期配置で出入口の前にあった家具 (ソファ・飾り棚・サイドボード・白い台座) も、今はかからない
        let layout = validate_layout(v3_default_layout()).unwrap();
        assert!(door_blockers(&layout).is_empty(), "{:?}", door_blockers(&layout));
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
        // リビングは 10 × 10 になり、壁紙・床材はそのまま。左・右・前の部屋 (仮の部屋) は無くなる
        assert_eq!((layout.rooms.hub.width, layout.rooms.hub.depth), (10, 10));
        assert_eq!(layout.rooms.hub.wall, "plaster");
        // 物はそのまま (すべて hub。壁から離れているので動かない)。roomId を省いた床の作品は hub
        let ids: Vec<&str> = layout.objects.iter().map(LayoutObject::id).collect();
        assert_eq!(ids, vec!["console", "art-1", "art-2"]);
        assert!(layout.objects.iter().all(|o| layout.room_of(o).unwrap().id == "hub"));
        let value = serde_json::to_value(&layout).unwrap();
        assert_eq!(value["schemaVersion"], SCHEMA_VERSION);
        assert_eq!(value["rooms"].as_object().unwrap().len(), 1);
        assert_eq!(value["objects"][2]["roomId"], "hub");
        // 保存し直した v5 も同じ配置として読める
        assert_eq!(validate_layout(value).unwrap(), layout);
    }

    #[test]
    fn rejects_resized_rooms_and_unknown_room_ids() {
        // リビングの大きさは版ごとに決まっている (v4・v5 は 10 × 10、v3 は 8 × 8)
        for (version, base) in [(5, rooms()), (4, rooms_v4()), (3, rooms_v3())] {
            for key in ["width", "depth"] {
                let mut room = base.clone();
                room["hub"][key] = json!(9);
                let err = validate_layout(json!({ "schemaVersion": version, "rooms": room, "objects": [] })).unwrap_err();
                assert!(err.contains("部屋の大きさは変えられません"), "v{version} {key}: {err}");
            }
        }
        // 版が 6 以上なら読まない
        assert!(validate_layout(json!({ "schemaVersion": 6, "rooms": rooms(), "objects": [] })).is_err());
        // v5 の rooms は hub だけ (左・右・前の部屋は無い)
        let err = validate_layout(json!({ "schemaVersion": 5, "rooms": rooms_v4(), "objects": [] })).unwrap_err();
        assert!(err.contains("部屋「"), "{err}");
        // 家具・床置きの作品の roomId は hub だけ
        for room in ["attic", "left", "front"] {
            let err = layout_of(json!([furniture_in(room, "f", "home_stool", 0.0, 0.0, 0.0)])).unwrap_err();
            assert!(err.contains(room), "{err}");
        }
        let err = layout_of(json!([on_floor("right", "art-1", ART_A, 0.0, 0.0)])).unwrap_err();
        assert!(err.contains("right"), "{err}");
        let mut no_room = furniture("f", "home_stool", 0.0, 0.0, 0.0);
        no_room.as_object_mut().unwrap().remove("roomId");
        assert!(layout_of(json!([no_room])).is_err());
        // 家具の上の作品の roomId は使わない (親の家具の部屋)
        let layout = layout_of(json!([
            furniture("stool", "home_stool", 0.0, 0.0, 0.0),
            { "kind": "artwork", "id": "art-1", "artworkId": ART_A, "parentId": "stool", "roomId": "front", "position": [0, 0, 0], "rotationY": 0 },
        ]))
        .unwrap();
        let LayoutObject::Artwork(a) = &layout.objects[1] else { panic!() };
        assert_eq!(a.room_id, None);
        assert_eq!(layout.room_of(&layout.objects[1]).unwrap().id, "hub");
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
        assert!(layout.rooms.hub.enabled);
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
    fn v4_layout_drops_the_removed_rooms() {
        // v4 (4 部屋) の配置を読むと、左・右・前の部屋の家具・床の作品と、その家具の上の作品を外す。hub の物はそのまま
        let raw = json!({
            "schemaVersion": 4,
            "kitVersion": KIT_VERSION,
            "rooms": rooms_v4(),
            "objects": [
                furniture("console", "home_console", 0.0, 2.0, 0.0),
                on_top("art-1", ART_A, "console", 0.0, 0.0, 0.0),
                furniture_in("left", "left-slim", "plinth_slim", 1.0, 1.0, 0.0),
                on_top("art-2", ART_B, "left-slim", 0.0, 0.0, 0.0),
                on_floor("front", "art-3", ART_C, 0.0, 0.0),
                on_floor("hub", "art-4", "00000000-0000-4000-8000-00000000000d", -2.0, -2.0),
            ],
        });
        let layout = validate_layout(raw.clone()).unwrap();
        assert_eq!(layout.schema_version, SCHEMA_VERSION);
        let ids: Vec<&str> = layout.objects.iter().map(LayoutObject::id).collect();
        assert_eq!(ids, vec!["console", "art-1", "art-4"]);
        // リビングの壁紙・床材はそのまま。v4 の hub は 10 × 10 なので物は動かない
        assert_eq!(layout.rooms.hub.wall, "plaster");
        let LayoutObject::Furniture(console) = &layout.objects[0] else { panic!() };
        assert_eq!(console.position, [0.0, 0.0, 2.0]);
        // 直すとき (repair_layout) も同じように外す
        let (repaired, dropped) = repair_layout(raw, &Sizes::new()).unwrap();
        assert!(dropped.is_empty());
        assert_eq!(repaired, layout);
    }

    #[test]
    fn floor_artworks_collide_with_furniture() {
        // 床置きの作品も家具と重ならない
        let err = layout_of(json!([
            furniture("a", "plinth_ivory", 1.0, 1.0, 0.0),
            on_floor("hub", "art-1", ART_A, 1.2, 1.0),
        ]))
        .unwrap_err();
        assert!(err.contains("重なって"), "{err}");
        // ラグは重なってよい
        assert!(layout_of(json!([
            furniture("rug", "home_rug", 0.0, 0.0, 0.0),
            furniture("table", "home_coffee_table", 0.0, 0.0, 0.0),
            on_floor("hub", "art-1", ART_A, 1.6, 0.5),
        ]))
        .is_ok());
    }

    /// 出入口のある部屋 (今の家には出入口が無いので、テストのためだけに作る。以前の hub と同じ 10 × 10・西・東・北)
    static DOOR_ROOM: RoomDef = RoomDef {
        id: "door-room",
        name: "出入口のある部屋",
        origin: [0.0, 0.0],
        size: [10.0, 10.0],
        model: "",
        doors: &[portal(Side::West), portal(Side::East), portal(Side::North)],
        cutaway: &[],
    };

    #[test]
    fn door_zones_follow_the_doors() {
        let zones: Vec<Rect> = DOOR_ROOM.doors.iter().map(|d| door_zone(&DOOR_ROOM, d)).collect();
        assert_eq!(zones.len(), 3);
        // 西・東・北 (キットと同じ: 幅 2.54、壁から 1.15)
        assert_rect(zones[0], [-5.0, -3.85, -1.27, 1.27]);
        assert_rect(zones[1], [3.85, 5.0, -1.27, 1.27]);
        assert_rect(zones[2], [-1.27, 1.27, -5.0, -3.85]);
        // 南の出入口と、壁の中心からずらした出入口
        let small = RoomDef { size: [8.0, 8.0], doors: &[], ..DOOR_ROOM };
        assert_rect(door_zone(&small, &portal(Side::South)), [-1.27, 1.27, 2.85, 4.0]);
        let offset = Door { offset: 1.0, ..portal(Side::North) };
        assert_rect(door_zone(&small, &offset), [-0.27, 2.27, -4.0, -2.85]);
    }

    #[test]
    fn moved_ids_finds_moved_and_new_objects() {
        let stored = layout_of(json!([
            furniture("console", "home_console", 3.7, 1.55, -FRAC_PI_2),
            furniture("sofa", "home_sofa", 0.0, 2.5, 0.0),
        ]))
        .unwrap();
        assert!(moved_ids(&stored, &stored).is_empty());
        // 動かした物だけ
        let mut after = stored.clone();
        let LayoutObject::Furniture(sofa) = &mut after.objects[1] else { panic!() };
        sofa.position[0] = 0.5;
        assert_eq!(moved_ids(&stored, &after), HashSet::from(["sofa".to_string()]));
        // 回すだけでも動かした扱い。2π 回したのは同じ向き
        let turn = |after: &mut Layout, rotation_y: f64| {
            let LayoutObject::Furniture(console) = &mut after.objects[0] else { panic!() };
            console.rotation_y = rotation_y;
        };
        let mut after = stored.clone();
        turn(&mut after, wrap_angle(-FRAC_PI_2 + TAU));
        assert!(moved_ids(&stored, &after).is_empty());
        turn(&mut after, FRAC_PI_2);
        assert_eq!(moved_ids(&stored, &after), HashSet::from(["console".to_string()]));
        // 新しく置いた物も入る。出入口が無いので、どこに置いても出入口の判定には掛からない
        let mut raw = serde_json::to_value(&stored).unwrap();
        raw["objects"].as_array_mut().unwrap().push(furniture("stool", "home_stool", 4.3, 0.0, 0.0));
        let after = parse_layout(raw).unwrap();
        let moved = moved_ids(&stored, &after);
        assert_eq!(moved, HashSet::from(["stool".to_string()]));
        assert!(check_placement(&after, &Sizes::new(), DoorPolicy::OnlyMoved(&moved)).is_ok());
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
    fn wall_furniture_hangs_on_a_wall() {
        // 4 つの壁の向きと位置。背面を壁の内側の面 (±5.0) に付ける
        for (x, z, rotation) in [(0.0, -5.0, 0.0), (0.0, 5.0, PI), (-5.0, 0.0, FRAC_PI_2), (5.0, 0.0, -FRAC_PI_2)] {
            assert!(layout_of(json!([on_wall("s", SHELF, x, 1.5, z, rotation)])).is_ok(), "{x} {z} {rotation}");
        }
        let side = |x: f64, z: f64, r: f64| {
            let layout = layout_of(json!([on_wall("s", SHELF, x, 1.5, z, r)])).unwrap();
            let LayoutObject::Furniture(f) = &layout.objects[0] else { unreachable!() };
            wall_side(f, &ROOM_DEFS[0])
        };
        assert_eq!(side(0.0, -5.0, 0.0), Some(Side::North));
        assert_eq!(side(5.0, 0.0, -FRAC_PI_2), Some(Side::East));
        // 壁から離れている・向きが壁に合っていない・45°
        let err = layout_of(json!([on_wall("s", SHELF, 0.0, 1.5, -4.5, 0.0)])).unwrap_err();
        assert!(err.contains("壁に背中を付けて"), "{err}");
        assert!(layout_of(json!([on_wall("s", SHELF, 0.0, 1.5, -5.0, PI)])).is_err());
        assert!(layout_of(json!([on_wall("s", SHELF, 0.0, 1.5, -5.0, FRAC_PI_4)])).is_err());
        // 2 mm のずれは許す
        assert!(layout_of(json!([on_wall("s", SHELF, 0.0, 1.5, -4.999, 0.0)])).is_ok());
        // 角から横にはみ出す (幅 1.3 なので x は ±4.35 まで)
        assert!(layout_of(json!([on_wall("s", SHELF, 4.35, 1.5, -5.0, 0.0)])).is_ok());
        let err = layout_of(json!([on_wall("s", SHELF, 4.5, 1.5, -5.0, 0.0)])).unwrap_err();
        assert!(err.contains("はみ出して"), "{err}");
    }

    #[test]
    fn wall_furniture_height_range() {
        // 飾り棚: 上に作品の枠 (0.61) を足して 0.706。0.3〜3.494 m に掛けられる
        let shelf = asset(SHELF).unwrap();
        let (lo, hi) = mount_range(shelf);
        assert!(close(lo, WALL_MOUNT_MIN) && close(hi, WALL_HEIGHT - 0.096 - 0.61), "{lo} {hi}");
        assert!(layout_of(json!([on_wall("s", SHELF, 0.0, lo, -5.0, 0.0)])).is_ok());
        assert!(layout_of(json!([on_wall("s", SHELF, 0.0, hi, -5.0, 0.0)])).is_ok());
        let err = layout_of(json!([on_wall("s", SHELF, 0.0, 0.2, -5.0, 0.0)])).unwrap_err();
        assert!(err.contains("高さは 0.30〜3.49 m"), "{err}");
        assert!(layout_of(json!([on_wall("s", SHELF, 0.0, 3.6, -5.0, 0.0)])).is_err());
        // キャビネットは天板の作品の枠 (0.46) まで含めて 1.32。上は 2.88 m まで
        let (_, hi) = mount_range(asset(CABINET).unwrap());
        assert!(close(hi, WALL_HEIGHT - 0.86 - 0.46), "{hi}");
    }

    #[test]
    fn wall_furniture_overlaps_by_height() {
        // ソファ (高さ 0.985) を北の壁ぎわに。ピクチャーレッジは 1.0 m より上なら掛けられる
        let sofa_z = -5.0 + WALL_MARGIN + 0.45;
        let sofa = furniture("sofa", "home_sofa", 0.0, sofa_z, 0.0);
        assert!(layout_of(json!([sofa, on_wall("l", LEDGE, 0.0, 1.2, -5.0, 0.0)])).is_ok());
        let err = layout_of(json!([sofa, on_wall("l", LEDGE, 0.0, 0.8, -5.0, 0.0)])).unwrap_err();
        assert!(err.contains("重なっています"), "{err}");
        // サイドボード (0.891) の上は、天板の作品の枠 (0.62) の上 = 1.511 m から
        let console_z = -5.0 + WALL_MARGIN + 0.255;
        let console = furniture("c", "home_console", 0.0, console_z, 0.0);
        assert!(layout_of(json!([console, on_wall("l", LEDGE, 0.0, 1.2, -5.0, 0.0)])).is_err());
        assert!(layout_of(json!([console, on_wall("l", LEDGE, 0.0, 1.52, -5.0, 0.0)])).is_ok());
        // 壁の家具どうし: 同じ高さで横に重なれば不可、上下に離れていれば同じ所に掛けられる
        assert!(layout_of(json!([on_wall("a", SHELF, 0.0, 1.0, -5.0, 0.0), on_wall("b", SHELF, 0.5, 1.0, -5.0, 0.0)])).is_err());
        assert!(layout_of(json!([on_wall("a", SHELF, 0.0, 0.5, -5.0, 0.0), on_wall("b", SHELF, 0.0, 1.3, -5.0, 0.0)])).is_ok());
        // 別の壁なら同じ x でも重ならない (足元が違う)
        assert!(layout_of(json!([on_wall("a", SHELF, 0.0, 1.0, -5.0, 0.0), on_wall("b", SHELF, 0.0, 1.0, 5.0, PI)])).is_ok());
    }

    #[test]
    fn wall_furniture_footprint_and_world() {
        // 北の壁の飾り棚: 原点は背面なので、足元は z −5.0〜−4.74
        let layout = layout_of(json!([
            on_wall("s", SHELF, 1.0, 1.5, -5.0, 0.0),
            on_top("art-1", ART_A, "s", 0.2, 0.0, 0.0),
            on_wall("e", SHELF, 5.0, 1.0, 0.0, -FRAC_PI_2),
        ]))
        .unwrap();
        let LayoutObject::Furniture(f) = &layout.objects[0] else { unreachable!() };
        assert_rect(furniture_rect(f, asset(SHELF).unwrap()), [0.35, 1.65, -5.0, -4.74]);
        let LayoutObject::Furniture(e) = &layout.objects[2] else { unreachable!() };
        assert_rect(furniture_rect(e, asset(SHELF).unwrap()), [4.74, 5.0, -0.65, 0.65]);
        // 家具の世界座標は高さつき。上の作品は 1.5 + 面の高さ 0.096、面の中心は背面から 0.13 手前
        let (pos, _) = world_of(&layout, &layout.objects[0]).unwrap();
        assert_eq!(pos, [1.0, 1.5, -5.0]);
        let (pos, _) = world_of(&layout, &layout.objects[1]).unwrap();
        assert!(close(pos[0], 1.2) && close(pos[1], 1.596) && close(pos[2], -4.87), "{pos:?}");
    }

    #[test]
    fn heights_are_kept_only_for_wall_furniture() {
        let layout = layout_of(json!([
            { "kind": "furniture", "id": "sofa", "assetId": "home_sofa", "roomId": "hub", "position": [0, 0.7, 0], "rotationY": 0 },
            on_wall("s", SHELF, 0.0, 1.5, -5.0, 0.0),
            { "kind": "artwork", "id": "art-1", "artworkId": ART_A, "roomId": "hub", "position": [3.0, 0.4, 3.0], "rotationY": 0 },
        ]))
        .unwrap();
        let ys: Vec<f64> = layout
            .objects
            .iter()
            .map(|o| match o {
                LayoutObject::Furniture(f) => f.position[1],
                LayoutObject::Artwork(a) => a.position[1],
            })
            .collect();
        assert_eq!(ys, vec![0.0, 1.5, 0.0]);
        // 上げ下げしただけでも、動かした物になる (出入口の前の判定のため)
        let mut raised = layout.clone();
        let LayoutObject::Furniture(f) = &mut raised.objects[1] else { unreachable!() };
        f.position[1] = 1.6;
        assert_eq!(moved_ids(&layout, &raised), HashSet::from(["s".to_string()]));
    }

    #[test]
    fn auto_placement_uses_wall_shelves_last() {
        // サイドボードと飾り棚があれば、まずサイドボード。サイドボードが埋まったら飾り棚へ
        let layout = layout_of(json!([furniture("c", "home_console", 0.0, 2.0, 0.0), on_wall("s", SHELF, 0.0, 1.5, -5.0, 0.0)])).unwrap();
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, None).unwrap().parent_id, "c");
        let shelf_only = layout_of(json!([on_wall("s", SHELF, 0.0, 1.5, -5.0, 0.0)])).unwrap();
        let spot = pick_spot(&shelf_only, &Sizes::new(), None, None, None).unwrap();
        assert_eq!(spot.parent_id, "s");
        // 飾り棚 2・ピクチャーレッジ 2・キャビネット 1
        let three = layout_of(json!([
            on_wall("s", SHELF, 0.0, 1.5, -5.0, 0.0),
            on_wall("l", LEDGE, 0.0, 1.2, 5.0, PI),
            on_wall("c", CABINET, -5.0, 1.3, 0.0, FRAC_PI_2),
        ]))
        .unwrap();
        assert_eq!(capacity(&three), 5);
    }

    #[test]
    fn world_of_adds_room_origin() {
        let layout = layout_of(json!([
            furniture("desk", "home_craft_desk", 1.0, 2.0, 0.0),
            on_top("art-1", ART_A, "desk", 0.1, 0.0, 0.0),
            on_floor("hub", "art-2", ART_B, 0.0, 1.0),
            furniture("console", "home_console", -3.0, -1.0, -FRAC_PI_2),
            on_top("art-3", ART_C, "console", 0.5, 0.0, 0.0),
        ]))
        .unwrap();
        let world = |i: usize| world_of(&layout, &layout.objects[i]).unwrap();
        let near = |p: [f64; 3], want: [f64; 3]| p.iter().zip(want).all(|(a, b)| close(*a, b));
        // リビングの中心は世界の原点なので、家具 (1, 0, 2) は世界でも (1, 0, 2)
        let (pos, yaw) = world(0);
        assert!(near(pos, [1.0, 0.0, 2.0]) && yaw == 0.0, "{pos:?}");
        // その上の作品 = 家具の世界座標 + 面の中心 + 作品の位置 (工作机の天板の高さ 0.795)
        let (pos, _) = world(1);
        assert!(near(pos, [1.1, 0.795, 2.0]), "{pos:?}");
        // 床の作品 (0, 0, 1)
        let (pos, _) = world(2);
        assert!(near(pos, [0.0, 0.0, 1.0]), "{pos:?}");
        // -90° 回したサイドボードの上の作品: 家具の世界座標 (−3, 0, −1) + 回した (0.5, 0) = (0, 0.5)
        let (pos, yaw) = world(4);
        assert!(near(pos, [-3.0, 0.891, -0.5]), "{pos:?}");
        assert!(close(yaw_degrees(yaw), -90.0));
        // 作品の部屋は親の家具の部屋
        assert_eq!(layout.room_of(&layout.objects[1]).unwrap().id, "hub");
        assert_eq!(layout.room_of_id("art-2").unwrap().name, "中央のリビング");
    }

    #[test]
    fn pick_spot_fills_the_room_and_fails_when_full() {
        // 飾り棚 (2 か所)・細い台座 (1 か所)
        let mut layout = layout_of(json!([
            furniture("slim", "plinth_slim", 2.0, 0.0, 0.0),
            furniture("shelf", "home_display_shelf", 0.0, 0.0, 0.0),
        ]))
        .unwrap();
        assert_eq!(capacity_by_room(&layout)["hub"], 3);
        assert_eq!(capacity(&layout), 3);
        // 飾り棚が先 (SUPPORT_ORDER)。hub を指定しても同じ
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, None, None).unwrap().parent_id, "shelf");
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, Some("hub"), None).unwrap().parent_id, "shelf");
        // 無い部屋を指定すると None
        assert_eq!(pick_spot(&layout, &Sizes::new(), None, Some("left"), None), None);
        for i in 0..3 {
            let spot = pick_spot(&layout, &Sizes::new(), None, None, None).unwrap();
            layout.objects.push(artwork_on(Uuid::from_u128(i + 1), spot));
        }
        let layout = validate_layout(serde_json::to_value(&layout).unwrap()).unwrap();
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
        // 出入口が無いので、出入口の前にかかる家具も無い
        assert!(door_blockers(&layout).is_empty());
        check_placement(&layout, &Sizes::new(), DoorPolicy::OnlyMoved(&moved_ids(&layout, &layout))).unwrap();

        // アトリエの 33 点の実寸でも通り、どれも 1 倍以下で置かれる
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
    fn catalog_has_seventeen_furniture_with_japanese_names() {
        assert_eq!(CATALOG.assets.len(), 17);
        assert!(CATALOG.assets.iter().all(|a| a.category == "furniture" && !a.name_ja.is_empty()));
        assert_eq!(CATALOG.assets.iter().filter(|a| a.is_support()).count(), 13);
        // 壁の家具は 3 つ。どれも高さを決めてあり、掛けられる高さの範囲に入っている。床の家具には高さが無い
        let walls: Vec<&Asset> = CATALOG.assets.iter().filter(|a| a.is_wall()).collect();
        assert_eq!(walls.len(), 3);
        for a in &walls {
            let (lo, hi) = mount_range(a);
            let h = a.mount_height.unwrap();
            assert!(lo <= h && h <= hi, "{}: {h} は {lo}〜{hi} の外", a.id);
        }
        assert!(CATALOG.assets.iter().filter(|a| !a.is_wall()).all(|a| a.placement == "floor" && a.mount_height.is_none()));
        // 作品を自動で置くときに、どの面のある家具も探す
        assert!(CATALOG.assets.iter().filter(|a| a.is_support()).all(|a| SUPPORT_ORDER.contains(&a.id.as_str())));
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
    fn finish_pack_wall_and_floor_round_trip() {
        // 内装セットの壁紙・床材を保存して読み直せる (物はそのまま)
        let theme = |wall: &str, floor: &str| {
            let mut raw = raw_layout(json!([furniture("sofa", "home_sofa", 0.0, 2.0, 0.0)]));
            raw["rooms"]["hub"]["wall"] = json!(wall);
            raw["rooms"]["hub"]["floor"] = json!(floor);
            raw
        };
        for (wall, floor) in FINISH_PACK_WALLS.iter().zip(&FINISH_PACK_FLOORS) {
            let layout = validate_layout(theme(wall, floor)).unwrap_or_else(|e| panic!("{wall} / {floor}: {e}"));
            let hub = &layout.rooms.hub;
            assert_eq!((hub.wall.as_str(), hub.floor.as_str()), (*wall, *floor));
            assert_eq!(layout.objects.len(), 1);
            let again = validate_layout(serde_json::to_value(&layout).unwrap()).unwrap();
            assert_eq!(again, layout);
        }
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

    /// アトリエの 33 点の寸法 (幅・高さ・奥行き)。static/atelier/catalog.json の dimensionsMeters を mm に丸めた値
    /// (GLB を測った値とも 1 mm 以内: glb::tests::measures_atelier_models_like_the_kit_catalog)
    const ATELIER: [(&str, [f64; 3]); 33] = [
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
        ("19_cardboard_puppet_theatre", [0.49, 0.521, 0.363]),
        ("20_patchwork_hot_air_balloon", [0.36, 0.554, 0.3]),
        ("21_craft_stick_biplane", [0.49, 0.212, 0.44]),
        ("22_milk_carton_lighthouse", [0.389, 0.544, 0.323]),
        ("23_tissue_lava_volcano", [0.428, 0.437, 0.371]),
        ("24_cardboard_treasure_chest", [0.41, 0.325, 0.34]),
        ("25_egg_carton_crocodile", [0.57, 0.136, 0.3]),
        ("26_paper_bowl_jellyfish", [0.45, 0.559, 0.405]),
        ("27_paper_plate_lion", [0.46, 0.431, 0.31]),
        ("28_clay_hedgehog_hideout", [0.458, 0.241, 0.392]),
        ("29_cardboard_submarine", [0.63, 0.403, 0.34]),
        ("30_origami_crane_wetland", [0.54, 0.295, 0.365]),
        ("31_toadstool_cottage", [0.501, 0.45, 0.378]),
        ("32_clay_sea_turtle", [0.495, 0.132, 0.442]),
        ("33_recycled_drum_kit", [0.564, 0.317, 0.412]),
        ("34_paper_horn_gramophone", [0.403, 0.476, 0.341]),
        ("35_woven_picnic_basket", [0.393, 0.316, 0.311]),
        ("36_folded_paper_peacock", [0.499, 0.418, 0.321]),
        ("37_craft_stick_bridge", [0.714, 0.289, 0.397]),
        ("38_cardboard_excavator", [0.688, 0.36, 0.368]),
    ];

    fn seed_id(asset_id: &str) -> Uuid {
        crate::seed::seed_id(asset_id)
    }

    /// アトリエの 33 点の寸法 (作品 id は seed と同じ)
    fn atelier_sizes() -> Sizes {
        ATELIER.iter().map(|(asset_id, size)| (seed_id(asset_id), ArtSize { size: *size, custom: true, frame: false })).collect()
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
        let boat = ArtSize { size: [0.56, 0.582, 0.34], custom: true, frame: false };
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
        // 写真の額縁 (800 × 600 は横長の額縁。幅 0.348 m) は custom でないので、枠いっぱいまで大きくする
        // (サイドボードでは幅で決まり 0.56 / 0.348 ≈ 1.609)
        let frame = generated_frame();
        let scale = display_scale(&frame, fit, 0.0);
        assert!(close(scale, 0.56 / frame.size[0]) && (scale - 1.609).abs() < 1e-3, "{scale}");
        // custom でない小さな作品は枠まで大きくする (1 倍の上限なし)。custom は 1 倍まで
        let small = ArtSize { size: [0.1, 0.1, 0.1], custom: false, frame: false };
        assert!(close(display_scale(&small, fit, 0.0), 4.8));
        assert!(close(display_scale(&ArtSize { custom: true, ..small }, fit, 0.0), 1.0));
    }

    #[test]
    fn art_size_from_model_needs_all_three() {
        let size = ArtSize::from_model(Some(0.5), Some(0.4), Some(0.3), "custom").unwrap();
        assert_eq!(size, ArtSize { size: [0.5, 0.4, 0.3], custom: true, frame: false });
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

    /// 表の作品: 名前・作品 id・寸法 (None は寸法なし)。アトリエの 33 点、仮生成の額縁、寸法の分からない作品
    #[test]
    fn frames_hang_on_the_north_wall_first() {
        let layout = parse_layout(raw_layout(json!([]))).unwrap();
        let frame = generated_frame();
        let id = Uuid::from_u128(7);
        let Some(LayoutObject::Artwork(a)) = pick_place(&layout, &Sizes::new(), id, Some(&frame), None) else {
            panic!("壁に掛ける場所がありません");
        };
        assert!(a.on_wall() && a.parent_id.is_none() && a.rotation_y == 0.0);
        // 北の壁の中央。背面を壁 (z = −5) に付け、中心を 1.6 m に
        let [_, h, d] = placed_size(&frame, WALL_ART_FIT, 0.0);
        assert!(close(a.position[0], 0.0) && close(a.position[2], -5.0 + d / 2.0), "{:?}", a.position);
        assert!(close(a.position[1] + h / 2.0, 1.6), "{:?}", a.position);
        // 2 つ目は同じ壁の右隣 (作品の幅 0.9 + 間 0.3)
        let mut layout = layout;
        layout.objects.push(LayoutObject::Artwork(a));
        let sizes = Sizes::from([(id, frame)]);
        let Some(LayoutObject::Artwork(b)) = pick_place(&layout, &sizes, Uuid::from_u128(8), Some(&frame), None) else {
            panic!("2 つ目を掛ける場所がありません");
        };
        assert!(close(b.position[0], 1.2) && b.rotation_y == 0.0, "{:?}", b.position);
    }

    #[test]
    fn frames_skip_walls_behind_tall_furniture() {
        // 北の壁の中央の前に本棚 (高さ 1.82) があると、その前 (|x| < 本棚の半分 + 作品の半分) には掛けない。
        // 低いサイドボード (0.891 + 作品の枠) は作品の下端 (約 1.28 m) より低いので、その上には掛ける
        let shelf = parse_layout(raw_layout(json!([furniture("b", "home_bookshelf", 0.0, -5.0 + WALL_MARGIN + 0.205, 0.0)]))).unwrap();
        let frame = generated_frame();
        let Some(LayoutObject::Artwork(a)) = pick_place(&shelf, &Sizes::new(), Uuid::from_u128(7), Some(&frame), None) else {
            panic!("壁に掛ける場所がありません");
        };
        assert!(a.position[0].abs() >= 0.58 + 0.45 - 1e-9 || a.rotation_y != 0.0, "{:?}", a.position);
    }

    #[test]
    fn only_frames_hang_on_walls() {
        let layout = parse_layout(raw_layout(json!([furniture("c", "home_console", 0.0, 0.0, 0.0)]))).unwrap();
        // 工作 (実寸の GLB) は家具の上
        let boat = ArtSize { size: [0.56, 0.582, 0.34], custom: true, frame: false };
        let placed = pick_place(&layout, &Sizes::new(), Uuid::from_u128(7), Some(&boat), None);
        assert!(matches!(placed, Some(LayoutObject::Artwork(ref a)) if a.parent_id.as_deref() == Some("c")), "{placed:?}");
        // 家具を指定すれば、額縁も家具の上
        let placed = pick_place(&layout, &Sizes::new(), Uuid::from_u128(7), Some(&generated_frame()), Some("c"));
        assert!(matches!(placed, Some(LayoutObject::Artwork(ref a)) if a.parent_id.as_deref() == Some("c")), "{placed:?}");
        // 家具に載せた作品は壁に掛けられない (placement は床の作品だけ)
        let mut raw = raw_layout(json!([furniture("c", "home_console", 0.0, 0.0, 0.0)]));
        raw["objects"].as_array_mut().unwrap().push(json!({
            "kind": "artwork", "id": "a", "artworkId": Uuid::from_u128(7), "parentId": "c", "placement": "wall",
            "position": [0.0, 0.0, 0.0], "rotationY": 0.0,
        }));
        assert!(parse_layout(raw).unwrap_err().contains("placement"));
    }

    #[test]
    fn wall_art_keeps_its_height_and_round_trips() {
        let frame = generated_frame();
        let mut raw = raw_layout(json!([]));
        raw["objects"].as_array_mut().unwrap().push(json!({
            "kind": "artwork", "id": "a", "artworkId": Uuid::from_u128(7), "roomId": "hub", "placement": "wall",
            "position": [0.0, 1.3, -5.0 + 0.0285], "rotationY": 0.0,
        }));
        let layout = parse_layout(raw).unwrap();
        let LayoutObject::Artwork(a) = &layout.objects[0] else { panic!() };
        assert_eq!(a.position[1], 1.3);
        // 世界座標の y も底面の高さ。保存し直しても placement は残る
        assert_eq!(world_of(&layout, &layout.objects[0]).unwrap().0[1], 1.3);
        let again = parse_layout(serde_json::to_value(&layout).unwrap()).unwrap();
        assert_eq!(again, layout);
        // 寸法 (額縁かどうか) が分からなければ検証に通らない
        assert!(check_placement(&layout, &Sizes::new(), DoorPolicy::Ignore).is_err());
        let [_, _, d] = placed_size(&frame, WALL_ART_FIT, 0.0);
        let mut fixed = layout.clone();
        if let LayoutObject::Artwork(a) = &mut fixed.objects[0] {
            a.position[2] = -5.0 + d / 2.0;
        }
        check_placement(&fixed, &Sizes::from([(Uuid::from_u128(7), frame)]), DoorPolicy::Ignore).unwrap();
        // 上げ下げも「動かした」
        let mut raised = fixed.clone();
        if let LayoutObject::Artwork(a) = &mut raised.objects[0] {
            a.position[1] = 1.5;
        }
        assert_eq!(moved_ids(&fixed, &raised), HashSet::from(["a".to_string()]));
    }

    /// 写真 (800 × 600) から作った額縁の作品の実寸 (glb.rs のオークの額縁。登録のときと同じく GLB を測る)
    fn generated_frame() -> ArtSize {
        let glb = crate::glb::build_artwork_glb(&[0xFF, 0xD8, 0xFF, 0xD9], 800, 600, crate::glb::Style::Frame);
        let [w, h, d] = crate::glb::measure_glb(&glb).unwrap();
        ArtSize::from_model(Some(w), Some(h), Some(d), "frame").unwrap()
    }

    fn case_arts() -> Vec<(String, Uuid, Option<ArtSize>)> {
        let mut arts: Vec<_> = ATELIER
            .iter()
            .map(|(asset_id, size)| (asset_id.to_string(), seed_id(asset_id), Some(ArtSize { size: *size, custom: true, frame: false })))
            .collect();
        let fixed = |s: &str| Uuid::parse_str(s).unwrap();
        arts.push(("frame_800x600".into(), fixed("00000000-0000-4000-8000-000000000800"), Some(generated_frame())));
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
        // 壁の家具は北・西・東の壁に掛ける (底面の高さ・向きつき)
        let walls = [
            (CABINET, -3.0, 1.3, -5.0, 0.0),
            (SHELF, -5.0, 1.5, -1.0, FRAC_PI_2),
            (LEDGE, 5.0, 1.2, 1.0, -FRAC_PI_2),
        ];
        assert_eq!(at.len() + walls.len(), CATALOG.assets.iter().filter(|a| a.is_support()).count());
        let mut objects: Vec<Value> =
            at.iter().map(|(asset_id, x, z)| furniture(&format!("f-{asset_id}"), asset_id, *x, *z, 0.0)).collect();
        objects.extend(walls.iter().map(|(asset_id, x, y, z, r)| on_wall(&format!("f-{asset_id}"), asset_id, *x, *y, *z, *r)));
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
        let raw = raw_layout(json!([furniture("f-hub", "plinth_ivory", x, z, 0.0)]));
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

    /// 壁に掛ける作品の配置 JSON (リビング。position の y は底面の高さ)
    fn wall_art(id: &str, artwork: Uuid, x: f64, y: f64, z: f64, rotation: f64) -> Value {
        json!({
            "kind": "artwork", "id": id, "artworkId": artwork, "roomId": HUB_ID, "placement": WALL_PLACEMENT,
            "position": [x, y, z], "rotationY": rotation,
        })
    }

    /// layout に objects を足した配置が検証に通るか。moved なら id "cand" の物だけ出入口の前を見る (保存済みの物は見ない)
    fn fits(layout: &Value, objects: &[Value], sizes: &Sizes, moved: bool) -> bool {
        let mut raw = layout.clone();
        raw["objects"].as_array_mut().unwrap().extend(objects.iter().cloned());
        let candidate: HashSet<String> = moved.then(|| CANDIDATE_ID.to_string()).into_iter().collect();
        check_placement(&parse_layout(raw).unwrap(), sizes, DoorPolicy::OnlyMoved(&candidate)).is_ok()
    }

    /// 表の上の段に書く説明 (Web の check-placement.mjs を書く人向け)
    const NOTES: [&str; 10] = [
        "配置 JSON は schemaVersion 5 (中央のリビング hub 10 × 10 の 1 部屋。出入口なし)。家具と床置きの作品の position は、所属する部屋 (roomId) の中心から見たローカル座標。部屋は回さない",
        "house は /api/museum の house と同じ形 (model_url は null)。部屋の置ける範囲は ±(size / 2 − wall_margin)、はみ出しは 2 mm (tolerance ではなく home.rs の TOLERANCE = 0.002) まで許す",
        "door_zone: 出入口の前の置けない場所。壁に沿って出入口の中心 (offset) から ±width / 2、壁の内側の面から部屋の中へ depth。重なりと同じく 2 mm より深くかかったら置けない",
        "layouts.supports = 作品を載せられる家具を hub に 1 つずつ (壁の家具は北・西・東の壁に、底面の高さ y つきで)。layouts.floor = 空の家。layouts.rooms = hub の (3.2, 0, 3.2) に白い台座 (f-hub) を置いた家 (床の隅の候補が台座と重なる)",
        "cases: surface が \"floor\" の行は room (house.rooms の部屋。今は hub だけ) の床に layouts.rooms で置く (候補の roomId = room)。それ以外の行は \"<assetId>/<面の id>\" の面に layouts.supports で置く (parentId = \"f-<assetId>\")",
        "cases の target: 面は centre・+x・-z・+x+z の 4 つ、床はそれに -x・+z を足した 6 つ (targets の座標を、面または部屋の矩形へ clamp_to_rect で寄せた位置が position)",
        "cases の候補 (id \"cand\") は新しく置いた物として判定する (DoorPolicy::OnlyMoved({cand}))。床の候補は所属する部屋の出入口の前にかかると ok: false。layouts の家具は保存済みの物なので出入口の前を見ない",
        "extra: layout に objects (保存済みの物) を足して candidate (id \"cand\") を置けるか。moved が true なら候補の出入口の前を見る、false なら見ない (動かしていない保存済みの物と同じ扱い)",
        "壁の家具 (catalog の placement が \"wall\"): 原点は背面の底の中心。背面を壁の内側の面 (±size / 2) に付け、向きは 90° ごと。高さ (position の y) は wall.mount_min から wall.height − reach まで (reach = 家具の高さと、面の anchor の y + art_fit の高さの大きいほう)。物どうしは足元と高さの範囲の両方が重なると置けない (床の家具は 0〜reach、床の作品は 0〜床の枠の高さ)",
        "壁に掛ける作品 (配置 JSON の placement が \"wall\"。arts の frame が true の作品 = 写真の額縁だけ): 大きさは wall_art_fit に作品の向きで収めたもの。position の (x, z) は足元の中心、y は底面の高さ。足元の背面の側を壁の内側の面に付け (向きは 90° ごと。0 で北の壁、π で南、π/2 で西、−π/2 で東)、壁の内側からはみ出さず、y は wall.mount_min から wall.height − 置いた高さまで。高さの範囲は y〜y + 置いた高さで、ほかの物と足元と高さの範囲の両方が重なると置けない",
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

        // 置いてある作品との重なり・壁・床の額縁・寸法の分からない作品・床の台座
        let id_of = |name: &str| arts.iter().find(|a| a.0 == name).unwrap().1;
        let console = On::Surface("f-home_console", TOP_SURFACE);
        let floor_of = |room: &'static str| On::Floor(room);
        let (boat, rocket) = (id_of("07_rainbow_sailboat"), id_of("06_starbound_rocket"));
        // 45° の帆船をサイドボードの左端に寄せた位置 (外接長方形 0.48 四方)
        let console_top = top("home_console");
        let [w, _, d] = placed_size(&sizes[&boat], art_fit(console_top), FRAC_PI_4);
        let (left_x, left_z) = clamp_to_rect(&top_rect(console_top), w, d, FRAC_PI_4, -10.0, 0.0);
        // 壁に掛けた額縁 (横長。壁の枠 0.9 に収めて幅 0.9・高さ約 0.64・奥行き約 0.057) の奥行きの半分
        let frame = id_of("frame_800x600");
        let [_, frame_h, frame_d] = placed_size(&sizes[&frame], WALL_ART_FIT, 0.0);
        let half = frame_d / 2.0;
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
            // 額縁 (幅 0.348) は床の枠 0.8 まで大きくなるので、壁ぎわ (4.08〜4.88) にも置ける。床の帆船 (2.22〜2.78) とも重ならない
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
            // 床の台座 (3.2, 3.2) に近い (2.8, 2.8) の帆船は台座と重なる。(1.8, 1.8) なら重ならない
            ("floor-overlap-plinth", "rooms", vec![], boat_on("hub", 2.8, 2.8), true),
            ("floor-beside-plinth", "rooms", vec![], boat_on("hub", 1.8, 1.8), true),
            // 家具の候補も同じ。白い台座を台座と同じ (3.2, 3.2) に置くと重なる
            (
                "furniture-overlap-plinth",
                "rooms",
                vec![],
                furniture(CANDIDATE_ID, "plinth_ivory", 3.2, 3.2, 0.0),
                true,
            ),
            // ラグ (3.0 × 2.26) は台座と重なってよい
            (
                "rug-over-plinth",
                "rooms",
                vec![],
                furniture(CANDIDATE_ID, "home_rug", 2.0, 2.5, 0.0),
                true,
            ),
            // 以前の東の出入口の前 (x 3.85〜5.0、z ±1.27)。出入口が無くなったので、新しく置く物でも置ける
            ("former-door-zone", "floor", vec![], boat_on("hub", 4.3, 0.0), true),
            // 壁の家具: 北の壁に付ける・壁から離す・45°・高すぎる
            ("wall-shelf-on-wall", "floor", vec![], on_wall(CANDIDATE_ID, SHELF, 1.0, 1.5, -5.0, 0.0), true),
            ("wall-shelf-off-wall", "floor", vec![], on_wall(CANDIDATE_ID, SHELF, 1.0, 1.5, -4.6, 0.0), true),
            ("wall-shelf-at-45", "floor", vec![], on_wall(CANDIDATE_ID, SHELF, 1.0, 1.5, -5.0, FRAC_PI_4), true),
            ("wall-shelf-too-high", "floor", vec![], on_wall(CANDIDATE_ID, SHELF, 1.0, 3.6, -5.0, 0.0), true),
            ("wall-shelf-past-corner", "floor", vec![], on_wall(CANDIDATE_ID, SHELF, 4.5, 1.5, -5.0, 0.0), true),
            // 東の壁 (−90°) と南の壁 (180°)
            ("wall-ledge-east", "floor", vec![], on_wall(CANDIDATE_ID, LEDGE, 5.0, 1.2, 2.0, -FRAC_PI_2), true),
            ("wall-cabinet-south", "floor", vec![], on_wall(CANDIDATE_ID, CABINET, -2.0, 1.3, 5.0, PI), true),
            // 壁ぎわのサイドボード (高さ 0.891 + 作品の枠 0.62) の上: 1.2 m は重なる、1.52 m なら掛けられる
            (
                "wall-ledge-over-console-low",
                "floor",
                vec![furniture("c", "home_console", 0.0, -5.0 + WALL_MARGIN + 0.255, 0.0)],
                on_wall(CANDIDATE_ID, LEDGE, 0.0, 1.2, -5.0, 0.0),
                true,
            ),
            (
                "wall-ledge-over-console-high",
                "floor",
                vec![furniture("c", "home_console", 0.0, -5.0 + WALL_MARGIN + 0.255, 0.0)],
                on_wall(CANDIDATE_ID, LEDGE, 0.0, 1.52, -5.0, 0.0),
                true,
            ),
            // 壁の家具どうしは上下に離れていれば同じ所に掛けられる
            (
                "wall-shelves-stacked",
                "floor",
                vec![on_wall("s", SHELF, 0.0, 0.5, -5.0, 0.0)],
                on_wall(CANDIDATE_ID, SHELF, 0.0, 1.3, -5.0, 0.0),
                true,
            ),
            (
                "wall-shelves-overlap",
                "floor",
                vec![on_wall("s", SHELF, 0.0, 1.0, -5.0, 0.0)],
                on_wall(CANDIDATE_ID, SHELF, 0.5, 1.2, -5.0, 0.0),
                true,
            ),
            // 壁に掛ける額縁: 北・西の壁に付ける・壁から離す・壁に背を向ける・高すぎる・角からはみ出す
            ("wall-frame-north", "floor", vec![], wall_art(CANDIDATE_ID, frame, 0.0, 1.3, -5.0 + half, 0.0), true),
            ("wall-frame-west", "floor", vec![], wall_art(CANDIDATE_ID, frame, -5.0 + half, 1.3, 1.0, FRAC_PI_2), true),
            ("wall-frame-off-wall", "floor", vec![], wall_art(CANDIDATE_ID, frame, 0.0, 1.3, -4.7, 0.0), true),
            ("wall-frame-facing-wall", "floor", vec![], wall_art(CANDIDATE_ID, frame, 0.0, 1.3, -5.0 + half, PI), true),
            (
                "wall-frame-too-high",
                "floor",
                vec![],
                wall_art(CANDIDATE_ID, frame, 0.0, WALL_HEIGHT - frame_h + 0.05, -5.0 + half, 0.0),
                true,
            ),
            ("wall-frame-past-corner", "floor", vec![], wall_art(CANDIDATE_ID, frame, 4.7, 1.3, -5.0 + half, 0.0), true),
            // 壁の棚と高さが重なれば掛けられない。壁ぎわのサイドボードの上には掛けられる (サイドボードは壁から 12 cm 離れている)
            (
                "wall-frame-over-shelf",
                "floor",
                vec![on_wall("s", SHELF, 0.0, 1.2, -5.0, 0.0)],
                wall_art(CANDIDATE_ID, frame, 0.3, 1.0, -5.0 + half, 0.0),
                true,
            ),
            (
                "wall-frame-above-console",
                "floor",
                vec![furniture("c", "home_console", 0.0, -5.0 + WALL_MARGIN + 0.255, 0.0)],
                wall_art(CANDIDATE_ID, frame, 0.0, 1.0, -5.0 + half, 0.0),
                true,
            ),
            // 壁に掛けられるのは写真の額縁だけ (工作の GLB・寸法の分からない作品は掛けられない)
            ("wall-boat-rejected", "floor", vec![], wall_art(CANDIDATE_ID, boat, 0.0, 1.3, -5.0 + 0.17, 0.0), true),
            ("wall-unknown-rejected", "floor", vec![], wall_art(CANDIDATE_ID, id_of("unknown"), 0.0, 1.3, -4.6, 0.0), true),
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
                    "placement": a.placement,
                    "mount_height": a.mount_height,
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
                let value = json!({
                    "artwork_id": id,
                    "size": size.map(|s| s.size),
                    "custom": size.is_none_or(|s| s.custom),
                    "frame": size.is_some_and(|s| s.frame),
                });
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
            "wall_art_fit": WALL_ART_FIT,
            "wall_margin": WALL_MARGIN,
            "wall": { "height": WALL_HEIGHT, "mount_min": WALL_MOUNT_MIN },
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
        const KEYS: [&str; 15] = [
            "generated_by",
            "notes",
            "tolerance",
            "floor_art_fit",
            "wall_art_fit",
            "wall_margin",
            "wall",
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

    /// 受け入れ条件: アトリエの 33 点すべてが、どの面の中央にも (どの部屋の床の中央にも) 0° でも 90° でも置ける
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
        // (面 16 (本棚は段 3 つと天板、壁の家具 3 つ) + 部屋の床) × 33 点 × 2 つの向き
        let surfaces: usize = CATALOG.assets.iter().map(|a| a.surfaces.len()).sum();
        assert_eq!(surfaces, 16);
        assert_eq!(checked, (surfaces + ROOM_DEFS.len()) * ATELIER.len() * 2);
    }
}
