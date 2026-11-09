//! 写真から 3D を作る (試験中)。作品の写真を受け取り、リポジトリの `generator/` の `kt auto` で GLB を作って、
//! 作品の 3D モデルを差し替える (手で GLB をアップロードしたときと同じ。model_kind = custom)。
//!
//! - 使えるのは `KT_GENERATOR_ENABLED=1` で、`generator/` (または `KT_GENERATOR_DIR`) に kt.sh (Windows は kt.ps1) と
//!   setup.sh が作った `.venv` があるときだけ。それ以外は API が 404 (`GET /api/generator` だけは `{"enabled": false}`)。
//!   本番 (Render) では設定しない。入れ物には Python も generator/ も無い
//! - 生成は数分かかるので、受け付けたら 202 で job を返し、裏で動かす。GPU を使うので、同時に動かすのは 1 つだけ (ほかは 409)
//! - job はメモリにだけ持つ (サーバーを止めると消える)。作業のファイルは OS の一時フォルダの memoria-generator/<job id>/ に置き、終わったら消す
//!
//! 仕組みは docs/generator.md。

use std::{
    collections::HashMap,
    path::{Path as FsPath, PathBuf},
    process::Stdio,
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use axum::{
    extract::{multipart::Field, Multipart, Path, State},
    http::StatusCode,
    Json,
};
use serde::Serialize;
use tokio::{fs, io::AsyncWriteExt, process::Command};
use uuid::Uuid;

use crate::{
    artworks, capture,
    error::{AppError, AppResult},
    state::AppState,
};

const MB: u64 = 1024 * 1024;
/// 1 回に送れる写真の数
pub const MAX_PHOTOS: usize = 8;
/// 写真 1 枚の上限
pub const MAX_PHOTO_BYTES: u64 = 20 * MB;
/// POST /api/artworks/{id}/generate だけの送信の上限 (写真の上限 × 枚数 + フォームの余白)
pub const UPLOAD_BODY_LIMIT: usize = (MAX_PHOTOS as u64 * MAX_PHOTO_BYTES + MB) as usize;
/// 寸法 (cm) の上限
const MAX_SIZE_CM: f64 = 500.0;
/// できた GLB の上限
const MAX_MODEL_BYTES: u64 = 100 * MB;
/// 終わった job を覚えておく数 (古いものから忘れる)
const KEEP_FINISHED: usize = 20;
const DEFAULT_TIMEOUT_SECS: u64 = 900;
const DEFAULT_AI_MODEL: &str = "sonnet";
/// stderr のうち、ログに出す最後の行数
const LOG_TAIL_LINES: usize = 20;

/// 作業のフォルダの名前 (OS の一時フォルダの下。/media で配信されないように、MEDIA_DIR には置かない)
const WORK_DIR: &str = "memoria-generator";

fn work_root() -> PathBuf {
    std::env::temp_dir().join(WORK_DIR)
}

#[cfg(windows)]
const LAUNCHER: &str = "kt.ps1";
#[cfg(not(windows))]
const LAUNCHER: &str = "kt.sh";

/// setup.sh (setup.ps1) が作る venv の Python
fn venv_python(dir: &FsPath) -> PathBuf {
    if cfg!(windows) {
        dir.join(".venv").join("Scripts").join("python.exe")
    } else {
        dir.join(".venv").join("bin").join("python")
    }
}

// =============================
// 設定 (起動時に 1 回だけ環境変数から読む)
// =============================

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// generator/ のフォルダ (kt.sh と .venv がある)
    pub dir: PathBuf,
    pub timeout: Duration,
    /// kt auto の --ai-model
    pub ai_model: String,
    /// iPhone で撮った写真の受信フォルダ (capture/receiver の --data-dir。中の sessions/ を読む。capture.rs)
    pub capture_dir: PathBuf,
}

/// 環境変数から設定を作る。`Ok(None)` は使わない (KT_GENERATOR_ENABLED が 1 でない)、
/// `Err` は使うつもりだが準備ができていない (理由)。`default_dir` は KT_GENERATOR_DIR が無いときのフォルダ、
/// `default_capture_dir` は CAPTURE_DATA_DIR が無いときの受信フォルダ (無くてもよい。そのときは撮影の一覧が空)
pub fn config_from(
    var: impl Fn(&str) -> Option<String>,
    default_dir: &FsPath,
    default_capture_dir: &FsPath,
) -> Result<Option<Config>, String> {
    if var("KT_GENERATOR_ENABLED").as_deref().map(str::trim) != Some("1") {
        return Ok(None);
    }
    let dir = var("KT_GENERATOR_DIR")
        .map(|d| d.trim().to_string())
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| default_dir.to_path_buf());
    if !dir.is_dir() {
        return Err(format!("{} がありません (KT_GENERATOR_DIR)", dir.display()));
    }
    if !dir.join(LAUNCHER).is_file() {
        return Err(format!("{} に {LAUNCHER} がありません", dir.display()));
    }
    if !venv_python(&dir).is_file() {
        return Err(format!(
            "{} がありません (generator/ で setup.sh を実行して venv を作ってください)",
            venv_python(&dir).display()
        ));
    }
    let timeout = var("KT_GENERATOR_TIMEOUT_SECS")
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|&s| s > 0)
        .unwrap_or(DEFAULT_TIMEOUT_SECS);
    let ai_model = var("KT_GENERATOR_AI_MODEL")
        .map(|m| m.trim().to_string())
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| DEFAULT_AI_MODEL.to_string());
    let capture_dir = var("CAPTURE_DATA_DIR")
        .map(|d| d.trim().to_string())
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| default_capture_dir.to_path_buf());
    Ok(Some(Config { dir, timeout: Duration::from_secs(timeout), ai_model, capture_dir }))
}

// =============================
// job (メモリにだけ持つ)
// =============================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum JobStatus {
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone)]
struct Job {
    artwork_id: Uuid,
    status: JobStatus,
    error: Option<String>,
    started: Instant,
    finished: Option<Instant>,
}

#[derive(Debug, Serialize)]
pub struct JobDto {
    pub job_id: Uuid,
    pub artwork_id: Uuid,
    pub status: JobStatus,
    pub error: Option<String>,
    pub elapsed_secs: u64,
}

impl JobDto {
    fn new(job_id: Uuid, job: &Job) -> Self {
        let end = job.finished.unwrap_or_else(Instant::now);
        JobDto {
            job_id,
            artwork_id: job.artwork_id,
            status: job.status,
            error: job.error.clone(),
            elapsed_secs: end.duration_since(job.started).as_secs(),
        }
    }
}

#[derive(Default)]
struct Jobs {
    /// 今動いている (写真を受け取っている途中も含む) job
    running: Option<Uuid>,
    list: HashMap<Uuid, Job>,
}

pub struct Generator {
    config: Option<Config>,
    jobs: Mutex<Jobs>,
}

impl Generator {
    pub fn new(config: Option<Config>) -> Self {
        Generator { config, jobs: Mutex::new(Jobs::default()) }
    }

    /// 環境変数から作り、使えるかどうかを 1 行ログに出す
    pub fn from_env(default_dir: &FsPath, default_capture_dir: &FsPath) -> Self {
        let config = match config_from(|k| std::env::var(k).ok(), default_dir, default_capture_dir) {
            Ok(Some(config)) => {
                println!(
                    "[Generator] enabled: {} (timeout {} s, ai model {}, iPhone captures {})",
                    config.dir.display(),
                    config.timeout.as_secs(),
                    config.ai_model,
                    config.capture_dir.display()
                );
                Some(config)
            }
            Ok(None) => {
                println!("[Generator] disabled");
                None
            }
            Err(reason) => {
                println!("[Generator] disabled: KT_GENERATOR_ENABLED=1 ですが、{reason}");
                None
            }
        };
        Generator::new(config)
    }

    pub fn enabled(&self) -> bool {
        self.config.is_some()
    }

    /// 使えるときの設定
    pub fn config(&self) -> Option<&Config> {
        self.config.as_ref()
    }

    fn lock(&self) -> MutexGuard<'_, Jobs> {
        self.jobs.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 動かす枠を取る (ほかの job が動いていれば None)
    fn reserve(self: &Arc<Self>, job_id: Uuid) -> Option<Slot> {
        let mut jobs = self.lock();
        if jobs.running.is_some() {
            return None;
        }
        jobs.running = Some(job_id);
        Some(Slot { generator: self.clone(), job_id, done: false })
    }

    fn begin(&self, job_id: Uuid, artwork_id: Uuid) -> JobDto {
        let mut jobs = self.lock();
        let job = Job { artwork_id, status: JobStatus::Running, error: None, started: Instant::now(), finished: None };
        let dto = JobDto::new(job_id, &job);
        jobs.list.insert(job_id, job);
        dto
    }

    fn finish(&self, job_id: Uuid, result: Result<(), String>) {
        let mut jobs = self.lock();
        if jobs.running == Some(job_id) {
            jobs.running = None;
        }
        if let Some(job) = jobs.list.get_mut(&job_id) {
            job.finished = Some(Instant::now());
            match result {
                Ok(()) => job.status = JobStatus::Done,
                Err(error) => {
                    job.status = JobStatus::Failed;
                    job.error = Some(error);
                }
            }
        }
        // 終わった job は新しい KEEP_FINISHED 個だけ覚えておく
        let mut finished: Vec<(Uuid, Instant)> =
            jobs.list.iter().filter_map(|(id, j)| j.finished.map(|f| (*id, f))).collect();
        if finished.len() > KEEP_FINISHED {
            finished.sort_by_key(|(_, f)| std::cmp::Reverse(*f));
            for (id, _) in finished.into_iter().skip(KEEP_FINISHED) {
                jobs.list.remove(&id);
            }
        }
    }

    fn job(&self, job_id: Uuid) -> Option<JobDto> {
        self.lock().list.get(&job_id).map(|job| JobDto::new(job_id, job))
    }
}

/// 動かす枠。終わったら finish で返す。途中で落ちたとき (送信が切れた・パニック) は Drop で返す
struct Slot {
    generator: Arc<Generator>,
    job_id: Uuid,
    done: bool,
}

impl Slot {
    fn finish(mut self, result: Result<(), String>) {
        self.done = true;
        self.generator.finish(self.job_id, result);
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        if !self.done {
            self.generator.finish(self.job_id, Err("途中で止まりました".into()));
        }
    }
}

// =============================
// 入力の検証
// =============================

/// 寸法 (cm)。1〜3 個の正の数をカンマで区切る (「、」「，」も可)
pub fn parse_size_cm(value: &str) -> Result<Vec<f64>, String> {
    let parts: Vec<&str> =
        value.split([',', '、', '，']).map(str::trim).filter(|s| !s.is_empty()).collect();
    if parts.is_empty() || parts.len() > 3 {
        return Err("大きさは cm で 1〜3 個の数をカンマで区切って入れてください (例: 16, 10.6, 6.6)".into());
    }
    parts
        .iter()
        .map(|p| match p.parse::<f64>() {
            Ok(v) if v.is_finite() && v > 0.0 && v <= MAX_SIZE_CM => Ok(v),
            Ok(_) => Err(format!("大きさは 0 より大きく {MAX_SIZE_CM} cm 以下で入れてください")),
            Err(_) => Err(format!("大きさ「{p}」を数として読めません")),
        })
        .collect()
}

/// 写真の拡張子 (kt が読める JPEG・PNG・WebP だけ)。中身から決める
fn photo_ext(head: &[u8]) -> Option<&'static str> {
    match image::guess_format(head).ok()? {
        image::ImageFormat::Jpeg => Some("jpg"),
        image::ImageFormat::Png => Some("png"),
        image::ImageFormat::WebP => Some("webp"),
        _ => None,
    }
}

// =============================
// API
// =============================

#[derive(Serialize)]
pub struct GeneratorStatus {
    pub enabled: bool,
}

/// GET /api/generator (いつでも使える。Web はこれで「写真から 3D を作る」を出すか決める)
pub async fn status(State(state): State<AppState>) -> Json<GeneratorStatus> {
    Json(GeneratorStatus { enabled: state.generator.enabled() })
}

fn disabled() -> AppError {
    AppError::not_found("写真から 3D を作る機能は使えません")
}

/// GET /api/generator/jobs/{job_id}
pub async fn job(State(state): State<AppState>, Path(job_id): Path<Uuid>) -> AppResult<Json<JobDto>> {
    if !state.generator.enabled() {
        return Err(disabled());
    }
    state.generator.job(job_id).map(Json).ok_or_else(|| AppError::not_found("その生成の記録はありません"))
}

/// POST /api/artworks/{id}/generate (multipart: photos を 1〜8 枚か、iPhone の撮影の capture_session と、size_cm
/// (撮影を選んだときは省ける))。受け付けたら 202 で job を返す
pub async fn start(
    State(state): State<AppState>,
    Path(artwork_id): Path<Uuid>,
    multipart: Multipart,
) -> AppResult<(StatusCode, Json<JobDto>)> {
    let Some(config) = state.generator.config.clone() else {
        return Err(disabled());
    };
    // 送られてくる写真を受け取る前に断る
    let title = sqlx::query_scalar::<_, String>("SELECT title FROM artworks WHERE id = $1")
        .bind(artwork_id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or_else(|| AppError::not_found("作品が見つかりません"))?;
    let job_id = Uuid::new_v4();
    let slot = state
        .generator
        .reserve(job_id)
        .ok_or_else(|| AppError::conflict("ほかの作品の 3D を作っています。終わってから試してください"))?;

    let work = work_root().join(job_id.to_string());
    let (photos, size) = match read_request(multipart, &work, &config.capture_dir).await {
        Ok(read) => read,
        Err(error) => {
            remove_work(&work).await;
            return Err(error);
        }
    };

    let dto = state.generator.begin(job_id, artwork_id);
    println!(
        "[Generator] job {job_id}: 「{title}」 photos {}, size {} cm",
        photos.len(),
        size_arg(&size)
    );
    tokio::spawn(async move {
        let started = Instant::now();
        let result = run_job(&state, &config, artwork_id, &work, &photos, &size).await;
        remove_work(&work).await;
        match &result {
            Ok(()) => println!("[Generator] job {job_id}: done in {:?}", started.elapsed()),
            Err(error) => println!("[Generator] job {job_id}: failed in {:?} ({error})", started.elapsed()),
        }
        slot.finish(result);
    });
    Ok((StatusCode::ACCEPTED, Json(dto)))
}

/// 写真を work/photos/ に書き、寸法を読む
/// 写真を work/photos/ に書き、寸法を読む。`capture_session` (iPhone で撮った撮影の id) があれば、送られた写真の代わりに
/// その撮影から選んだ写真をまっすぐにして使い、寸法を省いたときは撮影の大きさを使う (capture.rs)
async fn read_request(mut multipart: Multipart, work: &FsPath, capture_dir: &FsPath) -> AppResult<(Vec<PathBuf>, Vec<f64>)> {
    let photo_dir = work.join("photos");
    fs::create_dir_all(&photo_dir).await?;
    let mut photos = Vec::new();
    let mut size = None;
    let mut capture_session = None;
    while let Some(mut field) = multipart.next_field().await? {
        match field.name().unwrap_or("") {
            "capture_session" => {
                let text = field.text().await?;
                if !text.trim().is_empty() {
                    capture_session = Some(capture::parse_session_id(&text).map_err(AppError::bad_request)?);
                }
            }
            "photos" => {
                if photos.len() >= MAX_PHOTOS {
                    return Err(AppError::bad_request(format!("写真は {MAX_PHOTOS} 枚までです")));
                }
                if let Some(path) = save_photo(&mut field, &photo_dir, photos.len() + 1).await? {
                    photos.push(path);
                }
            }
            "size_cm" => size = Some(parse_size_cm(&field.text().await?).map_err(AppError::bad_request)?),
            _ => {}
        }
    }
    if let Some(session_id) = capture_session {
        if !photos.is_empty() {
            return Err(AppError::bad_request("写真を送るか、iPhone の撮影を選ぶか、どちらか 1 つにしてください"));
        }
        let (photos, session_size) = capture::prepare_photos(capture_dir, &session_id, MAX_PHOTOS, &photo_dir).await?;
        let size = size
            .or(session_size)
            .ok_or_else(|| AppError::bad_request("この撮影には大きさがありません。大きさ (cm) を入れてください"))?;
        return Ok((photos, size));
    }
    if photos.is_empty() {
        return Err(AppError::bad_request("写真を 1 枚以上選んでください"));
    }
    let size = size.ok_or_else(|| AppError::bad_request("大きさ (cm) を入れてください"))?;
    Ok((photos, size))
}

/// 写真を 1 枚書く (空のファイルは None)。拡張子は中身から決める (kt は拡張子で写真を選ぶ)
async fn save_photo(field: &mut Field<'_>, dir: &FsPath, n: usize) -> AppResult<Option<PathBuf>> {
    let mut bytes = Vec::new();
    while let Some(chunk) = field.chunk().await? {
        if (bytes.len() + chunk.len()) as u64 > MAX_PHOTO_BYTES {
            return Err(AppError::payload_too_large(format!("写真は 1 枚 {} MB までにしてください", MAX_PHOTO_BYTES / MB)));
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Ok(None);
    }
    let ext = photo_ext(&bytes).ok_or_else(|| AppError::bad_request("写真は JPEG・PNG・WebP を選んでください"))?;
    let path = dir.join(format!("photo{n}.{ext}"));
    let mut file = fs::File::create(&path).await?;
    file.write_all(&bytes).await?;
    file.flush().await?;
    Ok(Some(path))
}

fn size_arg(size: &[f64]) -> String {
    size.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",")
}

async fn remove_work(work: &FsPath) {
    if let Err(error) = fs::remove_dir_all(work).await
        && error.kind() != std::io::ErrorKind::NotFound
    {
        eprintln!("[Generator] Failed to remove {}: {error}", work.display());
    }
}

/// 前に動かしていたときの作業のフォルダが残っていれば消す (起動時。使うときだけ)
pub async fn remove_leftovers(state: &AppState) {
    if state.generator.enabled() {
        remove_work(&work_root()).await;
    }
}

/// 出力の最後の数行 (ログ用)
fn tail(output: &[u8], lines: usize) -> String {
    let text = String::from_utf8_lossy(output);
    let all: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    all[all.len().saturating_sub(lines)..].join("\n")
}

/// kt auto を動かし、できた GLB で作品の 3D を差し替える。Err は利用者に見せる短い文
async fn run_job(
    state: &AppState,
    config: &Config,
    artwork_id: Uuid,
    work: &FsPath,
    photos: &[PathBuf],
    size: &[f64],
) -> Result<(), String> {
    let out = work.join("out");
    let launcher = config.dir.join(LAUNCHER);
    let mut command = if cfg!(windows) {
        let mut c = Command::new("powershell");
        c.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]).arg(&launcher);
        c
    } else {
        let mut c = Command::new("bash");
        c.arg(&launcher);
        c
    };
    command
        .arg("auto")
        .args(photos)
        .arg("--size")
        .arg(size_arg(size))
        .arg("--out")
        .arg(&out)
        .arg("--ai-model")
        .arg(&config.ai_model)
        .current_dir(work)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // 時間切れのとき、kt が起こした子のプロセス (claude・形の生成) もまとめて止められるよう、別のプロセスグループにする
    #[cfg(unix)]
    command.process_group(0);

    let child = command.spawn().map_err(|error| {
        println!("[Generator] {} を起動できません ({error})", launcher.display());
        "生成の道具を起動できませんでした".to_string()
    })?;
    let pid = child.id();
    let output = match tokio::time::timeout(config.timeout, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => {
            println!("[Generator] kt の終わりを待てません ({error})");
            return Err("生成の途中でエラーが起きました".into());
        }
        Err(_) => {
            // child は wait_with_output と一緒に落ちて kill される。子のプロセスもグループごと止める
            #[cfg(unix)]
            if let Some(pid) = pid {
                let _ = Command::new("kill").arg("-KILL").arg(format!("-{pid}")).status().await;
            }
            #[cfg(not(unix))]
            let _ = pid;
            return Err(format!("{} 分たっても作り終わらなかったので止めました", config.timeout.as_secs().div_ceil(60)));
        }
    };
    if !output.status.success() {
        println!(
            "[Generator] kt auto failed ({})\n--- stdout (last lines)\n{}\n--- stderr (last lines)\n{}",
            output.status,
            tail(&output.stdout, LOG_TAIL_LINES),
            tail(&output.stderr, LOG_TAIL_LINES)
        );
        return Err("3D を作れませんでした。写真や大きさを変えて試してください".into());
    }

    let model_path = out.join("model.glb");
    let too_large = fs::metadata(&model_path).await.map(|m| m.len() > MAX_MODEL_BYTES).unwrap_or(false);
    if too_large {
        return Err(format!("できた 3D が大きすぎます ({} MB まで)", MAX_MODEL_BYTES / MB));
    }
    let model = fs::read(&model_path).await.map_err(|error| {
        println!("[Generator] {} を読めません ({error})\n{}", model_path.display(), tail(&output.stdout, LOG_TAIL_LINES));
        "3D のファイルができませんでした".to_string()
    })?;

    artworks::replace_model(state, artwork_id, model, "生成した GLB").await.map_err(|error| {
        if error.status == StatusCode::INTERNAL_SERVER_ERROR {
            "作品に 3D を入れられませんでした".to_string()
        } else {
            error.message
        }
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, extract::FromRequest, http::Request};
    use sqlx::postgres::PgPoolOptions;

    fn vars(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |k| map.get(k).cloned()
    }

    fn no_capture() -> PathBuf {
        std::env::temp_dir().join("memoria-generator-test-no-captures")
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("memoria-generator-test-{name}-{}", Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// kt.sh と .venv の Python があるフォルダ (中身は空でよい)
    fn ready_dir() -> PathBuf {
        let dir = temp_dir("ready");
        std::fs::write(dir.join(LAUNCHER), "").unwrap();
        let python = venv_python(&dir);
        std::fs::create_dir_all(python.parent().unwrap()).unwrap();
        std::fs::write(python, "").unwrap();
        dir
    }

    #[test]
    fn parses_size_cm() {
        assert_eq!(parse_size_cm("16,10.6,6.6").unwrap(), vec![16.0, 10.6, 6.6]);
        assert_eq!(parse_size_cm(" 20 ").unwrap(), vec![20.0]);
        assert_eq!(parse_size_cm("21、29.7").unwrap(), vec![21.0, 29.7]);
        assert_eq!(parse_size_cm("5, 6,").unwrap(), vec![5.0, 6.0]);
        assert_eq!(parse_size_cm("500").unwrap(), vec![500.0]);
        assert!(parse_size_cm("").is_err());
        assert!(parse_size_cm("1,2,3,4").is_err());
        assert!(parse_size_cm("0").is_err());
        assert!(parse_size_cm("-3").is_err());
        assert!(parse_size_cm("501").is_err());
        assert!(parse_size_cm("abc").is_err());
        assert!(parse_size_cm("NaN").is_err());
        assert!(parse_size_cm("inf").is_err());
        assert_eq!(size_arg(&[16.0, 10.6]), "16,10.6");
    }

    #[test]
    fn config_is_off_by_default() {
        let dir = ready_dir();
        assert_eq!(config_from(vars(&[]), &dir, &no_capture()), Ok(None));
        assert_eq!(config_from(vars(&[("KT_GENERATOR_ENABLED", "0")]), &dir, &no_capture()), Ok(None));
        assert_eq!(config_from(vars(&[("KT_GENERATOR_ENABLED", "true")]), &dir, &no_capture()), Ok(None));
        // フォルダを指定しても、ENABLED が無ければ使わない
        let dir_str = dir.to_string_lossy().to_string();
        assert_eq!(config_from(vars(&[("KT_GENERATOR_DIR", &dir_str)]), &dir, &no_capture()), Ok(None));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn config_needs_launcher_and_venv() {
        let missing = std::env::temp_dir().join(format!("memoria-generator-missing-{}", Uuid::new_v4().simple()));
        let on = [("KT_GENERATOR_ENABLED", "1")];
        assert!(config_from(vars(&on), &missing, &no_capture()).is_err());

        let empty = temp_dir("empty");
        assert!(config_from(vars(&on), &empty, &no_capture()).unwrap_err().contains(LAUNCHER));
        std::fs::write(empty.join(LAUNCHER), "").unwrap();
        assert!(config_from(vars(&on), &empty, &no_capture()).unwrap_err().contains(".venv"));
        std::fs::remove_dir_all(empty).unwrap();

        let dir = ready_dir();
        let config = config_from(vars(&on), &dir, &no_capture()).unwrap().unwrap();
        assert_eq!(config.dir, dir);
        assert_eq!(config.timeout, Duration::from_secs(DEFAULT_TIMEOUT_SECS));
        assert_eq!(config.ai_model, "sonnet");
        assert_eq!(config.capture_dir, no_capture());

        // KT_GENERATOR_DIR が既定のフォルダより優先される
        let dir_str = dir.to_string_lossy().to_string();
        let config = config_from(
            vars(&[
                ("KT_GENERATOR_ENABLED", "1"),
                ("KT_GENERATOR_DIR", &dir_str),
                ("KT_GENERATOR_TIMEOUT_SECS", "60"),
                ("KT_GENERATOR_AI_MODEL", "opus"),
                ("CAPTURE_DATA_DIR", "/tmp/captures"),
            ]),
            &missing,
            &no_capture(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(config.dir, dir);
        assert_eq!(config.timeout, Duration::from_secs(60));
        assert_eq!(config.ai_model, "opus");
        assert_eq!(config.capture_dir, PathBuf::from("/tmp/captures"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn runs_one_job_at_a_time() {
        let generator = Arc::new(Generator::new(None));
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let slot = generator.reserve(a).unwrap();
        assert!(generator.reserve(b).is_none());
        // 写真を受け取る途中で落ちた (job を始める前): 枠は空き、記録は残らない
        drop(slot);
        assert!(generator.job(a).is_none());

        let slot = generator.reserve(b).unwrap();
        let artwork = Uuid::new_v4();
        assert_eq!(generator.begin(b, artwork).status, JobStatus::Running);
        assert!(generator.reserve(a).is_none());
        slot.finish(Err("だめでした".into()));
        let job = generator.job(b).unwrap();
        assert_eq!((job.status, job.error.as_deref(), job.artwork_id), (JobStatus::Failed, Some("だめでした"), artwork));
        assert!(generator.reserve(a).is_some());
    }

    #[test]
    fn keeps_only_recent_finished_jobs() {
        let generator = Arc::new(Generator::new(None));
        let ids: Vec<Uuid> = (0..KEEP_FINISHED + 5).map(|_| Uuid::new_v4()).collect();
        for id in &ids {
            let slot = generator.reserve(*id).unwrap();
            generator.begin(*id, Uuid::new_v4());
            slot.finish(Ok(()));
        }
        assert_eq!(generator.lock().list.len(), KEEP_FINISHED);
        assert_eq!(generator.job(*ids.last().unwrap()).unwrap().status, JobStatus::Done);
    }

    #[test]
    fn accepts_only_photos_kt_can_read() {
        assert_eq!(photo_ext(&[0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]), Some("jpg"));
        assert_eq!(photo_ext(b"\x89PNG\r\n\x1a\n\0\0\0\0"), Some("png"));
        assert_eq!(photo_ext(b"RIFF\0\0\0\0WEBPVP8 "), Some("webp"));
        assert_eq!(photo_ext(b"GIF89a\0\0\0\0\0\0"), None);
        assert_eq!(photo_ext(b"not an image"), None);
    }

    /// 使わない設定のサーバー (DB にはつながない。プールは使うまで接続しない)
    fn disabled_state() -> AppState {
        AppState {
            pool: PgPoolOptions::new().connect_lazy("postgres://nobody@127.0.0.1:1/none").unwrap(),
            media_dir: std::env::temp_dir(),
            museum_model_url: None,
            walk_model_url: None,
            room_model_urls: HashMap::new(),
            generator: Arc::new(Generator::new(None)),
        }
    }

    #[tokio::test]
    async fn routes_are_404_when_disabled() {
        let state = disabled_state();
        assert!(!status(State(state.clone())).await.enabled);

        let error = job(State(state.clone()), Path(Uuid::new_v4())).await.unwrap_err();
        assert_eq!(error.status, StatusCode::NOT_FOUND);
        let error = capture::sessions(State(state.clone())).await.unwrap_err();
        assert_eq!(error.status, StatusCode::NOT_FOUND);

        let body = "--x\r\nContent-Disposition: form-data; name=\"size_cm\"\r\n\r\n10\r\n--x--\r\n";
        let request = Request::builder()
            .method("POST")
            .header("content-type", "multipart/form-data; boundary=x")
            .body(Body::from(body))
            .unwrap();
        let multipart = Multipart::from_request(request, &()).await.unwrap();
        // DB を見る前に 404 になる (プールは接続できない先なので、見に行けば 500 になる)
        let error = start(State(state), Path(Uuid::new_v4()), multipart).await.unwrap_err();
        assert_eq!(error.status, StatusCode::NOT_FOUND);
    }
}
