//! memoriaの振り返り。日付の選択・年齢による分類はRustで行う。
use std::collections::BTreeMap;

use axum::{
    Json,
    extract::{Query, State},
};
use chrono::{Datelike, Local, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::{
    age,
    artworks::{ArtworkDto, ArtworkRow, COLUMNS, DtoContext},
    error::{AppError, AppResult},
    memories::{self, MemoryDto},
    state::{AppState, MediaKind, media_url},
};

#[derive(Default, Deserialize)]
pub struct RecallQuery {
    age: Option<i16>,
}

#[derive(Serialize)]
pub struct RecallCard {
    artwork: ArtworkDto,
    /// 作品画像とは別の「おもいでの写真」。
    photo: Option<MemoryDto>,
    voice: Option<MemoryDto>,
}

#[derive(Serialize)]
pub struct AgeAlbum {
    age: i16,
    label: String,
    count: usize,
    cover_url: String,
}

#[derive(Serialize)]
pub struct Recollections {
    moment_title: String,
    moment_note: String,
    featured: Option<RecallCard>,
    moments: Vec<RecallCard>,
    voices: Vec<RecallCard>,
    age_albums: Vec<AgeAlbum>,
    selected_age: Option<i16>,
    age_artworks: Vec<ArtworkDto>,
    total: usize,
}

/// 入力は作成日の新しい順。未来の作品は振り返りに含めない。
fn moment_indices(dates: &[NaiveDate], today: NaiveDate) -> (String, Vec<usize>) {
    let anniversaries: Vec<_> = dates
        .iter()
        .enumerate()
        .filter(|(_, d)| d.year() < today.year() && d.month() == today.month())
        .map(|(i, _)| i)
        .collect();
    if !anniversaries.is_empty() {
        let first_year = dates[anniversaries[0]].year();
        let same_year = anniversaries.iter().all(|&i| dates[i].year() == first_year);
        let title = if same_year {
            format!("{}年前の{}月", today.year() - first_year, today.month())
        } else {
            format!("これまでの{}月", today.month())
        };
        return (title, anniversaries);
    }
    let latest = dates
        .iter()
        .find(|&&d| d <= today && (d.year(), d.month()) < (today.year(), today.month()))
        .or_else(|| dates.iter().find(|&&d| d <= today));
    match latest {
        Some(date) => (
            format!("{}年{}月の作品", date.year(), date.month()),
            dates
                .iter()
                .enumerate()
                .filter(|(_, d)| {
                    d.year() == date.year() && d.month() == date.month() && **d <= today
                })
                .map(|(i, _)| i)
                .collect(),
        ),
        None => ("作品を振り返る".into(), vec![]),
    }
}

/// 何度開いても同じ日に同じ作品と出会う。翌日は別の作品へ。
fn daily_feature(indices: &[usize], today: NaiveDate) -> Option<usize> {
    if indices.is_empty() {
        None
    } else {
        Some(indices[today.num_days_from_ce().unsigned_abs() as usize % indices.len()])
    }
}

async fn card(state: &AppState, row: &ArtworkRow, ctx: &DtoContext) -> AppResult<RecallCard> {
    let memories = memories::of_artwork(&state.pool, row.id).await?;
    let mut photo = None;
    let mut voice = None;
    for memory in memories {
        match memory.kind.as_str() {
            "photo" if photo.is_none() => photo = Some(memory),
            "audio" if voice.is_none() => voice = Some(memory),
            _ => {}
        }
    }
    Ok(RecallCard {
        artwork: ArtworkDto::new(row, ctx),
        photo,
        voice,
    })
}

pub async fn overview(
    State(state): State<AppState>,
    Query(query): Query<RecallQuery>,
) -> AppResult<Json<Recollections>> {
    if query.age.is_some_and(|a| !(0..=age::MAX_AGE).contains(&a)) {
        return Err(AppError::bad_request("年齢の指定を確認してください"));
    }
    let today = Local::now().date_naive();
    let rows = sqlx::query_as::<_, ArtworkRow>(&format!(
        "SELECT {COLUMNS} FROM artworks WHERE made_on <= $1 ORDER BY made_on DESC, created_at DESC, id"
    )).bind(today).fetch_all(&state.pool).await?;
    let ctx = DtoContext::load(&state.pool).await?;
    let dates: Vec<_> = rows.iter().map(|r| r.made_on).collect();
    let (moment_title, indices) = moment_indices(&dates, today);
    let selected = daily_feature(&indices, today);
    let featured = match selected {
        Some(i) => Some(card(&state, &rows[i], &ctx).await?),
        None => None,
    };
    let mut moments = Vec::new();
    for i in indices
        .iter()
        .copied()
        .filter(|&i| Some(i) != selected)
        .take(4)
    {
        moments.push(card(&state, &rows[i], &ctx).await?);
    }
    let mut voices = Vec::new();
    for row in rows
        .iter()
        .filter(|r| ctx.memories.get(&r.id).is_some_and(|c| c.audio > 0))
        .take(6)
    {
        let value = card(&state, row, &ctx).await?;
        if value.voice.is_some() {
            voices.push(value);
        }
    }
    let mut by_age: BTreeMap<i16, Vec<&ArtworkRow>> = BTreeMap::new();
    for row in &rows {
        by_age
            .entry(age::artwork_age(ctx.birthday, row.made_on, row.age))
            .or_default()
            .push(row);
    }
    let selected_age = query
        .age
        .filter(|a| by_age.contains_key(a))
        .or_else(|| by_age.keys().last().copied());
    let age_albums = by_age
        .iter()
        .map(|(&a, works)| AgeAlbum {
            age: a,
            label: format!("{a}さいのころ"),
            count: works.len(),
            cover_url: media_url(MediaKind::Thumb, &works[0].thumb_file),
        })
        .collect();
    let age_artworks = selected_age
        .and_then(|a| by_age.get(&a))
        .map(|works| works.iter().map(|r| ArtworkDto::new(r, &ctx)).collect())
        .unwrap_or_default();
    Ok(Json(Recollections {
        moment_title,
        moment_note: "作品を作った日から選んでいます".into(),
        featured,
        moments,
        voices,
        age_albums,
        selected_age,
        age_artworks,
        total: rows.len(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    #[test]
    fn recalls_same_month_in_previous_years_without_future_or_current_year() {
        let dates = [
            d(2027, 11, 1),
            d(2026, 11, 1),
            d(2025, 11, 30),
            d(2025, 10, 1),
            d(2024, 11, 1),
        ];
        let (title, indices) = moment_indices(&dates, d(2026, 11, 3));
        assert_eq!(title, "これまでの11月");
        assert_eq!(indices, vec![2, 4]);
        assert_eq!(
            moment_indices(&[d(2025, 11, 1)], d(2026, 11, 3)).0,
            "1年前の11月"
        );
    }

    #[test]
    fn sparse_records_fall_back_to_latest_recorded_month_and_use_honest_title() {
        let dates = [
            d(2027, 1, 1),
            d(2026, 11, 2),
            d(2026, 9, 20),
            d(2026, 9, 1),
            d(2025, 8, 1),
        ];
        let (title, indices) = moment_indices(&dates, d(2026, 11, 3));
        assert_eq!(title, "2026年9月の作品");
        assert_eq!(indices, vec![2, 3]);
        assert_eq!(moment_indices(&[d(2026, 11, 1)], d(2026, 11, 3)).1, vec![0]);
        assert!(moment_indices(&[], d(2026, 11, 3)).1.is_empty());
        assert!(
            moment_indices(&[d(2027, 1, 1)], d(2026, 11, 3))
                .1
                .is_empty()
        );
    }

    #[test]
    fn daily_selection_is_stable_changes_next_day_and_handles_leap_day() {
        let indices = [4, 9, 12];
        let date = d(2024, 2, 29);
        assert_eq!(daily_feature(&indices, date), daily_feature(&indices, date));
        assert_ne!(
            daily_feature(&indices, date),
            daily_feature(&indices, d(2024, 3, 1))
        );
        assert_eq!(daily_feature(&[], date), None);
    }
}
