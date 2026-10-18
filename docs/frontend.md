# Web（フロントエンド）の構成

> [!NOTE]
> `web/` を初めて触る人向けに、どこに何があるかと、変更するときの決まりをまとめています。

## 全体の考え方

- **処理は Rust、Web は表示だけ。** 日付の整形（`date_long` など）、画像のサムネイル、背景色（`tint`）、作品を置く世界座標、飾れる数などは、すべて API が計算して返します。家具と作品をどこに置くか（配置 JSON）も、検証と保存は Rust がします。家の部屋の形（部屋の中心・大きさ・出入口・建物の GLB。今はリビングだけで出入口なし）も、Rust の `home.rs` の `ROOM_DEFS` を `/api/museum` の `house` で受け取り、Web には数値を書きません。Web 側で計算を足したくなったら、まず `backend/` に置けないかを考えてください。
  例外は ⑫ 模様替えの「置けるかどうか」の判定です。ドラッグ中に緑・赤をすぐ出すために、Rust の `home.rs` と同じ計算（置けるかどうか・作品の大きさ・縁への寄せ方・部屋ごとの範囲と出入口の前）を `three/scenes/home/placement.ts` にも持っています（保存のときは Rust がもう一度検証します）。同じ計算かどうかは `npm run check:placement` で確かめます（下の「確認」）。
- **見た目とコードは隣に置く。** 1 つの部品や画面でだけ使う CSS は、その `.tsx` と同じ名前の `.css` に書きます（`NavBar.tsx` と `NavBar.css`）。2 か所以上で使うものだけを `styles/` に置きます。
- **スタイルは普通の CSS です。** Tailwind CSS は使っていません。色やフォントは CSS 変数（`styles/tokens.css`）でまとめています。
- **主なライブラリ：** React 19、React Router（画面の切り替え）、TanStack Query（API の取得とキャッシュ）、three.js（3D。React からは `@react-three/fiber` と `@react-three/drei` 経由で使う）。

## どこを触ればいい？

| やりたいこと | 触るファイル |
|---|---|
| ある画面の見た目や中身を変える | `pages/画面名.tsx` と `pages/画面名.css` |
| ある部品（上部のバー、下部タブなど）を変える | `components/部品名.tsx` と `components/部品名.css` |
| 色やフォントを変える | `styles/tokens.css` |
| ボタンの見た目を変える | `styles/buttons.css` |
| 画面を足す | `pages/` にファイルを作り、`App.tsx` に `Route` を 1 行足す（下の「よくある変更」） |
| API の項目を画面で使う | Rust の DTO → `api/types.ts` → 画面 |
| 3D のカメラの位置や動きを変える | `three/scenes/〇〇Scene.tsx` |
| 3D の照明や背景色を変える | `three/scenes/Stage.tsx`（⑪ 鑑賞モード は `three/scenes/walk/lighting.tsx`） |
| ⑪ 鑑賞モード の歩き方・はじめの位置・照明の数値 | `three/scenes/walk/stagePreset.ts` の `HOME_STAGE`（詳しくは [walk.md](walk.md)） |
| 3D で家具と作品をどう置くか | `three/scenes/home/HomeObjects.tsx`（置き場所そのものは配置 JSON（DB の `home_layout`）で、⑫ 模様替えで変えると `PUT /api/home/layout` で保存される） |
| 家の建物（部屋ごとの GLB）をどう並べるか | `three/scenes/home/HouseShells.tsx`。部屋の位置・大きさは `house.rooms`（Rust の `ROOM_DEFS`）なので、部屋そのものを変えるときは `backend/src/home.rs` を変える |
| 家全体の範囲・カメラに家を収める距離・出入口のある壁の向き（今は出入口が無いので空） | `three/scenes/home/house.ts`（three.js を使わない小さな関数） |
| 置けるかどうかの決まり（壁との間隔・重なり・出入口の前・面の区切り方・作品の大きさ） | Rust の `backend/src/home.rs` と、同じ計算の `three/scenes/home/placement.ts`。**必ず両方を合わせて変え、`npm run check:placement` で確かめる**（下の「模様替えの仕組み」） |
| ⑫ 模様替えの操作（部屋の切り替え・選ぶ・ドラッグ・回す・消す・元に戻す・自動保存・追加とテーマのシート） | 下書きと保存・部屋の切り替えは `pages/HomeEdit.tsx`、3D とドラッグ・選んだ部屋へのカメラは `three/scenes/HomeEditScene.tsx` |
| 壁紙・床材（テーマ）の見え方 | `three/scenes/home/theme.ts`（テーマの一覧とテクスチャは `backend/static/home/catalog.json` の `themes`・`materials`。内装セットの画像は `backend/static/home/textures/finish-pack/`。確かめるのは `npm run check:theme`） |
| 手前の壁のカット（ドールハウスの見せ方。部屋が 2 つ以上あるときは部屋どうしの間の壁も） | `three/scenes/home/cutaway.ts`（手前の 2 面を選ぶ `facingSides` と、隠す `applyCutaway`）。カメラに合わせて毎フレーム当てるのは `three/scenes/home/HouseShells.tsx` |
| 画面遷移のアニメーションを変える | `nav.ts` と `nav.css` |

## 読む順番

初めて読むときは、この順に開くと全体がつかめます。

1. `src/main.tsx`：起動するだけのファイル。全体のスタイルを読み込み、`App` を描画します。
2. `src/App.tsx`：URL と画面の対応表です。どの URL でどの画面が出るかが 1 か所にまとまっています。
3. `src/pages/Room.tsx`：おへやの画面。API からデータを取り（`api/`）、共通部品（`components/`）と 3D（`three/`）を並べる、という画面の基本の形が分かります。

## ディレクトリ

```
web/
├── index.html          フォントの読み込み、/api/ages の先読み
├── vite.config.ts      開発サーバーの設定（/api・/media・/home-assets を 8080 番の Rust に中継）
├── tsconfig.check.json npm run check:placement 用（placement.ts だけを node_modules/.cache/placement-check/ に出力する）
├── scripts/
│   └── check-placement.mjs  置けるかどうかの判定を、Rust と同じ総当たり表で照合する（npm run check:placement）
└── src/
    ├── main.tsx        起動（全体のスタイルを読み込み、App を描画する）
    ├── App.tsx / .css  画面の一覧（URL → 画面）と、全画面共通の部品。.app はアプリの外枠
    ├── nav.ts / .css   画面遷移のアニメーション（useNav）
    ├── icons.tsx       アイコン（SVG）
    ├── api/            サーバー（Rust）とのやりとり。入口は api/index.ts
    ├── pages/          画面（1 画面 1 ファイル。見た目があれば同じ名前の .css）
    ├── components/     共通部品（1 部品 1 ファイル。見た目があれば同じ名前の .css）。入口は components/index.ts
    ├── three/          3D 表示。入口は three/index.tsx
    │   └── scenes/     three.js を使う重いコード（遅延読み込み。画面から直接 import しない）
    └── styles/         2 か所以上で使うスタイル。入口は styles/index.css
```

画面から読み込むときは、フォルダの入口を使います。

```ts
import { useMuseum } from '../api'
import { NavBar, Screen } from '../components'
import { HomeScene, StageShell } from '../three'
```

## 画面（`pages/`）

番号はデザイン案の番号です（⑪ と ⑫ はデザイン案のあとに足した画面）。①ログインは未実装です。

| 番号 | 画面 | URL | ファイル | 開き方 |
|---|---|---|---|---|
| ② | ホーム（年齢のチップと、その年齢のおへやを積み上げた 3D の建物） | `/`（`?age=年齢`） | `Home.tsx` / `.css` | タブ |
| ②' | おへや（画面いっぱいの 3D のおへや。はじめはリビングの中の近景で、引けば家全体。ドラッグで見回し、放っておくとゆっくり回る） | `/rooms/:roomId` | `Room.tsx` / `.css` | push（② の階のラベルか「はいる」、⑦ のおへやの行から） |
| ③ | 作品を追加 | `/add` | `AddArtwork.tsx` | モーダル |
| ④ | 3D プレビュー | `/artworks/:id/preview` | `ArtworkPreview.tsx` / `.css` | モーダル |
| ⑤ | おうちの中 | `/museum`（`?focus=作品ID` / `?room=部屋ID`） | `MuseumView.tsx` / `.css` | push |
| ⑥ | 作品の詳細（下に「おもいで」：写真・動画・声の記録） | `/artworks/:id` | `ArtworkDetail.tsx` / `.css` | push |
| ⑦ | おうちのマップ（全部の年齢のおへやの一覧） | `/map` | `MapView.tsx` / `.css` | タブ |
| ⑧ | 作品一覧（種類・年・月で絞り込む。はじめは「すべて」で、全部の作品を見出し無しで 3 列。年を選ぶと、その年の作品を月ごとの見出しで区切って出し、月のダイヤルが現れる（横にスクロールして真ん中の枠に止まった月を選ぶ。押してもよい。`Collection.tsx` の `MonthScroller`）。月を選ぶとその月だけ。並びの上に、見ている範囲と点数。作品の下に作ったときの年齢「5さい 4か月」） | `/collection`（`?category=種類`・`?month=2026`（その年）・`?month=2026-10`（その月）。省くか、その種類の作品が無い年・月ならすべて） | `Collection.tsx` / `.css` | タブ |
| ⑨ | 作品を編集 | `/artworks/:id/edit` | `EditArtwork.tsx` | モーダル |
| ⑩ | 設定 | `/settings` | `Settings.tsx` / `.css` | タブ |
| ⑪ | 鑑賞モード（家の中を一人称で歩く。PC はキーボードとマウス、スマホはタッチ） | `/museum/walk`（`?room=おへやID`） | `MuseumWalk.tsx` / `.css` | push（②' の「歩く」、⑤ の「⋯」、⑫ の「鑑賞モードへ」から） |
| ⑫ | 模様替え（家具と作品を動かす・回す・消す・足す、壁の家具を上げ下げする、テーマを選ぶ） | `/home/edit`（`?room=おへやID`） | `HomeEdit.tsx` / `.css` | push（②' の「模様替え」、⑤ の「⋯」から） |

- 「開き方」は画面遷移アニメーションの種類です（後述の「画面遷移」）。
- 各ファイルの先頭に、番号・URL・開き方を書いています。
- `.css` がない画面は、共通のスタイル（`styles/`）と部品だけでできています。
- ② は、上に館名とアバター（⑩ へ）、その下に年齢のチップ（`/api/ages` の `ages`。選んだ年齢は `?age=` に入れ、`nav.replace` で切り替える。はじめは今の年齢、そこに作品が無ければ作品のあるいちばん大きい年齢）、「4さいのおへや 8（しまってある 1）」の見出し、積み上げの 3D（`StackScene`。`/api/ages/{age}`）を並べます。3D の各階の左に「4さいのおへや 2（数）›」のラベルが出て、押すと ②' へ入ります。おへやが 1 つのときは下に「はいる」も出ます。「おへやを足す」（おへやの無い年齢では「おへやをつくる」）は `POST /api/ages/{age}/rooms` です。いちばん上の階に作品を飾っていなければ、その下に「〇〇を消す」が出て、確かめのシートのあと `DELETE /api/rooms/{id}` で消します。3D は画面の残りの高さを使って伸び縮みし（`.home-screen` を縦の flex にする）、ボタンはいつも下部タブの上に収まります。お誕生日が未設定のときは、⑩ への案内を出します。作品の追加は下部タブの「＋」です。
- ②' は画面いっぱいの 3D のおへや（`HomeScene`）です。はじめはリビングの中の近景（手前に床ランプ、中央にソファとローテーブル、奥に棚）で、ピンチやホイールで引けば家全体まで見えます。3D の上に浮かぶ UI は 2 段だけで、上に戻る（② の `?age=` へ）とおへやの名前、下（`.room-dock`）に飾っている数と、丸いボタンの「歩く」（⑪）・「模様替え」（⑫）があります。どちらもこのおへやを `?room=` で渡します。作品をタップすると ⑥ へ進みます（家具や床のタップは何もしない）。
- ⑪ 鑑賞モード と ⑫ 模様替え は、PC の広い画面ではスマホの枠をやめてウィンドウいっぱいに広げます（`MuseumWalk.css`・`HomeEdit.css`）。⑫ の右上の「鑑賞モードへ」は、PC でもスマホでも出します（⑪ はスマホではタッチで歩く。[walk.md](walk.md) の「スマホ（タッチ）」）。
- ⑤ ⑪ ⑫ の `?room=` はおへやの id です（`useMuseum({ roomId })` で `/api/museum?room=` を取る）。省くとサーバーが選ぶおへや（今の年齢のいちばん下の階）です。⑥ と ④ からの「おうちで見る」は、その作品のおへや（`room_id`）を付けて ⑤ へ進みます。⑫ の「追加→作品」には、そのおへやの年齢の作品だけが出ます。
- ⑦ は、年齢ごと（大きい年齢から）に、見出し（「4さい 8 / 8 点」）と「ホームで見る」（② の `?age=` へ `nav.tab`）、その年齢のおへやの行（最近飾った作品のサムネイル・名前・何階か・飾っている数 / 置き場所の数）を並べます。行を押すと ②' へ進みます。
- ⑩ のプロフィールのシートで、子どものお誕生日（`child_birthday`）を変えられます。変えると、サーバーが作品を年齢のおへやへ置き直します。

## 共通部品（`components/`）

画面からは `import { NavBar, Screen } from '../components'` のように、入口の `components/index.ts` から読み込みます。

| ファイル | 部品 | 内容 |
|---|---|---|
| `Screen.tsx` / `.css` | `Screen` | 各画面の外枠（縦にスクロールする領域）。下部タブのある画面は `tabbar` を付ける |
| `NavBar.tsx` / `.css` | `NavBar` | 上部のバー。`large` で大きなタイトルを出し、スクロールすると小さくなる |
| `TabBar.tsx` / `.css` | `TabBar` | 下部タブと「＋」ボタン。`App.tsx` に 1 つだけ置き、タブの画面でだけ表示される |
| `TLink.tsx` | `TLink` | 遷移アニメーション付きのリンク |
| `GlassButton.tsx` / `.css` | `GlassButton` | 丸いガラスのボタン。3D や画像の上でだけ使う |
| `ActionMenu.tsx` / `.css` | `ActionMenu` | 「⋯」から開くメニュー |
| `Sheet.tsx` / `.css` | `Sheet` | 下から出るシート。つまみを下にドラッグすると閉じる |
| `Segmented.tsx` / `.css` | `Segmented` | 切り替えボタン（作品の種類など） |
| `Toast.tsx` / `.css` | `ToastProvider` / `useToast` | 上から降りてくるお知らせ |
| `Img.tsx` | `Img` | 画像。読み込みまでは API の `tint` を背景に敷く。見た目（`.thumb`）は `styles/common.css` |
| `ArtworkThumb.tsx` / `.css` | `ArtworkThumb` / `ThumbSkeletons` | 作品のサムネイルと、読み込み中の仮表示。`meta="age"` で、日付の代わりに作ったときの年齢（`age_month_label`。誕生日が無ければ日付）を出す（⑧）。`onSelect` を渡すと、詳細へのリンクではなく押すとそれを呼ぶボタンになる（⑫ の「追加」のシート） |
| `Loading.tsx` / `.css` | `Spinner` / `Busy` / `StageFallback` | 読み込み中の表示 |
| `ArtworkForm.tsx` / `.css` | `ArtworkForm` | 作品の登録・編集フォーム（③と⑨で共通） |
| `MemorySection.tsx` / `.css` | `MemorySection` | ⑥ の「おもいで」。写真と動画は 3 列のタイル（動画は最初のコマと長さ）、声はリストの行（その場で再生）。「＋ 追加」のシートから写真・動画・音声ファイルを選ぶ（1 つずつ順に送り、進み具合を出す）・声を録音する。スマホなど指で操作する端末（`pointer: coarse`）では「写真をとる」「動画をとる」も出し、その場でカメラを開く（`capture="environment"` の入力。PC では効かないので出さない）。「⋯」でひとことを変える・消す |
| `MemoryViewer.tsx` / `.css` | `MemoryViewer` | おもいでの写真と動画を画面いっぱいで見る（左右の送り・なぞる・← →・Esc）。この端末で再生できない動画は、ダウンロードのリンクを出す。シートを上に重ねるため z-index は 40 |
| `VoiceRecorder.tsx` / `.css` | `VoiceRecorder` | 声を録音するシート（`MediaRecorder`。`audio/mp4` を優先、だめなら webm・ogg。3 分まで。止めると聞き直せる）。マイクが使えない（https か localhost でない・許可しない）ときは理由を出し、音声ファイルを選ぶ方へ |
| `ErrorBoundary.tsx` | `ErrorBoundary` | 子の描画中のエラーを受け止めて、代わりの表示を出す（⑪ で 3D を読み込めなかったとき） |
| `usePresence.ts` | `usePresence` | 開閉アニメーション用。部品の中だけで使う |

## 3D（`three/`）

three.js はとても大きい（約 290 KB、gzip）ので、最初の読み込みには含めず、3D が必要になったときに別ファイルとして読み込みます。
そのため、`three/` は「画面が使う入口」と「three.js を使う重いコード（`scenes/`）」に分けています。

| ファイル | 内容 |
|---|---|
| `index.tsx` | **入口。画面はここだけを import する。** `HomeScene` などを遅延読み込みで渡す。`warmUp3D` で家の建物の GLB（部屋ごと。`shellUrlsOf`）・家具の GLB（`furnitureUrlsOf`）と 3D のコードを先読みする。模様替えの操作（`addFurniture`・`rotateObject`・`removeObject`・`namesFromSlots`・作品の実寸を引く `sizesFromSlots`）と、部屋の定義を読む関数（`houseRoomsOf`・`shellUrlsOf`・`hasHouseModel`）、⑪ の操作の種類（タッチの端末か。`isTouchDevice`）と仮想スティックの大きさ（`TOUCH_STICK_RADIUS`）は three.js を使わないので、`scenes/home/placement.ts`・`scenes/home/house.ts`・`scenes/walk/inputMode.ts` からそのまま渡している（数 KB） |
| `StageShell.tsx` / `.css` | 3D を表示する枠。3D が描画されるまで「準備しています…」を重ねる。画面遷移のアニメーション中は 3D（`children`）をまだ置かない（`nav.ts` の `useNavSettled`。下の「画面遷移」）。three.js は使わない |
| `walkPose.ts` | ⑪鑑賞モード で、歩いている位置と向きを覚えておく。詳細画面から戻ったときに続きから歩くため（three.js は使わない） |
| `scenes/index.ts` | 重いコードのまとめ役。ここから辿れるものが 1 つの遅延読み込みファイルになる |
| `scenes/Stage.tsx` | three.js のキャンバスと照明、背景色。②②'④⑤⑫ の 5 つの 3D 画面の土台（⑪ の照明は `scenes/walk/lighting.tsx`） |
| `scenes/models.tsx` | GLB を読み込んで置く部品：家の建物 1 部屋分（`MuseumModel`。壁のカットは `HouseShells` がカメラに合わせて当てるので、ふだんは `cutaway = false` で触らない（`true` にすると `cutSides` の向きを固定でカットする）。`theme`（配置 JSON の `rooms[部屋]`）と `materials`（`catalog.materials`）で壁紙と床材を変える。複製した建物は行列を固定するので、部屋の位置へは親のグループで動かす）、作品を置く（`FittedModel`。`scale` を渡すとその倍率で置き、渡さなければ範囲 `fit` に収める）、先読み（`preloadModel`）。`MuseumModel` は画面から直接使わず、`HouseShells` から使う |
| `scenes/home/HouseShells.tsx` | 家の建物を部屋ごとに置く。家の建物を描くのは、どの 3D 画面でもここだけ。`house.rooms` の部屋ごとに `MuseumModel` を 1 つ、部屋の中心（`origin`）へ動かした `SHELL_<部屋 id>` のグループに入れる。壁紙と床材は部屋ごと（`layout.rooms[部屋]`。⑫ では下書き）。隣の部屋と壁を共有するときは、共有する壁の隣の部屋に向いた面（`userData.faceRoom`）に、その部屋の壁紙を当てる（どの建物にも `faceThemes` = `layout.rooms` を渡す。今のリビングだけの家には、この面は無い）。`model_url` が null の部屋は描かない（console に 1 回だけ出す）。`cutaway` は `false`（⑪。カットに触らない）・`true`（カメラの側の 2 面。④）・`'house'`（さらに出入口のある壁をいつも。家全体を見下ろす ②'⑤⑫。今は出入口が無いので、カメラの側の 2 面だけ）。カメラの側の 2 面は、中の `CutawayFollower` が毎フレーム部屋ごとに、部屋の中心から見たカメラの位置で選び（`facingSides`。軸の近くでは 0.4 m のゆらぎ止め）、変わった部屋だけ `applyCutaway` で当て直す（② は変化があるときだけ描くので、当て直したら描き直しを頼む）。建物を読み込んだとき・テーマを当て直したとき（`MuseumModel` の `onLoaded`）は、その場で当て直す。なので、どの向きから見ても部屋の中が見える。`onReady` は描く建物が全部そろったときに 1 回だけ、`onLoaded` は部屋ごと（部屋の id つき）。`walk` を付けると、`walk_model_url` があればリビングの建物の代わりに使う。`useShells` は描く建物の一覧（⑪ がいくつそろえばよいかを数える） |
| `scenes/home/house.ts` | 部屋の定義（`house`）を扱う、three.js を使わない関数：部屋の一覧（`houseRoomsOf`。`house` の無い古いサーバーでは `model_url` のリビング 1 部屋）、描く建物（`shellsOf`・`shellUrlsOf`・`hasHouseModel`）、部屋と家全体の外形（`roomBounds`・`houseBounds`。内寸 + 壁の厚さ）、出入口のある壁の向き（`doorSidesOf`。家全体を見下ろす画面でいつもカットする。今は空）、カメラに家全体を収める見る先と距離（`frameCenter`・`fitDistance`・`cornersOf`）、壁の高さ `WALL_TOP`（4.2 m）。数値の部屋の定義は書かない |
| `scenes/home/HomeObjects.tsx` | 配置 JSON（`layout`）と家具の一覧（`catalog`）のとおりに、家具と作品を置く。家具と作品を描くのは、どの 3D 画面でもここだけ。家具と床の作品は、部屋ごとの `ROOM_<部屋 id>` のグループ（部屋の中心 `house.rooms[].origin` へ平行移動。`house` を props で渡す。無ければ原点）の中に、配置 JSON の位置（部屋の中の位置）のまま置く。家具は `FURN_<id>`、作品は `ARTWORK_<id>` のグループで、家具の上の作品は家具のグループの子にする（部屋の平行移動は家具に 1 回だけ掛かる）。スマホなど（`pointer: coarse`）では、カメラに近い作品 6 つだけを置く（⑫ では `maxArtworks` で全部置く）。作品の大きさは、`slots` の実寸（`artwork.model_size`）を置き場所の枠（面の `art_fit`、床は `FLOOR_ART_FIT`）に収める倍率を `displayScale` で計算して、`FittedModel` に `scale` で渡す（`slots[].scale` と同じ式。下書きで回した・載せ換えた作品も、保存を待たずにその大きさになる。親の家具が見つからない作品は `slots[].scale` を使う。実寸が分からない作品は `scale` を渡さず、`fit` に収める）。⑫ 用に `onObjectPointerDown`（物を押した）と `previewTransform`（ドラッグ中の仮の位置と向き。作品は載せ換え先の `parentId`・`surface`（床なら `roomId`）も持ち、新しい家具のグループの下（床なら部屋のグループ）に描く）を受け取る。GLB の載り外しのほか、置いた物の位置・向き・部屋が変わったときも `onReady` を呼ぶ（⑪ が当たり判定を作り直す）。`memoryBadges` を付けると、おもいでのある作品（`slots[].artwork.memory_counts`）の上に drei の `Html` で丸い印（声があれば音符と色付き、無ければ動画か写真の印と数）を出し、押すと `onSelect`（②' で使う。`.css` は印の見た目） |
| `scenes/home/cutaway.ts` | 壁の上の部分を隠す（`applyCutaway(root, sides)`。`sides` の向きの壁だけを隠し、ほかは元に戻す。`null` で全部戻す）と、カメラの側の 2 面を選ぶ（`facingSides(dx, dz, prev)`。部屋の中心から見たカメラの位置で、dx > 0 なら東、dz > 0 なら南。`prev` を渡すと 0.4 m のゆらぎ止め）。家の GLB の `userData`（`side`・`role`）を見る。GLB の `cutaway` の印（南東から見るときの向き）は使わない |
| `scenes/home/placement.ts` | 置けるかどうか（`canPlace`。3 つ目の引数 `ctx` に、理由の文言の名前 `nameOf`・作品の実寸 `sizeOf`・部屋の定義 `house` を渡す。`house` を渡すと出入口の前にも置かせない。今の家には出入口が無い）・作品の大きさ（`displayScale`・`placedSize`・`artRect`）・`slots` から作品の実寸を引く（`sizesFromSlots`）・部屋（`roomOrigin`・`roomOf`・部屋ごとの範囲 `roomRect(layout, roomId)`・出入口の前 `doorZones`）・世界座標（`worldOf`。部屋の中心を足す）・面の区切り方（`cellGrid`）・面や部屋の縁に寄せる（`clampToRect`・`clampObject`）と、模様替えの操作（`addFurniture`（部屋を指定）・`rotateObject`・`removeObject`・`replaceObject`）。three.js を使わない純粋な関数だけ。`backend/src/home.rs` と同じ計算で、各ルールの横に対応する Rust のテストの名前を書いている。`npm run check:placement` がこのファイルだけを出力して照合するので、実行時の import は書かない（型も `api/types.ts` から読む） |
| `scenes/home/theme.ts` | 壁紙と床材（テーマ）を家の建物に当てる（`applyTheme`）。`MuseumModel` から呼ばれる |
| `scenes/home/ClampTarget.tsx` | 視点の中心（`OrbitControls` の `target`）を、家の外形（`houseBounds`）から 0.5 m 内側・高さ 0.4〜2.5 m の中に収める。②⑤ で使う |
| `scenes/CameraFlight.tsx` | カメラを目的地へなめらかに移動させる |
| `scenes/HomeScene.tsx` | ②'おへや。画面いっぱいに、カメラの側の壁をカットした家（今はリビングだけ）を出す。はじめはリビングの中の近景：見る先 `LOOK_AT`（リビングの中心の少し北）から向き `DIRECTION`（東のやや南の、壁より上から約 37° 見下ろす）に、決まった距離 `START_DISTANCE`（8 m。画面の縦横では変えない）、画角 56°。手前に床ランプ、中央にソファとローテーブル、奥に棚が入る。ドラッグでぐるりと見回せる（`OrbitControls`。上下の角度は ⑤ と同じ 0.15π〜0.5π、平行移動はしない。視点の中心は `ClampTarget`）。距離は 3.5 m（作品に寄れる）から、全部の部屋の外形が画面に収まる距離（`fitDistance`）まで。引けば家全体まで見える。画面の大きさが変わったら収まる距離を測り直して、離れられる距離とカメラの `far`（いちばん離れても家の奥が切れない長さ）だけを変える。カメラを置くのははじめの 1 回だけで、置き直さない。放っておくとゆっくり自動で回る（`IdleRotate`。`autoRotateSpeed` 0.25 を 60 fps 換算で使い、1 周 240 秒。触ると止まり、最後の操作から 6 秒で再開。ページが隠れている間と「視差効果を減らす」の端末では回さない）。作品をタップすると `onSelect` |
| `scenes/MuseumScene.tsx` | ⑤おうちの中。カメラの側の壁をカットした家（今はリビングだけ）を、ドラッグでぐるりと見回す（水平の向きに制限は無い）。はじめはリビングを南東から見渡す位置。`?focus=` ならその作品の正面へ寄る。`?room=` ならその部屋の中心へ寄る。視点の中心は家の外形の中だけを動く（`home/ClampTarget.tsx`）。作品をクリックで詳細へ |
| `scenes/StackScene.tsx` / `.css` | ②ホームの積み上げの建物。ある年齢のおへや（`/api/ages/{age}` の `rooms`。1 階から）を、1 階分の高さ `FLOOR_PITCH`（壁の高さ 4.2 m + 床の下の土台 0.2 m。上の階が下の階の壁の上にそのまま乗る）ずつ上へずらしたグループに入れて縦に重ね、南東の斜め上（水平から約 16° の浅い角度。天井が高いので、上の階の床の下から下の階の中が奥まで見える）から、全部の階が収まる距離（`fitDistance`）で見下ろす。建物・家具・作品はほかの画面と同じ `HouseShells`（`cutaway`。カメラの側の 2 面をカット）と `HomeObjects` で、階ごとに `museumOf` で 1 おへや分の `Museum` の形にして渡す。階ごとに drei の `Html` で、建物の南西の角に名前と数のラベル（`.stack-label`。押すと `onRoom`）を出す。ドラッグで回せる（`OrbitControls`。平行移動なし）。変化があるときだけ描く（`frameloop="demand"`）。`onReady` は全部の階の建物がそろったとき |
| `scenes/PreviewScene.tsx` | ④3D プレビュー。リビングの中心（`house` の `hub` の `origin`）の台座の上で作品が回る（家具は置かない。建物は `house.rooms` の全部の部屋（今はリビング）を置き、手前（カメラの側）の壁だけカットする） |
| `scenes/WalkScene.tsx` | ⑪鑑賞モード。家の中を一人称で歩く（今はリビングの中だけ。出入口のある家なら、くぐってほかの部屋へも行ける）。照準の先の作品を選ぶ。家具にも当たる。天井とダウンライトは部屋ごと。PC はキーボードとマウス（`walk/FirstPersonControls.tsx`）、タッチの端末（画面が `touch` で渡す）は仮想スティックとなぞる操作（`walk/TouchControls.tsx`）で、タッチのときは画面の仕上げなどを省いた軽い表示にする。部品は `scenes/walk/` にあり、説明は [walk.md](walk.md) |
| `scenes/HomeEditScene.tsx` | ⑫模様替え。カメラの側の壁をカットした家（今はリビングだけ）を斜め上から見下ろし（はじめは南東から。ドラッグでどの向きにも回せる）、家具や作品を押して選ぶ・ドラッグで動かす。画面で選んだ部屋（`roomId`）へカメラが寄る（`RoomCamera`。はじめは南東から、切り替えたときはそのとき見ている向きのままで、距離は部屋の大きさの比で伸び縮みさせる）。どの部屋の物も選べるが、物は自分の部屋から出ない。作品は、ポインタの先の同じ部屋の家具の面（天板・本棚の段）か床へ載せ換えられる。選んだ物の下に板を敷き、置ける場所なら緑、置けない場所なら赤にする。出入口のある部屋では、ドラッグ中にその部屋の出入口の前を薄い赤で示す（`DoorZones`。今は出入口が無いので出ない）。R で 90° 回す、Delete / Backspace で消す、Esc で選ぶのをやめる。部屋を切り替えるとドラッグをやめる |

- **画面から `three/scenes/` の中を直接 import しないでください。** 必ず `import { ... } from '../three'` を使います。直接読むと three.js が最初の読み込みに混ざり、最初の表示が遅くなります。
- ビルドしたときに、`dist/assets/` の `scenes-〇〇.js` が約 1.2 MB（gzip で約 310 KB）、`index-〇〇.js` が約 350 KB のままなら、正しく分かれています。
- `/api/museum` の `slots` は、配置 JSON から Rust が計算した世界座標です（飾っている作品だけ。部屋の中心込み）。カメラを作品に寄せる、作品を照らす、近い作品を選ぶ、などに使います。家具は `layout` と `catalog` から `HomeObjects` が置きます。家具の上の作品は、配置 JSON の位置（載せている面の中心から。面は `catalog` の `surfaces`）に置きます。
- `/api/museum` の `house` は家の形（部屋ごとの `origin`・`size`・`doors`・`cutaway`・建物の GLB の `model_url`、壁の厚さ）です。今の `rooms` は hub の 1 件で、`doors` は `[]` です。部屋の位置や大きさが要るときは、必ずここから読みます（`house.ts`・`placement.ts` の `roomOrigin`・`doorZones`）。`house` の無い古いサーバーのときだけ、`model_url` のリビング 1 部屋として扱います（`houseRoomsOf`）。今のサーバーの `model_url` はリビングだけの `home-empty.glb` で、前の版の Web のために返しているだけです。
- 家の中の作品の大きさは、実寸（`slots[].artwork.model_size`。登録時に Rust が GLB から測った値）× 倍率です。倍率は、作品の向き（配置 JSON の `rotationY`）で回した縦横と高さが置き場所の枠 `fit` に収まる、いちばん大きい値です（`placement.ts` の `displayScale`。Rust の `display_scale` と同じ式で、`slots[].scale` と一致する）。枠は、家具の上なら載せている面の `art_fit`（本棚の段では上の棚板にぶつからない高さ）、床なら 0.8 × 1.0 × 0.8 m です。
- `model_kind` が `custom` の作品（登録時に渡した GLB と、サンプルの作品 33 点。実寸のモデル）は 1 倍まで（拡大しない）、それ以外（写真から作った額縁・スタンド）は枠いっぱいの大きさにします。置けるかどうかの判定も、この置いた後の大きさ（`placedSize`・`artRect`）で調べます。
- 実寸が分からない作品（`model_size` が null）は、`FittedModel` が範囲 `fit` に収めます（水平方向は対角線の長さで合わせる。`custom` なら `noUpscale` で縮めるだけ）。判定では枠そのものを作品の大きさとして扱います。④ 3D プレビューも `FittedModel` で、台座の上の範囲に収めます。

### 模様替えの仕組み（⑫）

1. **下書き：** `HomeEdit.tsx` は、`/api/museum` の配置 JSON を下書き（`draft`）として持ち、3D（`HomeEditScene`）にはこの下書きを渡します。保存していない変更がある間は、サーバーの配置で下書きを上書きしません。
2. **部屋：** 選んでいる部屋（`room`。はじめは `hub`）を `HomeEditScene` の `roomId` に渡し、カメラをその部屋へ寄せます。テーマ・家具の追加・作品の追加は、この部屋に入ります。画面の下の部屋の切り替え（`Segmented`）は `house.rooms` にある部屋だけを出し、1 部屋なら出さないので、今は出ません（シートの題も「追加」だけ）。部屋が 2 つ以上あるときは、切り替えると、選んでいる物と置けない理由の表示をやめ、ドラッグの途中なら元に戻します（シートの題は「追加（〇〇）」になる）。
3. **判定：** ドラッグ中は、ポインタが動くたびに置き先を決め、`placement.ts` の `canPlace` で置けるかどうかを調べて、板を緑・赤に変えます（置けない理由は画面下に出ます）。
   - 物は、押したときの部屋（`roomOf`）から出しません。家具と床の作品の位置は部屋の中の位置なので、ポインタの先の世界座標から部屋の中心（`roomOrigin`）を引いてから寄せます。
   - 家具は、押した点の高さの水平な面の上で動き、自分の部屋の中（壁から 12 cm。`roomRect(layout, roomId)`）に寄せます（`clampToRect`）。上の作品は家具のグループの子なので一緒に動きます。
   - 作品は、ポインタの先の家具に面があれば、その面に載せ換えます。レイは同じ部屋の家具のグループ（`FURN_`）にだけ当て、作品（`ARTWORK_`）の当たりは飛ばします。面は、当たった高さ + 5 cm 以下でいちばん高いもの（本棚なら指した段）です。家具に当たらない（面の無い家具・ラグに当たったときも）ときは、作品の部屋の床に置きます。どちらも作品の置いた後の大きさで、面の平らな所の縁・部屋の中に寄せます（`clampToRect`）。
   - 1 cm に丸めてから寄せるので、丸めてはみ出すことはありません。押した点と物の中心のずれは、押したときと同じ家具・面（床なら床）の上にいる間だけ保ちます。
   - 出入口のある部屋では、出入口の前（`doorZones`。Rust の `door_zone` と同じ大きさ）にかかると赤になり、ドラッグ中は床の物の部屋の出入口の前を薄い赤で示します（今の家には出入口が無いので、どちらも起きません）。`canPlace` の候補はいつも「動かした物」なので、Rust が保存のときに動かした物だけを調べる（`DoorPolicy::OnlyMoved`）のと合っています。前から出入口の前にある物は、そのまま描き、選ぶこともできます（出入口の前の中で動かす・回すと赤になる）。
   - 縁で止まるので、赤くなるのはほとんどがほかの物と重なるときです（実寸の分からない作品を奥行きの浅い面で 90° 回したときは、はみ出しで赤くなります）。
   - 作品の実寸は `slots` から `sizesFromSlots` で引きます。`HomeEditScene` の `canPlace`、`HomeEdit.tsx` の `rotateObject` には `{ nameOf, sizeOf, house }`、`addFurniture` には部屋の id と `{ sizeOf, house }` を渡します。
   - 「回す」（+90°）は、回した後に面や部屋の中へ寄せ直してから（`clampObject`）調べ、ほかの物と重なるとき（出入口のある部屋では出入口の前にかかるときも）は理由を出して回しません。
4. **確定：** 置ける場所で離すと、新しい配置（ほかの家具・本棚の段・床へ載せ換えた作品は、新しい `parentId`・`surface`、床なら部屋の `roomId`）を `commit` します（元に戻すの履歴に積む。30 回まで）。置けない場所で離すと、物は元の位置に戻り、理由をお知らせ（`useToast`）に出します。
5. **自動保存：** 最後の操作から 600 ms たつと、`useSaveLayout`（`PUT /api/home/layout`）で保存します。画面を離れるときはすぐに保存し、タブを閉じる・再読み込みするとき（`pagehide`）は `saveLayoutOnLeave`（`keepalive` 付きの `fetch`）で送ります。サーバーが 400 を返したときは、その文言をお知らせに出し、下書きをサーバーの配置に戻します（元に戻すの履歴も消えます）。
6. **追加：** 「追加」のシートの「家具」は、`addFurniture` が選んでいる部屋の中心から 0.5 m おきに渦巻き状に空きを探して置きます（向きは 0。出入口のある部屋では出入口の前を避ける）。置く場所が無ければ「〇〇に置く場所がありません」と出ます。「作品」は飾っていない作品の一覧で、選ぶと保存を済ませてから `POST /api/artworks/:id/display` を本文 `{ room_id: 選んでいる部屋 }` で送り（`useDisplay` の `roomId`。`house` の無い古いサーバーには送らない）、置き場所はサーバーがその部屋の中から選びます。その部屋に空きが無ければ 409 の文言（「中央のリビング に飾る場所がいっぱいです…」）をお知らせに出します。
7. **テーマ：** 選んでいる部屋の下書きの `rooms[部屋].wall`・`floor` だけを変えます（ほかの部屋はそのまま）。`HouseShells` が下書きの `rooms[部屋]` を部屋ごとの建物に当てるので、保存を待たずにその場で変わります。

- **Rust の `home.rs` と `placement.ts` の検証を揃える。** 正は Rust です（`check_placement`・`cell_grid`・`display_scale`・`placed_size`・`clamp_to_rect`・`world_of`・`room_rect`・`door_zone` とテスト）。片方だけ変えると、Web では緑なのに保存で 400 になる（またはその逆）ことになります。決まりを変えたら、`cd backend && cargo test regen_placement_cases -- --ignored` で総当たり表（`backend/src/testdata/placement-cases.json`）を作り直し、`cargo test` と `npm run check:placement` の両方を通します（手順は [AGENTS.md](../AGENTS.md) の「守ること」）。面に載せる作品の枠（`art_fit`）だけは、Rust が計算して `catalog` の `surfaces` に入れて返すので、Web では計算しません。
- **テーマ（`theme.ts`）：** 家の GLB のメッシュの `userData.role`（`wall_lower`・`wall_upper`・`floor`）を見て、壁と床の材質だけを `catalog.materials` のテクスチャで作った材質に差し替えます（幅木・柱・土台はそのまま。GLB に焼き込まれた白壁・オークの床を選んだときは GLB の材質に戻す）。テーマは建物（部屋）ごとに当てます。`userData.faceRoom` の印がある壁（共有する壁の、隣の部屋に向いた面）だけは、印の部屋のテーマ（`applyTheme` の `faceRooms`）を当てます（部屋を戻したときのため。今のリビングの GLB にはこの印がありません）。下の壁と上の壁では UV の原点の高さが違うので、テクスチャの縦のオフセットをずらして、レンガの模様が高さ 0.92 m の継ぎ目で切れないようにしています。材質は全部の画面で共有しているので、材質そのものを書き換えてはいけません（⑪ は `walk/stageMaterials.ts` で複製してから変えます）。内装セット（finish-pack）の素材は、壁紙・床材の名前と素材の id が同じで、GLB に焼き込みが無いのでいつもテクスチャを貼ります。色の画像が仕上がりの色なので、材質の色は白です（白壁 `plaster` の色の補正は `plaster` だけ）。幅木・枠は変えません。
- 今の模様替えでは、部屋の大きさの変更・増築と、物を部屋をまたいで動かすことは、まだできません。

## スタイル

### どこに書くか

| 使う場所 | 書く場所 | 例 |
|---|---|---|
| 1 つの画面だけ | `pages/画面名.css` | ホームの下段の並び → `pages/Home.css` |
| 1 つの部品だけ | `components/部品名.css` | 上部のバー → `components/NavBar.css` |
| 2 か所以上 | `styles/` | ボタン → `styles/buttons.css` |

各 `.tsx` は、自分の `.css` を最後の import で読み込みます（`import './Home.css'`）。
読み込みの順番は「`styles/`（`main.tsx` で最初に読む）→ 部品の `.css` → 画面の `.css`」です。CSS は後から読んだ方が優先されるので、画面の `.css` で部品や共通の指定を上書きできます。逆に、部品の `.css` どうしで同じ要素の同じ項目を指定し合わないでください（どちらが勝つかが import の順番で変わってしまいます）。

### `styles/`（2 か所以上で使うもの）

`styles/index.css` が、次の順に読み込みます。

| ファイル | 内容 |
|---|---|
| `tokens.css` | 色・フォント・動きの速さなどの CSS 変数 |
| `base.css` | 全体の基本設定（リセット、フォーカス、`.serif`、`.num`、`.visually-hidden`、「視差効果を減らす」設定） |
| `glass.css` | ガラス素材（`.glass`、`.glass-dark`） |
| `buttons.css` | ボタン（`.btn` と種類）、紙の上のアイコンボタン（`.icon-btn`）、押したときの反応（`.pressable`） |
| `layout.css` | 画面の余白（`.page`）、セクションの見出し（`.section-head`）、3 列の並び（`.grid-3`）、シートやメニューの後ろの幕（`.scrim`） |
| `common.css` | 作品の画像の枠（`.thumb`）、飾っている印（`.on-view`）、読み込み中（`.skeleton`）、アバター（`.avatar`）、補足の文字（`.eyebrow`、`.hint`、`.empty`、`.note`、`.count-caption`） |
| `form.css` | 入力欄（`.form`、`.field`、`.input`、`.textarea` など） |
| `list.css` | 設定アプリ風のリスト（`.list-group`、`.list-item`） |
| `stage-overlay.css` | 3D や画像の上に重ねる上部の操作列（詳細・3D プレビュー・おうちの中で共通） |
| `caption.css` | 作品のキャプション（詳細・3D プレビューで共通） |

このほか、アプリの外枠（`.app`）は `App.css`、画面遷移のアニメーションは `nav.css` にあります。

### デザインの決まり

- **色は CSS 変数を使う。** `styles/tokens.css` の `--paper`（紙の色）、`--ink`（文字の色）、`--accent`（差し色）などを使います。色を変えたいときは `tokens.css` だけを変えます。
- **フォントは 2 種類。** 本文は `--sans`（Zen Kaku Gothic New）、タイトルや作品名は `--serif`（Shippori Mincho）。
- **ガラスは、3D や画像の上に浮かぶ部品だけに使う。** 下部タブ、3D の上のボタン（`GlassButton`）、「⋯」のメニューなどです。紙の背景の上では `.icon-btn` を使います。何にでもガラスを付けると、見た目のバランスが崩れます。
- **ボタンは `.btn` に種類を足す。** 主な操作は `.btn-filled`（黒）、次の操作は `.btn-outline`（線）、ほかに `.btn-gray`、`.btn-plain`（文字だけ）、`.btn-destructive`（削除）、小さくするときは `.btn-small`。
- **角の曲線（`corner-shape: squircle`）は、その部品の `.css` の最後に `@supports` で書く。** 対応しているブラウザでだけ、角が iOS のような曲線になります。
- **クラス名と `@keyframes` の名前はアプリ全体で共通です。** ファイルを分けても名前の衝突は防げません。新しく足すときは、同じ名前がないかを検索してから付けてください。`@keyframes` は、同じ名前があると後から読んだ方だけが使われます。
- 余白の微調整など 1 か所だけのものは、画面のコードに `style={{ ... }}` で書いています。2 か所以上で使うなら CSS に移してください。

## データの取り方（`api/`）

Rust のファイルと対応するように分けています。

| ファイル | 内容 | Rust 側 |
|---|---|---|
| `index.ts` | 入口。画面からは `import { useMuseum } from '../api'` で読み込む | |
| `types.ts` | API の型。Rust の構造体名をコメントに書いている。配置 JSON（`Layout`。v5。`rooms` は `hub` だけ）だけは camelCase。テーマの型（`HomeTheme`・`HomeMaterial`・`WallFinish`・`FloorFinish`）、部屋の型（`RoomId`・`Side`・`LayoutRoom`）と家の形（`House`・`HouseRoom`・`HouseDoor`。`Museum.house`）もここ | DTO（`ArtworkDto`、`MuseumOverview`、`Layout`、`HouseView` など） |
| `client.ts` | 通信の共通処理（`request`、`ApiError`）、TanStack Query の設定、キャッシュのキー | `error.rs`（`{ "error": "..." }` の形） |
| `museum.ts` | おへや 1 つの全体像（家の GLB・配置 JSON・家具の一覧・飾っている作品）と設定：`useMuseum({ roomId })`（キャッシュのキーは `keys.museumOf(roomId)`）、`useSettings`、`useUpdateSettings`（お誕生日を変えると作品のおへやが変わるので、年齢の一覧・おへや・作品も取り直す） | `museum_api.rs` |
| `ages.ts` | 年齢とおへや：`useAges`（`GET /api/ages`）、`useAgeStack(age)`（`GET /api/ages/{age}`）、`useAddRoom`（`POST /api/ages/{age}/rooms`）、`useDeleteRoom`（`DELETE /api/rooms/{id}`。② の「〇〇を消す」） | `ages_api.rs` |
| `home.ts` | おへや 1 つの配置 JSON の読み書き（どれも `roomId` を取り、`?room=` を付ける）：`useLayout`（`GET /api/home/layout`）、`useSaveLayout`（`PUT`。保存すると、おうちの全体像と作品の一覧も取り直す。置き方がおかしいと 400 で、Rust の日本語の文言の `ApiError` になる）、`saveLayoutOnLeave`（画面を閉じるときに `keepalive` で送る。結果は待たない）。⑫ は配置を `useMuseum` から読み、`useLayout` は今は使っていない | `home_api.rs` |
| `memories.ts` | 作品のおもいで：`useUploadMemory`（`XMLHttpRequest` で送り、進み具合を返す）・`useUpdateMemory`・`useDeleteMemory`（どれも作品の詳細・一覧・おへやを取り直す）、種類の判定 `kindOfFile`（Content-Type、無ければ拡張子）、動画と声の長さ・大きさを測る `probeMedia`、上限 `MEMORY_LIMITS`（Rust と同じ） | `memories.rs` |
| `artworks.ts` | 作品：取得は `useArtworks`、`useArtwork`、画面の外から詳細を取る `fetchArtworkDetail`（⑪ の声）。変更は `useCreateArtwork`、`useUpdateArtwork`、`useDeleteArtwork`、`useFavorite`、`useDisplay`（おうちに飾る・飾るのをやめる。`roomId`（おへやの id）を渡すと本文 `{ room_id }` でそのおへやに飾る。省くと、作品の年齢のおへやにサーバーが置く） | `artworks.rs` |

- 型は Rust の API の形と同じです。API の項目を増やしたら、`types.ts` の型も合わせます。
- 変更が成功すると、関係する一覧・おうちの情報・配置 JSON を自動で取り直します（`useInvalidate`）。画面側で取り直す処理を書く必要はありません。
- 一覧で取得済みの作品は、詳細画面を開いた瞬間に表示されます（`placeholderData`）。
- `/api/ages` は `index.html` で先読みしています（ホームが最初に使う。`fetch` の URL が同じなら、ブラウザが先読みの結果を使う）。

## 画面遷移（`nav.ts` と `nav.css`）

iOS 風のアニメーションは、ブラウザの View Transitions API で作っています。

- 画面の移動には `useNav()` を使います。

  | 関数 | 動き |
  |---|---|
  | `nav.push(to, 作品ID?)` | 右から次の画面が重なる。作品 ID を渡すと、その作品の画像が次の画面へつながって動く |
  | `nav.back(fallback)` | push の逆 |
  | `nav.modal(to)` | 下からせり上がる |
  | `nav.dismiss(fallback)` | modal の逆 |
  | `nav.tab(to)` | 素早いクロスフェード |
  | `nav.replace(to)` | 履歴を置き換えて進む（登録 → プレビューなど） |

- リンクには `TLink`（`kind` で種類を選ぶ）を使います。普通の `<a>` や React Router の `Link` だと、アニメーションが付きません。
- 仕組み：
  1. `nav.ts` が `<html>` に `data-nav="push"` などの印を付けて、`document.startViewTransition` を始める。
  2. その中で画面を切り替え、`App.tsx` に置いた `RouteRendered` が「新しい画面の描画が終わった」と知らせる。
  3. `nav.css` が、印の種類に合わせて古い画面と新しい画面を動かす。
- 長さ（`nav.css`）：push / pop 0.32 秒、modal / dismiss 0.3 秒、tab / fade 0.18 秒、上部のバーと下部タブ 0.2 秒。どれも、はね返らない ease-out（`tokens.css` の `--ease-out`）です。長くすると、前の画面が残っているように見えます。古い画面の写しには `filter`（明るさ）をかけず、少し薄くするだけにしています（画面全体の写しに `filter` をかけると、毎フレーム描き直しになって重い）。アプリの外（PC での背景）は動かしません（`root` は `animation: none`）。
- 3D の画面は、遷移のアニメーションが終わってからキャンバスを置きます。`nav.ts` が動いている遷移を覚えていて（`finished` まで。1.2 秒たったら `finished` を待たずに終わったとみなす）、`useNavSettled()` が遷移中は `false` を返します。3D の枠 `three/StageShell.tsx` はこれが `true` になるまで `children`（3D）を置かず、その間は「準備しています…」を出します。WebGL の準備・GLB の複製・シェーダーの準備がアニメーションと重なると、コマ落ちしてアニメーションが長引くためです（⑫ で 0.5 秒の設定が 1.4 秒かかっていた）。遷移なしで開いた画面（URL を直接開いた・ブラウザの戻る）ではすぐに置き、一度置いた 3D は次の遷移が始まっても外しません。
- 遷移が動いている間に次の遷移が始まったら、前の遷移を `skipTransition()` で終わらせてから始めます（前の遷移が新しい画面の描画を待っていれば、それも終わらせる）。前の遷移の後始末で、新しい遷移の `data-nav` や共有要素の名前を消さないようにしています。
- 作品の画像がつながって動く仕組み：`data-share="作品ID"` を付けた要素のうち、`nav.push` に渡した作品 ID と一致するものだけに名前（`view-transition-name`）を付けます。
- アプリ全体（`.app`）、上部のバー（`.navbar`）、下部タブ（`.tabbar-wrap`）は別々に動きます。push ではバーとタブはその場で切り替わり、モーダルでは画面と一緒に動きます。
- 対応していないブラウザ（Firefox や古い Safari）と、「視差効果を減らす」設定の端末では、アニメーションなしで切り替わります。ブラウザの戻るボタンでもアニメーションは付きません。

## よくある変更

- **画面を足す：** `pages/` に `画面名.tsx` を作り、`App.tsx` に `Route` を足します。専用の見た目があれば `pages/画面名.css` を作り、`.tsx` の最後で `import './画面名.css'` します。タブにするなら `components/TabBar.tsx` の `TABS` にも足します。最後に、この文書の画面一覧も更新してください。
- **部品を足す：** `components/` に `部品名.tsx`（と `部品名.css`）を作り、`components/index.ts` に `export` を足します。
- **色やフォントを変える：** `styles/tokens.css` を変えます。
- **API の項目を使う：** Rust の DTO に項目を足す → `api/types.ts` の型に足す → 画面で使う、の順です。
- **3D の見え方を変える：** 照明と背景色は `three/scenes/Stage.tsx`、カメラの位置は各 `three/scenes/〇〇Scene.tsx` です。

## 確認

- 型チェックとビルド：`cd web && npm run build`
- 置けるかどうかの判定が Rust と同じか：`cd web && npm run check:placement`。`tsc -p tsconfig.check.json` で `placement.ts` だけを `node_modules/.cache/placement-check/` に出力し、`scripts/check-placement.mjs` が Rust の総当たり表（`backend/src/testdata/placement-cases.json`）を計算し直して、寄せた位置・倍率・置けるかどうかを比べます。違いがあれば最初の 20 件を出して、終了コード 1 で終わります。TypeScript を直接読む機能は使わないので、Node 20.19 でも動きます。環境変数 `PLACEMENT_CASES` で別の表を渡せます
  - 今の表はリビングだけ（配置は v5。出入口なし）の表です。`cases` は 4,900 件（面 16 × 作品 35 × 2 つの向き × 寄せる先 4 = 4,480 件と、hub の床 × 作品 35 × 2 × 寄せる先 6 = 420 件。床の行には `room` がある）、`extra` は重なり・壁・床の枠・寸法の分からない作品・45°・床の台座（(3.2, 3.2)）との重なり・台座の上のラグ・以前の出入口の前に置けることの 10 件と、壁の家具の 11 件です。表の `wall`（壁の高さ・掛けられるいちばん低い高さ）を `placement.ts` の `WALL_HEIGHT`・`WALL_MOUNT_MIN` と比べます。部屋の定義は表の `house`（`/api/museum` の `house` と同じ形。hub だけで `doors: []`）、出入口の前の大きさは `door_zone` から読み、`placement.ts` の `DOOR_ZONE_WIDTH`・`DOOR_ZONE_DEPTH` と比べます。
  - 候補（id `cand`）は「新しく置いた物」として、出入口の前も調べます（`canPlace` に `house` を渡す。今は出入口が無いので何も止まらない）。`extra[].moved` が `false` の行は、動かしていない保存済みの物の扱いで、出入口の前を調べません（今の表には無い）。
  - 終わりに `表の形: 部屋ごと（床のケースに room あり）・床のケースの部屋: hub・部屋の定義: 表の house` と `cases 1740 件・extra 10 件・world 0 件 → 違い 0 件` が出れば OK です。リビングだけの v2 の表も読めます（そのときは出入口を調べない）
- 開発中の表示：サーバー（`cd backend && cargo run`）を起動したうえで、`cd web && npm run dev` → http://localhost:5173
