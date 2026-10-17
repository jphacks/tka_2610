//! 博物館全体の API (Web 画面 ②⑤⑦⑩)

use axum::{extract::State, Json};
use chrono::{Datelike, Local, NaiveDate, Weekday};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
    museum::{self, FloorView},
    state::{media_url, AppState, MediaKind},
};

#[derive(sqlx::FromRow)]
struct DisplayedRow {
    id: Uuid,
    title: String,
    thumb_file: String,
    model_file: String,
    tint: String,
    slot_id: String,
}

async fn displayed_rows(state: &AppState) -> AppResult<Vec<DisplayedRow>> {
    Ok(sqlx::query_as::<_, DisplayedRow>(
        "SELECT id, title, thumb_file, model_file, tint, slot_id \
         FROM artworks WHERE slot_id IS NOT NULL ORDER BY displayed_at ASC",
    )
    .fetch_all(&state.pool)
    .await?)
}

// =============================
// 設定 (⑩)
// =============================

#[derive(Serialize, Deserialize, sqlx::FromRow)]
pub struct Settings {
    pub museum_name: String,
    pub owner_name: String,
}

async fn load_settings(state: &AppState) -> AppResult<Settings> {
    Ok(sqlx::query_as::<_, Settings>(
        "SELECT museum_name, owner_name FROM museum_settings WHERE id = 1",
    )
    .fetch_one(&state.pool)
    .await?)
}

pub async fn get_settings(State(state): State<AppState>) -> AppResult<Json<Settings>> {
    Ok(Json(load_settings(&state).await?))
}

pub async fn update_settings(
    State(state): State<AppState>,
    Json(body): Json<Settings>,
) -> AppResult<Json<Settings>> {
    let museum_name = body.museum_name.trim();
    let owner_name = body.owner_name.trim();
    if museum_name.is_empty() || museum_name.chars().count() > 30 {
        return Err(AppError::bad_request("博物館の名前は1〜30文字で入力してください"));
    }
    if owner_name.is_empty() || owner_name.chars().count() > 30 {
        return Err(AppError::bad_request("名前は1〜30文字で入力してください"));
    }

    let settings = sqlx::query_as::<_, Settings>(
        "UPDATE museum_settings SET museum_name = $1, owner_name = $2, updated_at = NOW() \
         WHERE id = 1 RETURNING museum_name, owner_name",
    )
    .bind(museum_name)
    .bind(owner_name)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(settings))
}

// =============================
// 博物館の全体像 (②ホーム / ⑤館内 / ⑦マップ)
// =============================

#[derive(Serialize)]
pub struct SlotArtwork {
    id: Uuid,
    title: String,
    thumb_url: String,
    model_url: String,
    tint: String,
}

#[derive(Serialize)]
pub struct SlotView {
    id: &'static str,
    position: [f32; 3],
    /// 作品の正面を向ける Y 回転 (度)
    yaw: f32,
    floor: &'static str,
    room_id: Option<&'static str>,
    artwork: Option<SlotArtwork>,
}

#[derive(Serialize)]
pub struct RoomView {
    id: &'static str,
    name: &'static str,
    description: &'static str,
    capacity: usize,
    count: usize,
    floors: Vec<&'static str>,
    /// 展示中の作品サムネイル (最大3件)
    thumbs: Vec<String>,
    tint: Option<String>,
}

#[derive(Serialize)]
pub struct MuseumOverview {
    /// ホームの見出しの上に出す今日の日付 (例: "9月25日 木曜日")
    today_label: String,
    name: String,
    owner_name: String,
    model_url: Option<String>,
    total_artworks: i64,
    displayed_count: usize,
    capacity: usize,
    floors: Vec<FloorView>,
    rooms: Vec<RoomView>,
    slots: Vec<SlotView>,
    /// 作品が置かれた展示台にある、博物館モデル付属のサンプル展示物 (Web では隠す)
    hidden_node_prefixes: Vec<String>,
}

pub async fn museum_overview(State(state): State<AppState>) -> AppResult<Json<MuseumOverview>> {
    let (settings, displayed, total) = tokio::try_join!(
        load_settings(&state),
        displayed_rows(&state),
        async {
            Ok::<i64, AppError>(
                sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM artworks")
                    .fetch_one(&state.pool)
                    .await?,
            )
        },
    )?;

    let find = |slot_id: &str| displayed.iter().find(|r| r.slot_id == slot_id);

    let slots: Vec<SlotView> = museum::SLOTS
        .iter()
        .map(|s| SlotView {
            id: s.id,
            position: s.position,
            yaw: museum::world_yaw(s),
            floor: museum::floor_of(s),
            room_id: museum::room_of_slot(s.id).map(|r| r.id),
            artwork: find(s.id).map(|r| SlotArtwork {
                id: r.id,
                title: r.title.clone(),
                thumb_url: media_url(MediaKind::Thumb, &r.thumb_file),
                model_url: media_url(MediaKind::Model, &r.model_file),
                tint: r.tint.clone(),
            }),
        })
        .collect();

    let rooms = museum::ROOMS
        .iter()
        .map(|room| {
            let in_room: Vec<&DisplayedRow> =
                room.slots.iter().filter_map(|id| find(id)).collect();
            let mut floors: Vec<&'static str> = room
                .slots
                .iter()
                .filter_map(|id| museum::slot(id))
                .map(museum::floor_of)
                .collect();
            floors.dedup();
            RoomView {
                id: room.id,
                name: room.name,
                description: room.description,
                capacity: room.slots.len(),
                count: in_room.len(),
                floors,
                thumbs: in_room
                    .iter()
                    .rev()
                    .take(3)
                    .map(|r| media_url(MediaKind::Thumb, &r.thumb_file))
                    .collect(),
                tint: in_room.last().map(|r| r.tint.clone()),
            }
        })
        .collect();

    let hidden_node_prefixes = displayed
        .iter()
        .filter(|r| museum::slot(&r.slot_id).is_some())
        .map(|r| format!("{}_PROP", r.slot_id))
        .collect();

    Ok(Json(MuseumOverview {
        today_label: today_label(Local::now().date_naive()),
        name: settings.museum_name,
        owner_name: settings.owner_name,
        model_url: state.museum_model_url.clone(),
        total_artworks: total,
        displayed_count: displayed.len(),
        capacity: museum::SLOTS.len(),
        floors: museum::floor_views(),
        rooms,
        slots,
        hidden_node_prefixes,
    }))
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
}
