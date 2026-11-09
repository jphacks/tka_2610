//! 作品 API (Web 画面 ②③④⑥⑧⑨ が使う)

use std::collections::{HashMap, HashSet};

use axum::{
    body::Bytes,
    extract::{Multipart, Path, Query, State},
    http::StatusCode,
    Json,
};
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    age, albums,
    db::{self, uuid_list, Db},
    error::{AppError, AppResult},
    glb::{self, Style},
    home::{self, ArtworkObject, DoorPolicy, LayoutObject},
    home_api, media,
    memories::{self, MemoryCounts, MemoryDto},
    museum, museum_api, now_sql, params, schema, store,
    state::{media_url, today, AppState, MediaKind},
};

pub const COLUMNS: &str = "id, title, child_name, age, made_on, memo, category, \
    image_file, thumb_file, model_file, model_kind, image_width, image_height, tint, \
    favorite, slot_id, displayed_at, created_at, updated_at, catalog_no, \
    model_width, model_height, model_depth, house_room_id";

#[derive(Debug, Clone, Deserialize)]
pub struct ArtworkRow {
    pub id: Uuid,
    pub title: String,
    pub child_name: String,
    pub age: Option<i16>,
    pub made_on: NaiveDate,
    pub memo: String,
    pub category: String,
    pub image_file: String,
    pub thumb_file: String,
    pub model_file: String,
    pub model_kind: String,
    pub image_width: i32,
    pub image_height: i32,
    pub tint: String,
    #[serde(deserialize_with = "db::flag")]
    pub favorite: bool,
    pub slot_id: Option<String>,
    pub displayed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub catalog_no: i64,
    /// 作品の実寸 (幅・高さ・奥行き, m)。GLB から測れなかったら NULL
    pub model_width: Option<f64>,
    pub model_height: Option<f64>,
    pub model_depth: Option<f64>,
    /// 飾っているおへや (house_rooms.id)。飾っていなければ NULL
    pub house_room_id: Option<Uuid>,
}

impl ArtworkRow {
    /// 作品の実寸 (3 つ揃うときだけ)
    pub fn art_size(&self) -> Option<home::ArtSize> {
        home::ArtSize::from_model(self.model_width, self.model_height, self.model_depth, &self.model_kind)
    }
}

#[derive(Serialize)]
pub struct ArtworkDto {
    /// 目録番号 (例: 4)
    pub catalog_no: i64,
    /// 例: "No.004"
    pub catalog_label: String,
    pub id: Uuid,
    pub title: String,
    pub child_name: String,
    pub age: Option<i16>,
    /// 例: "5歳"
    pub age_label: String,
    /// 作ったときの年齢。子どもの誕生日と作成日から計算する (誕生日が無ければ age、それも無ければ 0)。
    /// 作品はこの年齢のおへやに飾る
    pub age_at_made: i16,
    /// 例: "はるか（5歳）"
    pub author_label: String,
    /// 例: "2024-05-12" (フォーム用)
    pub made_on: String,
    /// 例: "2024.5.12"
    pub date_short: String,
    /// 例: "2024年5月12日"
    pub date_long: String,
    /// 作ったときの年齢 (例: "4さい 3か月")。子どもの誕生日があるときだけ (作品一覧に出す)
    pub age_month_label: Option<String>,
    /// 作った月 (例: "2024-05")。作品一覧を月ごとに区切るのに使う
    pub month_key: String,
    /// 作った月の見出し (例: "2024年 5月")
    pub month_label: String,
    pub memo: String,
    pub category: String,
    pub category_label: &'static str,
    pub image_url: String,
    pub thumb_url: String,
    pub model_url: String,
    pub model_kind: String,
    /// 作品の実寸 (幅・高さ・奥行き, m)。登録時に GLB から測る。測れなかった作品は None
    pub model_size: Option<[f64; 3]>,
    pub image_width: i32,
    pub image_height: i32,
    pub tint: String,
    pub favorite: bool,
    pub displayed: bool,
    pub slot_id: Option<String>,
    /// 飾っているおへや (house_rooms.id)。飾っていなければ None
    pub room_id: Option<Uuid>,
    /// 飾っているおへやの名前 (例: "4さいのおへや 2")
    pub room_name: Option<String>,
    pub floor: Option<&'static str>,
    /// おもいで (写真・動画・声の記録) の数
    pub memory_counts: MemoryCounts,
    pub displayed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub fn date_short(date: NaiveDate) -> String {
    format!("{}.{}.{}", date.year(), date.month(), date.day())
}

pub fn date_long(date: NaiveDate) -> String {
    format!("{}年{}月{}日", date.year(), date.month(), date.day())
}

/// 作品の DTO を作るのに使う値: 子どもの誕生日 (作ったときの年齢を計算する)、おへやの名前、おもいでの数
pub struct DtoContext {
    pub birthday: Option<NaiveDate>,
    pub rooms: HashMap<Uuid, String>,
    pub memories: HashMap<Uuid, MemoryCounts>,
}

impl DtoContext {
    pub fn load(db: &Db) -> AppResult<Self> {
        Ok(DtoContext {
            birthday: museum_api::child_birthday(db)?,
            rooms: home_api::room_names(db)?,
            memories: memories::counts(db)?,
        })
    }
}

impl ArtworkDto {
    pub fn new(row: &ArtworkRow, ctx: &DtoContext) -> Self {
        let birthday = ctx.birthday;
        let age_label = row.age.map(|a| format!("{a}歳")).unwrap_or_default();
        let author_label = match (row.child_name.is_empty(), age_label.is_empty()) {
            (false, false) => format!("{}（{}）", row.child_name, age_label),
            (false, true) => row.child_name.clone(),
            (true, false) => age_label.clone(),
            (true, true) => String::new(),
        };
        // 飾っている作品はどれも、どこかのおへや (1F) にある
        let displayed = row.slot_id.is_some();
        let room_name = row.house_room_id.and_then(|id| ctx.rooms.get(&id).cloned());

        ArtworkDto {
            catalog_no: row.catalog_no,
            catalog_label: format!("No.{:03}", row.catalog_no),
            id: row.id,
            title: row.title.clone(),
            child_name: row.child_name.clone(),
            age: row.age,
            age_label,
            age_at_made: age::artwork_age(birthday, row.made_on, row.age),
            author_label,
            made_on: row.made_on.format("%Y-%m-%d").to_string(),
            date_short: date_short(row.made_on),
            date_long: date_long(row.made_on),
            age_month_label: birthday.map(|b| age::age_month_label(b, row.made_on)),
            month_key: row.made_on.format("%Y-%m").to_string(),
            month_label: format!("{}年 {}月", row.made_on.year(), row.made_on.month()),
            memo: row.memo.clone(),
            category: row.category.clone(),
            category_label: museum::category_label(&row.category),
            image_url: media_url(MediaKind::Image, &row.image_file),
            thumb_url: media_url(MediaKind::Thumb, &row.thumb_file),
            model_url: media_url(MediaKind::Model, &row.model_file),
            model_kind: row.model_kind.clone(),
            model_size: row.art_size().map(|a| a.size),
            image_width: row.image_width,
            image_height: row.image_height,
            tint: row.tint.clone(),
            favorite: row.favorite,
            displayed,
            slot_id: row.slot_id.clone(),
            room_id: row.house_room_id,
            room_name,
            floor: displayed.then_some(home::FLOOR_ID),
            memory_counts: ctx.memories.get(&row.id).copied().unwrap_or_default(),
            displayed_at: row.displayed_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

pub(crate) fn fetch_row(db: &Db, id: Uuid) -> AppResult<ArtworkRow> {
    db.one(&format!("SELECT {COLUMNS} FROM artworks WHERE id = ?1"), params![id])
}

// =============================
// 作品の実寸 (配置の判定に使う)
// =============================

/// 作品の実寸の列
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SizeRow {
    pub id: Uuid,
    pub model_width: Option<f64>,
    pub model_height: Option<f64>,
    pub model_depth: Option<f64>,
    pub model_kind: String,
}

/// 作品の実寸を読む。登録されていない作品の行は返らない (行の数で、作品があるかの確認にも使う)
pub(crate) fn load_sizes(db: &Db, ids: &[Uuid]) -> AppResult<Vec<SizeRow>> {
    db.all(
        "SELECT id, model_width, model_height, model_depth, model_kind FROM artworks WHERE id IN (SELECT value FROM json_each(?1))",
        vec![uuid_list(ids)],
    )
}

/// 寸法の分かる作品だけを集める (分からない作品は、配置の判定で面の枠をそのまま使う)
pub(crate) fn sizes_of(rows: &[SizeRow]) -> home::Sizes {
    rows.iter()
        .filter_map(|r| {
            home::ArtSize::from_model(r.model_width, r.model_height, r.model_depth, &r.model_kind).map(|size| (r.id, size))
        })
        .collect()
}

/// GLB の実寸を測る。測れなければ None (ログだけ出す。登録は止めない)
pub(crate) fn measure_model(model: &[u8], label: &str) -> Option<[f64; 3]> {
    match glb::measure_glb(model) {
        Ok(size) => Some(size),
        Err(error) => {
            worker::console_log!("[Artwork] {label} の大きさを測れませんでした ({error})");
            None
        }
    }
}

// =============================
// 一覧
// =============================

#[derive(Deserialize)]
pub struct ListQuery {
    /// drawing / craft / photo / other / all
    pub category: Option<String>,
    pub favorite: Option<bool>,
    /// アルバムの id (UUID か "favorites")。そのアルバムに入っている作品だけ
    pub album: Option<String>,
    /// recent (登録が新しい順, 既定) / made (制作日が新しい順)
    pub sort: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Serialize, Default)]
pub struct CategoryCount {
    pub id: &'static str,
    pub label: &'static str,
    pub count: i64,
}

#[derive(Serialize)]
pub struct ArtworkList {
    pub items: Vec<ArtworkDto>,
    pub total: i64,
    /// カテゴリタブ用 (先頭は「すべて」)
    pub categories: Vec<CategoryCount>,
}

pub async fn list_artworks(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> AppResult<Json<ArtworkList>> {
    let category = query
        .category
        .filter(|c| museum::CATEGORIES.contains(&c.as_str()));

    let order = match query.sort.as_deref() {
        Some("made") => "made_on DESC, created_at DESC",
        // 作成日の古い順 (作品一覧の「古い順」)
        Some("made_asc") => "made_on ASC, created_at ASC",
        _ => "created_at DESC",
    };
    let limit = query.limit.unwrap_or(200).clamp(1, 500);
    let (album_favorite, album) = albums::list_filter(query.album.as_deref())?;
    let favorite = query.favorite.or(album_favorite);

    let rows_sql = format!(
        "SELECT {COLUMNS} FROM artworks \
         WHERE (?1 IS NULL OR category = ?1) \
           AND (?2 IS NULL OR favorite = ?2) \
           AND (?4 IS NULL OR id IN (SELECT artwork_id FROM album_artworks WHERE album_id = ?4)) \
         ORDER BY {order} LIMIT ?3"
    );
    let db = &state.db;
    let rows: Vec<ArtworkRow> = db.all(&rows_sql, params![category, favorite, limit, album])?;
    let counts: Vec<(String, i64)> = db.tuples("SELECT category, COUNT(*) FROM artworks GROUP BY category", params![])?;
    let ctx = DtoContext::load(db)?;

    let total: i64 = counts.iter().map(|(_, n)| n).sum();
    let mut categories = vec![CategoryCount { id: "all", label: "すべて", count: total }];
    for id in museum::CATEGORIES {
        let count = counts.iter().find(|(c, _)| c == id).map(|(_, n)| *n).unwrap_or(0);
        categories.push(CategoryCount { id, label: museum::category_label(id), count });
    }

    Ok(Json(ArtworkList {
        items: rows.iter().map(|r| ArtworkDto::new(r, &ctx)).collect(),
        total,
        categories,
    }))
}

// =============================
// 詳細 (+ 関連する作品)
// =============================

#[derive(Serialize)]
pub struct ArtworkDetail {
    pub artwork: ArtworkDto,
    pub related: Vec<ArtworkDto>,
    /// おもいで (写真・動画・声の記録。足した順)
    pub memories: Vec<MemoryDto>,
}

pub async fn get_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<ArtworkDetail>> {
    let db = &state.db;
    let row = fetch_row(db, id)?;
    let ctx = DtoContext::load(db)?;
    let memories = memories::of_artwork(db, id)?;

    // 同じカテゴリ → 同じ子ども → 制作日が近い順
    let related: Vec<ArtworkRow> = db.all(
        &format!(
            "SELECT {COLUMNS} FROM artworks WHERE id <> ?1 \
             ORDER BY (category = ?2) DESC, (child_name = ?3) DESC, ABS(julianday(made_on) - julianday(?4)) ASC \
             LIMIT 6"
        ),
        params![row.id, row.category, row.child_name, row.made_on],
    )?;

    Ok(Json(ArtworkDetail {
        artwork: ArtworkDto::new(&row, &ctx),
        related: related.iter().map(|r| ArtworkDto::new(r, &ctx)).collect(),
        memories,
    }))
}

// =============================
// フォーム (multipart) の読み取りと検証
// =============================

#[derive(Default)]
struct ArtworkForm {
    title: Option<String>,
    child_name: Option<String>,
    age: Option<String>,
    made_on: Option<String>,
    memo: Option<String>,
    category: Option<String>,
    image: Option<Bytes>,
    model: Option<Bytes>,
}

async fn read_form(mut multipart: Multipart) -> AppResult<ArtworkForm> {
    let mut form = ArtworkForm::default();

    while let Some(field) = multipart.next_field().await? {
        let name = field.name().unwrap_or_default().to_string();
        match name.as_str() {
            "image" | "model" => {
                let bytes = field.bytes().await?;
                if bytes.is_empty() {
                    continue;
                }
                if name == "image" {
                    form.image = Some(bytes);
                } else {
                    form.model = Some(bytes);
                }
            }
            "title" => form.title = Some(field.text().await?),
            "child_name" => form.child_name = Some(field.text().await?),
            "age" => form.age = Some(field.text().await?),
            "made_on" => form.made_on = Some(field.text().await?),
            "memo" => form.memo = Some(field.text().await?),
            "category" => form.category = Some(field.text().await?),
            _ => {}
        }
    }

    Ok(form)
}

fn clean_text(value: String, max_chars: usize, label: &str) -> AppResult<String> {
    let value = value.trim().to_string();
    if value.chars().count() > max_chars {
        return Err(AppError::bad_request(format!("{label}は{max_chars}文字以内で入力してください")));
    }
    Ok(value)
}

fn parse_age(value: &str) -> AppResult<Option<i16>> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    let age: i16 = value
        .parse()
        .map_err(|_| AppError::bad_request("年齢は数字で入力してください"))?;
    if !(0..=120).contains(&age) {
        return Err(AppError::bad_request("年齢は0〜120で入力してください"));
    }
    Ok(Some(age))
}

fn parse_date(value: &str) -> AppResult<NaiveDate> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(today());
    }
    let date = NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| AppError::bad_request("作成年月日の形式が正しくありません"))?;
    if date > today() + chrono::Days::new(1) {
        return Err(AppError::bad_request("作成年月日に未来の日付は指定できません"));
    }
    Ok(date)
}

fn parse_category(value: &str) -> AppResult<String> {
    let value = value.trim();
    if museum::CATEGORIES.contains(&value) {
        Ok(value.to_string())
    } else {
        Err(AppError::bad_request("作品の種類が正しくありません"))
    }
}

fn file_tag() -> String {
    Uuid::new_v4().simple().to_string()[..8].to_string()
}

/// 生成したファイルを書き込む (トランザクションの中で呼ぶと、失敗したときに一緒に取り消される)
pub(crate) fn write_files(db: &Db, files: &[(MediaKind, String, &[u8])]) -> AppResult<()> {
    for (kind, name, bytes) in files {
        store::put(db, *kind, name, bytes)?;
    }
    Ok(())
}

pub(crate) fn remove_files(db: &Db, files: impl Iterator<Item = (MediaKind, String)>) {
    store::remove_all(db, files);
}

/// 保存してあるファイルを読む。サンプルの作品のファイル (名前に "-seed." が入る) は静的ファイルにある
pub(crate) async fn read_media(state: &AppState, kind: MediaKind, file: &str) -> AppResult<Option<Vec<u8>>> {
    if !file.contains("-seed.") {
        return store::get(&state.db, kind, file);
    }
    let assets = state.env.assets("ASSETS")?;
    let url = format!("https://assets.local{}", media_url(kind, file));
    let response = worker::send::SendFuture::new(assets.fetch(url, None)).await?;
    if response.status() != 200 {
        return Ok(None);
    }
    let mut response = worker::Response::try_from(response)?;
    Ok(Some(worker::send::SendFuture::new(response.bytes()).await?))
}

// =============================
// 登録
// =============================

pub async fn create_artwork(
    State(state): State<AppState>,
    multipart: Multipart,
) -> AppResult<(StatusCode, Json<ArtworkDto>)> {
    let form = read_form(multipart).await?;

    let title = clean_text(form.title.unwrap_or_default(), 40, "作品のタイトル")?;
    if title.is_empty() {
        return Err(AppError::bad_request("作品のタイトルを入力してください"));
    }
    let child_name = clean_text(form.child_name.unwrap_or_default(), 30, "つくった人")?;
    let memo = clean_text(form.memo.unwrap_or_default(), 500, "メモ")?;
    let age = parse_age(form.age.as_deref().unwrap_or(""))?;
    let made_on = parse_date(form.made_on.as_deref().unwrap_or(""))?;
    let category = match form.category.as_deref() {
        Some(c) if !c.trim().is_empty() => parse_category(c)?,
        _ => "drawing".to_string(),
    };
    let image = form
        .image
        .ok_or_else(|| AppError::bad_request("写真を撮るか選んでください"))?;
    if let Some(model) = &form.model {
        glb::validate_glb(model).map_err(AppError::bad_request)?;
    }

    let style = Style::for_category(&category);
    let custom_model = form.model;
    let model_kind = if custom_model.is_some() { "custom" } else { style.as_str() };

    let label = format!("「{title}」の GLB");
    let (processed, model, model_size) = (move || {
        let processed = crate::photo::process(&image)?;
        let model = match custom_model {
            Some(model) => model.to_vec(),
            None => glb::build_artwork_glb(
                &processed.texture_jpeg,
                processed.display_width,
                processed.display_height,
                style,
            ),
        };
        let model_size = measure_model(&model, &label);
        Ok::<_, String>((processed, model, model_size))
    })()
    .map_err(AppError::bad_request)?;

    let id = Uuid::new_v4();
    let tag = file_tag();
    let image_file = format!("{id}-{tag}.jpg");
    let thumb_file = format!("{id}-{tag}.jpg");
    let model_file = format!("{id}-{tag}.glb");

    let files = [
        (MediaKind::Image, image_file.clone(), processed.display_jpeg.as_slice()),
        (MediaKind::Thumb, thumb_file.clone(), processed.thumb_jpeg.as_slice()),
        (MediaKind::Model, model_file.clone(), model.as_slice()),
    ];
    let db = &state.db;
    // ファイルと行を 1 つのトランザクションで書く (失敗したらファイルも残らない)
    let row: ArtworkRow = db.tx(|| {
        write_files(db, &files)?;
        let catalog_no = schema::next_catalog_no(db)?;
        db.one(
            &format!(
                "INSERT INTO artworks (id, title, child_name, age, made_on, memo, category, \
                    image_file, thumb_file, model_file, model_kind, image_width, image_height, tint, \
                    model_width, model_height, model_depth, catalog_no) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18) \
                 RETURNING {COLUMNS}"
            ),
            params![
                id, title, child_name, age, made_on, memo, category, image_file, thumb_file, model_file, model_kind,
                processed.display_width, processed.display_height, processed.tint,
                model_size.map(|s| s[0]), model_size.map(|s| s[1]), model_size.map(|s| s[2]), catalog_no
            ],
        )
    })?;
    worker::console_log!("[Artwork] created \"{}\" ({}, {} KB model)", row.title, row.model_kind, model.len() / 1024);
    // 登録したばかりの作品は飾っていない
    let ctx = DtoContext::load(db)?;
    Ok((StatusCode::CREATED, Json(ArtworkDto::new(&row, &ctx))))
}

// =============================
// 更新 (⑨ 作品の登録 詳細入力)
// =============================

pub async fn update_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    multipart: Multipart,
) -> AppResult<Json<ArtworkDto>> {
    let row = fetch_row(&state.db, id)?;
    let form = read_form(multipart).await?;

    let title = match form.title {
        Some(t) => clean_text(t, 40, "作品のタイトル")?,
        None => row.title.clone(),
    };
    if title.is_empty() {
        return Err(AppError::bad_request("作品のタイトルを入力してください"));
    }
    let child_name = match form.child_name {
        Some(v) => clean_text(v, 30, "つくった人")?,
        None => row.child_name.clone(),
    };
    let memo = match form.memo {
        Some(v) => clean_text(v, 500, "メモ")?,
        None => row.memo.clone(),
    };
    let age = match form.age.as_deref() {
        Some(v) => parse_age(v)?,
        None => row.age,
    };
    let made_on = match form.made_on.as_deref() {
        Some(v) => parse_date(v)?,
        None => row.made_on,
    };
    let category = match form.category.as_deref() {
        Some(v) => parse_category(v)?,
        None => row.category.clone(),
    };
    if let Some(model) = &form.model {
        glb::validate_glb(model).map_err(AppError::bad_request)?;
    }

    let style = Style::for_category(&category);
    let uploaded_custom = form.model.is_some();
    let keep_custom = row.model_kind == "custom" && !uploaded_custom;
    let needs_new_model = form.model.is_some()
        || (!keep_custom && (form.image.is_some() || category != row.category));

    // 画像やモデルの作り直し (必要なときだけ)
    let new_image = form.image;
    let new_model = form.model;

    struct Regenerated {
        processed: Option<media::ProcessedImage>,
        model: Option<Vec<u8>>,
        /// 作り直したモデルの実寸 (測れなければ None)
        model_size: Option<[f64; 3]>,
    }

    let regenerated = if new_image.is_some() || needs_new_model {
        let stored_display = if new_image.is_none() && new_model.is_none() {
            Some(
                read_media(&state, MediaKind::Image, &row.image_file)
                    .await?
                    .ok_or_else(|| AppError::internal(format!("{} がありません", row.image_file)))?,
            )
        } else {
            None
        };

        let label = format!("「{title}」の GLB");
        (move || {
            let processed = match &new_image {
                Some(bytes) => Some(crate::photo::process(bytes)?),
                None => None,
            };
            let model = if let Some(model) = new_model {
                Some(model.to_vec())
            } else if !needs_new_model {
                None
            } else if let Some(p) = &processed {
                Some(glb::build_artwork_glb(&p.texture_jpeg, p.display_width, p.display_height, style))
            } else {
                let stored = stored_display.expect("display image loaded for regeneration");
                let (texture, w, h) = media::texture_from_display(&stored)?;
                Some(glb::build_artwork_glb(&texture, w, h, style))
            };
            let model_size = model.as_deref().and_then(|m| measure_model(m, &label));
            Ok::<_, String>(Regenerated { processed, model, model_size })
        })()
        .map_err(AppError::bad_request)?
    } else {
        Regenerated { processed: None, model: None, model_size: None }
    };

    let tag = file_tag();
    let mut new_files: Vec<(MediaKind, String, &[u8])> = Vec::new();
    let mut old_files: Vec<(MediaKind, String)> = Vec::new();

    let mut image_file = row.image_file.clone();
    let mut thumb_file = row.thumb_file.clone();
    let mut model_file = row.model_file.clone();
    let mut image_width = row.image_width;
    let mut image_height = row.image_height;
    let mut tint = row.tint.clone();

    if let Some(p) = &regenerated.processed {
        image_file = format!("{id}-{tag}.jpg");
        thumb_file = format!("{id}-{tag}.jpg");
        image_width = p.display_width as i32;
        image_height = p.display_height as i32;
        tint = p.tint.clone();
        new_files.push((MediaKind::Image, image_file.clone(), &p.display_jpeg));
        new_files.push((MediaKind::Thumb, thumb_file.clone(), &p.thumb_jpeg));
        old_files.push((MediaKind::Image, row.image_file.clone()));
        old_files.push((MediaKind::Thumb, row.thumb_file.clone()));
    }
    if let Some(model) = &regenerated.model {
        model_file = format!("{id}-{tag}.glb");
        new_files.push((MediaKind::Model, model_file.clone(), model));
        old_files.push((MediaKind::Model, row.model_file.clone()));
    }

    let model_kind = if uploaded_custom || keep_custom { "custom" } else { style.as_str() };
    // モデルを作り直したときだけ測り直す
    let [model_width, model_height, model_depth] = match &regenerated.model {
        Some(_) => regenerated.model_size.map_or([None; 3], |s| s.map(Some)),
        None => [row.model_width, row.model_height, row.model_depth],
    };

    let db = &state.db;
    let mut updated: ArtworkRow = db.tx(|| {
        write_files(db, &new_files)?;
        let updated = db.one(
            &format!(
                "UPDATE artworks SET title = ?2, child_name = ?3, age = ?4, made_on = ?5, memo = ?6, \
                    category = ?7, image_file = ?8, thumb_file = ?9, model_file = ?10, model_kind = ?11, \
                    image_width = ?12, image_height = ?13, tint = ?14, \
                    model_width = ?15, model_height = ?16, model_depth = ?17, updated_at = {} \
                 WHERE id = ?1 RETURNING {COLUMNS}",
                now_sql!()
            ),
            params![
                id, title, child_name, age, made_on, memo, category, image_file, thumb_file, model_file, model_kind,
                image_width, image_height, tint, model_width, model_height, model_depth
            ],
        )?;
        remove_files(db, old_files.into_iter());
        Ok(updated)
    })?;
    worker::console_log!("[Artwork] updated \"{}\"", updated.title);
    // 作成日 (や年齢) が変わって、飾っているおへやの年齢と合わなくなったら、正しい年齢のおへやへ置き直す
    if let Some(room_id) = updated.house_room_id {
        let birthday = museum_api::child_birthday(db)?;
        let room = home_api::find_room(db, room_id)?;
        if room.age != age::artwork_age(birthday, updated.made_on, updated.age) {
            home_api::reconcile(&state)?;
            updated = fetch_row(db, id)?;
        }
    }
    let ctx = DtoContext::load(db)?;
    Ok(Json(ArtworkDto::new(&updated, &ctx)))
}

// =============================
// 削除
// =============================

pub async fn delete_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    // 飾っているおへやの配置からも、同じトランザクションで外す (ファイルも一緒に消す)
    let db = &state.db;
    db.tx(|| {
        let row = fetch_row(db, id)?;
        let room = match row.house_room_id {
            Some(room_id) => {
                let room = home_api::find_room(db, room_id)?;
                Some((room, home_api::lock_layout(db, room_id)?))
            }
            None => None,
        };
        // おもいでの行は作品と一緒に CASCADE で消えるので、ファイル名を先に集めておく
        let memory_files = memories::files_of(db, id)?;

        let (image_file, thumb_file, model_file): (String, String, String) = db
            .tuples("DELETE FROM artworks WHERE id = ?1 RETURNING image_file, thumb_file, model_file", params![id])?
            .into_iter()
            .next()
            .ok_or_else(|| AppError::not_found("作品が見つかりません"))?;

        if let Some((room, mut layout)) = room
            && layout.remove_artwork(id)
        {
            // 外すだけで、動かす物は無い
            home_api::save_layout(db, room, layout, DoorPolicy::Ignore)?;
        }
        remove_files(
            db,
            [(MediaKind::Image, image_file), (MediaKind::Thumb, thumb_file), (MediaKind::Model, model_file)]
                .into_iter()
                .chain(memory_files),
        );
        Ok(())
    })?;

    Ok(StatusCode::NO_CONTENT)
}

// =============================
// お気に入り
// =============================

#[derive(Deserialize)]
pub struct FavoriteBody {
    pub favorite: bool,
}

pub async fn set_favorite(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<FavoriteBody>,
) -> AppResult<Json<ArtworkDto>> {
    let row: ArtworkRow =
        state.db.one(&format!("UPDATE artworks SET favorite = ?2 WHERE id = ?1 RETURNING {COLUMNS}"), params![id, body.favorite])?;
    let ctx = DtoContext::load(&state.db)?;
    Ok(Json(ArtworkDto::new(&row, &ctx)))
}

// =============================
// 飾る / 飾るのをやめる (配置 JSON に反映される)
// =============================

/// POST /api/artworks/{id}/display の本文 (任意)。
/// position を省くと空いている場所に自動で置く (room_id があればそのおへやだけ、無ければその作品の年齢のおへやを下の階から)
#[derive(Deserialize, Default)]
pub struct DisplayBody {
    /// 飾るおへや (house_rooms.id)。作品の年齢と違うおへやは 400。自動で置くときはこのおへやの家具だけを探す
    /// (空きが無ければ 409。ほかのおへやには置かない)。position・parent_id を指定するときは要る (省くと今飾っているおへや)。
    /// "hub" など家の部屋の id (前の版の Web) は、省いたのと同じに扱う
    pub room_id: Option<String>,
    /// 載せる家具の object id。省くと床 (position があるとき) か自動
    pub parent_id: Option<String>,
    /// 載せる面 ("top"・"shelf1" など)。省くと天板。parent_id と position があるときだけ使う
    pub surface: Option<String>,
    /// 配置 JSON と同じ意味の位置 (家具の上なら面の中心から、床ならおへやの中心から見た位置)
    pub position: Option<[f64; 3]>,
    /// 向き (ラジアン)。position があるときだけ使う
    pub rotation_y: Option<f64>,
}

pub async fn display_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    body: Bytes,
) -> AppResult<Json<ArtworkDto>> {
    let request: DisplayBody = if body.is_empty() {
        DisplayBody::default()
    } else {
        serde_json::from_slice(&body).map_err(|e| AppError::bad_request(e.to_string()))?
    };
    let target = match request.room_id.as_deref() {
        None => None,
        Some(room) => match Uuid::parse_str(room) {
            Ok(id) => Some(id),
            Err(_) if home::room_def(room).is_some() => None,
            Err(_) => return Err(AppError::bad_request(format!("おへや「{room}」はありません"))),
        },
    };

    let db = &state.db;
    let (row, room_name) = db.tx(|| display_in(db, id, target, request))?;
    let ctx = DtoContext::load(db)?;
    worker::console_log!("[Display] \"{}\" -> {} ({})", row.title, row.slot_id.as_deref().unwrap_or("-"), room_name);
    Ok(Json(ArtworkDto::new(&row, &ctx)))
}

/// 飾る (トランザクションの中)。飾ったあとの作品の行と、飾ったおへやの名前を返す
fn display_in(db: &Db, id: Uuid, target: Option<Uuid>, request: DisplayBody) -> AppResult<(ArtworkRow, String)> {
    let row = fetch_row(db, id)?;
    let birthday = museum_api::child_birthday(db)?;
    let age = age::artwork_age(birthday, row.made_on, row.age);
    let manual = request.parent_id.is_some() || request.position.is_some();

    if row.house_room_id.is_some() && !manual && target.is_none_or(|t| Some(t) == row.house_room_id) {
        // すでに飾ってある (同じ要求を 2 回送っても置き場所は変わらない)。別のおへやを指定したときは、そのおへやへ移す
        let name = row.house_room_id.map(|r| home_api::find_room(db, r).map(|r| r.name())).transpose()?.unwrap_or_default();
        return Ok((row, name));
    }

    // 飾るおへや。手で置く (parent_id・position) ときは、省くと今飾っているおへや
    let room = match target.or(if manual { row.house_room_id } else { None }) {
        Some(room_id) => Some(home_api::find_room(db, room_id)?),
        None if manual => return Err(AppError::bad_request("置き場所を指定するときは、おへや (room_id) も指定してください")),
        None => None,
    };
    if let Some(room) = room
        && room.age != age
    {
        return Err(AppError::bad_request(format!(
            "「{}」は {age} さいのときの作品なので、{} には飾れません",
            row.title,
            room.name()
        )));
    }

    // ほかのおへやに飾ってあれば、先に外す (object id は移した先でも使う)
    let mut moving_id = None;
    if let Some(current) = row.house_room_id
        && room.is_none_or(|r| r.id != current)
    {
        let current_room = home_api::find_room(db, current)?;
        let mut layout = home_api::lock_layout(db, current)?;
        moving_id = layout.artwork_for(id).map(|a| a.id.clone());
        if layout.remove_artwork(id) {
            home_api::save_layout(db, current_room, layout, DoorPolicy::Ignore)?;
        }
    }

    let saved = match room {
        // おへやを省いたとき: その年齢のおへやを下の階から探す (おへやが無ければ 1 階を作る)
        None => home_api::place_in_age(db, id, row.art_size().as_ref(), age)?.ok_or_else(|| {
            AppError::conflict(format!("{age} さいのおへやがいっぱいです。「おへやを足す」でおへやを増やしてください"))
        })?,
        Some(room) => {
            let mut layout = home_api::lock_layout(db, room.id)?;
            if let Some(parent_id) = &request.parent_id {
                let support = layout
                    .furniture(parent_id)
                    .and_then(|f| home::asset(&f.asset_id))
                    .filter(|a| a.is_support());
                let Some(support) = support else {
                    return Err(AppError::bad_request("その家具には作品を置けません"));
                };
                if support.surface(request.surface.as_deref()).is_none() {
                    return Err(AppError::bad_request("その家具にはその置き場所がありません"));
                }
            } else if request.surface.is_some() {
                return Err(AppError::bad_request("surface は parent_id と一緒に指定してください"));
            }

            // 移動するときは object id をそのまま使う
            let current = layout.artwork_for(id).cloned();
            layout.remove_artwork(id);
            let object_id = current.map(|c| c.id).or(moving_id).unwrap_or_else(|| home::new_object_id("art"));
            let object = match request.position {
                Some(position) => ArtworkObject {
                    id: object_id,
                    artwork_id: id,
                    room_id: request.parent_id.is_none().then(|| home::HUB_ID.to_string()),
                    parent_id: request.parent_id,
                    // 天板 ("top") は省いた形にそろえる (save_layout の検証でも直る)
                    surface: request.surface.filter(|s| s != home::TOP_SURFACE),
                    placement: None,
                    position,
                    rotation_y: request.rotation_y.unwrap_or(0.0),
                },
                None => {
                    // 載っている作品は実寸、置く作品も実寸で空きを探す
                    let ids: Vec<Uuid> = layout.artworks().map(|a| a.artwork_id).collect();
                    let sizes = sizes_of(&load_sizes(db, &ids)?);
                    // 写真の額縁は、家具を指定していなければ壁に掛ける (壁がいっぱいなら家具の上)
                    let placed = home::pick_place(&layout, &sizes, id, row.art_size().as_ref(), request.parent_id.as_deref());
                    let Some(LayoutObject::Artwork(object)) = placed else {
                        return Err(AppError::conflict(format!(
                            "{} に飾る場所がいっぱいです。模様替えで棚や机を足してください",
                            room.name()
                        )));
                    };
                    ArtworkObject { id: object_id, ..object }
                }
            };
            let slot_id = object.id.clone();
            layout.objects.push(LayoutObject::Artwork(object));
            // 置けない位置 (はみ出し・重なり・出入口の前) はここで 400 になる。出入口の前を見るのは、いま置いた作品だけ
            let moved = HashSet::from([slot_id]);
            home_api::save_layout(db, room, layout, DoorPolicy::OnlyMoved(&moved))?
        }
    };
    Ok((fetch_row(db, id)?, saved.room.name))
}

pub async fn undisplay_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<ArtworkDto>> {
    let db = &state.db;
    let row = db.tx(|| {
        let row = fetch_row(db, id)?;
        match row.house_room_id {
            Some(room_id) => {
                let room = home_api::find_room(db, room_id)?;
                let mut layout = home_api::lock_layout(db, room_id)?;
                layout.remove_artwork(id);
                // 外すだけで、動かす物は無い。配置に無くても save_layout で未展示に揃う
                home_api::save_layout(db, room, layout, DoorPolicy::Ignore)?;
            }
            None if row.slot_id.is_some() => {
                db.exec(
                    concat!("UPDATE artworks SET slot_id = NULL, displayed_at = NULL, updated_at = ", now_sql!(), " WHERE id = ?1"),
                    params![id],
                )?;
            }
            None => {}
        }
        fetch_row(db, id)
    })?;
    let ctx = DtoContext::load(db)?;

    worker::console_log!("[Display] \"{}\" removed", row.title);
    Ok(Json(ArtworkDto::new(&row, &ctx)))
}

