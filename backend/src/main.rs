mod age;
mod ages_api;
mod artworks;
mod error;
mod glb;
mod home;
mod home_api;
mod media;
mod migration_repair;
mod museum;
mod museum_api;
mod seed;
mod state;

use std::{
    collections::HashMap,
    env,
    hash::{DefaultHasher, Hash, Hasher},
    io::Write,
    net::SocketAddr,
    path::{Path, PathBuf},
    time::{Duration, UNIX_EPOCH},
};

use axum::{
    extract::DefaultBodyLimit,
    http::{header, HeaderValue},
    response::Html,
    routing::{delete, get, post, put},
    Router,
};
use sqlx::postgres::PgPoolOptions;
use tokio::fs;
use tower_http::{
    compression::CompressionLayer,
    cors::CorsLayer,
    services::{ServeDir, ServeFile},
    set_header::SetResponseHeader,
};

use crate::state::AppState;

const IMMUTABLE: HeaderValue = HeaderValue::from_static("public, max-age=31536000, immutable");
/// 家具の GLB と壁紙。URL にハッシュが無いので immutable にはしない
const ONE_DAY: HeaderValue = HeaderValue::from_static("public, max-age=86400");

#[tokio::main]
async fn main() {
    dotenvy::dotenv().ok();

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    // -----------------------------
    // Environment
    // -----------------------------

    let database_url = env::var("DATABASE_URL").expect("DATABASE_URL is not set");

    let media_dir = env::var("MEDIA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| manifest_dir.join("data").join("media"));

    let static_dir = manifest_dir.join("static");

    // 家の建物 (壁と床だけ。8 × 8 m のリビング)。家具と作品は配置 JSON から別に置く
    let museum_source = env::var("MUSEUM_MODEL_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| static_dir.join("models").join("home-empty.glb"));

    // 一人称で歩く画面だけで使う別の GLB。指定したときだけ使い、無ければ歩く画面も MUSEUM_MODEL_PATH の GLB を使う
    let walk_source = env::var("WALK_MODEL_PATH").ok().map(PathBuf::from);

    // 家の建物 (部屋ごとの GLB。今はリビングの hub.glb だけ。ファイル名は home::ROOM_DEFS の model)
    let room_models_dir = env::var("HOME_ROOM_MODELS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| static_dir.join("models").join("rooms"));

    let web_dist = env::var("WEB_DIST")
        .map(PathBuf::from)
        .unwrap_or_else(|_| manifest_dir.join("..").join("web").join("dist"));

    // -----------------------------
    // PostgreSQL
    // -----------------------------

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await
        .expect("failed to connect database (.env の DATABASE_URL を確認してください)");

    println!("[DB] PostgreSQL connected");

    let migrator = sqlx::migrate!("./migrations");

    migration_repair::repair_line_endings(&pool, &migrator)
        .await
        .expect("failed to repair migration checksums");

    migrator
        .run(&pool)
        .await
        .expect("migration failed");

    println!("[DB] Migration completed");

    // -----------------------------
    // Storage
    // -----------------------------

    for dir in ["images", "thumbs", "models", "museum"] {
        fs::create_dir_all(media_dir.join(dir))
            .await
            .expect("failed to create media directory");
    }
    println!("[Storage] Media directory: {}", media_dir.display());

    let museum_model_url = prepare_museum_model(&museum_source, &media_dir.join("museum"), "museum").await;
    let walk_model_url = match &walk_source {
        Some(source) => prepare_museum_model(source, &media_dir.join("museum"), "walk").await,
        None => None,
    };
    // 部屋ごとに media/museum/room-<id>-<version>.glb にする。ファイルが無い部屋は model_url が null (警告だけ出して起動する)
    let mut room_model_urls = HashMap::new();
    for room in &home::ROOM_DEFS {
        let name = format!("room-{}", room.id);
        if let Some(url) = prepare_museum_model(&room_models_dir.join(room.model), &media_dir.join("museum"), &name).await {
            room_model_urls.insert(room.id, url);
        }
    }

    let state = AppState {
        pool,
        media_dir: media_dir.clone(),
        museum_model_url,
        walk_model_url,
        room_model_urls,
    };

    // -----------------------------
    // おうちの配置 (作品の実寸 → 初期配置 → 旧データの整理 → アトリエの作品の登録)
    // 配置の判定は作品の実寸を使うので、寸法の無い作品を先に測っておく
    // -----------------------------

    if let Err(error) = artworks::backfill_model_sizes(&state).await {
        println!("[Artwork] model sizes failed: {}", error.message);
    }
    home_api::ensure_rooms(&state)
        .await
        .unwrap_or_else(|e| panic!("failed to prepare rooms: {}", e.message));
    if let Err(error) = home_api::reconcile(&state).await {
        println!("[Home] reconcile failed: {}", error.message);
    }
    seed::ensure_atelier(&state, &static_dir.join("atelier")).await;

    // -----------------------------
    // Router
    // -----------------------------

    let api = Router::new()
        .route("/museum", get(museum_api::museum_overview))
        .route(
            "/settings",
            get(museum_api::get_settings).put(museum_api::update_settings),
        )
        .route(
            "/artworks",
            get(artworks::list_artworks).post(artworks::create_artwork),
        )
        .route(
            "/artworks/{id}",
            get(artworks::get_artwork)
                .patch(artworks::update_artwork)
                .delete(artworks::delete_artwork),
        )
        .route("/artworks/{id}/favorite", put(artworks::set_favorite))
        // 年齢ごとのおへや (ホームの年齢のチップ・積み上げの建物・マップ)
        .route("/ages", get(ages_api::list_ages))
        .route("/ages/{age}", get(ages_api::age_stack))
        .route("/ages/{age}/rooms", post(ages_api::add_room))
        .route("/rooms/{id}", delete(ages_api::delete_room))
        // 模様替え (家具と作品の配置 JSON)
        .route(
            "/home/layout",
            get(home_api::get_layout).put(home_api::put_layout),
        )
        .route(
            "/artworks/{id}/display",
            post(artworks::display_artwork).delete(artworks::undisplay_artwork),
        )
        .layer(CompressionLayer::new())
        .layer(DefaultBodyLimit::max(40 * 1024 * 1024));

    let immutable = |dir: ServeDir| {
        SetResponseHeader::if_not_present(dir, header::CACHE_CONTROL, IMMUTABLE)
    };

    let mut app = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .nest("/api", api)
        // Rust が生成した画像・サムネイル・作品GLB と博物館GLB。
        // ファイル名が内容ごとに変わるので永続キャッシュでき、.gz があれば圧縮版を返す
        .nest_service(
            "/media",
            immutable(ServeDir::new(&media_dir).precompressed_gzip()),
        )
        // 家具の GLB と壁紙のテクスチャ (static/home)
        .nest_service(
            "/home-assets",
            SetResponseHeader::if_not_present(
                ServeDir::new(static_dir.join("home")),
                header::CACHE_CONTROL,
                ONE_DAY,
            ),
        );

    // React (web/dist) を配信。未ビルドなら案内を表示
    let index = web_dist.join("index.html");
    if index.exists() {
        println!("[Web] Serving {}", web_dist.display());
        app = app
            .nest_service("/assets", immutable(ServeDir::new(web_dist.join("assets"))))
            .fallback_service(ServeDir::new(&web_dist).fallback(ServeFile::new(index)));
    } else {
        println!("[Web] {} が見つかりません。web で npm run build を実行してください", index.display());
        app = app.fallback(|| async {
            Html(
                "<h1>Memory Museum</h1><p>Web 画面が未ビルドです。<code>cd web &amp;&amp; npm install &amp;&amp; npm run build</code> を実行するか、開発中は <code>npm run dev</code> (http://localhost:5173) を使ってください。</p>",
            )
        });
    }

    let app = app.layer(CorsLayer::permissive()).with_state(state);

    // -----------------------------
    // Server
    // -----------------------------

    let port: u16 = env::var("PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8080);
    let address = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .unwrap_or_else(|e| panic!("failed to bind port {port}: {e}"));

    println!();
    println!("==============================");
    println!("Memory Museum Backend");
    println!("==============================");
    println!();
    println!("Web   : http://localhost:{port}");
    println!("API   : http://localhost:{port}/api/museum");
    println!();

    axum::serve(listener, app).await.expect("server failed");
}

/// 博物館GLBを media/museum/{name}-{version}.glb にコピーし、gzip 版も作っておく。
/// バージョンは元ファイルのサイズと更新日時から決まるので、差し替えると URL が変わる。
/// name ごとに古いバージョンを掃除する（通常版 "museum"、歩く画面用 "walk"、部屋ごとの "room-hub" などが同じフォルダに並ぶため）。
async fn prepare_museum_model(source: &Path, out_dir: &Path, name: &str) -> Option<String> {
    let meta = match fs::metadata(source).await {
        Ok(meta) => meta,
        Err(_) => {
            let note = match name {
                "walk" => "一人称で歩く画面も通常の博物館GLBを使います",
                room if room.starts_with("room-") => "警告: この部屋の建物は表示されません (house.rooms[].model_url は null)",
                _ => "3D背景なしで起動します",
            };
            println!("[Museum] {} が見つかりません ({note})", source.display());
            return None;
        }
    };

    let mut hasher = DefaultHasher::new();
    meta.len().hash(&mut hasher);
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .hash(&mut hasher);
    let version = format!("{:012x}", hasher.finish() & 0xffff_ffff_ffff);

    let file_name = format!("{name}-{version}.glb");
    let file = out_dir.join(&file_name);
    let gz = out_dir.join(format!("{file_name}.gz"));

    if !gz.exists() {
        let source = source.to_path_buf();
        let out_dir = out_dir.to_path_buf();
        let prefix = format!("{name}-");
        let (file, gz) = (file.clone(), gz.clone());
        let result = tokio::task::spawn_blocking(move || -> std::io::Result<(u64, u64)> {
            // 同じ name の古いバージョンを掃除
            for entry in std::fs::read_dir(&out_dir)?.flatten() {
                if entry.file_name().to_string_lossy().starts_with(&prefix) {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
            let data = std::fs::read(&source)?;
            std::fs::write(&file, &data)?;
            let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(7));
            encoder.write_all(&data)?;
            let compressed = encoder.finish()?;
            std::fs::write(&gz, &compressed)?;
            Ok((data.len() as u64, compressed.len() as u64))
        })
        .await;

        match result {
            Ok(Ok((raw, compressed))) => println!(
                "[Museum] Prepared {name} model: {} KB -> {} KB (gzip)",
                raw / 1024,
                compressed / 1024
            ),
            Ok(Err(error)) => {
                println!("[Museum] Failed to prepare {name} model: {error}");
                return None;
            }
            Err(error) => {
                println!("[Museum] Failed to prepare {name} model: {error}");
                return None;
            }
        }
    }

    Some(format!("/media/museum/{file_name}"))
}
