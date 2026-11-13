//! 年齢ごとのおへや (house_rooms) の配置 API と、配置を保存する共通の処理。
//!
//! おへやは 1 行に 1 つの配置 JSON (schemaVersion 5。リビング hub 1 部屋の家具と作品) を持つ。
//! 作品は、作ったときの年齢 (crate::age) のおへやにだけ飾る。artworks.house_room_id が飾っているおへや、
//! artworks.slot_id がそのおへやの配置の中の作品の object id。
//!
//! 配置を変える処理 (模様替えの保存・作品を飾る / 外す / 消す・起動時の整理・seed) は、
//! どれも 1 つのトランザクション (Db::tx) の中で `lock_layout` → 変更 → `save_layout` の順に行う。
//! Durable Object の SQL は同期で動き、その間にほかの要求は割り込まないので、backend の家全体のロック (lock_house) は要らない。
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
use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::{
    age,
    artworks::{load_sizes, sizes_of},
    db::{self, json, uuid_list, Db},
    error::{AppError, AppResult},
    home::{self, ArtSize, DoorPolicy, Layout, LayoutObject, Sizes},
    museum_api, now_sql, params,
    state::{today, AppState},
};

/// house_rooms.schema_version に書く値 (配置 JSON の schemaVersion と同じ)
const SCHEMA_VERSION: i16 = home::SCHEMA_VERSION as i16;

/// 1 つの年齢に積み上げられるおへやの数
pub const MAX_FLOORS: i16 = 10;

// =============================
// おへや
// =============================

/// おへや 1 つ (配置は別に読む)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
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
pub fn all_rooms(db: &Db) -> AppResult<Vec<RoomRow>> {
    db.all("SELECT id, age, floor FROM house_rooms ORDER BY age, floor", params![])
}

/// おへやの id → 名前 (作品の「飾っているおへや」を出すため)
pub fn room_names(db: &Db) -> AppResult<HashMap<Uuid, String>> {
    Ok(all_rooms(db)?.iter().map(|r| (r.id, r.name())).collect())
}

/// ある年齢のおへや (階の順)
pub fn rooms_of_age(db: &Db, age: i16) -> AppResult<Vec<RoomRow>> {
    db.all("SELECT id, age, floor FROM house_rooms WHERE age = ?1 ORDER BY floor", params![age])
}

pub fn find_room(db: &Db, id: Uuid) -> AppResult<RoomRow> {
    db.opt::<RoomRow>("SELECT id, age, floor FROM house_rooms WHERE id = ?1", params![id])?
        .ok_or_else(|| AppError::not_found("そのおへやはありません"))
}

/// ?room= のおへや。省いたら今の年齢の 1 階、無ければ最近保存したおへや (起動時に少なくとも 1 つは作ってある)
pub fn resolve_room(db: &Db, id: Option<Uuid>) -> AppResult<RoomRow> {
    if let Some(id) = id {
        return find_room(db, id);
    }
    let today = museum_api::child_birthday(db)?.map(|b| age::age_on(b, today()));
    // 誕生日が無ければ (age = NULL) は NULL になるので、並べ替えでは 0 として扱う
    db.opt::<RoomRow>(
        "SELECT id, age, floor FROM house_rooms ORDER BY COALESCE(age = ?1, 0) DESC, floor ASC, updated_at DESC LIMIT 1",
        params![today],
    )?
    .ok_or_else(|| AppError::internal("おへやがありません"))
}

/// その年齢のいちばん上におへやを足す (家具は layout のまま。作品は入れない)
pub fn create_room(db: &Db, age: i16, layout: &Layout) -> AppResult<RoomRow> {
    insert_room(db, age, &without_artworks(layout))
}

/// 家具とテーマだけの配置
pub fn without_artworks(layout: &Layout) -> Layout {
    let mut layout = layout.clone();
    layout.objects.retain(|o| matches!(o, LayoutObject::Furniture(_)));
    layout
}

/// その年齢のいちばん上に、layout をそのまま持つおへやを足す (作品も入れたまま。artworks の列は呼ぶ側が合わせる)
fn insert_room(db: &Db, age: i16, layout: &Layout) -> AppResult<RoomRow> {
    let room: RoomRow = db.one(
        "INSERT INTO house_rooms (id, age, floor, layout, schema_version) \
         SELECT ?1, ?2, COALESCE(MAX(floor) + 1, 0), ?3, ?4 FROM house_rooms WHERE age = ?2 \
         RETURNING id, age, floor",
        vec![db::ToVal::to_val(&Uuid::new_v4()), db::ToVal::to_val(&age), json(layout)?, db::ToVal::to_val(&SCHEMA_VERSION)],
    )?;
    if room.floor >= MAX_FLOORS {
        return Err(AppError::bad_request(format!("{} さいのおへやは {MAX_FLOORS} 個までです", room.age)));
    }
    Ok(room)
}

// =============================
// 読み書きの共通処理
// =============================

/// 保存されている配置を読む (ロックなし。表示用)
pub fn load_layout(db: &Db, room: RoomRow) -> AppResult<SavedLayout> {
    let (value, updated_at): (String, DateTime<Utc>) =
        db.tuples("SELECT layout, updated_at FROM house_rooms WHERE id = ?1", params![room.id])?
            .into_iter()
            .next()
            .ok_or_else(|| AppError::not_found("そのおへやはありません"))?;
    Ok(SavedLayout { room: room.info(), layout: read_saved(db, parse_json(&value)?)?, updated_at })
}

/// 保存されている配置 JSON (文字列) を読む
fn parse_json(text: &str) -> AppResult<Value> {
    serde_json::from_str(text).map_err(|e| AppError::internal(format!("保存されている配置が読めません: {e}")))
}

/// 配置 JSON に出てくる作品の実寸を読む (形の正しくない配置でも読む。直すときにも使うため)
fn raw_sizes(db: &Db, raw: &Value) -> AppResult<Sizes> {
    Ok(sizes_of(&load_sizes(db, &home::raw_artwork_ids(raw))?))
}

/// 配置 JSON を作品の実寸で検証する (保存済みの配置なので、出入口の前は見ない)
fn check_saved(raw: Value, sizes: &Sizes) -> Result<Layout, String> {
    let layout = home::parse_layout(raw)?;
    home::check_placement(&layout, sizes, DoorPolicy::Ignore)?;
    Ok(layout)
}

/// 保存されている JSON を配置にする。検証に通らなければ (別の版のサーバーが保存したときなど)、
/// 置けない作品だけを外した配置にする。ここでは書き込まない (外した作品は次の起動の reconcile で置き直される)
fn read_saved(db: &Db, value: Value) -> AppResult<Layout> {
    let sizes = raw_sizes(db, &value)?;
    match check_saved(value.clone(), &sizes) {
        Ok(layout) => Ok(layout),
        Err(error) => {
            let (layout, dropped) = home::repair_layout(value, &sizes)
                .map_err(|_| AppError::internal(format!("保存されている配置が読めません: {error}")))?;
            worker::console_log!("[Home] 置けない作品 {} 点 ({}) を外して配置を読みました ({error})", dropped.len(), dropped.join(", "));
            Ok(layout)
        }
    }
}

/// 保存されている JSON をそのまま返す
fn lock_row(db: &Db, room: Uuid) -> AppResult<Value> {
    let text = db
        .scalar::<String>("SELECT layout FROM house_rooms WHERE id = ?1", params![room])?
        .ok_or_else(|| AppError::not_found("そのおへやはありません"))?;
    parse_json(&text)
}

/// おへやの配置を読む (backend では家全体のロックも取る。Durable Object では要らない)
pub fn lock_layout(db: &Db, room: Uuid) -> AppResult<Layout> {
    let value = lock_row(db, room)?;
    read_saved(db, value)
}

/// 配置を保存する。`lock_layout` したトランザクションの中で呼ぶ。
///
/// 形の検証 → 作品が存在するか・おへやの年齢の作品かの確認 (作品の実寸も読む) → 位置の検証 (出入口の前は doors の物だけ) →
/// artworks.slot_id / house_room_id / displayed_at を配置に合わせる → JSONB に書く (schema_version も今の版にする)。
/// このおへやに飾っていたのに配置に無い作品は未展示 (slot_id・house_room_id = NULL) になる。ほかのおへやの作品は触らない
pub fn save_layout(db: &Db, room: RoomRow, layout: Layout, doors: DoorPolicy<'_>) -> AppResult<SavedLayout> {
    // コードで組み立てた配置もここで検証し直し、DB には正規化した配置だけを書く
    let value = serde_json::to_value(&layout).map_err(AppError::internal)?;
    let layout = home::parse_layout(value).map_err(AppError::bad_request)?;

    let (artwork_ids, slot_ids): (Vec<Uuid>, Vec<String>) =
        layout.artworks().map(|a| (a.artwork_id, a.id.clone())).unzip();

    // 同じ作品が 2 か所にあるときは、このあとの位置の検証で「2 か所に置かれています」にする
    let unique: HashSet<Uuid> = artwork_ids.iter().copied().collect();
    let rows = load_sizes(db, &artwork_ids)?;
    if rows.len() != unique.len() {
        return Err(AppError::bad_request("配置に、登録されていない作品が含まれています"));
    }
    check_ages(db, room, &artwork_ids)?;
    home::check_placement(&layout, &sizes_of(&rows), doors).map_err(AppError::bad_request)?;

    // このおへやから外れた作品は未展示に戻す
    db.exec(
        concat!(
            "UPDATE artworks SET slot_id = NULL, displayed_at = NULL, house_room_id = NULL, updated_at = ", now_sql!(), " \
             WHERE house_room_id = ?1 AND id NOT IN (SELECT value FROM json_each(?2))"
        ),
        vec![db::ToVal::to_val(&room.id), uuid_list(&artwork_ids)],
    )?;

    // 作品 id と object id の組 ([[id, slot], …])
    let pairs: Vec<(Uuid, &str)> = artwork_ids.iter().copied().zip(slot_ids.iter().map(String::as_str)).collect();
    let pairs = json(&pairs)?;
    const PAIRS: &str = "(SELECT json_extract(value, '$[0]') AS id, json_extract(value, '$[1]') AS slot FROM json_each(?1))";

    // 置き場所が変わる作品は、先に slot_id を外しておく (入れ替えで UNIQUE に当たらないように)
    db.exec(
        &format!(
            "UPDATE artworks AS a SET slot_id = NULL FROM {PAIRS} AS v \
             WHERE a.id = v.id AND a.slot_id IS NOT NULL AND a.slot_id <> v.slot"
        ),
        vec![db::ToVal::to_val(&pairs)],
    )?;

    // slot_id = 配置の object id。飾り始めた日時 (displayed_at) は移動しても変えない
    db.exec(
        &format!(
            "UPDATE artworks AS a \
             SET slot_id = v.slot, house_room_id = ?2, displayed_at = COALESCE(a.displayed_at, {now}), updated_at = {now} \
             FROM {PAIRS} AS v \
             WHERE a.id = v.id AND (a.slot_id IS NOT v.slot OR a.house_room_id IS NOT ?2)",
            now = now_sql!()
        ),
        vec![db::ToVal::to_val(&pairs), db::ToVal::to_val(&room.id)],
    )?;

    let updated_at: DateTime<Utc> = db
        .scalar(
            concat!(
                "UPDATE house_rooms SET layout = ?2, schema_version = ?3, updated_at = ", now_sql!(), " WHERE id = ?1 RETURNING updated_at"
            ),
            vec![db::ToVal::to_val(&room.id), json(&layout)?, db::ToVal::to_val(&SCHEMA_VERSION)],
        )?
        .ok_or_else(|| AppError::not_found("そのおへやはありません"))?;

    Ok(SavedLayout { room: room.info(), layout, updated_at })
}

/// 作品の年齢 (作ったときの年齢) を読む
pub fn artwork_ages(db: &Db, birthday: Option<NaiveDate>, ids: &[Uuid]) -> AppResult<HashMap<Uuid, (String, i16)>> {
    let rows: Vec<(Uuid, String, NaiveDate, Option<i16>)> = db.tuples(
        "SELECT id, title, made_on, age FROM artworks WHERE id IN (SELECT value FROM json_each(?1))",
        vec![uuid_list(ids)],
    )?;
    Ok(rows
        .into_iter()
        .map(|(id, title, made_on, manual)| (id, (title, age::artwork_age(birthday, made_on, manual))))
        .collect())
}

/// おへやに置く作品が、どれもそのおへやの年齢の作品か
fn check_ages(db: &Db, room: RoomRow, ids: &[Uuid]) -> AppResult<()> {
    let birthday = museum_api::child_birthday(db)?;
    let ages = artwork_ages(db, birthday, ids)?;
    if let Some((title, age)) = ages.values().find(|(_, age)| *age != room.age) {
        return Err(AppError::bad_request(format!(
            "「{title}」は {age} さいのときの作品なので、{} には飾れません",
            room.name()
        )));
    }
    Ok(())
}

/// 作品を、その年齢のおへやの空いている所に飾る (下の階から探す)。その年齢のおへやが 1 つも無ければ 1 階を作る。
/// どのおへやもいっぱいなら None。家具は足さない (起動時のサンプルの登録 seed が使う。利用者が飾るときは place_in_age)。
/// 作品がいまほかのおへやにあれば、先に外しておくこと
fn place_in_free_spot(db: &Db, artwork_id: Uuid, size: Option<&ArtSize>, age: i16) -> AppResult<Option<SavedLayout>> {
    let mut rooms = rooms_of_age(db, age)?;
    if rooms.is_empty() {
        rooms.push(create_room(db, age, &home::default_layout())?);
    }
    for room in rooms {
        let mut layout = lock_layout(db, room.id)?;
        if layout.artwork_for(artwork_id).is_some() {
            return Ok(Some(SavedLayout { room: room.info(), layout, updated_at: Utc::now() }));
        }
        let ids: Vec<Uuid> = layout.artworks().map(|a| a.artwork_id).collect();
        let sizes = sizes_of(&load_sizes(db, &ids)?);
        if let Some(object) = home::pick_place(&layout, &sizes, artwork_id, size, None) {
            layout.objects.push(object);
            // 家具の上か壁に置くので、出入口の前は見ない
            return Ok(Some(save_layout(db, room, layout, DoorPolicy::Ignore)?));
        }
    }
    Ok(None)
}

/// 作品を、その年齢のおへやに飾る (利用者が飾るとき・作品を登録したとき)。その年齢のおへやが 1 つも無ければ 1 階を作る。
///
/// 1. 下の階から、今ある家具や壁の空いている所 (home::pick_place)
/// 2. どのおへやにも空きが無ければ、下の階から、家具を 1 つ足してその上に置けるおへや (home::place_on_new_furniture)。
///    おへやの数は増やさず、1 つのおへやに家具を足して詰める
///
/// どちらもできなければ None (階は足さない。利用者が「おへやを足す」で足す)。作品がいまほかのおへやにあれば、先に外しておくこと
pub fn place_in_age(db: &Db, artwork_id: Uuid, size: Option<&ArtSize>, age: i16) -> AppResult<Option<SavedLayout>> {
    let mut rooms = rooms_of_age(db, age)?;
    if rooms.is_empty() {
        rooms.push(create_room(db, age, &home::default_layout())?);
    }
    // 1. 今ある空き
    for &room in &rooms {
        let mut layout = lock_layout(db, room.id)?;
        if layout.artwork_for(artwork_id).is_some() {
            return Ok(Some(SavedLayout { room: room.info(), layout, updated_at: Utc::now() }));
        }
        // 物の数の上限に達したおへやは、空きがあっても保存できない (400 になる) ので飛ばす
        if !home::has_room_for(&layout, 1) {
            continue;
        }
        let sizes = layout_sizes(db, &layout)?;
        if let Some(object) = home::pick_place(&layout, &sizes, artwork_id, size, None) {
            layout.objects.push(object);
            // 家具の上か壁に置くので、出入口の前は見ない
            return Ok(Some(save_layout(db, room, layout, DoorPolicy::Ignore)?));
        }
    }
    // 2. 家具を足す
    for room in rooms {
        let mut layout = lock_layout(db, room.id)?;
        let sizes = layout_sizes(db, &layout)?;
        let Some((furniture, artwork)) = home::place_on_new_furniture(&layout, &sizes, artwork_id, size) else {
            continue;
        };
        let name = furniture_name(&furniture);
        // 足した家具と作品は新しく置いた物なので、出入口の前も見る (place_on_new_furniture も同じ決まりで探している)
        let moved = HashSet::from([furniture.id().to_string(), artwork.id().to_string()]);
        layout.objects.push(furniture);
        layout.objects.push(artwork);
        let saved = save_layout(db, room, layout, DoorPolicy::OnlyMoved(&moved))?;
        worker::console_log!("[Home] {} に{}を足して飾りました (空いている所が無かったため)", room.name(), name);
        return Ok(Some(saved));
    }
    Ok(None)
}

/// 配置に置いてある作品の実寸
pub fn layout_sizes(db: &Db, layout: &Layout) -> AppResult<Sizes> {
    let ids: Vec<Uuid> = layout.artworks().map(|a| a.artwork_id).collect();
    Ok(sizes_of(&load_sizes(db, &ids)?))
}

/// ログに出す家具の名前 (例: "サイドボード")
pub fn furniture_name(object: &LayoutObject) -> String {
    match object {
        LayoutObject::Furniture(f) => home::asset(&f.asset_id).map_or(f.asset_id.clone(), |a| a.name_ja.clone()),
        LayoutObject::Artwork(_) => String::new(),
    }
}

/// place_in_free_spot と同じ。ただし、その年齢のどのおへやもいっぱいなら、いちばん上に初期配置の家具でおへやを足して置く
/// (MAX_FLOORS まで)。起動時のサンプルの登録 (seed) だけが使う。家具は足さない (デモの家を今までと同じにするため)。
/// 利用者が飾るときは place_in_age (階は足さずに家具を足す)
pub fn place_in_age_adding_floors(db: &Db, artwork_id: Uuid, size: Option<&ArtSize>, age: i16) -> AppResult<Option<SavedLayout>> {
    if let Some(saved) = place_in_free_spot(db, artwork_id, size, age)? {
        return Ok(Some(saved));
    }
    // 空のおへやにも入らない作品のために、使われないおへやを作らない
    let empty = without_artworks(&home::default_layout());
    if home::pick_place(&empty, &home::Sizes::new(), artwork_id, size, None).is_none()
        || rooms_of_age(db, age)?.len() as i16 >= MAX_FLOORS
    {
        return Ok(None);
    }
    let room = create_room(db, age, &empty)?;
    worker::console_log!("[Home] {} を足しました (サンプルの作品を飾るため)", room.name());
    place_in_free_spot(db, artwork_id, size, age)
}

// =============================
// API
// =============================

pub async fn get_layout(State(state): State<AppState>, Query(query): Query<RoomQuery>) -> AppResult<Json<SavedLayout>> {
    let room = resolve_room(&state.db, query.room)?;
    Ok(Json(load_layout(&state.db, room)?))
}

/// 模様替えの保存。後から保存したほうが勝つ
pub async fn put_layout(
    State(state): State<AppState>,
    Query(query): Query<RoomQuery>,
    body: Bytes,
) -> AppResult<Json<SavedLayout>> {
    let body: PutBody = serde_json::from_slice(&body)
        .map_err(|e| AppError::bad_request(format!("送信データを読み取れません: {e}")))?;
    // 形の間違いはここで返す。位置 (作品の実寸を使う) は save_layout で検証する。
    // やめた家具 (前の画面を開いたままのタブが送ってくる) は、400 にせず外して保存する
    let retired = home::raw_retired_furniture(&body.layout);
    let layout = home::parse_layout(body.layout).map_err(AppError::bad_request)?;
    let db = &state.db;
    let room = resolve_room(db, query.room)?;
    if !retired.is_empty() {
        worker::console_log!("[Home] {} の保存で、やめた家具 {} 個 ({}) を外しました", room.name(), retired.len(), retired.join(", "));
    }

    let saved = db.tx(|| {
        // 保存されている配置は上書きする。比べるのは、出入口の前を見る「新しく置いた物・動かした物」を決めるためだけ。
        // 保存済みの配置が読めなければ (形が違うなど)、すべての物を動かした物として見る
        let raw = lock_row(db, room.id)?;
        let moved = match home::parse_layout(raw) {
            Ok(stored) => home::moved_ids(&stored, &layout),
            Err(_) => layout.objects.iter().map(|o| o.id().to_string()).collect(),
        };
        save_layout(db, room, layout, DoorPolicy::OnlyMoved(&moved))
    })?;

    worker::console_log!("[Home] {} saved ({} objects)", room.name(), saved.layout.objects.len());
    Ok(Json(saved))
}

// =============================
// 起動時の処理
// =============================

/// おへやの用意。house_rooms が空なら (初めての起動)、今の年齢の 1 階を初期配置で作る
/// (backend は前の 1 つだけの配置 home_layout をおへやに分けるが、Cloudflare には前の配置が無い)。
/// そのあと、どのおへやの配置も今の版に上げ、読めない作品・やめた家具があれば外して保存し直す。家具や部屋がおかしくて直せないおへやは初期配置に戻す
pub fn ensure_rooms(state: &AppState) -> AppResult<()> {
    let db = &state.db;
    let birthday = museum_api::child_birthday(db)?;
    if all_rooms(db)?.is_empty() {
        let age = birthday.map_or(0, |b| age::age_on(b, today()));
        let room = db.tx(|| create_room(db, age, &home::default_layout()))?;
        worker::console_log!("[Home] {} を作りました", room.name());
    }

    let rooms = all_rooms(db)?;
    let mut upgraded = 0;
    for room in &rooms {
        let changed = db.tx(|| {
            let (raw, column_version): (String, i16) = db
                .tuples("SELECT layout, schema_version FROM house_rooms WHERE id = ?1", params![room.id])?
                .into_iter()
                .next()
                .ok_or_else(|| AppError::not_found("そのおへやはありません"))?;
            let raw = parse_json(&raw)?;
            let json_version = home::raw_schema_version(&raw);
            // やめた家具は読むときに外れるので、DB からも消すために保存し直す (版は変えない)
            let retired = home::raw_retired_furniture(&raw);
            let sizes = raw_sizes(db, &raw)?;
            let (layout, repaired) = match check_saved(raw.clone(), &sizes) {
                Ok(layout) => (layout, false),
                Err(error) => match home::repair_layout(raw, &sizes) {
                    Ok((layout, dropped)) => {
                        worker::console_log!("[Home] {} の置けない作品 {} 点 ({}) を外します ({error})", room.name(), dropped.len(), dropped.join(", "));
                        (layout, true)
                    }
                    Err(_) => {
                        worker::console_log!("[Home] {} の配置が読めないので、初期配置に戻します ({error})", room.name());
                        (home::default_layout(), true)
                    }
                },
            };
            let old = json_version.is_some_and(|v| v < u64::from(home::SCHEMA_VERSION));
            if !retired.is_empty() {
                worker::console_log!("[Home] {} のやめた家具 {} 個 ({}) を外します", room.name(), retired.len(), retired.join(", "));
            }
            if repaired || old || !retired.is_empty() || column_version != SCHEMA_VERSION {
                // artworks.slot_id はそのままにしておき、このあとの reconcile で置き直す
                db.exec(
                    concat!("UPDATE house_rooms SET layout = ?2, schema_version = ?3, updated_at = ", now_sql!(), " WHERE id = ?1"),
                    vec![db::ToVal::to_val(&room.id), json(&layout)?, db::ToVal::to_val(&SCHEMA_VERSION)],
                )?;
                return Ok(true);
            }
            Ok(false)
        })?;
        upgraded += usize::from(changed);
    }
    worker::console_log!("[Home] rooms loaded ({} rooms{})", rooms.len(), if upgraded > 0 { format!(", {upgraded} saved again") } else { String::new() });
    Ok(())
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
            home::pick_place(layout, sizes, art.id, sizes.get(&art.id), None).map(|object| (room.id, layout, object))
        });
        match spot {
            Some((room_id, layout, object)) => {
                layout.objects.push(object);
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
pub fn reconcile(state: &AppState) -> AppResult<()> {
    let db = &state.db;
    let result = db.tx(|| reconcile_in(db))?;
    worker::console_log!(
        "[Home] reconcile: relocated {}, unplaced {}, removed {}{}",
        result.relocated,
        result.unplaced.len(),
        result.removed,
        if result.changed.is_empty() { " (no changes)" } else { " (saved)" }
    );
    Ok(())
}

fn reconcile_in(db: &Db) -> AppResult<Reconciled> {
    let birthday = museum_api::child_birthday(db)?;

    // 先に飾った作品から順に
    let rows: Vec<(Uuid, Option<String>, Option<Uuid>, NaiveDate, Option<i16>, Option<f64>, Option<f64>, Option<f64>, String)> =
        db.tuples(
            "SELECT id, slot_id, house_room_id, made_on, age, model_width, model_height, model_depth, model_kind FROM artworks \
             ORDER BY displayed_at ASC NULLS LAST, created_at ASC",
            params![],
        )?;
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
    let mut have: HashSet<i16> = all_rooms(db)?.iter().map(|r| r.age).collect();
    for art in arts.iter().filter(|a| a.displayed) {
        if have.insert(art.age) {
            create_room(db, art.age, &home::default_layout())?;
        }
    }

    // 全部のおへやを年齢・階の順に読む
    let mut rooms = Vec::new();
    for room in all_rooms(db)? {
        let layout = lock_layout(db, room.id)?;
        rooms.push((room, layout));
    }

    let result = reconcile_rooms(&mut rooms, &arts, &sizes);
    for (room, layout) in rooms {
        if result.changed.contains(&room.id) {
            // 起動時の整理なので出入口の前は見ない (置き直す作品は家具の上だけ)
            save_layout(db, room, layout, DoorPolicy::Ignore)?;
        }
    }
    if !result.unplaced.is_empty() {
        db.exec(
            concat!(
                "UPDATE artworks SET slot_id = NULL, displayed_at = NULL, house_room_id = NULL, updated_at = ", now_sql!(), " \
                 WHERE id IN (SELECT value FROM json_each(?1))"
            ),
            vec![uuid_list(&result.unplaced)],
        )?;
    }
    Ok(result)
}

