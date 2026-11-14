//! memoria を Cloudflare で動かす (テスト環境)。
//!
//! - 入口の Worker (このファイルの fetch): /api と /media を、その人の家の Durable Object (Museum) に渡す。
//!   家は開いた人ごとに 1 つ (house.rs。Cookie `memoria_house`)。
//!   画面の JS・CSS (/assets)・家具と壁紙 (/home-assets)・舞台 (/stage-assets) は静的ファイルで、Worker を通らずに配られる。
//!   画面の HTML は Worker を通して、家の Cookie を付けてから静的ファイルを返す (wrangler.toml の run_worker_first)。
//!   建物の GLB とサンプルの作品のファイルも静的ファイル (/media の中なので Worker が取って返す)
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
#[path = "../../backend/src/all_ages.rs"]
mod all_ages;
#[path = "../../backend/src/all_home.rs"]
mod all_home;
mod all_home_api;
mod albums;
mod artworks;
mod db;
mod digest;
mod error;
mod home_api;
mod house;
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

/// 静的ファイルの応答を、本体の ReadableStream ごとそのまま返す。
/// `Fetcher::fetch_request` (http 機能あり) は本体を Rust のストリームに変えてから JS に戻すので、
/// Content-Length が消えて、大きな GLB をいくつも同時に読むと途中で切れた (本物の Cloudflare で確認)
async fn static_asset(env: &Env, req: &Request) -> Result<Response> {
    use worker::wasm_bindgen::JsCast;
    let assets = env.assets("ASSETS")?;
    let fetcher: &worker::worker_sys::Fetcher = assets.as_ref().unchecked_ref();
    let promise = fetcher.fetch(req.inner())?;
    let res = worker::wasm_bindgen_futures::JsFuture::from(promise).await?;
    Ok(res.dyn_into::<worker::web_sys::Response>()?.into())
}

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    let path = req.path();
    if path == "/healthz" {
        return Response::ok("ok");
    }
    if is_static_media(&path) {
        return static_asset(&env, &req).await;
    }
    let is_data = path.starts_with("/api/") || path.starts_with("/media/");
    if !is_data {
        if let Some(res) = house::switch(&req)? {
            return Ok(res);
        }
    }
    let house = house::of_request(&req);
    if path == "/house" {
        return house::page(&req, &house);
    }
    let res = if is_data {
        // 家ごとに Durable Object が 1 つ
        let stub = env.durable_object("MUSEUM")?.id_from_name(&house::object_name(&house))?.get_stub()?;
        stub.fetch_with_request(req).await?
    } else {
        // 画面 (index.html。SPA のどのパスでも同じ)
        static_asset(&env, &req).await?
    };
    if house.fresh { house::with_cookie(res, &house.id) } else { Ok(res) }
}
