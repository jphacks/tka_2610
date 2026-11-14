# MCP サーバー（Claude Code・Codex・Claude のデスクトップアプリから撮影データを読み、GLB を作る）

受信サーバーが受け取った撮影セッション（`captures/`）を、Claude Code・Codex CLI・Claude のデスクトップアプリ（Mac）などの AI が MCP（Model Context Protocol）で読めるようにするサーバーです。AI はセッションの一覧を見て、`brief.md` を読み、写真を見ます。

さらに、**用意してある形の組み立てツール**（`tools/flat-art-glb`・`tools/solid-glb`）で、写真から GLB を作れます。AI は形を作るプログラムを書かず、写真を見て **設定（JSON）だけを書き**、Mac の上でツールが GLB を作り、AI は比較の画像を 1 枚見て直します（AI に形のコードを一から書かせると、1 つの作品に 20〜40 分・4〜6 ドルかかったため。ユーザーが決めた形です）。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

- Mac の中だけで動きます（標準入出力でつなぐ stdio サーバー）。サーバー自身は外へ何も送りません。GLB の組み立て・検証・描画も Mac の中です。
- ただし、AI が写真を見る（`get_view`・`photo_grid`、`build_model` の重ね描きの画像、`check_model` の比較の画像）と、その画像は Claude などのクラウドの AI に渡ります。これは外部への送信です。写真を見せるのは、ユーザーがその作業を頼んだときだけにしてください（`captures/README.md` の「外部への送信について」と同じ決まりです）。
- 元のセッション（`captures/sessions/`）には書き込みません。転送の途中（`captures/incoming/`）は読みません。ペアリングコードの入った `captures/.receiver.json` も読みません。
- 書き込むのは次のツールだけです：`rebuild_pack`（`captures/for_claude/<sessionId>/` を作り直す）、`output_dir`・`build_model`・`check_model`（`captures/reconstructions/<sessionId>/<label>/` の中だけ）。`photo_grid` の画像は一時フォルダで作って消します。

## GLB を作る流れ（Claude のデスクトップアプリで、新しいチャットから）

「最新の撮影から 3D モデルを作って」のように頼むと、AI は次の順に進めます（サーバーの `instructions` にも同じことを書いてあります）。

1. `latest_session`（または `list_sessions`）でセッションを見つけ、`get_brief` で `brief.md` を読む。
2. `build_guide` で、どのツールが合うかと、写真の場所・分かっている大きさを入れた設定のひな形を受け取る。
   - 平面の作品（`workKind: "flat"`）→ `flat-art-glb`。ひな形は `plane`（まっすぐにした絵 `views/artwork.jpg` を、選んだ紙の大きさの薄い板に貼る）で、そのまま作れます。色紙の貼り絵なら `layers` に変えます。
   - 立体で、上から見下ろした写真（60° 以上）がある → `solid-glb` の `slab`。**上が平らな物（箱・板・トレー・操作盤・本・ふたのある容器）のときだけ**。角・輪郭は `TODO` になっていて、AI が `photo_grid` で読んで埋めます。
   - それ以外（丸い物・動物の形・人形など、または上からの写真が無い）→ **どちらも合いません。** AI はそのことをユーザーに伝えて止まります（自分で形のコードを書きません）。
3. `get_view` で写真を 1 回ずつ見て、`photo_grid` で位置（割合）を読み、設定の `TODO` を埋める。
4. `build_model` で作る（1 秒ほど）。結果の数字と重ね描きの画像を 1 回見る。ツールのエラーは、そのメッセージ付きで返るので、設定を直してもう一度呼ぶ。
5. `check_model` で検証（エラー 0 件）と、写真とモデルを並べた `compare.jpg` を 1 回見る。直すのは 2 回くらいまで。
6. `model.glb` の場所（絶対パス）、写真との違い、仮定した値（大きさ・高さ）をユーザーに伝える。

後の会話で続きをするときは `list_models` で、作ったものと設定（`config.json`）の場所が分かります。

**memoria への登録は、今は手作業です。** できた `model.glb` を、memoria の作品追加のフォームか作品の編集の画面でアップロードしてください。

## ツール

### 撮影データを読む

| ツール | 中身 |
|---|---|
| `list_sessions(limit=20)` | 受け取ったセッションを新しい順に。sessionId・タイトル・作品の種類（`workKind`。`object` は立体、`flat` は平面）・立体の撮り方（`guidance`。`free` は案内なしで自由に撮ったもの（どの写真がどの向きかは記録していない）、`heading` は向きで案内して位置と大きさを撮ったあとに求めたもの、`baseCylinder` は底の中心と円柱を先に決めたもの。平面は null）・撮る人が選んだ・入力した大きさ（`declaredSize`。平面は一覧から選んだ紙 `sheet`、立体は入力した高さ `heightM`。AR で測った値ではなく、測った値・求めた値より優先する。入力していなければ null）・撮影方法（`capturePlan`。`ai5` は正面・右・後ろ・左・真上の 5 枚、`flat1` は真上から 1 枚）・写真の数・受信時刻・パック（`for_claude/`）があるか・そのパス |
| `latest_session(received_after=None)` | 一番新しいセッション。`received_after` より後に受け取ったものが無ければ `status: "nothing_new"` |
| `get_brief(session)` | `brief.md` の本文と、作品の種類（`workKind`）、案内のしかた（`guidance`。`heading` なら大きさは撮ったあとに求めたおおよその値で、`measurements.heading` に下と上の目安・信頼度・中心の線の外れ）、撮る人が選んだ・入力した大きさ（`declaredSize`。立体で高さを入力したときは `next` にも「この高さを優先する」と出る）、実寸（`measurements.json`）、見られる写真の一覧（名前・方位と仰角・ピクセルの大きさ・絶対パス）、撮れていない方向。平面の作品は `flat`（使った写真・紙の四隅など）も |
| `get_view(session, view, max_side=1568)` | 1 枚の写真を画像で返す（長い辺が `max_side` より大きければ縮める）。パスと方向も返す。`view="overview"` で一覧の画像 |
| `get_original_photos(session)` | 元の写真（`sessions/<id>/photos/`）のパスと、写真ごとの方向・カメラの姿勢と内部パラメータ・マスクの状態、平面の作品なら紙の四隅・ARKit の平面で測った実寸・補正した画像（`rectified/`）、`declaredSize`、向きで案内したセッションなら撮ったときの向き（`photos[].heading`）と基準の `heading`（撮ったあとに求めた中心・大きさ）（画像そのものは返さない） |
| `rebuild_pack(session, cutouts=false)` | `memoria-pack` でパックを作り直す（受信サーバーと同じ呼び方に `--force`）。`cutouts=true` で背景を透明にした `views/<名前>_cutout.png` も作る |
| `output_dir(session, label)` | `captures/reconstructions/<sessionId>/<label>/` を作って返す。`label` の `A-Z a-z 0-9 . _ -` 以外の文字は `-` にする。用意したツール以外の方法で作るのを、ユーザーが頼んだときの置き場所 |
| `receiver_status()` | 受信サーバーがポート（既定 8765）で待ち受けているか（接続できるかだけを見る。認証の値は送らない）、`captures/` の場所、セッションの数、`memoria-pack` をビルドしてあるか |

### GLB を作る

| ツール | 中身 |
|---|---|
| `build_guide(session)` | どのツールが合うか（`builder`：`flat-art-glb`・`solid-glb`・null）、`fit`、`decision`（何をするか。合わないときは「ユーザーに伝えて止まる」）、`starterConfig`（写真のパス・分かっている大きさを入れた設定のひな形。`TODO` で始まる値は埋める）、`photoKeys`（写真を指す設定のキー）、`photos`（使える写真：名前・絶対パス・大きさ・見下ろす角度・方位）、`assumptions`（ユーザーに伝える仮定）、`steps`、`outputRoot`。2 つ目のブロックは、ツールの README から取り出した設定の説明（`flat-art-glb` は「モード」「設定（JSON）」と例のファイル、`solid-glb` は「作れる形」「設定ファイル（`slab`）」）。説明を別に書き写していないので、ツールの README を直せばそのまま変わります |
| `photo_grid(session, view, region=None)` | 写真に座標の格子を描いた画像（長い辺 1500 以下）。目盛りは **写真全体に対する割合**（x は右、y は下、0〜1）。`region=[x0, y0, x1, y1]` で一部を拡大（目盛りは全体の割合のまま）。中身は `solidglb.py grid` |
| `build_model(session, label, builder, config)` | 設定を `captures/reconstructions/<sessionId>/<label>/config.json` に書き（写真は絶対パスに直す）、ツールを動かして `model.glb`・`report.json`・重ね描きの画像を作る。結果は `modelPath`・`sizeMm`（x 左右・y 高さ・z 前後、mm）・三角形の数・バイト数・警告・ツールの数字・絶対パスと、重ね描きの画像（`flat-art-glb` は `overlay.jpg`：まっすぐにした写真に紙・紙片の輪郭、`solid-glb` は `top_overlay.jpg`：上面の輪郭（緑）と丸い部品（赤））。同じ `label` は上書き（前の `compare.jpg` なども消す）。ツールのエラーは、ツールのメッセージ付きのエラーで返す |
| `check_model(session, label)` | glTF の検証（Khronos の gltf-validator。エラー 0 件が条件）と、ヘッドレスの Chromium での描画、`compare.jpg`（`flat-art-glb` は 写真 ｜ 正面 ｜ 斜め、`solid-glb` は設定の `views` ごとに 写真 ｜ モデル）。画像は長い辺 1568 以下の JPEG で返す。描画の準備が無いときは、検証の結果と `rendererReady: false`・入れるコマンドを返す |
| `list_models(session)` | そのセッションで作ったもの（新しい順）：label・ツール・フォルダ・`model.glb`・`config.json`・`compare.jpg`・重ね描きの画像の絶対パス、`sizeMm`、三角形の数、作った時刻、警告、検証の結果、確かめた時刻 |
| `tools_status()` | ツールを動かす準備ができているか：ツール用の Python（numpy・OpenCV・mapbox_earcut）、Node.js、各ツールの `node_modules`（three・gltf-validator・playwright）、Playwright の Chromium。`ready.build`・`ready.photoGrid`・`ready.check`、足りないときは `fix`（実行するコマンド） |

- `session` には sessionId 全体か、先頭の数文字（大文字・小文字は問わない）を渡します。あてはまるものが無い・複数あるときは、候補を並べたエラーを返します。
- 結果にはすべて絶対パスが入っています。ファイルを読めるエージェントは、元のファイルを直接開けます。
- 写真の名前（`front`・`top` など）は決め打ちせず、`pack.json` とフォルダにあるものから作ります。`ai5` のパックは背景付きの写真だけ（`hull.obj` なし、実寸は撮影時の円柱の目安）、前の版のパックは `<名前>_cutout.jpg` と `hull.obj` もあります。`get_view` に渡せるのは `get_brief` の一覧にある名前と `overview` だけです。
- **自由に撮った立体**（`guidance` が `free`）のパックは、撮った順の `photo-01`・`photo-02`…（16 枚まで）だけです。`overview` はありません。どの写真が正面・横・後ろ・真上かは記録していないので、写真を見て決めます。大きさは写真から求めず、撮る人が高さを入力したときだけ `measurements.declaredHeight` にあります。`build_guide` は、見下ろす角度が一番大きい写真（60° 以上）を真上の写真にします。
- **平面の作品**（`workKind` が `flat`）のパックは、`artwork`（遠近を直した絵。直せなかったときは写真をまっすぐに回したもの）と、補正したときは `photo`（元の写真）だけです。`overview` はありません。紙の大きさは `measurements.sheet`（`source` が `declared` なら撮る人が一覧から選んだ紙、`measured` なら ARKit の平面で測った値。どちらも無ければ null）。補正した絵なら、`build_guide` のひな形は紙の 4 隅を画像の 4 隅（`[[0,0],[1,0],[1,1],[0,1]]`）にします。
- `get_view` は JPEG を JPEG のまま、透明の PNG（`_cutout.png`）を PNG のまま返します。縮めるのに macOS の `sips` を使います（Pillow などは要りません）。

### 設定の中の写真（安全のための決まり）

`build_model` の設定で写真を指すキー（`flat-art-glb` は `photo`、`solid-glb` は `top.photo` と `views[].photo`）には、**そのセッションの写真だけ** を書けます：

- `build_guide`・`get_brief` の写真の名前（`artwork`・`top`・`photo-03` など）、または
- そのセッションのパック（`for_claude/<sessionId>/`）か元の写真（`sessions/<sessionId>/photos/`・`upright/`・`rectified/`）の中の画像の絶対パス。

相対パス・`..`・ほかのセッション・画像でないファイル・外を指すシンボリックリンクは断ります。`solid-glb` の `views[].name`（描画した画像のファイル名になる）は `A-Z a-z 0-9 _ -` だけです。`TODO` で始まる値が残っている設定も断ります（その場所を返します）。

## 必要なもの

- [uv](https://docs.astral.sh/uv/)（`brew install uv`）。サーバーの依存（公式の Python MCP SDK `mcp`）は、スクリプトの先頭に書いてあり（PEP 723）、uv が入れます。
- GLB を作るとき：ツール用の Python の環境 `tools/.venv`（numpy・opencv-python-headless・mapbox_earcut。Python 3.12）。
- 検証と描画（`check_model`）のとき：Node.js（`brew install node`）、`tools/flat-art-glb`・`tools/solid-glb` の `node_modules`（three・gltf-validator・playwright。`package-lock.json` のとおり）、Playwright の Chromium（`~/Library/Caches/ms-playwright/` に 1 つ。両方のツールで共有）。
- パックを作り直すときは、ビルドした `memoria-pack`（`cd tools/claude-pack && swift build -c release`）。

これらは下の `scripts/install-mcp.sh` が一度に用意します（ツールの準備だけなら `scripts/install-mcp.sh --tools-only`）。`tools/.venv` と `node_modules/` は git に入りません。

手で起動するときは、`capture/` で次のようにします（MCP のクライアントからつなぐもので、そのままでは何も表示しません。Ctrl-C で止めます）。

```sh
uv run --script mcp-server/memoria_mcp.py
```

## つなぎ方

### まとめて登録する（Claude Code・Codex・Claude のデスクトップアプリ）

```sh
scripts/install-mcp.sh                       # 見つかったものすべてに登録し、ツールを用意する（何度実行しても同じ）
MEMORIA_CAPTURES_DIR=/path/to/captures scripts/install-mcp.sh   # 受信サーバーの保存先が capture/captures/ でないとき
scripts/install-mcp.sh --dry-run             # することを表示するだけ
scripts/install-mcp.sh --claude-desktop      # デスクトップアプリだけ（--claude-code・--codex も。組み合わせられる）
scripts/install-mcp.sh --skip-tools          # 登録だけ（ツールを用意しない）
scripts/install-mcp.sh --tools-only          # ツールの用意だけ（登録しない）
scripts/install-mcp.sh --uninstall           # 登録を消す（tools/.venv・node_modules は残す）
```

このスクリプトがすること：

1. サーバーの依存を先に入れる（`uv sync --script`）。
2. Claude Code（`claude` があるとき）：`claude mcp add --scope user memoria-capture -- <uv のパス> run --script <tka_2610>/capture/mcp-server/memoria_mcp.py`（前の登録は消してから足す。`MEMORIA_CAPTURES_DIR` があれば `-e` で渡す）。
3. Codex（`codex` があるとき）：`codex mcp add memoria-capture -- …`（同じく `--env`）。
4. Claude のデスクトップアプリ（設定のフォルダ `~/Library/Application Support/Claude/` があるとき。`--claude-desktop` のときは必ず）：`claude_desktop_config.json` の `mcpServers["memoria-capture"]` だけを足す・書き換える。ほかのキー・ほかのサーバーはそのままです。書き換える前に、同じフォルダに `claude_desktop_config.json.bak-<日時>` を作ります。中身が同じなら何も書きません。`--uninstall` はこの項目だけを消します（`mcpServers` は空のまま残る）。JSON の編集は埋め込みの Python（標準の `json`）で行い、壊れた JSON のファイルには触りません。
5. ツールの用意（`--skip-tools` で省く）：`uv venv --python 3.12 tools/.venv`（無いときだけ）、`uv pip install`（両方のツールの `requirements.txt`）、OpenCV を一度読み込む（初回の読み込みは数秒かかるため）、`npm ci`（両方のツール）、`playwright install chromium`。Node.js が無いときは、そのことと、入れたあとに実行するコマンドを表示します（GLB を作るのは Node.js 無しでもできます）。

デスクトップアプリの項目は、次の形になります（パスは実行したときに求めます。リポジトリには入りません）。デスクトップアプリはシェルの `PATH` を引き継がないので、`uv` は絶対パスにし、`uv`・`node` の場所を入れた `PATH` を `env` で渡します。

```json
"memoria-capture": {
  "command": "/Users/<名前>/.local/bin/uv",
  "args": ["run", "--script", "<tka_2610>/capture/mcp-server/memoria_mcp.py"],
  "env": {
    "PATH": "/Users/<名前>/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "MEMORIA_CAPTURES_DIR": "<受信サーバーの保存先（実行したときに環境変数があれば）>"
  }
}
```

**登録したら、デスクトップアプリを一度終了（Cmd-Q）して開き直してください。** 開いている間は設定を読み直しません。チェックアウトを別の場所へ移したとき・`MEMORIA_CAPTURES_DIR` を変えたときは、もう一度実行します。

試すときに本物の設定を変えないよう、`CLAUDE_DESKTOP_CONFIG`（デスクトップアプリの設定ファイルの場所）・`CLAUDE_CONFIG_DIR`（Claude Code）・`CODEX_HOME`（Codex）で一時的な場所を指せます。

### Claude Code（tka_2610 の中だけで使う）

tka_2610 の一番上の `.mcp.json` に `memoria-capture` として書いてあります（スクリプトの場所は `capture/mcp-server/memoria_mcp.py`）。tka_2610（またはその下のフォルダ）で `claude` を起動すると、初回に使ってよいかを聞かれるので、許可してください。`/mcp` で状態を見られます。

### 撮影データの場所を変える

既定は `capture/captures/` です（起動したフォルダではなく、`memoria_mcp.py` の場所から決めます）。受信サーバーを `--data-dir` で別のフォルダにしているときは、環境変数 `MEMORIA_CAPTURES_DIR` で同じフォルダを指定します（`scripts/install-mcp.sh` を実行するときに付けると、3 つのクライアントすべてに渡します）。受信サーバーのポートを変えているときは `MEMORIA_RECEIVER_PORT` も指定します（`receiver_status` だけが使います）。ツール用の Python を別の場所にしたいときは `MEMORIA_TOOLS_PYTHON` です（既定 `tools/.venv/bin/python`）。

## 動くかの確認

```sh
python3 -m unittest discover -s mcp-server/tests -v   # 一時フォルダの偽の captures/ で確かめる（MCP SDK は要らない）
claude mcp get memoria-capture                        # Status: ✔ Connected
codex mcp get memoria-capture
```

- テストのうち、本物のツールで GLB を作る・描画するもの（`BuilderRunTests`）は、`tools/.venv` が無いと飛ばします（描画は Chromium が無いときも）。インストーラーのテスト（`InstallerDesktopTests`）は、偽の `uv` と一時的な設定ファイルで `scripts/install-mcp.sh --claude-desktop` を動かします。
- Claude Code の中では `/mcp` に `memoria-capture` が出て、「tools_status を呼んで」などと頼むと結果が返ります。
- **Claude のデスクトップアプリ**：開き直したあと、「設定 > 開発者（Developer）」に `memoria-capture` が出て、状態が running になっているかを見ます。チャットの入力欄のツールの一覧（スライダーの形のボタン）にも出ます。新しいチャットで「memoria-capture の tools_status を呼んで」と頼み、`ready` がすべて true なら準備ができています。続けて「最新の撮影から 3D モデルを作って」と頼みます。

## うまくいかないとき

| 症状 | 確かめること |
|---|---|
| つながらない（Failed to connect） | `uv` が PATH にあるか（`command -v uv`）。`capture/` で `uv run --script mcp-server/memoria_mcp.py` を実行し、エラーが出ないか（標準エラーに `captures: …` と出て待ち続ければ正常） |
| デスクトップアプリに出てこない | アプリを Cmd-Q で終了して開き直したか。`~/Library/Application Support/Claude/claude_desktop_config.json` に `mcpServers.memoria-capture` があるか。ログは `~/Library/Logs/Claude/mcp.log` と `~/Library/Logs/Claude/mcp-server-memoria-capture.log`（サーバーの標準エラーもここに出ます） |
| デスクトップアプリで `uv`・`node` が見つからない | 項目の `command` が uv の絶対パスか、`env.PATH` に `uv`・`node` のフォルダがあるか。uv や Node.js を入れ直して場所が変わったら、`scripts/install-mcp.sh --claude-desktop` をもう一度 |
| 初回だけ時間切れになる | uv が依存を入れている間に、クライアントの起動の待ち時間（Codex は既定 10 秒）を過ぎた。`uv sync --script mcp-server/memoria_mcp.py` を一度実行してからつなぎ直す。Codex は `~/.codex/config.toml` の `[mcp_servers.memoria-capture]` に `startup_timeout_sec = 30` を足してもよい |
| `build_model`・`photo_grid` が「Python environment is missing」 | `scripts/install-mcp.sh --tools-only` を一度実行する（`tools_status` の `fix` と同じ）。デスクトップアプリの開き直しは要りません |
| `check_model` が `rendererReady: false` | Node.js・`node_modules`・Chromium のどれかが無い。`tools_status` を見て、`scripts/install-mcp.sh --tools-only`。GLB 自体はできています |
| `build_model` がツールのエラーを返す | メッセージの最後の行（例：`ValueError: …`）が設定のどこが悪いかを示します。設定を直してもう一度。`config still has TODO placeholders at …` は、ひな形の `TODO` が残っている場所 |
| `has no pack` と出る | 受け取った直後なら数秒待つ。作られないときは `rebuild_pack` |
| `memoria-pack is not built` と出る | `cd tools/claude-pack && swift build -c release` |
| セッションが出てこない | `receiver_status` の `capturesDir` が受信サーバーの保存先と同じか（`MEMORIA_CAPTURES_DIR`）。転送の途中（`incoming/`）のものは出ません |
| `receiverListening` が false | 受信サーバーを起動する（`python3 receiver/memoria_receiver.py`）。ポートを変えているときは `MEMORIA_RECEIVER_PORT` |
| 画像が大きすぎると言われる | `get_view` の `max_side` を小さくする（例 1024）。Claude Code は `MAX_MCP_OUTPUT_TOKENS` で上限を変えられます |

- サーバーのログは標準エラーに出ます（標準出力は MCP の通信だけに使います）。
- かかる時間の目安（この Mac で、合成の写真）：`build_model` 0.1〜1.3 秒、`check_model` 約 2 秒、`photo_grid` 0.1 秒、`build_guide`・`list_models` は一瞬。ツールを入れた直後の最初の OpenCV の読み込みは 10 秒ほどかかるので、インストーラーが先に済ませます。

## できないこと

- **丸い物・動物や人形の形・斜めの面の物は作れません。** `solid-glb` は上が平らな物（`slab`）だけ、`flat-art-glb` は平面の作品だけです。合わないときは、AI がそのことをユーザーに伝えます（その場で別の形のコードを書きません）。
- 上から見下ろした写真（60° 以上）が無い立体は、上が平らでも作れません（撮り直しで真上の写真を足します）。
- **memoria への登録は手作業です。** `model.glb` を memoria の作品追加のフォームか編集の画面でアップロードします。
- `solid-glb` の幅（`width_mm`）は写真からは分かりません。パックに大きさ（`measurements.sizeCm`）があればひな形に入れ、無ければ AI が見積もって「仮定した」と伝えます。
- Claude のデスクトップアプリそのものでの動きは、このリポジトリの中では確かめられません（MCP の公式 SDK のクライアントで、デスクトップアプリと同じ起動のしかた・同じ `PATH` で確かめています）。
