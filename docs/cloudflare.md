# Cloudflare で動かす（テスト環境）

Render の代わりに、Cloudflare だけで memoria を動かすための作業メモです。今はテスト環境で、本番（Render）とチームの共有の Supabase には触りません。
無料プランのまま、クレジットカードを登録しないで使えます。

## 仕組み

| 部分 | Render（今） | Cloudflare（このフォルダ） |
|---|---|---|
| 画面（`web/dist`）・家具と壁紙・舞台・建物の GLB・サンプルの作品 33 点 | Rust のサーバーが配る | **静的ファイル**（Workers Static Assets）。Worker を通らずに配られる |
| API（`/api`） | Rust（axum + sqlx） | **Durable Object**（`Museum`。Rust を Wasm にして、同じ axum の API を動かす） |
| データベース | Supabase（PostgreSQL） | Durable Object の中の **SQLite** |
| 登録した写真・GLB・おもいで（`/media`） | サーバーのディスク（再起動で消える） | Durable Object の SQLite（1 MB ずつに分けて入れる。消えない） |

- 入口の Worker（`src/lib.rs`）は、`/api` と `/media` を Durable Object に渡すだけです。
  - ただし `/media` のうち、サンプルの作品（ファイル名に `-seed.` が入る）と建物の GLB（`/media/museum/`）は静的ファイルにあるので、Worker が静的ファイルから取って返します（`static_asset`）。
  - このとき、応答の本体は JS のストリームのまま返します。workers-rs の `Fetcher::fetch_request`（`http` 機能あり）と `Response::try_from` を使うと、本体がいったん Rust のストリームになって Content-Length が消え、本物の Cloudflare では大きな GLB をいくつも同時に読むと途中で切れました（`wrangler dev` では起きない）。おうち・美術館・鑑賞モードで `Invalid typed array length` が出たら、ここを疑ってください。
  - 普通の Worker は、無料プランだと 1 回の処理の CPU が 10 ミリ秒までです。
  - Durable Object は 30 秒まで使えるので、写真の処理（縮小・GLB 作り）も backend と同じ Rust のコードのまま動きます。
- おうちは 1 つなので、Durable Object も 1 つです（id `main`）。
- SQL は同期で動き、その間にほかの要求は割り込みません。そのため backend の家全体のロック（`lock_house`）は要りません。まとめて書く処理は `Db::tx`（`transactionSync`）で 1 つのトランザクションにしています。
- R2（Cloudflare のファイル置き場）はカードの登録が要るので使っていません。

## コードの置き場所

- `cloudflare/src/`：Worker と Durable Object。
  - DB に触らない処理（置き方の決まり `home.rs`・年齢 `age.rs`・GLB `glb.rs`・写真 `media.rs`・種類 `museum.rs`）は、`backend/src/` のファイルをそのまま読み込んでいます（`#[path]`）。backend と同じ結果になります。
  - DB とファイルに触る処理（`artworks.rs`・`home_api.rs` など）は、backend から書き移したものです。SQL は SQLite に、`sqlx` は `db.rs` に、`tokio::fs` は `store.rs` に置き換えています。
  - 表の形は `schema.rs` です（backend のマイグレーション 001〜016 を当てたあとと同じ形）。
- `cloudflare/prep/`：静的ファイルを `public/` に集め、Worker に埋め込む値を `generated/` に書く道具（手元で動かす Rust）。
  - サンプルの作品の写真は、backend の seed と同じ処理で縮めます。
- `public/`・`generated/`・`build/` は作られるものなので、git に入れません。

**backend の API を変えたら、`cloudflare/src/` の同じ名前のファイルも合わせて直してください。** 置き方の決まり（`home.rs`）などの共有のファイルは、直せば両方に入ります。

## 手元で動かす

要るもの：
- rustup の Rust と wasm32 のターゲット：`rustup target add wasm32-unknown-unknown`
- worker-build：`cargo install worker-build`
- Node.js

```sh
cd cloudflare
npm install
npm run build      # web をビルドして、public/ と generated/ を作る
npm run dev        # http://localhost:8787 (wrangler dev。Durable Object とその SQLite も手元で動く)
```

- 手元のデータは `cloudflare/.wrangler/` に入ります。消すと最初からやり直せます。
- AI のメモの下書きを試すときは、`cloudflare/.dev.vars` に `GEMINI_API_KEY=...` を書きます（git に入れない）。

## 公開する（テスト環境）

1. `npx wrangler login` で、自分の Cloudflare のアカウントに入ります（ブラウザが開きます）。
2. `npm run build && npm run deploy` で公開します。
   - `https://memoria-try.<アカウントのサブドメイン>.workers.dev` のような URL が出ます。
   - アカウントに workers.dev のサブドメインがまだ無いと、wrangler が自動で付けようとして、名前が使われていれば止まります。ダッシュボードの Workers の最初の画面で登録してから、もう一度公開します。
   - 今のテスト環境：<https://memoria-try.tka-2610.workers.dev>
   - サブドメインを付けた直後は、証明書ができるまで数分 HTTPS につながりません。
3. AI のメモの下書きを使うなら、`npx wrangler secret put GEMINI_API_KEY` でキーを入れます。

### CI/CD（GitHub Actions）

`.github/workflows/ci.yml` が、PR と main への push のたびに動きます。

| いつ | すること |
|---|---|
| PR | backend の `cargo test`・web の `npm run build` と `npm run check:placement`・Cloudflare 版のビルド（`wrangler deploy --dry-run`。公開はしない） |
| main に入ったとき | 上が全部通ったら、memoria-try に公開する |
| Actions の画面の「Run workflow」（main） | 同じテストのあとに公開する（自動の公開を止めているときに使う） |

- backend を直したときも、Cloudflare 版のビルドが通るかを PR で確かめられます（`home.rs` などを共有しているため）。
- 実行結果の Summary に、Worker の大きさ（無料プランの上限は gzip で 3 MB）が出ます。
- 公開には、リポジトリの secrets の `CLOUDFLARE_API_TOKEN` を使います。Cloudflare のダッシュボードの「My Profile → API Tokens」で、テンプレートの「Edit Cloudflare Workers」から作ったトークンです。アカウント ID は `ci.yml` に書いてあります（秘密の値ではない）。
- **自動の公開を止めるとき**（発表の直前など）：リポジトリの Settings → Secrets and variables → Actions → Variables で、`CLOUDFLARE_AUTO_DEPLOY` を `false` にします。テストとビルドは今までどおり動きます。戻すときは変数を消すか `true` にします。

### 公開したあとの確かめ方

- スクリプトから API を呼ぶときは、`User-Agent` を付けてください。Python の `urllib` の既定の名前（`Python-urllib/…`）は、Cloudflare に機械からのアクセスとして止められます（403、本文は `error code: 1010`）。ブラウザからは関係ありません。
- `npx wrangler tail memoria-try --format json` で、要求ごとの CPU 時間と結果（`ok`・`exceededCpu`・`exceededMemory` など）が見られます。12MP の写真から作品を作る処理は、Durable Object で CPU 約 0.7 秒でした（上限は 30 秒）。

## 無料プランの制限と、backend との違い

- **おもいでの動画は 95 MB まで**：Cloudflare が受け取れる送信の大きさが 100 MB までのためです（backend は 100 MB）。
- **入れられる量**：Durable Object の SQLite は、無料プランでは全部で 5 GB です（1 つの Durable Object は 1 GB までと書かれている所もあります）。
- **日付**：「今日」は日本時間で決めます（backend はサーバーの PC の時計）。
- **起動時の処理**：Durable Object が起きてから最初の要求のときに、表の用意・おへやの用意・整理（reconcile）・サンプルの登録をします。
  - backend の額縁の作り直し（`upgrade_frames`）・寸法の後埋め（`backfill_model_sizes`）・孤児ファイルの掃除はしません。作品はどれも今の額縁で作り、登録のときに測り、ファイルは行と同じ DB にあるためです。
- **前の配置**：Cloudflare には前の 1 つだけの配置（`home_layout`）が無いので、初めての起動では、今の年齢の 1 階を初期配置で作ります。
