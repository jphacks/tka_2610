//! おうち全体の API (Web 画面 ②⑤⑦⑩)

use std::{
    collections::{BTreeMap, HashMap},
    sync::LazyLock,
};

use axum::{
    extract::{Query, State},
    Json,
};
use chrono::{Datelike, Local, NaiveDate, Weekday};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
    home::{self, Layout, LayoutObject, RoomDef},
    home_api,
    memories::MemoryCounts,
    state::{media_url, AppState, MediaKind},
};

#[derive(sqlx::FromRow)]
pub(crate) struct DisplayedRow {
    id: Uuid,
    title: String,
    thumb_file: String,
    model_file: String,
    model_kind: String,
    tint: String,
    model_width: Option<f64>,
    model_height: Option<f64>,
    model_depth: Option<f64>,
    /// おもいでの数 (3D の印と鑑賞モードのカードで使う)
    memory_photo: i64,
    memory_video: i64,
    memory_audio: i64,
}

/// おへやに飾っている作品 (飾った順)
pub(crate) async fn displayed_rows(pool: &sqlx::PgPool, room: Uuid) -> AppResult<Vec<DisplayedRow>> {
    Ok(sqlx::query_as::<_, DisplayedRow>(
        "SELECT id, title, thumb_file, model_file, model_kind, tint, \
            model_width, model_height, model_depth, \
            (SELECT COUNT(*) FROM artwork_memories m WHERE m.artwork_id = artworks.id AND m.kind = 'photo') AS memory_photo, \
            (SELECT COUNT(*) FROM artwork_memories m WHERE m.artwork_id = artworks.id AND m.kind = 'video') AS memory_video, \
            (SELECT COUNT(*) FROM artwork_memories m WHERE m.artwork_id = artworks.id AND m.kind = 'audio') AS memory_audio \
         FROM artworks WHERE slot_id IS NOT NULL AND house_room_id = $1 ORDER BY displayed_at ASC",
    )
    .bind(room)
    .fetch_all(pool)
    .await?)
}

// =============================
// 設定 (⑩)
// =============================

#[derive(Serialize, sqlx::FromRow)]
pub struct Settings {
    pub museum_name: String,
    pub owner_name: String,
    /// 子どもの誕生日 ("2021-06-01")。作品の作成日から、作ったときの年齢 (おへや) を決める。未設定なら null
    pub child_birthday: Option<NaiveDate>,
}

/// PUT /api/settings の本文。child_birthday を省くと今の誕生日のまま (消すことはできない)
#[derive(Deserialize)]
pub struct SettingsBody {
    pub museum_name: String,
    pub owner_name: String,
    #[serde(default)]
    pub child_birthday: Option<NaiveDate>,
}

async fn load_settings(state: &AppState) -> AppResult<Settings> {
    Ok(sqlx::query_as::<_, Settings>(
        "SELECT museum_name, owner_name, child_birthday FROM museum_settings WHERE id = 1",
    )
    .fetch_one(&state.pool)
    .await?)
}

/// 子どもの誕生日 (未設定なら None)。作品の年齢 (crate::age) を計算するのに使う
pub async fn child_birthday<'e>(executor: impl sqlx::PgExecutor<'e>) -> AppResult<Option<NaiveDate>> {
    Ok(sqlx::query_scalar::<_, Option<NaiveDate>>("SELECT child_birthday FROM museum_settings WHERE id = 1")
        .fetch_optional(executor)
        .await?
        .flatten())
}

pub async fn get_settings(State(state): State<AppState>) -> AppResult<Json<Settings>> {
    Ok(Json(load_settings(&state).await?))
}

pub async fn update_settings(
    State(state): State<AppState>,
    Json(body): Json<SettingsBody>,
) -> AppResult<Json<Settings>> {
    let before = child_birthday(&state.pool).await?;
    let museum_name = body.museum_name.trim();
    let owner_name = body.owner_name.trim();
    if museum_name.is_empty() || museum_name.chars().count() > 30 {
        return Err(AppError::bad_request("memoriaの名前は1〜30文字で入力してください"));
    }
    if owner_name.is_empty() || owner_name.chars().count() > 30 {
        return Err(AppError::bad_request("名前は1〜30文字で入力してください"));
    }

    if let Some(birthday) = body.child_birthday
        && (birthday > Local::now().date_naive() || birthday.year() < 1900)
    {
        return Err(AppError::bad_request("生年月日の日付が正しくありません"));
    }

    let settings = sqlx::query_as::<_, Settings>(
        "UPDATE museum_settings SET museum_name = $1, owner_name = $2, \
            child_birthday = COALESCE($3, child_birthday), updated_at = NOW() \
         WHERE id = 1 RETURNING museum_name, owner_name, child_birthday",
    )
    .bind(museum_name)
    .bind(owner_name)
    .bind(body.child_birthday)
    .fetch_one(&state.pool)
    .await?;
    // 誕生日が変わると作品の年齢が変わるので、年齢の合わないおへやの作品を、正しい年齢のおへやへ置き直す
    if settings.child_birthday != before {
        home_api::reconcile(&state).await?;
    }
    Ok(Json(settings))
}

// =============================
// おうちの全体像 (②ホーム / ⑤館内 / ⑦マップ)
// =============================

#[derive(Serialize)]
pub struct SlotArtwork {
    id: Uuid,
    title: String,
    thumb_url: String,
    model_url: String,
    tint: String,
    /// "custom" (実寸の工作の GLB) は Web で置き場所より小さくても拡大しない
    model_kind: String,
    /// 作品の実寸 (幅・高さ・奥行き, m)。GLB から測れなかった作品は None。
    /// Web が同じ値で拡縮率と足元を計算するので、f32 に丸めずそのまま返す (丸めると壁ぎりぎりの位置の判定がずれる)
    model_size: Option<[f64; 3]>,
    /// おもいで (写真・動画・声の記録) の数
    memory_counts: MemoryCounts,
}

/// 飾っている作品 1 つの置き場所 (博物館の展示台のころの名前のまま。中身は配置 JSON の作品)
#[derive(Serialize)]
pub struct SlotView {
    /// 配置 JSON の作品の object id
    id: String,
    /// 作品を置く面の中心 (世界座標。部屋の origin 込み。天板の上なら天板の高さ、床なら 0)
    position: [f32; 3],
    /// 作品の正面を向ける Y 回転 (度)
    yaw: f32,
    floor: &'static str,
    /// 作品のある部屋 (家具の上なら家具の部屋)
    room_id: Option<&'static str>,
    /// Web の家のモデル内にあるか (博物館のころの項目。常に true)
    in_main_model: bool,
    /// 作品を収める枠 (幅・高さ・奥行き, m)。家具の上なら載せている面の art_fit、床なら床置きの枠
    fit: [f32; 3],
    /// 作品を表示する倍率 (実寸 model_size × scale で置く)。home::display_scale で、枠と作品自身の向き (rotationY) から決まる。
    /// 寸法が分からない作品は None (Web が枠に合わせる)
    scale: Option<f32>,
    /// 載せている家具の object id。床置きは None
    parent_id: Option<String>,
    /// 載せている面 ("top"・"shelf1" など)。床置きは None
    surface: Option<String>,
    artwork: SlotArtwork,
}

/// 部屋ごとの飾っている作品の数など (順番は home::ROOM_DEFS と同じ。今はリビングだけ)
#[derive(Serialize)]
pub struct RoomView {
    id: &'static str,
    name: &'static str,
    description: &'static str,
    /// 博物館の別館のころの項目。常に false
    annex: bool,
    /// この部屋の家具の置き場所の合計
    capacity: usize,
    /// この部屋に飾っている作品の数 (家具の上の作品は家具の部屋で数える)
    count: usize,
    floors: Vec<&'static str>,
    /// 飾っている作品のサムネイル (新しい順に最大3件)
    thumbs: Vec<String>,
    tint: Option<String>,
}

/// フロア (家は 1F だけ。博物館のころの項目を残している)
#[derive(Serialize)]
pub struct FloorView {
    id: &'static str,
    label: &'static str,
    hide_prefixes: Vec<String>,
}

/// 家具 1 種類 (static/home/catalog.json から)
#[derive(Serialize)]
pub struct AssetView {
    id: &'static str,
    name: &'static str,
    name_ja: &'static str,
    file_url: String,
    category: &'static str,
    /// "floor" (床に置く) か "wall" (壁に掛ける。原点が背面の底の中心で、背面を壁に付ける)
    placement: &'static str,
    /// 壁の家具を足したときに掛ける高さ (底面の y, m)。床の家具は None
    mount_height: Option<f64>,
    dimensions_meters: [f64; 3],
    top_anchor: Option<[f64; 3]>,
    layer: Option<&'static str>,
    /// 作品を載せられるか (面が 1 つ以上ある)
    support: bool,
    /// 作品を載せられる面 (天板・本棚の段など)。作品を自動で置くときに探す順
    surfaces: Vec<SurfaceView>,
}

/// 家具の上で作品を載せられる面
#[derive(Serialize)]
pub struct SurfaceView {
    id: &'static str,
    /// 面の中心 (家具から見た位置、回す前。y は面の高さ)
    anchor: [f64; 3],
    /// 作品を置ける平らな範囲 (幅・奥行き)。中心は anchor
    size: [f64; 2],
    /// この面に載せる作品を収める枠 (幅・高さ・奥行き)
    art_fit: [f64; 3],
}

#[derive(Serialize)]
pub struct ThemeView {
    id: &'static str,
    name: &'static str,
    wall: &'static str,
    floor: &'static str,
}

#[derive(Serialize)]
pub struct MaterialView {
    tile_meters: [f64; 2],
    base_url: String,
    normal_url: String,
    orm_url: String,
}

/// 置ける家具・テーマ・素材の一覧 (サーバーの定数)
#[derive(Serialize)]
pub struct CatalogView {
    kit_version: &'static str,
    assets: Vec<AssetView>,
    themes: Vec<ThemeView>,
    materials: BTreeMap<&'static str, MaterialView>,
}

/// 家の形 (home::ROOM_DEFS をそのまま出す)。Web は部屋の位置・大きさ・出入口をここから読み、数値を直書きしない
#[derive(Serialize)]
pub struct HouseView {
    rooms: Vec<RoomDefView>,
    /// 壁の厚さ (m)
    wall_thickness: f32,
}

/// 部屋 1 つの形
#[derive(Serialize)]
pub struct RoomDefView {
    id: &'static str,
    name: &'static str,
    /// 部屋の中心の世界座標 [x, z]。家具・床置きの作品の position はここから見た位置
    origin: [f32; 2],
    /// 内寸 [幅 (X), 奥行き (Z)] (m)
    size: [f32; 2],
    /// 部屋の建物の GLB (壁・床・出入口)。ファイルが無ければ None
    model_url: Option<String>,
    doors: Vec<DoorView>,
    /// 見下ろすときに切り取る壁の向き ("south" など)
    cutaway: Vec<&'static str>,
}

/// 部屋の壁の出入口
#[derive(Serialize)]
pub struct DoorView {
    /// "north" | "south" | "east" | "west"
    side: &'static str,
    /// 壁の中心からのずれ (m)。北・南の壁は +X、西・東の壁は +Z が正
    offset: f32,
    /// 通れる幅 (m)
    clear_width: f32,
    /// 開口の高さ (m)
    height: f32,
}

/// 家の形。model_url は部屋ごとの GLB の配信 URL (main.rs で用意する)
pub(crate) fn house_view(model_url: impl Fn(&RoomDef) -> Option<String>) -> HouseView {
    HouseView {
        rooms: home::ROOM_DEFS
            .iter()
            .map(|room| RoomDefView {
                id: room.id,
                name: room.name,
                origin: room.origin.map(|v| v as f32),
                size: room.size.map(|v| v as f32),
                model_url: model_url(room),
                doors: room
                    .doors
                    .iter()
                    .map(|d| DoorView {
                        side: d.side.as_str(),
                        offset: d.offset as f32,
                        clear_width: d.clear_width as f32,
                        height: d.height as f32,
                    })
                    .collect(),
                cutaway: room.cutaway.iter().map(|s| s.as_str()).collect(),
            })
            .collect(),
        wall_thickness: home::WALL_THICKNESS as f32,
    }
}

/// 部屋の短い説明 (ホームのカードに出す)
fn room_description(id: &str) -> &'static str {
    match id {
        "hub" => "家族の作品を飾るリビング",
        _ => "",
    }
}

/// 家具の GLB と壁紙のテクスチャの配信先 (main.rs の /home-assets)
const HOME_ASSETS: &str = "/home-assets";

pub(crate) static CATALOG_VIEW: LazyLock<CatalogView> = LazyLock::new(|| {
    let catalog = &*home::CATALOG;
    let texture = |file: &str| format!("{HOME_ASSETS}/textures/{file}");
    CatalogView {
        kit_version: &catalog.kit_version,
        assets: catalog
            .assets
            .iter()
            .map(|a| AssetView {
                id: &a.id,
                name: &a.name,
                name_ja: &a.name_ja,
                file_url: format!("{HOME_ASSETS}/modules/{}", a.file_name()),
                category: &a.category,
                placement: &a.placement,
                mount_height: a.mount_height,
                dimensions_meters: a.dimensions_meters,
                top_anchor: a.top_anchor,
                layer: a.layer.as_deref(),
                support: a.is_support(),
                surfaces: a
                    .surfaces
                    .iter()
                    .map(|s| SurfaceView { id: &s.id, anchor: s.anchor, size: s.size, art_fit: home::art_fit(s) })
                    .collect(),
            })
            .collect(),
        themes: catalog
            .themes
            .iter()
            .map(|t| ThemeView { id: &t.id, name: &t.name, wall: &t.wall, floor: &t.floor })
            .collect(),
        materials: catalog
            .materials
            .iter()
            .map(|(id, m)| {
                let view = MaterialView {
                    tile_meters: m.tile_meters,
                    base_url: texture(&m.base_color),
                    normal_url: texture(&m.normal),
                    orm_url: texture(&m.orm),
                };
                (id.as_str(), view)
            })
            .collect(),
    }
});

#[derive(Serialize)]
pub struct MuseumOverview {
    /// このおへや (?room= のおへや。省いたら最近保存したおへや)。layout・slots・capacity・rooms はこのおへやのもの
    room: home_api::RoomInfo,
    /// ホームの見出しの上に出す今日の日付 (例: "9月25日 木曜日")
    today_label: String,
    name: String,
    owner_name: String,
    /// 家の建物 (壁と床だけの GLB。MUSEUM_MODEL_PATH、既定は 8 × 8 m のリビングだけの home-empty.glb)。
    /// 前の版の Web のために残している。今の建物は house.rooms[].model_url
    model_url: Option<String>,
    /// 一人称で歩く画面用の別の GLB (WALK_MODEL_PATH を指定したときだけ)。無ければ None (model_url を使う)
    walk_model_url: Option<String>,
    total_artworks: i64,
    displayed_count: usize,
    /// 作品を飾れる場所の数 (全部屋の、天板のある家具の置き場所の合計)
    capacity: usize,
    /// 家の形 (部屋の位置・大きさ・出入口・建物の GLB。今はリビングだけ)
    house: HouseView,
    floors: Vec<FloorView>,
    rooms: Vec<RoomView>,
    slots: Vec<SlotView>,
    /// 博物館のころの項目 (建物のノードを名前で隠す)。常に空
    hidden_node_prefixes: Vec<String>,
    /// 配置 JSON (camelCase)
    layout: Layout,
    catalog: &'static CatalogView,
}

/// 配置 JSON の作品から、飾っている作品の置き場所を作る (作品の行が無い配置は飛ばす)
pub(crate) fn slot_views(layout: &Layout, rows: &[DisplayedRow]) -> Vec<SlotView> {
    layout
        .objects
        .iter()
        .filter_map(|obj| {
            let LayoutObject::Artwork(a) = obj else { return None };
            let row = rows.iter().find(|r| r.id == a.artwork_id)?;
            let (position, yaw) = home::world_of(layout, obj)?;
            let room = layout.room_of(obj)?;
            let fit = match &a.parent_id {
                Some(parent_id) => {
                    let parent = layout.furniture(parent_id)?;
                    home::art_fit(home::asset(&parent.asset_id)?.surface(a.surface.as_deref())?)
                }
                None if a.on_wall() => home::WALL_ART_FIT,
                None => home::FLOOR_ART_FIT,
            };
            let size = home::ArtSize::from_model(row.model_width, row.model_height, row.model_depth, &row.model_kind);
            Some(SlotView {
                id: a.id.clone(),
                position: position.map(|v| v as f32),
                yaw: home::yaw_degrees(yaw) as f32,
                floor: home::FLOOR_ID,
                room_id: Some(room.id),
                in_main_model: true,
                fit: fit.map(|v| v as f32),
                // 世界での向きではなく、作品自身の rotationY (載せている面から見た向き) で決まる
                scale: size.map(|s| home::display_scale(&s, fit, a.rotation_y) as f32),
                parent_id: a.parent_id.clone(),
                surface: a.parent_id.as_ref().map(|_| a.surface_id().to_string()),
                artwork: SlotArtwork {
                    id: row.id,
                    title: row.title.clone(),
                    thumb_url: media_url(MediaKind::Thumb, &row.thumb_file),
                    model_url: media_url(MediaKind::Model, &row.model_file),
                    tint: row.tint.clone(),
                    model_kind: row.model_kind.clone(),
                    model_size: size.map(|s| s.size),
                    memory_counts: MemoryCounts {
                        photo: row.memory_photo,
                        video: row.memory_video,
                        audio: row.memory_audio,
                    },
                },
            })
        })
        .collect()
}

pub async fn museum_overview(
    State(state): State<AppState>,
    Query(query): Query<home_api::RoomQuery>,
) -> AppResult<Json<MuseumOverview>> {
    let room = home_api::resolve_room(&state.pool, query.room).await?;
    let (settings, displayed, total, saved) = tokio::try_join!(
        load_settings(&state),
        displayed_rows(&state.pool, room.id),
        async {
            Ok::<i64, AppError>(
                sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM artworks")
                    .fetch_one(&state.pool)
                    .await?,
            )
        },
        home_api::load_layout(&state.pool, room),
    )?;
    let layout = saved.layout;

    let slots = slot_views(&layout, &displayed);
    let capacity = home::capacity(&layout);
    let rooms = room_views(&slots, &displayed, &home::capacity_by_room(&layout));
    let house = house_view(|room| state.room_model_urls.get(room.id).cloned());

    Ok(Json(MuseumOverview {
        room: saved.room,
        today_label: today_label(Local::now().date_naive()),
        name: settings.museum_name,
        owner_name: settings.owner_name,
        model_url: state.museum_model_url.clone(),
        walk_model_url: state.walk_model_url.clone(),
        total_artworks: total,
        displayed_count: slots.len(),
        capacity,
        house,
        floors: vec![FloorView { id: home::FLOOR_ID, label: home::FLOOR_ID, hide_prefixes: Vec::new() }],
        rooms,
        slots,
        hidden_node_prefixes: Vec::new(),
        layout,
        catalog: &CATALOG_VIEW,
    }))
}

/// 部屋ごとの数とサムネイル (ROOM_DEFS の順)。rows は飾った順なので、サムネイルは後ろから (最近飾った順)
fn room_views(slots: &[SlotView], rows: &[DisplayedRow], capacity: &HashMap<&'static str, usize>) -> Vec<RoomView> {
    home::ROOM_DEFS
        .iter()
        .map(|room| {
            let in_room: Vec<&DisplayedRow> = rows
                .iter()
                .filter(|r| slots.iter().any(|s| s.artwork.id == r.id && s.room_id == Some(room.id)))
                .collect();
            RoomView {
                id: room.id,
                name: room.name,
                description: room_description(room.id),
                annex: false,
                capacity: capacity.get(room.id).copied().unwrap_or(0),
                count: in_room.len(),
                floors: vec![home::FLOOR_ID],
                thumbs: in_room
                    .iter()
                    .rev()
                    .take(3)
                    .map(|r| media_url(MediaKind::Thumb, &r.thumb_file))
                    .collect(),
                tint: in_room.last().map(|r| r.tint.clone()),
            }
        })
        .collect()
}

fn today_label(date: NaiveDate) -> String {
    let weekday = match date.weekday() {
        Weekday::Mon => "月",
        Weekday::Tue => "火",
        Weekday::Wed => "水",
        Weekday::Thu => "木",
        Weekday::Fri => "金",
        Weekday::Sat => "土",
        Weekday::Sun => "日",
    };
    format!("{}月{}日 {}曜日", date.month(), date.day(), weekday)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_today_label() {
        let d = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
        assert_eq!(today_label(d), "9月25日 金曜日");
    }

    #[test]
    fn catalog_view_serves_finish_pack_textures() {
        // 内装セットの素材は /home-assets/textures/finish-pack/<素材 id>/ から配信する (テーマも Web に渡す)
        let json = serde_json::to_value(&*CATALOG_VIEW).unwrap();
        let sage = &json["materials"]["sage_limewash"];
        assert_eq!(sage["tile_meters"], serde_json::json!([1.0, 1.0]));
        assert_eq!(sage["base_url"], "/home-assets/textures/finish-pack/sage_limewash/basecolor.jpg");
        assert_eq!(sage["normal_url"], "/home-assets/textures/finish-pack/sage_limewash/normal.png");
        assert_eq!(sage["orm_url"], "/home-assets/textures/finish-pack/sage_limewash/orm.png");
        assert_eq!(json["materials"]["soft_brick"]["tile_meters"], serde_json::json!([1.0, 0.6]));
        assert_eq!(json["materials"]["nero_marble"]["tile_meters"], serde_json::json!([2.0, 2.0]));
        // キットの素材のパスは今までどおり
        assert_eq!(json["materials"]["plaster"]["base_url"], "/home-assets/textures/plaster_base.jpg");
        let theme = json["themes"].as_array().unwrap().iter().find(|t| t["id"] == "dark_marble").unwrap();
        assert_eq!((theme["wall"].as_str(), theme["floor"].as_str()), (Some("mushroom_limewash"), Some("nero_marble")));
    }

    fn row(id: Uuid, title: &str, size: Option<[f64; 3]>) -> DisplayedRow {
        DisplayedRow {
            id,
            title: title.into(),
            thumb_file: format!("{id}.jpg"),
            model_file: format!("{id}.glb"),
            model_kind: "custom".into(),
            tint: "#f3e7da".into(),
            model_width: size.map(|s| s[0]),
            model_height: size.map(|s| s[1]),
            model_depth: size.map(|s| s[2]),
            memory_photo: 0,
            memory_video: 0,
            memory_audio: 0,
        }
    }

    #[test]
    fn slot_view_from_layout() {
        let (on_console, on_floor, missing) = (Uuid::from_u128(1), Uuid::from_u128(2), Uuid::from_u128(3));
        let turned = Uuid::from_u128(4);
        let layout = home::parse_layout(serde_json::json!({
            "schemaVersion": 2,
            "rooms": {
                "hub": { "enabled": true, "width": 8, "depth": 8, "wall": "plaster", "floor": "oak" },
                "left": { "enabled": false, "width": 6, "depth": 6, "wall": "oak", "floor": "oak" },
                "right": { "enabled": false, "width": 6, "depth": 6, "wall": "plaster", "floor": "oak" },
                "front": { "enabled": false, "width": 6, "depth": 6, "wall": "brick", "floor": "limestone" }
            },
            "objects": [
                { "kind": "furniture", "id": "home-005", "assetId": "home_console", "roomId": "hub",
                  "position": [2.7, 0, 1.55], "rotationY": -std::f64::consts::FRAC_PI_2 },
                { "kind": "artwork", "id": "art-1", "artworkId": on_console, "parentId": "home-005",
                  "position": [0.5, 0, 0], "rotationY": 0 },
                { "kind": "artwork", "id": "art-2", "artworkId": on_floor, "roomId": "hub",
                  "position": [-1.0, 0, 1.0], "rotationY": std::f64::consts::PI },
                { "kind": "artwork", "id": "art-3", "artworkId": missing, "parentId": "home-005",
                  "position": [-0.56, 0, 0], "rotationY": 0 },
                { "kind": "artwork", "id": "art-4", "artworkId": turned, "parentId": "home-005",
                  "position": [0.0, 0, 0], "rotationY": std::f64::consts::FRAC_PI_2 }
            ]
        }))
        .unwrap();

        // 帆船の実寸 (幅 0.56・奥行き 0.34)。床の作品は寸法が分からない
        let boat = Some([0.56, 0.582, 0.34]);
        let rows = [row(on_floor, "床", None), row(on_console, "棚", boat), row(turned, "回した棚", boat)];
        let sizes: home::Sizes = rows
            .iter()
            .filter_map(|r| home::ArtSize::from_model(r.model_width, r.model_height, r.model_depth, &r.model_kind).map(|s| (r.id, s)))
            .collect();
        // 実寸なら 90° 回した帆船もサイドボードに置ける
        home::check_placement(&layout, &sizes, home::DoorPolicy::Ignore).unwrap();

        // 作品の行が無い配置 (art-3) は出さない
        let slots = slot_views(&layout, &rows);
        assert_eq!(slots.len(), 3);

        let s = &slots[0];
        assert_eq!(s.id, "art-1");
        assert_eq!(s.parent_id.as_deref(), Some("home-005"));
        assert_eq!(s.artwork.id, on_console);
        assert_eq!(s.artwork.model_kind, "custom");
        let close = |a: f32, b: f32| (a - b).abs() < 1e-5;
        assert!(close(s.position[0], 2.7) && close(s.position[1], 0.891) && close(s.position[2], 2.05), "{:?}", s.position);
        // 向きは度、枠はサイドボードの天板の art_fit (平らな所の奥行き 0.48)
        assert!(close(s.yaw, -90.0), "{}", s.yaw);
        assert!(close(s.fit[0], 0.56) && close(s.fit[1], 0.62) && close(s.fit[2], 0.48), "{:?}", s.fit);
        // 0° の帆船は実寸のまま (サイドボードの向きが -90° でも、作品自身の向きで決まる)
        assert_eq!(s.artwork.model_size, Some([0.56, 0.582, 0.34]));
        assert!(close(s.scale.unwrap(), 1.0), "{:?}", s.scale);

        let s = &slots[1];
        assert_eq!(s.parent_id, None);
        assert_eq!(s.position, [-1.0, 0.0, 1.0]);
        assert!(close(s.yaw, 180.0), "{}", s.yaw);
        assert_eq!(s.fit, [0.8, 1.0, 0.8]);
        assert_eq!(s.room_id, Some("hub"));
        // 寸法が分からない作品は None (Web が枠に合わせる)
        assert_eq!(s.artwork.model_size, None);
        assert_eq!(s.scale, None);

        // 90° 回した帆船は、奥行き 0.48 に幅 0.56 を収める 0.857142…
        let s = &slots[2];
        assert_eq!(s.id, "art-4");
        assert!(close(s.scale.unwrap(), 0.48 / 0.56), "{:?}", s.scale);
        assert!(close(s.yaw, 0.0), "{}", s.yaw);
        // v2 の配置なので、作品はどれも hub
        assert!(slots.iter().all(|s| s.room_id == Some("hub")));
    }

    /// 今の版 (v5) の rooms (中央のリビングだけ)
    fn rooms_now() -> serde_json::Value {
        serde_json::json!({ "hub": { "enabled": true, "width": 10, "depth": 10, "wall": "plaster", "floor": "oak" } })
    }

    #[test]
    fn slot_view_world_positions_by_room() {
        let ids: Vec<Uuid> = (1..=4).map(Uuid::from_u128).collect();
        let layout = home::parse_layout(serde_json::json!({
            "schemaVersion": home::SCHEMA_VERSION,
            "rooms": rooms_now(),
            "objects": [
                { "kind": "furniture", "id": "desk", "assetId": "home_craft_desk", "roomId": "hub",
                  "position": [1.0, 0, 2.0], "rotationY": 0 },
                { "kind": "artwork", "id": "art-1", "artworkId": ids[0], "parentId": "desk",
                  "position": [0.1, 0, 0], "rotationY": 0 },
                { "kind": "artwork", "id": "art-2", "artworkId": ids[1], "roomId": "hub",
                  "position": [-2.0, 0, 1.0], "rotationY": 0 },
                { "kind": "furniture", "id": "slim", "assetId": "plinth_slim", "roomId": "hub",
                  "position": [-3.0, 0, 0.5], "rotationY": 0 },
                { "kind": "artwork", "id": "art-3", "artworkId": ids[2], "parentId": "slim",
                  "position": [0.0, 0, 0], "rotationY": 0 },
                { "kind": "furniture", "id": "shelf", "assetId": "home_display_shelf", "roomId": "hub",
                  "position": [0.0, 0, 0.0], "rotationY": 0 },
                { "kind": "artwork", "id": "art-4", "artworkId": ids[3], "parentId": "shelf",
                  "position": [-0.28, 0, 0], "rotationY": 0 }
            ]
        }))
        .unwrap();
        home::check_placement(&layout, &home::Sizes::new(), home::DoorPolicy::Ignore).unwrap();
        let rows: Vec<DisplayedRow> = ids.iter().map(|id| row(*id, "作品", None)).collect();
        let slots = slot_views(&layout, &rows);
        assert_eq!(slots.len(), 4);
        let close = |a: [f32; 3], b: [f32; 3]| a.iter().zip(b).all(|(x, y)| (x - y).abs() < 1e-5);
        // リビングの中心は世界の原点。工作机 (1, 0, 2) の天板の上の作品 (x + 0.1)
        assert!(slots.iter().all(|s| s.room_id == Some("hub")));
        assert!(close(slots[0].position, [1.1, 0.795, 2.0]), "{:?}", slots[0].position);
        // 床の作品 (−2, 0, 1)
        assert!(close(slots[1].position, [-2.0, 0.0, 1.0]), "{:?}", slots[1].position);
        // 細い台座 (−3, 1.235, 0.5)
        assert!(close(slots[2].position, [-3.0, 1.235, 0.5]), "{:?}", slots[2].position);
        assert!(close(slots[3].position, [-0.28, 0.843, 0.0]), "{:?}", slots[3].position);

        // 部屋ごとの数・置き場所の数 (ROOM_DEFS の順。今はリビングだけ)。サムネイルは新しい 3 つ
        let rooms = room_views(&slots, &rows, &home::capacity_by_room(&layout));
        let summary: Vec<(&str, &str, usize, usize, usize)> =
            rooms.iter().map(|r| (r.id, r.name, r.count, r.capacity, r.thumbs.len())).collect();
        assert_eq!(summary, vec![("hub", "中央のリビング", 4, 5, 3)]);
    }

    #[test]
    fn house_view_lists_room_defs() {
        let house = house_view(|room| Some(format!("/media/museum/room-{}.glb", room.id)));
        let value = serde_json::to_value(&house).unwrap();
        let text = serde_json::to_string(&house).unwrap();
        // f32 でも JSON には短く書かれる
        assert!(text.contains("\"origin\":[0.0,0.0]") && text.contains("\"wall_thickness\":0.24"), "{text}");
        // 部屋は中央のリビングだけ。出入口は無い
        let rooms = value["rooms"].as_array().unwrap();
        let ids: Vec<&str> = rooms.iter().map(|r| r["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["hub"]);
        assert_eq!(rooms[0]["model_url"], "/media/museum/room-hub.glb");
        assert_eq!(rooms[0]["size"], serde_json::json!([10.0, 10.0]));
        assert_eq!(rooms[0]["doors"], serde_json::json!([]));
        assert_eq!(rooms[0]["cutaway"], serde_json::json!(["south", "east"]));
        // 建物の GLB が無ければ model_url は null
        let none = serde_json::to_value(house_view(|_| None)).unwrap();
        assert!(none["rooms"][0]["model_url"].is_null());
    }
}
