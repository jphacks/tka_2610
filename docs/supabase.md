# Supabase に移すときにやること

> [!NOTE]
> データベースの Supabase への移行（1〜3、4 は A）は済んでいます。
> プロジェクトは組織 kobadaidesu の `memory-museum`（Northeast Asia (Tokyo)、プロジェクト ID `srfcfowcgnvhwujpijuw`）です。
> このファイルは、データベースを Supabase に移すときの作業リストです。終わった項目にはチェックを入れてください。

> [!NOTE]
> マイグレーション `005_home_layout.sql` で、おうちの配置 JSON を入れる表 `home_layout` を足しました。行は 1 つだけで、列 `layout` は JSONB、RLS は有効です。初期値は SQL に入れず、サーバーの起動時に `backend/static/home/default-layout.json` から入れます。
> 初回の起動では、サンプルの作品 13 点（`backend/static/atelier/`）も `artworks` に登録し、おうちに飾ります。
> 画像と GLB の扱いは、今も下の 4 の A（サーバーは 1 台）です。ただし、サンプルの 13 点だけは、どの PC のサーバーも起動のたびに、足りない画像と GLB を `backend/static/atelier/` から作り直します。そのため、同じ Supabase につないだ 2 台目の PC でも表示されます。

> [!NOTE]
> マイグレーション `006_artwork_model_size.sql` で、`artworks` に作品の実寸の列 `model_width`・`model_height`・`model_depth`（m。NULL 可）を足しました。共有の Supabase には適用済みです。値はサーバーが GLB を測って入れます（登録のとき・編集でモデルを作り直したとき・seed が登録するとき。寸法の無い行は起動時に埋める）。おうちに置く作品の大きさと、置けるかどうかの判定に使います。
> 006 を持たない古いビルドのサーバーは、`migration failed: VersionMissing(6)` で起動できません。最新を pull してからビルドし直してください（`cargo run`）。006 を入れる前から起動したままのサーバーは、作品を枠の大きさで判定するので、実寸でしか置けない作品（奥行きの浅い天板で 90° 回した作品など）を配置から外してしまいます。止めてから最新で起動し直してください。
> 寸法の列は、ほかの PC のサーバーと同時に起動しても、値の無い行にだけ書きます（上書きしない）。この PC に GLB が無い作品は測れないので飛ばします（サンプルの 13 点は、seed が GLB を作り直したときに測ります）。

> [!IMPORTANT]
> マイグレーション `007_home_rooms.sql`（4 部屋の家）を足しました。共有の Supabase（`memory-museum`）には適用済みです（配置は v3 に昇格済み）。開発と確認は、開発用の Supabase プロジェクト `memory-museum-dev` で行いました（接続文字列は開発した人の `.env` にだけあります）。
> 007 は `home_layout` に列 `schema_version`（SMALLINT、NOT NULL、既定 2）を足すだけです。配置 JSON を 4 部屋の形（`schemaVersion` 3）に上げるのは SQL ではなく、サーバーの起動時の処理（`home_api.rs` の `ensure_layout`）です。上げたあとは列にも 3 を書きます。
> 007 を持たない古いビルドは、007 を適用したデータベースでは `migration failed: VersionMissing(7)` で起動できません。わざとそうしています（古いサーバーは v3 の配置を読めないと、初期配置に戻して保存してしまうため）。切り替えの手順は下の「4 部屋の家に切り替える（マイグレーション 007）」です。

## 今の構成（前提）

| 項目 | 今の状態 |
|---|---|
| データベース | `docker-compose.yml` の PostgreSQL 16。接続先は `.env` の `DATABASE_URL` |
| 表の作成 | サーバー起動時に、`backend/migrations/` の SQL を sqlx が自動で適用する |
| 画像・サムネイル・作品の GLB | サーバーを動かしている PC の `backend/data/media/` に保存。**データベースには入らない** |
| 家の GLB | 4 部屋の建物 `backend/static/models/rooms/{hub,left,right,front}.glb`（今は開発用のシェル）と、リビングだけの `backend/static/models/home-empty.glb`（前の版の Web 用）を、起動時に `backend/data/media/museum/` へコピーして配信。家具の GLB と壁紙は `backend/static/home/` から `/home-assets` で配信。どれもデータベースには入らない |
| Web | Rust のサーバー（`/api/...` と `/media/...`）にだけつなぐ。Supabase には直接つながない |

Supabase に移しても、Web の設定は変わりません。変わるのはサーバー（`backend/`）の接続先です。

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
- [x] `docker compose up -d db` は不要になる。起動手順（[development.md](./development.md)）も合わせて直す。

### 4. 画像と GLB をどう共有するか決める

データベースを Supabase にしても、画像と GLB は **サーバーを動かしている PC にしか保存されない。**
複数人がそれぞれ自分の PC でサーバーを動かして同じ Supabase につなぐと、作品の情報は全員に見えるが、ほかの人が登録した作品の画像と 3D は表示されない（404 になる）。
次のどちらかを選ぶ。

- [x] **A. サーバーは 1 台だけ動かす。** ほかの人の Web はそのサーバーにつなぐ（[development.md](./development.md) の「別の PC のサーバーにつなぐとき」）。コードの変更は不要。
- [ ] **B. 画像と GLB を Supabase Storage に置く。** コードの変更が必要。主に触る場所は次のとおり。
  - `backend/src/artworks.rs` の `write_files` と `remove_files`：ローカル保存を Storage へのアップロード・削除に変える
  - `backend/src/state.rs` の `media_url`：Storage の公開 URL を返すようにする
  - `backend/src/main.rs` の `/media` の配信：Storage に移したものは不要になる
  - 家の GLB（部屋ごとの `backend/static/models/rooms/` と `home-empty.glb`）と家具の GLB（`backend/static/home/`）も Storage に置くか、今のままサーバーから配信するかを決める

### 5. 動作確認

- [x] `cargo run` で `[DB] PostgreSQL connected` と `[DB] Migration completed` が出る
- [x] Supabase の Table Editor に `artworks` と `museum_settings` があり、RLS が有効になっている
- [ ] Supabase の Table Editor に `home_layout` があり、RLS が有効になっている（005 を適用したあと）
- [ ] Supabase の Table Editor の `artworks` に `model_width`・`model_height`・`model_depth` があり、サーバーを起動したあとに値が入っている（006 を適用したあと。GLB が無い・測れない作品は NULL のまま）
- [ ] 共有の Supabase の `home_layout` に `schema_version` があり、値が 3 になっている。`layout` の `schemaVersion` も 3 で、`rooms` に `hub`・`left`・`right`・`front` が `enabled: true` で入っている（下の 6 で 007 を適用したあと）
- [x] Web で作品を登録して「おうちに飾る」を押すと、おうちの棚や机に並ぶ
- [ ] （共有する場合）別の PC からも同じ作品と画像が見える

### 6. 4 部屋の家に切り替える（マイグレーション 007）

共有の Supabase では実施済みです（配置は v3 に昇格済み）。下は、そのときに 1 回だけ行った手順です。

- [ ] 1. **全員がサーバーを止める。** 古いサーバーが動いたままだと、v3 の配置を読めずにおうちの画面がエラーになる。前から開いていた模様替えの画面が古いサーバーに保存すると、リビングだけの配置（v2）で上書きしてしまう。
- [ ] 2. 各自、`main` を pull して、`web` で `npm run build`、`backend` で `cargo build` をしてビルドし直す。`.env` の `DATABASE_URL` が共有の Supabase（`memory-museum`）の Session pooler になっていることを確かめる（開発用の `memory-museum-dev` につないだままにしない）。
- [ ] 3. **1 人だけ** が、新しいサーバーを共有の Supabase につないで起動する（`cd backend` → `cargo run`）。007 が適用され、配置が v3 に上がって保存される。ログに `[DB] Migration completed`、`[Home] 配置を v3 に昇格しました (schemaVersion 2 から)`、`[Home] layout loaded (〇 objects, v3)`（物の数は昇格の前と同じ）が出ることを確かめる。リビングの家具と作品はそのまま残り、左・右・前の部屋は空室から始まる（壁紙と床材は、前の配置に入っていた値のまま）。
- [ ] 4. 3 のサーバーが起動し終わってから、ほかの人もサーバーを起動する。2 回目からは昇格のログは出ず、`[Home] layout loaded (〇 objects, v3)` だけが出る。
- [ ] 5. 上の「5. 動作確認」の `schema_version` の項目を確かめる。

- 更新していない古いビルドは `migration failed: VersionMissing(7)` で起動できない（上の注意）。2 からやり直す。
- 切り替える前に自分で試したいときは、Supabase で別のプロジェクトを作り、その Session pooler の接続文字列を自分の `.env` の `DATABASE_URL` にする（接続文字列やパスワードは git に入れない）。空のデータベースなら、初期配置（4 部屋。家具はリビングだけ）とサンプルの作品 13 点が入る。共有の配置を昇格させたときの動きは、`cargo test` の `shared_layout_fixture_validates`（以前の共有の配置。家具 12・作品 13 が v3 でもそのままリビングに残る）で確かめている。

## 注意

- 適用済みのマイグレーションファイル（`backend/migrations/` の既存ファイル）は **書き換えない。** 変更は新しい番号のファイルで足す。書き換えるとチェックサムが変わり、起動できなくなる。`007_home_rooms.sql` は開発用のプロジェクトにはもう適用してあるので、共有の Supabase に適用する前でも書き換えない。
- Supabase のパスワードや接続文字列は git に入れない（`.env` は `.gitignore` 済み）。
- サーバーは Postgres に直接つなぐので、Supabase の `anon` キーや `service_role` キーは今のところ使わない（B を選んで Storage を使うときに必要になる）。
