//! 期間をえらんで振り返る、3D のダイジェスト・シアター。
//!
//! 期間 (作品を作った日 `made_on`) の作品を古い順に全部ならべ、作品ごとの場面の時間割を作る。
//! Web は再生位置の時刻 1 本から、どの場面か・大地の回転・写真や動画・メモ・声を決めるので、
//! 時刻はすべてここで決める。おもいで (写真・動画・声) は追加した日にかかわらず作品と一緒に出す。
use axum::{
    Json,
    extract::{Query, State},
};
use chrono::{Datelike, Local, NaiveDate};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    age,
    artworks::{ArtworkDto, ArtworkRow, COLUMNS, DtoContext, date_short},
    error::{AppError, AppResult},
    memories::{self, MemoryDto},
    museum,
    state::AppState,
};

/// 1 回のシアターに出す作品の上限 (これより多いと truncated)
const MAX_SCENES: usize = 200;
// ---- テンポ (ふつうの速さ 1× のときの長さ。画面の「進む速さ」は、これを全部 1/速さ 倍にする) ----
/// 前の作品が流れ去り、次の作品が奥の稜線の上に来るまで (大地は止まらずに回る)
const TRANSITION_MS: u32 = 2000;
/// 最後の作品のあと、流れ去って終わるまで
const OUTRO_MS: u32 = 2000;
/// 写真・動画が立ち上がる時刻 (作品が着いてから)
const MEDIA_AT_MS: u32 = 500;
/// メモが浮かび上がる時刻 (作品が着いてから)。写真が立ったあと、少し間をおく
const MEMO_AT_MS: u32 = 1000;
/// 作品だけの場面の長さ / おもいでがある場面の最低の長さ
const BASE_HOLD_MS: u32 = 3800;
const MEDIA_HOLD_MS: u32 = 5200;
/// 写真 2 枚を見せる 1 回分の長さ
const PHOTO_ROUND_MS: u32 = 3400;
/// メモの 1 行を読む時間 = LINE_BASE_MS + 文字数 × LINE_PER_CHAR_MS (LINE_MIN_MS〜LINE_MAX_MS)
const LINE_BASE_MS: u32 = 800;
const LINE_PER_CHAR_MS: u32 = 80;
const LINE_MIN_MS: u32 = 1800;
const LINE_MAX_MS: u32 = 4500;
/// 動画は 1 本あたりこの長さまで流す。長さが分からない動画はこの長さとみなす
const VIDEO_MAX_MS: u32 = 12_000;
const VIDEO_UNKNOWN_MS: u32 = 8000;
/// 声は冒頭のこの長さまで
const VOICE_MAX_MS: u32 = 12_000;
const VOICE_UNKNOWN_MS: u32 = 6000;
/// 1 作品の写真・動画の数の上限
const MAX_MEDIA: usize = 6;
/// 場面の終わりの、写真やメモが消えていく時間
const SCENE_TAIL_MS: u32 = 500;
/// メモの 1 行の長さ (これより長い文は読点などで分ける)
const LINE_MAX_CHARS: usize = 42;
/// メモは最大この行数まで (それより後は省く)
const MAX_MEMO_LINES: usize = 10;

#[derive(Default, Deserialize)]
pub struct TheaterQuery {
    from: Option<String>,
    to: Option<String>,
    category: Option<String>,
}

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Side {
    Left,
    Right,
}

/// 作品の隣に立つ写真・動画。時刻は作品が着いた時刻 (arrive_ms) からの相対
#[derive(Serialize)]
pub struct MediaSlot {
    memory: MemoryDto,
    side: Side,
    show_ms: u32,
    hide_ms: u32,
    /// 動画を流す長さ (写真は None)
    play_ms: Option<u32>,
}

/// 作品の上に浮かぶメモの 1 行。時刻は arrive_ms からの相対
#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct MemoLine {
    text: String,
    show_ms: u32,
    hide_ms: u32,
}

#[derive(Serialize)]
pub struct TheaterScene {
    artwork: ArtworkDto,
    /// 大地が回りはじめる時刻 (全体の先頭から)
    start_ms: u32,
    /// 作品が手前に着く時刻 (全体の先頭から)
    arrive_ms: u32,
    /// 着いてから次の場面が始まるまで
    hold_ms: u32,
    media: Vec<MediaSlot>,
    memo: Vec<MemoLine>,
    voice: Option<MemoryDto>,
    /// 声を流す時刻 (arrive_ms からの相対) と長さ
    voice_at_ms: u32,
    voice_ms: u32,
}

/// 期間をえらぶボタン (これまで・作品のある年齢ごと)
#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct TheaterPreset {
    key: String,
    label: String,
    title: String,
    from: String,
    to: String,
}

#[derive(Serialize)]
pub struct TheaterAvailable {
    /// 作品のある最初と最後の日 (作品が無ければ None)
    first: Option<String>,
    last: Option<String>,
    today: String,
    presets: Vec<TheaterPreset>,
}

#[derive(Serialize)]
pub struct TheaterData {
    title: String,
    period_label: String,
    from: String,
    to: String,
    artwork_count: usize,
    truncated: bool,
    transition_ms: u32,
    outro_ms: u32,
    total_ms: u32,
    duration_label: String,
    available: TheaterAvailable,
    scenes: Vec<TheaterScene>,
}

// =============================
// 時間割 (DB を使わない純粋な処理)
// =============================

/// 文の終わりのあとに続けて置く記号 (閉じかっこなど)
fn is_closer(c: char) -> bool {
    matches!(c, '」' | '』' | '）' | ')' | '】' | '"' | '”' | '〉' | '》')
}

/// メモを、浮かび上がらせる行に分ける。改行と「。！？」で文に分け、長い文は読点などで折る
pub fn memo_lines(memo: &str) -> Vec<String> {
    let mut sentences = Vec::new();
    for paragraph in memo.lines() {
        let mut current = String::new();
        // かっこの中の「！」などでは切らない (「すごいでしょ！」って見せてくれた。は 1 文)
        let mut depth = 0i32;
        let mut chars = paragraph.trim().chars().peekable();
        while let Some(c) = chars.next() {
            current.push(c);
            if matches!(c, '「' | '『' | '（' | '(' | '【' | '〈' | '《' | '“') {
                depth += 1;
            } else if is_closer(c) {
                depth = (depth - 1).max(0);
            }
            if depth == 0 && matches!(c, '。' | '！' | '？' | '!' | '?' | '♪') {
                while let Some(&next) = chars.peek() {
                    if is_closer(next) || matches!(next, '。' | '！' | '？' | '!' | '?' | '♪') {
                        current.push(next);
                        chars.next();
                    } else {
                        break;
                    }
                }
                let sentence = current.trim().to_owned();
                if !sentence.is_empty() {
                    sentences.push(sentence);
                }
                current.clear();
            }
        }
        let rest = current.trim().to_owned();
        if !rest.is_empty() {
            sentences.push(rest);
        }
    }
    let mut lines: Vec<String> = sentences.into_iter().flat_map(|s| wrap_sentence(&s)).collect();
    if lines.len() > MAX_MEMO_LINES {
        lines.truncate(MAX_MEMO_LINES);
        if let Some(last) = lines.last_mut() {
            last.push('…');
        }
    }
    lines
}

/// 長い文を LINE_MAX_CHARS 以内に分ける。なるべく「、」「，」や空白のあとで切る
fn wrap_sentence(sentence: &str) -> Vec<String> {
    let chars: Vec<char> = sentence.chars().collect();
    let mut out = Vec::new();
    let mut start = 0;
    while chars.len() - start > LINE_MAX_CHARS {
        let window = &chars[start..start + LINE_MAX_CHARS];
        // 後ろ半分にある区切りを探す (前すぎると 1 行が短くなりすぎる)
        let cut = window
            .iter()
            .enumerate()
            .rev()
            .take(LINE_MAX_CHARS / 2)
            .find(|(_, c)| matches!(c, '、' | '，' | ',' | ' ' | '　'))
            .map_or(LINE_MAX_CHARS, |(i, _)| i + 1);
        let piece: String = chars[start..start + cut].iter().collect();
        out.push(piece.trim().to_owned());
        start += cut;
    }
    let rest: String = chars[start..].iter().collect();
    if !rest.trim().is_empty() {
        out.push(rest.trim().to_owned());
    }
    out
}

/// メモの 1 行を読む時間 (文字数から)
fn line_ms(text: &str) -> u32 {
    (LINE_BASE_MS + text.chars().count() as u32 * LINE_PER_CHAR_MS).clamp(LINE_MIN_MS, LINE_MAX_MS)
}

/// 写真・動画の情報 (時間割を決めるのに使う分だけ)
#[derive(Clone, Copy, Debug)]
pub struct MediaInfo {
    pub video: bool,
    pub duration_ms: Option<i32>,
}

fn video_play_ms(duration_ms: Option<i32>) -> u32 {
    duration_ms
        .filter(|&d| d > 0)
        .map_or(VIDEO_UNKNOWN_MS, |d| (d as u32).min(VIDEO_MAX_MS))
}

/// 1 つの場面の時間割
#[derive(Debug, PartialEq, Eq)]
pub struct ScenePlan {
    pub hold_ms: u32,
    /// media と同じ順の (左右・出る時刻・消える時刻・動画を流す長さ)
    pub slots: Vec<(Side, u32, u32, Option<u32>)>,
    /// memo_lines と同じ順の (出る時刻・消える時刻)
    pub lines: Vec<(u32, u32)>,
    pub voice_at_ms: u32,
    pub voice_ms: u32,
}

/// 場面の長さと、写真・動画・メモ・声の出る時刻を決める。
/// 写真・動画は左右 2 枠に交互に置き、2 つずつ順に見せる (動画がある回は、その長さだけ見せる)。
/// 場面の長さは、写真・動画を見る時間・メモを読む時間・声を聞く時間のいちばん長いもの
pub fn plan_scene(media: &[MediaInfo], lines: &[String], voice_ms: Option<Option<i32>>) -> ScenePlan {
    let media = &media[..media.len().min(MAX_MEDIA)];
    // 2 つずつの回に分け、回ごとの長さを決める
    let rounds: Vec<u32> = media
        .chunks(2)
        .map(|pair| {
            pair.iter()
                .filter(|m| m.video)
                .map(|m| video_play_ms(m.duration_ms))
                .max()
                .map_or(PHOTO_ROUND_MS, |v| v.max(PHOTO_ROUND_MS))
        })
        .collect();
    let media_end = MEDIA_AT_MS + rounds.iter().sum::<u32>();

    let mut line_times = Vec::with_capacity(lines.len());
    let mut at = MEMO_AT_MS;
    for line in lines {
        let ms = line_ms(line);
        line_times.push((at, at + ms));
        at += ms;
    }
    let memo_end = at;

    let voice_ms = voice_ms.map_or(0, |d| {
        d.filter(|&d| d > 0).map_or(VOICE_UNKNOWN_MS, |d| (d as u32).min(VOICE_MAX_MS))
    });
    let voice_at_ms = MEMO_AT_MS;

    let base = if media.is_empty() && voice_ms == 0 { BASE_HOLD_MS } else { MEDIA_HOLD_MS };
    let mut hold_ms = base;
    if !media.is_empty() {
        hold_ms = hold_ms.max(media_end + SCENE_TAIL_MS);
    }
    if !lines.is_empty() {
        hold_ms = hold_ms.max(memo_end + SCENE_TAIL_MS + 400);
    }
    if voice_ms > 0 {
        hold_ms = hold_ms.max(voice_at_ms + voice_ms + SCENE_TAIL_MS + 400);
    }

    // 最後の回の写真・動画とメモの最後の行は、場面の終わりまで残す
    let mut slots = Vec::with_capacity(media.len());
    let mut round_start = MEDIA_AT_MS;
    for (round, pair) in media.chunks(2).enumerate() {
        let last_round = round + 1 == rounds.len();
        let end = if last_round { hold_ms - SCENE_TAIL_MS } else { round_start + rounds[round] };
        for (i, m) in pair.iter().enumerate() {
            let side = if i == 0 { Side::Left } else { Side::Right };
            let play = m.video.then(|| video_play_ms(m.duration_ms));
            slots.push((side, round_start, end, play));
        }
        round_start += rounds[round];
    }
    if let Some(last) = line_times.last_mut() {
        last.1 = hold_ms - SCENE_TAIL_MS;
    }

    ScenePlan { hold_ms, slots, lines: line_times, voice_at_ms, voice_ms }
}

/// 全体の時間割: 各場面の (start_ms, arrive_ms) と全体の長さ。最初の作品も奥から転がってくる
pub fn layout_timeline(holds: &[u32]) -> (Vec<(u32, u32)>, u32) {
    let mut at = 0;
    let mut times = Vec::with_capacity(holds.len());
    for &hold in holds {
        times.push((at, at + TRANSITION_MS));
        at += TRANSITION_MS + hold;
    }
    let total = if holds.is_empty() { 0 } else { at + OUTRO_MS };
    (times, total)
}

// =============================
// 期間
// =============================

fn iso(date: NaiveDate) -> String {
    date.format("%Y-%m-%d").to_string()
}

fn parse_date(text: &str) -> AppResult<NaiveDate> {
    NaiveDate::parse_from_str(text.trim(), "%Y-%m-%d")
        .map_err(|_| AppError::bad_request("日付は 2026-04-01 のように指定してください"))
}

/// birthday から years 年後の誕生日 (2/29 生まれは、平年は 3/1。age::age_on と同じ扱い)
fn birthday_in(birthday: NaiveDate, years: i32) -> NaiveDate {
    NaiveDate::from_ymd_opt(birthday.year() + years, birthday.month(), birthday.day())
        .unwrap_or_else(|| NaiveDate::from_ymd_opt(birthday.year() + years, 3, 1).expect("valid date"))
}

/// 期間をえらぶボタン。dates は今日までの作品の作った日 (古い順)
pub fn presets(dates: &[NaiveDate], today: NaiveDate, birthday: Option<NaiveDate>) -> Vec<TheaterPreset> {
    let mut out = Vec::new();
    let first = dates.first().copied().unwrap_or(today);
    out.push(TheaterPreset {
        key: "all".into(),
        label: "これまで".into(),
        title: "これまでの作品".into(),
        from: iso(first.min(today)),
        to: iso(today),
    });
    // ほかは年齢ごとだけ (「この1年」「2026年」のような暦の区切りは、年齢と単位が混ざって分かりにくいので出さない。
    // それ以外の期間は「日付をえらぶ」で)
    if let Some(birthday) = birthday {
        let mut ages: Vec<i16> = dates
            .iter()
            .filter(|d| **d >= birthday)
            .map(|d| age::age_on(birthday, *d))
            .collect();
        ages.dedup();
        for a in ages {
            let from = birthday_in(birthday, i32::from(a));
            let to = (birthday_in(birthday, i32::from(a) + 1) - chrono::Duration::days(1)).min(today);
            out.push(TheaterPreset {
                key: format!("age{a}"),
                label: format!("{a}さい"),
                title: format!("{a}さいの作品"),
                from: iso(from),
                to: iso(to),
            });
        }
    }
    out
}

/// 期間の作品の添え字 (dates は古い順。from..=to に入るもの)。多すぎるときは先頭から MAX_SCENES 件
pub fn in_range(dates: &[NaiveDate], from: NaiveDate, to: NaiveDate) -> (Vec<usize>, bool) {
    let all: Vec<usize> = dates
        .iter()
        .enumerate()
        .filter(|(_, d)| **d >= from && **d <= to)
        .map(|(i, _)| i)
        .collect();
    let truncated = all.len() > MAX_SCENES;
    (all.into_iter().take(MAX_SCENES).collect(), truncated)
}

fn duration_label(total_ms: u32) -> String {
    let seconds = total_ms.div_ceil(1000);
    if seconds < 60 {
        format!("約{seconds}秒")
    } else {
        let minutes = seconds / 60;
        let rest = seconds % 60;
        if rest == 0 { format!("約{minutes}分") } else { format!("約{minutes}分{rest}秒") }
    }
}

// =============================
// API
// =============================

/// GET /api/recollections/theater?from=YYYY-MM-DD&to=YYYY-MM-DD[&category=drawing]
pub async fn theater(
    State(state): State<AppState>,
    Query(query): Query<TheaterQuery>,
) -> AppResult<Json<TheaterData>> {
    let category = query.category.as_deref().filter(|c| *c != "all" && !c.is_empty());
    if category.is_some_and(|c| !museum::CATEGORIES.contains(&c)) {
        return Err(AppError::bad_request("作品の種類を確認してください"));
    }
    let today = Local::now().date_naive();
    let from = query.from.as_deref().filter(|s| !s.trim().is_empty()).map(parse_date).transpose()?;
    let to = query.to.as_deref().filter(|s| !s.trim().is_empty()).map(parse_date).transpose()?;
    if let (Some(f), Some(t)) = (from, to)
        && f > t
    {
        return Err(AppError::bad_request("はじまりの日は、おわりの日より前にしてください"));
    }

    // 期間をえらぶボタンは、種類で絞らない全部の作品から作る
    let all_dates: Vec<NaiveDate> = sqlx::query_scalar(
        "SELECT made_on FROM artworks WHERE made_on <= $1 ORDER BY made_on ASC",
    )
    .bind(today)
    .fetch_all(&state.pool)
    .await?;
    let ctx = DtoContext::load(&state.pool).await?;
    let presets = presets(&all_dates, today, ctx.birthday);

    let to = to.unwrap_or(today).min(today);
    let from = from.unwrap_or_else(|| all_dates.first().copied().unwrap_or(today));

    let rows = sqlx::query_as::<_, ArtworkRow>(&format!(
        "SELECT {COLUMNS} FROM artworks WHERE made_on >= $1 AND made_on <= $2 AND ($3::text IS NULL OR category = $3) ORDER BY made_on ASC, created_at ASC, id"
    ))
    .bind(from)
    .bind(to)
    .bind(category)
    .fetch_all(&state.pool)
    .await?;
    let (indices, truncated) = in_range(&rows.iter().map(|r| r.made_on).collect::<Vec<_>>(), from, to);

    let ids: Vec<Uuid> = indices.iter().map(|&i| rows[i].id).collect();
    let mut memories = memories::of_artworks(&state.pool, &ids).await?;

    // 場面ごとの時間割
    let mut planned = Vec::with_capacity(indices.len());
    for &i in &indices {
        let row = &rows[i];
        let mut media = Vec::new();
        let mut voice = None;
        for memory in memories.remove(&row.id).unwrap_or_default() {
            match memory.kind.as_str() {
                "photo" | "video" if media.len() < MAX_MEDIA => media.push(memory),
                "audio" if voice.is_none() => voice = Some(memory),
                _ => {}
            }
        }
        let lines = memo_lines(&row.memo);
        let infos: Vec<MediaInfo> = media
            .iter()
            .map(|m| MediaInfo { video: m.kind == "video", duration_ms: m.duration_ms })
            .collect();
        let plan = plan_scene(&infos, &lines, voice.as_ref().map(|v| v.duration_ms));
        planned.push((row, media, lines, voice, plan));
    }
    let (times, total_ms) = layout_timeline(&planned.iter().map(|p| p.4.hold_ms).collect::<Vec<_>>());

    let scenes: Vec<TheaterScene> = planned
        .into_iter()
        .zip(times)
        .map(|((row, media, lines, voice, plan), (start_ms, arrive_ms))| TheaterScene {
            artwork: ArtworkDto::new(row, &ctx),
            start_ms,
            arrive_ms,
            hold_ms: plan.hold_ms,
            media: media
                .into_iter()
                .zip(plan.slots)
                .map(|(memory, (side, show_ms, hide_ms, play_ms))| MediaSlot { memory, side, show_ms, hide_ms, play_ms })
                .collect(),
            memo: lines
                .into_iter()
                .zip(plan.lines)
                .map(|(text, (show_ms, hide_ms))| MemoLine { text, show_ms, hide_ms })
                .collect(),
            voice,
            voice_at_ms: plan.voice_at_ms,
            voice_ms: plan.voice_ms,
        })
        .collect();

    let (from_s, to_s) = (iso(from), iso(to));
    let noun = if category == Some("drawing") { "絵" } else { "作品" };
    let title = presets
        .iter()
        .find(|p| p.from == from_s && p.to == to_s)
        .map(|p| if noun == "作品" { p.title.clone() } else { p.title.replace("作品", noun) })
        .unwrap_or_else(|| format!("えらんだ期間の{noun}"));

    Ok(Json(TheaterData {
        title,
        period_label: format!("{} — {}", date_short(from), date_short(to)),
        from: from_s,
        to: to_s,
        artwork_count: scenes.len(),
        truncated,
        transition_ms: TRANSITION_MS,
        outro_ms: OUTRO_MS,
        total_ms,
        duration_label: duration_label(total_ms),
        available: TheaterAvailable {
            first: all_dates.first().map(|d| iso(*d)),
            last: all_dates.last().map(|d| iso(*d)),
            today: iso(today),
            presets,
        },
        scenes,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }
    fn photo() -> MediaInfo {
        MediaInfo { video: false, duration_ms: None }
    }
    fn video(ms: Option<i32>) -> MediaInfo {
        MediaInfo { video: true, duration_ms: ms }
    }

    #[test]
    fn range_is_inclusive_and_keeps_order() {
        let dates = [d(2026, 3, 31), d(2026, 4, 1), d(2026, 6, 15), d(2026, 10, 31), d(2026, 11, 1)];
        assert_eq!(in_range(&dates, d(2026, 4, 1), d(2026, 10, 31)), (vec![1, 2, 3], false));
        assert_eq!(in_range(&dates, d(2027, 1, 1), d(2027, 12, 31)), (vec![], false));
        let many = vec![d(2026, 1, 1); MAX_SCENES + 5];
        let (picked, truncated) = in_range(&many, d(2026, 1, 1), d(2026, 1, 1));
        assert_eq!(picked.len(), MAX_SCENES);
        assert!(truncated);
    }

    #[test]
    fn memo_splits_into_sentences_and_wraps_long_ones() {
        assert!(memo_lines(" \n　").is_empty());
        assert_eq!(
            memo_lines("はじめての工作。「すごいでしょ！」って見せてくれた。\nまた作りたいね"),
            vec!["はじめての工作。", "「すごいでしょ！」って見せてくれた。", "また作りたいね"]
        );
        let long = format!("{}、{}。", "あ".repeat(30), "い".repeat(30));
        let lines = memo_lines(&long);
        assert_eq!(lines.len(), 2);
        assert!(lines[0].ends_with('、'));
        assert!(lines.iter().all(|l| l.chars().count() <= LINE_MAX_CHARS));
        // 区切りが無い長い文も切る
        assert!(memo_lines(&"う".repeat(100)).iter().all(|l| l.chars().count() <= LINE_MAX_CHARS));
        let many = "a。".repeat(20);
        let capped = memo_lines(&many);
        assert_eq!(capped.len(), MAX_MEMO_LINES);
        assert!(capped.last().unwrap().ends_with('…'));
    }

    #[test]
    fn artwork_only_scene_is_short() {
        let plan = plan_scene(&[], &[], None);
        assert_eq!(plan.hold_ms, BASE_HOLD_MS);
        assert!(plan.slots.is_empty() && plan.lines.is_empty());
        assert_eq!(plan.voice_ms, 0);
    }

    #[test]
    fn memo_lines_follow_each_other_and_last_stays_until_the_end() {
        let lines = memo_lines("大きな船を作ったよ。ダンボールを三つも使った。");
        let plan = plan_scene(&[photo()], &lines, None);
        assert_eq!(plan.lines.len(), 2);
        assert_eq!(plan.lines[0].0, MEMO_AT_MS);
        assert_eq!(plan.lines[1].0, plan.lines[0].1);
        assert_eq!(plan.lines[1].1, plan.hold_ms - SCENE_TAIL_MS);
        assert!(plan.hold_ms >= MEDIA_HOLD_MS);
    }

    #[test]
    fn media_alternate_sides_and_rotate_in_pairs() {
        let plan = plan_scene(&[photo(), photo(), photo()], &[], None);
        let sides: Vec<Side> = plan.slots.iter().map(|s| s.0).collect();
        assert_eq!(sides, vec![Side::Left, Side::Right, Side::Left]);
        // 1 回目の 2 枚は同時に出て、2 回目が始まるときに消える
        assert_eq!(plan.slots[0].1, MEDIA_AT_MS);
        assert_eq!(plan.slots[0].2, MEDIA_AT_MS + PHOTO_ROUND_MS);
        assert_eq!(plan.slots[2].1, MEDIA_AT_MS + PHOTO_ROUND_MS);
        // 最後の回は場面の終わりまで
        assert_eq!(plan.slots[2].2, plan.hold_ms - SCENE_TAIL_MS);
        assert!(plan.hold_ms >= MEDIA_AT_MS + 2 * PHOTO_ROUND_MS + SCENE_TAIL_MS);
        // 6 件より多い分は使わない
        assert_eq!(plan_scene(&[photo(); 9], &[], None).slots.len(), MAX_MEDIA);
    }

    #[test]
    fn videos_stretch_the_scene_but_are_capped() {
        let plan = plan_scene(&[video(Some(9000)), photo()], &[], None);
        assert_eq!(plan.slots[0].3, Some(9000));
        assert_eq!(plan.slots[1].3, None);
        assert_eq!(plan.hold_ms, MEDIA_AT_MS + 9000 + SCENE_TAIL_MS);
        let long = plan_scene(&[video(Some(60_000))], &[], None);
        assert_eq!(long.slots[0].3, Some(VIDEO_MAX_MS));
        let unknown = plan_scene(&[video(None)], &[], None);
        assert_eq!(unknown.slots[0].3, Some(VIDEO_UNKNOWN_MS));
    }

    #[test]
    fn voice_gets_listening_time() {
        let plan = plan_scene(&[], &[], Some(Some(10_000)));
        assert_eq!(plan.voice_ms, 10_000);
        assert!(plan.hold_ms >= plan.voice_at_ms + 10_000 + SCENE_TAIL_MS);
        assert_eq!(plan_scene(&[], &[], Some(None)).voice_ms, VOICE_UNKNOWN_MS);
        assert_eq!(plan_scene(&[], &[], Some(Some(90_000))).voice_ms, VOICE_MAX_MS);
    }

    #[test]
    fn timeline_chains_transitions_and_holds() {
        let (times, total) = layout_timeline(&[5000, 7000]);
        assert_eq!(times, vec![(0, TRANSITION_MS), (TRANSITION_MS + 5000, 2 * TRANSITION_MS + 5000)]);
        assert_eq!(total, 2 * TRANSITION_MS + 12_000 + OUTRO_MS);
        assert_eq!(layout_timeline(&[]), (vec![], 0));
    }

    #[test]
    fn presets_cover_all_and_each_age() {
        let today = d(2026, 11, 5);
        let birthday = d(2021, 6, 1);
        let dates = [d(2024, 9, 1), d(2025, 7, 1), d(2026, 2, 1)];
        let p = presets(&dates, today, Some(birthday));
        let keys: Vec<&str> = p.iter().map(|x| x.key.as_str()).collect();
        assert_eq!(keys, vec!["all", "age3", "age4"]);
        assert_eq!((p[0].from.as_str(), p[0].to.as_str()), ("2024-09-01", "2026-11-05"));
        assert_eq!((p[1].from.as_str(), p[1].to.as_str()), ("2024-06-01", "2025-05-31"));
        assert_eq!((p[2].from.as_str(), p[2].to.as_str()), ("2025-06-01", "2026-05-31"));
        // 今の年齢の期間は今日まで
        let now = presets(&[d(2026, 7, 1)], today, Some(birthday));
        assert_eq!((now[1].label.as_str(), now[1].to.as_str()), ("5さい", "2026-11-05"));
        let leap = presets(&[d(2025, 3, 2)], today, Some(d(2020, 2, 29)));
        assert_eq!((leap[1].from.as_str(), leap[1].to.as_str()), ("2025-03-01", "2026-02-28"));
        // 誕生日が無ければ「これまで」だけ
        assert_eq!(presets(&dates, today, None).len(), 1);
    }

    #[test]
    fn durations_read_naturally() {
        assert_eq!(duration_label(42_100), "約43秒");
        assert_eq!(duration_label(120_000), "約2分");
        assert_eq!(duration_label(95_000), "約1分35秒");
    }
}
