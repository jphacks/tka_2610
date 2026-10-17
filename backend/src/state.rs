use std::{collections::HashMap, path::PathBuf};

use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    /// Rust が生成した画像・モデルの保存先
    pub media_dir: PathBuf,
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
}

impl MediaKind {
    pub fn dir(self) -> &'static str {
        match self {
            MediaKind::Image => "images",
            MediaKind::Thumb => "thumbs",
            MediaKind::Model => "models",
        }
    }
}

impl AppState {
    pub fn media_path(&self, kind: MediaKind, file: &str) -> PathBuf {
        self.media_dir.join(kind.dir()).join(file)
    }
}

/// Web 画面用の相対 URL (スマホから LAN 経由で開いても壊れない)
pub fn media_url(kind: MediaKind, file: &str) -> String {
    format!("/media/{}/{}", kind.dir(), file)
}
