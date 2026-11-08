//! 年齢ごとのおへやの一覧と、積み上げの建物の API (Web のホーム・マップ)。
//!
//! - GET /api/ages            年齢の一覧 (年齢ごとの作品の数・おへや)。ホームの年齢のチップとマップのリスト
//! - GET /api/ages/{age}      その年齢のおへやを積み上げて描くための、おへやごとの配置と飾っている作品
//! - POST /api/ages/{age}/rooms  その年齢のいちばん上におへやを足す (家具は初期配置)
//! - DELETE /api/rooms/{id}   作品の無い、その年齢のいちばん上のおへやを消す (階の番号を詰めないで済むように、上からだけ)

use std::collections::{BTreeMap, BTreeSet, HashMap};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use chrono::NaiveDate;
use serde::Serialize;
use uuid::Uuid;

use crate::{
    age,
    db::Db,
    error::{AppError, AppResult},
    home::{self, Layout},
    home_api::{self, RoomInfo, RoomRow},
    museum_api::{self, CatalogView, HouseView, SlotView, CATALOG_VIEW},
    params,
    state::{media_url, today, AppState, MediaKind},
};

/// おへやのリストの 1 つ
#[derive(Serialize)]
pub struct RoomSummary {
    #[serde(flatten)]
    room: RoomInfo,
    /// 飾っている作品の数
    count: usize,
    /// 作品を飾れる場所の数
    capacity: usize,
    /// 最近飾った作品のサムネイル (最大 3 件)
    thumbs: Vec<String>,
    /// いちばん最近飾った作品の色
    tint: Option<String>,
}

#[derive(Serialize)]
pub struct AgeView {
    age: i16,
    /// "4さい"
    label: String,
    /// その年齢の作品の数 (飾っていない作品も)
    artwork_count: usize,
    displayed_count: usize,
    /// その年齢のおへや (1 階から)
    rooms: Vec<RoomSummary>,
}

#[derive(Serialize)]
pub struct AgesOverview {
    /// 博物館の名前
    name: String,
    /// 子どもの誕生日 (未設定なら null。そのときは作品の年齢は登録時に入れた年齢)
    child_birthday: Option<NaiveDate>,
    /// 今の年齢 (誕生日が無ければ null)
    current_age: Option<i16>,
    total_artworks: usize,
    /// 年齢の小さい順。作品のある年齢・おへやのある年齢・今の年齢
    ages: Vec<AgeView>,
}

/// 積み上げの建物の 1 階分
#[derive(Serialize)]
pub struct StackRoom {
    room: RoomInfo,
    count: usize,
    capacity: usize,
    /// 配置 JSON (camelCase)
    layout: Layout,
    slots: Vec<SlotView>,
}

#[derive(Serialize)]
pub struct AgeStack {
    age: i16,
    label: String,
    /// 家の形 (どのおへやも同じ建物。今はリビング hub)
    house: HouseView,
    catalog: &'static CatalogView,
    /// 1 階から
    rooms: Vec<StackRoom>,
}

/// 「4さい」
pub fn age_label(age: i16) -> String {
    format!("{age}さい")
}

/// 作品 1 つの、一覧に使う値
struct ArtRow {
    age: i16,
    room: Option<Uuid>,
    thumb_file: String,
    tint: String,
}

fn art_rows(db: &Db, birthday: Option<NaiveDate>) -> AppResult<Vec<ArtRow>> {
    // 飾った順 (サムネイルは後ろから = 最近飾った順)
    let rows = db.tuples::<(NaiveDate, Option<i16>, Option<Uuid>, String, String)>(
        "SELECT made_on, age, house_room_id, thumb_file, tint FROM artworks ORDER BY displayed_at ASC NULLS FIRST, created_at ASC",
        params![],
    )?;
    Ok(rows
        .into_iter()
        .map(|(made_on, manual, room, thumb_file, tint)| ArtRow {
            age: age::artwork_age(birthday, made_on, manual),
            room,
            thumb_file,
            tint,
        })
        .collect())
}

/// おへやごとの置き場所の数
fn capacities(db: &Db, rooms: &[RoomRow]) -> AppResult<HashMap<Uuid, usize>> {
    let mut out = HashMap::new();
    for room in rooms {
        let saved = home_api::load_layout(db, *room)?;
        out.insert(room.id, home::capacity(&saved.layout));
    }
    Ok(out)
}

fn summary(room: &RoomRow, arts: &[ArtRow], capacity: usize) -> RoomSummary {
    let shown: Vec<&ArtRow> = arts.iter().filter(|a| a.room == Some(room.id)).collect();
    RoomSummary {
        room: room.info(),
        count: shown.len(),
        capacity,
        thumbs: shown.iter().rev().take(3).map(|a| media_url(MediaKind::Thumb, &a.thumb_file)).collect(),
        tint: shown.last().map(|a| a.tint.clone()),
    }
}

/// GET /api/ages
pub async fn list_ages(State(state): State<AppState>) -> AppResult<Json<AgesOverview>> {
    let db = &state.db;
    let birthday = museum_api::child_birthday(db)?;
    let name = db
        .scalar::<String>("SELECT museum_name FROM museum_settings WHERE id = 1", params![])?
        .ok_or_else(|| AppError::not_found("作品が見つかりません"))?;
    let current_age = birthday.map(|b| age::age_on(b, today()));
    let arts = art_rows(db, birthday)?;
    let rooms = home_api::all_rooms(db)?;
    let capacity = capacities(db, &rooms)?;

    let mut ages: BTreeSet<i16> = arts.iter().map(|a| a.age).chain(rooms.iter().map(|r| r.age)).collect();
    ages.extend(current_age);
    let mut by_age: BTreeMap<i16, Vec<&RoomRow>> = BTreeMap::new();
    for room in &rooms {
        by_age.entry(room.age).or_default().push(room);
    }

    let ages = ages
        .into_iter()
        .map(|a| AgeView {
            age: a,
            label: age_label(a),
            artwork_count: arts.iter().filter(|x| x.age == a).count(),
            displayed_count: arts.iter().filter(|x| x.age == a && x.room.is_some()).count(),
            rooms: by_age
                .get(&a)
                .into_iter()
                .flatten()
                .map(|room| summary(room, &arts, capacity.get(&room.id).copied().unwrap_or(0)))
                .collect(),
        })
        .collect();

    Ok(Json(AgesOverview { name, child_birthday: birthday, current_age, total_artworks: arts.len(), ages }))
}

/// GET /api/ages/{age}
pub async fn age_stack(State(state): State<AppState>, Path(age): Path<i16>) -> AppResult<Json<AgeStack>> {
    let db = &state.db;
    let mut rooms = Vec::new();
    for room in home_api::rooms_of_age(db, age)? {
        let saved = home_api::load_layout(db, room)?;
        let displayed = museum_api::displayed_rows(db, room.id)?;
        let slots = museum_api::slot_views(&saved.layout, &displayed);
        rooms.push(StackRoom {
            room: room.info(),
            count: slots.len(),
            capacity: home::capacity(&saved.layout),
            layout: saved.layout,
            slots,
        });
    }
    let house = museum_api::house_view(|room| state.room_model_urls.get(room.id).cloned());
    Ok(Json(AgeStack { age, label: age_label(age), house, catalog: &CATALOG_VIEW, rooms }))
}

/// POST /api/ages/{age}/rooms
pub async fn add_room(State(state): State<AppState>, Path(age): Path<i16>) -> AppResult<(StatusCode, Json<RoomInfo>)> {
    let db = &state.db;
    let birthday = museum_api::child_birthday(db)?;
    let oldest = birthday.map_or(age::MAX_AGE, |b| age::age_on(b, today()));
    if !(0..=oldest).contains(&age) {
        return Err(AppError::bad_request(format!("{} のおへやは作れません", age_label(age))));
    }
    let room = db.tx(|| home_api::create_room(db, age, &home::default_layout()))?;
    worker::console_log!("[Home] {} を足しました", room.name());
    Ok((StatusCode::CREATED, Json(room.info())))
}

/// DELETE /api/rooms/{id}
pub async fn delete_room(State(state): State<AppState>, Path(id): Path<Uuid>) -> AppResult<StatusCode> {
    let db = &state.db;
    let room = db.tx(|| {
        let room = home_api::find_room(db, id)?;
        let top = home_api::rooms_of_age(db, room.age)?.last().copied();
        if top != Some(room) {
            return Err(AppError::bad_request("消せるのは、いちばん上のおへやだけです"));
        }
        let count: i64 = db
            .scalar("SELECT COUNT(*) FROM artworks WHERE house_room_id = ?1", params![id])?
            .unwrap_or(0);
        if count > 0 {
            return Err(AppError::conflict("作品を飾っているおへやは消せません。先に作品を外してください"));
        }
        db.exec("DELETE FROM house_rooms WHERE id = ?1", params![id])?;
        Ok(room)
    })?;
    worker::console_log!("[Home] {} を消しました", room.name());
    Ok(StatusCode::NO_CONTENT)
}
