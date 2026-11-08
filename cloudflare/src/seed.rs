//! 起動時に、アトリエの作品 33 点 (backend/static/atelier) を作品として登録し、おうちに飾る (backend の seed.rs と同じ)。
//!
//! 写真の縮小と GLB の実寸の計測は、ビルドのときに cloudflare/prep が済ませてある (generated/seed.json)。
//! ファイルは静的ファイル (public/media/…/<作品 id>-seed.*) なので、ここでは行を入れて飾るだけ。
//! backend と同じく、作品を Web で削除しても、次に起きたときに登録し直される。

use chrono::NaiveDate;
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    age,
    artworks::{load_sizes, sizes_of},
    db::{uuid_list, Db},
    error::AppResult,
    home_api, museum_api, params, schema,
    state::AppState,
};

const CHILD_NAME: &str = "アトリエ";
const CATEGORY: &str = "craft";

const SEED_JSON: &str = include_str!("../generated/seed.json");

/// generated/seed.json の 1 件 (cloudflare/prep が書く)
#[derive(Deserialize)]
struct SeedItem {
    id: Uuid,
    title: String,
    memo: String,
    made_on: NaiveDate,
    image_file: String,
    model_file: String,
    image_width: u32,
    image_height: u32,
    tint: String,
    size: Option<[f64; 3]>,
}

/// assetId から決まる作品 id (何度起動しても、どの PC でも同じ)
pub fn seed_id(asset_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, format!("memory-museum/atelier/{asset_id}").as_bytes())
}

pub fn ensure_atelier(state: &AppState) {
    match run(&state.db) {
        Ok((inserted, placed)) => worker::console_log!("[Seed] atelier: inserted {inserted}, placed {placed}"),
        Err(error) => worker::console_log!("[Seed] atelier: 登録できませんでした ({})", error.message),
    }
}

fn run(db: &Db) -> AppResult<(usize, usize)> {
    let items: Vec<SeedItem> = serde_json::from_str(SEED_JSON).map_err(crate::error::AppError::internal)?;
    let ids: Vec<Uuid> = items.iter().map(|i| i.id).collect();
    let existing: Vec<(Uuid,)> = db.tuples("SELECT id FROM artworks WHERE id IN (SELECT value FROM json_each(?1))", vec![uuid_list(&ids)])?;
    let missing: Vec<&SeedItem> = items.iter().filter(|i| !existing.iter().any(|(id,)| *id == i.id)).collect();
    if missing.is_empty() {
        return Ok((0, 0));
    }

    db.tx(|| {
        for item in &missing {
            let catalog_no = schema::next_catalog_no(db)?;
            db.exec(
                "INSERT INTO artworks (id, title, child_name, made_on, memo, category, \
                    image_file, thumb_file, model_file, model_kind, image_width, image_height, tint, \
                    model_width, model_height, model_depth, catalog_no) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?8, 'custom', ?9, ?10, ?11, ?12, ?13, ?14, ?15) \
                 ON CONFLICT (id) DO NOTHING",
                params![
                    item.id, item.title, CHILD_NAME, item.made_on, item.memo, CATEGORY, item.image_file, item.model_file,
                    item.image_width, item.image_height, item.tint,
                    item.size.map(|s| s[0]), item.size.map(|s| s[1]), item.size.map(|s| s[2]), catalog_no
                ],
            )?;
        }
        let inserted: Vec<Uuid> = missing.iter().map(|i| i.id).collect();
        let placed = place(db, &inserted)?;
        Ok((inserted.len(), placed))
    })
}

/// 新しく登録した作品を、作ったときの年齢のおへやの空いている棚や机の上に飾る (その年齢のおへやが無ければ 1 階を作り、
/// どのおへやもいっぱいなら上の階を足す)
fn place(db: &Db, ids: &[Uuid]) -> AppResult<usize> {
    let birthday = museum_api::child_birthday(db)?;
    let rows: Vec<(Uuid, NaiveDate, Option<i16>)> =
        db.tuples("SELECT id, made_on, age FROM artworks WHERE id IN (SELECT value FROM json_each(?1))", vec![uuid_list(ids)])?;
    let sizes = sizes_of(&load_sizes(db, ids)?);

    let mut placed = 0;
    for &id in ids {
        let Some((_, made_on, manual)) = rows.iter().find(|r| r.0 == id) else { continue };
        let age = age::artwork_age(birthday, *made_on, *manual);
        if home_api::place_in_age_adding_floors(db, id, sizes.get(&id), age)?.is_some() {
            placed += 1;
        }
    }
    Ok(placed)
}
