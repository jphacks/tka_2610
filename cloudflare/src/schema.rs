//! Durable Object の SQLite の表。backend のマイグレーション 001〜017 を当てたあとの形と同じ
//! (Unity 用の exhibits と、おへやに分ける前の home_layout は使わないので作らない)。
//!
//! 表を変えるときは、SCHEMA の文を書き換えずに MIGRATIONS に足す (版は meta の schema_version)。

use crate::{error::AppResult, params, db::Db};

/// 最初に作る表 (版 1)
const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS museum_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    museum_name TEXT NOT NULL,
    owner_name TEXT NOT NULL,
    child_birthday TEXT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS house_rooms (
    id TEXT PRIMARY KEY,
    age INTEGER NOT NULL CHECK (age >= 0 AND age <= 120),
    floor INTEGER NOT NULL CHECK (floor >= 0),
    layout TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE (age, floor)
);

CREATE TABLE IF NOT EXISTS artworks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    child_name TEXT NOT NULL DEFAULT '',
    age INTEGER,
    made_on TEXT NOT NULL,
    memo TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'drawing' CHECK (category IN ('drawing', 'craft', 'photo', 'other')),
    image_file TEXT NOT NULL,
    thumb_file TEXT NOT NULL,
    model_file TEXT NOT NULL,
    model_kind TEXT NOT NULL CHECK (model_kind IN ('frame', 'stand', 'custom')),
    image_width INTEGER NOT NULL,
    image_height INTEGER NOT NULL,
    tint TEXT NOT NULL DEFAULT '#f3e7da',
    favorite INTEGER NOT NULL DEFAULT 0,
    slot_id TEXT UNIQUE,
    displayed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    catalog_no INTEGER NOT NULL,
    model_width REAL,
    model_height REAL,
    model_depth REAL,
    house_room_id TEXT REFERENCES house_rooms (id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS artworks_category_made_on_idx ON artworks (category, made_on DESC);
CREATE INDEX IF NOT EXISTS artworks_created_at_idx ON artworks (created_at DESC);
CREATE INDEX IF NOT EXISTS artworks_house_room_id_idx ON artworks (house_room_id);

CREATE TABLE IF NOT EXISTS artwork_memories (
    id TEXT PRIMARY KEY,
    artwork_id TEXT NOT NULL REFERENCES artworks (id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('photo', 'video', 'audio')),
    file TEXT NOT NULL,
    thumb_file TEXT,
    mime TEXT NOT NULL,
    bytes INTEGER NOT NULL,
    duration_ms INTEGER,
    width INTEGER,
    height INTEGER,
    caption TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS artwork_memories_artwork_idx ON artwork_memories (artwork_id, created_at);

CREATE TABLE IF NOT EXISTS albums (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS album_artworks (
    album_id TEXT NOT NULL REFERENCES albums (id) ON DELETE CASCADE,
    artwork_id TEXT NOT NULL REFERENCES artworks (id) ON DELETE CASCADE,
    added_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (album_id, artwork_id)
);
CREATE INDEX IF NOT EXISTS album_artworks_artwork_idx ON album_artworks (artwork_id);

-- 写真・GLB・おもいでのファイル (backend の media フォルダの代わり)。path は "images/<ファイル名>" の形。
-- 中身は CHUNK ごとに media_chunks に分けて入れる (1 行の大きさの上限があるため)
CREATE TABLE IF NOT EXISTS media_files (
    path TEXT PRIMARY KEY,
    mime TEXT NOT NULL,
    size INTEGER NOT NULL,
    chunk_size INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE TABLE IF NOT EXISTS media_chunks (
    path TEXT NOT NULL REFERENCES media_files (path) ON DELETE CASCADE,
    idx INTEGER NOT NULL,
    data BLOB NOT NULL,
    PRIMARY KEY (path, idx)
);
"#;

/// 版 2 から先の変更 (版, 文)。
const MIGRATIONS: &[(i64, &str)] = &[(2, r#"
CREATE TABLE IF NOT EXISTS all_home_layout (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    state TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
"#)];

/// 表を用意して、最初の設定の行を入れる (backend の 002・010 と同じ値)
pub fn migrate(db: &Db) -> AppResult<()> {
    db.batch(SCHEMA)?;
    let version: i64 = db
        .scalar::<String>("SELECT value FROM meta WHERE key = 'schema_version'", params![])?
        .and_then(|v| v.parse().ok())
        .unwrap_or(1);
    for (to, sql) in MIGRATIONS.iter().filter(|(v, _)| *v > version) {
        db.batch(sql)?;
        db.exec(
            "INSERT INTO meta (key, value) VALUES ('schema_version', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            params![to.to_string()],
        )?;
    }
    db.exec(
        "INSERT INTO meta (key, value) VALUES ('schema_version', '1') ON CONFLICT (key) DO NOTHING",
        params![],
    )?;
    // 送っている途中で切れたおもいでのファイル (size = -1。読まれない) を消す (backend の起動時の孤児ファイルの掃除の代わり)
    db.exec("DELETE FROM media_chunks WHERE path IN (SELECT path FROM media_files WHERE size < 0)", params![])?;
    db.exec("DELETE FROM media_files WHERE size < 0", params![])?;
    db.exec(
        "INSERT INTO museum_settings (id, museum_name, owner_name, child_birthday) \
         VALUES (1, 'はるのミュージアム', 'はると', '2021-06-01') ON CONFLICT (id) DO NOTHING",
        params![],
    )?;
    Ok(())
}

/// 次の目録番号 (backend の catalog_no の SEQUENCE と同じく、作品を消しても番号は戻さない)
pub fn next_catalog_no(db: &Db) -> AppResult<i64> {
    db.exec(
        "INSERT INTO meta (key, value) \
         VALUES ('catalog_no', (SELECT COALESCE(MAX(catalog_no), 0) + 1 FROM artworks)) \
         ON CONFLICT (key) DO UPDATE SET value = CAST(value AS INTEGER) + 1",
        params![],
    )?;
    Ok(db
        .scalar::<String>("SELECT value FROM meta WHERE key = 'catalog_no'", params![])?
        .and_then(|v| v.parse().ok())
        .unwrap_or(1))
}
