# Supabase に移すときにやること

> [!NOTE]
> 2026年10月4日に、データベースの Supabase への移行（1〜3、4 は A）を行いました。
> プロジェクトは組織 kobadaidesu の `memory-museum`（Northeast Asia (Tokyo)、プロジェクト ID `srfcfowcgnvhwujpijuw`）です。
> このファイルは、データベースを Supabase に移すときの作業リストです。終わった項目にはチェックを入れてください。

## 今の構成（前提）

| 項目 | 今の状態 |
|---|---|
| データベース | `docker-compose.yml` の PostgreSQL 16。接続先は `.env` の `DATABASE_URL` |
| 表の作成 | サーバー起動時に、`backend/migrations/` の SQL を sqlx が自動で適用する |
| 画像・サムネイル・作品の GLB | サーバーを動かしている PC の `backend/data/media/` に保存。**データベースには入らない** |
| 博物館の GLB | `backend/static/models/sample.glb` を起動時に `backend/data/media/museum/` へコピーして配信 |
| Unity | Rust のサーバー（`/api/exhibits` と `/media/...`）にだけつなぐ。Supabase には直接つながない |

Supabase に移しても、Web と Unity の設定は変わりません。変わるのはサーバー（`backend/`）の接続先です。

## やること

### 1. Supabase のダッシュボード

- [x] プロジェクトを作る。リージョンは Northeast Asia（Tokyo）。データベースのパスワードを控える。
- [x] 画面上部の「Connect」から、**Session pooler** の接続文字列をコピーする。
  - Direct connection は IPv6 専用なので、家庭のネットワークからはつながらないことが多い。
  - **Transaction pooler（ポート 6543）は使わない。** sqlx は prepared statement を使うので、エラーになる。

### 2. サーバーのコード（`backend/`）

- [x] **暗号化通信（TLS）を有効にする（必須）。**
  `backend/Cargo.toml` の sqlx の `features` に `"tls-rustls"` を足す。
  今は TLS なしの設定なので、`sslmode=require` を付けた接続はできない。

- [x] **マイグレーションの改行コード対策（共有するなら必須）。**
  sqlx は、適用したマイグレーションファイルのチェックサム（SHA-384）をデータベースの `_sqlx_migrations` に記録する。
  あとでファイルの改行コードが変わる（Windows の CRLF と Mac の LF など）と、内容が同じでも `migration failed: VersionMismatch(番号)` で起動できなくなる。
  1 つのデータベースを複数人で使うと、最初に起動した人の改行コードで記録されるので、ほかの人が起動できなくなる。
  対策として、起動時に「改行コードの違いだけでずれている記録」を見つけたら、記録を今のファイルのチェックサムに直す処理を、`sqlx::migrate!` を実行する前に入れる。
  - `backend/src/migration_repair.rs` で実装済み。直したときは `[DB] Migration 番号: 改行コードの違いによるチェックサムのずれを直しました` と出る。
  - `.gitattributes` で SQL を LF に固定する方法は使わない。すでに Windows（CRLF）で起動した人のデータベースと食い違うため。

- [x] **RLS（Row Level Security）を有効にするマイグレーションを足す。**
  Supabase は `public` スキーマの表を自動で API として公開するので、RLS がオフだと、公開キーを知っている人が誰でも読み書きできる。
  サーバーは表の所有者として接続するので、RLS をオンにしてもサーバーの動作は変わらない（所有者は RLS の対象外）。
  `backend/migrations/004_enable_rls.sql` などの新しいファイルとして追加する。

  ```sql
  ALTER TABLE artworks ENABLE ROW LEVEL SECURITY;
  ALTER TABLE museum_settings ENABLE ROW LEVEL SECURITY;
  ALTER TABLE exhibits ENABLE ROW LEVEL SECURITY;
  ALTER TABLE _sqlx_migrations ENABLE ROW LEVEL SECURITY;
  ```

### 3. 設定（`.env`）

- [x] `DATABASE_URL` を Supabase の Session pooler に変える。パスワードに記号があるときは URL エンコードする。

  ```
  DATABASE_URL=postgresql://postgres.<プロジェクトID>:<パスワード>@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres?sslmode=require
  ```

- [x] `.env.example` にも、Supabase の接続文字列の形をコメントで足す（パスワードは書かない）。
- [x] `docker compose up -d db` は不要になる。README の起動手順も合わせて直す。

### 4. 画像と GLB をどう共有するか決める

データベースを Supabase にしても、画像と GLB は **サーバーを動かしている PC にしか保存されない。**
複数人がそれぞれ自分の PC でサーバーを動かして同じ Supabase につなぐと、作品の情報は全員に見えるが、ほかの人が登録した作品の画像と 3D は表示されない（404 になる）。
次のどちらかを選ぶ。

- [x] **A. サーバーは 1 台だけ動かす。** ほかの人の Web と Unity はそのサーバーにつなぐ（README の「別の PC のサーバーにつなぐとき」）。コードの変更は不要。
- [ ] **B. 画像と GLB を Supabase Storage に置く。** コードの変更が必要。主に触る場所は次のとおり。
  - `backend/src/artworks.rs` の `write_files` と `remove_files`：ローカル保存を Storage へのアップロード・削除に変える
  - `backend/src/state.rs` の `media_url`：Storage の公開 URL を返すようにする
  - `backend/src/museum_api.rs` の Unity 用の展示一覧：`model_url` を Storage の URL にする
  - `backend/src/main.rs` の `/media` の配信：Storage に移したものは不要になる
  - 博物館の GLB（`sample.glb`）も Storage に置くか、今のままサーバーから配信するかを決める

### 5. 動作確認

- [x] `cargo run` で `[DB] PostgreSQL connected` と `[DB] Migration completed` が出る
- [x] Supabase の Table Editor に `artworks` と `museum_settings` があり、RLS が有効になっている
- [ ] Web で作品を登録して「展示する」を押すと、Unity の展示台に並ぶ
- [ ] （共有する場合）別の PC からも同じ作品と画像が見える

## 注意

- 適用済みのマイグレーションファイル（`backend/migrations/` の既存ファイル）は **書き換えない。** 変更は新しい番号のファイルで足す。書き換えるとチェックサムが変わり、起動できなくなる。
- Supabase のパスワードや接続文字列は git に入れない（`.env` は `.gitignore` 済み）。
- サーバーは Postgres に直接つなぐので、Supabase の `anon` キーや `service_role` キーは今のところ使わない（B を選んで Storage を使うときに必要になる）。
