//! 作品 API (Web 画面 ②③④⑥⑧⑨ が使う)

use std::{collections::HashSet, time::Instant};

use axum::{
    body::Bytes,
    extract::{Multipart, Path, Query, State},
    http::StatusCode,
    Json,
};
use chrono::{DateTime, Datelike, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use tokio::fs;
use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
    glb::{self, Style},
    media,
    museum,
    state::{media_url, AppState, MediaKind},
};

pub const COLUMNS: &str = "id, title, child_name, age, made_on, memo, category, \
    image_file, thumb_file, model_file, model_kind, image_width, image_height, tint, \
    favorite, slot_id, displayed_at, created_at, updated_at, catalog_no";

#[derive(Debug, Clone, FromRow)]
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
    pub favorite: bool,
    pub slot_id: Option<String>,
    pub displayed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub catalog_no: i64,
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
    /// 例: "はるか（5歳）"
    pub author_label: String,
    /// 例: "2024-05-12" (フォーム用)
    pub made_on: String,
    /// 例: "2024.5.12"
    pub date_short: String,
    /// 例: "2024年5月12日"
    pub date_long: String,
    pub memo: String,
    pub category: String,
    pub category_label: &'static str,
    pub image_url: String,
    pub thumb_url: String,
    pub model_url: String,
    pub model_kind: String,
    pub image_width: i32,
    pub image_height: i32,
    pub tint: String,
    pub favorite: bool,
    pub displayed: bool,
    pub slot_id: Option<String>,
    pub room_id: Option<&'static str>,
    pub room_name: Option<&'static str>,
    pub floor: Option<&'static str>,
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

impl From<&ArtworkRow> for ArtworkDto {
    fn from(row: &ArtworkRow) -> Self {
        let age_label = row.age.map(|a| format!("{a}歳")).unwrap_or_default();
        let author_label = match (row.child_name.is_empty(), age_label.is_empty()) {
            (false, false) => format!("{}（{}）", row.child_name, age_label),
            (false, true) => row.child_name.clone(),
            (true, false) => age_label.clone(),
            (true, true) => String::new(),
        };
        let slot = row.slot_id.as_deref().and_then(museum::slot);
        let room = row.slot_id.as_deref().and_then(museum::room_of_slot);

        ArtworkDto {
            catalog_no: row.catalog_no,
            catalog_label: format!("No.{:03}", row.catalog_no),
            id: row.id,
            title: row.title.clone(),
            child_name: row.child_name.clone(),
            age: row.age,
            age_label,
            author_label,
            made_on: row.made_on.format("%Y-%m-%d").to_string(),
            date_short: date_short(row.made_on),
            date_long: date_long(row.made_on),
            memo: row.memo.clone(),
            category: row.category.clone(),
            category_label: museum::category_label(&row.category),
            image_url: media_url(MediaKind::Image, &row.image_file),
            thumb_url: media_url(MediaKind::Thumb, &row.thumb_file),
            model_url: media_url(MediaKind::Model, &row.model_file),
            model_kind: row.model_kind.clone(),
            image_width: row.image_width,
            image_height: row.image_height,
            tint: row.tint.clone(),
            favorite: row.favorite,
            displayed: row.slot_id.is_some(),
            slot_id: row.slot_id.clone(),
            room_id: room.map(|r| r.id),
            room_name: room.map(|r| r.name),
            floor: slot.map(museum::floor_of),
            displayed_at: row.displayed_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

async fn fetch_row(state: &AppState, id: Uuid) -> AppResult<ArtworkRow> {
    let row = sqlx::query_as::<_, ArtworkRow>(&format!("SELECT {COLUMNS} FROM artworks WHERE id = $1"))
        .bind(id)
        .fetch_one(&state.pool)
        .await?;
    Ok(row)
}

// =============================
// 一覧
// =============================

#[derive(Deserialize)]
pub struct ListQuery {
    /// drawing / craft / photo / other / all
    pub category: Option<String>,
    pub favorite: Option<bool>,
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
        _ => "created_at DESC",
    };
    let limit = query.limit.unwrap_or(200).clamp(1, 500);

    let rows_sql = format!(
        "SELECT {COLUMNS} FROM artworks \
         WHERE ($1::text IS NULL OR category = $1) \
           AND ($2::bool IS NULL OR favorite = $2) \
         ORDER BY {order} LIMIT $3"
    );
    let rows_query = sqlx::query_as::<_, ArtworkRow>(&rows_sql)
    .bind(&category)
    .bind(query.favorite)
    .bind(limit)
    .fetch_all(&state.pool);

    let counts_query = sqlx::query_as::<_, (String, i64)>(
        "SELECT category, COUNT(*) FROM artworks GROUP BY category",
    )
    .fetch_all(&state.pool);

    let (rows, counts) = tokio::try_join!(rows_query, counts_query)?;

    let total: i64 = counts.iter().map(|(_, n)| n).sum();
    let mut categories = vec![CategoryCount { id: "all", label: "すべて", count: total }];
    for id in museum::CATEGORIES {
        let count = counts.iter().find(|(c, _)| c == id).map(|(_, n)| *n).unwrap_or(0);
        categories.push(CategoryCount { id, label: museum::category_label(id), count });
    }

    Ok(Json(ArtworkList {
        items: rows.iter().map(ArtworkDto::from).collect(),
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
}

pub async fn get_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<ArtworkDetail>> {
    let row = fetch_row(&state, id).await?;

    // 同じカテゴリ → 同じ子ども → 制作日が近い順
    let related = sqlx::query_as::<_, ArtworkRow>(&format!(
        "SELECT {COLUMNS} FROM artworks WHERE id <> $1 \
         ORDER BY (category = $2) DESC, (child_name = $3) DESC, ABS(made_on - $4::date) ASC \
         LIMIT 6"
    ))
    .bind(row.id)
    .bind(&row.category)
    .bind(&row.child_name)
    .bind(row.made_on)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(ArtworkDetail {
        artwork: ArtworkDto::from(&row),
        related: related.iter().map(ArtworkDto::from).collect(),
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
        return Ok(Local::now().date_naive());
    }
    let date = NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| AppError::bad_request("作成年月日の形式が正しくありません"))?;
    if date > Local::now().date_naive() + chrono::Days::new(1) {
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

/// 生成したファイルを書き込む。失敗したら書いた分を消す
async fn write_files(state: &AppState, files: &[(MediaKind, String, &[u8])]) -> AppResult<()> {
    for (i, (kind, name, bytes)) in files.iter().enumerate() {
        if let Err(error) = fs::write(state.media_path(*kind, name), bytes).await {
            remove_files(state, files[..i].iter().map(|(k, n, _)| (*k, n.clone()))).await;
            return Err(error.into());
        }
    }
    Ok(())
}

async fn remove_files(state: &AppState, files: impl Iterator<Item = (MediaKind, String)>) {
    for (kind, name) in files {
        let path = state.media_path(kind, &name);
        if let Err(error) = fs::remove_file(&path).await {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("[Storage] Failed to remove {}: {error}", path.display());
            }
        }
    }
}

// =============================
// 登録
// =============================

pub async fn create_artwork(
    State(state): State<AppState>,
    multipart: Multipart,
) -> AppResult<(StatusCode, Json<ArtworkDto>)> {
    let started = Instant::now();
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

    let (processed, model) = tokio::task::spawn_blocking(move || {
        let processed = media::process(&image)?;
        let model = match custom_model {
            Some(model) => model.to_vec(),
            None => glb::build_artwork_glb(
                &processed.texture_jpeg,
                processed.display_width,
                processed.display_height,
                style,
            ),
        };
        Ok::<_, String>((processed, model))
    })
    .await?
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
    write_files(&state, &files).await?;

    let inserted = sqlx::query_as::<_, ArtworkRow>(&format!(
        "INSERT INTO artworks (id, title, child_name, age, made_on, memo, category, \
            image_file, thumb_file, model_file, model_kind, image_width, image_height, tint) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) \
         RETURNING {COLUMNS}"
    ))
    .bind(id)
    .bind(&title)
    .bind(&child_name)
    .bind(age)
    .bind(made_on)
    .bind(&memo)
    .bind(&category)
    .bind(&image_file)
    .bind(&thumb_file)
    .bind(&model_file)
    .bind(model_kind)
    .bind(processed.display_width as i32)
    .bind(processed.display_height as i32)
    .bind(&processed.tint)
    .fetch_one(&state.pool)
    .await;

    match inserted {
        Ok(row) => {
            println!(
                "[Artwork] created \"{}\" ({}, {} KB model) in {:?}",
                row.title,
                row.model_kind,
                model.len() / 1024,
                started.elapsed()
            );
            Ok((StatusCode::CREATED, Json(ArtworkDto::from(&row))))
        }
        Err(error) => {
            remove_files(&state, files.iter().map(|(k, n, _)| (*k, n.clone()))).await;
            Err(error.into())
        }
    }
}

// =============================
// 更新 (⑨ 作品の登録 詳細入力)
// =============================

pub async fn update_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    multipart: Multipart,
) -> AppResult<Json<ArtworkDto>> {
    let started = Instant::now();
    let row = fetch_row(&state, id).await?;
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
    let display_path = state.media_path(MediaKind::Image, &row.image_file);

    struct Regenerated {
        processed: Option<media::ProcessedImage>,
        model: Option<Vec<u8>>,
    }

    let regenerated = if new_image.is_some() || needs_new_model {
        let stored_display = if new_image.is_none() && new_model.is_none() {
            Some(fs::read(&display_path).await?)
        } else {
            None
        };

        tokio::task::spawn_blocking(move || {
            let processed = match &new_image {
                Some(bytes) => Some(media::process(bytes)?),
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
            Ok::<_, String>(Regenerated { processed, model })
        })
        .await?
        .map_err(AppError::bad_request)?
    } else {
        Regenerated { processed: None, model: None }
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

    write_files(&state, &new_files).await?;

    let updated = sqlx::query_as::<_, ArtworkRow>(&format!(
        "UPDATE artworks SET title = $2, child_name = $3, age = $4, made_on = $5, memo = $6, \
            category = $7, image_file = $8, thumb_file = $9, model_file = $10, model_kind = $11, \
            image_width = $12, image_height = $13, tint = $14, updated_at = NOW() \
         WHERE id = $1 RETURNING {COLUMNS}"
    ))
    .bind(id)
    .bind(&title)
    .bind(&child_name)
    .bind(age)
    .bind(made_on)
    .bind(&memo)
    .bind(&category)
    .bind(&image_file)
    .bind(&thumb_file)
    .bind(&model_file)
    .bind(model_kind)
    .bind(image_width)
    .bind(image_height)
    .bind(&tint)
    .fetch_one(&state.pool)
    .await;

    match updated {
        Ok(updated) => {
            remove_files(&state, old_files.into_iter()).await;
            println!("[Artwork] updated \"{}\" in {:?}", updated.title, started.elapsed());
            Ok(Json(ArtworkDto::from(&updated)))
        }
        Err(error) => {
            remove_files(&state, new_files.iter().map(|(k, n, _)| (*k, n.clone()))).await;
            Err(error.into())
        }
    }
}

// =============================
// 削除
// =============================

pub async fn delete_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    let (image_file, thumb_file, model_file) = sqlx::query_as::<_, (String, String, String)>(
        "DELETE FROM artworks WHERE id = $1 RETURNING image_file, thumb_file, model_file",
    )
    .bind(id)
    .fetch_one(&state.pool)
    .await?;

    remove_files(
        &state,
        [
            (MediaKind::Image, image_file),
            (MediaKind::Thumb, thumb_file),
            (MediaKind::Model, model_file),
        ]
        .into_iter(),
    )
    .await;

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
    let row = sqlx::query_as::<_, ArtworkRow>(&format!(
        "UPDATE artworks SET favorite = $2 WHERE id = $1 RETURNING {COLUMNS}"
    ))
    .bind(id)
    .bind(body.favorite)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(ArtworkDto::from(&row)))
}

// =============================
// 展示 / 展示をやめる (Unity に反映される)
// =============================

#[derive(Deserialize, Default)]
pub struct DisplayBody {
    pub slot_id: Option<String>,
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

    let row = fetch_row(&state, id).await?;
    if request.slot_id.is_none() && row.slot_id.is_some() {
        return Ok(Json(ArtworkDto::from(&row)));
    }

    // 同時に展示されても UNIQUE 制約で衝突を検出し、別の台で再試行する
    for _ in 0..5 {
        let occupied: HashSet<String> = sqlx::query_scalar::<_, String>(
            "SELECT slot_id FROM artworks WHERE slot_id IS NOT NULL AND id <> $1",
        )
        .bind(id)
        .fetch_all(&state.pool)
        .await?
        .into_iter()
        .collect();

        let slot_id = match &request.slot_id {
            Some(requested) => {
                if museum::slot(requested).is_none() {
                    return Err(AppError::bad_request(format!("展示台が存在しません: {requested}")));
                }
                if occupied.contains(requested) {
                    return Err(AppError::conflict("その展示台には別の作品が展示されています"));
                }
                requested.clone()
            }
            None => museum::pick_slot(&row.category, &occupied)
                .ok_or_else(|| AppError::conflict("展示スペースがいっぱいです。ほかの作品の展示をやめてから試してください"))?
                .to_string(),
        };

        let result = sqlx::query_as::<_, ArtworkRow>(&format!(
            "UPDATE artworks SET slot_id = $2, displayed_at = NOW(), updated_at = NOW() \
             WHERE id = $1 RETURNING {COLUMNS}"
        ))
        .bind(id)
        .bind(&slot_id)
        .fetch_one(&state.pool)
        .await;

        match result {
            Ok(row) => {
                println!("[Display] \"{}\" -> {}", row.title, slot_id);
                return Ok(Json(ArtworkDto::from(&row)));
            }
            Err(sqlx::Error::Database(db)) if db.code().as_deref() == Some("23505") => continue,
            Err(error) => return Err(error.into()),
        }
    }

    Err(AppError::conflict("展示台の割り当てが混み合っています。もう一度お試しください"))
}

pub async fn undisplay_artwork(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<ArtworkDto>> {
    let row = sqlx::query_as::<_, ArtworkRow>(&format!(
        "UPDATE artworks SET slot_id = NULL, displayed_at = NULL, updated_at = NOW() \
         WHERE id = $1 RETURNING {COLUMNS}"
    ))
    .bind(id)
    .fetch_one(&state.pool)
    .await?;
    println!("[Display] \"{}\" removed", row.title);
    Ok(Json(ArtworkDto::from(&row)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_japanese_dates() {
        let d = NaiveDate::from_ymd_opt(2024, 5, 12).unwrap();
        assert_eq!(date_short(d), "2024.5.12");
        assert_eq!(date_long(d), "2024年5月12日");
    }

    #[test]
    fn validates_age() {
        assert_eq!(parse_age("").unwrap(), None);
        assert_eq!(parse_age(" 5 ").unwrap(), Some(5));
        assert!(parse_age("abc").is_err());
        assert!(parse_age("200").is_err());
    }
}
