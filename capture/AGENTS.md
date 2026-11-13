# AGENTS.md

このフォルダで作業する AI エージェント（Claude Code・Codex など）と、引き継ぐ人向けのメモです。人向けの短い説明は [README.md](README.md) にあります。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。以前は別のリポジトリ（memoria-capture）で作っていたものを取り込み、今は **tka_2610 が正** です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。tka_2610 全体の決まりは一番上の `AGENTS.md` にあります。

## 目的と範囲

子どもの絵や工作を 3D モデルにするときの **入力の写真をそろえる** ためのフォルダです。iPhone のアプリで作品のまわりを撮り、同じネットワークの Mac へ送り、AI エージェントが読みやすい形にまとめるところまでを持ちます。

- **アプリは memoria（tka_2610 の Web）の入れ物です**（ユーザーが決めたもの）。アプリを開くと memoria が WKWebView で出て、作品追加の画面の「3D 生成で追加」から頼まれたときだけ、ネイティブの撮影画面を出します。「これで登録」で代表の写真を Web の作品追加のフォームに返し、memoria の今の処理（額縁・アクリルスタンドの GLB）ですぐ飾ります。生成 AI はあとでつなぎます。撮影データ一式は iPhone に残ります。下の「memoria とのつながり」。
- 今までのセッションの一覧・確認・Mac へ送る・設定は、**開発用の画面** として残しています（memoria の設定の「撮影データ（開発用）」から開く）。

- **3D の生成そのものは範囲の外です。** 生成は、Claude Code・Codex などの AI エージェントが、ここで作ったデータを読んで行います。生成のアルゴリズムや特定の生成サービスへの接続は、このフォルダに入れません。
- 例外として、**平らな作品（貼り絵・紙に描いた絵）を写真 1 枚から GLB にするツール** `tools/flat-art-glb/` を置いています（ユーザーが決めたもの）。撮影アプリや `for_claude/` の流れとはつながっておらず、写真 1 枚と設定ファイルから単独で動きます。
- 同じく例外として、**上が平らな単純な立体（箱・板・操作盤など）を数枚の写真から GLB にするツール** `tools/solid-glb/` を置いています（ユーザーが決めたもの）。これも撮影の流れとはつながっておらず、写真と設定ファイルから単独で動きます。形はプログラムが組み立て、AI は写真を見て設定ファイルを書きます。生成 AI は使いません。それ以外の立体の作品の生成は、引き続き範囲の外です。
- 今の方針（ユーザーが決めたもの）は **「AI に推論させながら作る」** です。正面・右・後ろ・左の 4 方向と、最後に真上から撮る **5 枚の撮影（`ai5`）** を、案内つきの撮り方の既定にしています（新しい立体のセッションの既定は、下の自由に撮る撮り方）。数枚のよい写真から AI が形を推論する前提なので、写真どうしの重なりは要りません。
- 立体の作品は、**案内なしで自由に何枚でも撮る方法（`guidance: "free"`）** を新しいセッションの既定にしています（ユーザーが決めたもの）。案内も自動撮影もなく、シャッターを押すだけで、1 枚以上あれば送れます。どの写真がどの向きかは記録せず、AI が写真を見て決めます（下の「撮影から AI に渡るまでの流れ（立体：自由に撮る）」）。下の案内つきの撮り方は、設定の「立体の撮り方」で選べるように残しています。
- 案内つきの撮り方では、**向きで案内する方法（`guidance: "heading"`）** が標準です（ユーザーの案）。作品を画面の中央の十字に合わせて正面を撮り、iPhone の向きが 90°・180°・270° 回った位置と真上で撮ります。底の中心・円柱の設定はありません。作品の位置と大きさは、撮ったあとに写真から求めます。**新しい方法で、実機ではまだ試していません**（下の「未対応・予定」）。前の方法（底の中心と円柱を決めてから撮る `baseCylinder`）は設定で選べ、48 方向（`photogrammetry`）などほかの一覧はいつも前の方法です。
- 新しいセッションを作るときに、撮る人が作品の種類を選びます。**立体（工作・粘土など）** は自由に撮る（撮る方向の一覧 `free`。案内つきなら `ai5` など）、**平面（絵・貼り絵など）** は真上から 1 枚（`flat1`）です。どちらにするかは人が決め、アプリは自動で見分けません。
- 48 方向の写真測量向けの撮影（`photogrammetry`）や Mac での写真測量のツール（`tools/reconstruct/`）は、実験のために残しています。今の主な流れではありません（下の「決めたこと・分かったこと」）。

## 構成

| ディレクトリ | 中身 | 役割 |
|---|---|---|
| `ios/MemoriaCapture/`・`ios/MemoriaCapture.xcodeproj` | iPhone のアプリ（Swift・SwiftUI・ARKit・Vision・WebKit。iOS 17 以上、外部のライブラリなし。表示名「Memoria」） | memoria の Web を開く入れ物（`Web/MemoriaWebView.swift`）と橋渡し（`Web/MemoriaBridge.swift`）、撮影の案内・高解像度の写真（`ARSession.captureHighResolutionFrame()`）とカメラの情報の保存・作品マスクの作成と確かめ・平面の作品の用紙の検出と遠近の補正・確認画面・Mac への送信。`App/`・`UI/`・`AR/`・`Analysis/`・`Storage/`・`Transfer/`・`Web/` に分けている。自由に撮る撮影は `AR/FreeCaptureController.swift`・`UI/FreeCaptureView.swift`、向きで案内する撮影は `AR/HeadingCaptureController.swift`・`UI/HeadingCaptureView.swift`・`Analysis/HeadingSizeService.swift`、前の方法は `AR/CaptureController.swift`、平面の作品の撮影は `AR/FlatCaptureController.swift`・`UI/FlatCaptureView.swift`・`Analysis/SheetDetection.swift`、4 つの撮影画面の共通の入れ物（映像を写真と同じ範囲で出し、上下を黒い帯にする）は `UI/CameraPreviewContainer.swift` |
| `ios/Packages/CaptureCore/` | SwiftPM のパッケージ（Foundation・simd・CryptoKit だけ） | アプリの「純粋なロジック」：session.json の型、撮影方向の一覧（`DirectionPlan`）、角度と投影の計算、撮影の進み具合、マスクの範囲と確かめ、向きの案内と撮ったあとの中心・大きさ（`HeadingGuidance.swift`・`HeadingRecorder.swift`・`HeadingDerivation.swift`・`HeadingSize.swift`）、平面の作品の計算（`FlatCapture.swift`：四隅の並べ方・実寸・案内・自動撮影）、撮る人が選んだ・入力した大きさ（`DeclaredSize.swift`：紙の一覧 `SheetPreset`・「その他」の紙・紙の向き・cm の入力の確かめ）、自由に撮る写真の記録（`FreeCapture.swift`）、転送、同じネットワークかの判定（`LocalNetworkPolicy`）、memoria の Web との橋渡しの決まり（`WebBridge.swift`：接続先・知らせの確かめ・返事の形・`window.MemoriaNative`・代表の写真・家のリンク）。macOS の `swift test` で確かめられる。Mac のツールもこの型を使う。確認用の `capture-e2e`（合成セッションを受信サーバーへ送る）もここ |
| `receiver/` | Python 3.9 以上（標準ライブラリだけ） | Mac の受信サーバー `memoria_receiver.py`。同じネットワークからの接続だけを受け、`captures/` に保存する。受け取るたびに `memoria-pack` を裏で動かす |
| `tools/claude-pack/` | Swift（macOS 14 以上） | `memoria-pack`。受け取ったセッションから AI 向けの入力 `captures/for_claude/<sessionId>/` を作る（平面の作品は、まっすぐにした絵と紙の実寸だけ） |
| `mcp-server/` | Python（MCP の SDK は uv が入れる。中身の `memoria_core.py` は標準ライブラリだけ） | Claude Code・Codex から撮影データを読む MCP サーバー（`list_sessions`・`get_brief`・`get_view` など） |
| `tools/reconstruct/` | Swift（Apple シリコンの Mac、macOS 14 以上） | `memoria-reconstruct`。RealityKit の `PhotogrammetrySession` で写真から USDZ を作る実験用のツール |
| `tools/flat-art-glb/` | Python（numpy・OpenCV・mapbox_earcut）。確かめには Node.js（three・gltf-validator）と Playwright | 平らな作品の写真 1 枚から GLB を作る関数の集まりとコマンド（`flatart_glb.py`）。撮影の流れとは別に単独で動く。説明は `tools/flat-art-glb/README.md` |
| `tools/solid-glb/` | Python（numpy・OpenCV・mapbox_earcut）。確かめには Node.js（three・gltf-validator）と Playwright | 上が平らな単純な立体を、真上の写真と設定ファイルから GLB にするコマンド（`solidglb.py`）。輪郭をなぞった層を積み、上面に写真を貼り、丸い部品を載せる。撮影の流れとは別に単独で動く。説明は `tools/solid-glb/README.md` |
| `docs/` | 取り決め | `data-format.md`（session.json の形・座標・画像の向き・撮影方向の一覧・マスクの確かめ・local.json）、`transfer-protocol.md`（iPhone → Mac の転送の手順と、同じネットワークの中だけにする決まり）、`web-bridge.md`（memoria の Web とアプリの橋渡し。取り決め v1） |
| `captures/` | 受け取ったデータ（git に入らない） | 受信サーバーが作る。読み方は受信サーバーが起動のたびに書き直す `captures/README.md` |

session.json の形は [docs/data-format.md](docs/data-format.md) が正です。iPhone・受信サーバー・Mac のツールは同じ形を読み書きします。項目を足すときは、無くても読めるようにして `schemaVersion` を 1 のままにしてきました（足した項目はどれも「後から足した項目」と書いてある）。

## memoria とのつながり（アプリの形）

- 一番下の画面は memoria の Web（`MemoriaWebScreen`）。接続先は Info.plist の `MemoriaWebURL` = `$(MEMORIA_WEB_SCHEME)://$(MEMORIA_WEB_HOST)`（`ios/Config/Signing.xcconfig`。既定は `https` と `memoria-try.tka-2610.workers.dev`。手元の memoria は `Local.xcconfig` で上書きする。[README.md](README.md) の「手元の memoria につなぐ」）。メインのフレームで開くのはこの接続先だけで、ほかは外のアプリで開きます。Web のデータは既定の保存場所（家の Cookie が残る。Safari とは別の家）。
- Web が `startCapture` を送ると、`AppModel.beginEmbeddedCapture` がセッションを作り（題名は空。立体は端末の設定によらず `guidance: "free"`、平面は `flat1`。選んだ紙・高さは `declaredSize`）、撮影画面を全画面のカバー（`EmbeddedCaptureScreen`。自分の `NavigationStack`）で出します。撮影画面の「確認へ」にあたるボタン（`CaptureScreen`・`FlatCaptureView`・`FreeCaptureView`・`HeadingCaptureView` の全部）は `AppModel.finishCapture` を通り、memoria から頼まれた撮影では「これで登録」（0 枚では押せない）で Web に返します。そうでなければ今までどおり確認画面へ移ります。左上の「やめる」は、写真があれば確かめてからセッションを消します。
- 返す写真は `RepresentativePhoto.pick`（平面は一番新しい写真の補正した画像、無ければ元の写真。立体は最初の写真）を、回転を画素に焼き込んだ JPEG（長い辺 2048・質 0.85。`ImageLoading.uprightJPEG`）にしたものです。main スレッドの外で作ります。
- 撮影中に Web の処理が落ちたら、撮影画面を閉じてから読み込み直し、結果は `pendingCapture` で 1 回だけ渡します。作品を登録すると Web が `artworkCreated` を送り、`local.json` の `memoria` に作品の id を書きます（Mac へは送らない）。
- 開発用の画面（`DeveloperScreens`。今までの `SessionListView` から確認・送信・設定まで）は、Web の `openSessions` か、読み込めないときの画面から全画面のカバーで出します。設定の「memoria」に「家を引き継ぐ」（`/house` のリンクか 32 桁の番号を貼ると `<接続先>/?house=<番号>` を開く）と「読み込み直す」があります。
- 知らせ・返事・失敗の文言は [docs/web-bridge.md](docs/web-bridge.md) が正です。Web 側は tka_2610 の `web/src/native/bridge.ts` です。

## 撮影から AI に渡るまでの流れ（立体：自由に撮る。標準）

ここからの「新しく撮る」「設定」「確認画面」「送信」は、開発用の画面の中の操作です（memoria から頼まれた撮影は、上の「memoria とのつながり」）。

1〜2 は下の「向きで案内」と同じです（受信サーバーの起動と、iPhone の送り先の設定）。

3. 「新しく撮る」で作品名を入れ、作品の種類で **「立体（工作・粘土など）」**（既定）を選びます。分かれば **「高さ（cm・分かれば）」** を入れます（空でよい。session.json の `declaredSize.heightM`）。設定の「立体の撮り方」が **「自由に撮る（標準）」** なら、撮る方向の一覧は `free`（方向は 0 個）、`guidance` は `free` になります。
4. 撮影画面には「作品の全体を画面に入れて撮ってください。正面・横・後ろ・真上があると、形を作りやすくなります」という目安と、撮った枚数・入力した高さだけが出ます。案内・自動撮影はなく、シャッターを押すたびに 1 枚撮ります（枚数の上限なし）。基準（底の中心・円柱）もマスクも作りません。写真ごとに記録する向きは、カメラの見下ろす角度だけです（平面の作品と同じ測り方）。
5. 確認画面で写真を見て「Mac へ送る」を押します。1 枚以上あれば送れます。足りない方向・切り抜きの表示はありません。
6. Mac の `for_claude/<sessionId>/` には、`brief.md`（自由に撮った n 枚、向きの案内はしていない、どの写真がどの向きかは写真を見て判断する、写真ごとの見下ろす角度、入力した高さか「大きさは分かりません」）、`views/photo-01.jpg`…（撮った順にまっすぐに回した写真。16 枚まで）、`measurements.json`（`method: "freeCapture"`、大きさは写真から求めない、`declaredHeight`）、`pack.json`（`guidance: "free"`）が入ります。`overview.jpg`・`hull.obj` はありません。

session.json の形は [docs/data-format.md](docs/data-format.md) の「自由に撮る撮影」です。

## 撮影から AI に渡るまでの流れ（立体：`ai5`・向きで案内。設定で選ぶ）

設定の「立体の撮り方」で「向きで案内」を選んだときの流れです。

1. Mac で受信サーバーを起動します。ペアリングコード（6 桁）と接続先の URL が出ます。
2. iPhone と Mac を同じネットワーク（自宅の Wi-Fi・USB ケーブル・iPhone のインターネット共有）につなぎ、アプリの「設定」で送り先（Bonjour の一覧か、URL の手入力）とペアリングコードを入れて「接続を確認」を押します。
3. 「新しく撮る」で作品名を入れ（AI が何の物かを知る手がかりになります）、作品の種類で **「立体（工作・粘土など）」**（既定）を選びます。分かれば **「高さ（cm・分かれば）」** を入れます（空でよい。0.5〜300 cm だけを使い、session.json の `declaredSize.heightM` になる）。平面の作品は下の「平面の作品の流れ」です。
4. 作品を画面の中央の十字に合わせ、正面を手動で撮ります（**このときの iPhone の向きがデータの「正面」になります**）。底の中心・円柱の設定はありません。
5. 作品を十字に入れたまま、作品のまわりを歩きます。画面に「次は右。右へ回ってください（あと 63°）」のように、回る向きと残りの角度が出ます。向きが正面から 90°・180°・270°（±15°）、見下ろす角度が 15° 前後（±12°）になり、その場で回しただけではない（ARKit の位置で確かめる）と十字が緑になり、0.5 秒止めると自動で撮ります。近い方の横から右・後ろ・左（またはその逆）、最後に真上（見下ろす角度 75° 以上、向きは問わない）。向きは合っているのにその場で回しただけのときは十字が橙になり、「その場で回さず、作品のまわりを歩いてください」と出ます。正面のときより遠い・近いときは、撮るのは止めずに「少し近づいて・離れて」と出ます。シャッターはいつでも押せます（狙った向きの外の写真も、測った向きのまま保存して確認画面で知らせる）。画面には「n / 5」が出ます。
6. 撮るたびに、iPhone が方向ごとの代表の写真の画面の中心の線から作品の中心を求め、机の面（ARKit の平面か特徴点）が測れれば底の高さも決めて session.json に書きます。切り抜きができると、おおよその大きさも求めます。確認画面には、入力した高さ（入れたとき）、求めた位置（線の外れ）と大きさ（おおよそ・信頼度）が出ます。写真と切り抜きを見て、「送信」を押します。入力した高さは、写真から求めた大きさより優先するよう `brief.md`・`measurements.json`（`declaredHeight`）で AI に伝えます（求めた大きさは書き換えない）。
7. Mac では、完了したセッションが `captures/sessions/<sessionId>/` に入り、続けて `captures/for_claude/<sessionId>/` が作られます（`tools/claude-pack` を release でビルドしてあるときだけ）。AI エージェントの入口は **`captures/for_claude/<sessionId>/brief.md`** です。

前の方法（設定の「立体の撮り方」で「底の中心と円柱で案内」）では、4 の前に底の中心に印を合わせて「ここが底の中心」を押し、円柱のガイドの高さと半径を作品に合わせ、「基準を確定」を押します。印は ARKit の平面（黄色）、机の特徴点から推定した高さ（水色）、iPhone の下端を机に当てて測った高さ（紫）の順に使います。「底の高さ ▼▲」で 0.5 cm ずつ直せます。撮る方向は同じで、方向は作品の位置から案内します。

session.json の形（`guidance`・`referenceFrames[].heading`・`photos[].heading`）は [docs/data-format.md](docs/data-format.md) の「向きで案内する撮影」です。

## 平面の作品の流れ（`flat1`）

1〜2 は立体と同じです。

3. 「新しく撮る」で作品名を入れ、**「平面（絵・貼り絵など）」** を選びます。画面には見分ける手がかり（横から見るとほぼ紙だけの物）を出しますが、決めるのは撮る人です。続けて **「紙の大きさ」** を一覧（八つ切・四つ切・A4・B4・A3・B5）から選びます（既定は「わからない」。session.json の `declaredSize.sheet` になる）。一覧に無い紙は **「その他（大きさを入力）」** を選び、縦と横を cm で入れます（どちらも 1〜300 cm のときだけ使い、`id` は `custom`。外れた値・空なら紙は選んでいない扱いで、橙の注意が出る）。
4. 底の中心・円柱の設定はありません。iPhone を作品の真上に持ち、紙の全体を画面に入れます。Vision（`VNDetectRectanglesRequest`）が見つけた紙の輪郭が画面に出ます（撮れる状態なら緑）。
5. 輪郭が止まり、iPhone の傾きが 70° 以上（ほぼ真上）、紙が画面の端にかかっていないと、0.8 秒で自動で撮ります（自動撮影はオフにもできる）。シャッターはいつでも押せます（紙が見つからない・真上でないときも撮れる。撮ったあとに知らせる）。画面には選んだ紙（「紙：八つ切（選んだ大きさ）」）と、「1 / 1 撮りました」、紙が見つからない・端にかかっている・真上でない・（紙を選んでいないときは）測った大きさが出ます。
6. 撮った高解像度の写真で紙を見つけ直し、ARKit の平面に四隅を当てて実寸を測り（平面が無ければ測った大きさは null。紙を選んでいれば問題として出さない）、遠近を直した画像（`rectified/<photoId>.jpg`）を作ります。縦横比は、選んだ紙があればその比（向きは四隅の辺の長さで決める）、無ければ測った実寸、それも無ければ四隅の辺の長さです。元の写真はそのまま保存します。マスクは作りません。
7. 確認画面（1/1）で写真と選んだ紙を見て「送信」を押します。撮り直すと一番新しい写真が代表になります。
8. Mac の `for_claude/<sessionId>/` には `brief.md`（平面の作品で、3D の再構成は要らない、紙の大きさ（選んだ紙 → 測った実寸の順）か「分かりません」）、`views/artwork.jpg`（まっすぐにした絵。直せなかったときは写真をまっすぐに回したもの）、補正したときは `views/photo.jpg`、`measurements.json`（`sheet`。`source` が `declared` か `measured`）、`pack.json`（`workKind: "flat"`）が入ります。`overview.jpg`・`hull.obj` はありません。

session.json の形（`workKind`・`photos[].flat`）は [docs/data-format.md](docs/data-format.md) の「平面の作品」、選んだ紙・入力した高さ（`declaredSize`）は「撮る人が選んだ・入力した大きさ」です。

## 立体のパックの中身

`ai5` のセッションの `for_claude/` には、`brief.md`、`overview.jpg`（3 × 3 の一覧）、`views/{front,right,back,left,top}.jpg`（まっすぐに回し、作品のまわりで切り出した背景付きの写真）、`measurements.json`、`pack.json` が入ります。`ai5` では visual hull を作らないので `hull.obj` はありません。向きで案内したセッションの `measurements.json` は `method: "headingDerived"`（撮ったあとに求めたおおよその大きさ、下と上の目安、信頼度、中心の線の外れ）で、`brief.md` に位置と大きさは撮ったあとに求めた値だと書きます。iPhone がまだ求めていなければ、`memoria-pack` が同じ計算で求めます。中身の詳しい説明は [tools/claude-pack/README.md](tools/claude-pack/README.md) です。

## 起動と確認

コマンドは `capture/` から実行します（`cd` のあるものは、`capture/` からの場所）。

```sh
# 受信サーバー（ポート 8765、保存先 captures/。止めるときは Ctrl-C）
python3 receiver/memoria_receiver.py
python3 receiver/memoria_receiver.py list                       # 受け取ったセッションの一覧
python3 receiver/memoria_receiver.py show <sessionId の先頭>     # 1 つのセッションの写真ごとの情報

# AI 向けの入力を作るツール（受信サーバーが自動で使うのは release のビルド）
(cd tools/claude-pack && swift build -c release)
tools/claude-pack/.build/release/memoria-pack <sessionId の先頭> --force             # 作り直す
tools/claude-pack/.build/release/memoria-pack <sessionId の先頭> --force --cutouts   # 背景を透明にした PNG も作る

# 写真測量（実験用）
(cd tools/reconstruct && swift run -c release memoria-reconstruct <sessionId の先頭> --detail preview)
```

受信サーバーのオプション（`--port`・`--data-dir`・`--no-bonjour`・`--allow-remote`・`--reset-code` など）は [receiver/README.md](receiver/README.md) にあります。

テスト（どれも Mac の中だけで動き、受信サーバーのテストは空いているポートと一時フォルダを使います）：

```sh
(cd ios/Packages/CaptureCore && swift test)
(cd tools/claude-pack && swift test)
(cd tools/reconstruct && swift test)
python3 -m unittest discover -s receiver/tests
python3 -m unittest discover -s mcp-server/tests
python3 -m unittest discover -s tools/flat-art-glb/tests   # numpy・OpenCV・mapbox_earcut が要る
python3 -m unittest discover -s tools/solid-glb/tests      # numpy・OpenCV・mapbox_earcut が要る
```

iPhone のアプリのビルド：

```sh
# 署名なしでビルドが通るかの確認（実機は要らない）
xcodebuild -project ios/MemoriaCapture.xcodeproj -scheme MemoriaCapture \
  -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

実機に入れるとき：

1. iPhone を Mac にケーブルでつなぎ、ロックを解除します。iPhone の「デベロッパモード」をオンにしておきます（再起動のあとの確認で「オンにする」を押すまでがひとまとまり）。
2. 初めてのときは、`ios/Config/Local.xcconfig.example` を同じフォルダに `Local.xcconfig` としてコピーし、`DEVELOPMENT_TEAM =` のあとに **自分の Team ID** を書きます（調べ方は example の中に書いてあります）。手元の memoria につなぐときは、同じファイルに `MEMORIA_WEB_SCHEME`・`MEMORIA_WEB_HOST` も書きます（[README.md](README.md) の「手元の memoria につなぐ」）。署名の Team は `ios/Config/Signing.xcconfig` がこのファイルから読みます。`Local.xcconfig` は `.gitignore` に入っていて、コミットされません。`project.pbxproj` には Team を書かないので、Xcode の「Signing & Capabilities」で Team を選び直さないでください（選ぶと `project.pbxproj` に書き込まれます）。Bundle Identifier が使えないと出たら末尾を変えます。
3. 次のコマンドでビルドして入れます。`<UDID>` は `xcrun devicectl list devices` の Identifier の列です。`ios/DerivedData/` は git に入りません。

```sh
xcrun devicectl list devices
xcodebuild -project ios/MemoriaCapture.xcodeproj -scheme MemoriaCapture \
  -destination 'id=<UDID>' -configuration Debug -derivedDataPath ios/DerivedData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> ios/DerivedData/Build/Products/Debug-iphoneos/MemoriaCapture.app
```

- 初めて署名するときは、Mac で codesign がキーチェーンの鍵を使う許可を求めます（Mac のログインのパスワードを入れて「常に許可」）。コマンドからだと `errSecInternalComponent` で止まることがあり、そのときは Xcode の ▶ で一度実行します。
- iPhone で「信頼されていないデベロッパ」と出たら、「設定 > 一般 > VPN とデバイス管理」で自分の開発元を信頼します。
- `devicectl` で iPhone が `unavailable` のときは入れられません。ケーブルでつなぎ直し、ロックを解除します。
- 送信の流れは、`capture-e2e` で実機なしに確かめられます。8765 で動いている受信サーバーとは別のポートと一時フォルダで受信サーバーを立てて、`(cd ios/Packages/CaptureCore && swift run capture-e2e http://127.0.0.1:<port> <ペアリングコード>)` を実行します（受信サーバーの `--host 127.0.0.1 --no-bonjour --data-dir <一時フォルダ>`。`--fail-put-every N` で再送も確かめられる）。`--flat` を付けると、平面の作品の合成セッション（真上の写真 1 枚・紙の四隅・実寸・補正した画像）を、`--heading` を付けると、向きで案内した立体の合成セッション（箱を 5 方向から撮った写真・十字のまわりのマスク・撮ったあとに求めた中心と大きさ）を送ります（どちらも付けないと前の方法の立体）。`--flat` に `--sheet=yatsugiri` など（id は `SheetPreset`）を足すと選んだ紙を、`--heading` に `--height-cm=12` などを足すと入力した高さを `declaredSize` に付けます（付けなければ null）。`--free` を付けると、自由に撮った立体の合成セッション（写真 4 枚・基準もマスクも無し。`--height-cm` も使える）を送ります。受信サーバーは受け取るたびに release の `memoria-pack` を動かすので、続けて `for_claude/` も確かめられます。

## 決めたこと・分かったこと

白いマウス（Logitech G Pro X Superlight、実物は約 12.5 × 6.4 × 4.0 cm）を撮ったセッションで、生成の方法を比べました。生成は範囲の外ですが、ここで作る入力が役に立つかを確かめるためです。

| 方法 | 結果 |
|---|---|
| 写真測量（`tools/reconstruct`、Mac の `PhotogrammetrySession`） | 1 周 8 方向では形にならない（机の天板だけ）。48 方向の撮影（53 枚）で 48 枚の位置が決まり、medium で約 21 秒。マウスと分かる形だが、なめらかすぎて黒いムラがあり、底は無い。白く模様の無い物は苦手。ARKit のカメラの姿勢と K は渡せない（写真から推定し直す） |
| Claude Code が写真を見て Blender のスクリプトで組み立てる（2 分） | 約 53 秒。卵形や円柱の組み合わせで、質は低い。`for_claude/` だけを渡した別のエージェントは 24 秒で、質は同程度。寸法は実測に基づくようになった |
| Hunyuan3D-2.1（Mac の中、写真 1 枚） | 生成 96 秒、全体で約 2 分 10 秒、メモリは最大約 23 GB。手元の方法の中では形が一番良いが、色は付かない。幅が約 1 割広い |
| Tripo（クラウド、Web 版、写真 1 枚） | 一番良い。形と色が一度に出る。約 2 分半〜3 分、約 197 万面と重い。写っていない部分は想像で作る。無料のプランでは作ったモデルが公開になる |
| Tripo のマルチビュー（前・左・右・背面） | Web 版の無料のプランでは使えない（有料プランが要る）。API にはマルチビューがあるが、試していない（API の残高は Web 版のクレジットと別。チャージとキーが要る） |
| AI エージェントに 14 分で作らせる（48 方向の輪郭から形を削り、写真の色を投影） | 約 15.5 分かかり、5.5 × 4.0 × 12.0 cm と小さめ。表面はでこぼこで、色はぼやけて二重。写真測量と同じくらいの質 |

分かったこと：

- 入力のデータ（方向別の写真・切り抜き・実寸・向き）は役目を果たしていて、品質を決めているのは生成の方法です。生成 AI（物の形の知識で補う）が強い、という結果でした。役割は「撮影アプリと `for_claude/` が入力をそろえる → AI エージェントが写真を選んで整え、生成を頼み、できたモデルを実寸と向きに合わせて確かめる → 生成 AI が形と色を作る」が合っていそうです。
- ARKit のカメラの姿勢は、写真ごとに数 mm ずれます。撮影の案内や切り抜きには十分ですが、輪郭を重ねると形が痩せ、色を投影すると二重になります。
- 底の位置（基準点）は、方法によって数 mm〜数 cm ずれます（iPhone の下端で測ったセッションでは約 2 cm 低かった）。48 方向のセッションでは `memoria-pack` が hull から机の面を推定し直します。
- 以上を受けて、ユーザーが **「AI に推論させながら作る」** 方針に切り替え、既定の撮影を `ai5` にしました。
- 背景を消した写真（cutout）は既定では作りません。読み手は写真を見る AI で、背景付きの写真で作品を見分けられるためです。要るときだけ `memoria-pack --cutouts` で、iPhone のマスクから透明な PNG を作ります。
- iPhone ではマスクを作り続けます（作品が写っているかの確認に使う）。ただし `ai5` で撮り直させるのは **はっきり失敗したときだけ** です（作品が見つからない・マスクの大半が作品の外など。決まりは [docs/data-format.md](docs/data-format.md) の「マスクの確かめ」）。マスクの確かめのしきい値（`MaskCheckThresholds`）は、マウスの撮影だけで決めた値です。
- 作品の種類（立体・平面）は **撮る人が選びます**。紙に毛糸を貼った絵のような中間の作品を自動で見分ける仕組みは作らない、とユーザーが決めました。
- 平面の作品はマスクを作りません（紙の四隅が作品の範囲の代わり）。撮り直しもマスクでは決めず、真上の写真が 1 枚あればそろったとみなします。紙が見つからない・端にかかっている・真上でない写真は「気になる写真」に出すだけで、撮る・送るのは止めません。
- 平面の作品の大きさは、ARKit の平面に四隅を当てて **測れたときだけ** 書きます。測れなければ null で、`brief.md` も「分かりません」と書きます。影・照り返しの検出は範囲の外です。（下の「大きさは撮る人が選ぶ・入力する」で、選んだ紙があればそちらを優先するようにしました。）
- **大きさは撮る人が選ぶ・入力する**（ユーザーが決めたもの）：机の面（ARKit の平面）は認識されないことが多く、それに頼る部分は使いにくかったため、大きさは AR で測るのに頼らず、新しいセッションを作るときに撮る人が決めることにしました。平面の作品は紙の大きさを一覧（八つ切・四つ切・A4・B4・A3・B5・わからない）から選び、立体の作品は高さを cm で入れます（省略できる）。session.json の `declaredSize`（後から足した項目。無い・null は入力していない）に書き、AR に頼るのは iPhone の向きだけです。机が認識されなくても、選んだ・入力した大きさは変わりません。決めたこと：
  - ARKit の平面で測る処理（平面の作品の `photos[].flat.size`、立体の机の面）は消さずに補助として残し、**選んだ大きさは `declaredSize`、測った大きさは今までの場所** と分けます。
  - 優先順：平面の紙の大きさは 選んだ紙 → 測った実寸 → 分かりません。補正した画像の縦横比も選んだ紙を先に使います。立体の高さは、入力した値を写真から求めたおおよその大きさより優先するよう AI に伝えます（`brief.md`・`measurements.json` の `declaredHeight`）。求めた大きさは書き換えず、縮尺も掛けません。
  - 紙の縦・横の向きは session.json に書かず、使う側で四隅（補正した画像）の形から決めます（横が縦以上なら横が長い辺）。四隅が無ければ向きは決めません。
  - 紙の一覧は CaptureCore の `SheetPreset` の 1 か所です。受信サーバーは一覧に無い id も受け付けます（値の範囲だけを確かめる）。
  - 一覧に無い紙は「その他」で縦と横を入力します（ユーザーが決めたもの）。記録は同じ `declaredSize.sheet` で、`id` は `custom`、長い辺・短い辺は入力の大きい方・小さい方。`SheetPreset` には入れず、表示名は「その他」（寸法が要る所では「その他（21.0 × 30.0 cm）」）。
- **立体は自由に何枚でも撮るのを既定にする**（ユーザーが決めたもの）：案内つきの撮り方（向きで案内・底の中心と円柱）は撮る人には難しく、実機でも試せていなかったため、立体も平面と同じく「基準を作らない・マスクを作らない・向きはカメラの傾きだけ」の撮り方にし、案内も自動撮影もなくしました。どの写真がどの向きかは AI が写真を見て決めます。決めたこと：
  - session.json の `guidance` に `"free"` を足し（今ある値は変えない）、撮る方向の一覧 `free`（方向 0 個）を足しました。方向が 0 個の一覧は `free` だけです。新しい立体のセッションの既定は `free` で、案内つきの撮り方は設定の「立体の撮り方」で選びます（そのときだけ「撮る方向」を使う）。設定に保存した値が無ければ `free` です（前に案内のしかたを選んで保存した人は、その値のまま）。
  - 進み具合は 1 枚以上で「そろった」。枚数の上限なし、撮り直しは求めません。
  - 実装は平面の作品（`FlatCaptureController`・`FlatCaptureView`・`FlatPack.swift`）を手本にし、用紙の検出・補正・実寸を除いた形です。写真の詳細は平面の作品の画面（`FlatPhotoDetailView`）を使います。
  - `memoria-pack` は撮った順の写真（16 枚まで。多いときは均等に選ぶ）と `brief.md` だけを作り、大きさは写真から求めません。`overview.jpg` は、今の作り方が向きで並べるため作りません。
- `ai5` の大きさは **おおよそ** です。使えるマスクが 8 枚未満では visual hull を作らず、前の方法では撮影のときに合わせた円柱の大きさを `status: "approximate"`・`confidence: "low"` で書きます。
- **向きで案内する撮影**（ユーザーの案）：前の方法で人がつまずき、誤差も出ていたのは、撮る前に底の中心と円柱を合わせるところでした（位置と机の高さはずれやすく、iPhone の向きはとても正確）。そこで撮るときは向きだけで案内し、作品の位置・大きさは撮ったあとに写真から求めることにしました。作品が中央にあるかは撮る人が十字で合わせます（マスクは違う物を選ぶことがあるため、案内には使わない）。決めたこと：
  - 方法は session.json の `guidance`（後から足した項目。無ければ前の方法）に書き、今あるセッションは作ったときの方法のまま。向きの案内は `ai5` だけ（48 方向などは底の中心と円柱）。撮る方向の一覧・許容は `ai5` と同じ。
  - その場で回しただけで条件を満たさないよう、ARKit の位置は確かめにだけ使う（今の線と正面の線が両方のカメラの前 8 cm〜2.5 m で交わる、距離の比が 3 倍以内、10 cm 以上動いた、など。値は CaptureCore の `HeadingPosition` の 1 か所）。
  - 撮ったあとの中心は、方向ごとの代表の写真の画面の中心の線に一番近い点。線がほぼ平行・写真が足りないときは「分からない」にする。机の面は、撮影中に ARKit の平面か特徴点で測れたときだけ使い、測れなければ底の高さは「分からない」（原点は中心）。
  - 大きさは切り抜きの外接長方形から、箱の当てはめ（角ばった物で正しく丸い物で小さい）と中心の面での広がり（丸い物で近く角ばった物で大きい）の幾何平均。どちらも同じ CaptureCore のコードを iPhone と `memoria-pack` が使う。切り抜きが使えなければ大きさは null。
  - 切り抜きは十字のまわりの正方形から作る（撮ったあとに中心と大きさが分かっても作り直さない）。撮り直しは `ai5` と同じく、はっきり失敗したときだけ。
- 実物の白いマウス（約 6.4 × 12.5 × 4.0 cm）を前の方法で撮った 48 方向のセッションから、正面・右・後ろ・左・真上に近い 5 枚の姿勢とマスクを使って、撮ったあとの計算を試しました（前の案内で撮った写真なので、作品は画面の中央にきっちりは無い。目安です）：向きの差は右 89.6°・後ろ 173.7°・左 265.8°（理想との差 −0.4°・−6.3°・−4.2°）。中心は線の外れが二乗平均 3.2 cm で、左の 1 枚（外れ 5.2 cm）を除くと 1.7 cm・`ok`、手で決めた基準の円柱の中心から 1.8 cm（水平 1.3 cm）。大きさは 6.5 × 12.7 × 4.4 cm（下の目安 5.6 × 11.9 × 2.3、上の目安 7.6 × 13.7 × 8.4。高さが形しだいなので信頼度は低い）。求めた箱の底は、iPhone の下端で測った基準点より約 2 cm 上で、この基準点が約 2 cm 低かったことと合っています。

## 守ること

- **転送は同じネットワークの中だけ。** 通信は暗号化しない HTTP です。この Mac は公開 IPv4 が直接付くネットワークにいたことがあり、そのとき 0.0.0.0 で待ち受けていた受信サーバーにインターネットのスキャナーが届きました。それ以来、受信サーバーはループバック・プライベート・リンクローカル・IPv6 の ULA からの接続だけを受け、iPhone も公開アドレスへは送りません（[docs/transfer-protocol.md](docs/transfer-protocol.md)）。この判定をゆるめる変更をしないでください。`--allow-remote` はふだん使いません。Mac に公開アドレスしか無いときは、USB ケーブルか iPhone のインターネット共有でつなぎます。
- **`captures/sessions/` に書き込まない。** 元のデータです。派生データは `for_claude/`・`reconstructions/` などの別のフォルダに作ります（ツールも `sessions/`・`incoming/` への出力を断ります）。
- **`captures/incoming/` を読まない・使わない・消さない。** 転送の途中のデータで、受信サーバーが使います。
- **`captures/.receiver.json` の中身を出さない。** ペアリングコードと受信機の ID が入っています。ペアリングコードや接続先の IP アドレスをファイル・コミット・PR・チャットに書かないでください。
- **画像を外部に送るのはユーザーが決めること。** 写真は子どもの作品や身の回りを写した個人のデータです。受信サーバーとツールは外へ何も送りません。画像や session.json をクラウドの AI・生成サービスに渡すのは外部への送信なので、ユーザーがはっきり頼んだときだけにします。
- **秘密の値をコミットしない。** API キー・`.env`・パスワード・ペアリングコード・端末の UDID・メールアドレスなどです。**tka_2610 は公開のリポジトリです**（GitHub の `jphacks/tka_2610`。`main` に入れると memoria の Web が自動で公開される）。ホームディレクトリの絶対パスも、リポジトリからの相対パスで書けるときは書きません。
- **Team ID のような、Mac や人ごとに違う値は、git に入らないローカルのファイルに書く。** 署名の Team ID と、手元の memoria の接続先（`MEMORIA_WEB_SCHEME`・`MEMORIA_WEB_HOST`。Mac の名前が入る）は `ios/Config/Local.xcconfig`（`.gitignore` 済み）に書き、`project.pbxproj` などコミットするファイルには書きません。ほかにも同じ種類の値を足すときは、ローカルのファイルと、空の値の example を用意します。
- **コミットメッセージや PR の説明に、AI ツールの署名（`Co-Authored-By` や「Generated with」など）を入れない。**
- **コミットメッセージは英語**（今までの履歴と同じ書き方）。ドキュメントとアプリの文言は日本語です。
- **アプリの中で開くのは、設定した memoria の接続先だけ。** 橋渡しの知らせは、その接続先のメインのフレームからだけ受けます（`WebOrigin`）。この判定をゆるめない・ほかの接続先をアプリの中で開かないでください。Info.plist の ATS の設定（`NSAllowsArbitraryLoads` は false、`NSAllowsLocalNetworking` は true）も変えません。
- **橋渡しの決まり（知らせ・返事・`window.MemoriaNative`）を変えるときは、`docs/web-bridge.md`・CaptureCore の `WebBridge.swift` とテスト・アプリの `Web/`・tka_2610 の `web/src/native/bridge.ts` を一緒に変える。** 失敗の文言は Web がそのまま画面に出すので、短い日本語にします。
- **撮影画面のカメラの映像は、写真と同じ範囲を出す。** 4 つの撮影画面（`CaptureView`・`FreeCaptureView`・`FlatCaptureView`・`HeadingCaptureView`）は、どれも共通の入れ物 `UI/CameraPreviewContainer.swift` に ARSCNView を渡します。入れ物は映像を写真と同じ縦横比（今の形式は縦 3:4。使っている映像の形式 `videoFormat.imageResolution` から決め、分からない間は 3:4）にして画面の幅に合わせ、余った上下を黒い帯にします（標準のカメラと同じ）。前は ARSCNView を全画面（`ignoresSafeArea`）に広げていたため映像の左右が切れ、画面より写真の方が広く写っていました。ARSCNView を全画面に戻さない・撮影画面ごとに別の置き方を作らないでください。置き方と、写真の点 ↔ 画面の点の計算は CaptureCore の `CameraPreview`（テストは `CameraPreviewTests`）です。映像の上に描く印（十字・紙の輪郭）は入れ物の `overlay`（ARSCNView と同じ大きさ・座標）に置き、`UIScreen` の大きさや画面の全体の中心を使わないでください。
- **session.json の形を変えるときは、`docs/data-format.md`・`CaptureCore` の型・受信サーバーの検証・Mac のツールを一緒に確かめる。** 足す項目は無くても読めるようにし、取れない値は推測で埋めず `null` にします。

## 作業の進め方

ユーザーの決めた進め方です。

- メインのセッションは、指示・判断・設計をします。
- 実装やそのほかの手を動かす作業は、Opus 5.5 のサブエージェントに任せます。
- メインのセッションは、サブエージェントの差分を自分で見てからユーザーに報告します（テストを自分でも実行して確かめる）。

## 未対応・予定

- **向きで案内する撮影は実機で試していません。** 作ったときは iPhone の空き容量が足りず（約 9.8 MB 要るところ 0.6 MB）、入れられませんでした。確かめたのは CaptureCore のテスト（合成したカメラ・雑音・平行な線など）、`capture-e2e --heading` から受信サーバー・`memoria-pack`・MCP までの流れ、前の方法で撮った実物のセッションの姿勢とマスクを使った計算だけです。実機で確かめること：
  - 十字が写真の中心と合っているか（撮った写真の中央に作品があるか）。
  - 向きの許容（±15°）・見下ろす角度の許容（±12°）と自動撮影が、歩きながらで撮りやすいか。右・左のどちらへ回っても案内が合うか。
  - その場で回したとき十字が橙になり撮れないこと、作品のまわりを歩けば緑になること（`HeadingPosition` のしきい値が厳しすぎ・ゆるすぎないか。特に後ろ・真上、小さい作品の近くから撮るとき）。
  - 距離の目安（「少し近づいて・離れて」）がうるさくないか。
  - 確認画面に出る中心の線の外れ（2 cm 以下が目安）と、おおよその大きさが実物に近いか（角ばった物と丸い物の両方で）。机の面が見つかるか（白い机）。
  - 十字のまわりの切り抜き（短い辺の 0.7 倍の正方形）で、作品が大きい・小さいときに Vision が作品を選ぶか。
- **自由に撮る撮影（`guidance: "free"`）・紙の「その他」・選んだ紙と入力した高さ（`declaredSize`）は、実機では確かめていません。** 作ったときは Swift のコンパイラが無い環境でしたが、そのあと Mac で `swift test`（CaptureCore・claude-pack・reconstruct）とアプリの `xcodebuild`（署名なし）が通ることを確かめています。実機で確かめること：
  - 自由に撮る撮影画面（シャッター・枚数・目安の文・入力した高さ）、確認画面・写真の詳細・送信で、方向・基準・マスクの表示や警告が出ないこと、新しいセッションの「その他」の縦と横の入力と注意。設定の「立体の撮り方」（自由に撮るが既定）。
  - 新しいセッションの画面（平面の「紙の大きさ」の一覧、立体の「高さ（cm・分かれば）」の入力と、範囲の外の注意）、撮影画面と確認画面の「紙：八つ切（選んだ大きさ）」・入力した高さの表示、選んだ紙で補正した画像の縦横比と向き（縦長・横長の紙の両方）。
  - 前のアプリで「案内のしかた」を選んで保存していた端末では、その値が残り、自由に撮るにならない（設定で選び直す。memoria から頼まれた撮影は設定によらず自由に撮る）。
  - `capture-e2e --free --height-cm=8`・`--flat --sheet=yatsugiri`・`--heading --height-cm=12` から受信サーバー・`memoria-pack`・MCP までの流れ（Mac だけで確かめられる）。
- **撮影画面の映像と写真が同じ範囲か（実機で確かめること）**：作品を画面の端から端まで入れて撮り、保存した写真に同じ範囲が写っているか（余白が増えないか）。平面の作品の紙の輪郭が紙に重なるか、紙が映像の端にかかると「はみ出しそう」と出るか。向きで案内する撮影の十字の中心が写真の中心か。前の方法の照準（底の中心）が映像の中心に出るか。memoria からの撮影（「やめる」・「これで登録」）と開発用の画面の両方で、ナビゲーションバーが映像を隠さないか。置き方の計算は CaptureCore のテスト（iPhone 15・SE・15 Pro Max の大きさ）と、シミュレーターで置き方だけを見て確かめています。
- **memoria の入れ物（Web と橋渡し）で、実機でしか確かめられないこと**：アプリの中の 3D の家の表示とメモリ（撮影中に Web の処理が落ちないか。落ちたら撮影のあとで読み込み直し、結果を `pendingCapture` で渡すか）、Web の写真の選択・動画・声の記録（カメラ・マイクの許可）、画面の上下の余白（`viewport-fit=cover`）、アプリを閉じても同じ家か、家の引き継ぎ、平面の補正した画像・立体の写真の向き（Web のフォームでまっすぐか）、「これで登録」「やめる」と開発用の画面の行き来。橋渡しの決まり（知らせの確かめ・返事の形・代表の写真・家のリンク）は CaptureCore のテストで、写真を回す計算は Mac で確かめています。
- 向きで案内したセッションで、撮ったあとに中心と大きさが分かっても、切り抜きを作り直していません（十字のまわりのまま）。作品が切り抜きからはみ出すときは、求めた箱の範囲で作り直す案があります。
- 向きで案内したセッションでも、撮影画面を開き直すと正面から撮り直しになります（世界座標が変わるため）。前の方法で基準を設定し直すのと同じです。
- **memoria の入れ物にした版（`ai5`・平面・自由に撮るを含む）は、開発の iPhone に入れて起動するところまで確かめました。** `ai5`・平面の作品・自由に撮る撮影と、memoria からの撮影の流れは、実機ではまだ試していません。
- **平面の作品で、実機でしか確かめられないこと**：撮影画面の紙の輪郭（Vision の四角の検出と、画面の座標への変換）、自動撮影のしきい値（傾き 70° 以上・角の動き 1.5%・0.8 秒）、ARKit の平面に四隅を当てた実寸の精度（白い机・白い紙で平面が見つかるか）、`CIPerspectiveCorrection` の向き（補正した画像の上が、撮る人が画面で見ていた上になるか）。計算そのもの（四隅の並べ方・実寸・補正した画像の大きさ）は CaptureCore のテストと `capture-e2e --flat` で確かめています。
- **作品としての正面を撮影のあとで選べるようにする。** 今はデータの「正面」が最初に撮った方向で、マウスではお尻側になりました。生成 AI のマルチビューの「前」には作品の正面が要ります。それまでは、作品の正面から撮り始めてもらいます。
- **写真ごとのカメラの情報を、AI が使いやすい形で `for_claude/` に入れる。**
- **低い角度の写真を足す**（真横に近い高さからの写真。上面の形や高さを見るため）。
- **Tripo の API のマルチビュー** は試していません。API へのチャージとキーが要ります（キーはユーザーが設定し、リポジトリには入れない）。
- 撮影の途中で基準をやり直すと、同じセッションのまま撮り続けられます。作品や周りを動かしたかを聞いて、動かしたなら別のセッションに分ける案があります。
- 人の体のように間違った物しか見つからない写真では、タップで作品を選び直せません（撮り直すしかない）。
- `captures/for_ai/` は、48 方向のセッションから 5 枚を手で抜き出した実験用のフォルダです。ツールは作りません。
- Claude Code・Codex から使う MCP サーバーは `mcp-server/` にあります。説明は `mcp-server/README.md` を見てください。
