use std::collections::HashMap;

use worker::Env;

use crate::db::Db;

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub env: Env,
    /// 博物館GLBの配信URL (無ければ None)
    pub museum_model_url: Option<String>,
    /// 一人称で歩く画面用の高画質版の配信URL (無ければ None。そのときは museum_model_url を使う)
    pub walk_model_url: Option<String>,
    /// 家の建物の GLB の配信URL (部屋の id → URL)。ファイルが無い部屋は入らない (API では null)
    pub room_model_urls: HashMap<&'static str, String>,
}

/// メディアの種類ごとのサブディレクトリ
#[derive(Clone, Copy)]
pub enum MediaKind {
    Image,
    Thumb,
    Model,
    /// 作品のおもいで (写真・動画・声。写真の小さい画像も同じフォルダ)
    Memory,
}

impl MediaKind {
    pub fn dir(self) -> &'static str {
        match self {
            MediaKind::Image => "images",
            MediaKind::Thumb => "thumbs",
            MediaKind::Model => "models",
            MediaKind::Memory => "memories",
        }
    }
}

/// Web 画面用の相対 URL (スマホから LAN 経由で開いても壊れない)
pub fn media_url(kind: MediaKind, file: &str) -> String {
    format!("/media/{}/{}", kind.dir(), file)
}

/// 今日の日付 (日本時間)。backend はサーバーの PC の時計 (Local) を使うが、Cloudflare は UTC なので日本時間にそろえる
pub fn today() -> chrono::NaiveDate {
    (chrono::Utc::now() + chrono::Duration::hours(9)).date_naive()
}
