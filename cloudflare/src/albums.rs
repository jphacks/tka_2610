//! アルバム API (⑧ 作品一覧の上の棚・アルバムの画面・⑥ 作品の詳細の「アルバムに入れる」)
//!
//! 作品を自分で好きなグループにまとめる。1 つの作品をいくつのアルバムにも入れられる。
//! お気に入り (artworks.favorite) は表を持たない、最初からあるアルバム (id "favorites") として先頭に並べる。
//! 名前を変えたり消したりはできず、作品を入れる・外すとお気に入りの印が付く・外れる。

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    db::{uuid_list, Db},
    error::{AppError, AppResult},
    now_sql, params,
    state::{media_url, AppState, MediaKind},
};

/// お気に入りのアルバムの id
pub const FAVORITES: &str = "favorites";
const FAVORITES_NAME: &str = "お気に入り";
/// アルバムの名前の長さ (文字数)
const NAME_MAX: usize = 30;

/// どのアルバムか。URL の id ("favorites" か UUID) から決める
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlbumRef {
    Favorites,
    Album(Uuid),
}

impl AlbumRef {
    pub fn parse(id: &str) -> AppResult<Self> {
        if id == FAVORITES {
            return Ok(AlbumRef::Favorites);
        }
        Uuid::parse_str(id).map(AlbumRef::Album).map_err(|_| not_found())
    }
}

fn not_found() -> AppError {
    AppError::not_found("アルバムが見つかりません")
}

/// 名前の前後の空白を落とし、1〜30 文字かを確かめる
fn album_name(name: &str) -> AppResult<String> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > NAME_MAX {
        return Err(AppError::bad_request(format!("アルバムの名前は1〜{NAME_MAX}文字で入力してください")));
    }
    Ok(name.to_string())
}

#[derive(Serialize)]
pub struct AlbumDto {
    /// UUID か "favorites"
    pub id: String,
    pub name: String,
    /// 入っている作品の数
    pub count: i64,
    /// 表紙 (いちばん新しく作った作品のサムネイル)。空のアルバムは None
    pub cover_url: Option<String>,
    pub cover_tint: Option<String>,
    /// お気に入り (名前を変えたり消したりできない)
    pub built_in: bool,
    /// ?artwork= で聞いたときだけ: その作品が入っているか
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contains: Option<bool>,
}

#[derive(Deserialize)]
struct AlbumRow {
    id: Uuid,
    name: String,
    count: i64,
    thumb_file: Option<String>,
    tint: Option<String>,
    #[serde(deserialize_with = "crate::db::flag")]
    contains: bool,
}

#[derive(Deserialize)]
struct FavoritesRow {
    count: i64,
    thumb_file: Option<String>,
    tint: Option<String>,
    #[serde(deserialize_with = "crate::db::flag")]
    contains: bool,
}

impl AlbumDto {
    fn new(id: String, name: String, count: i64, thumb_file: Option<String>, tint: Option<String>, built_in: bool) -> Self {
        AlbumDto {
            id,
            name,
            count,
            cover_url: thumb_file.map(|f| media_url(MediaKind::Thumb, &f)),
            cover_tint: tint,
            built_in,
            contains: None,
        }
    }
}

/// 作ったアルバム (新しく作った順)。artwork を渡すと contains にその作品が入っているかを入れる
fn load_albums(db: &Db, only: Option<Uuid>, artwork: Option<Uuid>) -> AppResult<Vec<AlbumDto>> {
    // 表紙 (いちばん新しく作った作品) は、backend の LATERAL の代わりに相関サブクエリで読む
    const COVER: &str = "FROM album_artworks x JOIN artworks w ON w.id = x.artwork_id \
        WHERE x.album_id = a.id ORDER BY w.made_on DESC, w.created_at DESC, w.id DESC LIMIT 1";
    let rows = db.all::<AlbumRow>(
        &format!(
            "SELECT a.id, a.name, \
                (SELECT COUNT(*) FROM album_artworks x WHERE x.album_id = a.id) AS count, \
                (SELECT w.thumb_file {COVER}) AS thumb_file, \
                (SELECT w.tint {COVER}) AS tint, \
                EXISTS (SELECT 1 FROM album_artworks x WHERE x.album_id = a.id AND x.artwork_id = ?2) AS contains \
             FROM albums a \
             WHERE (?1 IS NULL OR a.id = ?1) \
             ORDER BY a.created_at DESC"
        ),
        params![only, artwork],
    )?;
    Ok(rows
        .into_iter()
        .map(|r| AlbumDto {
            contains: artwork.map(|_| r.contains),
            ..AlbumDto::new(r.id.to_string(), r.name, r.count, r.thumb_file, r.tint, false)
        })
        .collect())
}

/// お気に入りのアルバム
fn load_favorites(db: &Db, artwork: Option<Uuid>) -> AppResult<AlbumDto> {
    const COVER: &str = "FROM artworks WHERE favorite ORDER BY made_on DESC, created_at DESC, id DESC LIMIT 1";
    let row = db.one::<FavoritesRow>(
        &format!(
            "SELECT (SELECT COUNT(*) FROM artworks WHERE favorite) AS count, \
                (SELECT thumb_file {COVER}) AS thumb_file, \
                (SELECT tint {COVER}) AS tint, \
                EXISTS (SELECT 1 FROM artworks WHERE id = ?1 AND favorite) AS contains"
        ),
        params![artwork],
    )?;
    Ok(AlbumDto {
        contains: artwork.map(|_| row.contains),
        ..AlbumDto::new(FAVORITES.into(), FAVORITES_NAME.into(), row.count, row.thumb_file, row.tint, true)
    })
}

fn load_one(db: &Db, album: AlbumRef) -> AppResult<AlbumDto> {
    match album {
        AlbumRef::Favorites => load_favorites(db, None),
        AlbumRef::Album(id) => load_albums(db, Some(id), None)?.into_iter().next().ok_or_else(not_found),
    }
}

// =============================
// 一覧・1 つ
// =============================

#[derive(Deserialize)]
pub struct AlbumsQuery {
    /// 渡すと、各アルバムにその作品が入っているか (contains) を付ける (⑥ の「アルバムに入れる」)
    pub artwork: Option<Uuid>,
}

#[derive(Serialize)]
pub struct AlbumList {
    /// 先頭はお気に入り、そのあとは新しく作った順
    pub items: Vec<AlbumDto>,
}

/// GET /api/albums
pub async fn list_albums(State(state): State<AppState>, Query(query): Query<AlbumsQuery>) -> AppResult<Json<AlbumList>> {
    let favorites = load_favorites(&state.db, query.artwork)?;
    let albums = load_albums(&state.db, None, query.artwork)?;
    let mut items = Vec::with_capacity(albums.len() + 1);
    items.push(favorites);
    items.extend(albums);
    Ok(Json(AlbumList { items }))
}

/// GET /api/albums/{id}
pub async fn get_album(State(state): State<AppState>, Path(id): Path<String>) -> AppResult<Json<AlbumDto>> {
    Ok(Json(load_one(&state.db, AlbumRef::parse(&id)?)?))
}

// =============================
// 作る・名前を変える・消す
// =============================

#[derive(Deserialize)]
pub struct CreateBody {
    pub name: String,
    /// 作ると同時に入れる作品 (⑥ から作ったとき)
    #[serde(default)]
    pub artwork_ids: Vec<Uuid>,
}

/// POST /api/albums
pub async fn create_album(State(state): State<AppState>, Json(body): Json<CreateBody>) -> AppResult<(StatusCode, Json<AlbumDto>)> {
    let name = album_name(&body.name)?;
    let id = Uuid::new_v4();
    let db = &state.db;
    db.tx(|| {
        db.exec("INSERT INTO albums (id, name) VALUES (?1, ?2)", params![id, name])?;
        add_artworks(db, id, &body.artwork_ids)
    })?;
    Ok((StatusCode::CREATED, Json(load_one(db, AlbumRef::Album(id))?)))
}

#[derive(Deserialize)]
pub struct UpdateBody {
    pub name: String,
}

/// PATCH /api/albums/{id}
pub async fn update_album(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<UpdateBody>,
) -> AppResult<Json<AlbumDto>> {
    let AlbumRef::Album(id) = AlbumRef::parse(&id)? else {
        return Err(AppError::bad_request("お気に入りの名前は変えられません"));
    };
    let name = album_name(&body.name)?;
    let updated = state.db.exec(
        concat!("UPDATE albums SET name = ?2, updated_at = ", now_sql!(), " WHERE id = ?1"),
        params![id, name],
    )?;
    if updated == 0 {
        return Err(not_found());
    }
    Ok(Json(load_one(&state.db, AlbumRef::Album(id))?))
}

/// DELETE /api/albums/{id}。入っていた作品はそのまま残る
pub async fn delete_album(State(state): State<AppState>, Path(id): Path<String>) -> AppResult<StatusCode> {
    let AlbumRef::Album(id) = AlbumRef::parse(&id)? else {
        return Err(AppError::bad_request("お気に入りは消せません"));
    };
    let deleted = state.db.exec("DELETE FROM albums WHERE id = ?1", params![id])?;
    if deleted == 0 {
        return Err(not_found());
    }
    Ok(StatusCode::NO_CONTENT)
}

// =============================
// 作品を入れる・外す
// =============================

#[derive(Deserialize)]
pub struct ArtworksBody {
    #[serde(default)]
    pub add: Vec<Uuid>,
    #[serde(default)]
    pub remove: Vec<Uuid>,
}

/// 無い作品の id は無視する。もう入っている作品はそのまま
fn add_artworks(db: &Db, album: Uuid, ids: &[Uuid]) -> AppResult<()> {
    db.exec(
        "INSERT INTO album_artworks (album_id, artwork_id) \
         SELECT ?1, id FROM artworks WHERE id IN (SELECT value FROM json_each(?2)) \
         ON CONFLICT DO NOTHING",
        params![album, uuid_list(ids)],
    )?;
    Ok(())
}

/// PUT /api/albums/{id}/artworks。お気に入りなら、お気に入りの印を付ける・外す
pub async fn update_artworks(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<ArtworksBody>,
) -> AppResult<Json<AlbumDto>> {
    let album = AlbumRef::parse(&id)?;
    // 同じ作品を入れて外すときは、入れるほうを優先する
    let remove: Vec<Uuid> = body.remove.iter().copied().filter(|id| !body.add.contains(id)).collect();
    let db = &state.db;
    db.tx(|| {
        match album {
            AlbumRef::Favorites => {
                db.exec(
                    "UPDATE artworks SET favorite = 1 WHERE id IN (SELECT value FROM json_each(?1)) AND NOT favorite",
                    params![uuid_list(&body.add)],
                )?;
                db.exec(
                    "UPDATE artworks SET favorite = 0 WHERE id IN (SELECT value FROM json_each(?1)) AND favorite",
                    params![uuid_list(&remove)],
                )?;
            }
            AlbumRef::Album(id) => {
                let touched =
                    db.exec(concat!("UPDATE albums SET updated_at = ", now_sql!(), " WHERE id = ?1"), params![id])?;
                if touched == 0 {
                    return Err(not_found());
                }
                add_artworks(db, id, &body.add)?;
                db.exec(
                    "DELETE FROM album_artworks WHERE album_id = ?1 AND artwork_id IN (SELECT value FROM json_each(?2))",
                    params![id, uuid_list(&remove)],
                )?;
            }
        }
        Ok(())
    })?;
    Ok(Json(load_one(db, album)?))
}

/// 作品一覧 (GET /api/artworks?album=) の絞り込み。(お気に入りだけか, このアルバムの作品だけか)
pub fn list_filter(album: Option<&str>) -> AppResult<(Option<bool>, Option<Uuid>)> {
    match album.map(AlbumRef::parse).transpose()? {
        None => Ok((None, None)),
        Some(AlbumRef::Favorites) => Ok((Some(true), None)),
        Some(AlbumRef::Album(id)) => Ok((None, Some(id))),
    }
}
