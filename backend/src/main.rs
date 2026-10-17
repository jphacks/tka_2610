mod artworks;
mod error;
mod glb;
mod media;
mod migration_repair;
mod museum;
mod museum_api;
mod state;

use std::{
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
    routing::{get, post, put},
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

    let museum_source = env::var("MUSEUM_MODEL_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| manifest_dir.join("static").join("models").join("sample.glb"));

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

    let museum_model_url = prepare_museum_model(&museum_source, &media_dir.join("museum")).await;

    let state = AppState {
        pool,
        media_dir: media_dir.clone(),
        museum_model_url,
    };

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
        // 以前の管理画面でアップロードした GLB
        .nest_service(
            "/models",
            ServeDir::new(manifest_dir.join("static").join("models")),
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

/// 博物館GLBを media/museum/{version}.glb にコピーし、gzip 版も作っておく。
/// バージョンは元ファイルのサイズと更新日時から決まるので、差し替えると URL が変わる。
async fn prepare_museum_model(source: &Path, out_dir: &Path) -> Option<String> {
    let meta = match fs::metadata(source).await {
        Ok(meta) => meta,
        Err(_) => {
            println!("[Museum] {} が見つかりません (3D背景なしで起動します)", source.display());
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

    let file = out_dir.join(format!("museum-{version}.glb"));
    let gz = out_dir.join(format!("museum-{version}.glb.gz"));

    if !gz.exists() {
        let source = source.to_path_buf();
        let out_dir = out_dir.to_path_buf();
        let (file, gz) = (file.clone(), gz.clone());
        let result = tokio::task::spawn_blocking(move || -> std::io::Result<(u64, u64)> {
            // 古いバージョンを掃除
            for entry in std::fs::read_dir(&out_dir)?.flatten() {
                let _ = std::fs::remove_file(entry.path());
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
                "[Museum] Prepared model: {} KB -> {} KB (gzip)",
                raw / 1024,
                compressed / 1024
            ),
            Ok(Err(error)) => {
                println!("[Museum] Failed to prepare model: {error}");
                return None;
            }
            Err(error) => {
                println!("[Museum] Failed to prepare model: {error}");
                return None;
            }
        }
    }

    Some(format!("/media/museum/museum-{version}.glb"))
}
