//! 「すべて」の配置。家ごとの SQLite に、1 トランザクションで保存する。
use crate::{
    all_home::AllHome,
    db::Db,
    error::{AppError, AppResult},
    home,
    home_api::SavedLayout,
    museum_api::{self, DisplayedRow},
    now_sql, params,
    state::AppState,
};
use axum::{
    Json,
    body::Bytes,
    extract::{Path, State},
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

pub(crate) struct Snapshot {
    pub home: AllHome,
    pub artworks: Vec<DisplayedRow>,
    updated_at: DateTime<Utc>,
}
impl Snapshot {
    fn saved(&self, floor: usize) -> AppResult<SavedLayout> {
        Ok(SavedLayout {
            room: crate::all_ages::room_info(floor),
            layout: self
                .home
                .floors
                .get(floor)
                .ok_or_else(|| AppError::not_found("そのおへやはありません"))?
                .clone(),
            updated_at: self.updated_at,
        })
    }
}

fn write(db: &Db, home: &AllHome) -> AppResult<DateTime<Utc>> {
    db.exec(concat!("INSERT INTO all_home_layout (id, state) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET state = excluded.state, updated_at = ", now_sql!()), params![crate::db::json(home)?])?;
    db.scalar(
        "SELECT updated_at FROM all_home_layout WHERE id = 1",
        params![],
    )?
    .ok_or_else(|| AppError::internal("all_home_layout missing"))
}

/// 呼び出し元の db.tx で、読み取り・整理・保存を1つにまとめる。
fn lock_layout(db: &Db) -> AppResult<Snapshot> {
    let row = db
        .tuples::<(String, DateTime<Utc>)>(
            "SELECT state, updated_at FROM all_home_layout WHERE id = 1",
            params![],
        )?
        .into_iter()
        .next();
    let artworks = museum_api::all_artwork_rows(db)?;
    let mut home: AllHome = row
        .as_ref()
        .map(|(raw, _)| serde_json::from_str(raw))
        .transpose()
        .map_err(AppError::internal)?
        .unwrap_or_default();
    home.reconcile(
        &artworks
            .iter()
            .map(DisplayedRow::placement)
            .collect::<Vec<_>>(),
    )
    .map_err(AppError::internal)?;
    let value = serde_json::to_string(&home).map_err(AppError::internal)?;
    let updated_at = match row {
        Some((raw, updated_at)) if raw == value => updated_at,
        _ => write(db, &home)?,
    };
    Ok(Snapshot {
        home,
        artworks,
        updated_at,
    })
}

pub(crate) fn load(state: &AppState) -> AppResult<Snapshot> {
    state.db.tx(|| lock_layout(&state.db))
}

pub async fn get_layout(
    State(state): State<AppState>,
    Path(floor): Path<usize>,
) -> AppResult<Json<SavedLayout>> {
    Ok(Json(load(&state)?.saved(floor)?))
}

#[derive(Deserialize)]
struct PutBody {
    layout: Value,
}

pub async fn put_layout(
    State(state): State<AppState>,
    Path(floor): Path<usize>,
    body: Bytes,
) -> AppResult<Json<SavedLayout>> {
    let body: PutBody = serde_json::from_slice(&body)
        .map_err(|e| AppError::bad_request(format!("送信データを読み取れません: {e}")))?;
    let layout = home::parse_layout(body.layout).map_err(AppError::bad_request)?;
    Ok(Json(state.db.tx(|| {
        let mut snapshot = lock_layout(&state.db)?;
        snapshot.saved(floor)?;
        let artworks = snapshot
            .artworks
            .iter()
            .map(DisplayedRow::placement)
            .collect::<Vec<_>>();
        snapshot
            .home
            .save_floor(floor, layout, &artworks)
            .map_err(AppError::bad_request)?;
        snapshot.updated_at = write(&state.db, &snapshot.home)?;
        snapshot.saved(floor)
    })?))
}

pub async fn display_artwork(
    State(state): State<AppState>,
    Path((floor, id)): Path<(usize, Uuid)>,
) -> AppResult<Json<SavedLayout>> {
    Ok(Json(state.db.tx(|| {
        let mut snapshot = lock_layout(&state.db)?;
        snapshot.saved(floor)?;
        let artworks = snapshot
            .artworks
            .iter()
            .map(DisplayedRow::placement)
            .collect::<Vec<_>>();
        if !artworks.iter().any(|(key, _)| *key == id) {
            return Err(AppError::not_found("作品が見つかりません"));
        }
        if !snapshot
            .home
            .display(floor, id, &artworks)
            .map_err(AppError::bad_request)?
        {
            return Err(AppError::conflict(
                "このおへやはいっぱいで飾れません。家具や作品の配置を変えてください",
            ));
        }
        snapshot.updated_at = write(&state.db, &snapshot.home)?;
        snapshot.saved(floor)
    })?))
}
