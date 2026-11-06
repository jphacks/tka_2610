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
use sqlx::{FromRow, PgPool};
use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
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

#[derive(FromRow)]
struct AlbumRow {
    id: Uuid,
    name: String,
    count: i64,
    thumb_file: Option<String>,
    tint: Option<String>,
    contains: bool,
}

#[derive(FromRow)]
struct FavoritesRow {
    count: i64,
    thumb_file: Option<String>,
    tint: Option<String>,
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
async fn load_albums(pool: &PgPool, only: Option<Uuid>, artwork: Option<Uuid>) -> AppResult<Vec<AlbumDto>> {
    let rows = sqlx::query_as::<_, AlbumRow>(
        "SELECT a.id, a.name, \
            (SELECT COUNT(*) FROM album_artworks x WHERE x.album_id = a.id) AS count, \
            cover.thumb_file, cover.tint, \
            EXISTS (SELECT 1 FROM album_artworks x WHERE x.album_id = a.id AND x.artwork_id = $2) AS contains \
         FROM albums a \
         LEFT JOIN LATERAL ( \
            SELECT w.thumb_file, w.tint FROM album_artworks x JOIN artworks w ON w.id = x.artwork_id \
            WHERE x.album_id = a.id ORDER BY w.made_on DESC, w.created_at DESC LIMIT 1 \
         ) cover ON TRUE \
         WHERE ($1::uuid IS NULL OR a.id = $1) \
         ORDER BY a.created_at DESC",
    )
    .bind(only)
    .bind(artwork)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| AlbumDto {
            contains: artwork.map(|_| r.contains),
            ..AlbumDto::new(r.id.to_string(), r.name, r.count, r.thumb_file, r.tint, false)
        })
        .collect())
}

/// お気に入りのアルバム
async fn load_favorites(pool: &PgPool, artwork: Option<Uuid>) -> AppResult<AlbumDto> {
    let row = sqlx::query_as::<_, FavoritesRow>(
        "SELECT (SELECT COUNT(*) FROM artworks WHERE favorite) AS count, \
            cover.thumb_file, cover.tint, \
            EXISTS (SELECT 1 FROM artworks WHERE id = $1 AND favorite) AS contains \
         FROM (SELECT 1) one \
         LEFT JOIN LATERAL ( \
            SELECT thumb_file, tint FROM artworks WHERE favorite ORDER BY made_on DESC, created_at DESC LIMIT 1 \
         ) cover ON TRUE",
    )
    .bind(artwork)
    .fetch_one(pool)
    .await?;
    Ok(AlbumDto {
        contains: artwork.map(|_| row.contains),
        ..AlbumDto::new(FAVORITES.into(), FAVORITES_NAME.into(), row.count, row.thumb_file, row.tint, true)
    })
}

async fn load_one(pool: &PgPool, album: AlbumRef) -> AppResult<AlbumDto> {
    match album {
        AlbumRef::Favorites => load_favorites(pool, None).await,
        AlbumRef::Album(id) => load_albums(pool, Some(id), None).await?.into_iter().next().ok_or_else(not_found),
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
    let (favorites, albums) = tokio::try_join!(
        load_favorites(&state.pool, query.artwork),
        load_albums(&state.pool, None, query.artwork)
    )?;
    let mut items = Vec::with_capacity(albums.len() + 1);
    items.push(favorites);
    items.extend(albums);
    Ok(Json(AlbumList { items }))
}

/// GET /api/albums/{id}
pub async fn get_album(State(state): State<AppState>, Path(id): Path<String>) -> AppResult<Json<AlbumDto>> {
    Ok(Json(load_one(&state.pool, AlbumRef::parse(&id)?).await?))
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
    let mut tx = state.pool.begin().await?;
    sqlx::query("INSERT INTO albums (id, name) VALUES ($1, $2)")
        .bind(id)
        .bind(&name)
        .execute(&mut *tx)
        .await?;
    add_artworks(&mut *tx, id, &body.artwork_ids).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(load_one(&state.pool, AlbumRef::Album(id)).await?)))
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
    let updated = sqlx::query("UPDATE albums SET name = $2, updated_at = NOW() WHERE id = $1")
        .bind(id)
        .bind(&name)
        .execute(&state.pool)
        .await?;
    if updated.rows_affected() == 0 {
        return Err(not_found());
    }
    Ok(Json(load_one(&state.pool, AlbumRef::Album(id)).await?))
}

/// DELETE /api/albums/{id}。入っていた作品はそのまま残る
pub async fn delete_album(State(state): State<AppState>, Path(id): Path<String>) -> AppResult<StatusCode> {
    let AlbumRef::Album(id) = AlbumRef::parse(&id)? else {
        return Err(AppError::bad_request("お気に入りは消せません"));
    };
    let deleted = sqlx::query("DELETE FROM albums WHERE id = $1").bind(id).execute(&state.pool).await?;
    if deleted.rows_affected() == 0 {
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
async fn add_artworks<'e>(db: impl sqlx::PgExecutor<'e>, album: Uuid, ids: &[Uuid]) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO album_artworks (album_id, artwork_id) \
         SELECT $1, id FROM artworks WHERE id = ANY($2) \
         ON CONFLICT DO NOTHING",
    )
    .bind(album)
    .bind(ids)
    .execute(db)
    .await?;
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
    let mut tx = state.pool.begin().await?;
    match album {
        AlbumRef::Favorites => {
            sqlx::query("UPDATE artworks SET favorite = TRUE WHERE id = ANY($1) AND NOT favorite")
                .bind(&body.add)
                .execute(&mut *tx)
                .await?;
            sqlx::query("UPDATE artworks SET favorite = FALSE WHERE id = ANY($1) AND favorite")
                .bind(&remove)
                .execute(&mut *tx)
                .await?;
        }
        AlbumRef::Album(id) => {
            let touched = sqlx::query("UPDATE albums SET updated_at = NOW() WHERE id = $1")
                .bind(id)
                .execute(&mut *tx)
                .await?;
            if touched.rows_affected() == 0 {
                return Err(not_found());
            }
            add_artworks(&mut *tx, id, &body.add).await?;
            sqlx::query("DELETE FROM album_artworks WHERE album_id = $1 AND artwork_id = ANY($2)")
                .bind(id)
                .bind(&remove)
                .execute(&mut *tx)
                .await?;
        }
    }
    tx.commit().await?;
    Ok(Json(load_one(&state.pool, album).await?))
}

/// 作品一覧 (GET /api/artworks?album=) の絞り込み。(お気に入りだけか, このアルバムの作品だけか)
pub fn list_filter(album: Option<&str>) -> AppResult<(Option<bool>, Option<Uuid>)> {
    match album.map(AlbumRef::parse).transpose()? {
        None => Ok((None, None)),
        Some(AlbumRef::Favorites) => Ok((Some(true), None)),
        Some(AlbumRef::Album(id)) => Ok((None, Some(id))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn album_names_are_trimmed_and_limited() {
        assert_eq!(album_name("  なつやすみ ").unwrap(), "なつやすみ");
        assert!(album_name(" \n　").is_err());
        assert_eq!(album_name(&"あ".repeat(NAME_MAX)).unwrap().chars().count(), NAME_MAX);
        assert!(album_name(&"あ".repeat(NAME_MAX + 1)).is_err());
    }

    #[test]
    fn album_ids_are_favorites_or_uuids() {
        let id = Uuid::new_v4();
        assert_eq!(AlbumRef::parse("favorites").unwrap(), AlbumRef::Favorites);
        assert_eq!(AlbumRef::parse(&id.to_string()).unwrap(), AlbumRef::Album(id));
        assert_eq!(AlbumRef::parse("summer").unwrap_err().status, StatusCode::NOT_FOUND);
    }

    #[test]
    fn list_filter_picks_favorites_or_one_album() {
        let id = Uuid::new_v4();
        assert_eq!(list_filter(None).unwrap(), (None, None));
        assert_eq!(list_filter(Some("favorites")).unwrap(), (Some(true), None));
        assert_eq!(list_filter(Some(&id.to_string())).unwrap(), (None, Some(id)));
        assert!(list_filter(Some("nope")).is_err());
    }
}
