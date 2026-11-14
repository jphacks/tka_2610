//! Durable Object「Museum」。backend の main.rs の代わりに、起動時の処理と API のルートを持つ。
//!
//! 体験用の家ごとに 1 つ (lib.rs が house.rs の `object_name` で呼ぶ。前の、みんなで 1 つの家は "main")。
//! 中の SQLite がデータベースとファイルの置き場所 (schema.rs・store.rs)。
//! 起動時の処理 (表の用意・おへやの用意・整理・サンプルの登録) は、起きてから最初の要求のときに 1 回だけ行う。

use std::{cell::Cell, collections::HashMap};

use axum::{
    extract::DefaultBodyLimit,
    routing::{delete, get, patch, post, put},
    Router,
};
use tower_service::Service;
use worker::{
    durable_object,
    js_sys::Reflect,
    wasm_bindgen::JsValue,
    DurableObject, Env, Request, Response, Result, State,
};

use crate::{
    ages_api, albums, artworks, db::Db, digest, home_api, memo_draft, memories, museum_api, recollections, schema, seed,
    state::AppState, store, theater,
};

/// 建物の GLB の配信 URL (ビルドのときに prepare が書く)
const MUSEUM_JSON: &str = include_str!("../generated/museum.json");

#[derive(serde::Deserialize)]
struct MuseumModels {
    museum_model_url: Option<String>,
    rooms: HashMap<String, String>,
}

#[durable_object]
pub struct Museum {
    state: State,
    env: Env,
    ready: Cell<bool>,
}

impl Museum {
    fn app_state(&self) -> Result<AppState> {
        let storage = Reflect::get(self.state.as_raw(), &JsValue::from_str("storage"))?;
        let db = Db::new(self.state.storage().sql(), storage);
        let models: MuseumModels = serde_json::from_str(MUSEUM_JSON).map_err(|e| worker::Error::RustError(e.to_string()))?;
        let room_model_urls = crate::home::ROOM_DEFS
            .iter()
            .filter_map(|room| models.rooms.get(room.id).map(|url| (room.id, url.clone())))
            .collect();
        Ok(AppState {
            db,
            env: self.env.clone(),
            museum_model_url: models.museum_model_url,
            walk_model_url: None,
            room_model_urls,
        })
    }
}

/// 起きてから最初の要求のときの処理 (backend の main.rs の起動時の処理と同じ順)。
/// 額縁の作り直し (upgrade_frames) と寸法の後埋め (backfill_model_sizes) は、作品をどれも今の額縁で作り、
/// 登録のときに測るので要らない。孤児ファイルの掃除も、ファイルが行と同じ DB にあるので要らない
fn startup(state: &AppState) -> crate::error::AppResult<()> {
    schema::migrate(&state.db)?;
    worker::console_log!("[DB] Migration completed");
    home_api::ensure_rooms(state)?;
    if let Err(error) = home_api::reconcile(state) {
        worker::console_log!("[Home] reconcile failed: {}", error.message);
    }
    seed::ensure_atelier(state);
    Ok(())
}

/// backend の main.rs と同じルート
fn router(state: AppState) -> Router {
    let api = Router::new()
        .route("/museum", get(museum_api::museum_overview))
        .route("/settings", get(museum_api::get_settings).put(museum_api::update_settings))
        .route("/artworks", get(artworks::list_artworks).post(artworks::create_artwork))
        .route(
            "/artworks/{id}",
            get(artworks::get_artwork).patch(artworks::update_artwork).delete(artworks::delete_artwork),
        )
        .route("/artworks/{id}/favorite", put(artworks::set_favorite))
        // アルバム (作品を自分で好きなグループにまとめる。id は UUID か "favorites")
        .route("/albums", get(albums::list_albums).post(albums::create_album))
        .route("/albums/{id}", get(albums::get_album).patch(albums::update_album).delete(albums::delete_album))
        .route("/albums/{id}/artworks", put(albums::update_artworks))
        .route("/artworks/{id}/memo-draft", post(memo_draft::generate))
        .route("/artworks/memo-draft", post(memo_draft::generate_upload))
        // おもいで (写真・動画・声の記録)。動画を送れるよう、このルートだけ送信の上限を上げる
        .route(
            "/artworks/{id}/memories",
            post(memories::upload_memory).layer(DefaultBodyLimit::max(memories::UPLOAD_BODY_LIMIT)),
        )
        .route("/artworks/{id}/memories/{memory_id}", patch(memories::update_memory).delete(memories::delete_memory))
        // 年齢ごとのおへや (ホームの年齢のチップ・積み上げの建物・マップ)
        .route("/recollections", get(recollections::overview))
        .route("/recollections/digest", get(digest::generate))
        .route("/recollections/miniature", get(digest::miniature))
        // 期間をえらんで振り返るシアター (場面ごとの時間割)
        .route("/recollections/theater", get(theater::theater))
        .route("/ages", get(ages_api::list_ages))
        .route("/ages/all", get(ages_api::all_stack))
        .route("/ages/all/{floor}", get(museum_api::all_room))
        .route("/ages/{age}", get(ages_api::age_stack))
        .route("/ages/{age}/rooms", post(ages_api::add_room))
        .route("/rooms/{id}", delete(ages_api::delete_room))
        // 模様替え (家具と作品の配置 JSON)
        .route("/home/layout", get(home_api::get_layout).put(home_api::put_layout))
        .route("/artworks/{id}/display", post(artworks::display_artwork).delete(artworks::undisplay_artwork))
        .layer(DefaultBodyLimit::max(40 * 1024 * 1024));
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .nest("/api", api)
        // 利用者が登録した写真・GLB・おもいで (サンプルの作品と建物は静的ファイル。lib.rs)
        .route("/media/{dir}/{file}", get(store::serve))
        .with_state(state)
}

impl DurableObject for Museum {
    fn new(state: State, env: Env) -> Self {
        Self { state, env, ready: Cell::new(false) }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        let app = self.app_state()?;
        if !self.ready.get() {
            startup(&app).map_err(|e| worker::Error::RustError(e.message))?;
            self.ready.set(true);
        }
        // web_sys::Request の clone() は JS の Request.clone() なので、Rust の Clone で参照を写す
        let request = worker::request_from_wasm(Clone::clone(req.inner()))?;
        let response = router(app).call(request).await.map_err(|e| worker::Error::RustError(e.to_string()))?;
        Ok(worker::response_to_wasm(response)?.into())
    }
}
