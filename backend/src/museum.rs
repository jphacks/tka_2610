//! 作品の種類 (カテゴリ)。
//!
//! 作品をどこに飾るか (家具と作品の配置) は home.rs の配置 JSON にある。

pub fn category_label(category: &str) -> &'static str {
    match category {
        "drawing" => "絵画",
        "craft" => "工作",
        "photo" => "写真",
        _ => "その他",
    }
}

pub const CATEGORIES: &[&str] = &["drawing", "craft", "photo", "other"];
