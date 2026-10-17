//! 年齢ごとのおへや (house_rooms) の配置 API と、配置を保存する共通の処理。
//!
//! おへやは 1 行に 1 つの配置 JSON (schemaVersion 5。リビング hub 1 部屋の家具と作品) を持つ。
//! 作品は、作ったときの年齢 (crate::age) のおへやにだけ飾る。artworks.house_room_id が飾っているおへや、
//! artworks.slot_id がそのおへやの配置の中の作品の object id。
//!
//! 配置を変える処理 (模様替えの保存・作品を飾る / 外す / 消す・起動時の整理・seed) は、
//! どれも 1 つのトランザクションの中で `lock_layout` → 変更 → `save_layout` の順に行う。
//! `lock_layout` は家全体のロック (lock_house。advisory lock) を取るので、おへやをまたぐ移動も含めて書き込みは 1 本に並ぶ
//! (おへやの行をばらばらの順にロックして、デッドロックになることがない)。
//! slot_id の object id は全部のおへやで重ならないので、UNIQUE には当たらない。
//!
//! 出入口の前 (home::door_zone) は、保存するときに「新しく置いた物・動かした物」だけを見る (home::DoorPolicy)。
//! 今の家には出入口が無いので、何も止まらない。

use std::collections::{HashMap, HashSet};

use axum::{
    body::Bytes,
    extract::{Query, State},
    Json,
};
use chrono::{DateTime, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{types::Json as JsonColumn, FromRow, PgExecutor, PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::{
    age,
    artworks::{load_sizes, sizes_of},
    error::{AppError, AppResult},
    home::{self, ArtSize, DoorPolicy, Layout, LayoutObject, Sizes},
    museum_api,
    state::AppState,
};

/// house_rooms.schema_version に書く値 (配置 JSON の schemaVersion と同じ)
const SCHEMA_VERSION: i16 = home::SCHEMA_VERSION as i16;

/// 1 つの年齢に積み上げられるおへやの数
pub const MAX_FLOORS: i16 = 10;

/// 家全体の書き込みロックの鍵 (pg_advisory_xact_lock)。値に意味は無い
const HOUSE_LOCK: i64 = 0x6f6d6f69_64650001;

// =============================
// おへや
// =============================

/// おへや 1 つ (配置は別に読む)
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromRow)]
pub struct RoomRow {
    pub id: Uuid,
    /// 作品を作ったときの年齢
    pub age: i16,
    /// その年齢の中での階 (0 が 1 階)
    pub floor: i16,
}

impl RoomRow {
    pub fn name(&self) -> String {
        room_name(self.age, self.floor)
    }

    pub fn info(&self) -> RoomInfo {
        RoomInfo { id: self.id, age: self.age, floor: self.floor, name: self.name() }
    }
}

/// 「4さいのおへや」「4さいのおへや 2」(2 階から上は番号を付ける)
pub fn room_name(age: i16, floor: i16) -> String {
    if floor == 0 { format!("{age}さいのおへや") } else { format!("{age}さいのおへや {}", floor + 1) }
}

/// API で返すおへや
#[derive(Debug, Clone, Serialize)]
pub struct RoomInfo {
    pub id: Uuid,
    pub age: i16,
    pub floor: i16,
    /// 例: "4さいのおへや 2"
    pub name: String,
}

#[derive(Serialize)]
pub struct SavedLayout {
    pub room: RoomInfo,
    pub layout: Layout,
    pub updated_at: DateTime<Utc>,
}

/// ?room=<おへやの id>。省くと最近使ったおへや
#[derive(Deserialize, Default)]
pub struct RoomQuery {
    pub room: Option<Uuid>,
}

#[derive(Deserialize)]
struct PutBody {
    layout: Value,
}

/// 全部のおへや (年齢・階の順)
pub async fn all_rooms<'e>(executor: impl PgExecutor<'e>) -> AppResult<Vec<RoomRow>> {
    Ok(sqlx::query_as::<_, RoomRow>("SELECT id, age, floor FROM house_rooms ORDER BY age, floor")
        .fetch_all(executor)
        .await?)
}

/// おへやの id → 名前 (作品の「飾っているおへや」を出すため)
pub async fn room_names<'e>(executor: impl PgExecutor<'e>) -> AppResult<HashMap<Uuid, String>> {
    Ok(all_rooms(executor).await?.iter().map(|r| (r.id, r.name())).collect())
}

/// ある年齢のおへや (階の順)
pub async fn rooms_of_age<'e>(executor: impl PgExecutor<'e>, age: i16) -> AppResult<Vec<RoomRow>> {
    Ok(sqlx::query_as::<_, RoomRow>("SELECT id, age, floor FROM house_rooms WHERE age = $1 ORDER BY floor")
        .bind(age)
        .fetch_all(executor)
        .await?)
}

pub async fn find_room<'e>(executor: impl PgExecutor<'e>, id: Uuid) -> AppResult<RoomRow> {
    sqlx::query_as::<_, RoomRow>("SELECT id, age, floor FROM house_rooms WHERE id = $1")
        .bind(id)
        .fetch_optional(executor)
        .await?
        .ok_or_else(|| AppError::not_found("そのおへやはありません"))
}

/// ?room= のおへや。省いたら今の年齢の 1 階、無ければ最近保存したおへや (起動時に少なくとも 1 つは作ってある)
pub async fn resolve_room(pool: &PgPool, id: Option<Uuid>) -> AppResult<RoomRow> {
    if let Some(id) = id {
        return find_room(pool, id).await;
    }
    let today = museum_api::child_birthday(pool).await?.map(|b| age::age_on(b, Local::now().date_naive()));
    sqlx::query_as::<_, RoomRow>(
        "SELECT id, age, floor FROM house_rooms ORDER BY (age = $1) DESC, floor ASC, updated_at DESC LIMIT 1",
    )
    .bind(today)
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| AppError::internal("おへやがありません"))
}

/// その年齢のいちばん上におへやを足す (家具は layout のまま。作品は入れない)
pub async fn create_room<'e>(executor: impl PgExecutor<'e>, age: i16, layout: &Layout) -> AppResult<RoomRow> {
    insert_room(executor, age, &without_artworks(layout)).await
}

/// 家具とテーマだけの配置
pub fn without_artworks(layout: &Layout) -> Layout {
    let mut layout = layout.clone();
    layout.objects.retain(|o| matches!(o, LayoutObject::Furniture(_)));
    layout
}

/// その年齢のいちばん上に、layout をそのまま持つおへやを足す (作品も入れたまま。artworks の列は呼ぶ側が合わせる)
async fn insert_room<'e>(executor: impl PgExecutor<'e>, age: i16, layout: &Layout) -> AppResult<RoomRow> {
    let room = sqlx::query_as::<_, RoomRow>(
        "INSERT INTO house_rooms (id, age, floor, layout, schema_version) \
         SELECT $1, $2, COALESCE(MAX(floor) + 1, 0), $3, $4 FROM house_rooms WHERE age = $2 \
         RETURNING id, age, floor",
    )
    .bind(Uuid::new_v4())
    .bind(age)
    .bind(JsonColumn(layout))
    .bind(SCHEMA_VERSION)
    .fetch_one(executor)
    .await?;
    if room.floor >= MAX_FLOORS {
        return Err(AppError::bad_request(format!("{} さいのおへやは {MAX_FLOORS} 個までです", room.age)));
    }
    Ok(room)
}

// =============================
// 読み書きの共通処理
// =============================

/// 保存されている配置を読む (ロックなし。表示用)
pub async fn load_layout(pool: &PgPool, room: RoomRow) -> AppResult<SavedLayout> {
    let (value, updated_at) = sqlx::query_as::<_, (Value, DateTime<Utc>)>(
        "SELECT layout, updated_at FROM house_rooms WHERE id = $1",
    )
    .bind(room.id)
    .fetch_one(pool)
    .await?;
    Ok(SavedLayout { room: room.info(), layout: read_saved(pool, value).await?, updated_at })
}

/// 配置 JSON に出てくる作品の実寸を読む (形の正しくない配置でも読む。直すときにも使うため)
async fn raw_sizes<'e>(executor: impl PgExecutor<'e>, raw: &Value) -> AppResult<Sizes> {
    Ok(sizes_of(&load_sizes(executor, &home::raw_artwork_ids(raw)).await?))
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

/// 家全体とおへやの行をロックして、保存されている JSON をそのまま返す
async fn lock_row(tx: &mut Transaction<'_, Postgres>, room: Uuid) -> AppResult<Value> {
    lock_house(tx).await?;
    sqlx::query_scalar::<_, Value>("SELECT layout FROM house_rooms WHERE id = $1 FOR UPDATE")
        .bind(room)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| AppError::not_found("そのおへやはありません"))
}

/// 家全体の書き込みロック。トランザクションが終わるまで、ほかの配置の書き込みは待たされる (同じトランザクションで何度取ってもよい)
pub async fn lock_house(tx: &mut Transaction<'_, Postgres>) -> AppResult<()> {
    sqlx::query("SELECT pg_advisory_xact_lock($1)").bind(HOUSE_LOCK).execute(&mut **tx).await?;
    Ok(())
}

/// 家全体をロックして、おへやの配置を読む
pub async fn lock_layout(tx: &mut Transaction<'_, Postgres>, room: Uuid) -> AppResult<Layout> {
    let value = lock_row(tx, room).await?;
    read_saved(&mut **tx, value).await
}

/// 配置を保存する。`lock_layout` したトランザクションの中で呼ぶ。
///
/// 形の検証 → 作品が存在するか・おへやの年齢の作品かの確認 (作品の実寸も読む) → 位置の検証 (出入口の前は doors の物だけ) →
/// artworks.slot_id / house_room_id / displayed_at を配置に合わせる → JSONB に書く (schema_version も今の版にする)。
/// このおへやに飾っていたのに配置に無い作品は未展示 (slot_id・house_room_id = NULL) になる。ほかのおへやの作品は触らない
pub async fn save_layout(
    tx: &mut Transaction<'_, Postgres>,
    room: RoomRow,
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
    check_ages(tx, room, &artwork_ids).await?;
    home::check_placement(&layout, &sizes_of(&rows), doors).map_err(AppError::bad_request)?;

    // このおへやから外れた作品は未展示に戻す
    sqlx::query(
        "UPDATE artworks SET slot_id = NULL, displayed_at = NULL, house_room_id = NULL, updated_at = NOW() \
         WHERE house_room_id = $1 AND id <> ALL($2)",
    )
    .bind(room.id)
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
         SET slot_id = v.slot, house_room_id = $3, displayed_at = COALESCE(a.displayed_at, NOW()), updated_at = NOW() \
         FROM unnest($1::uuid[], $2::text[]) AS v(id, slot) \
         WHERE a.id = v.id AND (a.slot_id IS DISTINCT FROM v.slot OR a.house_room_id IS DISTINCT FROM $3)",
    )
    .bind(&artwork_ids)
    .bind(&slot_ids)
    .bind(room.id)
    .execute(&mut **tx)
    .await?;

    let updated_at: DateTime<Utc> = sqlx::query_scalar(
        "UPDATE house_rooms SET layout = $2, schema_version = $3, updated_at = NOW() WHERE id = $1 RETURNING updated_at",
    )
    .bind(room.id)
    .bind(JsonColumn(&layout))
    .bind(SCHEMA_VERSION)
    .fetch_one(&mut **tx)
    .await?;

    Ok(SavedLayout { room: room.info(), layout, updated_at })
}

/// 作品の年齢 (作ったときの年齢) を読む
pub async fn artwork_ages<'e>(
    executor: impl PgExecutor<'e>,
    birthday: Option<NaiveDate>,
    ids: &[Uuid],
) -> AppResult<HashMap<Uuid, (String, i16)>> {
    let rows = sqlx::query_as::<_, (Uuid, String, NaiveDate, Option<i16>)>(
        "SELECT id, title, made_on, age FROM artworks WHERE id = ANY($1)",
    )
    .bind(ids)
    .fetch_all(executor)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, title, made_on, manual)| (id, (title, age::artwork_age(birthday, made_on, manual))))
        .collect())
}

/// おへやに置く作品が、どれもそのおへやの年齢の作品か
async fn check_ages(tx: &mut Transaction<'_, Postgres>, room: RoomRow, ids: &[Uuid]) -> AppResult<()> {
    let birthday = museum_api::child_birthday(&mut **tx).await?;
    let ages = artwork_ages(&mut **tx, birthday, ids).await?;
    if let Some((title, age)) = ages.values().find(|(_, age)| *age != room.age) {
        return Err(AppError::bad_request(format!(
            "「{title}」は {age} さいのときの作品なので、{} には飾れません",
            room.name()
        )));
    }
    Ok(())
}

/// 作品を、その年齢のおへやの空いている所に飾る (下の階から探す)。その年齢のおへやが 1 つも無ければ 1 階を作る。
/// どのおへやもいっぱいなら None。作品がいまほかのおへやにあれば、先に外しておくこと
pub async fn place_in_age(
    tx: &mut Transaction<'_, Postgres>,
    artwork_id: Uuid,
    size: Option<&ArtSize>,
    age: i16,
) -> AppResult<Option<SavedLayout>> {
    let mut rooms = rooms_of_age(&mut **tx, age).await?;
    if rooms.is_empty() {
        rooms.push(create_room(&mut **tx, age, &home::default_layout()).await?);
    }
    for room in rooms {
        let mut layout = lock_layout(tx, room.id).await?;
        if layout.artwork_for(artwork_id).is_some() {
            return Ok(Some(SavedLayout { room: room.info(), layout, updated_at: Utc::now() }));
        }
        let ids: Vec<Uuid> = layout.artworks().map(|a| a.artwork_id).collect();
        let sizes = sizes_of(&load_sizes(&mut **tx, &ids).await?);
        if let Some(spot) = home::pick_spot(&layout, &sizes, size, None, None) {
            layout.objects.push(home::artwork_on(artwork_id, spot));
            // 家具の上にだけ置くので、出入口の前は見ない
            return Ok(Some(save_layout(tx, room, layout, DoorPolicy::Ignore).await?));
        }
    }
    Ok(None)
}

// =============================
// API
// =============================

pub async fn get_layout(State(state): State<AppState>, Query(query): Query<RoomQuery>) -> AppResult<Json<SavedLayout>> {
    let room = resolve_room(&state.pool, query.room).await?;
    Ok(Json(load_layout(&state.pool, room).await?))
}

/// 模様替えの保存。後から保存したほうが勝つ
pub async fn put_layout(
    State(state): State<AppState>,
    Query(query): Query<RoomQuery>,
    body: Bytes,
) -> AppResult<Json<SavedLayout>> {
    let body: PutBody = serde_json::from_slice(&body)
        .map_err(|e| AppError::bad_request(format!("送信データを読み取れません: {e}")))?;
    // 形の間違いはここで返す。位置 (作品の実寸を使う) は save_layout で検証する
    let layout = home::parse_layout(body.layout).map_err(AppError::bad_request)?;
    let room = resolve_room(&state.pool, query.room).await?;

    let mut tx = state.pool.begin().await?;
    // 保存されている配置は上書きする。比べるのは、出入口の前を見る「新しく置いた物・動かした物」を決めるためだけ。
    // 保存済みの配置が読めなければ (形が違うなど)、すべての物を動かした物として見る
    let raw = lock_row(&mut tx, room.id).await?;
    let moved = match home::parse_layout(raw) {
        Ok(stored) => home::moved_ids(&stored, &layout),
        Err(_) => layout.objects.iter().map(|o| o.id().to_string()).collect(),
    };
    let saved = save_layout(&mut tx, room, layout, DoorPolicy::OnlyMoved(&moved)).await?;
    tx.commit().await?;

    println!("[Home] {} saved ({} objects)", room.name(), saved.layout.objects.len());
    Ok(Json(saved))
}

// =============================
// 起動時の処理
// =============================

/// おへやの用意。house_rooms が空なら (このマイグレーションを入れて初めての起動)、今までの配置 (home_layout) の家具とテーマで、
/// 飾っている作品のある年齢と今の年齢の 1 階を作る (作品はこのあとの reconcile で置き直す)。
/// そのあと、どのおへやの配置も今の版に上げ、読めない作品があれば外して保存し直す。家具や部屋がおかしくて直せないおへやは初期配置に戻す
pub async fn ensure_rooms(state: &AppState) -> AppResult<()> {
    let birthday = museum_api::child_birthday(&state.pool).await?;
    if all_rooms(&state.pool).await?.is_empty() {
        // 今までの配置を年齢ごとに分ける。どのおへやも同じ家具とテーマで、作品はその年齢の物だけを同じ位置のまま入れる
        // (置いてある配置から作品を抜くだけなので、どのおへやも置き方の決まりに通る)
        let legacy = legacy_layout(&state.pool).await?;
        let ids: Vec<Uuid> = legacy.artworks().map(|a| a.artwork_id).collect();
        let ages_of = artwork_ages(&state.pool, birthday, &ids).await?;
        let mut ages: Vec<i16> = ages_of.values().map(|(_, a)| *a).collect();
        ages.push(birthday.map_or(0, |b| age::age_on(b, Local::now().date_naive())));
        ages.sort();
        ages.dedup();
        let mut tx = state.pool.begin().await?;
        lock_house(&mut tx).await?;
        for &a in &ages {
            let mut layout = legacy.clone();
            layout.objects.retain(|o| match o {
                LayoutObject::Artwork(art) => ages_of.get(&art.artwork_id).is_some_and(|(_, age)| *age == a),
                LayoutObject::Furniture(_) => true,
            });
            let room = insert_room(&mut *tx, a, &layout).await?;
            // 作品の house_room_id を合わせる (位置はそのまま)
            save_layout(&mut tx, room, layout, DoorPolicy::Ignore).await?;
        }
        tx.commit().await?;
        println!(
            "[Home] 今までの配置をおへやに分けました ({} さい。家具・テーマ・作品の位置はそのまま)",
            ages.iter().map(i16::to_string).collect::<Vec<_>>().join("・")
        );
    }

    let rooms = all_rooms(&state.pool).await?;
    let mut upgraded = 0;
    for room in &rooms {
        let mut tx = state.pool.begin().await?;
        let (raw, column_version) = sqlx::query_as::<_, (Value, i16)>(
            "SELECT layout, schema_version FROM house_rooms WHERE id = $1 FOR UPDATE",
        )
        .bind(room.id)
        .fetch_one(&mut *tx)
        .await?;
        let json_version = home::raw_schema_version(&raw);
        let sizes = raw_sizes(&mut *tx, &raw).await?;
        let (layout, repaired) = match check_saved(raw.clone(), &sizes) {
            Ok(layout) => (layout, false),
            Err(error) => match home::repair_layout(raw, &sizes) {
                Ok((layout, dropped)) => {
                    println!("[Home] {} の置けない作品 {} 点 ({}) を外します ({error})", room.name(), dropped.len(), dropped.join(", "));
                    (layout, true)
                }
                Err(_) => {
                    println!("[Home] {} の配置が読めないので、初期配置に戻します ({error})", room.name());
                    (home::default_layout(), true)
                }
            },
        };
        let old = json_version.is_some_and(|v| v < u64::from(home::SCHEMA_VERSION));
        if repaired || old || column_version != SCHEMA_VERSION {
            // artworks.slot_id はそのままにしておき、このあとの reconcile で置き直す
            sqlx::query("UPDATE house_rooms SET layout = $2, schema_version = $3, updated_at = NOW() WHERE id = $1")
                .bind(room.id)
                .bind(JsonColumn(&layout))
                .bind(SCHEMA_VERSION)
                .execute(&mut *tx)
                .await?;
            upgraded += 1;
        }
        tx.commit().await?;
    }
    println!("[Home] rooms loaded ({} rooms{})", rooms.len(), if upgraded > 0 { format!(", {upgraded} saved again") } else { String::new() });
    Ok(())
}

/// 今までの 1 つだけの配置 (home_layout。v4 までなら v5 に上げる)。置けない作品は外す。行が無いか読めなければ初期配置
async fn legacy_layout(pool: &PgPool) -> AppResult<Layout> {
    let Some(raw) = sqlx::query_scalar::<_, Value>("SELECT layout FROM home_layout WHERE id = 1")
        .fetch_optional(pool)
        .await?
    else {
        return Ok(home::default_layout());
    };
    let sizes = raw_sizes(pool, &raw).await?;
    Ok(match check_saved(raw.clone(), &sizes) {
        Ok(layout) => layout,
        Err(_) => home::repair_layout(raw, &sizes).map(|(layout, _)| layout).unwrap_or_else(|_| home::default_layout()),
    })
}

/// 作品 1 つの、起動時の整理に使う値
#[derive(Debug, Clone)]
pub struct ArtState {
    pub id: Uuid,
    /// 作ったときの年齢
    pub age: i16,
    /// 飾っている (slot_id がある) か
    pub displayed: bool,
    pub slot_id: Option<String>,
    pub room_id: Option<Uuid>,
}

/// 起動時の整理の結果
#[derive(Debug, Default, PartialEq)]
pub struct Reconciled {
    /// 書き直すおへや
    pub changed: HashSet<Uuid>,
    /// おへやから外した作品の数 (消えた作品・年齢の合わない作品・2 か所にある作品)
    pub removed: usize,
    /// 置き直した作品の数
    pub relocated: usize,
    /// 飾っていたのに置けなかった作品 (未展示に戻す)
    pub unplaced: Vec<Uuid>,
}

/// おへやの配置と作品のずれを直す (DB を使わない)。rooms は年齢・階の順。
///
/// 1. どのおへやからも、消えた作品・年齢の合わない作品・ほかのおへやと 2 か所にある作品 (下の階を残す) を外す
/// 2. 飾っている (slot_id がある) のにどのおへやにも無い作品を、その年齢のおへやの空いている所へ、下の階から置く。
///    その年齢のおへやが無いか、どこもいっぱいなら unplaced
/// 3. 作品の slot_id・house_room_id が配置と違うおへやも書き直す (save_layout で合わせる)
pub fn reconcile_rooms(rooms: &mut [(RoomRow, Layout)], arts: &[ArtState], sizes: &Sizes) -> Reconciled {
    let by_id: HashMap<Uuid, &ArtState> = arts.iter().map(|a| (a.id, a)).collect();
    let mut result = Reconciled::default();
    let mut placed: HashSet<Uuid> = HashSet::new();

    for (room, layout) in rooms.iter_mut() {
        let before = layout.objects.len();
        layout.objects.retain(|o| match o {
            LayoutObject::Artwork(a) => {
                by_id.get(&a.artwork_id).is_some_and(|art| art.age == room.age) && placed.insert(a.artwork_id)
            }
            LayoutObject::Furniture(_) => true,
        });
        if layout.objects.len() != before {
            result.removed += before - layout.objects.len();
            result.changed.insert(room.id);
        }
        let out_of_sync = layout.artworks().any(|a| {
            let art = by_id[&a.artwork_id];
            art.slot_id.as_deref() != Some(a.id.as_str()) || art.room_id != Some(room.id)
        });
        if out_of_sync {
            result.changed.insert(room.id);
        }
    }

    // 先に飾った作品から順に置き直す (arts はその順)
    for art in arts.iter().filter(|a| a.displayed && !placed.contains(&a.id)) {
        let spot = rooms.iter_mut().filter(|(room, _)| room.age == art.age).find_map(|(room, layout)| {
            home::pick_spot(layout, sizes, sizes.get(&art.id), None, None).map(|spot| (room.id, layout, spot))
        });
        match spot {
            Some((room_id, layout, spot)) => {
                layout.objects.push(home::artwork_on(art.id, spot));
                result.changed.insert(room_id);
                result.relocated += 1;
            }
            None => result.unplaced.push(art.id),
        }
    }
    // 飾っていないのにおへやを指している作品も、未展示に揃える
    result.unplaced.extend(arts.iter().filter(|a| !a.displayed && a.room_id.is_some()).map(|a| a.id));
    result
}

/// 起動時 (と誕生日を変えたとき) に、おへやの配置と作品のずれを直す (reconcile_rooms)。
/// 飾っている作品の年齢のおへやが無ければ、先にその年齢の 1 階を作る
pub async fn reconcile(state: &AppState) -> AppResult<()> {
    let mut tx = state.pool.begin().await?;
    lock_house(&mut tx).await?;
    let birthday = museum_api::child_birthday(&mut *tx).await?;

    // 先に飾った作品から順に
    let rows: Vec<(Uuid, Option<String>, Option<Uuid>, NaiveDate, Option<i16>, Option<f64>, Option<f64>, Option<f64>, String)> =
        sqlx::query_as(
            "SELECT id, slot_id, house_room_id, made_on, age, model_width, model_height, model_depth, model_kind FROM artworks \
             ORDER BY displayed_at ASC NULLS LAST, created_at ASC",
        )
        .fetch_all(&mut *tx)
        .await?;
    let sizes: Sizes = rows
        .iter()
        .filter_map(|(id, _, _, _, _, w, h, d, kind)| ArtSize::from_model(*w, *h, *d, kind).map(|s| (*id, s)))
        .collect();
    let arts: Vec<ArtState> = rows
        .into_iter()
        .map(|(id, slot_id, room_id, made_on, manual, ..)| ArtState {
            id,
            age: age::artwork_age(birthday, made_on, manual),
            displayed: slot_id.is_some(),
            slot_id,
            room_id,
        })
        .collect();

    // 飾っている作品の年齢で、おへやの無い年齢には 1 階を作る
    let mut have: HashSet<i16> = all_rooms(&mut *tx).await?.iter().map(|r| r.age).collect();
    for art in arts.iter().filter(|a| a.displayed) {
        if have.insert(art.age) {
            create_room(&mut *tx, art.age, &home::default_layout()).await?;
        }
    }

    // 全部のおへやを年齢・階の順にロックして読む
    let mut rooms = Vec::new();
    for room in all_rooms(&mut *tx).await? {
        let layout = lock_layout(&mut tx, room.id).await?;
        rooms.push((room, layout));
    }

    let result = reconcile_rooms(&mut rooms, &arts, &sizes);
    for (room, layout) in rooms {
        if result.changed.contains(&room.id) {
            // 起動時の整理なので出入口の前は見ない (置き直す作品は家具の上だけ)
            save_layout(&mut tx, room, layout, DoorPolicy::Ignore).await?;
        }
    }
    if !result.unplaced.is_empty() {
        sqlx::query(
            "UPDATE artworks SET slot_id = NULL, displayed_at = NULL, house_room_id = NULL, updated_at = NOW() \
             WHERE id = ANY($1)",
        )
        .bind(&result.unplaced)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;

    println!(
        "[Home] reconcile: relocated {}, unplaced {}, removed {}{}",
        result.relocated,
        result.unplaced.len(),
        result.removed,
        if result.changed.is_empty() { " (no changes)" } else { " (saved)" }
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn room(age: i16, floor: i16) -> RoomRow {
        RoomRow { id: Uuid::from_u128(((age as u128) << 8) | floor as u128), age, floor }
    }

    /// 飾り棚 1 つ (置き場所 2) のおへや
    fn shelf_room() -> Layout {
        home::validate_layout(json!({
            "schemaVersion": home::SCHEMA_VERSION,
            "kitVersion": home::KIT_VERSION,
            "rooms": { "hub": { "enabled": true, "width": 10, "depth": 10, "wall": "plaster", "floor": "oak" } },
            "objects": [{ "kind": "furniture", "id": "shelf", "assetId": "home_display_shelf", "roomId": "hub", "position": [0, 0, 0], "rotationY": 0 }],
        }))
        .unwrap()
    }

    fn art(n: u128, age: i16) -> ArtState {
        ArtState { id: Uuid::from_u128(n), age, displayed: true, slot_id: None, room_id: None }
    }

    #[test]
    fn names_rooms_by_age_and_floor() {
        assert_eq!(room_name(4, 0), "4さいのおへや");
        assert_eq!(room_name(4, 1), "4さいのおへや 2");
    }

    #[test]
    fn places_artworks_in_rooms_of_their_age_from_the_bottom() {
        let mut rooms = vec![(room(3, 0), shelf_room()), (room(4, 0), shelf_room()), (room(4, 1), shelf_room())];
        // 4さいの作品 3 点 (1 階に 2 点、2 階に 1 点)、3さいの作品 1 点、おへやの無い 5さいの作品 1 点
        let arts = vec![art(1, 4), art(2, 4), art(3, 4), art(4, 3), art(5, 5)];
        let result = reconcile_rooms(&mut rooms, &arts, &Sizes::new());
        let count = |i: usize| rooms[i].1.artworks().count();
        assert_eq!((count(0), count(1), count(2)), (1, 2, 1));
        assert!(rooms[1].1.artwork_for(Uuid::from_u128(1)).is_some() && rooms[2].1.artwork_for(Uuid::from_u128(3)).is_some());
        assert_eq!(result.relocated, 4);
        assert_eq!(result.unplaced, vec![Uuid::from_u128(5)]);
        assert_eq!(result.changed.len(), 3);
    }

    #[test]
    fn removes_artworks_of_another_age_and_duplicates() {
        let mut first = shelf_room();
        let spot = home::pick_spot(&first, &Sizes::new(), None, None, None).unwrap();
        first.objects.push(home::artwork_on(Uuid::from_u128(1), spot));
        let mut rooms = vec![(room(4, 0), first.clone()), (room(4, 1), first), (room(5, 0), shelf_room())];
        // 誕生日を変えて 5さいの作品になった (4さいの 1 階・2 階の両方にあった)
        let mut moved = art(1, 5);
        moved.slot_id = rooms[0].1.artworks().next().map(|a| a.id.clone());
        moved.room_id = Some(rooms[0].0.id);
        let result = reconcile_rooms(&mut rooms, &[moved], &Sizes::new());
        assert_eq!(result.removed, 2);
        assert_eq!(result.relocated, 1);
        assert!(rooms[2].1.artwork_for(Uuid::from_u128(1)).is_some());
        assert_eq!(rooms[0].1.artworks().count() + rooms[1].1.artworks().count(), 0);

        // 年齢が合っていて 2 か所にあれば、下の階を残す
        let mut first = shelf_room();
        let spot = home::pick_spot(&first, &Sizes::new(), None, None, None).unwrap();
        first.objects.push(home::artwork_on(Uuid::from_u128(1), spot));
        let mut rooms = vec![(room(4, 0), first.clone()), (room(4, 1), first)];
        let result = reconcile_rooms(&mut rooms, &[art(1, 4)], &Sizes::new());
        assert_eq!((rooms[0].1.artworks().count(), rooms[1].1.artworks().count()), (1, 0));
        assert_eq!((result.removed, result.relocated), (1, 0));
    }

    #[test]
    fn leaves_rooms_alone_when_in_sync() {
        let mut layout = shelf_room();
        let spot = home::pick_spot(&layout, &Sizes::new(), None, None, None).unwrap();
        layout.objects.push(home::artwork_on(Uuid::from_u128(1), spot));
        let object_id = layout.artworks().next().unwrap().id.clone();
        let mut rooms = vec![(room(4, 0), layout)];
        let mut synced = art(1, 4);
        synced.slot_id = Some(object_id);
        synced.room_id = Some(rooms[0].0.id);
        // 飾っていないのにおへやを指している作品は未展示に揃える
        let stray = ArtState { id: Uuid::from_u128(2), age: 4, displayed: false, slot_id: None, room_id: Some(rooms[0].0.id) };
        let result = reconcile_rooms(&mut rooms, &[synced, stray], &Sizes::new());
        assert!(result.changed.is_empty());
        assert_eq!(result.unplaced, vec![Uuid::from_u128(2)]);
    }
}
