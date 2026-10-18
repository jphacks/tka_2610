//! 子どもの誕生日から、作品を作ったときの年齢 (満年齢) を計算する。DB を使わない純粋な処理だけを置く。
//!
//! 年齢ごとのおへや (house_rooms.age) に作品を分けるのに使う。作品一覧に出す「4さい 3か月」(月齢) もここで作る。

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

/// birthday から k か月後の記念日。その月にその日が無ければ翌月 1 日
/// (1/31 生まれの 1 か月後は 3/1。2/29 生まれの平年の誕生日が 3/1 なのと同じ扱い)
fn month_anniversary(birthday: NaiveDate, k: i32) -> NaiveDate {
    let total = birthday.year() * 12 + birthday.month0() as i32 + k;
    let (year, month0) = (total.div_euclid(12), total.rem_euclid(12) as u32);
    NaiveDate::from_ymd_opt(year, month0 + 1, birthday.day()).unwrap_or_else(|| {
        let (y, m) = if month0 == 11 { (year + 1, 1) } else { (year, month0 + 2) };
        NaiveDate::from_ymd_opt(y, m, 1).expect("valid date")
    })
}

/// birthday に生まれた子が date に生まれて何か月か。date が誕生日より前なら 0。
/// 12 で割った商は age_on (満年齢) と同じになる
pub fn months_on(birthday: NaiveDate, date: NaiveDate) -> i32 {
    if date <= birthday {
        return 0;
    }
    let mut months = (date.year() - birthday.year()) * 12 + date.month() as i32 - birthday.month() as i32;
    if month_anniversary(birthday, months) > date {
        months -= 1;
    }
    months.clamp(0, i32::from(MAX_AGE) * 12 + 11)
}

/// 作品一覧に出す、作ったときの年齢 (例: "4さい 3か月")
pub fn age_month_label(birthday: NaiveDate, date: NaiveDate) -> String {
    let months = months_on(birthday, date);
    format!("{}さい {}か月", months / 12, months % 12)
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
    fn counts_months_since_birth() {
        let birthday = d(2021, 6, 1);
        assert_eq!(age_month_label(birthday, d(2021, 6, 1)), "0さい 0か月");
        assert_eq!(age_month_label(birthday, d(2021, 6, 30)), "0さい 0か月");
        assert_eq!(age_month_label(birthday, d(2021, 7, 1)), "0さい 1か月");
        assert_eq!(age_month_label(birthday, d(2025, 5, 31)), "3さい 11か月");
        assert_eq!(age_month_label(birthday, d(2025, 6, 1)), "4さい 0か月");
        // デモの誕生日で、サンプルのショベルカー (2026-10-12) は 5 さい 4 か月
        assert_eq!(age_month_label(birthday, d(2026, 10, 12)), "5さい 4か月");
        // 誕生日より前は 0
        assert_eq!(age_month_label(birthday, d(2020, 1, 1)), "0さい 0か月");
        // 記念日の前日と当日
        let birthday = d(2022, 3, 15);
        assert_eq!(months_on(birthday, d(2022, 5, 14)), 1);
        assert_eq!(months_on(birthday, d(2022, 5, 15)), 2);
    }

    #[test]
    fn month_ends_move_to_the_first_of_next_month() {
        // 1/31 生まれ: 2 月に 31 日が無いので、1 か月目は 3/1
        let birthday = d(2021, 1, 31);
        assert_eq!(months_on(birthday, d(2021, 2, 28)), 0);
        assert_eq!(months_on(birthday, d(2021, 3, 1)), 1);
        assert_eq!(months_on(birthday, d(2021, 3, 30)), 1);
        assert_eq!(months_on(birthday, d(2021, 3, 31)), 2);
        // 2/29 生まれ: 平年の 2/28 はまだ 0 さい 11 か月、3/1 に 1 さい 0 か月 (age_on と同じ)
        let birthday = d(2020, 2, 29);
        assert_eq!(age_month_label(birthday, d(2021, 2, 28)), "0さい 11か月");
        assert_eq!(age_month_label(birthday, d(2021, 3, 1)), "1さい 0か月");
        assert_eq!(age_month_label(birthday, d(2024, 2, 29)), "4さい 0か月");
    }

    #[test]
    fn month_years_match_full_years() {
        for birthday in [d(2021, 6, 1), d(2020, 2, 29), d(2019, 1, 31), d(2018, 12, 31)] {
            let mut date = birthday;
            while date < d(2027, 1, 1) {
                assert_eq!(months_on(birthday, date) / 12, i32::from(age_on(birthday, date)), "{birthday} {date}");
                date = date.succ_opt().unwrap();
            }
        }
    }

    #[test]
    fn falls_back_to_the_manual_age() {
        assert_eq!(artwork_age(None, d(2026, 1, 1), Some(5)), 5);
        assert_eq!(artwork_age(None, d(2026, 1, 1), None), 0);
        assert_eq!(artwork_age(Some(d(2021, 6, 1)), d(2026, 1, 1), Some(9)), 4);
    }

    #[test]
    fn sample_artworks_split_into_three_ages() {
        // デモの誕生日 (2021-06-01) で、サンプルの 33 点は 3さい 5・4さい 19・5さい 9 に分かれる
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
        assert_eq!(counts.into_iter().collect::<Vec<_>>(), vec![(3, 5), (4, 19), (5, 9)]);
    }
}
