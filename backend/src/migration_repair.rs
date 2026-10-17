//! 改行コード (CRLF / LF) の違いだけでずれたマイグレーションの記録を直す。
//!
//! sqlx は適用したファイルのチェックサム (SHA-384) を `_sqlx_migrations` に記録する。
//! Windows (CRLF) と Mac (LF) で同じデータベースを使うと、内容が同じでもチェックサムが合わず
//! `VersionMismatch` で起動できなくなるので、`sqlx::migrate!` を実行する前にここで記録を合わせる。

use sha2::{Digest, Sha384};
use sqlx::{migrate::Migrator, PgPool};

pub async fn repair_line_endings(pool: &PgPool, migrator: &Migrator) -> Result<(), sqlx::Error> {
    // 初回起動 (表がまだ無い) なら直すものは無い
    let exists: bool = sqlx::query_scalar("SELECT to_regclass('_sqlx_migrations') IS NOT NULL")
        .fetch_one(pool)
        .await?;
    if !exists {
        return Ok(());
    }

    let applied: Vec<(i64, Vec<u8>)> =
        sqlx::query_as("SELECT version, checksum FROM _sqlx_migrations")
            .fetch_all(pool)
            .await?;

    for (version, recorded) in applied {
        let Some(migration) = migrator
            .iter()
            .find(|m| m.version == version && m.migration_type.is_up_migration())
        else {
            continue;
        };
        if recorded.as_slice() == migration.checksum.as_ref() {
            continue;
        }

        // 改行コードだけを変えた版のどちらかと一致するときだけ直す (中身が違うときは触らない)
        let lf = migration.sql.replace("\r\n", "\n");
        let crlf = lf.replace('\n', "\r\n");
        let only_line_endings = [lf, crlf]
            .iter()
            .any(|sql| Sha384::digest(sql.as_bytes()).as_slice() == recorded.as_slice());
        if !only_line_endings {
            continue;
        }

        sqlx::query("UPDATE _sqlx_migrations SET checksum = $1 WHERE version = $2")
            .bind(migration.checksum.as_ref())
            .bind(version)
            .execute(pool)
            .await?;
        println!("[DB] Migration {version}: 改行コードの違いによるチェックサムのずれを直しました");
    }

    Ok(())
}
