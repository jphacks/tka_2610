# memoria-pack（AI ツール向けの入力を作る Mac のツール）

受信サーバーが受け取った撮影セッション（`captures/sessions/<sessionId>/`）から、Claude Code などの AI エージェントが作品の 3D モデルを作るときの入力一式を `captures/for_claude/<sessionId>/` に作ります。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

元の写真はセンサーの向き（横向き）のままで、作品は画面の 1〜2 割しかなく、どの写真がどの向きかは session.json を読まないと分かりません。大きさも書かれていません。このツールは、代表の向きの写真を選んでまっすぐに回して切り抜き、実寸を測り、撮れていない範囲を書き出します。

- **Mac の中だけで動きます。** 何も外へ送りません。できた画像を Claude などのクラウドのツールに渡すのは外部への送信で、するかどうかはユーザーが決めます（`brief.md` にも書いてあります）。
- 元のセッション（`sessions/`）には書き込みません。`incoming/`（転送の途中）は読みません。
- session.json は iPhone アプリと同じ `ios/Packages/CaptureCore` の型と幾何で読みます。使うのは Foundation・simd・CoreGraphics・ImageIO・CoreImage だけです。

必要なもの：macOS 14 以降、Xcode（Swift 5.9 以降）。

## 使い方

```sh
cd tools/claude-pack
swift build -c release
.build/release/memoria-pack <セッションのフォルダ | sessionId | sessionId の先頭> [--data-dir captures] [--force] [--cutouts]

# 例
.build/release/memoria-pack CEB6
```

| オプション | 意味 |
|---|---|
| `--data-dir` | 受信フォルダ（既定：今のフォルダから上へ探した `captures/`、無ければ `capture/captures/`） |
| `--force` | 作り直す。既定では、同じ manifestHash・同じツールの版・同じオプションで作った `for_claude/<sessionId>/` があれば何もしない |
| `--cutouts` | `views/<向き>_cutout.png`（iPhone のマスクの外を透明にした PNG）も作る。既定では作らない（読み手は写真を見る AI なので、背景付きの写真を渡す） |

受信サーバー（`receiver/memoria_receiver.py`）は、セッションを受け取るたびに `.build/release/memoria-pack` があれば裏で動かします（受信の応答は待たせない。失敗はログに 1 行）。無ければ、ビルドの方法を一度だけ表示します。

出力は一時フォルダに書いてから rename で置き換えるので、途中の状態は見えません。白いマウスの 53 枚のセッションで 1 秒ほどです。

## 出力（`captures/for_claude/<sessionId>/`）

```
brief.md                 最初に読む説明（日本語）：作品名、実寸と誤差と求め方、座標の決まり、写真の一覧（方位・仰角・距離・photoId）、
                         撮れている範囲（仰角の範囲・底面は無い・写真の無い向き）、使えない切り抜き、AI での使い方、出どころ
overview.jpg             選んだ写真の一覧（3 × 4、ai5 は 3 × 3。カメラが立っていた位置に並べ、上から見た配置で正面が下、中央が上から）と実寸。長い辺 2000 px 以下
views/<向き>.jpg          まっすぐに回し（displayRotationDegClockwise）、作品のまわりで切り抜いた写真（背景は写ったまま）。長い辺 1568 px 以下、元より大きくしない
views/<向き>_cutout.png   `--cutouts` のときだけ：同じ範囲で、iPhone のマスクを透明度にした PNG（マスクの外は透明、縁は 1 px ほどぼかす）。使える切り抜きが無い向きは作らない
measurements.json        実寸（下の「実寸の測り方」）
hull.obj                 visual hull の粗い形（ボクセルの外側の面。メートル、+Y が上、+Z が正面、y = 0 が机の面）。hull を作れたときだけ
pack.json                写真の選び方（向きごとの photoId・実際の方位と仰角・切り抜きの範囲）、撮れている範囲、使えない切り抜き、出どころ、時間
```

### 平面の作品（`workKind` が `flat`）

撮影アプリで「平面（絵・貼り絵など）」を選んだセッション（撮影方向 `flat1`、真上から 1 枚）は、3D 用の出力を作りません。

```
brief.md            「平面の作品です」「3D の形を推論・再構成する必要はありません（絵を板や額に貼る形で使える）」、紙の大きさ（撮る人が選んだ値か測った値）か「分かりません」、注意点
views/artwork.jpg   遠近を直してまっすぐにした絵（iPhone が作った rectified/<photoId>.jpg を長い辺 1568 px 以下にしたもの）。
                    補正した画像が無いとき（紙が見つからなかったなど）は、元の写真をまっすぐに回しただけのもの
views/photo.jpg     補正した画像があるときだけ：元の写真をまっすぐに回したもの（補正が正しいかを見比べる）
measurements.json   workKind "flat"、method "declaredSheet"（撮る人が選んだ紙）か "flatSheetCorners"（ARKit の平面で測った）、
                    sheet（source "declared" | "measured"、widthM・heightM・widthCm・heightCm（幅は絵の横、高さは縦）、
                    longSideM・shortSideM・longSideCm・shortSideCm、orientation "landscape" | "portrait"、
                    declaredSheetId・declaredSheetName（選んだ紙。縦と横を入力した「その他」は id "custom"・名前「その他」）、planeSource（測った値のとき）、measured（測った値があればいつも）、photoId）。
                    どちらも無いときは status "unavailable"・sheet null と理由（推測で埋めない）。sizeCm・sizeM は null
pack.json           workKind "flat"、views（artwork・photo）、flat（使った写真・紙の四隅・紙が端にかかっているか・補正した画像の場所・カメラの傾き）
```

- 紙の大きさの優先順：撮る人が一覧から選んだ紙（session.json の `declaredSize.sheet`）→ ARKit の平面で測った実寸（`photos[].flat.size`）→ 分からない。選んだ紙の縦・横の向きは、`views/artwork.jpg` が補正した画像ならその縦横、そうでなければ紙の四隅の辺の長さで決めます（横が縦以上なら横が長い辺）。四隅も無ければ向きは決めず、`widthM`・`heightM` は null（`longSideM`・`shortSideM` だけ）で、`brief.md` に「縦・横の向きは分かりません」と書きます。選んだ紙と測った値の両方があるときは、選んだ紙を使い、測った値を `sheet.measured` と `brief.md` に参考として書きます。
- `overview.jpg`（方向の一覧）・`hull.obj`・`--cutouts` の PNG は作りません。マスクは使いません。
- 使う写真：置き換え済みでない（アプリと同じ決まり：一番新しい真上の写真が前の写真を置き換える）、真上（`targetId` あり）、補正した画像がある、紙の四隅がある、画質がよい、新しい、の順。

### 自由に撮った立体（`guidance` が `free`）

撮影アプリで案内なしに自由に撮った立体のセッション（撮る方向の一覧 `free`、方向は 0 個。基準もマスクも無い）は、向きの分かる出力を作りません。

```
brief.md            自由に撮った n 枚であること、向き・位置の案内はしていないこと、どの写真がどの向きかは写真を見て判断すること、
                    写真ごとの見下ろす角度、撮る人が入力した高さ（あれば優先）か「大きさは分かりません」
views/photo-01.jpg… 撮った順に、まっすぐに回した写真（切り抜きなし、長い辺 1568 px 以下）。16 枚より多いときは、撮った順に均等に 16 枚（最初と最後を含む）
measurements.json   method "freeCapture"、status "unavailable"（大きさは写真から求めない）、declaredHeight（入力した高さ。無ければ null）
pack.json           guidance "free"、views（photo-01…。方位は null、仰角は見下ろす角度）、free（photoCount・viewCount・selection "all" | "evenlySpaced"）
```

- `overview.jpg`（方向の一覧）は作りません（並べ方が向きに基づくため）。`hull.obj`・`--cutouts` の PNG も作りません。

### 向きと写真の選び方

**AI 用 5 方向（`directionPlan.id` が `ai5`）のセッション**：向きは `front`・`right`・`back`・`left`（それぞれ `a000-e15`・`a090-e15`・`a180-e15`・`a270-e15`）と `top`（`top-e90`、方位は問わない）の 5 つだけです。それぞれ、その方向として撮った写真（`direction.targetId` が同じ）を一番に選びます（その写真は、撮ったあとに求め直した方位・仰角が向きの許容から外れていても選ぶ）。`top` は仰角 60° 以上（アプリは 75° 以上で撮る）。

ほかのセッション：向きは `front`（方位 0°）・`front_right`（45°）・`right`（90°）・`back_right`（135°）・`back`（180°）・`back_left`（225°）・`left`（270°）・`front_left`（315°）を一番低い段（撮影方向の一覧の一番低い仰角、今は 20°）で、`top`（仰角 70° に一番近い写真。40° 以上、かつ一番低い段 ＋ 20° 以上）、`front_high`（方位 0°・仰角 45°）。

- 必ず守ること：方向が確定（`direction.confirmed`）、方向の確定した写真が一番多い基準（`referenceFrameId`。同じ数なら後の基準）、置き換え済みでない（アプリと同じ決まり）、許容の中（低い段は方位 ±25°・仰角 ±15°、`front_high` は仰角 ±12°）。
- その中で、使える切り抜き（`confirmed`、または `candidate` で `check` が `ok`）→ 確かめていない切り抜き（`check` の無い前の版）→ 使えない切り抜き、の順。次に保存した写真の画質（`quality.saved` の blur・brightness が ok）、次に角度の近さ。1 枚の写真は 1 つの向きにだけ使う。
- 切り抜く範囲：マスクの外接長方形に、長い辺の 20% の余白を足し、縦横比を 4:3 以内に広げ、写真の内側へずらす。マスクが使えないときは、作品の円柱を投影した範囲（`MaskCropPlanner.projectObject`）。向きで案内したセッションは、撮ったあとに求めた大きさの箱を投影した範囲（`cropSource: "projectedDerivedBox"`）、大きさも分からなければ写真の中央（十字）のまわりの正方形（`"crosshairCenter"`）。

### 向きで案内したセッション（`guidance` が `heading`）

撮るときに底の中心・円柱を決めていないので、円柱の目安はありません。作品の中心・作品座標・おおよその大きさは、撮ったあとに写真から求めた値（session.json の `referenceFrames[].heading.derivation`。決まりは [docs/data-format.md](../../docs/data-format.md) の「向きで案内する撮影」）を使います。iPhone がまだ求めていない（切り抜きを作っている間に送ったなど）ときは、`memoria-pack` が同じ計算（CaptureCore の `HeadingSizer.refresh`）をメモリの中で行います（session.json は書き換えない。`measurements.json` の `heading.computedBy` が `"memoria-pack"`）。

- `measurements.json`：`method: "headingDerived"`。大きさが分かれば `status: "approximate"`、`sizeM`・`sizeCm`（下の目安＝箱の当てはめ と 上の目安＝中心の面での広がり の幾何平均）、`confidence`（`normal` | `low`）と `confidenceReasons`、`bboxMinM`・`bboxMaxM`（大きさの箱）。分からなければ `status: "unavailable"` と `unavailableReason`（数字は書かない）。`heading` に中心の求め方（`derivationStatus`・線の外れ `residualRmsM`・使った写真・原点 `origin`）と大きさの全部（`lowerM`・`upperM`・`crossChecks` など）。
- 座標：x・z の原点は求めた中心、y = 0 は机の面（`origin: "base"`。ARKit で測れたとき）か、**求めた中心の高さ**（`origin: "center"`。机の高さが分からない。底ではない）。+Z は正面の写真の向きの反対。
- visual hull は作りません（`hull.obj` なし）。
- `brief.md` には、位置と大きさが撮ったあとに求めた値であること、線の外れ（2 cm 以下ならおおむね合っている）、机の面が分かったか、下と上の目安、信頼度が低い理由を書きます。
- `pack.json` の `guidance` に案内のしかた（`heading` | `baseCylinder`、平面は null）を書きます。

### 撮る人が入力した高さ（立体の作品）

session.json の `declaredSize.heightM`（新しいセッションで撮る人が入力した高さ。AR で測った値ではない）があれば、どの立体のセッション（`heading`・`baseCylinder`・visual hull）でも：

- `measurements.json` の `declaredHeight` に `heightM`・`heightCm`・`source: "userEntered"`・`note` を書きます（無ければ null）。`sizeM`・`sizeCm`・`heading.size` などの求めた値・測った値は、今までどおりに書き、書き換えたり縮尺を掛けたりしません。
- `brief.md` の大きさの前に「高さ（撮る人が入力した値）」を書き、写真から求めた大きさよりこの高さを優先すること、幅・奥行きはこの高さとの比が写真と合うように決めることを書きます。

### 実寸の測り方（visual hull）

向きで案内したセッションは上の決まりです。それ以外で、使えるマスクのある写真が 8 枚未満（ai5 の 5 枚など）のときは hull を作りません（数枚の輪郭から削った箱は、見かけより不確かなため）。代わりに、撮影時にユーザーが AR のガイドで合わせた円柱（直径 × 直径 × 高さ）を `status: "approximate"`・`method: "userCylinder"`・`confidence: "low"` で書き、`brief.md` にも「目安。実測ではありません」と書きます。`hull.obj` は作りません。

1. 多数派の基準の、追跡が `normal` で使える（または確かめていない）マスクのある写真を全部使う（白いマウスでは 49 枚）。マスクは 1/4（長い辺 1008 px）に縮める。
2. 基準の円柱（`referenceFrames[].object`、無ければ `object`）の半径・高さの 1.3 倍の範囲を 2 mm のボクセルに分け（多すぎると 160³ を上限に粗くする）、基準点の下にも半径の半分まで広げる。
3. ボクセルの中心を各写真に投影し（`objectToWorld` → `cameraToWorld` の逆 → K を画像の大きさに合わせる。ARKit のカメラは +X 右・+Y 上・−Z 前、画素の y は下向き）、マスク（1 px 広げる）の外に落ちた写真が、見えている写真の 10% を超えたら削る。画像の外・カメラの後ろは「分からない」で削らない。2 枚以上に写っていないボクセルは残さない。一番大きなつながりだけ残す。
4. **机の面を hull から推定する。** 作品の下の机の中は、作品に隠れてどの写真からも見えないので、hull に「くさび」が残る（足元の縁からの距離 d、カメラの仰角 e のとき、深さ d·tan e）。列ごとに「一番下のボクセル ＋ その深さ」を求めた中央値を机の面とし、それより下を捨てて y = 0 にする。撮影時の基準点は数 mm〜数 cm ずれることがあり（白いマウスでは 2.1 cm 下）、そのまま使うと高さが大きく狂うため。
5. 外接箱（幅 X・奥行き Z・高さ Y）、上から見た最小の長方形、体積（ボクセル数 × 体積）を書く。

誤差：`±` は ボクセル ＋ 写真ごとの「マスクの外接長方形と hull の投影の差」の中央値。ほかに、

- 高さは大きめに出る：写真はどれも上から見下ろしているので、上面が平らだと上面の上の空間を削れない。最大の量（`heightOverestimateUpToCm`）も書く。
- visual hull は凹み・穴・底を埋める。底面は写っていない。
- 写真が少ない（12 枚未満）、輪郭のずれが 5 mm を超える、確かめていないマスクがある、のどれかで `confidence: "low"`。輪郭が合わないと実物まで削られ、± を超えて小さく出ることがある。

### 実際のセッションでの結果

| セッション | 実物 | 結果 |
|---|---|---|
| CEB6B0BC（白いマウス、48 方向、53 枚） | Logitech G Pro X Superlight：12.5 × 6.4 × 4.0 cm | 奥行き 12.4 × 幅 6.2 × 高さ 4.9 cm（±0.5、高さは最大 0.9 cm 大きめ）、49 枚、机の面は基準点の 2.1 cm 上 |
| 844B473E（同じマウス、前の版の 8 方向、基準 2 つ・マスク未確認） | 同上 | 10.8 × 3.6 × 3.2 cm、9 枚、信頼度 low（輪郭のずれ 1.1 cm）。写真の切り抜きと一覧は使える。`top` は写真なし |

## 確認

```sh
swift test   # 写真の選び方（角度・切り抜き・置き換え済み・基準・ai5 の 5 方向）、向きで案内したセッションの出力（中心と大きさをここで求める・iPhone の値を使う・マスクが無いと大きさ不明で中央を切り抜く）、切り抜きと回転の計算と画素、透明の cutout、合成した箱の visual hull（大きさ・机の面）、
             # 5 方向のセッションの出力（背景付きの写真だけ・円柱の目安・--cutouts）、平面の作品の出力（補正した絵・実寸・大きさ不明）、JSON の形
```
