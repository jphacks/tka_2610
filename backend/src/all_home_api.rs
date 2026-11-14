//! 「すべて」の配置の永続化。年齢別と同じ家全体のロックで書き込みを並べる。
use crate::{
    all_home::AllHome,
    error::{AppError, AppResult},
    home,
    home_api::{self, SavedLayout},
    museum_api::{self, DisplayedRow},
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
use sqlx::{Postgres, Transaction};
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

async fn write(tx: &mut Transaction<'_, Postgres>, home: &AllHome) -> AppResult<DateTime<Utc>> {
    Ok(sqlx::query_scalar("INSERT INTO all_home_layout (id, state) VALUES (1, $1) ON CONFLICT (id) DO UPDATE SET state = EXCLUDED.state, updated_at = NOW() RETURNING updated_at")
        .bind(sqlx::types::Json(home)).fetch_one(&mut **tx).await?)
}

/// 年齢別の lock_layout と同じ家全体のロックを取り、作品の一覧も同じトランザクションで読む。
async fn lock_layout(tx: &mut Transaction<'_, Postgres>) -> AppResult<Snapshot> {
    home_api::lock_house(tx).await?;
    let row = sqlx::query_as::<_, (Value, DateTime<Utc>)>(
        "SELECT state, updated_at FROM all_home_layout WHERE id = 1 FOR UPDATE",
    )
    .fetch_optional(&mut **tx)
    .await?;
    let artworks = museum_api::all_artwork_rows(&mut **tx).await?;
    let mut home: AllHome = row
        .as_ref()
        .map(|(raw, _)| serde_json::from_value(raw.clone()))
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
    let value = serde_json::to_value(&home).map_err(AppError::internal)?;
    let updated_at = match row {
        Some((raw, updated_at)) if raw == value => updated_at,
        _ => write(tx, &home).await?,
    };
    Ok(Snapshot {
        home,
        artworks,
        updated_at,
    })
}

pub(crate) async fn load(state: &AppState) -> AppResult<Snapshot> {
    let mut tx = state.pool.begin().await?;
    let snapshot = lock_layout(&mut tx).await?;
    tx.commit().await?;
    Ok(snapshot)
}

pub async fn get_layout(
    State(state): State<AppState>,
    Path(floor): Path<usize>,
) -> AppResult<Json<SavedLayout>> {
    Ok(Json(load(&state).await?.saved(floor)?))
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
    let mut tx = state.pool.begin().await?;
    let mut snapshot = lock_layout(&mut tx).await?;
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
    snapshot.updated_at = write(&mut tx, &snapshot.home).await?;
    let saved = snapshot.saved(floor)?;
    tx.commit().await?;
    Ok(Json(saved))
}

pub async fn display_artwork(
    State(state): State<AppState>,
    Path((floor, id)): Path<(usize, Uuid)>,
) -> AppResult<Json<SavedLayout>> {
    let mut tx = state.pool.begin().await?;
    let mut snapshot = lock_layout(&mut tx).await?;
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
    snapshot.updated_at = write(&mut tx, &snapshot.home).await?;
    let saved = snapshot.saved(floor)?;
    tx.commit().await?;
    Ok(Json(saved))
}
