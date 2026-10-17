use std::path::PathBuf;

use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    /// Unity など別プロセスに渡す絶対URLの基点 (例: http://127.0.0.1:8080)
    pub public_base_url: String,
    /// Rust が生成した画像・モデルの保存先
    pub media_dir: PathBuf,
    /// 博物館GLBの配信URL (無ければ None)
    pub museum_model_url: Option<String>,
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
