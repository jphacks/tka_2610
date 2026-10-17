//! 起動時に、アトリエの作品 13 点 (static/atelier) を作品として登録し、おうちに飾る。
//!
//! ほかの処理から独立している。要らなくなったら main.rs の呼び出し 1 行とこのファイルを消せばよい。
//! static/atelier/catalog.json が無ければ何もしない。

use std::path::Path;

use chrono::NaiveDate;
use serde::Deserialize;
use tokio::fs;
use uuid::Uuid;

use crate::{
    artworks::{load_sizes, measure_model, remove_files, set_model_size, sizes_of, write_files},
    error::AppError,
    glb, home, home_api, media,
    state::{AppState, MediaKind},
};

const CHILD_NAME: &str = "アトリエ";
const CATEGORY: &str = "craft";

/// 以前の版で、サンプルの作品 13 点にそろえて入れていた作成日 (キットの日付)。
/// この日付のままの作品は、起動時に catalog.json の madeOn に直す (画面で作成日を変えた作品は触らない)
fn old_made_on() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 10, 14).expect("valid date")
}

/// static/atelier/catalog.json の 1 件 (使う項目だけ)
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AtelierItem {
    pub asset_id: String,
    pub title_ja: String,
    pub memo: String,
    /// 作成日。去年と今年の休みの日に、作品の季節に合わせて散らしてある
    pub made_on: NaiveDate,
    /// static/atelier からの相対パス
    pub model: String,
    pub photo: String,
}

/// assetId から決まる作品 id (何度起動しても、どの PC でも同じ)
pub fn seed_id(asset_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, format!("memory-museum/atelier/{asset_id}").as_bytes())
}

/// 表示用画像・サムネイルのファイル名 (フォルダ違いで同じ名前) と GLB のファイル名
fn seed_file_names(id: Uuid) -> (String, String) {
    (format!("{id}-seed.jpg"), format!("{id}-seed.glb"))
}

struct Summary {
    inserted: usize,
    repaired: usize,
    redated: usize,
    placed: usize,
}

pub async fn ensure_atelier(state: &AppState, dir: &Path) {
    match run(state, dir).await {
        Ok(Some(s)) => println!(
            "[Seed] atelier: inserted {}, repaired {} files, redated {}, placed {}",
            s.inserted, s.repaired, s.redated, s.placed
        ),
        Ok(None) => {}
        Err(error) => println!("[Seed] atelier: 登録できませんでした ({error})"),
    }
}

async fn run(state: &AppState, dir: &Path) -> Result<Option<Summary>, String> {
    let catalog_path = dir.join("catalog.json");
    let Ok(text) = fs::read_to_string(&catalog_path).await else {
        println!("[Seed] atelier: {} が無いので登録しません", catalog_path.display());
        return Ok(None);
    };
    let items: Vec<AtelierItem> =
        serde_json::from_str(&text).map_err(|e| format!("catalog.json を読めません: {e}"))?;

    let ids: Vec<Uuid> = items.iter().map(|item| seed_id(&item.asset_id)).collect();
    let existing: Vec<(Uuid, String, String, String, NaiveDate)> = sqlx::query_as(
        "SELECT id, image_file, thumb_file, model_file, made_on FROM artworks WHERE id = ANY($1)",
    )
    .bind(&ids)
    .fetch_all(&state.pool)
    .await
    .map_err(|e| e.to_string())?;

    let mut inserted = Vec::new();
    let mut repaired = 0;
    let mut redated = 0;
    for (item, &id) in items.iter().zip(&ids) {
        match existing.iter().find(|row| row.0 == id) {
            Some((_, image_file, thumb_file, model_file, made_on)) => {
                repaired += repair_files(state, dir, item, id, image_file, thumb_file, model_file).await?;
                if *made_on == old_made_on() && item.made_on != old_made_on() {
                    redated += redate(state, id, item.made_on).await?;
                }
            }
            None => {
                if insert(state, dir, item, id).await? {
                    inserted.push(id);
                }
            }
        }
    }

    let placed = if inserted.is_empty() { 0 } else { place(state, &inserted).await? };
    Ok(Some(Summary { inserted: inserted.len(), repaired, redated, placed }))
}

/// 以前の版の作成日 (old_made_on) のままの作品を、catalog.json の作成日に直す。
/// ほかの PC が先に直していたり、画面で作成日を変えていたりしたら何もしない (0 を返す)
async fn redate(state: &AppState, id: Uuid, made_on: NaiveDate) -> Result<usize, String> {
    let done = sqlx::query("UPDATE artworks SET made_on = $2, updated_at = NOW() WHERE id = $1 AND made_on = $3")
        .bind(id)
        .bind(made_on)
        .bind(old_made_on())
        .execute(&state.pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(done.rows_affected() as usize)
}

async fn read_static(dir: &Path, relative: &str) -> Result<Vec<u8>, String> {
    let path = dir.join(relative);
    fs::read(&path).await.map_err(|e| format!("{} を読めません: {e}", path.display()))
}

/// 写真から表示用画像・サムネイル・tint を作る
async fn process_photo(dir: &Path, item: &AtelierItem) -> Result<media::ProcessedImage, String> {
    let photo = read_static(dir, &item.photo).await?;
    tokio::task::spawn_blocking(move || media::process(&photo))
        .await
        .map_err(|e| e.to_string())?
}

async fn read_model(dir: &Path, item: &AtelierItem) -> Result<Vec<u8>, String> {
    let model = read_static(dir, &item.model).await?;
    glb::validate_glb(&model).map_err(|e| format!("{}: {e}", item.model))?;
    Ok(model)
}

/// 作品を 1 件登録する。ほかの PC が先に登録していたら false
async fn insert(state: &AppState, dir: &Path, item: &AtelierItem, id: Uuid) -> Result<bool, String> {
    let processed = process_photo(dir, item).await?;
    let model = read_model(dir, item).await?;
    // 実寸は GLB から測る (catalog.json の dimensionsMeters はテストの正解としてだけ使う)
    let size = measure_model(&model, &item.model);
    let (image_file, model_file) = seed_file_names(id);

    let files = [
        (MediaKind::Image, image_file.clone(), processed.display_jpeg.as_slice()),
        (MediaKind::Thumb, image_file.clone(), processed.thumb_jpeg.as_slice()),
        (MediaKind::Model, model_file.clone(), model.as_slice()),
    ];
    write_files(state, &files).await.map_err(|e| e.message)?;

    let result = sqlx::query(
        "INSERT INTO artworks (id, title, child_name, made_on, memo, category, \
            image_file, thumb_file, model_file, model_kind, image_width, image_height, tint, \
            model_width, model_height, model_depth) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $7, $8, 'custom', $9, $10, $11, $12, $13, $14) \
         ON CONFLICT (id) DO NOTHING",
    )
    .bind(id)
    .bind(&item.title_ja)
    .bind(CHILD_NAME)
    .bind(item.made_on)
    .bind(&item.memo)
    .bind(CATEGORY)
    .bind(&image_file)
    .bind(&model_file)
    .bind(processed.display_width as i32)
    .bind(processed.display_height as i32)
    .bind(&processed.tint)
    .bind(size.map(|s| s[0]))
    .bind(size.map(|s| s[1]))
    .bind(size.map(|s| s[2]))
    .execute(&state.pool)
    .await;

    match result {
        // 0 件ならほかの PC が同時に登録した。ファイルは同じ名前・同じ中身なので残してよい
        Ok(done) => Ok(done.rows_affected() == 1),
        Err(error) => {
            remove_files(state, files.iter().map(|(k, n, _)| (*k, n.clone()))).await;
            Err(error.to_string())
        }
    }
}

/// 登録済みなのにこの PC にファイルが無いとき (同じデータベースを使う 2 台目の PC など)、static から作り直す。
/// 作品の編集で写真やモデルを差し替えたあと (ファイル名が seed のものでない) は作り直せないので触らない。
/// GLB を置き直したときは、寸法が NULL なら測って入れる (起動時の backfill はファイルが無くて飛ばしている)
async fn repair_files(
    state: &AppState,
    dir: &Path,
    item: &AtelierItem,
    id: Uuid,
    image_file: &str,
    thumb_file: &str,
    model_file: &str,
) -> Result<usize, String> {
    let (seed_image, seed_model) = seed_file_names(id);
    let missing = |kind: MediaKind, name: &str, seed: &str| {
        name == seed && !state.media_path(kind, name).exists()
    };
    let need_image = missing(MediaKind::Image, image_file, &seed_image);
    let need_thumb = missing(MediaKind::Thumb, thumb_file, &seed_image);
    let need_model = missing(MediaKind::Model, model_file, &seed_model);
    if !(need_image || need_thumb || need_model) {
        return Ok(0);
    }

    let processed = if need_image || need_thumb { Some(process_photo(dir, item).await?) } else { None };
    let model = if need_model { Some(read_model(dir, item).await?) } else { None };

    let mut files: Vec<(MediaKind, String, &[u8])> = Vec::new();
    if let Some(p) = &processed {
        if need_image {
            files.push((MediaKind::Image, seed_image.clone(), &p.display_jpeg));
        }
        if need_thumb {
            files.push((MediaKind::Thumb, seed_image.clone(), &p.thumb_jpeg));
        }
    }
    if let Some(model) = &model {
        files.push((MediaKind::Model, seed_model, model));
    }
    write_files(state, &files).await.map_err(|e| e.message)?;
    if let Some(size) = model.as_deref().and_then(|m| measure_model(m, &item.model)) {
        set_model_size(&state.pool, id, size).await.map_err(|e| e.message)?;
    }
    Ok(files.len())
}

/// 新しく登録した作品を、空いている棚や机の上に飾る
async fn place(state: &AppState, ids: &[Uuid]) -> Result<usize, String> {
    let message = |e: AppError| e.message;
    let mut tx = state.pool.begin().await.map_err(|e| e.to_string())?;
    let mut layout = home_api::lock_layout(&mut tx).await.map_err(message)?;
    // 載っている作品と、新しく置く作品の実寸
    let all: Vec<Uuid> = layout.artworks().map(|a| a.artwork_id).chain(ids.iter().copied()).collect();
    let sizes = sizes_of(&load_sizes(&mut *tx, &all).await.map_err(message)?);

    let mut placed = 0;
    for &id in ids {
        if layout.artwork_for(id).is_some() {
            continue;
        }
        let Some(spot) = home::pick_spot(&layout, &sizes, sizes.get(&id), None, None) else { break };
        layout.objects.push(home::artwork_on(id, spot));
        placed += 1;
    }

    if placed > 0 {
        // 家具の上にだけ置くので、出入口の前は見ない
        home_api::save_layout(&mut tx, layout, home::DoorPolicy::Ignore).await.map_err(message)?;
    }
    tx.commit().await.map_err(|e| e.to_string())?;
    Ok(placed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Datelike;

    #[test]
    fn seed_ids_are_deterministic() {
        // Python の uuid.uuid5(uuid.NAMESPACE_URL, "memory-museum/atelier/<assetId>") と同じ値
        assert_eq!(
            seed_id("06_starbound_rocket").to_string(),
            "7505d491-1bc8-5357-aa22-3be72ba26a4e"
        );
        assert_eq!(seed_id("18_wishwheel").to_string(), "40b91f38-f757-5a84-90a5-f1c1614ebc92");
        assert_eq!(seed_id("18_wishwheel"), seed_id("18_wishwheel"));
        assert_ne!(seed_id("06_starbound_rocket"), seed_id("07_rainbow_sailboat"));
    }

    #[test]
    fn memo_table_covers_catalog() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("static").join("atelier");
        let Ok(text) = std::fs::read_to_string(dir.join("catalog.json")) else {
            // フォルダが無い構成でも動くようにしてある (seed は何もしない)
            return;
        };
        let items: Vec<AtelierItem> = serde_json::from_str(&text).unwrap();
        assert_eq!(items.len(), 13);

        let mut ids: Vec<Uuid> = items.iter().map(|i| seed_id(&i.asset_id)).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), items.len(), "assetId が重複しています");

        for item in &items {
            let memo_len = item.memo.chars().count();
            assert!((1..=60).contains(&memo_len), "{}: memo が {memo_len} 文字", item.asset_id);
            assert!(!item.memo.chars().any(|c| c.is_ascii_alphabetic()), "{}: memo に英字", item.asset_id);
            let title_len = item.title_ja.chars().count();
            assert!((1..=40).contains(&title_len), "{}: titleJa が {title_len} 文字", item.asset_id);
            assert!(dir.join(&item.model).is_file(), "{} がありません", item.model);
            assert!(dir.join(&item.photo).is_file(), "{} がありません", item.photo);
        }
    }

    #[test]
    fn made_on_spreads_over_last_year_and_this_year() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("static").join("atelier");
        let Ok(text) = std::fs::read_to_string(dir.join("catalog.json")) else {
            return;
        };
        let items: Vec<AtelierItem> = serde_json::from_str(&text).unwrap();
        let date = |y, m, d| NaiveDate::from_ymd_opt(y, m, d).unwrap();
        // 去年 (2025 年) と今年 (2026 年) の両方にあり、どれも以前の固定の日付 (2026-10-14) より前 (未来の日付にならない)
        for item in &items {
            assert!((date(2025, 1, 1)..old_made_on()).contains(&item.made_on), "{}: {}", item.asset_id, item.made_on);
        }
        let in_year = |y| items.iter().filter(|i| i.made_on.year() == y).count();
        assert!(in_year(2025) >= 5 && in_year(2026) >= 5, "2025: {}, 2026: {}", in_year(2025), in_year(2026));
        // 同じ日に 2 つ作ったことにはしない
        let mut dates: Vec<NaiveDate> = items.iter().map(|i| i.made_on).collect();
        dates.sort();
        dates.dedup();
        assert_eq!(dates.len(), items.len());
    }
}
