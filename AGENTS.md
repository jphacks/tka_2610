# AGENTS.md

このリポジトリで作業する AI エージェント向けのメモです。人向けの説明（仕組み・起動方法・API）は [docs/development.md](docs/development.md) にあります（リポジトリ直下の README.md は JPHACKS の提出用）。

## 構成

| ディレクトリ | 中身 | 役割 |
|---|---|---|
| `backend/` | Rust（axum + sqlx + PostgreSQL） | 写真の処理、GLB の生成、家の部屋の定義（`ROOM_DEFS`）、配置 JSON の検証と保存、作品を飾る場所の自動選択など、処理はすべてここ |
| `web/` | React + Vite + three.js | 表示だけ。3D の家（リビング 1 部屋の建物・家具と作品、一人称で歩く鑑賞モード、模様替えも）もここで表示する。処理を足すときは `backend/` に書く（例外は模様替えの「置けるかどうか」の判定（作品の大きさ・縁への寄せ方・部屋ごとの範囲・出入口の前を含む）で、Rust と同じ計算を `web/src/three/scenes/home/placement.ts` にも持つ） |
| `tools/` | Python（`tools/home-rooms/`） | 開発用の建物 GLB（`backend/static/models/rooms/hub.glb`）を家のキット v1 の部品から作る `build_rooms.py` と、GLB の作りを確かめる `check_rooms.py`。アプリの実行には使わない |
| `docs/` | 作業メモ | 構成の説明や、作業の記録、家の建物 GLB の仕様（`house-assets.md`）など |

家は中央のリビング `hub`（10 × 10 m）の 1 部屋だけです。出入口は無く、4 面の壁はすべてふさがっています（以前あった左・右・前の部屋 `left`・`right`・`front` と、そこへの出入口は消しました）。部屋の定義（中心・大きさ・出入口・建物の GLB のファイル名・カットする壁）は **`backend/src/home.rs` の `ROOM_DEFS` がただ 1 つの正** です。`/api/museum` の `house` で Web に渡し、Web（`web/src/three/scenes/home/house.ts`・`placement.ts` の `roomOrigin`・`doorZones`）はそこから読みます。Web に部屋の座標や大きさを書かないでください（`house` の無い古いサーバーのときだけ、リビング 1 部屋として扱う代わりの値があります）。

- 座標はメートル、Y が上、リビングの中心が世界の原点、床が y = 0。+X が東（右）、+Z が南（手前・入口側）。
- hub の中心は (0, 0)、内寸 10 × 10 m、壁の高さ 3.2 m、壁の厚さ 0.24 m（内の面 ±5.0、外の面 ±5.24）。家具と床の作品の `position` は所属する部屋（`roomId`。今はいつも `hub`）の中心から見た位置で、世界座標 = 中心 + 位置（`world_of`）。家具の上の作品は親の家具の部屋です。部屋は平行移動だけで回しません。
- `ROOM_DEFS` の hub は `doors: &[]` です。出入口の前の決まり（`door_zone`・`DoorPolicy`）はコードに残していますが、今は何も出入口の前にかかりません（テストは出入口のあるテスト用の部屋 `DOOR_ROOM` で行う）。
- 部屋を戻すときは、`ROOM_DEFS` に `RoomDef` を、hub に `doors` を足し、`tools/home-rooms/build_rooms.py`（`ROOMS`・`HUB_WALL_AT_OPEN`）と `check_rooms.py`（`EXPECT`・`ORIGINS`・`DOOR_TO_ROOM`・`HUB_WALL_AT_OPEN`）にも部屋を足して、配置の版の引き上げ・初期配置・総当たり表・番兵のマイグレーションを合わせます。以前の 4 部屋の値（中心 left (−9.24, 0)・right (9.24, 0)・front (0, −9.24)、8 × 8 m、hub の西・東・北の壁の中央の出入口）は git の履歴にあります。`front` を戻すときは −Z 側（北）です（家のキット v1 は `front` を +Z に置く定義なので、キットの値をそのまま持ち込まない）。

家具と作品の置き場所は、DB の `home_layout` に入っている配置 JSON がただ 1 つの正です（行は 1 つだけ）。型と検証は `backend/src/home.rs`、読み書きは `backend/src/home_api.rs` にあります。
配置 JSON は `schemaVersion` 5 です。`rooms` は `hub` だけで（v5 にほかの部屋があれば 400）、`enabled: true`、大きさは 10 × 10 に決まっています（違えば 400）。家具と床の作品の `roomId` は `hub` です。壁紙と床材は部屋ごと（`rooms.hub.wall`・`floor`）。v1〜v4 の配置は `parse_layout` が読むときに v5 に上げ、起動時の `ensure_layout` が保存し直します（`[Home] 配置を v5 に昇格しました (schemaVersion 4 から)`）。上げるときは、消した部屋（`LEGACY_ROOM_IDS`：`left`・`right`・`front`）にあった家具・床の作品と、その家具の上の作品を外します（`drop_legacy_rooms`）。外した作品は起動時の `reconcile` が、リビングに空きがあれば置き直し、無ければ「飾っていない」に戻します。v3（hub が 8 × 8 の 4 部屋）は、さらに壁から 0.6 m 以内の家具と床の作品を、広がった分（1 m）だけその壁の方へ動かします（`widen_from_v3`。ほかの物は動かさないので、新しく重なる物は出ない）。v1・v2（リビングだけ）の物はすべて hub にあり、同じように上げます。列 `home_layout.schema_version`（マイグレーション 007）にも保存した配置の版が入ります。
**部屋の大きさや数を変えるときは、`ROOM_DEFS`・建物の GLB（`tools/home-rooms/build_rooms.py` で作り直す）・配置を上げる処理（`widen_from_v3`・`drop_legacy_rooms` のような版の引き上げ）・初期配置・総当たり表・古いサーバーを止める番兵のマイグレーション（008・009 のような）を一緒に変えてください。**
作品を飾る・外す・消す処理も、この配置 JSON を書き換えます。`artworks.slot_id` には配置 JSON の作品の id（`art-xxxxxxxx`）が入り、保存のたびに配置 JSON に合わせます。
作品の大きさは、GLB から測った実寸（`artworks.model_width`・`model_height`・`model_depth`、m。マイグレーション 006）で決まります。登録のとき・編集でモデルを作り直したとき・seed が登録するときに GLB を測り（`glb::measure_glb`）、寸法の無い行は起動時に GLB を測って埋めます（`artworks::backfill_model_sizes`。ログは `[Artwork] model sizes: measured …`）。測れなかった作品（NULL）は、今までどおり置き場所の枠（面の `art_fit`、床は `FLOOR_ART_FIT`）をそのまま作品の大きさとして扱います。

- 家の建物の GLB：部屋ごとに `backend/static/models/rooms/<部屋 id>.glb`。今は `hub.glb` だけ（出入口の無い 4 面の壁。フォルダは環境変数 `HOME_ROOM_MODELS_DIR` で変えられる）。今入っているのは `tools/home-rooms/build_rooms.py` で作った **開発用のシェル** で、本番の GLB は [docs/house-assets.md](docs/house-assets.md) の仕様で作ってもらい、同じ名前で置き換えます。起動時に `media/museum/room-<部屋 id>-<版>.glb` にして `house.rooms[].model_url` で配信します。ファイルが無い部屋は `model_url` が null（警告を出して起動する）。
- 部屋ごとの GLB にする前の `backend/static/models/home-empty.glb`（8 × 8 m のリビングだけ。部屋を広げる前の大きさのまま）は残しています。`MUSEUM_MODEL_PATH` の既定値で、`/api/museum` の `model_url` として前の版の Web のために返します。今の Web は `house` があれば使いません。
- 家具の GLB・壁紙と床材のテクスチャ・家具の一覧：`backend/static/home/`（`/home-assets` で配信）。家具の一覧 `catalog.json` と初期配置 `default-layout.json` は、Rust に埋め込んでいます（`include_str!`）。
- サンプルの作品 13 点：`backend/static/atelier/`。起動時に `backend/src/seed.rs` が登録して、空いている棚や机に飾ります。
- 博物館のころの GLB（高画質版の `museum-walk.glb` と、以前の管理画面でアップロードした 3 つ）と、それを作る Blender のスクリプト（`tools/walk-stage/`）は `feat/home-stage` で消しました。git の履歴にだけあります。博物館の建物 `sample.glb` も消しました。

3D の表示は Web（three.js）だけで完結させています。3D の機能を足すときは `web/src/three/` に足してください。Unity 版は削除しました。最初のマイグレーションが作る `exhibits` 表は Unity 用の名残で、今は使っていません（適用済みのマイグレーションは書き換えられないので、表は残っています）。
鑑賞モードの照明（`web/src/three/scenes/walk/`）は、強さを Unity の単位で書いて `lighting.tsx` で three.js の単位に換算する決まりです。コメントに出てくる「Unity」はこの単位と、もとにした Unity 版の考え方のことです。
Web の鑑賞モード（`/museum/walk`）のはじめの位置・歩き方・照明は `web/src/three/scenes/walk/stagePreset.ts` の `HOME_STAGE` にあります。詳しくは [docs/walk.md](docs/walk.md) を見てください。
Web の模様替え（`/home/edit`）は `web/src/pages/HomeEdit.tsx`（下書き・元に戻す・自動保存・追加とテーマのシート・部屋の切り替え。切り替えは `house.rooms` が 2 部屋以上のときだけ出すので、今は出ない）と `web/src/three/scenes/HomeEditScene.tsx`（3D とドラッグ・選んだ部屋へのカメラ）です。変えた配置は `PUT /api/home/layout` で保存します。作品はドラッグで、同じ部屋のほかの家具の面（本棚の段も）や床へ載せ換えられます。物は自分の部屋から出ません。家具の追加・作品の追加（`POST /display` の `room_id`。今は `hub` だけ受け付け、ほかは 400）・テーマは選んでいる部屋（今はリビング）に入ります。壁紙と床材（テーマ）は配置 JSON の `rooms.<部屋 id>.wall`・`floor` で、`web/src/three/scenes/home/theme.ts` が部屋ごとの建物に当てます。仕組みは [docs/frontend.md](docs/frontend.md) の「模様替えの仕組み」を見てください。
家の建物を描くのは `web/src/three/scenes/home/HouseShells.tsx` だけです（`house.rooms` の部屋ごとに `MuseumModel` を 1 つ、`SHELL_<部屋 id>` のグループで部屋の中心へ動かす。今は hub の 1 つ）。

## 起動と確認

- 起動手順は [docs/development.md](docs/development.md) の「起動方法」を見てください。`.env` は `.env.example` をコピーして作ります。
- データベースは、ローカルの PostgreSQL 16（Docker か Homebrew）か、チームで共有する Supabase です。Supabase に移したときの作業の記録は [docs/supabase.md](docs/supabase.md) にあります。
- バックエンドのテスト: `cd backend && cargo test`（ignored の 1 件は総当たり表を作り直すテスト）
- Web のビルド確認: `cd web && npm run build`
- 置き方の判定が Rust と同じかの確認: `cd web && npm run check:placement`（置き方の決まりを変えたときは必須。下の「守ること」）
- 壁紙と床材の当て方の確認: `cd web && npm run check:theme`（`theme.ts`・`catalog.json` の `themes`・`materials`・建物の GLB を変えたとき。材質の作り・上下の継ぎ目・連続して切り替えたときの競合を見る。GLB のある部屋だけを調べ、今は `× 1 部屋（hub）` と出る。隣の部屋の GLB があれば共有する壁の表と裏も見る。ブラウザは使わない）
- 建物の GLB の作りの確認: `python3 tools/home-rooms/check_rooms.py [GLB のフォルダ]`（開発用の GLB を作り直したとき・本番の GLB に置き換えるとき。今は hub だけを調べ、出入口・床のつながり・開いた側・共有の壁の検査は隣の部屋が無いので飛ばす。`ALL CHECKS PASSED` で OK）

Web の構成（画面・共通部品・3D・スタイル）と、変更するときの決まりは [docs/frontend.md](docs/frontend.md) にあります。

## 守ること

- **適用済みのマイグレーションを書き換えない。** `backend/migrations/` の既存ファイルを変えるとチェックサムが変わり、サーバーが `VersionMismatch` で起動できなくなります。変更は新しい番号のファイルで足してください。
- **SQL の改行コードを `.gitattributes` で固定しない。** Windows では CRLF のまま適用済みの環境があり、LF に固定するとその環境で起動できなくなります。詳しくは [docs/supabase.md](docs/supabase.md) の「マイグレーションの改行コード対策」を見てください。
- **写真から GLB を作る処理（`backend/src/glb.rs`）は仮の実装です。** 差し替える前提で扱ってください。
- **置き方の決まり（配置 JSON の検証・作品の大きさ・縁への寄せ方・部屋と出入口）を変えるときは、`backend/src/home.rs` と `web/src/three/scenes/home/placement.ts` を一緒に変える。** 正は `home.rs`（`check_placement`・面の区切り方 `cell_grid`（`pick_spot` もこれで空きを探す）・`art_fit`・作品の大きさ `display_scale`・`placed_size`・縁に寄せる `clamp_to_rect`・`world_of`・部屋の範囲 `room_rect`・出入口の前 `door_zone`（`DOOR_ZONE_WIDTH` 2.54・`DOOR_ZONE_DEPTH` 1.15。今の家には出入口が無いが、部屋を戻すときのために残している）とテスト）です。`placement.ts` は同じ計算（`canPlace`・`cellGrid`・`displayScale`・`placedSize`・`clampToRect`・`worldOf`・`roomRect`・`roomOrigin`・`roomOf`・`doorZones`・`DOOR_ZONE_WIDTH`・`DOOR_ZONE_DEPTH` など）を持ち、各ルールの横に対応する Rust のテストの名前を書いています。部屋の中心・大きさ・出入口の位置は `placement.ts` に書かず、`house`（`ROOM_DEFS`）から受け取ります。片方だけ変えると、模様替えで緑なのに保存で 400 になる（またはその逆）ので、変えたら次の順で確かめてください。面ごとの `art_fit` は Rust が計算して `catalog` の `surfaces` で返すので、Web では計算しません。
  1. `cd backend && cargo test regen_placement_cases -- --ignored` で、総当たり表 `backend/src/testdata/placement-cases.json` を作り直す（リビングだけの表。面 13 × 作品 15（サンプルの 13 点・仮生成の額縁・寸法の分からない作品）× 0° と 90° × 寄せる先 4 = 1,560 件と、hub の床（行に `room`）× 作品 15 × 2 × 寄せる先 6 = 180 件の、計 1,740 件。それに重なり・壁・床の枠・寸法の分からない作品・45°・床の台座との重なり（台座 `f-hub` は (3.2, 0, 3.2)）・台座の上のラグ・以前の出入口の前に置けることの `extra` 10 件。表には `house`（`/api/museum` の `house` と同じ形。今は hub だけで `doors: []`）と `door_zone` が入り、`extra[].moved` が false の行は出入口の前を見ない）。差分が意図どおりかを `git diff` で見る
  2. `cd backend && cargo test`（65 件が通り、1 件は ignored。`placement_cases_match` が表と今の計算を比べる。受け入れ条件は `every_atelier_artwork_fits_every_surface_at_0_and_90_degrees`：サンプルの 13 点が、どの面の中央にも hub の床の中央にも 0° と 90° で置ける）
  3. `cd web && npm run check:placement`（同じ表を `placement.ts` で計算し直して、寄せた位置・倍率・置けるかどうかが 1 件も違わないこと）
- **出入口の前（`door_zone`）は、保存のときに「新しく置いた物・動かした物」だけを調べる。** 今の家には出入口が無いので何も止まりませんが、出入口を戻したときのために仕組みを残しています。`check_placement` の第 3 引数 `DoorPolicy` で決めます。模様替えの保存（`put_layout`）は保存済みの配置と比べた `moved_ids`（位置・向き・部屋・載せ先が変わった物と新しい物）を `OnlyMoved` で渡し、作品を飾るときは置いた作品だけ、起動時の整理・seed・作品を外す・消す・読むときは `Ignore` です。出入口を戻したとき、すでに出入口の前にある家具を読めなくしないためです（4 部屋のころは、v3 の初期配置を上げた配置や共有の配置に、出入口の前にかかる白い台座がありました）。全部の物に出入口の判定をかける変更をしないでください。Web の `canPlace` は `ctx.house` を渡すと候補（いつも動かした物）に出入口の判定をします。
- **部屋をまたぐ判定はしない。** 今はリビングだけですが、部屋を戻したときも、床の物の重なりは同じ部屋の中だけで比べます。壁の範囲は部屋ごと（hub は ±4.88）です。
- **作品を置ける面（`catalog.json` の `surfaces`）は、家具の GLB から測った平らな範囲。** 家具のモデルを差し替えたら測り直してください（天板の丸い縁や、本棚の本・かごの場所が変わるため）。`topAnchor` は家のキットの値なので変えません。面を変えたら `cargo test`（共有配置のフィクスチャ `shared_layout_fixture_validates` を含む）で、今の配置が読めることを確かめてください。面は総当たり表にも入っているので、上の 1〜3 で表も作り直します。
- **保存されている配置が検証に通らないとき、配置全体を初期化しない。** `home_api.rs` は `home::repair_layout` で置けない作品だけを外します（起動時は保存し直し、`reconcile` が置き直す）。チームで共有の DB を使うので、置き方の決まりを広げる変更（新しい面など）は、古いサーバーが読んでも配置が消えないよう、この仕組みが全員の手元に入ってから共有の DB で使ってください。
- **新しいマイグレーションを共有の DB で使うときは、先に全員が最新を pull してサーバーをビルドし直し、古いサーバーを止める。** 手元に無いマイグレーションが適用された DB では、古いビルドは `migration failed: VersionMissing(番号)` で起動できません。`007_home_rooms.sql`（4 部屋。v3）・`008_wider_rooms.sql`（部屋を広げた。v4）・`009_single_room.sql`（リビングだけにした。v5。古いビルドは `VersionMissing(9)` で止まる）は、これを使った番兵も兼ねています（古いサーバーは新しい版の配置を読めず、初期配置に戻して保存してしまうため）。006（作品の実寸）より前のサーバーは、実寸でしか置けない配置を読むと `repair_layout` でその作品を外します。
- **壁紙と床材の名前（`home.rs` の `WALLS`・`FLOORS`）を足すときは、`web/src/api/types.ts` の `WallFinish`・`FloorFinish`、`theme.ts` の `WALL_TEXTURE`・`FLOOR_TEXTURE`、`HomeEdit.tsx` の `WALL_LABEL`・`FLOOR_LABEL`、`catalog.json` の `materials`・`themes` を一緒に変える。** 古いサーバーは知らない名前の配置を読めず、起動時に配置全体を初期配置に戻して保存します（`parse_rooms` が Err、`repair_layout` は作品しか外せない）。新しい名前は、全員が更新して古いサーバーを止めてから共有の DB で使ってください（[docs/development.md](docs/development.md) の「共有のデータベースを使うとき」）。内装セットは `backend/static/home/textures/finish-pack/`（10 種・6 テーマ）です。内装セットの色の画像は仕上がりの色なので、白壁 `plaster` の色の補正（`theme.ts` の `BASE_COLOR`）を掛けないでください。素材セットの空室 GLB（以前の 1 部屋の見本）で `rooms/` の建物を上書きしないでください。
- **建物の GLB を node で読むときは、アプリと同じ `three-stdlib` の `GLTFLoader` を使う。** three の `examples/jsm`（r186）の `GLTFLoader` は `extras.pivot` を回転の中心として読み替えるので、キットの `extras.pivot`（`"bottom-center"` の文字）で壁や床のノードの位置が NaN になります（drei の `useGLTF` は `three-stdlib` を使うので、アプリは大丈夫）。
- **`backend/static/models/home-empty.glb` を上書き・削除しない。** 今の家の建物は `backend/static/models/rooms/hub.glb` で、別のファイルです。`home-empty.glb` は前の版の Web が `model_url` で読むリビングだけの GLB として残しています。建物を差し替えるときは `rooms/` の同じ名前のファイルを置き換えます（仕様は [docs/house-assets.md](docs/house-assets.md)。開発用は `tools/home-rooms/build_rooms.py` が作り直す）。
- **家具と作品を 3D に描くのは `web/src/three/scenes/home/HomeObjects.tsx` だけ。** ホーム・おうちの中・マップ・鑑賞モード・模様替えのどれも、これを使います。部屋ごとに `ROOM_<部屋 id>` のグループを部屋の中心へ動かし、その中に配置 JSON の位置のまま置きます（`house` を props で渡す）。画面ごとに別の描き方を作らず、必要なら props を足してください（模様替えの `onObjectPointerDown`・`previewTransform` のように）。GLB の材質は全部の物・全部の画面で共有しているので、選んだ印などで材質の色を変えないでください（模様替えは床に板を敷いて印にしています）。家の建物を描くのは `HouseShells.tsx` だけです。
- **配置 JSON だけは camelCase。** 家のキットの JSON と同じ形にするためです。ほかの API の項目は snake_case のままにしてください（`web/src/api/types.ts` の `Layout` にも書いてあります）。
- **初期配置（`default-layout.json`）は、`home_layout` の行が無いときだけ入る。** 書き換えても、すでに DB にある配置は変わりません。初期配置は v5 で、`rooms` は hub だけ、家具 11 個もすべて hub です（出入口はありません）。v3 のころの初期配置は、版を上げるテストのために `backend/src/testdata/default-layout-v3.json` に残しています。`cargo test`（`default_layout_validates`）で検証され、置き場所が 17（すべて hub）であることも確かめています。
- **`backend/static/atelier/` を消すと、seed は止まる。** フォルダが無ければ、seed は何もせずに終わります。フォルダを残したまま作品だけを Web で削除すると、次の起動で登録し直されます。
- **作品の GLB は、テクスチャを 1024px 以下に縮めてから入れる。** 2048px のままだと、スマホで GPU のメモリが足りなくなります。手順は [backend/static/atelier/README.md](backend/static/atelier/README.md) にあります（`@gltf-transform/cli resize`）。
- **Web の画面から `web/src/three/scenes/` の中を直接 import しない。** 必ず `import { ... } from '../three'`（`web/src/three/index.tsx`）を使います。直接読むと three.js が最初に読み込まれ、表示が遅くなります。
- **Web の CSS は、1 か所でだけ使うものはその `.tsx` の隣の同じ名前の `.css` に、2 か所以上で使うものは `web/src/styles/` に書く。** 色は `web/src/styles/tokens.css` の CSS 変数を使い、直接書かない。
- **`.env` や接続文字列、パスワードをコミットしない。**
- **コミットメッセージや PR の説明に、AI ツールの署名（`Co-Authored-By` や「Generated with」など）を入れない。**

## 未対応・予定

- 部屋の大きさの変更・増築の UI はありません。リビングの位置と大きさは `ROOM_DEFS` で決まっていて、配置 JSON で違う大きさを送ると 400 です。左・右・前の部屋を戻すときの手順は上の「構成」にあります。
- 部屋を戻したときも、物を部屋をまたいでドラッグすることはできません（模様替えでは、物は自分の部屋の中でだけ動く）。配置 JSON で `roomId` を変えて保存することはできます（出入口の判定では動かした物として扱う）。
- 本番の建物 GLB はまだありません（今は開発用のシェル）。仕様は [docs/house-assets.md](docs/house-assets.md) です。
- ログイン画面（デザイン案の①）は未実装です。
