//! Cloudflare に置く静的ファイルを public/ に集め、Worker に埋め込む値を generated/ に書く。
//!
//! - web/dist → public/ (画面)
//! - backend/static/home → public/home-assets/ (家具・壁紙)、backend/static/stage → public/stage-assets/ (シアターの舞台)
//! - 建物の GLB → public/media/museum/<名前>-<版>.glb (版は中身のハッシュ。中身が変わると URL も変わる) と generated/museum.json
//! - サンプルの作品 (backend/static/atelier) → public/media/{images,thumbs,models}/<作品 id>-seed.* と generated/seed.json。
//!   写真は backend の seed と同じ処理 (media::process) で縮め、GLB は実寸を測る
//!
//! 使い方: cd cloudflare/prep && cargo run --release (cloudflare/ の npm run build から呼ぶ)

#[allow(dead_code)]
#[path = "../../../backend/src/glb.rs"]
mod glb;
#[allow(dead_code)]
#[path = "../../../backend/src/media.rs"]
mod media;

use std::{
    fs,
    path::{Path, PathBuf},
};

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// static/atelier/catalog.json の 1 件 (backend の seed::AtelierItem と同じ)
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AtelierItem {
    asset_id: String,
    title_ja: String,
    memo: String,
    made_on: NaiveDate,
    model: String,
    photo: String,
}

/// Worker が登録に使う、サンプルの作品 1 件
#[derive(Serialize)]
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

/// assetId から決まる作品 id (backend の seed::seed_id と同じ)
fn seed_id(asset_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, format!("memory-museum/atelier/{asset_id}").as_bytes())
}

fn copy_dir(from: &Path, to: &Path) -> usize {
    let mut count = 0;
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap_or_else(|e| panic!("{} を読めません: {e}", from.display())) {
        let entry = entry.unwrap();
        let path = entry.path();
        let target = to.join(entry.file_name());
        if path.is_dir() {
            count += copy_dir(&path, &target);
        } else {
            fs::copy(&path, &target).unwrap();
            count += 1;
        }
    }
    count
}

fn write(path: &Path, bytes: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap_or_else(|e| panic!("{} を書けません: {e}", path.display()));
}

/// 建物の GLB を public/media/museum/<名前>-<版>.glb に置き、配信 URL を返す
fn museum_model(source: &Path, public: &Path, name: &str) -> Option<String> {
    let Ok(data) = fs::read(source) else {
        println!("[Museum] {} が見つかりません", source.display());
        return None;
    };
    let hash = Sha256::digest(&data);
    let version: String = hash.iter().take(6).map(|b| format!("{b:02x}")).collect();
    let file = format!("{name}-{version}.glb");
    write(&public.join("media/museum").join(&file), &data);
    Some(format!("/media/museum/{file}"))
}

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap();
    let cloudflare = root.join("cloudflare");
    let public = cloudflare.join("public");
    let generated = cloudflare.join("generated");
    let static_dir = root.join("backend/static");

    if public.exists() {
        fs::remove_dir_all(&public).unwrap();
    }
    fs::create_dir_all(&generated).unwrap();

    let web = root.join("web/dist");
    assert!(web.join("index.html").exists(), "web/dist がありません。先に cd web && npm run build をしてください");
    println!("[Web] {} files", copy_dir(&web, &public));
    println!("[Home] {} files", copy_dir(&static_dir.join("home"), &public.join("home-assets")));
    println!("[Stage] {} files", copy_dir(&static_dir.join("stage"), &public.join("stage-assets")));

    // 建物 (backend の main.rs の prepare_museum_model と同じ名前の付け方。版だけ中身のハッシュにする)
    let museum_model_url = museum_model(&static_dir.join("models/home-empty.glb"), &public, "museum");
    let mut rooms = serde_json::Map::new();
    for entry in fs::read_dir(static_dir.join("models/rooms")).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "glb") {
            let id = path.file_stem().unwrap().to_string_lossy().to_string();
            if let Some(url) = museum_model(&path, &public, &format!("room-{id}")) {
                rooms.insert(id, url.into());
            }
        }
    }
    let museum = serde_json::json!({ "museum_model_url": museum_model_url, "rooms": rooms });
    write(&generated.join("museum.json"), serde_json::to_string_pretty(&museum).unwrap().as_bytes());
    println!("[Museum] {museum}");

    // サンプルの作品 (backend の seed.rs の insert と同じ処理)
    let atelier = static_dir.join("atelier");
    let items: Vec<AtelierItem> = match fs::read_to_string(atelier.join("catalog.json")) {
        Ok(text) => serde_json::from_str(&text).expect("atelier/catalog.json を読めません"),
        Err(_) => Vec::new(),
    };
    let mut seeds = Vec::new();
    for item in &items {
        let id = seed_id(&item.asset_id);
        let photo = fs::read(atelier.join(&item.photo)).unwrap();
        let processed = media::process(&photo).unwrap_or_else(|e| panic!("{}: {e}", item.photo));
        let model = fs::read(atelier.join(&item.model)).unwrap();
        glb::validate_glb(&model).unwrap_or_else(|e| panic!("{}: {e}", item.model));
        let size = glb::measure_glb(&model).ok();
        let (image_file, model_file) = (format!("{id}-seed.jpg"), format!("{id}-seed.glb"));
        write(&public.join("media/images").join(&image_file), &processed.display_jpeg);
        write(&public.join("media/thumbs").join(&image_file), &processed.thumb_jpeg);
        write(&public.join("media/models").join(&model_file), &model);
        seeds.push(SeedItem {
            id,
            title: item.title_ja.clone(),
            memo: item.memo.clone(),
            made_on: item.made_on,
            image_file,
            model_file,
            image_width: processed.display_width,
            image_height: processed.display_height,
            tint: processed.tint,
            size,
        });
    }
    write(&generated.join("seed.json"), serde_json::to_string_pretty(&seeds).unwrap().as_bytes());
    println!("[Seed] {} artworks", seeds.len());
}
