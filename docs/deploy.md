# 公開する（Render）

審査員などがブラウザで開けるよう、サーバーを Render に置く手順です。
見る人は公開した URL を開くだけで、環境変数などは要りません。環境変数は Render の管理画面で、私たちが一度だけ入れます。

## 仕組み

- リポジトリ直下の `Dockerfile` で、1 つの入れ物を作ります。
  1. Web（React + Vite）をビルドする（Node）
  2. サーバー（Rust）をビルドする
  3. 動かす入れ物に、サーバーの実行ファイル・`backend/static`（家具・建物・サンプルの作品）・Web のビルド結果だけを入れる
- 入れ物の中では、`STATIC_DIR`・`WEB_DIST`・`MEDIA_DIR`・`PORT` を Dockerfile が決めています。管理画面で入れるのは `DATABASE_URL` だけです（`PORT` は Render が上書きする）。
- 設定は `render.yaml`（Render の Blueprint）にあります。
  - 無料プラン、シンガポール（日本にいちばん近い場所）
  - 死活確認は `/healthz`
  - `main` に入ったら自動で作り直す
- データベースは Supabase です。今は、チームの共有の Supabase につなぐ前提です。

## はじめて置くとき

1. **Render のアカウント**：GitHub でログインして作ります。
2. **リポジトリへの許可**：リポジトリ `jphacks/tka_2610` を Render から読めるようにします。GitHub の組織（`jphacks`）のリポジトリなので、組織の管理者の許可が要ることがあります。
3. **Blueprint を作る**：管理画面の「New → Blueprint」で、このリポジトリを選びます。`render.yaml` を読んで、サービス `memoria` が作られます。
4. **`DATABASE_URL` を入れる**：Supabase の Session pooler の接続文字列（ポート 5432、`?sslmode=require` 付き）を入れます。パスワードが入るので、どこにも書き残さないでください。
5. **起動を待つ**：最初のビルドは 10〜20 分ほどかかります（Rust のビルドが長い）。
   - ログに `[DB] Migration completed`・`[Seed] atelier: …`・`Memory Museum Backend` が出れば起動しています。
   - `https://memoria-xxxx.onrender.com` のような URL が出ます。これを審査員に渡します。

## 気をつけること

### 共有の Supabase につなぐとき
- **先に全員を最新にする**：公開したサーバーは、起動のときに新しいマイグレーションを共有の DB に当てます（今は 014 まで）。古いサーバーは `VersionMissing` で起動できなくなるので、先に全員が pull してビルドし直してください（`docs/development.md` の「共有のデータベースを使うとき」）。
- **初めて当てるとき**：まだ年齢ごとのおへやになっていない DB なら、その起動のときに、今までの配置を年齢ごとのおへやに分けます。
- **チームの PC で登録した作品**：写真と GLB はその PC にしか無いので、公開したサーバーでは画像や 3D が出ません。サンプルの 33 点は出ます。
- **公開したサーバーで登録した作品**：写真と GLB は、再起動で消えます（下の「無料プランの制限」）。データベースの行は共有の DB に残るので、チームの PC からも画像が出ない作品として見えます。

### 無料プランの制限
- **寝る**：15 分ほど使わないと寝ます。次に開いたときは、起きるまで 1 分ほどかかります。審査の前に一度開いておくと安心です。
- **ディスクが消える**：再起動のたびにディスクが空になります。
  - サンプルの作品のファイルは、起動のときに `backend/static/atelier` から作り直されます（ログの `repaired 99 files`）。
  - 利用者が登録した写真・GLB・おもいでの動画や声は消えます。残したいときは、Supabase Storage に置くようにする必要があります（`docs/supabase.md` の 4 の B）。
- **メモリ**：512 MB です。サーバーは 100 MB ほどしか使いません。

### その他
- **ログインが無い**：URL を知っている人は誰でも、作品を消したり模様替えしたりできます。
- **https になる**：公開した URL は https なので、スマホでも声の録音（マイク）が使えます。

## 手元で入れ物を試すとき（Docker があるとき）

```sh
docker build -t memoria .
docker run --rm -p 8080:8080 -e DATABASE_URL='postgres://museum:museum@host.docker.internal:5432/museum' memoria
```
