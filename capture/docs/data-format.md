# 撮影データの形式（session.json schemaVersion 1）

iPhone 側と PC 側で同じ形です。1 つの撮影セッションが 1 つのフォルダになります。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

```
<sessionId>/
  session.json            メタデータ（このファイルの形）
  photos/<photoId>.jpg    元写真（センサーの向きのまま。回転・縮小・切り抜きなし）
  masks/<photoId>.png     作品マスク（元写真と同じ幅・高さ・向き。8bit グレー、255 = 作品、0 = 背景）
  rectified/<photoId>.jpg 平面の作品だけ：用紙の四隅から遠近を直してまっすぐにした画像（作れたときだけ。下の「平面の作品」）
```

- `sessionId`・`photoId` は UUID（大文字、ハイフン付き）。ファイル名に使える文字はこれだけです。
- 元写真は上書きしません。マスクと補正した画像は別ファイルで、無い写真もあります（元写真がいつも正）。
- iPhone 側の転送状態（`transfer.json`）はセッションのフォルダにありますが、転送するファイルには入れません。
- iPhone 側の端末だけのメモ（`local.json`）も転送しません。中身は撮影順の控え（`lastSequence`）・ファイルのハッシュの控え（`fileHashes`）と、memoria の Web から撮って作品を登録したときの **memoria の作品とのつながり**（`memoria`。後から足した項目で、無いこともある）です。`memoria` は `{"artworkId": "<memoria の作品の id>", "origin": "https://…（登録した memoria の接続先）", "linkedAt": "2026-11-13T12:00:00Z"}` の形で、Mac へは送らず、session.json も `schemaVersion` も変えません（[web-bridge.md](web-bridge.md)）。

## 決まり（conventions）

`session.json` の `conventions` にも同じ内容を文字で入れます。

| 項目 | 決まり |
|---|---|
| 単位 | メートル、角度は度、時刻は ISO 8601（タイムゾーン付き）、`arFrameTimestamp` は秒（端末の起動からの時間） |
| 世界座標 | ARKit の world（`worldAlignment = .gravity`）。右手系、+Y が重力の反対（上）、原点は AR セッション開始時の端末位置。**同じ `referenceFrameId` の中でだけ意味を持つ** |
| 行列 | 入れ子の配列で **行優先**（`m[row][col]`）。点は列ベクトルで `p' = M · p` |
| `cameraToWorld` | ARKit の `ARCamera.transform`（カメラ → 世界）。カメラ座標は ARKit の決まりで、+X が保存した画像の右、+Y が画像の上、−Z が見ている方向。OpenCV 式（x 右・y 下・z 前）にするには右から `diag(1, −1, −1, 1)` を掛ける |
| `intrinsics` | 3 × 3 の K（行優先、ピクセル単位、原点は保存した画像の左上）。`intrinsicsResolution` の大きさの画像に対する値 |
| 画像の向き | 保存した画像はセンサーの向き（横長）のまま。EXIF Orientation は 1。`displayRotationDegClockwise` は、まっすぐ見るために時計回りに回す角度（表示用の情報で、K は回さない画像のもの） |
| 作品座標（objectToWorld） | 原点は作品の底面中央（基準マーカー）。+Y は上、+Z は基準点から正面のカメラへ向かう水平方向、+X = Y × Z（正面から見て右）。向きで案内した基準は撮ったあとに求める（下の「向きで案内する撮影」） |
| 方位角 `azimuthDeg` | 作品座標でのカメラ位置 (x, z) について `atan2(x, z)` を度にして 0〜360。0 = 正面、90 = +X 側（正面から見て右へ回り込んだ位置） |
| 仰角 `elevationDeg` | 作品の中心（基準点から `heightM / 2` 上）からカメラへのベクトルの水平面からの角度。上から見下ろすと正。向きで案内した基準では、撮ったあとに求めた中心から |

## session.json

```jsonc
{
  "schema": "memoria.capture.session",
  "schemaVersion": 1,
  "sessionId": "8B0F…",
  "title": "ねこの貯金箱",                 // 作品名（空文字可）
  "workKind": "object",                    // 作品の種類："object"（立体）| "flat"（平面）。後から足した項目（下の「平面の作品」）
  "guidance": "heading",                   // 立体の撮り方："free"（自由に撮る。新しいセッションの既定）| "heading"（向き）| "baseCylinder"（底の中心と円柱）。平面は null。後から足した項目（下の「向きで案内する撮影」「自由に撮る撮影」）
  "declaredSize": {                        // 撮る人が選んだ・入力した大きさ（AR で測った値ではない）。入力していなければ null。後から足した項目（下の「撮る人が選んだ・入力した大きさ」）
    "sheet": null,                         // 平面の作品：一覧から選んだ紙 { "id", "longSideM", "shortSideM" }。選んでいなければ null
    "heightM": 0.12                        // 立体の作品：入力した高さ（m）。入力していなければ null
  },
  "createdAt": "2026-11-09T10:00:00+09:00",
  "updatedAt": "…",
  "conventions": { "…": "上の表と同じ内容の文字列" },
  "device": { "model": "iPhone15,4", "systemName": "iOS", "systemVersion": "26.6",
              "appVersion": "0.1.0", "appBuild": "1" },
  "object": {                              // 作品の大きさ（ユーザーが AR のガイドで合わせた値）。最後に設定した基準の大きさ
    "heightM": 0.15, "radiusM": 0.08, "source": "userAdjusted"   // （前の版との互換のため。写真に使うのは referenceFrames[].object）
  },
  "referenceFrames": [                     // 基準を設定するたびに 1 つ増える
    {
      "id": "ref-1",
      "createdAt": "…",
      "basePointWorld": [0.1, -0.7, -0.4],
      "objectToWorld": [[1,0,0,0.1],[0,1,0,-0.7],[0,0,1,-0.4],[0,0,0,1]], // 正面が決まるまで null
      "frontPhotoId": "…",                 // 正面を決めた写真（最初の写真）。まだなら null
      "invalidatedAt": null,               // 中断・リセット・基準の再設定で無効になった時刻
      "invalidationReason": null,          // "sessionInterrupted" | "trackingLost" | "userReset" | "anchorDrift"
      "object": {                          // この基準を設定したときの作品の大きさ（上の object と同じ形）
        "heightM": 0.15, "radiusM": 0.08, "source": "userAdjusted"
      },                                   // この項目より前に作った基準は null（または無い）→ 上の object を使う
      "base": {                            // 基準点（basePointWorld）をどう求めたか。この項目より前に作った基準は null（または無い）
        "source": "featurePoints",         // 下の「基準点の求め方」
        "manualOffsetM": -0.005,           // 手で合わせた底の高さ（m、上が正）。basePointWorld はこれを足したあとの点
        "supportPoints": 34                // 机の高さの推定に使った特徴点の数（featurePoints のときだけ。ほかは null）
      },
      "heading": null                      // 向きで案内した基準だけ（下の「向きで案内する撮影」）。ほかは null
    }
  ],
  "directionPlan": {                       // 撮る方向の一覧（下の「撮影方向（directionPlan）」）。セッションを作ったときに決まり、あとで変わらない
    "id": "ai5",                           // "ai5" | "photogrammetry" | "ring8" | "ring4" | "ring8plusHigh" | "flat1"
    "targets": [
      { "id": "a000-e15", "azimuthDeg": 0, "elevationDeg": 15,
        "azimuthToleranceDeg": 15, "elevationToleranceDeg": 12, "anyAzimuth": false },
      { "id": "top-e90", "azimuthDeg": 0, "elevationDeg": 90,   // 方位を問わない方向（真上）
        "azimuthToleranceDeg": 180, "elevationToleranceDeg": 15, "anyAzimuth": true }
    ]
  },
  "photos": [
    {
      "photoId": "…",
      "sequence": 1,                       // 撮影順。削除しても番号は詰めない
      "capturedAt": "…",
      "trigger": "auto",                   // "auto" | "manual"
      "referenceFrameId": "ref-1",         // 基準が無いときは null
      "image": {
        "file": "photos/<photoId>.jpg", "format": "jpeg", "width": 4032, "height": 3024,
        "exifOrientation": 1, "displayRotationDegClockwise": 90,
        "deviceOrientation": "portrait"    // 撮影時の端末の向き（UIDeviceOrientation の名前）
      },
      "camera": {                          // 写真と同じ ARFrame（captureHighResolutionFrame の返り値）から取得
        "source": "captureHighResolutionFrame",
        "arFrameTimestamp": 12345.678,
        "cameraToWorld": [[…],[…],[…],[0,0,0,1]],
        "intrinsics": [[fx,0,cx],[0,fy,cy],[0,0,1]],
        "intrinsicsResolution": { "width": 4032, "height": 3024 },
        "exposureDurationS": 0.01,         // 取れないときは null
        "exposureOffsetEV": 0.0,           // 取れないときは null
        "trackingState": "normal",         // "normal" | "limited" | "notAvailable"
        "trackingReason": null             // limited のとき "initializing" | "relocalizing" | "excessiveMotion" | "insufficientFeatures"
      },
      "direction": {
        "confirmed": true,                 // false なら方向は参考値。撮影済みの方向として数えない
        "unconfirmedReason": null,         // "trackingNotNormal" | "noReference" | "referenceInvalidated"
        "targetId": "a000-e20",            // 当てはまる撮影方向。追加撮影・範囲外は null
        "azimuthDeg": 3.2, "elevationDeg": 21.0, "distanceM": 0.42
      },
      "quality": {
        "live": {                          // シャッター直前の解析結果
          "tracking": "ok", "inFrame": "ok", "direction": "ok", "motion": "ok",
          "brightness": "ok", "sharpness": "warning",   // "ok" | "warning" | "blocked" | "unknown"
          "warningsAcknowledged": true     // 警告を確認して手動で撮ったとき true
        },
        "saved": {                         // 保存した写真そのものを解析した結果
          "meanLuma": 0.46, "sharpness": 0.0021,        // 0〜1 の明るさ、ラプラシアンの分散（縮小画像）
          "brightness": "ok", "blur": "ok"
        }
      },
      "mask": {
        "status": "candidate",             // "notGenerated" | "processing" | "candidate"（自動で選んだ・未確定）
                                           // | "confirmed"（ユーザーが確認） | "failed" | "noObject"
        "file": "masks/<photoId>.png",     // candidate / confirmed のときだけ。ほかは null
        "width": 4032, "height": 3024,
        "method": "VNGenerateForegroundInstanceMaskRequest",
        "instanceCount": 2,                // Vision が見つけた物の数（番号は写真ごとの番号で、写真間で同じ物とは限らない）
        "selectedInstances": [1],
        "selection": "auto",               // "auto" | "user"
        "error": null,
        "inputRegion": { "x": 652, "y": 617, "width": 2447, "height": 2407 },
                                           // Vision に渡した範囲（写真のピクセル、原点は左上、センサーの向き）。全体なら null
        "inputRegionSource": "projectedCylinder",
                                           // "projectedCylinder"（作品の円柱を投影した範囲）| "fullImage"（写真の全体）
                                           // | "crosshair"（写真の中央のまわり。向きで案内したセッション）
                                           // まだ作っていない・この項目が入る前に作ったマスクは null
        "check": {                         // マスクが作品らしいか（下の「マスクの確かめ」）。まだ確かめていない・マスクが無いときは null
          "status": "ok",                  // "ok" | "suspicious" | "unknown"
          "reasons": [],                   // suspicious・unknown の理由（下の表）
          "insideSilhouetteRatio": 1.0,    // マスクのうち、作品の輪郭（少し広げたもの）の中にある割合。unknown なら null
          "cropCoverage": 0.14,            // マスクが切り抜き（inputRegion）に占める割合。unknown なら null
          "silhouetteAreaRatio": 0.27,     // マスクの面積 ÷ 作品の輪郭の面積。unknown なら null
          "centerOffset": 0.06,            // マスクの重心と作品の中心の距離 ÷ 輪郭の外接長方形の長い辺。unknown なら null
          "touchedCropEdges": 0            // マスクが届いている切り抜きの辺の数（0〜4）。unknown なら null
        }
      },
      "flat": null,                        // 平面の作品の写真で測ったもの（下の「平面の作品」）。立体の作品の写真は null
      "heading": null                      // 向きで案内した写真の、撮ったときの向き（下の「向きで案内する撮影」）。ほかは null
    }
  ]
}
```

- 取れない値は推測で埋めず `null` にします。
- 撮影に失敗した写真・保存に失敗した写真は `photos` に入りません。
- `direction.confirmed` が true になるのは、写真の `trackingState` が `normal` で、無効になっていない基準（`objectToWorld` あり）があるときだけです（向きで案内した基準では、正面の向きが決まっていること。下の「向きで案内する撮影」）。
- 別の `referenceFrameId` の写真どうしの姿勢は比べられません（同じ世界座標とは限らない）。
- 作品の大きさは、写真の `referenceFrameId` の基準の `object` を使います（無ければ上の `object`）。基準を設定し直すと上の `object` は新しい大きさになりますが、前の基準の写真は前の大きさで撮っています。`referenceFrames[].object` は後から足した項目で、無くても読めるので `schemaVersion` は 1 のままです。
- 基準点の求め方 `referenceFrames[].base.source`（`basePointWorld` は、どの方法でも最後に決めた点）：
  - `"existingPlaneInfinite"`：ARKit が見つけた水平の平面を延ばした面（平面の縁から 0.6 m 以内）と、画面の中心の線の交点。
  - `"existingPlaneGeometry"`：ARKit が見つけた平面の形との交点。
  - `"estimatedPlane"`：ARKit が推定した平面との交点。
  - `"featurePoints"`：ARKit の平面が無い（または床しか無く、机の方が線の上で手前にある）とき。ARKit の特徴点（`rawFeaturePoints`）のうち、画面の中心の線のまわりの円錐（半角 15°）にある最近 1.5 秒の点の高さの度数分布（5 mm ごと）から机の高さを推定し、線との交点を使う。推定なので数 mm〜1 cm ずれることがある（`supportPoints` が少ないほど不確か）。
  - `"deviceEdge"`：iPhone を縦に立てて下端を作品の横の机に当て、カメラの姿勢と機種ごとのカメラの位置（Apple の寸法図から読んだおおよその値。知らない機種はさらにおおよそ）から机の高さを測り、線との交点を使う。測ったあとの位置の見失い（ドリフト）があれば、その分ずれる。
  - `manualOffsetM` が 0 でないとき、基準点は「ここが底の中心」を押したときの画面の中心の線に沿って動かしてある（線が水平に近いときは真上・真下）。
  - `base` は後から足した項目で、無くても読めるので `schemaVersion` は 1 のままです。
- `direction.targetId` は `directionPlan.targets[].id` のどれか（形は下の「撮影方向（`directionPlan`）」）。
- 正面を決める 1 枚目（その基準の最初の確定した写真）の方位は 0° です。仰角が方位 0° の方向（一番近い仰角のもの）の許容に入っていれば、その方向の `targetId`（`a000-e20` など）が付きます。外れていると `targetId` は null で、正面の方向はあとで撮り直すことになるので、撮影画面は 1 枚目の前に高さを案内します（警告だけで、撮るのは止めない）。

## 撮影方向（`directionPlan`）

`directionPlan` はセッションを作ったときの一覧をそのまま書きます（あとで一覧の決まりを変えても、今あるセッションは変わらない）。PC 側は `id` で決め打ちせず、`targets` の値（方位・仰角・許容）を使ってください。

| `id` | 方向 | 方位の許容 | 仰角の許容 | 使いどころ |
|---|---|---|---|---|
| `ai5`（新しいセッションの既定） | 仰角 15° の正面・右・後ろ・左（`a000-e15`・`a090-e15`・`a180-e15`・`a270-e15`）＋ 真上 `top-e90`（計 5） | 横 ±15°、真上は問わない | 横 ±12°、真上 ±15°（75° 以上） | AI に数枚のよい写真から 3D を推論させる。重なりは要らない |
| `photogrammetry` | 仰角 20° で 15° ごとに 24、45° で 22.5° ごとに 16、70° で 45° ごとに 8（計 48） | 20° の段 ±7°、45° の段 ±10°、70° の段 ±20° | ±10° | Mac の RealityKit `PhotogrammetrySession` で 3D にする。隣の写真が大きく重なり、3 つの高さから撮る |
| `ring8` | 仰角 20° で 45° ごとに 8 | ±20° | ±15° | |
| `ring4` | 仰角 20° で 90° ごとに 4 | ±20° | ±15° | |
| `ring8plusHigh` | `ring8` ＋ 仰角 50° で 90° ごとに 4（計 12） | ±20° | ±15° | |
| `flat1` | 真上 `top-e90`（計 1） | 問わない | ±20°（70° 以上） | 平面の作品（`workKind` が `flat`）。仰角はカメラの傾きで測る（下の「平面の作品」）。設定画面の「撮る方向」には出さない |
| `free` | なし（計 0） | — | — | 自由に撮る立体の作品（`guidance` が `free`）。方向が 0 個の一覧はこれだけ（下の「自由に撮る撮影」）。設定画面の「撮る方向」には出さない |

- `targets` の順は、低い段から段ごと、段の中は方位 0° から増える順です。
- **方位を問わない方向**（`anyAzimuth: true`。今は `ai5` と `flat1` の真上 `top-e90` だけ）：真上では水平の成分がほぼ 0 で方位が定まらないので、**仰角だけ** で当てはめます（仰角の差が許容の中なら、写真の方位は何度でもよい）。古い読み手が方位で弾かないよう、`azimuthDeg` は 0、`azimuthToleranceDeg` は 180 を入れてあります。`anyAzimuth` は後から足した項目で、無ければ false（それより前のセッション）なので `schemaVersion` は 1 のままです。写真の `direction.azimuthDeg` には、真上でも計算した値（不安定な値）がそのまま入ります。
- どの一覧でも、隣の方向・隣の段の許容は重なりません（`photogrammetry` は 15° 間隔に ±7°、22.5° 間隔に ±10°、段の間 30〜35°・55〜60° はどの方向にも入らない）。重なる一覧を読むときは、許容で割った近さ（方位の差 ÷ 方位の許容 ＋ 仰角の差 ÷ 仰角の許容）が一番小さい方向、同じなら一覧の順で先の方向に当てはめます。
- **方向の `id`**：方位を問わない方向は `top-e<仰角>`（`top-e90`。正規表現では `^top-em?[0-9]{2}$`）。それ以外は `a<方位>-e<仰角>`。方位は 0 以上 360 未満を整数 3 桁（`a045`）、端数があるときは小数 1 桁を付けます（`a022.5`、`a337.5`。四捨五入して丸めない）。仰角は整数 2 桁、負なら `m` を付けます（`e20`、`em05`）。正規表現では `^a[0-9]{3}(\.[0-9])?-em?[0-9]{2}$`。同じ一覧の中で重複せず、同じ方位・仰角からはいつも同じ `id` になります。`id` はファイル名には使いません（写真のファイル名は `photoId`）。
- 撮影画面の案内（session.json には書かない）：向きで案内するセッションは上の「向きで案内する撮影」。前の方法の `ai5` は 正面 → 近い方の横（右か左）→ 後ろ → 残りの横 → 真上 の順に「正面・右・後ろ・左・真上」と名前で案内し、「n / 5」を出します。真上は「最後に真上から撮ります。iPhone を作品の真上に持ち上げて、画面を下に向けてください」と高さだけを案内します（回る向きは言わない）。ほかの一覧は、段を低い順（20° → 45° → 70°）に 1 段ずつ、段の中は歩いている向きのまま 1 周します（近い方向へ行ったり来たりしない）。撮りそこねた・撮り直しになった方向は、すぐ後ろでなければ 1 周の終わりに撮ります。上の段の途中で下の段の撮り直しが出たときは、上の段を終えてから下の段へ戻ります。
- 自動撮影の待ち時間（撮影のあと次の自動撮影まで）は、1 周に 13 方向以上の段がある一覧（`photogrammetry`）で 0.7 秒、ほかは 1.2 秒です。どちらも同じだけ止まってから撮り、撮影は 1 枚ずつです。

## 向きで案内する撮影（`guidance: "heading"`）

立体の作品の新しいセッション（撮る方向が `ai5`）の既定です。**新しい方法で、まだ実機で試しているところです**（AGENTS.md の「未対応・予定」）。撮る前に底の中心・円柱を決めず、作品を画面の中央の十字に合わせて撮ります。

- `guidance`（**後から足した項目**）：`"free"`（自由に撮る。**後から足した値**。下の「自由に撮る撮影」）、`"heading"`（向きで案内）か `"baseCylinder"`（底の中心と円柱で案内。前の方法）。新しい立体のセッションの既定は `"free"` で、案内つきの 2 つは設定で選びます。キーが無い・null の立体のセッションは `"baseCylinder"` として読みます。平面の作品は null。iPhone は書くときいつも書きます（`schemaVersion` は 1 のまま）。向きの案内は `ai5` だけで使い、ほかの一覧（`photogrammetry` など）はいつも `"baseCylinder"` です。今あるセッションは作ったときの方法のままです。
- 撮り方：作品を十字に合わせて正面を手で撮ります（この写真の向きが正面）。続けて、作品を十字に入れたまま、iPhone の **水平の向き** が正面から 90°・180°・270° 回った位置（右・後ろ・左。近い方の横から）を、見下ろす角度 15° 前後で撮り、最後に真上（見下ろす角度 75° 以上、向きは問わない）を撮ります。方向の一覧と許容は `ai5` と同じです（向き ±15°、見下ろす角度 ±12°）。
- 向き：画面の中心（十字。保存した画像の中心のピクセル）を通る線の水平の向き `atan2(−x, −z)`（度）。正面から右（+X 側）へ回り込むと増えます。見下ろす角度は、その線が水平から下へ傾いた角度（真下が 90）。
- その場で回しただけではないかの確かめ：向きだけなら、その場で iPhone を回しても条件を満たしてしまうので、ARKit の位置を確かめにだけ使います。今の線と正面（と、撮った横の写真）の線を水平に投影し、作品のあるはずの点が両方のカメラの前 8 cm〜2.5 m にあり、距離の比が 3 倍以内か（後ろはほぼ平行なので、正面の線の先にいて線から大きく横にずれていないか。真上は作品の推定の位置の上にいるか）を見ます。横・後ろ・真上は、正面の位置から 10 cm 以上動いていることも求めます。満たさない写真は `targetId` を付けずに保存し、確認画面の「気になる写真」に「狙った向きの外」と出します。
- 自動撮影：向き・見下ろす角度・位置の確かめがそろい、止まっているとき（前の方法と同じ 0.5 秒・3 回）。シャッターはいつでも押せます（狙った向きの外でも、測った向きのまま保存）。

### 撮ったときの記録

```jsonc
// referenceFrames[]（向きで案内した基準）
"basePointWorld": null,                 // 机の面が分かったときだけ（撮ったあとに求める）。分からなければ null
"objectToWorld": null,                  // 撮ったあとに求める。中心が分からなければ null
"frontPhotoId": "…",                    // 正面の写真（その基準の最初の確定した写真）
"heading": {
  "frontHeadingDeg": 6.95,              // 正面の写真の向き（度、世界座標）。正面を撮るまでは null
  "frontPitchDeg": 15.2,                // 正面の写真の見下ろす角度
  "derivation": { … }                   // 撮ったあとに求めたもの（下）。まだなら null
}

// photos[]（向きで案内した写真）
"heading": {
  "relativeHeadingDeg": 89.6,           // 正面からの向きの差（0〜360）。正面が無い・真下を向いていれば null
  "pitchDeg": 14.8,                     // 見下ろす角度
  "position": "ok",                     // 位置の確かめ："ok" | "notWalkedAround"（その場で回した・作品が中央に無い）| "notChecked"（正面そのものなど）
  "estimatedDistanceM": 0.31            // 撮ったときに推定した、作品までの水平の距離。分からなければ null
}
```

- 基準は正面を撮ったときに作られます（底の中心・円柱は無いので、`object` は null のまま）。撮影画面を閉じる・中断する・位置を見失うと基準は無効になり、次の写真が新しい正面になります（前の方法で基準を設定し直すのと同じ）。
- 正面を真上から撮ろうとした（見下ろす角度 60° 以上）・追跡が normal でないときは正面にならず、その写真の方向は参考値（`noReference`・`trackingNotNormal`）です。
- `direction`：撮ったときは、方位 = 正面からの向きの差、仰角 = 見下ろす角度、距離 = 推定した水平の距離（無ければ null）。撮ったあとに中心を求めると、中心から測った方位・仰角・距離に置き換わります（`targetId` は撮ったときのまま）。撮ったときの値は `photos[].heading` に残ります。

### 撮ったあとに求めるもの（`referenceFrames[].heading.derivation`）

前の方法で撮る前に決めていたもの（作品の位置・座標・大きさ）を、撮ったあとに写真から求めます。iPhone が撮るたび（方向ごとの代表の写真が変わるたび）と切り抜きができたときに求めて session.json に書くので、送られた session.json にはふつう入っています。無いとき（切り抜きを作っている間に送ったなど）は、Mac の `memoria-pack` が同じ計算（CaptureCore）で求めます（session.json は書き換えない）。

```jsonc
"derivation": {
  "method": "opticalAxesLeastSquares",  // 求め方：各写真の画面の中心を通る線に一番近い点
  "status": "ok",                       // "ok" | "lowConfidence"（写真 2 枚だけ・線の外れが大きい）| "unknown"（求められない）
  "reasons": [],                        // "noFront" | "tooFewPhotos" | "onlyTwoPhotos" | "nearParallelAxes" | "behindCamera" | "largeResidual" | "outlierExcluded"
  "photoIds": ["…"],                    // 使った写真（方向ごとの代表の写真。追跡が normal のもの）
  "excludedPhotoIds": [],               // 大きく外れていたので除いた写真（4 枚以上のとき 1 枚まで）
  "centerWorld": [0.056, -0.179, -0.260], // 作品の中心（世界座標）。分からなければ null
  "residualRmsM": 0.017,                // 線が中心から外れている距離の二乗平均・最大（m）。分からなければ null
  "residualMaxM": 0.022,
  "perPhoto": [{ "photoId": "…", "missM": 0.009, "distanceM": 0.353 }],
  "origin": "center",                   // objectToWorld の原点："base"（机の面。basePointWorld と同じ）| "center"（机の高さが分からない）。中心が分からなければ null
  "size": { … }                         // おおよその大きさ（下）。切り抜きをまだ作っているときは null
}
```

- 中心：方向ごとの代表の写真の画面の中心の線（光軸とほぼ同じ）に一番近い点（最小二乗）。写真が 2 枚未満・線がほぼ平行（2 本なら角度 約 32° 未満。正面と後ろだけなど）・点がカメラの後ろなら `unknown` で、中心も座標も null（推測しない）。4 枚以上で、1 枚を除いて求めた中心からその写真の線が max(3 cm, 残りの残差の 3 倍) より外れていれば、その 1 枚を除きます。写真 3 枚以上で二乗平均が 2 cm 以下なら `ok`。
- 作品座標 `objectToWorld`：+Y 上、+Z は正面の写真の水平の向きの反対（作品から正面のカメラへ）、+X = Y × Z。原点の x・z は中心。y は、撮影中に ARKit で作品の下の面が測れたとき（中心の真下の ARKit の平面、無ければまわりの特徴点の面。中心の下 40 cm 以内）はその高さ（`origin: "base"`、`basePointWorld` と `base.source` も入る）、測れなければ **中心の高さ**（`origin: "center"`、`basePointWorld` は null。y = 0 は底ではない）。
- 写真ごとの `direction`：方位は作品座標でのカメラの位置から（決まりは前の方法と同じ）、仰角と距離は **中心から** 測ります（前の方法の「基準点から heightM / 2 上」の代わり）。

### おおよその大きさ（`derivation.size`）

撮るときには大きさを決めないので、撮ったあとに切り抜き（マスク）から求めます。使う切り抜きは、方向ごとの代表の写真のうち確認済み、または確かめた結果が `ok` のものです。切り抜きが足りない（正面か後ろ・右か左・ほかに 1 枚、の計 3 枚以上が要る）ときは `status: "unknown"` で数字は null です。

```jsonc
"size": {
  "status": "approximate",              // "approximate" | "unknown"
  "confidence": "low",                  // "normal" | "low"（reasons を見る）。unknown なら null
  "method": "maskBoundsBoxAndCenterPlane",
  "reasons": ["shapeDependent"],        // "noCenter" | "notEnoughMasks" | "maskTouchesImageEdge" | "poorFit" | "oppositeViewsDisagree" | "centerLowConfidence" | "shapeDependent" | "fitFailed"
  "widthM": 0.065, "depthM": 0.127, "heightM": 0.044,       // 幅（X）・奥行き（Z）・高さ（Y）。下と上の目安の幾何平均
  "lowerM": { "widthM": 0.056, "depthM": 0.119, "heightM": 0.023 },  // 下の目安（箱の当てはめ）
  "upperM": { "widthM": 0.076, "depthM": 0.137, "heightM": 0.084 },  // 上の目安（中心の面での広がり）
  "boxMinM": [-0.032, 0.001, -0.063], "boxMaxM": [0.032, 0.045, 0.064],  // 大きさの箱（原点は centerWorld、作品座標の向き）
  "photoIds": ["…"],
  "fitResidualDeg": 0.63,               // 箱の輪郭と切り抜きの外接長方形のずれ（度）
  "crossChecks": [{ "dimension": "width", "values": { "front": 0.081, "back": 0.071 }, "disagreement": 0.138 }]
}
```

- 下の目安（箱の当てはめ）：作品座標の軸にそろった箱を、どの写真に投影してもその外接長方形が切り抜きの外接長方形に合うように決めます（最小二乗。透視をそのまま扱う）。角ばった物ではほぼ正しく、丸い物では小さく出ます。
- 上の目安（中心の面での広がり）：切り抜きの外接長方形の 4 隅を通る線を、中心を通り写真の向きに垂直な面に当てた広がり（写真の中の長さを中心までの距離で実寸にしたもの）。幅は正面・後ろ、奥行きは右・左、高さは横の 4 枚の平均。丸い物では近く、角ばった物では大きく出ます。
- `widthM`・`depthM`・`heightM` は 2 つの幾何平均です。上が下の 1.6 倍を超える寸法があると `shapeDependent`（形しだいで変わる）で信頼度は低くなります。ほかに、箱のずれが 1.5° を超える（`poorFit`）、向かい合う写真の広がりが 25% を超えて違う（`oppositeViewsDisagree`）、切り抜きが写真の端に届く、中心の信頼度が低い、のどれかで信頼度は低くなります。
- 使う切り抜きの写真が変わったとき（撮り直した・選び直した）は求め直します。

### 切り抜き（マスク）

撮るときには作品の位置も大きさも分からないので、Vision には **写真の中央（十字）のまわりの正方形** を切り抜いて渡します（辺は短い辺の 0.7 倍。作品らしい物が見つからなければ 0.45 倍で試す）。`mask.inputRegionSource` は `"crosshair"` です（**後から足した値**）。自動で選ぶ物は、切り抜きの中央の正方形（辺の 0.3 倍）と重なる物です。撮ったあとに中心と大きさが分かっても、切り抜きは作り直しません（「切り抜きを作り直す」も十字のまわりのまま）。

マスクの確かめ（`mask.check`）は、作品の輪郭が無いので分かることだけで決めます：空（`empty`）、切り抜きの 0.3% 未満（`tooSmall`）、切り抜きの 60% より広い（`tooLarge`）、切り抜きの 2 辺以上に届く（`touchesCropEdge`）、中央の正方形に 1 つも無く重心が切り抜きの中心から辺の 0.35 倍より離れている（`offCenter`）。`insideSilhouetteRatio`・`silhouetteAreaRatio` は null です。撮り直しは `ai5` と同じく、はっきり失敗したとき（`empty`・`tooSmall`・`failed`・`noObject`）だけです。

## 平面の作品（`workKind: "flat"`）

新しいセッションを作るときに、ユーザーが作品の種類を選びます（アプリは自動で見分けません）。紙に毛糸を貼った絵のような中間の作品も、どちらにするかは撮る人が決めます。

- `workKind`：`"object"`（立体：工作・粘土など。今までの撮り方）か `"flat"`（平面：絵・貼り絵など）。**後から足した項目** で、キーが無い・null のセッションは `"object"` として読みます。無くても読めるので `schemaVersion` は 1 のままです。iPhone は書くときいつも書きます。
- 平面の作品のセッションは、撮影方向 `flat1`（真上 `top-e90` を 1 つ）で、**基準（`referenceFrames`）を作りません**（底の中心と円柱を合わせない）。`object` は null のままです。
- 写真の方向（`direction`）：作品の中心が分からないので、カメラの向きで測ります。
  - `elevationDeg`：カメラの光軸（−Z）が水平から下へ傾いた角度（90 が真下）。`flat1` の真上の許容（70° 以上）に入れば `targetId` は `top-e90`、外れれば null。
  - `azimuthDeg`：null（方位は無い）。`distanceM`：用紙の中心を通る線が、四隅を当てた平面（下の `size`）と交わるまでの距離。平面が無ければ null。
  - `confirmed`：傾きは重力から決まるので、追跡（`trackingState`）が `notAvailable` でなければ true（そのときは `unconfirmedReason` が `trackingNotNormal`、`targetId` は null）。`referenceFrameId` は null。
  - 画像の向き：`displayRotationDegClockwise` は端末の向きから決めます。真上から撮って端末が上向き・下向き（`faceUp`・`faceDown`）のときは、縦向きの画面のまま（90）。撮る人が画面で見ていた上が、補正した画像の上になります。
- **マスクは作りません**（`mask.status` は `notGenerated` のまま、マスクの確かめも無い）。作品の範囲は用紙の四隅で記録します。
- `photos[].flat`（**後から足した項目**。立体の作品の写真・この項目より前の写真は null）：アプリが測ったものだけを入れ、測れなかった値は推測せず null にします。

```jsonc
"flat": {
  "corners": {                             // 用紙の四隅（保存した写真＝センサーの向きのピクセル、原点は左上）。四角が見つからなければ null
    "topLeft": [1012.4, 455.0], "topRight": [1030.8, 2610.2],   // 左上・右上…は、写真を displayRotationDegClockwise だけ回して
    "bottomRight": [2890.1, 2598.7], "bottomLeft": [2870.0, 470.3]  // まっすぐ見たときの位置（補正した画像の左上・右上・右下・左下）
  },
  "cornersMethod": "VNDetectRectanglesRequest",   // 四隅の求め方。四隅が無ければ null
  "cornersConfidence": 0.97,               // Vision の確からしさ（0〜1）。四隅が無ければ null
  "sheetAtFrameEdge": false,               // どれかの角が写真の端から幅・高さの 2% 以内（用紙が切れているかもしれない）。四隅が無ければ null
  "size": {                                // 用紙の実寸。四隅を ARKit の平面に当てて測れたときだけ。測れなければ null
    "widthM": 0.297, "heightM": 0.21,      // 幅 = 上と下の辺の平均（補正した画像の横）、高さ = 左と右の辺の平均（縦）
    "planeSource": "estimatedPlane"        // "existingPlaneGeometry"（ARKit が見つけた平面の形）| "estimatedPlane"（ARKit が推定した平面）
  },
  "rectified": {                           // 遠近を直してまっすぐにした画像。作れたときだけ。無ければ null
    "file": "rectified/<photoId>.jpg", "width": 2970, "height": 2100
  }
}
```

- 四隅：撮った高解像度の写真そのもので、Vision（`VNDetectRectanglesRequest`）が見つけた四角です（撮影画面に出す輪郭は別のフレームなので使わない）。見つからなければ写真をそのまま全体で保存し（`corners` は null）、確認画面の「気になる写真」に出します（送るのは止めない）。
- 実寸：用紙の中心を通る線で ARKit の平面（見つかった平面の形、無ければ推定した平面。水平でカメラより下のもの）を探し、四隅を通る線とその平面の交点の間の長さを測ります。平面が無い・どれかの角が当たらないときは null。紙からはみ出して貼った物と厚みは測りません。撮る人が紙の大きさを選んだとき（`declaredSize.sheet`）は、測った実寸は補助です（上の「撮る人が選んだ・入力した大きさ」）。
- 補正した画像：Core Image の `CIPerspectiveCorrection` で四隅の中を長方形にします。大きさは、四隅の長い方の辺のピクセル数を長い辺とし、縦横比は選んだ紙（`declaredSize.sheet`。向きは四隅の辺の長さで決める）、無ければ実寸、それも無ければ辺の長さに合わせます。すでにまっすぐなので、回さずに見ます。元写真（`photos/`）は今までどおり保存・転送し、補正した画像は派生のものです。
- 撮影の進み具合：`flat1` は基準を見ず、方向が確定して `targetId` のある写真を数えます。マスクは見ないので、真上の写真が 1 枚あれば「そろった」（1/1）。撮り直すと一番新しい写真が代表になり、前の写真は「置き換え済み」です。確認画面の「気になる写真」は、用紙が見つからない（`sheetNotFound`）・用紙が端にかかっている（`sheetAtFrameEdge`）・真上から撮れていない（`notOverhead`）・置き換え済み、です。

## 撮る人が選んだ・入力した大きさ（`declaredSize`）

机の面（ARKit の平面）は見つからないことが多く、それに頼ると大きさが決まらないことがあります。そこで大きさは、**撮る人が新しいセッションを作るときに選ぶ・入力する** 値を第一にします。AR に頼るのは iPhone の向きだけで、机が見つからなくても、選んだ・入力した大きさは変わりません。

- `declaredSize`（**後から足した項目**）：セッションの最上位。キーが無い・null は「入力していない」です。無くても読めるので `schemaVersion` は 1 のままです。iPhone は書くときいつも書き、どちらも入力していなければ null にします。

```jsonc
"declaredSize": {
  "sheet": {                    // 平面の作品：一覧から選んだ紙。「わからない」を選んだとき・立体の作品は null
    "id": "yatsugiri",          // 一覧の id（下の表）
    "longSideM": 0.392,         // 長い辺
    "shortSideM": 0.271         // 短い辺
  },
  "heightM": null               // 立体の作品：入力した高さ（m）。入力していないとき・平面の作品は null
}
```

- 紙の一覧（CaptureCore の `SheetPreset` の 1 か所にある。表示名は日本語）：

| id | 表示名 | 短い辺 × 長い辺（mm） |
|---|---|---|
| `yatsugiri` | 八つ切 | 271 × 392 |
| `yotsugiri` | 四つ切 | 392 × 542 |
| `a4` | A4 | 210 × 297 |
| `b4` | B4 | 257 × 364 |
| `a3` | A3 | 297 × 420 |
| `b5` | B5 | 182 × 257 |
| `custom` | その他 | 撮る人が入力した縦と横 |

- 「その他」（`id` が `custom`。**後から足した値**）：一覧に無い紙は、縦と横を cm で入力します。どちらも 1 cm 以上 300 cm 以下のときだけ採用し、`longSideM` は大きい方、`shortSideM` は小さい方です。外れた値・空なら紙は選んでいない扱い（`sheet` は null）です。表示名は「その他」で、寸法が要る所では「その他（21.0 × 30.0 cm）」のように出します。`SheetPreset`（決まった紙の一覧）には入れません。
- 紙の縦・横の向きは書きません。使う側で決めます：検出した四隅（補正した画像）の横が縦以上なら横 = 長い辺、そうでなければ横 = 短い辺。四隅が無ければ向きは決めません（長い辺・短い辺だけが分かる）。
- 高さは cm で入力し、0.5 cm 以上 300 cm 以下だけを採用します（外れた値・空は null。全角の数字と小数点の「,」も読む）。値は 0.1 mm に丸めます。
- 平面の作品は `sheet` だけ、立体の作品は `heightM` だけを書きます（もう一方は null）。自由に撮るセッションも立体なので `heightM` を使います。
- `photos[].flat.size`（ARKit の平面で測った実寸）の意味は変えません。測る処理も残します。**選んだ大きさは `declaredSize`、測った大きさは今までの場所** です。

### どちらを使うか（優先順）

- 平面の紙の大きさ：`declaredSize.sheet` があればそれ、無ければ `photos[].flat.size`（測れたとき）、どちらも無ければ「分かりません」。
- 補正した画像（`rectified`）の縦横比：選んだ紙があればその比（向きは上の決め方）、無ければ今までどおり（測った実寸、無ければ四隅の辺の長さ）。
- 立体の高さ：`declaredSize.heightM` があれば、写真から求めたおおよその大きさ（`referenceFrames[].heading.derivation.size`）や visual hull・円柱の大きさより **この値を優先するよう AI に伝えます**（`for_claude/` の `brief.md` と `measurements.json` の `declaredHeight`）。求めた大きさ自体は今までどおり書き、書き換えたり縮尺を掛けたりはしません。

## 自由に撮る撮影（`guidance: "free"`）

立体の作品を、**案内も自動撮影もなく、シャッターを押すだけで何枚でも撮る** 撮り方です（新しい立体のセッションの既定。ユーザーが決めたもの）。平面の作品（`flat1`）と同じ系統で、基準を作らず、マスクを作らず、向きはカメラの傾きだけを記録します。撮影画面には「作品の全体を画面に入れて撮ってください。正面・横・後ろ・真上があると、形を作りやすくなります」という目安だけを出します。

- `guidance`：`"free"`（**後から足した値**）。今ある値（`heading`・`baseCylinder`）の意味は変えません。
- `directionPlan`：いつも `{"id": "free", "targets": []}`（方向は 0 個）。方向が 0 個の一覧は `free` だけで、受信サーバーも `guidance` が `free` のときだけ認めます。
- `referenceFrames` は `[]`（基準を作らない）、`object` は null。
- 写真の `direction`：平面の作品と同じ測り方です。`elevationDeg` はカメラの光軸が水平から下へ傾いた角度（90 が真下）、`azimuthDeg`・`distanceM`・`targetId` は null、`referenceFrameId` は null。`confirmed` は追跡（`trackingState`）が `notAvailable` でなければ true（そのときは `unconfirmedReason` が `trackingNotNormal`）。
- `mask.status` はいつも `notGenerated`（マスクを作らない）。`flat`・`heading` は null。
- 撮影の進み具合：写真が 1 枚以上あれば「そろった」。枚数に上限はなく、撮り直しも求めません。気になる写真は、方向（傾き）が参考値の写真だけです。
- どの写真がどの向きかは記録しません。`for_claude/` の `brief.md` は、写真を見て判断するよう AI に伝えます。大きさは写真から求めず、`declaredSize.heightM` があればそれを使います。

## マスクの作り方（`mask`）

- Vision（`VNGenerateForegroundInstanceMaskRequest`）には、写真の全体ではなく **作品のまわりを切り抜いた画像** を渡します。写真の全体を渡すと、作品が小さいときに机やマットのような大きな面を選ぶ（または何も見つからない）ためです。
  - 切り抜く範囲：その写真の `referenceFrameId` の基準の `basePointWorld` と、その基準の `object`（無ければ上の `object`。`radiusM`・`heightM`）の円柱を、その写真の `cameraToWorld`・`intrinsics` で投影した外接長方形を、中心のまわりに 1.2 倍に広げ、幅・高さを 512 ピクセル以上にし、写真からはみ出すときは大きさを保ったまま内側へずらしてから写真の中に切り詰めます。session.json の値だけで決まるので、撮ったあとの写真でも作り直せます。
  - 自動で選ぶ物は、切り抜きの中で投影した円柱と重なる物です。選んだ物が切り抜きの 85% より広い（机やマットらしい）ときは、ほかの物のうち円柱の輪郭と一番よく重なる物に替えます。
  - 作品らしい物が見つからない（何も無い・広すぎる物だけ）ときは、1.0 倍の切り抜きでもう一度試します。`inputRegion` は実際にマスクを作った方の範囲です。
  - 基準が無い・作品の大きさが無い・作品がカメラの後ろ・写真の外のときは、写真の全体を渡します（`inputRegion` は null、`inputRegionSource` は `"fullImage"`）。
- マスクの PNG は、いつも **元写真と同じ幅・高さ・向き** です（切り抜きで作ったマスクを写真の大きさの画像の `inputRegion` の位置に貼り、切り抜きの外は 0）。
- `selectedInstances`・`instanceCount` の番号は、`inputRegion` の切り抜きに対して Vision が付けた番号です。
- `inputRegion`・`inputRegionSource` は後から足した項目です。無くても読めるので（無ければ null と同じ）、`schemaVersion` は 1 のままです。
- 状態の移り方：`notGenerated` →（作り始める）`processing` → `candidate`（物を選べた）| `noObject`（物が無い・選べない）| `failed`（`error` に理由。写真は残す）。`candidate` はユーザーが確認すると `confirmed`、選び直しても `candidate`（`selection` が `"user"`）。
- `check` は後から足した項目です。無くても読めるので（無ければ null と同じ）、`schemaVersion` は 1 のままです。
- 切り抜きの作り直し（iPhone の確認画面の「切り抜きを作り直す」）：元写真は変えず、1 枚ずつ順番に `processing` から同じように作り直します（一覧からはまとめて、`confirmed` の写真は除く。写真 1 枚の画面からは、その写真を `confirmed` でも作り直す）。

## マスクの確かめ（`mask.check`）

Vision が作品ではなく、撮る人の体・後ろのスピーカー・机のような物を選ぶことがあるので、マスクを作ったら（自動でも選び直しでも）すぐに、投影した作品の円柱の輪郭と比べます。結果が `suspicious` の写真は、撮影中に同じ方向を撮り直します。ただし撮り直しの決まりは一覧ごとで（iPhone 側の `DirectionPlan.retakePolicy`）、`ai5` は **はっきり失敗したときだけ** 撮り直します：`noObject`・`failed`、または `suspicious` で理由に `empty`・`tooSmall` がある（作品が写っていない）か `insideSilhouetteRatio` が 0.5 未満（マスクの大半が作品の外）。`touchesCropEdge`・`offCenter`・`tooLarge` だけの `suspicious` や `unknown` では撮り直しません（記録はそのまま残り、確認画面の「気になる写真」には出ます）。ほかの一覧は `ok` 以外（`suspicious`・`unknown`）を撮り直します。

- 比べる輪郭：`inputRegionSource` が `"projectedCylinder"` のマスクだけ。切り抜きを作ったときと同じ円柱（その写真の基準の `basePointWorld` と `object`）を投影した凸包を、外接長方形の中心のまわりに 1.05 倍に広げたもの。
- 写真の全体から作ったマスク（基準が無い・投影できない）、`inputRegionSource` の無い前の版のマスクは `"unknown"`（`reasons` は `["noProjection"]`、割合は null）。
- 切り抜きを長い辺 512 の格子に間引いて数えます（写真の大きさのマスクからでも、切り抜きの大きさのマスクからでも同じ値になる）。
- 次のどれかに当てはまると `"suspicious"`、どれにも当てはまらなければ `"ok"`。しきい値は iPhone 側の `MaskCheckThresholds` の 1 か所にまとめています（実機の写真で決めた値。変えることがあります）。

| `reasons` | 条件 |
|---|---|
| `outsideObject` | `insideSilhouetteRatio` < 0.93 |
| `touchesCropEdge` | `touchedCropEdges` ≥ 2（切り抜きの辺から短い辺の 1% の帯に、その辺の 5% を超えるマスクがある辺の数） |
| `tooLarge` | `silhouetteAreaRatio` > 1.6、または `cropCoverage` > 0.6 |
| `tooSmall` | `silhouetteAreaRatio` < 0.03 |
| `offCenter` | `centerOffset` > 0.35 |
| `empty` | マスクが空 |
| `noProjection` | （`unknown` のとき）作品を投影できない |

- `status` が `failed`・`noObject`・`notGenerated`・`processing` のときは `check` は null です。ユーザーが確認した（`confirmed`）マスクは、`check` が `suspicious` でも使えるマスクとして扱います。
- `check` の無い前の版のマスクは、iPhone のアプリを起動したときに確かめて書き足します（マスクは作り直さない）。

## 撮影の進み具合（session.json には書かない）

iPhone は次の決まりで、方向がそろったかを session.json から計算します（項目は足さない）。PC 側で同じ判定をしたいときも、この決まりで計算できます。

- 数えるのは、その基準（`referenceFrameId`）で撮った、`direction.confirmed` が true で `targetId` のある写真だけ。撮影画面では今の基準、確認画面・送信画面では最後に設定した基準で数えます（平面の作品 `flat1` は基準を見ず、マスクも見ない。上の「平面の作品」。自由に撮るセッション `free` は写真が 1 枚以上あればそろった。上の「自由に撮る撮影」）。
- 写真のマスクが「使える」：`mask.status` が `confirmed`、または `candidate` で `check.status` が `ok`。「まだ分からない」：`notGenerated`・`processing`、または `candidate` で `check` が null。それ以外（`suspicious`・`unknown`・`failed`・`noObject`）は「使えない」。
- 方向ごとの代表の写真：使える写真のうち一番新しいもの。無ければ一番新しい写真。代表の写真で、方向は「そろった」（使える）・「確認中」（まだ分からない）・「撮り直し」（使えない）のどれかになります。
- 代表ではない写真は「置き換え済み」です（写真は消さない）。ただし代表より新しくて「まだ分からない」写真は、置き換え済みにしません。確認画面の「置き換え済みを削除」で消せます。
- 撮影中は「確認中」の方向も撮ったとみなし（自動撮影ですぐに撮り直さない）、「撮り直し」の方向は撮っていないとみなして、自動撮影がもう一度撮ります。
- すべての方向が「そろった」とき、送る準備ができたとみなします。そろっていなくても送れます。
