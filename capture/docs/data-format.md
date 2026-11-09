# 撮影データの形式（session.json schemaVersion 1）

iPhone 側と PC 側で同じ形です。1 つの撮影セッションが 1 つのフォルダになります。

```
<sessionId>/
  session.json            メタデータ（このファイルの形）
  photos/<photoId>.jpg    元写真（センサーの向きのまま。回転・縮小・切り抜きなし）
  masks/<photoId>.png     作品マスク（元写真と同じ幅・高さ・向き。8bit グレー、255 = 作品、0 = 背景）
```

- `sessionId`・`photoId` は UUID（大文字、ハイフン付き）。ファイル名に使える文字はこれだけです。
- 元写真は上書きしません。マスクは別ファイルで、マスクが無い（失敗・未生成）写真もあります。
- iPhone 側の転送状態（`transfer.json`）はセッションのフォルダにありますが、転送するファイルには入れません。

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
| 作品座標（objectToWorld） | 原点は作品の底面中央（基準マーカー）。+Y は上、+Z は基準点から正面のカメラへ向かう水平方向、+X = Y × Z（正面から見て右） |
| 方位角 `azimuthDeg` | 作品座標でのカメラ位置 (x, z) について `atan2(x, z)` を度にして 0〜360。0 = 正面、90 = +X 側（正面から見て右へ回り込んだ位置） |
| 仰角 `elevationDeg` | 作品の中心（基準点から `heightM / 2` 上）からカメラへのベクトルの水平面からの角度。上から見下ろすと正 |

## session.json

```jsonc
{
  "schema": "memoria.capture.session",
  "schemaVersion": 1,
  "sessionId": "8B0F…",
  "title": "ねこの貯金箱",                 // 作品名（空文字可）
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
      }
    }
  ],
  "directionPlan": {                       // 撮る方向の一覧（下の「撮影方向（directionPlan）」）。セッションを作ったときに決まり、あとで変わらない
    "id": "photogrammetry",                // "photogrammetry" | "ring8" | "ring4" | "ring8plusHigh"
    "targets": [
      { "id": "a000-e20", "azimuthDeg": 0, "elevationDeg": 20,
        "azimuthToleranceDeg": 7, "elevationToleranceDeg": 10 },
      { "id": "a022.5-e45", "azimuthDeg": 22.5, "elevationDeg": 45,
        "azimuthToleranceDeg": 10, "elevationToleranceDeg": 10 }
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
      }
    }
  ]
}
```

- 取れない値は推測で埋めず `null` にします。
- 撮影に失敗した写真・保存に失敗した写真は `photos` に入りません。
- `direction.confirmed` が true になるのは、写真の `trackingState` が `normal` で、無効になっていない基準（`objectToWorld` あり）があるときだけです。
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
| `photogrammetry`（新しいセッションの既定） | 仰角 20° で 15° ごとに 24、45° で 22.5° ごとに 16、70° で 45° ごとに 8（計 48） | 20° の段 ±7°、45° の段 ±10°、70° の段 ±20° | ±10° | Mac の RealityKit `PhotogrammetrySession` で 3D にする。隣の写真が大きく重なり、3 つの高さから撮る |
| `ring8` | 仰角 20° で 45° ごとに 8 | ±20° | ±15° | 前の既定 |
| `ring4` | 仰角 20° で 90° ごとに 4 | ±20° | ±15° | |
| `ring8plusHigh` | `ring8` ＋ 仰角 50° で 90° ごとに 4（計 12） | ±20° | ±15° | |

- `targets` の順は、低い段から段ごと、段の中は方位 0° から増える順です。
- どの一覧でも、隣の方向・隣の段の許容は重なりません（`photogrammetry` は 15° 間隔に ±7°、22.5° 間隔に ±10°、段の間 30〜35°・55〜60° はどの方向にも入らない）。重なる一覧を読むときは、許容で割った近さ（方位の差 ÷ 方位の許容 ＋ 仰角の差 ÷ 仰角の許容）が一番小さい方向、同じなら一覧の順で先の方向に当てはめます。
- **方向の `id`**：`a<方位>-e<仰角>`。方位は 0 以上 360 未満を整数 3 桁（`a045`）、端数があるときは小数 1 桁を付けます（`a022.5`、`a337.5`。四捨五入して丸めない）。仰角は整数 2 桁、負なら `m` を付けます（`e20`、`em05`）。正規表現では `^a[0-9]{3}(\.[0-9])?-em?[0-9]{2}$`。同じ一覧の中で重複せず、同じ方位・仰角からはいつも同じ `id` になります。`id` はファイル名には使いません（写真のファイル名は `photoId`）。
- 撮影画面の案内（session.json には書かない）：段を低い順（20° → 45° → 70°）に 1 段ずつ、段の中は歩いている向きのまま 1 周します（近い方向へ行ったり来たりしない）。撮りそこねた・撮り直しになった方向は、すぐ後ろでなければ 1 周の終わりに撮ります。上の段の途中で下の段の撮り直しが出たときは、上の段を終えてから下の段へ戻ります。
- 自動撮影の待ち時間（撮影のあと次の自動撮影まで）は、1 周に 13 方向以上の段がある一覧（`photogrammetry`）で 0.7 秒、ほかは 1.2 秒です。どちらも同じだけ止まってから撮り、撮影は 1 枚ずつです。

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

Vision が作品ではなく、撮る人の体・後ろのスピーカー・机のような物を選ぶことがあるので、マスクを作ったら（自動でも選び直しでも）すぐに、投影した作品の円柱の輪郭と比べます。結果が `suspicious` の写真は、撮影中に同じ方向を撮り直します。

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

- 数えるのは、その基準（`referenceFrameId`）で撮った、`direction.confirmed` が true で `targetId` のある写真だけ。撮影画面では今の基準、確認画面・送信画面では最後に設定した基準で数えます。
- 写真のマスクが「使える」：`mask.status` が `confirmed`、または `candidate` で `check.status` が `ok`。「まだ分からない」：`notGenerated`・`processing`、または `candidate` で `check` が null。それ以外（`suspicious`・`unknown`・`failed`・`noObject`）は「使えない」。
- 方向ごとの代表の写真：使える写真のうち一番新しいもの。無ければ一番新しい写真。代表の写真で、方向は「そろった」（使える）・「確認中」（まだ分からない）・「撮り直し」（使えない）のどれかになります。
- 代表ではない写真は「置き換え済み」です（写真は消さない）。ただし代表より新しくて「まだ分からない」写真は、置き換え済みにしません。確認画面の「置き換え済みを削除」で消せます。
- 撮影中は「確認中」の方向も撮ったとみなし（自動撮影ですぐに撮り直さない）、「撮り直し」の方向は撮っていないとみなして、自動撮影がもう一度撮ります。
- すべての方向が「そろった」とき、送る準備ができたとみなします。そろっていなくても送れます。
