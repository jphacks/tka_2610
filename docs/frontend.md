# Web（フロントエンド）の構成

> [!NOTE]
> 2026年10月時点の構成です。`web/` を初めて触る人向けに、どこに何があるかと、変更するときの決まりをまとめています。

## 全体の考え方

- **処理は Rust、Web は表示だけ。** 日付の整形（`date_long` など）、画像のサムネイル、背景色（`tint`）、展示台の位置などは、すべて API が計算して返します。Web 側で計算を足したくなったら、まず `backend/` に置けないかを考えてください。
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
| 3D の照明や背景色を変える | `three/scenes/Stage.tsx` |
| 画面遷移のアニメーションを変える | `nav.ts` と `nav.css` |

## 読む順番

初めて読むときは、この順に開くと全体がつかめます。

1. `src/main.tsx`：起動するだけのファイル。全体のスタイルを読み込み、`App` を描画します。
2. `src/App.tsx`：URL と画面の対応表です。どの URL でどの画面が出るかが 1 か所にまとまっています。
3. `src/pages/Home.tsx`：ホーム画面。API からデータを取り（`api/`）、共通部品（`components/`）と 3D（`three/`）を並べる、という画面の基本の形が分かります。

## ディレクトリ

```
web/
├── index.html          フォントの読み込み、/api/museum の先読み
├── vite.config.ts      開発サーバーの設定（/api と /media を 8080 番の Rust に中継）
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
import { HeroScene, StageShell } from '../three'
```

## 画面（`pages/`）

番号はデザイン案の番号です。①ログインは未実装です。

| 番号 | 画面 | URL | ファイル | 開き方 |
|---|---|---|---|---|
| ② | ホーム | `/` | `Home.tsx` / `.css` | タブ |
| ③ | 作品を追加 | `/add` | `AddArtwork.tsx` | モーダル |
| ④ | 3D プレビュー | `/artworks/:id/preview` | `ArtworkPreview.tsx` / `.css` | モーダル |
| ⑤ | 博物館の中 | `/museum`（`?focus=作品ID` / `?room=部屋ID`） | `MuseumView.tsx` / `.css` | push |
| ⑥ | 作品の詳細 | `/artworks/:id` | `ArtworkDetail.tsx` / `.css` | push |
| ⑦ | 博物館のマップ | `/map` | `MapView.tsx` / `.css` | タブ |
| ⑧ | 作品一覧 | `/collection`（`?category=種類`） | `Collection.tsx` | タブ |
| ⑨ | 作品を編集 | `/artworks/:id/edit` | `EditArtwork.tsx` | モーダル |
| ⑩ | 設定 | `/settings` | `Settings.tsx` / `.css` | タブ |

- 「開き方」は画面遷移アニメーションの種類です（後述の「画面遷移」）。
- 各ファイルの先頭に、番号・URL・開き方を書いています。
- `.css` がない画面は、共通のスタイル（`styles/`）と部品だけでできています。

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
| `Segmented.tsx` / `.css` | `Segmented` | 切り替えボタン（作品の種類、フロアなど） |
| `Toast.tsx` / `.css` | `ToastProvider` / `useToast` | 上から降りてくるお知らせ |
| `Img.tsx` | `Img` | 画像。読み込みまでは API の `tint` を背景に敷く。見た目（`.thumb`）は `styles/common.css` |
| `ArtworkThumb.tsx` / `.css` | `ArtworkThumb` / `ThumbSkeletons` | 作品のサムネイルと、読み込み中の仮表示 |
| `Loading.tsx` / `.css` | `Spinner` / `Busy` / `StageFallback` | 読み込み中の表示 |
| `ArtworkForm.tsx` / `.css` | `ArtworkForm` | 作品の登録・編集フォーム（③と⑨で共通） |
| `usePresence.ts` | `usePresence` | 開閉アニメーション用。部品の中だけで使う |

## 3D（`three/`）

three.js はとても大きい（約 290 KB、gzip）ので、最初の読み込みには含めず、3D が必要になったときに別ファイルとして読み込みます。
そのため、`three/` は「画面が使う入口」と「three.js を使う重いコード（`scenes/`）」に分けています。

| ファイル | 内容 |
|---|---|
| `index.tsx` | **入口。画面はここだけを import する。** `HeroScene` などを遅延読み込みで渡す。`warmUp3D` で博物館の GLB と 3D のコードを先読みする |
| `StageShell.tsx` / `.css` | 3D を表示する枠。3D が描画されるまで「準備しています…」を重ねる（three.js は使わない） |
| `scenes/index.ts` | 重いコードのまとめ役。ここから辿れるものが 1 つの遅延読み込みファイルになる |
| `scenes/Stage.tsx` | three.js のキャンバスと照明、背景色。4 つの 3D 画面の土台 |
| `scenes/models.tsx` | GLB を読み込んで置く部品：博物館（`MuseumModel`）、展示台の上の作品（`SlotArtworks`、`FittedModel`）、先読み（`preloadModel`） |
| `scenes/CameraFlight.tsx` | カメラを目的地へなめらかに移動させる |
| `scenes/HeroScene.tsx` | ②ホームの背景。入口から館内をゆっくり見回す |
| `scenes/MuseumScene.tsx` | ⑤博物館の中。ドラッグで見回し、作品をクリックで詳細へ |
| `scenes/MapScene.tsx` / `.css` | ⑦見取り図。フロアごとに上の階を隠して見下ろす。`.css` は部屋の名前のラベル |
| `scenes/PreviewScene.tsx` | ④3D プレビュー。台座の上で作品が回る |

- **画面から `three/scenes/` の中を直接 import しないでください。** 必ず `import { ... } from '../three'` を使います。直接読むと three.js が最初の読み込みに混ざり、最初の表示が遅くなります。
- ビルドしたときに、`dist/assets/` の `scenes-〇〇.js` が約 1 MB（gzip で約 290 KB）、`index-〇〇.js` が約 335 KB のままなら、正しく分かれています。
- 展示台の位置と作品の向きは、API（`/api/museum` の `slots`）の値をそのまま使います。Unity と同じ座標です。
- 作品を展示台に収める大きさの計算（`FittedModel`）は、Unity の `MuseumDisplaySlot.PlacePrefab` と同じ規則にしてあります。

## スタイル

### どこに書くか

| 使う場所 | 書く場所 | 例 |
|---|---|---|
| 1 つの画面だけ | `pages/画面名.css` | ホームのヒーロー → `pages/Home.css` |
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
| `common.css` | 作品の画像の枠（`.thumb`）、展示中の印（`.on-view`）、読み込み中（`.skeleton`）、アバター（`.avatar`）、補足の文字（`.eyebrow`、`.hint`、`.empty`、`.note`、`.count-caption`） |
| `form.css` | 入力欄（`.form`、`.field`、`.input`、`.textarea` など） |
| `list.css` | 設定アプリ風のリスト（`.list-group`、`.list-item`） |
| `stage-overlay.css` | 3D や画像の上に重ねる上部の操作列（詳細・3D プレビュー・館内で共通） |
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
| `types.ts` | API の型。Rust の構造体名をコメントに書いている | DTO（`ArtworkDto`、`MuseumOverview` など） |
| `client.ts` | 通信の共通処理（`request`、`ApiError`）、TanStack Query の設定、キャッシュのキー | `error.rs`（`{ "error": "..." }` の形） |
| `museum.ts` | 博物館の全体像と設定：`useMuseum`、`useSettings`、`useUpdateSettings` | `museum_api.rs` |
| `artworks.ts` | 作品：取得は `useArtworks`、`useArtwork`。変更は `useCreateArtwork`、`useUpdateArtwork`、`useDeleteArtwork`、`useFavorite`、`useDisplay` | `artworks.rs` |

- 型は Rust の API の形と同じです。API の項目を増やしたら、`types.ts` の型も合わせます。
- 変更が成功すると、関係する一覧と博物館の情報を自動で取り直します（`useInvalidate`）。画面側で取り直す処理を書く必要はありません。
- 一覧で取得済みの作品は、詳細画面を開いた瞬間に表示されます（`placeholderData`）。
- `/api/museum` は `index.html` で先読みしていて、最初の 1 回だけその結果を使います（`museum.ts`）。

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
- 開発中の表示：サーバー（`cd backend && cargo run`）を起動したうえで、`cd web && npm run dev` → http://localhost:5173
