//! memoria を Cloudflare で動かす (テスト環境)。
//!
//! - 入口の Worker (このファイルの fetch): /api と /media を Durable Object (Museum) に渡す。
//!   画面 (web/dist)・家具と壁紙 (/home-assets)・舞台 (/stage-assets)・建物の GLB とサンプルの作品のファイルは、
//!   ビルドのときに public/ に入れた静的ファイルで、Worker を通らずに配られる (wrangler.toml の assets)
//! - Durable Object (museum.rs): backend と同じ API を axum で動かす。データとファイルはその中の SQLite
//!
//! 処理のうち DB に触らないもの (置き方の決まり・年齢・GLB・写真の処理) は backend のファイルをそのまま使う。

#[allow(dead_code)]
#[path = "../../backend/src/age.rs"]
mod age;
#[allow(dead_code)]
#[path = "../../backend/src/glb.rs"]
mod glb;
#[allow(dead_code)]
#[path = "../../backend/src/home.rs"]
mod home;
#[allow(dead_code)]
#[path = "../../backend/src/media.rs"]
mod media;
#[path = "../../backend/src/museum.rs"]
mod museum;

mod ages_api;
mod albums;
mod artworks;
mod db;
mod digest;
mod error;
mod home_api;
mod memo_draft;
mod memories;
mod museum_api;
mod museum_do;
mod photo;
mod recollections;
mod schema;
mod seed;
mod state;
mod store;
mod theater;

use worker::{event, Context, Env, Request, Response, Result};

/// サンプルの作品のファイル (ファイル名に "-seed." が入る) と建物の GLB は、静的ファイルに入れてある
fn is_static_media(path: &str) -> bool {
    path.starts_with("/media/museum/") || (path.starts_with("/media/") && path.contains("-seed."))
}

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    let path = req.path();
    if path == "/healthz" {
        return Response::ok("ok");
    }
    if is_static_media(&path) {
        return Response::try_from(env.assets("ASSETS")?.fetch_request(req).await?);
    }
    // おうちは 1 つなので、Durable Object も 1 つ
    let stub = env.durable_object("MUSEUM")?.id_from_name("main")?.get_stub()?;
    stub.fetch_with_request(req).await
}
