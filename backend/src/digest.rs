//! 制作日から時期を分散して選ぶ、memoriaの作品ダイジェスト。
use axum::{
    Json,
    extract::{Query, State},
};
use chrono::{Datelike, Local, Months, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::{
    artworks::{ArtworkDto, ArtworkRow, COLUMNS, DtoContext},
    error::{AppError, AppResult},
    memories, museum, recollections,
    state::AppState,
};

#[derive(Default, Deserialize)]
pub struct DigestQuery {
    scope: Option<String>,
    category: Option<String>,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DigestSlide {
    Artwork {
        artwork: ArtworkDto,
        voice: Option<memories::MemoryDto>,
        duration_ms: u32,
    },
    Photo {
        artwork: ArtworkDto,
        photo: memories::MemoryDto,
        duration_ms: u32,
    },
    Comparison {
        first: ArtworkDto,
        last: ArtworkDto,
        duration_ms: u32,
    },
}
impl DigestSlide {
    fn duration_ms(&self) -> u32 {
        match self {
            Self::Artwork { duration_ms, .. }
            | Self::Photo { duration_ms, .. }
            | Self::Comparison { duration_ms, .. } => *duration_ms,
        }
    }
}

#[derive(Serialize)]
pub struct Digest {
    title: String,
    period_label: String,
    artwork_count: usize,
    duration_label: String,
    slides: Vec<DigestSlide>,
}

/// 入力は制作日の古い順。最初と最後を含め、日付の間隔を均等にする。
/// 同日に集中した記録でも、同じ作品を重複させず最大8点を返す。
fn pick_indices(dates: &[NaiveDate], today: NaiveDate, year_only: bool) -> Vec<usize> {
    let start = today
        .checked_sub_months(Months::new(12))
        .expect("valid date");
    let eligible: Vec<_> = dates
        .iter()
        .enumerate()
        .filter(|(_, date)| **date <= today && (!year_only || **date >= start))
        .map(|(index, _)| index)
        .collect();
    let count = eligible.len().min(8);
    if count <= 2 {
        return eligible;
    }
    let first = dates[eligible[0]].num_days_from_ce();
    let last = dates[*eligible.last().unwrap()].num_days_from_ce();
    let mut chosen = vec![0];
    for slot in 1..count - 1 {
        let target = i64::from(first) + i64::from(last - first) * slot as i64 / (count - 1) as i64;
        let low = chosen.last().unwrap() + 1;
        let high = eligible.len() - (count - slot);
        let best = (low..=high)
            .min_by_key(|&i| (i64::from(dates[eligible[i]].num_days_from_ce()) - target).abs())
            .unwrap();
        chosen.push(best);
    }
    chosen.push(eligible.len() - 1);
    chosen.into_iter().map(|i| eligible[i]).collect()
}

struct Selection {
    rows: Vec<ArtworkRow>,
    ctx: DtoContext,
    indices: Vec<usize>,
    title: String,
    period_label: String,
}

async fn selection(state: &AppState, query: &DigestQuery) -> AppResult<Selection> {
    let scope = query.scope.as_deref().unwrap_or("all");
    if !matches!(scope, "all" | "year") {
        return Err(AppError::bad_request(
            "ダイジェストの期間を確認してください",
        ));
    }
    let category = query.category.as_deref().filter(|c| *c != "all");
    if category.is_some_and(|c| !museum::CATEGORIES.contains(&c)) {
        return Err(AppError::bad_request("作品の種類を確認してください"));
    }
    let today = Local::now().date_naive();
    let rows = sqlx::query_as::<_, ArtworkRow>(&format!(
        "SELECT {COLUMNS} FROM artworks WHERE made_on <= $1 AND ($2::text IS NULL OR category = $2) ORDER BY made_on ASC, created_at ASC, id"
    )).bind(today).bind(category).fetch_all(&state.pool).await?;
    let ctx = DtoContext::load(&state.pool).await?;
    let indices = pick_indices(
        &rows.iter().map(|r| r.made_on).collect::<Vec<_>>(),
        today,
        scope == "year",
    );
    let period_label = indices
        .first()
        .zip(indices.last())
        .map(|(&first, &last)| {
            format!(
                "{} — {}",
                crate::artworks::date_short(rows[first].made_on),
                crate::artworks::date_short(rows[last].made_on)
            )
        })
        .unwrap_or_default();
    let title = match (scope, category) {
        ("year", Some("drawing")) => "この1年の絵",
        (_, Some("drawing")) => "絵のうつりかわり",
        ("year", _) => "この1年の作品",
        _ => "これまでの作品",
    }
    .to_owned();
    Ok(Selection {
        rows,
        ctx,
        indices,
        title,
        period_label,
    })
}

pub async fn generate(
    State(state): State<AppState>,
    Query(query): Query<DigestQuery>,
) -> AppResult<Json<Digest>> {
    let Selection {
        rows,
        ctx,
        indices,
        title,
        period_label,
    } = selection(&state, &query).await?;
    let mut slides = Vec::new();
    for &index in &indices {
        let row = &rows[index];
        let memory = recollections::card(&state, row, &ctx).await?;
        // 声のある作品は、冒頭の最大8秒を聴ける間隔にする。
        let duration_ms = memory.voice.as_ref().map_or(4000, |v| {
            v.duration_ms.unwrap_or(6000).clamp(4000, 8000) as u32
        });
        slides.push(DigestSlide::Artwork {
            artwork: memory.artwork,
            voice: memory.voice,
            duration_ms,
        });
        if let Some(photo) = memory.photo {
            slides.push(DigestSlide::Photo {
                artwork: ArtworkDto::new(row, &ctx),
                photo,
                duration_ms: 2500,
            });
        }
    }
    if indices.len() > 1 {
        slides.push(DigestSlide::Comparison {
            first: ArtworkDto::new(&rows[indices[0]], &ctx),
            last: ArtworkDto::new(&rows[*indices.last().unwrap()], &ctx),
            duration_ms: 6000,
        });
    }
    let seconds = slides
        .iter()
        .map(DigestSlide::duration_ms)
        .sum::<u32>()
        .div_ceil(1000);
    Ok(Json(Digest {
        title: title.into(),
        period_label,
        artwork_count: indices.len(),
        duration_label: format!("約{seconds}秒"),
        slides,
    }))
}

/// 同じ選択ロジックを使う3D鑑賞用の読み取りAPI。既存の配置は変更しない。
#[derive(Serialize)]
pub struct MiniatureEntry {
    artwork: ArtworkDto,
    photos: Vec<memories::MemoryDto>,
    voice: Option<memories::MemoryDto>,
    hold_ms: u32,
}
#[derive(Serialize)]
pub struct MiniatureDigest {
    title: String,
    period_label: String,
    duration_label: String,
    transition_ms: u32,
    entries: Vec<MiniatureEntry>,
}

/// 写真を見る時間に、登録されたメモを読むための余韻を加える。
fn miniature_hold_ms(memo: &str, has_photos: bool) -> u32 {
    let base = if has_photos { 6000 } else { 4500 };
    let length = memo.trim().chars().count() as u32;
    if length == 0 {
        base
    } else {
        base.max((2500 + length * 70).clamp(8000, 14000))
    }
}

pub async fn miniature(
    State(state): State<AppState>,
    Query(query): Query<DigestQuery>,
) -> AppResult<Json<MiniatureDigest>> {
    let Selection {
        rows,
        ctx,
        indices,
        title,
        period_label,
    } = selection(&state, &query).await?;
    let mut entries = Vec::new();
    for index in indices {
        let row = &rows[index];
        let mut photos = Vec::new();
        let mut voice = None;
        for memory in memories::of_artwork(&state.pool, row.id).await? {
            match memory.kind.as_str() {
                "photo" if photos.len() < 3 => photos.push(memory),
                "audio" if voice.is_none() => voice = Some(memory),
                _ => {}
            }
        }
        let hold_ms = miniature_hold_ms(&row.memo, !photos.is_empty());
        entries.push(MiniatureEntry {
            artwork: ArtworkDto::new(row, &ctx),
            photos,
            voice,
            hold_ms,
        });
    }
    let transition_ms = 2400;
    let duration = entries.iter().map(|entry| entry.hold_ms).sum::<u32>()
        + entries.len().saturating_sub(1) as u32 * transition_ms;
    Ok(Json(MiniatureDigest {
        title,
        period_label,
        duration_label: format!("約{}秒", duration.div_ceil(1000)),
        transition_ms,
        entries,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn miniature_gives_memos_reading_time_without_slowing_empty_records() {
        assert_eq!(miniature_hold_ms(" \n　", false), 4500);
        assert_eq!(miniature_hold_ms("", true), 6000);
        assert_eq!(miniature_hold_ms("何度も作り直したね", false), 8000);
        assert_eq!(miniature_hold_ms(&"あ".repeat(100), true), 9500);
        assert_eq!(miniature_hold_ms(&"あ".repeat(500), true), 14000);
    }

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }
    #[test]
    fn includes_endpoints_and_spreads_dates_without_duplicates() {
        let dates: Vec<_> = (1..=12).map(|m| d(2025, m, 1)).collect();
        let picked = pick_indices(&dates, d(2026, 1, 1), false);
        assert_eq!(picked.len(), 8);
        assert_eq!(picked[0], 0);
        assert_eq!(*picked.last().unwrap(), 11);
        assert!(picked.windows(2).all(|w| w[0] < w[1]));
        let mut clustered = vec![d(2024, 1, 1); 25];
        clustered.extend([d(2024, 6, 1), d(2024, 12, 1), d(2025, 6, 1), d(2025, 12, 1)]);
        let selected = pick_indices(&clustered, d(2026, 1, 1), false);
        assert!(selected.iter().any(|&i| clustered[i] == d(2024, 12, 1)));
        assert!(selected.iter().any(|&i| clustered[i] == d(2025, 6, 1)));
    }
    #[test]
    fn handles_same_day_sparse_empty_and_future_records() {
        let same = vec![d(2025, 1, 1); 20];
        let selected = pick_indices(&same, d(2026, 1, 1), false);
        assert_eq!(selected.len(), 8);
        assert!(selected.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(*selected.last().unwrap(), 19);
        assert!(pick_indices(&[], d(2026, 1, 1), false).is_empty());
        assert_eq!(
            pick_indices(&[d(2025, 1, 1), d(2027, 1, 1)], d(2026, 1, 1), false),
            vec![0]
        );
    }
    #[test]
    fn year_range_is_inclusive_and_clamps_leap_day() {
        let dates = [
            d(2023, 2, 27),
            d(2023, 2, 28),
            d(2024, 2, 29),
            d(2024, 3, 1),
        ];
        assert_eq!(pick_indices(&dates, d(2024, 2, 29), true), vec![1, 2]);
        assert_eq!(pick_indices(&dates, d(2024, 2, 29), false), vec![0, 1, 2]);
    }
}
