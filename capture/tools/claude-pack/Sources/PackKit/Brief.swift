import Foundation
import CaptureCore

/// `brief.md`: a short Japanese description of the package for an AI modeller (and the person who runs it).
/// Only facts from session.json and the measurements; nothing is guessed.
public enum Brief {
    static let viewNameJa: [String: String] = [
        "front": "正面", "front_right": "右前", "right": "右", "back_right": "右後ろ",
        "back": "後ろ", "back_left": "左後ろ", "left": "左", "front_left": "左前",
        "top": "上", "front_high": "正面・高め",
    ]

    static func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    static func f0(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }

    static let baseSourceJa: [String: String] = [
        "existingPlaneInfinite": "ARKit の平面（延長）",
        "existingPlaneGeometry": "ARKit の平面の形",
        "estimatedPlane": "ARKit の推定平面",
        "featurePoints": "特徴点から推定した机の高さ（数 mm〜1 cm ずれることがある）",
        "deviceEdge": "iPhone の下端を机に当てて測った高さ（機種ごとの寸法はおおよそ）",
    ]

    /// Remarks about a chosen photo, in Japanese (pack.json keeps the English `notes`).
    static func notesJa(_ c: ViewChoice, session: CaptureSession) -> [String] {
        var notes: [String] = []
        switch c.maskUse {
        case .unchecked?: notes.append("切り抜きは確かめていない（古いセッション）")
        case .unusable?: notes.append(session.usesHeadingGuidance ? "使える切り抜きなし" : "使える切り抜きなし（切り抜く範囲は作品の円柱の投影から）")
        default: break
        }
        if let id = c.photoId, let p = session.photo(id: id) {
            if let saved = p.quality.saved {
                if saved.blur != .ok { notes.append("ぶれ \(saved.blur.rawValue)") }
                if saved.brightness != .ok { notes.append("明るさ \(saved.brightness.rawValue)") }
            } else {
                notes.append("画質は未解析")
            }
        }
        if let want = c.requestedAzimuthDeg, let az = c.azimuthDeg {
            let d = Geometry.angleDistance(want, az)
            if d > ViewSelector.weakAngleDeg { notes.append("方位が \(f0(d))° ずれ") }
        }
        if let el = c.elevationDeg {
            if c.name == "top" {
                if el < (session.directionPlan.usesStepNames ? 75 : 55) { notes.append("一番高い写真でも仰角 \(f0(el))°（真上ではない）") }
            } else if abs(el - c.requestedElevationDeg) > ViewSelector.weakAngleDeg {
                notes.append("仰角が \(f0(abs(el - c.requestedElevationDeg)))° ずれ")
            }
        }
        if c.cropSource == "projectedCylinder" { notes.append("切り抜き範囲は円柱の投影から") }
        if c.cropSource == "projectedDerivedBox" { notes.append("切り抜き範囲は撮ったあとに求めた大きさの箱の投影から") }
        if c.cropSource == "crosshairCenter" { notes.append("切り抜き範囲は写真の中央（十字のまわり）") }
        if let id = c.photoId, let p = session.photo(id: id), let h = p.heading, p.direction.targetId == nil {
            notes.append(h.position == .notWalkedAround ? "その場で回して撮った写真かもしれない" : "狙った向きの外で撮った写真")
        }
        return notes
    }

    /// The measured-size part (visual hull), or why there is none.
    static func sizeSection(_ m: Measurements, into out: inout [String]) {
        if let s = m.sizeCm {

            out.append("| 幅（X、左右） | 奥行き（Z、前後） | 高さ（Y、上下） | 誤差の目安 |")
            out.append("|---|---|---|---|")
            out.append("| \(f1(s.width)) cm | \(f1(s.depth)) cm | \(f1(s.height)) cm | ±\(f1(m.uncertainty?.plusMinusCm)) cm |")
            out.append("")
            if let f = m.footprint {
                out.append("- 上から見て一番小さく囲む長方形：\(f1(f.lengthCm)) × \(f1(f.widthCm)) cm（長い辺の向きは方位 \(f0(f.longAxisAzimuthDeg))°。0° = 前後、90° = 左右）。"
                           + "作品が正面に対して斜めに置かれていると、上の幅・奥行き（軸に沿った箱）はこれより大きくなります。")
            }
            out.append("- 求め方：基準 `\(m.referenceFrameId ?? "?")` の写真 \(m.viewsUsed) 枚の切り抜き（マスク）とカメラの位置・内部パラメータ（ARKit）から、"
                       + "ボクセル \(f1((m.grid?.voxelSizeM ?? 0) * 1000)) mm の visual hull（どの写真でも輪郭の内側に入る空間）を作り、その外接箱を測りました。")
            out.append("- 誤差の目安 ±\(f1(m.uncertainty?.plusMinusCm)) cm = ボクセル \(f1(m.uncertainty?.voxelCm)) cm ＋ 写真ごとの輪郭とのずれの中央値 \(f1(m.uncertainty?.reprojectionSlackCm)) cm。")
            if let bias = m.uncertainty?.heightOverestimateUpToCm, let h = m.sizeCm?.height {
                out.append("- 高さは大きめに出ます：写真はどれも上から見下ろしているので、上面が平らだと最大 \(f1(bias)) cm 高く出ます（丸い上面ほど小さい）。実際の高さはおよそ \(f1(max(0, h - bias)))〜\(f1(h)) cm。")
            }
            if m.confidence == "low" {
                var reasons: [String] = []
                if m.viewsUsed < 12 { reasons.append("輪郭に使えた写真が \(m.viewsUsed) 枚だけ（12 枚以上がよい）") }
                if let sl = m.uncertainty?.reprojectionSlackCm, sl > 0.5 { reasons.append("写真どうしの輪郭のずれが \(f1(sl)) cm（カメラ位置のずれか、切り抜きの誤り）") }
                if m.uncheckedMaskViews > 0 { reasons.append("確かめていない切り抜きが \(m.uncheckedMaskViews) 枚") }
                out.append("- **信頼度は低め**：\(reasons.joined(separator: "、"))。輪郭が写真どうしで合わないと実物の一部まで削られるので、上の ± を超えて小さく出ることがあります。写真と見比べてください。")
            }
            out.append("- visual hull は凹んだ所・穴・底の下を埋めるので、実物より大きめに出ます（小さくは出にくい）。")
            if let t = m.tablePlaneAboveReferenceM {
                out.append("- 高さは、hull の底の形から推定した机の面からの高さです。撮影時の基準点（底の中心）は、その机の面より \(f1(abs(t) * 100)) cm \(t >= 0 ? "下" : "上")にありました"
                           + "（基準点の求め方：\(m.baseSource.flatMap { baseSourceJa[$0] } ?? "記録なし")）。この分は直してあります。")
            } else {
                out.append("- 高さは撮影時の基準点（机の面）からの高さです（机の面を推定できませんでした。基準点の求め方：\(m.baseSource.flatMap { baseSourceJa[$0] } ?? "記録なし")）。")
            }
            if let lo = m.bboxMinM, let hi = m.bboxMaxM {
                out.append(String(format: "- 外接箱の位置（m）：x %.3f〜%.3f、y %.3f〜%.3f、z %.3f〜%.3f。原点（基準点）は作品の中心からずれていることがあります。", lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]))
            }
            if let c = m.userCylinder {
                out.append("- 参考：撮影時にユーザーが AR のガイドで合わせた円柱は 半径 \(f1(c.radiusM * 100)) cm・高さ \(f1(c.heightM * 100)) cm（作品より大きめに囲む目安で、作品の大きさではありません）。")
            }
            if !m.touchesSearchBox.isEmpty {
                out.append("- 注意：形が探索範囲の端（\(m.touchesSearchBox.joined(separator: "、"))）に届いています。その向きは実物がもっと大きい可能性があります。")
            }
            out.append("- 粗い形：`hull.obj`（同じ座標・メートル。ボクセルの外側の面だけのカクカクした形）。大きさと位置合わせの下敷きに使えますが、細部はありません。")
        } else {
            out.append("実寸は求められませんでした：\(m.unavailableReason ?? "理由不明")。大きさは写真から推測するしかありません（推測したことを結果に書いてください）。")
        }
    }

    static let headingSizeReasonJa: [HeadingSizeReason: String] = [
        .noCenter: "作品の中心が分からない",
        .notEnoughMasks: "使える切り抜きが足りない",
        .maskTouchesImageEdge: "切り抜きが写真の端に届いている（作品がはみ出しているかもしれない）",
        .poorFit: "箱が切り抜きにうまく合わない（切り抜きの誤り・十字に合わせていない写真・位置のずれ）",
        .oppositeViewsDisagree: "向かい合う写真で測った長さが大きく違う",
        .centerLowConfidence: "作品の中心の求め方の信頼度が低い",
        .shapeDependent: "下の目安と上の目安が大きく違う（作品の形しだいで変わる寸法がある）",
        .fitFailed: "箱を求められない",
    ]

    static let derivationReasonJa: [String: String] = [
        "noFront": "正面の写真が無い", "tooFewPhotos": "写真が足りない", "onlyTwoPhotos": "写真が 2 枚だけ",
        "nearParallelAxes": "写真の中心の線がほぼ平行", "behindCamera": "交わる点がカメラの後ろ",
        "largeResidual": "線が大きく外れている", "outlierExcluded": "大きく外れた 1 枚を除いた",
    ]

    /// 向きで案内したセッション：大きさ（おおよそ）と、撮ったあとに求めた位置・大きさの説明。
    static func headingSections(_ m: Measurements, session: CaptureSession, into out: inout [String]) {
        let h = m.heading
        if let s = m.sizeCm {
            out.append("## 大きさ（おおよそ。撮ったあとに写真から求めた値）")
            out.append("")
            out.append("| 幅（X、左右） | 奥行き（Z、前後） | 高さ（Y、上下） | 信頼度 |")
            out.append("|---|---|---|---|")
            out.append("| \(f1(s.width)) cm | \(f1(s.depth)) cm | \(f1(s.height)) cm | \(m.confidence == "normal" ? "ふつう" : "低い") |")
            out.append("")
            if let size = h?.size, let lo = size.lowerM, let hi = size.upperM {
                out.append("- 下の目安（箱の当てはめ。角ばった物ではほぼ正しく、丸い物では小さく出る）：\(f1(lo.widthM * 100)) × \(f1(lo.depthM * 100)) × \(f1(lo.heightM * 100)) cm")
                out.append("- 上の目安（中心の面での広がり。丸い物では近く、角ばった物では大きく出る）：\(f1(hi.widthM * 100)) × \(f1(hi.depthM * 100)) × \(f1(hi.heightM * 100)) cm")
                out.append("- 表の値は 2 つの幾何平均です。どちらも、iPhone の切り抜き（マスク）の外接長方形と、写真ごとのカメラの位置（ARKit）から求めました。撮るときには大きさを合わせていません。")
                if !size.reasons.isEmpty {
                    out.append("- **信頼度が低い理由**：\(size.reasons.map { headingSizeReasonJa[$0] ?? $0.rawValue }.joined(separator: "、"))。写真と見比べてください（特に高さ）。")
                }
            }
        } else {
            out.append("## 大きさ（分かりません）")
            out.append("")
            out.append("大きさは求められませんでした：\(m.unavailableReason ?? "理由不明")。写真から推測するしかありません（推測したことを結果に書いてください）。")
        }
        out.append("")
        out.append("## 撮り方（向きで案内）と、撮ったあとに求めたもの")
        out.append("")
        out.append("このセッションは、作品を画面の中央の十字に合わせて正面を撮り、iPhone の向きが 90°・180°・270° 回った位置（右・後ろ・左）と真上から撮る方法（`guidance: heading`）で撮りました。"
                   + "撮るときに底の中心・作品の大きさは決めていません。**作品の位置と大きさは、撮ったあとに写真から求めた値です。**")
        out.append("")
        guard let h else { return }
        if let c = h.centerWorld, c.count == 3 {
            let reasons = h.reasons.map { derivationReasonJa[$0] ?? $0 }
            out.append("- 作品の中心：写真 \(h.photoIds.count) 枚の画面の中心を通る線に一番近い点。線がその点から外れている距離は二乗平均 \(f1((h.residualRmsM ?? 0) * 100)) cm・最大 \(f1((h.residualMaxM ?? 0) * 100)) cm"
                       + "（十字に作品を合わせられていない写真や、位置のずれがあると大きくなる。2 cm 以下ならおおむね合っている）。"
                       + (h.derivationStatus == "ok" ? "" : "**当てにしにくい**（\(reasons.joined(separator: "、"))）。"))
            if !h.excludedPhotoIds.isEmpty { out.append("- 大きく外れていたので中心の計算から除いた写真：\(h.excludedPhotoIds.map { "`\($0)`" }.joined(separator: "、"))") }
        } else {
            out.append("- 作品の中心は求められませんでした（\(h.reasons.map { derivationReasonJa[$0] ?? $0 }.joined(separator: "、"))）。")
        }
        out.append(h.origin == "base"
                   ? "- 机の面：作品の下の面を ARKit で測りました（求め方：\(m.baseSource.flatMap { baseSourceJa[$0] } ?? "記録なし")）。y = 0 がその面です。"
                   : "- 机の面：**高さは分かりません**（撮影中に ARKit の平面・特徴点で作品の下の面を測れなかった）。y = 0 は求めた中心の高さです。")
        out.append("- 写真ごとの方位・仰角・距離は、求めた中心から測った値です（撮るときに狙ったのは、正面からの iPhone の向きの差と見下ろす角度）。")
        out.append("- 計算した場所：\(h.computedBy == "iPhone" ? "iPhone（送る前）" : "Mac の memoria-pack（session.json にまだ無かったため）")")
    }

    public static func markdown(session: CaptureSession, provenance: PackIndex.Provenance, choices: [ViewChoice],
                                measurements m: Measurements, coverage: PackIndex.Coverage, maskIssues: [PackIndex.MaskIssue],
                                cutouts: Bool = false) -> String {
        var out: [String] = []
        let named = session.directionPlan.usesStepNames
        func ja(_ name: String) -> String { named && name == "top" ? "真上" : viewNameJa[name] ?? name }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append("# 3D モデルを作るための入力（\(title.isEmpty ? "作品名なし" : title)）")
        out.append("")
        out.append("子どもが作った作品を iPhone で撮った写真から、AI（Claude Code など）が 3D モデルを作るときの入力です。"
                   + "受信した撮影セッション（`sessions/\(session.sessionId)/`）から `memoria-pack` が自動で作りました。元のセッションは変えていません。")
        out.append("")
        out.append("- 作品名（撮影アプリで入力した名前）：\(title.isEmpty ? "（空。何の作品かは書かれていません）" : "「\(title)」")")
        out.append("- まず `overview.jpg` を見てください（選んだ写真の一覧。カメラが立っていた位置に並べてあり、上から見た配置で正面が下、中央が上から見た写真）。")
        out.append("")

        // Height typed in by the person (preferred over the sizes below; those are not rescaled).
        if let d = m.declaredHeight {
            out.append("## 高さ（撮る人が入力した値）")
            out.append("")
            out.append("- **高さは \(f1(d.heightCm)) cm です。** 撮る人が撮影アプリで入力した値で、AR や写真で測った値ではありません（`measurements.json` の `declaredHeight`）。")
            out.append("- 下の写真から求めた大きさより、**この高さを優先してください**。幅・奥行きは、この高さとの比が写真と合うように決めてください（下の値は求めたままで、この高さに合わせて書き換えたり縮尺を掛けたりはしていません）。")
            out.append("")
        }

        // Size
        if m.method == "headingDerived" {
            headingSections(m, session: session, into: &out)
        } else if m.method == "userCylinder", let s = m.sizeCm {
            out.append("## 大きさ（目安。実測ではありません）")
            out.append("")
            out.append("| 直径（幅・奥行き） | 高さ | 求め方 |")
            out.append("|---|---|---|")
            out.append("| \(f1(s.width)) cm | \(f1(s.height)) cm | 撮影時にユーザーが AR のガイドで合わせた円柱 |")
            out.append("")
            out.append("- **信頼度は低め**：輪郭（切り抜き）に使える写真が \(m.usableSilhouettes) 枚だけなので（visual hull には \(PackBuilder.minimumHullViews) 枚以上が要る）、写真からは測っていません。"
                       + "上の値は、作品をおおまかに囲むようにユーザーが目で合わせた円柱の大きさです。")
            out.append("- 作品はふつうこの円柱より小さく、上から見て丸いとは限りません（幅と奥行きは、どちらも円柱の直径です）。")
            out.append("- 高さは撮影時の基準点（作品の底の中心として測った点。求め方：\(m.baseSource.flatMap { baseSourceJa[$0] } ?? "記録なし")）からの高さです。")
            out.append("- 写真から大きさを読み取るときは、この円柱を上限の目安にし、推測した値は推測と書いてください。`hull.obj` はありません。")
        } else {
            out.append("## 大きさ（実測）")
            out.append("")
            sizeSection(m, into: &out)
        }
        out.append("")

        // Axes
        out.append("## モデルの座標")
        out.append("")
        if m.method == "headingDerived" {
            let base = m.heading?.origin == "base"
            out.append("- 単位はメートル。+Y が上。x・z の原点は撮ったあとに求めた作品の中心（写真の中心の線が交わる点）、"
                       + (base ? "y = 0 は作品の下の机の面（ARKit で測った面）。" : "y = 0 はその中心の高さ（**机の高さは分かりません**。底ではありません。おおよその底は `measurements.json` の `bboxMinM` の y）。")
                       + "`measurements.json` も同じ座標です。")
        } else if m.method == "userCylinder" {
            out.append("- 単位はメートル。+Y が上、原点は撮影時の基準点（作品の底の中心として測った点。y = 0 がおよそ机の面）。`measurements.json` も同じ座標です。")
        } else {
            out.append("- 単位はメートル。+Y が上、y = 0 は机の面。x・z の原点は撮影時の基準点（作品の底の中心のあたり）。`hull.obj` と `measurements.json` も同じ座標です。")
        }
        out.append(m.method == "headingDerived"
                   ? "- +Z が正面（正面の写真を撮ったときの iPhone の向きの反対。正面の写真は −Z の向きに作品を見ている）。+X は正面から見て右。"
                   : "- +Z が正面（`views/front.jpg` を撮ったカメラの方向。正面の写真は −Z の向きに作品を見ている）。+X は正面から見て右。")
        out.append("- 写真の「方位」は作品のまわりの角度（0° = 正面、90° = 右、180° = 後ろ、270° = 左）、「仰角」は見下ろす角度です。")
        out.append("")

        // Views
        out.append("## 写真（`views/`）")
        out.append("")
        out.append("すべて上下をまっすぐに回し、作品のまわりを切り抜き（背景は写ったまま）、長い辺 \(CropMath.maxOutputSide) px 以下にしたものです（元の写真より大きくはしない）。"
                   + (cutouts ? "`*_cutout.png` は同じ範囲で、iPhone のマスクの外を透明にしたものです（縁は 1 px ほどぼかす）。" : "背景を消した画像は作っていません。"))
        out.append("")
        out.append("| ファイル | 向き | 方位 | 仰角 | 距離 | 写真 | メモ |")
        out.append("|---|---|---|---|---|---|---|")
        for c in choices {
            let jaName = ja(c.name)
            guard let id = c.photoId else {
                let why = c.name == "top" ? "仰角 \(f0(ViewSlot.slots(for: session).first { $0.kind == .top }?.minimumElevationDeg))° 以上の写真なし"
                    : coverage.referenceFrameId == nil ? "方向が確定した写真なし"
                    : "方位 ±\(f0(ViewSelector.ringAzimuthTolerance))°・仰角 ±\(f0(c.name == "front_high" ? 12 : ViewSelector.ringElevationTolerance))° の中に写真なし"
                out.append("| — | \(jaName)（\(c.name)） | — | — | — | — | 写真なし：\(why) |")
                continue
            }
            let files = [c.file, c.cutoutFile].compactMap { $0 }.map { "`\($0)`" }.joined(separator: "<br>")
            let dist = c.distanceM.map { String(format: "%.2f m", $0) } ?? "—"
            out.append("| \(files) | \(jaName)（\(c.name)） | \(f0(c.azimuthDeg))° | \(f0(c.elevationDeg))° | \(dist) | #\(c.sequence ?? 0) `\(id)` | \(notesJa(c, session: session).joined(separator: "、")) |")
        }
        out.append("")

        // Coverage
        out.append("## 撮れている範囲")
        out.append("")
        out.append("- 使った基準：`\(coverage.referenceFrameId ?? "なし")`（このセッションの基準：\(coverage.referenceFrameIds.isEmpty ? "なし" : coverage.referenceFrameIds.joined(separator: "、"))）。"
                   + "別の基準の写真は置き方や座標が違うことがあるので使っていません。")
        out.append("- 写真 \(coverage.photoCount) 枚のうち、この基準で方向が確定した写真 \(coverage.photosInReferenceFrame) 枚。仰角 \(f0(coverage.minElevationDeg))°〜\(f0(coverage.maxElevationDeg))°。")
        if !coverage.bands.isEmpty {
            let text = coverage.bands.map { "仰角 \(DirectionTarget.formatDegrees($0.elevationDeg))°：撮影 \($0.shot)/\($0.targets)・確かめた切り抜きあり \($0.done)" }
            out.append("- 撮影方向の一覧 `\(coverage.directionPlanId)` の段ごとのそろい方：\(text.joined(separator: "、"))")
        }
        out.append("- **底面は写っていません**（作品を机に置いて撮ったため）。底の形・色は写真にありません。")
        if !coverage.missingViews.isEmpty {
            out.append("- 写真の無い向き：\(coverage.missingViews.map { "\(ja($0))（\($0)）" }.joined(separator: "、"))")
        }
        if !coverage.weakViews.isEmpty {
            out.append("- 注意のある向き：\(coverage.weakViews.map { "\(ja($0))（\($0)）" }.joined(separator: "、"))（上の表のメモ）")
        }
        out.append("")

        // Masks
        out.append("## 切り抜き（マスク）")
        out.append("")
        if maskIssues.isEmpty {
            out.append("- すべての写真の切り抜きが使える状態です（確認済み、または自動の確かめが ok）。")
        } else {
            out.append("使えない切り抜き（実寸\(cutouts ? "にも `*_cutout.png` に" : "に")も使っていません）と、確かめていない切り抜き（`candidate` で確かめの記録が無いもの。使っていますが要注意）の写真：")
            out.append("")
            for i in maskIssues {
                let check = i.check.map { "・確かめ \($0)" } ?? ""
                let reasons = i.reasons.isEmpty ? "" : "（\(i.reasons.joined(separator: ", "))）"
                out.append("- #\(i.sequence) `\(i.photoId)`：\(i.status)\(check)\(reasons)、基準 \(i.referenceFrameId ?? "なし")、方向 \(i.targetId ?? "なし")")
            }
        }
        out.append("- 切り抜きは自動（Apple の Vision）で作ったもので、細い部分・机と同じ色の部分が欠けたり、影が入ったりすることがあります。"
                   + (cutouts ? "形は `*_cutout.png` と元の `views/<向き>.jpg` を見比べてください。" : "写真を切り抜く範囲と実寸に使っています。"))
        out.append("")

        // How to use
        out.append("## AI でモデルを作るときの使い方")
        out.append("")
        out.append("1. `overview.jpg` で全体の形・色・向きをつかむ。")
        out.append("2. 形・色・模様・細部は `views/<向き>.jpg`（\(named ? "正面・右・後ろ・左・真上" : "正面・横・後ろ・上")）で見る。写真には背景（机・まわりの物）も写っています。作品は真ん中の物です。"
                   + (cutouts ? "作品だけの輪郭は `views/*_cutout.png`（透明の PNG）でも確かめられます。" : ""))
        if m.method == "headingDerived" {
            out.append(m.sizeCm == nil
                       ? "3. 大きさは分かりません。写真から推測し、推測した大きさは結果に書く。"
                       : "3. 大きさは上のおおよその値（`measurements.json` の `sizeM`。下の目安 `heading.size.lowerM`〜上の目安 `upperM`）を参考に、写真と見比べて決める。信頼度が低い寸法は写真を優先し、決めた大きさは結果に書く。")
        } else if m.method == "userCylinder" {
            out.append("3. 大きさは上の円柱（目安・上限）を参考に、写真から推測する。推測した大きさは結果に書く。")
        } else {
            out.append("3. 大きさは上の実測（`measurements.json` の `sizeM`）に合わせる。`hull.obj` を読み込んで、外形がその中に収まるように作ると位置と大きさがそろう。")
        }
        if let d = m.declaredHeight {
            out.append("   ただし高さは、撮る人が入力した \(f1(d.heightCm)) cm を優先する（上の「高さ（撮る人が入力した値）」）。")
        }
        out.append(m.method == "headingDerived" && m.heading?.origin != "base"
                   ? "4. 正面は +Z、上は +Y、単位はメートル。y = 0 は求めた中心の高さ（机の面ではない）。"
                   : "4. 正面は +Z、上は +Y、単位はメートル、y = 0 が机の面。")
        out.append("5. 写っていない所（底面、上の「写真の無い向き」）は推測になります。推測した部分は結果に書いてください。")
        out.append("")
        out.append("**これらの画像を Claude やほかのクラウドのツールに渡すことは外部への送信にあたります。** 子どもの作品とまわりが写った個人の写真です。送るかどうかはユーザーが決めます。")
        out.append("")

        // Provenance
        out.append("## 出どころ")
        out.append("")
        out.append("- sessionId：`\(provenance.sessionId)`")
        out.append("- manifestHash（`_receipt.json`）：`\(provenance.manifestHash ?? "なし")`")
        out.append("- 受信：\(provenance.receivedAt ?? "記録なし")")
        out.append("- 作成：\(provenance.generatedAt)（\(provenance.tool) \(provenance.toolVersion)）")
        out.append("- 機械で読む一覧：`pack.json`（写真の選び方・切り抜きの範囲・撮れている範囲）、`measurements.json`（実寸・写真ごとのずれ・注意。撮る人が高さを入力したときは `declaredHeight`）")
        out.append("")
        return out.joined(separator: "\n")
    }
}
