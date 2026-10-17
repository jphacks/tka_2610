//! 作品の「おもいで」API (⑥ 作品の詳細・⑪ 鑑賞モードが使う)
//!
//! 作品ごとに、写真・動画・声の記録をいくつでも付けられる (1 作品に MAX_PER_ARTWORK まで)。
//! - 写真は作品の写真と同じく、長辺 1600px の表示用と 400px の正方形の小さい画像に縮めて JPEG で置く
//! - 動画と声は送られたまま置く (変換しない)。100 MB の動画をメモリに載せないよう、一時ファイルへ流しながら書く
//! - ファイルは media/memories/ に `{おもいでの id}-{tag}.{拡張子}` で置き、/media で配信する (Range に対応するので早送りもできる)

use std::collections::{HashMap, HashSet};

use axum::{
    extract::{multipart::Field, Multipart, Path, State},
    http::StatusCode,
    Json,
};
use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, PgExecutor};
use tokio::{fs, io::AsyncWriteExt};
use uuid::Uuid;

use crate::{
    artworks::{date_long, remove_files, write_files},
    error::{AppError, AppResult},
    media,
    state::{media_url, AppState, MediaKind},
};

/// 1 作品に付けられるおもいでの数
pub const MAX_PER_ARTWORK: i64 = 30;
/// POST /api/artworks/{id}/memories だけの送信の上限 (動画の上限 + フォームの余白)
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
            MemoryKind::Video => 100 * MB,
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

#[derive(FromRow)]
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
            width: row.width,
            height: row.height,
            caption: row.caption,
            date_label: date_long(row.created_at.with_timezone(&Local).date_naive()),
            created_at: row.created_at,
        }
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
pub async fn counts<'e>(executor: impl PgExecutor<'e>) -> AppResult<HashMap<Uuid, MemoryCounts>> {
    let rows = sqlx::query_as::<_, (Uuid, String, i64)>(
        "SELECT artwork_id, kind, COUNT(*) FROM artwork_memories GROUP BY artwork_id, kind",
    )
    .fetch_all(executor)
    .await?;
    Ok(tally(rows))
}

/// 作品のおもいで (足した順)
pub async fn of_artwork<'e>(executor: impl PgExecutor<'e>, artwork_id: Uuid) -> AppResult<Vec<MemoryDto>> {
    let rows = sqlx::query_as::<_, MemoryRow>(&format!(
        "SELECT {COLUMNS} FROM artwork_memories WHERE artwork_id = $1 ORDER BY created_at, id"
    ))
    .bind(artwork_id)
    .fetch_all(executor)
    .await?;
    Ok(rows.into_iter().map(MemoryDto::from).collect())
}

/// 作品のおもいでのファイル (作品を消すときに、行が CASCADE で消える前に集めておく)
pub async fn files_of<'e>(executor: impl PgExecutor<'e>, artwork_id: Uuid) -> AppResult<Vec<(MediaKind, String)>> {
    let rows = sqlx::query_as::<_, (String, Option<String>)>(
        "SELECT file, thumb_file FROM artwork_memories WHERE artwork_id = $1",
    )
    .bind(artwork_id)
    .fetch_all(executor)
    .await?;
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

/// 送られているファイルを一時ファイルへ流しながら書く。上限を超えたら、書いた分を消して 413
async fn stream_to_file(field: &mut Field<'_>, path: &std::path::Path, accepted: Accepted) -> AppResult<u64> {
    let mut file = fs::File::create(path).await?;
    let mut written: u64 = 0;
    let result: AppResult<()> = async {
        while let Some(chunk) = field.chunk().await? {
            written += chunk.len() as u64;
            if written > accepted.kind.max_bytes() {
                return Err(AppError::payload_too_large(format!(
                    "{}は {} MB までにしてください",
                    accepted.kind.label(),
                    accepted.kind.max_bytes() / MB
                )));
            }
            file.write_all(&chunk).await?;
        }
        file.flush().await?;
        Ok(())
    }
    .await;
    drop(file);
    if let Err(error) = result {
        let _ = fs::remove_file(path).await;
        return Err(error);
    }
    if written == 0 {
        let _ = fs::remove_file(path).await;
        return Err(AppError::bad_request("ファイルが空です"));
    }
    Ok(written)
}

/// POST /api/artworks/{id}/memories (multipart: file・任意で caption・duration_ms・width・height)
pub async fn upload_memory(
    State(state): State<AppState>,
    Path(artwork_id): Path<Uuid>,
    mut multipart: Multipart,
) -> AppResult<(StatusCode, Json<MemoryDto>)> {
    // 作品があって、まだ足せるか (送られてくるファイルを受け取る前に断る)
    let (exists, count) = sqlx::query_as::<_, (bool, i64)>(
        "SELECT EXISTS (SELECT 1 FROM artworks WHERE id = $1), \
         (SELECT COUNT(*) FROM artwork_memories WHERE artwork_id = $1)",
    )
    .bind(artwork_id)
    .fetch_one(&state.pool)
    .await?;
    if !exists {
        return Err(AppError::not_found("作品が見つかりません"));
    }
    if count >= MAX_PER_ARTWORK {
        return Err(AppError::conflict(format!("おもいでは 1 つの作品に {MAX_PER_ARTWORK} 個までです")));
    }

    let id = Uuid::new_v4();
    let part = state.media_path(MediaKind::Memory, &format!(".upload-{id}.part"));
    let mut caption = String::new();
    let mut duration_ms = None;
    let mut width = None;
    let mut height = None;
    let mut upload: Option<(Accepted, u64)> = None;

    let read: AppResult<()> = async {
        while let Some(mut field) = multipart.next_field().await? {
            match field.name().unwrap_or("") {
                "file" if upload.is_none() => {
                    let accepted = classify(
                        field.content_type().unwrap_or(""),
                        field.file_name().unwrap_or(""),
                    )
                    .map_err(AppError::bad_request)?;
                    let bytes = stream_to_file(&mut field, &part, accepted).await?;
                    upload = Some((accepted, bytes));
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
    let Some((accepted, bytes)) = upload else {
        read?;
        return Err(AppError::bad_request("ファイルを選んでください"));
    };
    if let Err(error) = read {
        let _ = fs::remove_file(&part).await;
        return Err(error);
    }

    // 置くファイル (写真は縮めて JPEG にし、小さい画像も作る。動画と声は一時ファイルの名前を変えるだけ)
    let tag = &Uuid::new_v4().simple().to_string()[..8];
    let file = format!("{id}-{tag}.{}", accepted.ext);
    let mut thumb_file = None;
    let mut stored_bytes = bytes as i64;
    if accepted.kind == MemoryKind::Photo {
        let original = fs::read(&part).await;
        let _ = fs::remove_file(&part).await;
        let photo = tokio::task::spawn_blocking(move || media::process_photo(&original?).map_err(std::io::Error::other))
            .await?
            .map_err(|e| AppError::bad_request(format!("写真を読み込めません: {e}")))?;
        let thumb = format!("{id}-{tag}-thumb.jpg");
        write_files(
            &state,
            &[
                (MediaKind::Memory, file.clone(), &photo.display_jpeg),
                (MediaKind::Memory, thumb.clone(), &photo.thumb_jpeg),
            ],
        )
        .await?;
        stored_bytes = photo.display_jpeg.len() as i64;
        width = Some(photo.width as i32);
        height = Some(photo.height as i32);
        duration_ms = None;
        thumb_file = Some(thumb);
    } else {
        if let Err(error) = fs::rename(&part, state.media_path(MediaKind::Memory, &file)).await {
            let _ = fs::remove_file(&part).await;
            return Err(error.into());
        }
        if accepted.kind == MemoryKind::Audio {
            width = None;
            height = None;
        }
    }

    let inserted = sqlx::query_as::<_, MemoryRow>(&format!(
        "INSERT INTO artwork_memories (id, artwork_id, kind, file, thumb_file, mime, bytes, duration_ms, width, height, caption) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING {COLUMNS}"
    ))
    .bind(id)
    .bind(artwork_id)
    .bind(accepted.kind.as_str())
    .bind(&file)
    .bind(&thumb_file)
    .bind(accepted.mime)
    .bind(stored_bytes)
    .bind(duration_ms)
    .bind(width)
    .bind(height)
    .bind(&caption)
    .fetch_one(&state.pool)
    .await;
    match inserted {
        Ok(row) => {
            println!("[Memory] {} を足しました ({} bytes)", accepted.kind.label(), stored_bytes);
            Ok((StatusCode::CREATED, Json(row.into())))
        }
        Err(error) => {
            // 作品が同時に消された (外部キー) ときなど
            remove_files(&state, std::iter::once((MediaKind::Memory, file)).chain(thumb_file.map(|t| (MediaKind::Memory, t))))
                .await;
            Err(error.into())
        }
    }
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
    let row = sqlx::query_as::<_, MemoryRow>(&format!(
        "UPDATE artwork_memories SET caption = $3 WHERE id = $1 AND artwork_id = $2 RETURNING {COLUMNS}"
    ))
    .bind(memory_id)
    .bind(artwork_id)
    .bind(&caption)
    .fetch_optional(&state.pool)
    .await?
    .ok_or_else(not_found)?;
    Ok(Json(row.into()))
}

/// DELETE /api/artworks/{id}/memories/{memory_id}
pub async fn delete_memory(
    State(state): State<AppState>,
    Path((artwork_id, memory_id)): Path<(Uuid, Uuid)>,
) -> AppResult<StatusCode> {
    let (file, thumb) = sqlx::query_as::<_, (String, Option<String>)>(
        "DELETE FROM artwork_memories WHERE id = $1 AND artwork_id = $2 RETURNING file, thumb_file",
    )
    .bind(memory_id)
    .bind(artwork_id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or_else(not_found)?;
    remove_files(&state, std::iter::once(file).chain(thumb).map(|f| (MediaKind::Memory, f))).await;
    Ok(StatusCode::NO_CONTENT)
}

// =============================
// 起動時の掃除
// =============================

/// memories/ にあって表に無いファイルを消す (古いサーバーで作品を消したとき・送っている途中で止まった一時ファイル)。
/// 起動の途中 (まだ受け付けていないとき) に呼ぶ
pub async fn remove_orphans(state: &AppState) -> AppResult<()> {
    let rows = sqlx::query_as::<_, (String, Option<String>)>("SELECT file, thumb_file FROM artwork_memories")
        .fetch_all(&state.pool)
        .await?;
    let known: HashSet<String> = rows.into_iter().flat_map(|(f, t)| std::iter::once(f).chain(t)).collect();
    let dir = state.media_dir.join(MediaKind::Memory.dir());
    let mut entries = fs::read_dir(&dir).await?;
    let mut orphans = Vec::new();
    while let Some(entry) = entries.next_entry().await? {
        let name = entry.file_name().to_string_lossy().into_owned();
        if entry.file_type().await?.is_file() && !known.contains(&name) {
            orphans.push((MediaKind::Memory, name));
        }
    }
    if !orphans.is_empty() {
        println!("[Memory] removed {} orphan files", orphans.len());
        remove_files(state, orphans.into_iter()).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_by_content_type_then_extension() {
        let a = classify("image/png", "IMG_1.PNG").unwrap();
        assert_eq!((a.kind, a.ext, a.mime), (MemoryKind::Photo, "jpg", "image/jpeg"));
        // iPhone の動画
        let v = classify("video/quicktime", "IMG_0001.MOV").unwrap();
        assert_eq!((v.kind, v.ext), (MemoryKind::Video, "mov"));
        // Safari の録音 (codecs が付く)
        let s = classify("audio/mp4;codecs=mp4a.40.2", "voice").unwrap();
        assert_eq!((s.kind, s.ext, s.mime), (MemoryKind::Audio, "m4a", "audio/mp4"));
        // Chrome の録音。webm でも Content-Type が声なら声
        let c = classify("audio/webm;codecs=opus", "voice.webm").unwrap();
        assert_eq!((c.kind, c.ext), (MemoryKind::Audio, "weba"));
        // Content-Type が分からなければ拡張子で
        let m = classify("application/octet-stream", "memo.m4a").unwrap();
        assert_eq!(m.kind, MemoryKind::Audio);
        let w = classify("", "clip.webm").unwrap();
        assert_eq!(w.kind, MemoryKind::Video);
    }

    #[test]
    fn rejects_unknown_and_mismatched_files() {
        assert!(classify("application/pdf", "a.pdf").is_err());
        assert!(classify("", "noext").is_err());
        assert!(classify("image/heic", "IMG.HEIC").is_err());
        // 拡張子を書き換えたファイル
        assert!(classify("image/png", "clip.mp4").is_err());
    }

    #[test]
    fn limits_sizes_per_kind() {
        assert_eq!(MemoryKind::Video.max_bytes(), 100 * MB);
        assert_eq!(MemoryKind::Photo.max_bytes(), 20 * MB);
        assert_eq!(MemoryKind::Audio.max_bytes(), 20 * MB);
        assert!(UPLOAD_BODY_LIMIT as u64 > MemoryKind::Video.max_bytes());
    }

    #[test]
    fn checks_caption_and_measures() {
        assert_eq!(clean_caption("  はるかの声  ").unwrap(), "はるかの声");
        assert!(clean_caption(&"あ".repeat(CAPTION_MAX)).is_ok());
        assert!(clean_caption(&"あ".repeat(CAPTION_MAX + 1)).is_err());
        assert_eq!(parse_measure("", "長さ", 100).unwrap(), None);
        assert_eq!(parse_measure("12.6", "長さ", 100).unwrap(), Some(13));
        assert!(parse_measure("-1", "長さ", 100).is_err());
        assert!(parse_measure("abc", "長さ", 100).is_err());
        assert!(parse_measure("101", "長さ", 100).is_err());
    }

    #[test]
    fn tallies_counts_per_artwork() {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let counts = tally([
            (a, "photo".to_string(), 2),
            (a, "audio".to_string(), 1),
            (b, "video".to_string(), 3),
        ]);
        assert_eq!(counts[&a], MemoryCounts { photo: 2, video: 0, audio: 1 });
        assert_eq!(counts[&b], MemoryCounts { photo: 0, video: 3, audio: 0 });
        assert_eq!(counts.len(), 2);
    }
}
