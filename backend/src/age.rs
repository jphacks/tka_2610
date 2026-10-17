//! 子どもの誕生日から、作品を作ったときの年齢 (満年齢) を計算する。DB を使わない純粋な処理だけを置く。
//!
//! 年齢ごとのおへや (house_rooms.age) に作品を分けるのに使う。

use chrono::{Datelike, NaiveDate};

/// 年齢の上限 (これより上は同じ年齢として扱う。チップが増えすぎないように)
pub const MAX_AGE: i16 = 120;

/// birthday に生まれた子が date に何歳か (満年齢)。
/// date が誕生日より前なら 0。2 月 29 日生まれは、うるう年でない年は 3 月 1 日に年を取る
pub fn age_on(birthday: NaiveDate, date: NaiveDate) -> i16 {
    if date <= birthday {
        return 0;
    }
    let mut years = date.year() - birthday.year();
    // その年の誕生日 (2/29 が無い年は 3/1)
    let this_year = NaiveDate::from_ymd_opt(date.year(), birthday.month(), birthday.day())
        .unwrap_or_else(|| NaiveDate::from_ymd_opt(date.year(), 3, 1).expect("valid date"));
    if date < this_year {
        years -= 1;
    }
    years.clamp(0, i32::from(MAX_AGE)) as i16
}

/// 作品の年齢。誕生日があれば作成日から計算し、無ければ登録時に入れた年齢 (artworks.age)、それも無ければ 0
pub fn artwork_age(birthday: Option<NaiveDate>, made_on: NaiveDate, manual: Option<i16>) -> i16 {
    match birthday {
        Some(b) => age_on(b, made_on),
        None => manual.unwrap_or(0).clamp(0, MAX_AGE),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    #[test]
    fn counts_full_years() {
        let birthday = d(2021, 6, 1);
        assert_eq!(age_on(birthday, d(2021, 6, 1)), 0);
        assert_eq!(age_on(birthday, d(2022, 5, 31)), 0);
        assert_eq!(age_on(birthday, d(2022, 6, 1)), 1);
        assert_eq!(age_on(birthday, d(2025, 5, 31)), 3);
        assert_eq!(age_on(birthday, d(2025, 6, 1)), 4);
        assert_eq!(age_on(birthday, d(2026, 10, 17)), 5);
        // 誕生日より前は 0
        assert_eq!(age_on(birthday, d(2020, 1, 1)), 0);
    }

    #[test]
    fn leap_day_birthday_ages_on_march_first() {
        let birthday = d(2020, 2, 29);
        assert_eq!(age_on(birthday, d(2021, 2, 28)), 0);
        assert_eq!(age_on(birthday, d(2021, 3, 1)), 1);
        assert_eq!(age_on(birthday, d(2024, 2, 28)), 3);
        assert_eq!(age_on(birthday, d(2024, 2, 29)), 4);
    }

    #[test]
    fn falls_back_to_the_manual_age() {
        assert_eq!(artwork_age(None, d(2026, 1, 1), Some(5)), 5);
        assert_eq!(artwork_age(None, d(2026, 1, 1), None), 0);
        assert_eq!(artwork_age(Some(d(2021, 6, 1)), d(2026, 1, 1), Some(9)), 4);
    }

    #[test]
    fn sample_artworks_split_into_three_ages() {
        // デモの誕生日 (2021-06-01) で、サンプルの 13 点は 3さい 2・4さい 8・5さい 3 に分かれる
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/static/atelier/catalog.json");
        let Ok(text) = std::fs::read_to_string(path) else {
            return;
        };
        let items: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap();
        let mut counts = std::collections::BTreeMap::new();
        for item in items {
            let made_on = NaiveDate::parse_from_str(item["madeOn"].as_str().unwrap(), "%Y-%m-%d").unwrap();
            *counts.entry(age_on(d(2021, 6, 1), made_on)).or_insert(0) += 1;
        }
        assert_eq!(counts.into_iter().collect::<Vec<_>>(), vec![(3, 2), (4, 8), (5, 3)]);
    }
}
