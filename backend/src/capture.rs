//! iPhone で撮った写真 (capture/ の Memoria Capture) を、写真から 3D を作る (generator.rs) の入力にする。試験中。
//!
//! - 受信サーバー (capture/receiver) が受け取った撮影は `CAPTURE_DATA_DIR` (既定は capture/captures) の
//!   `sessions/<sessionId>/` にある (session.json・photos/*.jpg)。転送の途中の `incoming/` は読まない
//! - `GET /api/capture/sessions` で一覧にし、`POST /api/artworks/{id}/generate` の `capture_session` で選ぶと、
//!   写真を 8 枚まで方位がばらけるように選び、まっすぐに回して kt auto に渡す
//! - 使えるのは写真から 3D を作る機能と同じく `KT_GENERATOR_ENABLED=1` のときだけ (それ以外は 404)
//!
//! session.json の形は capture/docs/data-format.md。仕組みは docs/generator.md。

use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
};

use axum::{extract::State, Json};
use chrono::{DateTime, FixedOffset};
use image::DynamicImage;
use serde::{Deserialize, Serialize};

use crate::{
    error::{AppError, AppResult},
    media,
    state::AppState,
};

/// session.json の `schema`・`schemaVersion`
const SCHEMA: &str = "memoria.capture.session";
const SCHEMA_VERSION: u32 = 1;
/// 上から見下ろす写真とみなす仰角 (度)。1 枚だけ混ぜる
const TOP_ELEVATION_DEG: f64 = 60.0;
/// まわりの写真で好む仰角 (度) と、方位の差 1° に対する仰角の差の重み (横から撮った写真を少し優先する)
const AROUND_ELEVATION_DEG: f64 = 20.0;
const ELEVATION_WEIGHT: f64 = 0.25;
/// 写真を回したあとの JPEG の質
const JPEG_QUALITY: u8 = 92;

// =============================
// session.json (使う項目だけ。知らない項目は無視する)
// =============================

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub schema: String,
    pub schema_version: u32,
    pub session_id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub object: Option<ObjectSize>,
    #[serde(default)]
    pub reference_frames: Vec<ReferenceFrame>,
    #[serde(default)]
    pub photos: Vec<Photo>,
}

/// 作品の大きさ (m。AR のガイドで合わせた値)
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObjectSize {
    #[serde(default)]
    pub height_m: Option<f64>,
    #[serde(default)]
    pub radius_m: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReferenceFrame {
    pub id: String,
    #[serde(default)]
    pub object: Option<ObjectSize>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Photo {
    pub photo_id: String,
    #[serde(default)]
    pub sequence: i64,
    #[serde(default)]
    pub reference_frame_id: Option<String>,
    pub image: PhotoImage,
    #[serde(default)]
    pub direction: Option<Direction>,
    #[serde(default)]
    pub mask: Option<Mask>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhotoImage {
    pub file: String,
    /// まっすぐ見るために時計回りに回す角度 (保存した JPEG はセンサーの向きの横長、EXIF Orientation は 1)
    #[serde(default)]
    pub display_rotation_deg_clockwise: Option<i32>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Direction {
    #[serde(default)]
    pub confirmed: bool,
    #[serde(default)]
    pub target_id: Option<String>,
    #[serde(default)]
    pub azimuth_deg: Option<f64>,
    #[serde(default)]
    pub elevation_deg: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Mask {
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub check: Option<MaskCheck>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MaskCheck {
    #[serde(default)]
    pub status: Option<String>,
}

// =============================
// 撮影の id とフォルダ
// =============================

/// 撮影の id (UUID、ハイフン付き 36 文字だけ。大文字にそろえて返す)。フォルダ名に使うので、ほかの形は受け付けない
pub fn parse_session_id(value: &str) -> Result<String, String> {
    let value = value.trim();
    let ok = value.len() == 36
        && value.chars().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        });
    if ok {
        Ok(value.to_ascii_uppercase())
    } else {
        Err("撮影の id が正しくありません".into())
    }
}

/// 写真のファイル (`photos/<photoId>.jpg` の形だけ。ほかの場所は読まない)
fn photo_file(photo: &Photo) -> Option<String> {
    let id = parse_session_id(&photo.photo_id).ok()?;
    let expected = format!("photos/{id}.jpg");
    photo.image.file.eq_ignore_ascii_case(&expected).then_some(expected)
}

/// session.json を読んで確かめる (形・schema・版・フォルダ名と sessionId が合うか)
pub fn parse_session(json: &[u8], folder_id: &str) -> Result<Session, String> {
    let session: Session = serde_json::from_slice(json).map_err(|e| format!("session.json を読めません ({e})"))?;
    if session.schema != SCHEMA || session.schema_version != SCHEMA_VERSION {
        return Err(format!("知らない形です ({} v{})", session.schema, session.schema_version));
    }
    if !session.session_id.eq_ignore_ascii_case(folder_id) {
        return Err(format!("sessionId ({}) がフォルダ名と違います", session.session_id));
    }
    Ok(session)
}

fn sessions_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("sessions")
}

/// 撮影を 1 つ読む (無ければ Err)
pub async fn load_session(data_dir: &Path, session_id: &str) -> Result<(PathBuf, Session), String> {
    let folder = sessions_dir(data_dir).join(session_id);
    let json = tokio::fs::read(folder.join("session.json")).await.map_err(|_| "その撮影はありません".to_string())?;
    let session = parse_session(&json, session_id)?;
    Ok((folder, session))
}

// =============================
// 大きさ・使える写真・選び方
// =============================

/// 大きさ (cm)。最後に設定した基準の大きさ (無ければ上の object) から、高さ = heightM × 100、直径 = radiusM × 200。
/// 0 以下・500 cm を超える値は入れない。どちらも無ければ None
pub fn size_cm(session: &Session) -> Option<Vec<f64>> {
    let object = session.reference_frames.iter().rev().find_map(|f| f.object).or(session.object)?;
    let round = |v: f64| (v * 10.0).round() / 10.0;
    let sizes: Vec<f64> = [object.height_m.map(|h| h * 100.0), object.radius_m.map(|r| r * 200.0)]
        .into_iter()
        .flatten()
        .map(round)
        .filter(|v| v.is_finite() && *v > 0.0 && *v <= 500.0)
        .collect();
    (!sizes.is_empty()).then_some(sizes)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MaskOutcome {
    Good,
    Pending,
    Bad,
}

/// マスクが使えるか (data-format.md の「撮影の進み具合」と同じ決まり)
fn mask_outcome(photo: &Photo) -> MaskOutcome {
    let Some(mask) = &photo.mask else { return MaskOutcome::Pending };
    let check = mask.check.as_ref().and_then(|c| c.status.as_deref());
    match (mask.status.as_deref(), check) {
        (Some("confirmed"), _) | (Some("candidate"), Some("ok")) => MaskOutcome::Good,
        (Some("notGenerated") | Some("processing") | None, _) | (Some("candidate"), None) => MaskOutcome::Pending,
        _ => MaskOutcome::Bad,
    }
}

/// 置き換え済みの写真 (基準と撮影方向ごとに、代表の写真 (使える写真のうち一番新しいもの、無ければ一番新しい写真) 以外。
/// ただし代表より新しくてまだ分からない写真は除く)。iPhone の CaptureCore の Coverage.progress と同じ決まり
fn superseded(session: &Session) -> HashSet<String> {
    let mut groups: HashMap<(&str, &str), Vec<&Photo>> = HashMap::new();
    for photo in &session.photos {
        if let (Some(frame), Some(direction)) = (photo.reference_frame_id.as_deref(), &photo.direction)
            && direction.confirmed
            && let Some(target) = direction.target_id.as_deref()
        {
            groups.entry((frame, target)).or_default().push(photo);
        }
    }
    let mut out = HashSet::new();
    for shots in groups.values_mut() {
        shots.sort_by_key(|p| p.sequence);
        let winner = shots.iter().rev().find(|p| mask_outcome(p) == MaskOutcome::Good).or(shots.last()).copied();
        let Some(winner) = winner else { continue };
        for shot in shots.iter() {
            let newer_pending = shot.sequence > winner.sequence && mask_outcome(shot) == MaskOutcome::Pending;
            if shot.photo_id != winner.photo_id && !newer_pending {
                out.insert(shot.photo_id.clone());
            }
        }
    }
    out
}

/// 方位の分かる、選べる写真 (方向が確定・方位あり・置き換え済みでない・ファイル名が正しい)
fn usable_photos(session: &Session) -> Vec<&Photo> {
    let superseded = superseded(session);
    session
        .photos
        .iter()
        .filter(|p| {
            p.direction.as_ref().is_some_and(|d| d.confirmed && d.azimuth_deg.is_some_and(f64::is_finite))
                && !superseded.contains(&p.photo_id)
                && photo_file(p).is_some()
        })
        .collect()
}

fn azimuth(photo: &Photo) -> f64 {
    photo.direction.as_ref().and_then(|d| d.azimuth_deg).unwrap_or(0.0).rem_euclid(360.0)
}

fn elevation(photo: &Photo) -> f64 {
    photo.direction.as_ref().and_then(|d| d.elevation_deg).unwrap_or(0.0)
}

/// 2 つの方位の差 (0〜180 度)
fn azimuth_gap(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(360.0);
    d.min(360.0 - d)
}

/// kt に渡す写真を `max` 枚まで選ぶ。
///
/// 方位の確定した写真がある最後の基準 (基準が違うと方位を比べられない) の写真から、上から見下ろす写真 (仰角 60° 以上) が
/// あれば一番高い 1 枚と、残りを 360° を等分した方位に近い写真 (方位の差 ＋ 仰角 20° からの差 × 0.25 が一番小さいもの) を選ぶ。方位の確定した写真が
/// 1 枚も無いときは、撮った順に等しい間隔で選ぶ。返す順は、まわりの写真を方位の順、そのあと上からの写真
pub fn select_photos(session: &Session, max: usize) -> Vec<&Photo> {
    let usable = usable_photos(session);
    let frame = session
        .reference_frames
        .iter()
        .rev()
        .find(|f| usable.iter().any(|p| p.reference_frame_id.as_deref() == Some(f.id.as_str())));
    let mut pool: Vec<&Photo> = match frame {
        Some(frame) => usable.into_iter().filter(|p| p.reference_frame_id.as_deref() == Some(frame.id.as_str())).collect(),
        None => usable,
    };

    if pool.is_empty() {
        // 方位が分からない: 撮った順に等しい間隔で
        let mut all: Vec<&Photo> = session.photos.iter().filter(|p| photo_file(p).is_some()).collect();
        all.sort_by_key(|p| p.sequence);
        if all.len() <= max {
            return all;
        }
        return (0..max).map(|k| all[k * all.len() / max]).collect();
    }

    if pool.len() <= max {
        pool.sort_by(|a, b| azimuth(a).total_cmp(&azimuth(b)).then(elevation(a).total_cmp(&elevation(b))));
        return pool;
    }

    let top = pool
        .iter()
        .copied()
        .filter(|p| elevation(p) >= TOP_ELEVATION_DEG)
        .max_by(|a, b| elevation(a).total_cmp(&elevation(b)).then(azimuth_gap(azimuth(b), 0.0).total_cmp(&azimuth_gap(azimuth(a), 0.0))));
    if let Some(top) = top {
        pool.retain(|p| p.photo_id != top.photo_id);
    }
    let slots = max - usize::from(top.is_some());
    let mut picked: Vec<&Photo> = Vec::with_capacity(max);
    for k in 0..slots {
        let target = k as f64 * 360.0 / slots as f64;
        let best = pool
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| {
                let score = |p: &Photo| {
                    azimuth_gap(azimuth(p), target) + ELEVATION_WEIGHT * (elevation(p) - AROUND_ELEVATION_DEG).abs()
                };
                score(a).total_cmp(&score(b)).then(elevation(a).total_cmp(&elevation(b)))
            })
            .map(|(i, _)| i);
        if let Some(i) = best {
            picked.push(pool.swap_remove(i));
        }
    }
    picked.sort_by(|a, b| azimuth(a).total_cmp(&azimuth(b)));
    picked.extend(top);
    picked
}

// =============================
// 写真をまっすぐにする
// =============================

/// 保存した JPEG (センサーの向き) を、displayRotationDegClockwise だけ時計回りに回した JPEG にする。0° はそのまま返す
pub fn upright_jpeg(bytes: &[u8], rotation_deg_clockwise: i32) -> Result<Vec<u8>, String> {
    let rotation = rotation_deg_clockwise.rem_euclid(360);
    if rotation == 0 {
        return Ok(bytes.to_vec());
    }
    let image = image::load_from_memory(bytes).map_err(|e| format!("写真を読めません ({e})"))?;
    let rotated: DynamicImage = match rotation {
        90 => image.rotate90(),
        180 => image.rotate180(),
        270 => image.rotate270(),
        other => return Err(format!("写真の向き ({other}°) が分かりません")),
    };
    Ok(media::encode_jpeg(&rotated, JPEG_QUALITY))
}

/// 選んだ撮影の写真を、まっすぐにして `out_dir/photo<N>.jpg` に書く。大きさ (cm) も返す (分からなければ None)
pub async fn prepare_photos(
    data_dir: &Path,
    session_id: &str,
    max: usize,
    out_dir: &Path,
) -> AppResult<(Vec<PathBuf>, Option<Vec<f64>>)> {
    let (folder, session) = load_session(data_dir, session_id).await.map_err(AppError::not_found)?;
    let chosen: Vec<(String, i32)> = select_photos(&session, max)
        .into_iter()
        .filter_map(|p| Some((photo_file(p)?, p.image.display_rotation_deg_clockwise.unwrap_or(0))))
        .collect();
    if chosen.is_empty() {
        return Err(AppError::bad_request("この撮影には使える写真がありません"));
    }
    let size = size_cm(&session);
    let out_dir = out_dir.to_path_buf();
    let written = tokio::task::spawn_blocking(move || -> Result<Vec<PathBuf>, String> {
        std::fs::create_dir_all(&out_dir).map_err(|e| e.to_string())?;
        chosen
            .iter()
            .enumerate()
            .map(|(i, (file, rotation))| {
                let bytes = std::fs::read(folder.join(file)).map_err(|e| format!("{file} を読めません ({e})"))?;
                let path = out_dir.join(format!("photo{}.jpg", i + 1));
                std::fs::write(&path, upright_jpeg(&bytes, *rotation)?).map_err(|e| e.to_string())?;
                Ok(path)
            })
            .collect()
    })
    .await?
    .map_err(|error| {
        println!("[Capture] {session_id} の写真を用意できません ({error})");
        AppError::bad_request("撮影の写真を読めませんでした")
    })?;
    Ok((written, size))
}

// =============================
// 一覧
// =============================

#[derive(Debug, Serialize)]
pub struct SessionSummary {
    pub session_id: String,
    pub title: String,
    pub created_at: Option<String>,
    /// 撮った日時 (例: "2026年11月9日 11:53"。撮った場所の時刻)。分からなければ空
    pub created_label: String,
    /// 写真の数
    pub photo_count: usize,
    /// 方位の確定した、置き換え済みでない写真の数 (3D を作るときはここから選ぶ)
    pub usable_count: usize,
    /// 作品の大きさ (cm。[高さ, 直径])。分からなければ null
    pub size_cm: Option<Vec<f64>>,
}

impl SessionSummary {
    fn new(session: &Session) -> Self {
        SessionSummary {
            session_id: session.session_id.to_ascii_uppercase(),
            title: session.title.clone().unwrap_or_default(),
            created_at: session.created_at.clone(),
            created_label: session
                .created_at
                .as_deref()
                .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
                .map(|t| t.format("%Y年%-m月%-d日 %H:%M").to_string())
                .unwrap_or_default(),
            photo_count: session.photos.len(),
            usable_count: usable_photos(session).len(),
            size_cm: size_cm(session),
        }
    }
}

fn created(summary: &SessionSummary) -> Option<DateTime<FixedOffset>> {
    summary.created_at.as_deref().and_then(|t| DateTime::parse_from_rfc3339(t).ok())
}

/// `sessions/` の撮影を新しい順に並べる。読めない session.json は飛ばす (ログを出す)。フォルダが無ければ空
pub fn list_sessions(data_dir: &Path) -> Vec<SessionSummary> {
    let Ok(entries) = std::fs::read_dir(sessions_dir(data_dir)) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let Ok(id) = parse_session_id(&name) else { continue };
        if !entry.path().is_dir() {
            continue;
        }
        let parsed = std::fs::read(entry.path().join("session.json"))
            .map_err(|e| format!("session.json を読めません ({e})"))
            .and_then(|json| parse_session(&json, &id));
        match parsed {
            Ok(session) => out.push(SessionSummary::new(&session)),
            Err(error) => println!("[Capture] {name} を飛ばしました ({error})"),
        }
    }
    out.sort_by(|a, b| created(b).cmp(&created(a)).then_with(|| a.session_id.cmp(&b.session_id)));
    out
}

/// GET /api/capture/sessions (写真から 3D を作る機能が使えないときは 404)
pub async fn sessions(State(state): State<AppState>) -> AppResult<Json<Vec<SessionSummary>>> {
    let Some(config) = state.generator.config() else {
        return Err(AppError::not_found("写真から 3D を作る機能は使えません"));
    };
    let dir = config.capture_dir.clone();
    Ok(Json(tokio::task::spawn_blocking(move || list_sessions(&dir)).await?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Cursor;

    const SID: &str = "844B473E-F087-4E5F-9689-368D359E4376";

    fn pid(n: u32) -> String {
        format!("00000000-0000-0000-0000-{n:012X}")
    }

    /// 写真 1 枚の JSON
    fn photo(n: u32, frame: Option<&str>, confirmed: bool, target: Option<&str>, az: f64, el: f64, mask: &str) -> serde_json::Value {
        json!({
            "photoId": pid(n), "sequence": n, "referenceFrameId": frame,
            "image": { "file": format!("photos/{}.jpg", pid(n)), "displayRotationDegClockwise": 90 },
            "direction": { "confirmed": confirmed, "targetId": target, "azimuthDeg": az, "elevationDeg": el },
            "mask": { "status": mask, "check": if mask == "candidate" { json!({ "status": "ok" }) } else { json!(null) } },
        })
    }

    fn session(photos: Vec<serde_json::Value>, frames: serde_json::Value, object: serde_json::Value) -> Session {
        let value = json!({
            "schema": SCHEMA, "schemaVersion": 1, "sessionId": SID, "title": "ねこ",
            "createdAt": "2026-11-09T10:00:00+09:00", "object": object,
            "referenceFrames": frames, "photos": photos, "extraFieldIgnored": { "a": 1 },
        });
        parse_session(value.to_string().as_bytes(), SID).unwrap()
    }

    fn ring(frame: &str, count: u32, el: f64, first: u32) -> Vec<serde_json::Value> {
        (0..count)
            .map(|i| {
                let az = i as f64 * 360.0 / count as f64;
                photo(first + i, Some(frame), true, Some(&format!("t{az}-{el}")), az, el, "candidate")
            })
            .collect()
    }

    #[test]
    fn validates_session_ids() {
        assert_eq!(parse_session_id(SID).unwrap(), SID);
        assert_eq!(parse_session_id(&SID.to_lowercase()).unwrap(), SID);
        for bad in ["", "..", "../etc/passwd", "844B473E", "844B473EF0874E5F9689368D359E4376", "{844B473E-F087-4E5F-9689-368D359E4376}",
            "844B473E-F087-4E5F-9689-368D359E437/", "844B473E/F087-4E5F-9689-368D359E4376", "G44B473E-F087-4E5F-9689-368D359E4376"]
        {
            assert!(parse_session_id(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn parses_good_and_rejects_malformed_sessions() {
        let s = session(ring("ref-1", 4, 20.0, 1), json!([{ "id": "ref-1" }]), json!({ "heightM": 0.15, "radiusM": 0.08 }));
        assert_eq!((s.title.as_deref(), s.photos.len()), (Some("ねこ"), 4));

        assert!(parse_session(b"{ not json", SID).is_err());
        assert!(parse_session(json!({ "schema": "other", "schemaVersion": 1, "sessionId": SID }).to_string().as_bytes(), SID).is_err());
        assert!(parse_session(json!({ "schema": SCHEMA, "schemaVersion": 2, "sessionId": SID }).to_string().as_bytes(), SID).is_err());
        let other = "11111111-2222-3333-4444-555555555555";
        assert!(parse_session(json!({ "schema": SCHEMA, "schemaVersion": 1, "sessionId": other }).to_string().as_bytes(), SID).is_err());
        // 項目が足りなくても (object・photos なし) 読める
        let bare = parse_session(json!({ "schema": SCHEMA, "schemaVersion": 1, "sessionId": SID }).to_string().as_bytes(), SID).unwrap();
        assert!(bare.photos.is_empty() && size_cm(&bare).is_none());
    }

    #[test]
    fn derives_size_from_the_latest_reference_frame() {
        let top = json!({ "heightM": 0.04, "radiusM": 0.09 });
        // 基準に大きさが無い (前の版) → 上の object
        let s = session(vec![], json!([{ "id": "ref-1", "object": null }]), top.clone());
        assert_eq!(size_cm(&s), Some(vec![4.0, 18.0]));
        // 最後の基準の大きさを使う
        let s = session(
            vec![],
            json!([{ "id": "ref-1", "object": { "heightM": 0.1, "radiusM": 0.1 } }, { "id": "ref-2", "object": { "heightM": 0.153, "radiusM": 0.0825 } }]),
            top,
        );
        assert_eq!(size_cm(&s), Some(vec![15.3, 16.5]));
        // 片方だけ・どちらも無い
        assert_eq!(size_cm(&session(vec![], json!([]), json!({ "heightM": 0.2 }))), Some(vec![20.0]));
        assert_eq!(size_cm(&session(vec![], json!([]), json!(null))), None);
        assert_eq!(size_cm(&session(vec![], json!([]), json!({ "heightM": 0.0, "radiusM": -1.0 }))), None);
    }

    #[test]
    fn spreads_selected_photos_around_and_adds_one_from_above() {
        // photogrammetry の一覧に近い形: 20° に 24 枚、45° に 16 枚、70° に 8 枚
        let mut photos = ring("ref-1", 24, 20.0, 1);
        photos.extend(ring("ref-1", 16, 45.0, 101));
        photos.extend(ring("ref-1", 8, 70.0, 201));
        let s = session(photos, json!([{ "id": "ref-1" }]), json!(null));
        let picked = select_photos(&s, 8);
        assert_eq!(picked.len(), 8);
        // 最後の 1 枚は上から
        assert_eq!(elevation(picked[7]), 70.0);
        // まわりの 7 枚は方位がばらける (隣どうしが 40° 以上離れる)、仰角の低い方
        let around: Vec<f64> = picked[..7].iter().map(|p| azimuth(p)).collect();
        assert!(picked[..7].iter().all(|p| elevation(p) == 20.0), "{around:?}");
        for w in around.windows(2) {
            assert!(w[1] - w[0] >= 40.0, "{around:?}");
        }
        assert!(azimuth_gap(around[0], around[6]) >= 40.0);
        assert_eq!(around[0], 0.0);
    }

    #[test]
    fn selects_from_the_last_reference_frame_and_skips_superseded_photos() {
        let mut photos = ring("ref-1", 8, 20.0, 1);
        let mut second = ring("ref-2", 3, 20.0, 50);
        // ref-2 の同じ方向をもう一度撮った (新しい方のマスクが使えない → 古い方が代表、新しい方は置き換え済み)
        let mut retake = photo(60, Some("ref-2"), true, Some("t0-20"), 1.0, 20.0, "failed");
        retake["mask"]["check"] = json!(null);
        second.push(retake);
        // 方向の確定していない写真・基準の無い写真は使わない
        second.push(photo(70, Some("ref-2"), false, None, 200.0, 20.0, "candidate"));
        second.push(photo(71, None, false, None, 0.0, 0.0, "noObject"));
        photos.extend(second);
        let s = session(photos, json!([{ "id": "ref-1" }, { "id": "ref-2" }]), json!(null));

        assert!(superseded(&s).contains(&pid(60)));
        let picked: Vec<String> = select_photos(&s, 8).iter().map(|p| p.photo_id.clone()).collect();
        assert_eq!(picked, vec![pid(50), pid(51), pid(52)]);
        assert_eq!(SessionSummary::new(&s).usable_count, 8 + 3);
        assert_eq!(SessionSummary::new(&s).photo_count, 8 + 6);
    }

    #[test]
    fn falls_back_to_capture_order_without_directions() {
        let photos: Vec<_> = (1..=20).map(|n| photo(n, None, false, None, 0.0, 0.0, "notGenerated")).collect();
        let s = session(photos, json!([]), json!(null));
        let picked: Vec<i64> = select_photos(&s, 8).iter().map(|p| p.sequence).collect();
        assert_eq!(picked, vec![1, 3, 6, 8, 11, 13, 16, 18]);
    }

    #[test]
    fn rejects_photo_files_outside_photos() {
        let mut bad = photo(1, Some("ref-1"), true, Some("t"), 0.0, 20.0, "candidate");
        bad["image"]["file"] = json!("../../../etc/passwd");
        let s = session(vec![bad, photo(2, Some("ref-1"), true, Some("u"), 90.0, 20.0, "candidate")], json!([{ "id": "ref-1" }]), json!(null));
        let picked: Vec<String> = select_photos(&s, 8).iter().map(|p| p.photo_id.clone()).collect();
        assert_eq!(picked, vec![pid(2)]);
    }

    #[test]
    fn rotates_photos_upright() {
        // 横長 40 × 20 (センサーの向き)。左上の 10 × 10 だけ赤
        let image = image::RgbImage::from_fn(40, 20, |x, y| {
            if x < 10 && y < 10 { image::Rgb([255, 0, 0]) } else { image::Rgb([255, 255, 255]) }
        });
        let mut jpeg = Vec::new();
        DynamicImage::ImageRgb8(image)
            .write_to(&mut Cursor::new(&mut jpeg), image::ImageFormat::Jpeg)
            .unwrap();
        let red = |img: &image::RgbImage, x: u32, y: u32| img.get_pixel(x, y)[1] < 100;
        let turn = |deg: i32| image::load_from_memory(&upright_jpeg(&jpeg, deg).unwrap()).unwrap().to_rgb8();

        assert_eq!(upright_jpeg(&jpeg, 0).unwrap(), jpeg);
        // 時計回りに 90°: 縦長になり、左上は右上へ
        let right = turn(90);
        assert_eq!(right.dimensions(), (20, 40));
        assert!(red(&right, 15, 5) && !red(&right, 5, 5));
        let upside = turn(180);
        assert_eq!(upside.dimensions(), (40, 20));
        assert!(red(&upside, 35, 15) && !red(&upside, 5, 5));
        // 反時計回り (270° = −90°): 左上は左下へ
        let left = turn(-90);
        assert_eq!(left.dimensions(), (20, 40));
        assert!(red(&left, 5, 35) && !red(&left, 5, 5));
        assert!(upright_jpeg(&jpeg, 45).is_err());
        assert!(upright_jpeg(b"not an image", 90).is_err());
    }

    #[test]
    fn lists_sessions_newest_first_and_skips_broken_ones() {
        let dir = std::env::temp_dir().join(format!("memoria-capture-test-{}", uuid::Uuid::new_v4().simple()));
        let write = |id: &str, body: String| {
            let folder = dir.join("sessions").join(id);
            std::fs::create_dir_all(&folder).unwrap();
            std::fs::write(folder.join("session.json"), body).unwrap();
        };
        let old = "11111111-1111-1111-1111-111111111111";
        let new = "22222222-2222-2222-2222-222222222222";
        let body = |id: &str, at: &str| {
            json!({ "schema": SCHEMA, "schemaVersion": 1, "sessionId": id, "title": id, "createdAt": at,
                    "object": { "heightM": 0.1, "radiusM": 0.05 } })
            .to_string()
        };
        write(old, body(old, "2026-11-09T10:00:00+09:00"));
        // 時差の違う時刻でも、本当の時刻で比べる (UTC 03:00 = JST 12:00 で、old より新しい)
        write(new, body(new, "2026-11-09T03:00:00Z"));
        write("33333333-3333-3333-3333-333333333333", "{ broken".into());
        // UUID でないフォルダと incoming/ は見ない
        write("not-a-session", body(old, "2026-11-09T10:00:00+09:00"));
        std::fs::create_dir_all(dir.join("incoming").join(old)).unwrap();

        let list = list_sessions(&dir);
        let ids: Vec<&str> = list.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(ids, vec![new, old]);
        assert_eq!(list[0].size_cm, Some(vec![10.0, 10.0]));
        assert_eq!(list[1].created_label, "2026年11月9日 10:00");
        assert!(list_sessions(&dir.join("missing")).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
