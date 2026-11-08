//! 作品の「おもいで」API (⑥ 作品の詳細・⑪ 鑑賞モードが使う)
//!
//! 作品ごとに、写真・動画・声の記録をいくつでも付けられる (1 作品に MAX_PER_ARTWORK まで)。
//! - 写真は作品の写真と同じく、長辺 1600px の表示用と 400px の正方形の小さい画像に縮めて JPEG で置く
//! - 動画と声は送られたまま置く (変換しない)。大きな動画をメモリに載せないよう、届いた分から store::Writer で少しずつ書く
//! - ファイルは store の memories/ に `{おもいでの id}-{tag}.{拡張子}` で置き、/media で配信する (Range に対応するので早送りもできる)

use std::collections::HashMap;

use axum::{
    extract::{multipart::Field, Multipart, Path, State},
    http::StatusCode,
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    artworks::{date_long, remove_files, write_files},
    db::{uuid_list, Db},
    error::{AppError, AppResult},
    params,
    state::{media_url, AppState, MediaKind},
    store,
};

/// 1 作品に付けられるおもいでの数
pub const MAX_PER_ARTWORK: i64 = 30;
/// POST /api/artworks/{id}/memories だけの送信の上限 (動画の上限 + フォームの余白)。
/// Cloudflare は送信を 100 MB で切るので、実際にはそちらが先にかかる
pub const UPLOAD_BODY_LIMIT: usize = 110 * 1024 * 1024;
const MB: u64 = 1024 * 1024;
const CAPTION_MAX: usize = 80;

const COLUMNS: &str =
    "id, artwork_id, kind, file, thumb_file, mime, bytes, duration_ms, width, height, caption, created_at";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemoryKind {
    Photo,
    Video,
    Audio,
}

impl MemoryKind {
    pub fn as_str(self) -> &'static str {
        match self {
            MemoryKind::Photo => "photo",
            MemoryKind::Video => "video",
            MemoryKind::Audio => "audio",
        }
    }

    fn label(self) -> &'static str {
        match self {
            MemoryKind::Photo => "写真",
            MemoryKind::Video => "動画",
            MemoryKind::Audio => "声",
        }
    }

    /// 送れる大きさの上限 (バイト)
    pub fn max_bytes(self) -> u64 {
        match self {
            MemoryKind::Photo => 20 * MB,
            // backend は 100 MB。Cloudflare は送信の本文を 100 MB で切る (フォームの余白も入る) ので、95 MB にしている
            MemoryKind::Video => 95 * MB,
            MemoryKind::Audio => 20 * MB,
        }
    }
}

/// 受け付けるファイル: (Content-Type, 拡張子, 種類, 置くときの拡張子, 置くときの Content-Type)。
/// 写真はどれも JPEG に作り直すので、置くときは jpg
const ACCEPTED: &[(&str, &[&str], MemoryKind, &str, &str)] = &[
    ("image/jpeg", &["jpg", "jpeg"], MemoryKind::Photo, "jpg", "image/jpeg"),
    ("image/png", &["png"], MemoryKind::Photo, "jpg", "image/jpeg"),
    ("image/webp", &["webp"], MemoryKind::Photo, "jpg", "image/jpeg"),
    ("image/gif", &["gif"], MemoryKind::Photo, "jpg", "image/jpeg"),
    ("video/mp4", &["mp4", "m4v"], MemoryKind::Video, "mp4", "video/mp4"),
    ("video/quicktime", &["mov"], MemoryKind::Video, "mov", "video/quicktime"),
    ("video/webm", &["webm"], MemoryKind::Video, "webm", "video/webm"),
    ("audio/mp4", &["m4a"], MemoryKind::Audio, "m4a", "audio/mp4"),
    ("audio/x-m4a", &[], MemoryKind::Audio, "m4a", "audio/mp4"),
    ("audio/m4a", &[], MemoryKind::Audio, "m4a", "audio/mp4"),
    ("audio/aac", &["aac"], MemoryKind::Audio, "aac", "audio/aac"),
    ("audio/mpeg", &["mp3"], MemoryKind::Audio, "mp3", "audio/mpeg"),
    ("audio/webm", &[], MemoryKind::Audio, "weba", "audio/webm"),
    ("audio/ogg", &["ogg", "oga", "opus"], MemoryKind::Audio, "ogg", "audio/ogg"),
    ("audio/wav", &["wav"], MemoryKind::Audio, "wav", "audio/wav"),
    ("audio/x-wav", &[], MemoryKind::Audio, "wav", "audio/wav"),
    ("audio/wave", &[], MemoryKind::Audio, "wav", "audio/wav"),
];

/// 置き方の決まった、送られたファイルの種類
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Accepted {
    pub kind: MemoryKind,
    pub ext: &'static str,
    pub mime: &'static str,
}

/// Content-Type と拡張子から、種類と置き方を決める。
/// Content-Type が分かればそれを使い、無い (application/octet-stream など) ときは拡張子で決める。
/// 両方分かって種類が違うときは断る (拡張子を書き換えたファイルなど)
pub fn classify(content_type: &str, file_name: &str) -> Result<Accepted, String> {
    let mime = content_type.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    let ext = file_name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    let to_accepted = |&(_, _, kind, ext, mime): &(&str, &[&str], MemoryKind, &'static str, &'static str)| Accepted {
        kind,
        ext,
        mime,
    };
    let by_mime = ACCEPTED.iter().find(|a| a.0 == mime).map(to_accepted);
    let by_ext = ACCEPTED.iter().find(|a| a.1.contains(&ext.as_str())).map(to_accepted);
    // webm と mp4 は、動画にも声にもなる (Chrome の録音は audio/webm の .webm)。このときは Content-Type に従う
    let media = |k: MemoryKind| k != MemoryKind::Photo;
    let ambiguous = |m: Accepted, e: Accepted| matches!(ext.as_str(), "webm" | "mp4") && media(m.kind) && media(e.kind);
    match (by_mime, by_ext) {
        (Some(m), Some(e)) if m.kind != e.kind && !ambiguous(m, e) => Err("ファイルの種類と拡張子が合いません".into()),
        (Some(m), _) => Ok(m),
        (None, Some(e)) => Ok(e),
        (None, None) => Err("写真 (JPEG・PNG・WebP)、動画 (MP4・MOV・WebM)、声 (M4A・MP3・WebM・OGG・WAV) を送ってください".into()),
    }
}

// =============================
// DTO
// =============================

#[derive(Deserialize)]
struct MemoryRow {
    id: Uuid,
    artwork_id: Uuid,
    kind: String,
    file: String,
    thumb_file: Option<String>,
    mime: String,
    bytes: i64,
    duration_ms: Option<i32>,
    width: Option<i32>,
    height: Option<i32>,
    caption: String,
    created_at: DateTime<Utc>,
}

#[derive(Serialize)]
pub struct MemoryDto {
    pub id: Uuid,
    pub artwork_id: Uuid,
    /// "photo" | "video" | "audio"
    pub kind: String,
    pub url: String,
    /// 写真の小さい画像 (動画と声は None)
    pub thumb_url: Option<String>,
    pub mime: String,
    pub bytes: i64,
    /// 動画と声の長さ (ミリ秒。Web が測って送った値。分からなければ None)
    pub duration_ms: Option<i32>,
    /// 例: "0:12"・"1:05:00" (長さが分からなければ None)
    pub duration_label: Option<String>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub caption: String,
    pub created_at: DateTime<Utc>,
    /// 例: "2026年10月18日" (足した日)
    pub date_label: String,
}

impl From<MemoryRow> for MemoryDto {
    fn from(row: MemoryRow) -> Self {
        MemoryDto {
            id: row.id,
            artwork_id: row.artwork_id,
            url: media_url(MediaKind::Memory, &row.file),
            thumb_url: row.thumb_file.as_deref().map(|f| media_url(MediaKind::Memory, f)),
            kind: row.kind,
            mime: row.mime,
            bytes: row.bytes,
            duration_ms: row.duration_ms,
            duration_label: row.duration_ms.map(duration_label),
            width: row.width,
            height: row.height,
            caption: row.caption,
            // backend はサーバーの PC の時計 (Local) の日付。Cloudflare は UTC なので日本時間にそろえる
            date_label: date_long((row.created_at + chrono::Duration::hours(9)).date_naive()),
            created_at: row.created_at,
        }
    }
}

/// 長さの表示 (秒は切り上げない。1 時間を超えたら時も付ける)
pub fn duration_label(ms: i32) -> String {
    let s = ms.max(0) / 1000;
    let (h, m, s) = (s / 3600, s / 60 % 60, s % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// 作品ごとの、おもいでの数 (3D の印・鑑賞モードのカード・一覧で使う)
#[derive(Serialize, Default, Clone, Copy, Debug, PartialEq, Eq)]
pub struct MemoryCounts {
    pub photo: i64,
    pub video: i64,
    pub audio: i64,
}

/// (作品, 種類, 数) の行を作品ごとにまとめる
fn tally(rows: impl IntoIterator<Item = (Uuid, String, i64)>) -> HashMap<Uuid, MemoryCounts> {
    let mut counts: HashMap<Uuid, MemoryCounts> = HashMap::new();
    for (artwork_id, kind, n) in rows {
        let c = counts.entry(artwork_id).or_default();
        match kind.as_str() {
            "photo" => c.photo += n,
            "video" => c.video += n,
            "audio" => c.audio += n,
            _ => {}
        }
    }
    counts
}

/// 全部の作品の、おもいでの数 (おもいでの無い作品は入らない)
pub fn counts(db: &Db) -> AppResult<HashMap<Uuid, MemoryCounts>> {
    let rows = db.tuples::<(Uuid, String, i64)>(
        "SELECT artwork_id, kind, COUNT(*) FROM artwork_memories GROUP BY artwork_id, kind",
        params![],
    )?;
    Ok(tally(rows))
}

/// 作品のおもいで (足した順)
pub fn of_artwork(db: &Db, artwork_id: Uuid) -> AppResult<Vec<MemoryDto>> {
    let rows = db.all::<MemoryRow>(
        &format!("SELECT {COLUMNS} FROM artwork_memories WHERE artwork_id = ?1 ORDER BY created_at, id"),
        params![artwork_id],
    )?;
    Ok(rows.into_iter().map(MemoryDto::from).collect())
}

/// いくつもの作品のおもいでを 1 回で読む (作品ごとに足した順)。おもいでの無い作品はキーが無い
pub fn of_artworks(db: &Db, artwork_ids: &[Uuid]) -> AppResult<HashMap<Uuid, Vec<MemoryDto>>> {
    let mut grouped: HashMap<Uuid, Vec<MemoryDto>> = HashMap::new();
    if artwork_ids.is_empty() {
        return Ok(grouped);
    }
    let rows = db.all::<MemoryRow>(
        &format!(
            "SELECT {COLUMNS} FROM artwork_memories WHERE artwork_id IN (SELECT value FROM json_each(?1)) \
             ORDER BY created_at, id"
        ),
        vec![uuid_list(artwork_ids)],
    )?;
    for row in rows {
        grouped.entry(row.artwork_id).or_default().push(MemoryDto::from(row));
    }
    Ok(grouped)
}

/// 作品のおもいでのファイル (作品を消すときに、行が CASCADE で消える前に集めておく)
pub fn files_of(db: &Db, artwork_id: Uuid) -> AppResult<Vec<(MediaKind, String)>> {
    let rows = db.tuples::<(String, Option<String>)>(
        "SELECT file, thumb_file FROM artwork_memories WHERE artwork_id = ?1",
        params![artwork_id],
    )?;
    Ok(rows
        .into_iter()
        .flat_map(|(file, thumb)| std::iter::once(file).chain(thumb))
        .map(|f| (MediaKind::Memory, f))
        .collect())
}

// =============================
// 足す
// =============================

fn clean_caption(value: &str) -> AppResult<String> {
    let caption = value.trim().to_string();
    if caption.chars().count() > CAPTION_MAX {
        return Err(AppError::bad_request(format!("ひとことは {CAPTION_MAX} 文字までにしてください")));
    }
    Ok(caption)
}

/// 長さ・大きさの数 (Web が測って送る)。空なら None、変な値は 400
fn parse_measure(value: &str, label: &str, max: i32) -> AppResult<Option<i32>> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    // 長さは小数で送られることがあるので、丸めて受け取る
    match value.parse::<f64>() {
        Ok(n) if n.is_finite() && (0.0..=max as f64).contains(&n) => Ok(Some(n.round() as i32)),
        _ => Err(AppError::bad_request(format!("{label}の値が正しくありません"))),
    }
}

fn too_large(kind: MemoryKind) -> AppError {
    AppError::payload_too_large(format!("{}は {} MB までにしてください", kind.label(), kind.max_bytes() / MB))
}

/// 受け取ったファイルの中身
enum Received {
    /// 写真 (20 MB まで。縮めるのでメモリに読む)
    Photo(Vec<u8>),
    /// 動画と声 (store へ書いている途中。最後に finish する)
    Stream(store::Writer),
}

impl Received {
    /// 途中でやめる (書いた分を消す)
    fn abort(self, db: &Db) {
        if let Received::Stream(writer) = self {
            writer.abort(db);
        }
    }
}

/// 写真を読む。上限を超えたら 413
async fn read_photo(field: &mut Field<'_>, accepted: Accepted) -> AppResult<Vec<u8>> {
    let mut bytes = Vec::new();
    while let Some(chunk) = field.chunk().await? {
        if (bytes.len() + chunk.len()) as u64 > accepted.kind.max_bytes() {
            return Err(too_large(accepted.kind));
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err(AppError::bad_request("ファイルが空です"));
    }
    Ok(bytes)
}

/// 送られているファイルを store へ流しながら書く。上限を超えたら、書いた分を消して 413
async fn stream_to_store(db: &Db, field: &mut Field<'_>, file: &str, accepted: Accepted) -> AppResult<store::Writer> {
    let mut writer = store::Writer::new(db, MediaKind::Memory, file)?;
    let mut written: u64 = 0;
    let result: AppResult<()> = async {
        while let Some(chunk) = field.chunk().await? {
            written += chunk.len() as u64;
            if written > accepted.kind.max_bytes() {
                return Err(too_large(accepted.kind));
            }
            writer.write(db, &chunk)?;
        }
        Ok(())
    }
    .await;
    if let Err(error) = result {
        writer.abort(db);
        return Err(error);
    }
    if written == 0 {
        writer.abort(db);
        return Err(AppError::bad_request("ファイルが空です"));
    }
    Ok(writer)
}

/// POST /api/artworks/{id}/memories (multipart: file・任意で caption・duration_ms・width・height)
pub async fn upload_memory(
    State(state): State<AppState>,
    Path(artwork_id): Path<Uuid>,
    mut multipart: Multipart,
) -> AppResult<(StatusCode, Json<MemoryDto>)> {
    let db = &state.db;
    // 作品があって、まだ足せるか (送られてくるファイルを受け取る前に断る)
    let (exists, count) = db
        .tuples::<(i64, i64)>(
            "SELECT EXISTS (SELECT 1 FROM artworks WHERE id = ?1), \
             (SELECT COUNT(*) FROM artwork_memories WHERE artwork_id = ?1)",
            params![artwork_id],
        )?
        .into_iter()
        .next()
        .unwrap_or((0, 0));
    if exists == 0 {
        return Err(AppError::not_found("作品が見つかりません"));
    }
    if count >= MAX_PER_ARTWORK {
        return Err(AppError::conflict(format!("おもいでは 1 つの作品に {MAX_PER_ARTWORK} 個までです")));
    }

    let id = Uuid::new_v4();
    let tag = Uuid::new_v4().simple().to_string()[..8].to_string();
    let mut caption = String::new();
    let mut duration_ms = None;
    let mut width = None;
    let mut height = None;
    let mut upload: Option<(Accepted, Received)> = None;

    let read: AppResult<()> = async {
        while let Some(mut field) = multipart.next_field().await? {
            match field.name().unwrap_or("") {
                "file" if upload.is_none() => {
                    let accepted = classify(
                        field.content_type().unwrap_or(""),
                        field.file_name().unwrap_or(""),
                    )
                    .map_err(AppError::bad_request)?;
                    let received = if accepted.kind == MemoryKind::Photo {
                        Received::Photo(read_photo(&mut field, accepted).await?)
                    } else {
                        let file = format!("{id}-{tag}.{}", accepted.ext);
                        Received::Stream(stream_to_store(db, &mut field, &file, accepted).await?)
                    };
                    upload = Some((accepted, received));
                }
                "caption" => caption = clean_caption(&field.text().await?)?,
                "duration_ms" => duration_ms = parse_measure(&field.text().await?, "長さ", 24 * 60 * 60 * 1000)?,
                "width" => width = parse_measure(&field.text().await?, "幅", 20_000)?,
                "height" => height = parse_measure(&field.text().await?, "高さ", 20_000)?,
                _ => {}
            }
        }
        Ok(())
    }
    .await;
    let Some((accepted, received)) = upload else {
        read?;
        return Err(AppError::bad_request("ファイルを選んでください"));
    };
    if let Err(error) = read {
        received.abort(db);
        return Err(error);
    }

    // 置くファイル (写真は縮めて JPEG にし、小さい画像も作る。動画と声は書き終えるだけ)
    let file = format!("{id}-{tag}.{}", accepted.ext);
    let mut thumb_file = None;
    let insert = |thumb_file: &Option<String>,
                  stored_bytes: i64,
                  duration_ms: Option<i32>,
                  width: Option<i32>,
                  height: Option<i32>|
     -> AppResult<MemoryRow> {
        db.one(
            &format!(
                "INSERT INTO artwork_memories (id, artwork_id, kind, file, thumb_file, mime, bytes, duration_ms, width, height, caption) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) RETURNING {COLUMNS}"
            ),
            params![
                id, artwork_id, accepted.kind.as_str(), file, thumb_file, accepted.mime, stored_bytes,
                duration_ms, width, height, caption
            ],
        )
    };
    let inserted = match received {
        Received::Photo(original) => {
            let photo = crate::photo::process_photo(&original)
                .map_err(|e| AppError::bad_request(format!("写真を読み込めません: {e}")))?;
            drop(original);
            let thumb = format!("{id}-{tag}-thumb.jpg");
            thumb_file = Some(thumb.clone());
            // ファイルと行を 1 つのトランザクションで書く (失敗したらファイルも残らない)
            db.tx(|| {
                write_files(
                    db,
                    &[
                        (MediaKind::Memory, file.clone(), photo.display_jpeg.as_slice()),
                        (MediaKind::Memory, thumb.clone(), photo.thumb_jpeg.as_slice()),
                    ],
                )?;
                insert(
                    &thumb_file,
                    photo.display_jpeg.len() as i64,
                    None,
                    Some(photo.width as i32),
                    Some(photo.height as i32),
                )
            })
        }
        Received::Stream(writer) => {
            let stored_bytes = writer.size() as i64;
            if accepted.kind == MemoryKind::Audio {
                width = None;
                height = None;
            }
            // 書き終えた印と行を 1 つのトランザクションで書く。失敗したら、書いた分も消す
            let result = db.tx(|| {
                writer.finish(db)?;
                insert(&thumb_file, stored_bytes, duration_ms, width, height)
            });
            if result.is_err() {
                store::remove(db, MediaKind::Memory, &file);
            }
            result
        }
    };
    // 失敗したとき (作品が同時に消された (外部キー) ときなど)、写真のファイルはトランザクションで取り消されている
    let row = inserted?;
    worker::console_log!("[Memory] {} を足しました ({} bytes)", accepted.kind.label(), row.bytes);
    Ok((StatusCode::CREATED, Json(row.into())))
}

// =============================
// ひとことを変える・消す
// =============================

#[derive(Deserialize)]
pub struct MemoryPatch {
    pub caption: String,
}

fn not_found() -> AppError {
    AppError::not_found("おもいでが見つかりません")
}

/// PATCH /api/artworks/{id}/memories/{memory_id}
pub async fn update_memory(
    State(state): State<AppState>,
    Path((artwork_id, memory_id)): Path<(Uuid, Uuid)>,
    Json(patch): Json<MemoryPatch>,
) -> AppResult<Json<MemoryDto>> {
    let caption = clean_caption(&patch.caption)?;
    let row = state
        .db
        .opt::<MemoryRow>(
            &format!("UPDATE artwork_memories SET caption = ?3 WHERE id = ?1 AND artwork_id = ?2 RETURNING {COLUMNS}"),
            params![memory_id, artwork_id, caption],
        )?
        .ok_or_else(not_found)?;
    Ok(Json(row.into()))
}

/// DELETE /api/artworks/{id}/memories/{memory_id}
pub async fn delete_memory(
    State(state): State<AppState>,
    Path((artwork_id, memory_id)): Path<(Uuid, Uuid)>,
) -> AppResult<StatusCode> {
    let db = &state.db;
    // 行とファイルを 1 つのトランザクションで消す
    db.tx(|| {
        let (file, thumb) = db
            .tuples::<(String, Option<String>)>(
                "DELETE FROM artwork_memories WHERE id = ?1 AND artwork_id = ?2 RETURNING file, thumb_file",
                params![memory_id, artwork_id],
            )?
            .into_iter()
            .next()
            .ok_or_else(not_found)?;
        remove_files(db, std::iter::once(file).chain(thumb).map(|f| (MediaKind::Memory, f)));
        Ok(())
    })?;
    Ok(StatusCode::NO_CONTENT)
}
