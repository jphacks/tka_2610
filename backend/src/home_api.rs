//! おうちの配置 API (GET / PUT /api/home/layout) と、配置を保存する共通の処理。
//!
//! 配置を変える処理 (模様替えの保存・作品を飾る / 外す / 消す・起動時の整理・seed) は、
//! どれも 1 つのトランザクションの中で `lock_layout` → 変更 → `save_layout` の順に行う。
//! `SELECT ... FOR UPDATE` で直列になるので、artworks.slot_id の UNIQUE に当たることはない。
//!
//! 出入口の前 (home::door_zone) は、保存するときに「新しく置いた物・動かした物」だけを見る (home::DoorPolicy)。
//! 模様替えの保存は保存済みの配置と比べた物 (home::moved_ids)、作品を飾るときはその作品だけ。
//! 起動時・読むとき・直すときは見ない (保存済みの配置が出入口の前にかかっていても読める)。

use std::collections::HashSet;

use axum::{body::Bytes, extract::State, Json};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{types::Json as JsonColumn, PgExecutor, PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::{
    artworks::{load_sizes, sizes_of},
    error::{AppError, AppResult},
    home::{self, DoorPolicy, Layout, LayoutObject, Sizes},
    state::AppState,
};

/// home_layout.schema_version に書く値 (配置 JSON の schemaVersion と同じ)
const SCHEMA_VERSION: i16 = home::SCHEMA_VERSION as i16;

#[derive(Serialize)]
pub struct SavedLayout {
    pub layout: Layout,
    pub updated_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct PutBody {
    layout: Value,
}

// =============================
// 読み書きの共通処理
// =============================

/// 保存されている配置を読む (ロックなし。表示用)
pub async fn load_layout(pool: &PgPool) -> AppResult<SavedLayout> {
    let (value, updated_at) = fetch_row(pool, "SELECT layout, updated_at FROM home_layout WHERE id = 1").await?;
    Ok(SavedLayout { layout: read_saved(pool, value).await?, updated_at })
}

/// 配置 JSON に出てくる作品の実寸を読む (形の正しくない配置でも読む。直すときにも使うため)
async fn raw_sizes<'e>(executor: impl PgExecutor<'e>, raw: &Value) -> AppResult<Sizes> {
    Ok(sizes_of(&load_sizes(executor, &home::raw_artwork_ids(raw)).await?))
}

/// 保存されている配置を形だけ読む (作品の部屋を引くため。位置の検証はしない)。読めなければ None
pub async fn peek_layout(pool: &PgPool) -> AppResult<Option<Layout>> {
    let (value, _) = fetch_row(pool, "SELECT layout, updated_at FROM home_layout WHERE id = 1").await?;
    Ok(home::parse_layout(value).ok())
}

/// 配置 JSON を作品の実寸で検証する (保存済みの配置なので、出入口の前は見ない)
fn check_saved(raw: Value, sizes: &Sizes) -> Result<Layout, String> {
    let layout = home::parse_layout(raw)?;
    home::check_placement(&layout, sizes, DoorPolicy::Ignore)?;
    Ok(layout)
}

/// 保存されている JSON を配置にする。検証に通らなければ (別の版のサーバーが保存したときなど)、
/// 置けない作品だけを外した配置にする。ここでは書き込まない (外した作品は次の起動の reconcile で置き直される)
async fn read_saved<'e>(executor: impl PgExecutor<'e>, value: Value) -> AppResult<Layout> {
    let sizes = raw_sizes(executor, &value).await?;
    match check_saved(value.clone(), &sizes) {
        Ok(layout) => Ok(layout),
        Err(error) => {
            let (layout, dropped) = home::repair_layout(value, &sizes)
                .map_err(|_| AppError::internal(format!("保存されている配置が読めません: {error}")))?;
            println!("[Home] 置けない作品 {} 点 ({}) を外して配置を読みました ({error})", dropped.len(), dropped.join(", "));
            Ok(layout)
        }
    }
}

async fn fetch_row<'e>(executor: impl PgExecutor<'e>, sql: &'static str) -> AppResult<(Value, DateTime<Utc>)> {
    sqlx::query_as::<_, (Value, DateTime<Utc>)>(sql)
        .fetch_optional(executor)
        .await?
        .ok_or_else(|| AppError::internal("home_layout の行がありません"))
}

/// 配置の行をロックして、保存されている JSON をそのまま返す
async fn lock_row(tx: &mut Transaction<'_, Postgres>) -> AppResult<Value> {
    let (value, _) =
        fetch_row(&mut **tx, "SELECT layout, updated_at FROM home_layout WHERE id = 1 FOR UPDATE").await?;
    Ok(value)
}

/// 配置の行をロックして読む。トランザクションが終わるまで、ほかの書き込みは待たされる
pub async fn lock_layout(tx: &mut Transaction<'_, Postgres>) -> AppResult<Layout> {
    let value = lock_row(tx).await?;
    read_saved(&mut **tx, value).await
}

/// 配置を保存する。`lock_layout` したトランザクションの中で呼ぶ。
///
/// 形の検証 → 作品が存在するかの確認 (作品の実寸も読む) → 位置の検証 (出入口の前は doors の物だけ) →
/// artworks.slot_id / displayed_at を配置に合わせる → JSONB に書く (schema_version も今の版にする)。
/// 配置に無い作品は未展示 (slot_id = NULL) になり、slot_id が無い object を指すことはない。
pub async fn save_layout(
    tx: &mut Transaction<'_, Postgres>,
    layout: Layout,
    doors: DoorPolicy<'_>,
) -> AppResult<SavedLayout> {
    // コードで組み立てた配置もここで検証し直し、DB には正規化した配置だけを書く
    let value = serde_json::to_value(&layout).map_err(AppError::internal)?;
    let layout = home::parse_layout(value).map_err(AppError::bad_request)?;

    let (artwork_ids, slot_ids): (Vec<Uuid>, Vec<String>) =
        layout.artworks().map(|a| (a.artwork_id, a.id.clone())).unzip();

    // 同じ作品が 2 か所にあるときは、このあとの位置の検証で「2 か所に置かれています」にする
    let unique: HashSet<Uuid> = artwork_ids.iter().copied().collect();
    let rows = load_sizes(&mut **tx, &artwork_ids).await?;
    if rows.len() != unique.len() {
        return Err(AppError::bad_request("配置に、登録されていない作品が含まれています"));
    }
    home::check_placement(&layout, &sizes_of(&rows), doors).map_err(AppError::bad_request)?;

    // 配置から外れた作品は未展示に戻す
    sqlx::query(
        "UPDATE artworks SET slot_id = NULL, displayed_at = NULL, updated_at = NOW() \
         WHERE slot_id IS NOT NULL AND id <> ALL($1)",
    )
    .bind(&artwork_ids)
    .execute(&mut **tx)
    .await?;

    // 置き場所が変わる作品は、先に slot_id を外しておく (入れ替えで UNIQUE に当たらないように)
    sqlx::query(
        "UPDATE artworks AS a SET slot_id = NULL \
         FROM unnest($1::uuid[], $2::text[]) AS v(id, slot) \
         WHERE a.id = v.id AND a.slot_id IS NOT NULL AND a.slot_id <> v.slot",
    )
    .bind(&artwork_ids)
    .bind(&slot_ids)
    .execute(&mut **tx)
    .await?;

    // slot_id = 配置の object id。飾り始めた日時 (displayed_at) は移動しても変えない
    sqlx::query(
        "UPDATE artworks AS a \
         SET slot_id = v.slot, displayed_at = COALESCE(a.displayed_at, NOW()), updated_at = NOW() \
         FROM unnest($1::uuid[], $2::text[]) AS v(id, slot) \
         WHERE a.id = v.id AND a.slot_id IS DISTINCT FROM v.slot",
    )
    .bind(&artwork_ids)
    .bind(&slot_ids)
    .execute(&mut **tx)
    .await?;

    let updated_at: DateTime<Utc> = sqlx::query_scalar(
        "UPDATE home_layout SET layout = $1, schema_version = $2, updated_at = NOW() WHERE id = 1 RETURNING updated_at",
    )
    .bind(JsonColumn(&layout))
    .bind(SCHEMA_VERSION)
    .fetch_one(&mut **tx)
    .await?;

    Ok(SavedLayout { layout, updated_at })
}

// =============================
// API
// =============================

pub async fn get_layout(State(state): State<AppState>) -> AppResult<Json<SavedLayout>> {
    Ok(Json(load_layout(&state.pool).await?))
}

/// 模様替えの保存。後から保存したほうが勝つ
pub async fn put_layout(State(state): State<AppState>, body: Bytes) -> AppResult<Json<SavedLayout>> {
    let body: PutBody = serde_json::from_slice(&body)
        .map_err(|e| AppError::bad_request(format!("送信データを読み取れません: {e}")))?;
    // 形の間違いはここで返す。位置 (作品の実寸を使う) は save_layout で検証する
    let layout = home::parse_layout(body.layout).map_err(AppError::bad_request)?;

    let mut tx = state.pool.begin().await?;
    // 保存されている配置は上書きする。比べるのは、出入口の前を見る「新しく置いた物・動かした物」を決めるためだけ。
    // 保存済みの配置が読めなければ (形が違うなど)、すべての物を動かした物として見る
    let raw = lock_row(&mut tx).await?;
    let moved = match home::parse_layout(raw) {
        Ok(stored) => home::moved_ids(&stored, &layout),
        Err(_) => layout.objects.iter().map(|o| o.id().to_string()).collect(),
    };
    let saved = save_layout(&mut tx, layout, DoorPolicy::OnlyMoved(&moved)).await?;
    tx.commit().await?;

    println!("[Home] layout saved ({} objects)", saved.layout.objects.len());
    Ok(Json(saved))
}

// =============================
// 起動時の処理
// =============================

/// 配置の行が無ければ初期配置を入れる。読めない配置が入っていたら、置けない作品だけを外して保存し直す。
/// 家具や部屋がおかしくて直せないときだけ初期配置に戻す。
/// v1・v2 の配置 (リビングだけの家) は v3 に上げて保存し直す (物はそのまま)。出入口の前は見ない
pub async fn ensure_layout(state: &AppState) -> AppResult<()> {
    let default = home::default_layout();
    let inserted = sqlx::query(
        "INSERT INTO home_layout (id, layout, schema_version) VALUES (1, $1, $2) ON CONFLICT (id) DO NOTHING",
    )
    .bind(JsonColumn(&default))
    .bind(SCHEMA_VERSION)
    .execute(&state.pool)
    .await?
    .rows_affected()
        == 1;

    let mut tx = state.pool.begin().await?;
    let (raw, column_version) = sqlx::query_as::<_, (Value, i16)>(
        "SELECT layout, schema_version FROM home_layout WHERE id = 1 FOR UPDATE",
    )
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(|| AppError::internal("home_layout の行がありません"))?;
    let json_version = home::raw_schema_version(&raw);
    let sizes = raw_sizes(&mut *tx, &raw).await?;
    let (layout, repaired) = match check_saved(raw.clone(), &sizes) {
        Ok(layout) => (layout, false),
        Err(error) => {
            let layout = match home::repair_layout(raw, &sizes) {
                Ok((layout, dropped)) => {
                    println!(
                        "[Home] 保存されている配置のうち、置けない作品 {} 点 ({}) を外します ({error})",
                        dropped.len(),
                        dropped.join(", ")
                    );
                    layout
                }
                Err(_) => {
                    println!("[Home] 保存されている配置が読めないので、初期配置に戻します ({error})");
                    default
                }
            };
            (layout, true)
        }
    };
    let upgraded = json_version.is_some_and(|v| v < u64::from(home::SCHEMA_VERSION));
    if repaired || upgraded || column_version != SCHEMA_VERSION {
        // artworks.slot_id はそのままにしておき、このあとの reconcile で置き直す
        sqlx::query("UPDATE home_layout SET layout = $1, schema_version = $2, updated_at = NOW() WHERE id = 1")
            .bind(JsonColumn(&layout))
            .bind(SCHEMA_VERSION)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;

    if upgraded {
        println!("[Home] 配置を v{} に昇格しました (schemaVersion {} から)", home::SCHEMA_VERSION, json_version.unwrap_or(0));
    }
    let note = if inserted { ", default" } else { "" };
    println!("[Home] layout loaded ({} objects, v{}{note})", layout.objects.len(), layout.schema_version);
    Ok(())
}

/// 起動時に、配置と artworks.slot_id のずれを直す。
/// - slot_id が配置に無い作品 (博物館のころの SLOT_xxx など) は空いている場所に置き直す。空きが無ければ未展示に戻す
/// - 作品が消えた配置は外す
pub async fn reconcile(state: &AppState) -> AppResult<()> {
    let mut tx = state.pool.begin().await?;
    let mut layout = lock_layout(&mut tx).await?;

    // 先に飾った作品から順に置き直す
    let rows: Vec<(Uuid, Option<String>, Option<f64>, Option<f64>, Option<f64>, String)> = sqlx::query_as(
        "SELECT id, slot_id, model_width, model_height, model_depth, model_kind FROM artworks \
         ORDER BY displayed_at ASC NULLS LAST, created_at ASC",
    )
    .fetch_all(&mut *tx)
    .await?;
    let sizes: Sizes = rows
        .iter()
        .filter_map(|(id, _, w, h, d, kind)| home::ArtSize::from_model(*w, *h, *d, kind).map(|s| (*id, s)))
        .collect();
    let rows: Vec<(Uuid, Option<String>)> = rows.into_iter().map(|(id, slot_id, ..)| (id, slot_id)).collect();

    let existing: HashSet<Uuid> = rows.iter().map(|(id, _)| *id).collect();
    let before = layout.objects.len();
    layout
        .objects
        .retain(|o| !matches!(o, LayoutObject::Artwork(a) if !existing.contains(&a.artwork_id)));
    let removed = before - layout.objects.len();

    let (mut relocated, mut unplaced, mut out_of_sync) = (0, 0, false);
    for (id, slot_id) in &rows {
        let placed = layout.artwork_for(*id).map(|a| a.id.clone());
        match (slot_id.as_deref(), placed.as_deref()) {
            (None, None) => {}
            (Some(slot), Some(object)) if slot == object => {}
            // 配置が正。slot_id は save_layout で合わせる
            (_, Some(_)) => out_of_sync = true,
            (Some(_), None) => match home::pick_spot(&layout, &sizes, sizes.get(id), None, None) {
                Some(spot) => {
                    layout.objects.push(home::artwork_on(*id, spot));
                    relocated += 1;
                }
                None => unplaced += 1,
            },
        }
    }

    let changed = removed + relocated + unplaced > 0 || out_of_sync;
    if changed {
        // 起動時の整理なので出入口の前は見ない (置き直す作品は家具の上だけ)
        save_layout(&mut tx, layout, DoorPolicy::Ignore).await?;
    }
    tx.commit().await?;

    println!(
        "[Home] reconcile: relocated {relocated}, unplaced {unplaced}, removed {removed}{}",
        if changed { " (saved)" } else { " (no changes)" }
    );
    Ok(())
}
