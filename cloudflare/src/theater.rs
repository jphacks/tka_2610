//! 期間をえらんで振り返る、3D のダイジェスト・シアター。
//!
//! 期間 (作品を作った日 `made_on`) の作品を古い順に全部ならべ、作品ごとの場面の時間割を作る。
//! `digest` を付けると、年齢ごとにランダムで 2 点ずつだけをえらんで、古い順にならべる (ダイジェスト)。
//! Web は再生位置の時刻 1 本から、どの場面か・大地の回転・写真や動画・メモ・声を決めるので、
//! 時刻はすべてここで決める。おもいで (写真・動画・声) は追加した日にかかわらず作品と一緒に出す。
use axum::{
    extract::{Query, State},
    Json,
};
use chrono::{Datelike, NaiveDate};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    age,
    artworks::{date_short, ArtworkDto, ArtworkRow, DtoContext, COLUMNS},
    error::{AppError, AppResult},
    memories::{self, MemoryDto},
    museum, params,
    state::{today, AppState},
};

/// 1 回のシアターに出す作品の上限 (これより多いと truncated)
const MAX_SCENES: usize = 200;
/// ダイジェストで、年齢 (誕生日が無ければ年) ごとにえらぶ作品の数
const DIGEST_PER_AGE: usize = 2;
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
    /// ダイジェストにする (年齢ごとにランダムで 2 点)。値は、えらび方の種。同じ種なら同じ作品になる
    digest: Option<u32>,
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
    /// ダイジェストのときの種 (ふつうは None)
    digest: Option<u32>,
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

/// ダイジェストのくじ。種と作品の id から決まる数 (小さいほど先にえらばれる)
fn lot(seed: u32, id: &Uuid) -> u64 {
    // FNV-1a で id を混ぜ、splitmix64 で散らす (乱数の箱を持たずに、同じ種なら何度でも同じ結果にする)
    let mut h: u64 = 0xcbf2_9ce4_8422_2325 ^ u64::from(seed);
    for b in id.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h = h.wrapping_add(0x9e37_79b9_7f4a_7c15);
    h = (h ^ (h >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    h = (h ^ (h >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    h ^ (h >> 31)
}

/// ダイジェストにえらぶ作品の添え字。dates・ids は古い順。
/// 年齢 (誕生日が無ければ作った年) ごとに、くじで DIGEST_PER_AGE 点ずつえらび、古い順のまま返す
pub fn digest_picks(dates: &[NaiveDate], ids: &[Uuid], birthday: Option<NaiveDate>, seed: u32) -> Vec<usize> {
    let group = |d: NaiveDate| match birthday {
        Some(b) => i32::from(age::age_on(b, d)),
        None => d.year(),
    };
    let mut picked = Vec::new();
    let mut start = 0;
    while start < dates.len() {
        // 古い順なので、同じ年齢の作品は続いて並ぶ
        let key = group(dates[start]);
        let end = start + dates[start..].iter().take_while(|d| group(**d) == key).count();
        let mut members: Vec<usize> = (start..end).collect();
        members.sort_by_key(|&i| (lot(seed, &ids[i]), i));
        members.truncate(DIGEST_PER_AGE);
        picked.extend(members);
        start = end;
    }
    picked.sort_unstable();
    picked
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

/// GET /api/recollections/theater?from=YYYY-MM-DD&to=YYYY-MM-DD[&category=drawing][&digest=種]
pub async fn theater(
    State(state): State<AppState>,
    Query(query): Query<TheaterQuery>,
) -> AppResult<Json<TheaterData>> {
    let category = query.category.as_deref().filter(|c| *c != "all" && !c.is_empty());
    if category.is_some_and(|c| !museum::CATEGORIES.contains(&c)) {
        return Err(AppError::bad_request("作品の種類を確認してください"));
    }
    let db = &state.db;
    let today = today();
    let from = query.from.as_deref().filter(|s| !s.trim().is_empty()).map(parse_date).transpose()?;
    let to = query.to.as_deref().filter(|s| !s.trim().is_empty()).map(parse_date).transpose()?;
    if let (Some(f), Some(t)) = (from, to)
        && f > t
    {
        return Err(AppError::bad_request("はじまりの日は、おわりの日より前にしてください"));
    }

    // 期間をえらぶボタンは、種類で絞らない全部の作品から作る
    let all_dates: Vec<NaiveDate> = db
        .tuples::<(NaiveDate,)>(
            "SELECT made_on FROM artworks WHERE made_on <= ?1 AND id <> ?2 ORDER BY made_on ASC",
            params![today, crate::recollections::hidden_artwork_id()],
        )?
        .into_iter()
        .map(|(d,)| d)
        .collect();
    let ctx = DtoContext::load(db)?;
    let presets = presets(&all_dates, today, ctx.birthday);

    let to = to.unwrap_or(today).min(today);
    let from = from.unwrap_or_else(|| all_dates.first().copied().unwrap_or(today));

    let rows = db.all::<ArtworkRow>(
        &format!(
            "SELECT {COLUMNS} FROM artworks WHERE made_on >= ?1 AND made_on <= ?2 AND (?3 IS NULL OR category = ?3) AND id <> ?4 ORDER BY made_on ASC, created_at ASC, id"
        ),
        params![from, to, category, crate::recollections::hidden_artwork_id()],
    )?;
    let dates: Vec<NaiveDate> = rows.iter().map(|r| r.made_on).collect();
    let (indices, truncated) = match query.digest {
        Some(seed) => {
            let ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
            let picks = digest_picks(&dates, &ids, ctx.birthday, seed);
            let truncated = picks.len() > MAX_SCENES;
            (picks.into_iter().take(MAX_SCENES).collect(), truncated)
        }
        None => in_range(&dates, from, to),
    };

    let ids: Vec<Uuid> = indices.iter().map(|&i| rows[i].id).collect();
    let mut memories = memories::of_artworks(db, &ids)?;

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
    let title = if query.digest.is_some() {
        let unit = if ctx.birthday.is_some() { "年齢" } else { "年" };
        if noun == "作品" { format!("{unit}ごとのダイジェスト") } else { format!("{unit}ごとの{noun}のダイジェスト") }
    } else {
        presets
            .iter()
            .find(|p| p.from == from_s && p.to == to_s)
            .map(|p| if noun == "作品" { p.title.clone() } else { p.title.replace("作品", noun) })
            .unwrap_or_else(|| format!("えらんだ期間の{noun}"))
    };

    Ok(Json(TheaterData {
        title,
        period_label: format!("{} — {}", date_short(from), date_short(to)),
        from: from_s,
        to: to_s,
        digest: query.digest,
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
