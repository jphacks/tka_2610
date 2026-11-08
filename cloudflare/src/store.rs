//! 写真・GLB・おもいでのファイルの置き場所 (backend の media フォルダの代わり)。
//!
//! カードを登録しなくても使えるよう、R2 ではなく Durable Object の SQLite に入れる。
//! 1 行に入る大きさに上限があるので、CHUNK ごとに media_chunks に分けて入れ、読むときにつなげる。
//! 動画は Range で一部だけを返す (早送りできるように。1 回に返すのは MAX_RANGE まで)。

use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use futures_util::StreamExt;
use serde::Deserialize;

use crate::{
    db::Db,
    error::{AppError, AppResult},
    params,
    state::{AppState, MediaKind},
};

/// 1 行に入れる大きさ
pub const CHUNK: usize = 1024 * 1024;

/// Range の要求に 1 回で返すいちばん大きな長さ (メモリを使いすぎないように)
const MAX_RANGE: u64 = 4 * 1024 * 1024;

pub fn path_of(kind: MediaKind, file: &str) -> String {
    format!("{}/{}", kind.dir(), file)
}

/// 拡張子から Content-Type
pub fn mime_of(file: &str) -> &'static str {
    let ext = file.rsplit('.').next().unwrap_or_default().to_ascii_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "glb" => "model/gltf-binary",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "m4a" => "audio/mp4",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" | "oga" => "audio/ogg",
        "aac" => "audio/aac",
        _ => "application/octet-stream",
    }
}

/// ファイルを書く (同じ名前があれば置き換える)
pub fn put(db: &Db, kind: MediaKind, file: &str, bytes: &[u8]) -> AppResult<()> {
    let path = path_of(kind, file);
    db.exec("DELETE FROM media_chunks WHERE path = ?", params![path])?;
    db.exec(
        "INSERT INTO media_files (path, mime, size, chunk_size) VALUES (?, ?, ?, ?) \
         ON CONFLICT (path) DO UPDATE SET mime = excluded.mime, size = excluded.size, chunk_size = excluded.chunk_size",
        params![path, mime_of(file), bytes.len(), CHUNK],
    )?;
    for (idx, chunk) in bytes.chunks(CHUNK).enumerate() {
        db.exec("INSERT INTO media_chunks (path, idx, data) VALUES (?, ?, ?)", params![path, idx, chunk])?;
    }
    Ok(())
}

/// 少しずつ届くファイルを書く (おもいでの動画など。全部をメモリに持たない)。最後に finish を呼ぶ
pub struct Writer {
    path: String,
    mime: &'static str,
    buffer: Vec<u8>,
    next: usize,
    size: usize,
}

impl Writer {
    pub fn new(db: &Db, kind: MediaKind, file: &str) -> AppResult<Self> {
        let path = path_of(kind, file);
        db.exec("DELETE FROM media_chunks WHERE path = ?", params![path])?;
        // 書いている途中のファイルは size = -1 (読まれない)
        db.exec(
            "INSERT INTO media_files (path, mime, size, chunk_size) VALUES (?, ?, -1, ?) \
             ON CONFLICT (path) DO UPDATE SET size = -1",
            params![path, mime_of(file), CHUNK],
        )?;
        Ok(Writer { path, mime: mime_of(file), buffer: Vec::with_capacity(CHUNK), next: 0, size: 0 })
    }

    pub fn write(&mut self, db: &Db, mut bytes: &[u8]) -> AppResult<()> {
        self.size += bytes.len();
        while !bytes.is_empty() {
            let take = (CHUNK - self.buffer.len()).min(bytes.len());
            self.buffer.extend_from_slice(&bytes[..take]);
            bytes = &bytes[take..];
            if self.buffer.len() == CHUNK {
                self.flush(db)?;
            }
        }
        Ok(())
    }

    fn flush(&mut self, db: &Db) -> AppResult<()> {
        if self.buffer.is_empty() {
            return Ok(());
        }
        db.exec("INSERT INTO media_chunks (path, idx, data) VALUES (?, ?, ?)", params![self.path, self.next, self.buffer])?;
        self.next += 1;
        self.buffer.clear();
        Ok(())
    }

    pub fn size(&self) -> usize {
        self.size
    }

    pub fn finish(mut self, db: &Db) -> AppResult<()> {
        self.flush(db)?;
        db.exec(
            "UPDATE media_files SET size = ?, mime = ? WHERE path = ?",
            params![self.size, self.mime, self.path],
        )?;
        Ok(())
    }

    /// 途中でやめる (書いた分を消す)
    pub fn abort(self, db: &Db) {
        let _ = db.exec("DELETE FROM media_files WHERE path = ?", params![self.path]);
        let _ = db.exec("DELETE FROM media_chunks WHERE path = ?", params![self.path]);
    }
}

#[derive(Deserialize)]
struct FileRow {
    mime: String,
    size: i64,
    chunk_size: i64,
}

fn file_row(db: &Db, path: &str) -> AppResult<Option<FileRow>> {
    Ok(db
        .opt::<FileRow>("SELECT mime, size, chunk_size FROM media_files WHERE path = ?", params![path])?
        .filter(|f| f.size >= 0))
}

/// [start, end) のバイトを読む
fn read_range(db: &Db, path: &str, chunk_size: u64, start: u64, end: u64) -> AppResult<Vec<u8>> {
    if start >= end {
        return Ok(Vec::new());
    }
    let first = start / chunk_size;
    let last = (end - 1) / chunk_size;
    let chunks: Vec<(i64, serde_bytes::ByteBuf)> = db.tuples(
        "SELECT idx, data FROM media_chunks WHERE path = ? AND idx BETWEEN ? AND ? ORDER BY idx",
        params![path, first as i64, last as i64],
    )?;
    let mut out = Vec::with_capacity((end - start) as usize);
    for (idx, data) in chunks {
        let base = idx as u64 * chunk_size;
        let from = start.saturating_sub(base) as usize;
        let to = ((end - base) as usize).min(data.len());
        if from < to {
            out.extend_from_slice(&data[from..to]);
        }
    }
    Ok(out)
}

/// ファイル全体を読む (無ければ None)
pub fn get(db: &Db, kind: MediaKind, file: &str) -> AppResult<Option<Vec<u8>>> {
    let path = path_of(kind, file);
    let Some(row) = file_row(db, &path)? else { return Ok(None) };
    Ok(Some(read_range(db, &path, row.chunk_size as u64, 0, row.size as u64)?))
}

/// ファイルを消す (無くてもよい)
pub fn remove(db: &Db, kind: MediaKind, file: &str) {
    let path = path_of(kind, file);
    if let Err(error) = db
        .exec("DELETE FROM media_chunks WHERE path = ?", params![path])
        .and_then(|_| db.exec("DELETE FROM media_files WHERE path = ?", params![path]))
    {
        worker::console_error!("[Storage] Failed to remove {path}: {}", error.message);
    }
}

pub fn remove_all(db: &Db, files: impl Iterator<Item = (MediaKind, String)>) {
    for (kind, file) in files {
        remove(db, kind, &file);
    }
}

/// "bytes=start-end" を読む (1 つの範囲だけ)
fn parse_range(value: &str, size: u64) -> Option<(u64, u64)> {
    let spec = value.strip_prefix("bytes=")?;
    let (from, to) = spec.split_once('-')?;
    let (start, end) = if from.is_empty() {
        // 後ろから n バイト
        let n: u64 = to.parse().ok()?;
        (size.saturating_sub(n), size)
    } else {
        let start: u64 = from.parse().ok()?;
        let end = if to.is_empty() { size } else { to.parse::<u64>().ok()?.saturating_add(1).min(size) };
        (start, end)
    };
    (start < end && start < size).then_some((start, end))
}

/// GET /media/{dir}/{file}
pub async fn serve(State(state): State<AppState>, Path((dir, file)): Path<(String, String)>, headers: HeaderMap) -> Response {
    match serve_file(&state.db, &dir, &file, &headers) {
        Ok(response) => response,
        Err(error) => error.into_response(),
    }
}

fn serve_file(db: &Db, dir: &str, file: &str, headers: &HeaderMap) -> AppResult<Response> {
    let path = format!("{dir}/{file}");
    let Some(row) = file_row(db, &path)? else {
        return Ok((StatusCode::NOT_FOUND, "Not Found").into_response());
    };
    let size = row.size as u64;
    let chunk_size = row.chunk_size as u64;
    let range = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(|v| parse_range(v, size).ok_or(()));

    let mut builder = Response::builder()
        .header(header::CONTENT_TYPE, row.mime.as_str())
        .header(header::ACCEPT_RANGES, "bytes")
        // ファイル名は中身が変わるたびに変わる (backend の /media と同じ)
        .header(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=31536000, immutable"));

    let (status, start, end) = match range {
        // 大きなファイルは、1 行ずつ読みながら返す (全部をメモリに持たない)
        None if size > MAX_RANGE => {
            let db = db.clone();
            let chunks = size.div_ceil(chunk_size);
            let stream = futures_util::stream::iter(0..chunks).map(move |idx| {
                let start = idx * chunk_size;
                read_range(&db, &path, chunk_size, start, (start + chunk_size).min(size))
                    .map(axum::body::Bytes::from)
                    .map_err(|e| std::io::Error::other(e.message))
            });
            return builder
                .status(StatusCode::OK)
                .header(header::CONTENT_LENGTH, size)
                .body(Body::from_stream(stream))
                .map_err(AppError::internal);
        }
        None => (StatusCode::OK, 0, size),
        Some(Err(())) => {
            return Ok(Response::builder()
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(header::CONTENT_RANGE, format!("bytes */{size}"))
                .body(Body::empty())
                .map_err(AppError::internal)?);
        }
        Some(Ok((start, end))) => {
            let end = end.min(start + MAX_RANGE);
            builder = builder.header(header::CONTENT_RANGE, format!("bytes {start}-{}/{size}", end - 1));
            (StatusCode::PARTIAL_CONTENT, start, end)
        }
    };
    let bytes = read_range(db, &path, chunk_size, start, end)?;
    builder
        .status(status)
        .header(header::CONTENT_LENGTH, bytes.len())
        .body(Body::from(bytes))
        .map_err(AppError::internal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ranges() {
        assert_eq!(parse_range("bytes=0-", 100), Some((0, 100)));
        assert_eq!(parse_range("bytes=10-19", 100), Some((10, 20)));
        assert_eq!(parse_range("bytes=90-200", 100), Some((90, 100)));
        assert_eq!(parse_range("bytes=-10", 100), Some((90, 100)));
        assert_eq!(parse_range("bytes=100-", 100), None);
        assert_eq!(parse_range("items=0-1", 100), None);
    }
}
