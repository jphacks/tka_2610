# memoria の Web とアプリの橋渡し（取り決め v1）

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

iPhone のアプリ（`ios/`。表示名は「Memoria」）は、memoria（tka_2610 の Web）を WKWebView で開きます。作品追加の画面の「3D 生成で追加」から頼まれたときだけ、ネイティブの撮影画面を出し、撮った写真を Web の作品追加のフォームに返します。この文書は、そのやりとりの決まりです。Web 側は `web/src/native/bridge.ts` で、`window.MemoriaNative` と `window.webkit.messageHandlers.memoria` に触るのはそのファイルだけです。

決まりを変えるときは、アプリ（`ios/MemoriaCapture/Web/`・CaptureCore の `WebBridge.swift` とテスト）、Web（`web/src/native/bridge.ts`）、この文書を一緒に変えます。互換の無い変更をするときは `version` を上げます。

## 接続先

- アプリが開く memoria は、Info.plist の `MemoriaWebURL`（`$(MEMORIA_WEB_SCHEME)://$(MEMORIA_WEB_HOST)`）です。既定は `ios/Config/Signing.xcconfig` の `https` と `memoria-try.tka-2610.workers.dev`（xcconfig では `//` がコメントになるので 2 つに分けています）。手元の memoria につなぐときは、git に入らない `ios/Config/Local.xcconfig` で上書きします（[README.md](../README.md) の「手元の memoria につなぐ」）。
- メインのフレームで開くのは、この接続先（scheme・ホスト・ポートが同じ）のページだけです。ほかの接続先へのリンク・`target="_blank"`・`window.open` は、Safari など外のアプリで開きます（http・https・mailto・tel・sms のときだけ）。iframe の中の移動は止めません。
- Web のデータ（Cookie・localStorage）は既定の保存場所に置くので、アプリを閉じても残ります。Safari とは別なので、アプリの中の家は Safari の家とは別になります。同じ家を使うときは、開発用の画面の「設定 > memoria > 家を引き継ぐ」に `/house` のリンク（`<接続先>/?house=<32 桁の番号>`）か番号を貼ります。アプリは番号だけを読み、自分の接続先で `<接続先>/?house=<番号>` を開きます。
- Web の処理が落ちたら読み込み直します。撮影画面を出している間に落ちたときは、撮影画面を閉じてから読み込み直します（結果は下の `pendingCapture` で渡す）。
- 読み込めないときは、アプリが「もう一度読み込む」の画面を出します（開発用の画面もそこから開けます）。
- カメラ・マイクの権限（Web の `getUserMedia`）は、この接続先のときだけ許します（iOS の許可はそのあとで別に聞かれる）。JS の `alert`・`confirm`・`prompt` は、アプリのダイアログで出します。
- デバッグのビルドでは `isInspectable` が true で、Mac の Safari の「開発」メニューから中を調べられます。

## `window.MemoriaNative`

ページの読み込みの初め（document start。メインのフレームだけ）に、アプリが次の値を入れます（`Object.freeze` 済み）。Web はこれがあり、`capture` が true のときだけ「3D 生成で追加」を出します。Safari や PC のブラウザには無いので、何も変わりません。

```js
window.MemoriaNative = {
  capture: true,
  version: 1,
  sheets: [                                  // 平面の作品の紙の一覧（CaptureCore の SheetPreset の順）
    { id: "yatsugiri", label: "八つ切（27.1 × 39.2 cm）" },
    { id: "yotsugiri", label: "四つ切（39.2 × 54.2 cm）" },
    { id: "a4",        label: "A4（21.0 × 29.7 cm）" },
    { id: "b4",        label: "B4（25.7 × 36.4 cm）" },
    { id: "a3",        label: "A3（29.7 × 42.0 cm）" },
    { id: "b5",        label: "B5（18.2 × 25.7 cm）" }
  ],
  heightCm: { min: 0.5, max: 300 }           // 立体の作品の高さの入力で受け付ける範囲（cm）
}
```

- `sheets[].id` は `SheetPreset` の値、`label` はそのまま画面に出す文言です。一覧はアプリの `SheetPreset` から作るので、紙を足すときは CaptureCore だけを変えます。「その他（縦と横を入力）」は Web からは選べません。「わからない」は一覧に無く、Web が `sheetId` を省きます。

## 知らせと返事

Web は `window.webkit.messageHandlers.memoria.postMessage(知らせ)` を送り、戻り値の Promise で返事を受けます（`WKScriptMessageHandlerWithReply`）。知らせは `type` の付いた平らなオブジェクトで、項目名は camelCase です。

アプリが受けるのは、設定した接続先のメインのフレームからの知らせだけです。受けられないときは Promise が失敗し、Error の `message` に短い日本語の文言が入ります。Web はその文言をそのまま画面に出します。

### `startCapture`：撮影画面を開く

```js
{ type: "startCapture", kind: "object" | "flat", sheetId?: string, heightCm?: number }
```

- `kind`：`object`（立体。memoria の種類は `craft`）か `flat`（平面。memoria の種類は `drawing`）。
- `sheetId`：平面のときだけ使います。`sheets[].id` のどれか。省く・null・空なら「わからない」。
- `heightCm`：立体のときだけ使います。0.5〜300 の数（cm）。0.1 mm に丸めます。省く・null なら入れていない。
- 使わない項目（平面の `heightCm`、立体の `sheetId`）は無視します。
- アプリは撮影データ（セッション）を新しく作り（題名は空。立体は端末の設定によらず「自由に撮る」、平面は真上から 1 枚）、選んだ紙・高さを session.json の `declaredSize` に書いて、全画面の撮影画面を出します。撮影画面には左上の「やめる」と、「これで登録」（写真が 0 枚のときは押せない）があります。
- 返事は、撮る人が終えるまで返りません。

返事：

```js
{ cancelled: true }                       // 「やめる」（撮影データは消した）
{ kind: "object" | "flat",                // 「これで登録」
  sessionId: "<UUID の大文字>",
  photoCount: 3,                          // 撮った枚数（渡すのは代表の 1 枚だけ）
  mime: "image/jpeg",
  image: "<base64。data: は付かない>" }
```

- 代表の写真：平面は一番新しい写真の、遠近を直した画像（無ければ元の写真）。立体は最初の写真（何枚撮っても、渡すのは最初の 1 枚）。
- 写真は回転を画素に焼き込んで（EXIF の向きに頼らない）、長い辺 2048 ピクセル以下、JPEG の質 0.85 にします。
- 撮影データ一式（全部の写真・カメラの情報など）は iPhone に残ります（開発用の画面から見られ、Mac へ送れる）。

失敗（Promise が失敗し、次の文言が入る）：

| 文言 | いつ |
|---|---|
| 作品の種類が正しくありません | `kind` が `object`・`flat` でない |
| 紙の大きさが一覧にありません | `sheetId` が一覧に無い |
| 高さは 0.5〜300 cm で入れてください | `heightCm` が数でない・範囲の外 |
| 撮影の画面がすでに開いています | 撮影中にもう一度頼まれた |
| カメラが許可されていません。「設定」アプリの「Memoria」でカメラをオンにしてください | カメラの許可が無い（まだ聞いていなければ、撮影画面で聞く） |
| この端末では撮影できません | ARKit のワールドトラッキングに対応していない |
| 撮影を始められませんでした | 撮影データを作れなかった |
| 撮った写真を読み込めませんでした | 代表の写真を読めない・JPEG にできない |

### `pendingCapture`：渡しそびれた結果

```js
{ type: "pendingCapture" }
```

- 撮影中に Web の処理が落ちたり、ページが読み込み直されたりすると、`startCapture` の返事は届きません。そのときアプリは結果を取っておき、`pendingCapture` で 1 回だけ渡します（渡したら消す）。Web は作品追加の画面を開いたときに 1 回だけ呼びます。
- 返事は `startCapture` の「これで登録」と同じ形か、無ければ `null`。
- 取っておくのは最後の 1 つだけです。新しく `startCapture` を頼まれたとき、その撮影データの `artworkCreated` を受けたときにも消します。アプリを閉じると消えます（撮影データは iPhone に残る）。

### `artworkCreated`：作品を登録できた

```js
{ type: "artworkCreated", sessionId: "<startCapture の sessionId>", artworkId: "<memoria の作品の id>", title: "<作品の題名>" }
```

- アプリは、その撮影データの `local.json` に `memoria`（`artworkId`・接続先・日時。[data-format.md](data-format.md)）を書きます。Mac へは送りません。
- 撮影データの題名が空なら、`title` を題名にします（送信中のときは付けない）。
- `artworkId` は文字（memoria では UUID）か整数。前後の空白は除き、200 文字まで。`title` は無くてもよく、200 文字で切ります。
- 返事は `{ ok: true }`。失敗：「撮影データが見つかりません」（`sessionId` が UUID でない・無い）、「作品の番号が正しくありません」（`artworkId` が空・形が違う）。

### `openSessions`：開発用の画面を開く

```js
{ type: "openSessions" }
```

- 今までの撮影データの一覧・確認・Mac へ送る・設定（家を引き継ぐ・読み込み直す）を、全画面で出します（左上の「閉じる」で Web に戻る）。返事は `{ ok: true }`。

### そのほかの失敗

| 文言 | いつ |
|---|---|
| このページからは撮影できません | 設定した接続先のメインのフレームからの知らせでない |
| アプリへの知らせの形が正しくありません | オブジェクトでない・`type` が無い |
| アプリが知らない知らせです（`type`） | 知らない `type` |

## 置き場所

| 何 | どこ |
|---|---|
| 接続先・知らせの読み方と確かめ・返事の形・`window.MemoriaNative`・代表の写真の選び方・家のリンクの読み方 | `ios/Packages/CaptureCore/Sources/CaptureCore/WebBridge.swift`（テストは `WebBridgeTests.swift`） |
| WKWebView・移動の決まり・読み込み直し・再試行の画面・権限・JS のダイアログ | `ios/MemoriaCapture/Web/MemoriaWebView.swift` |
| 知らせを受けて撮影画面を出し、結果を返す・渡しそびれた結果 | `ios/MemoriaCapture/Web/MemoriaBridge.swift` |
| 撮影画面の出し方（「これで登録」「やめる」） | `ios/MemoriaCapture/App/AppModel.swift`（`beginEmbeddedCapture`・`finishCapture`・`cancelEmbeddedCapture`）、`App/MemoriaCaptureApp.swift` |
| 写真をまっすぐに回した JPEG | `ios/MemoriaCapture/Storage/ImageLoading.swift`（`uprightJPEG`） |
| Web 側 | tka_2610 の `web/src/native/bridge.ts`（開発のときだけ `?fakeNative=1` で偽の橋渡し） |
