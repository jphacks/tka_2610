import Foundation
import simd

// できたマスクが作品らしいかを、投影した作品の円柱の輪郭と比べて確かめる（session.json の `mask.check`）。
// Vision が作品ではなく、撮る人の体・後ろのスピーカー・机のような物を選んだ写真を、撮影中に見つけて撮り直すため。

/// マスクの確かめの結果。
public enum MaskCheckStatus: String, Codable, Sendable {
    /// 作品らしい。
    case ok
    /// 作品ではない物を選んでいるかもしれない（`reasons` に理由）。
    case suspicious
    /// 確かめられない（基準が無い・作品を投影できない・写真の全体から作ったマスク）。
    case unknown
}

public enum MaskCheckReason: String, Codable, Sendable, CaseIterable {
    /// マスクの多くが作品の輪郭（少し広げたもの）の外にある。
    case outsideObject
    /// マスクが切り抜きの 2 辺以上に届いている（切り抜きの外まで続く大きな物）。
    case touchesCropEdge
    /// マスクが作品の輪郭や切り抜きに比べて広すぎる。
    case tooLarge
    /// マスクが作品の輪郭に比べて小さすぎる。
    case tooSmall
    /// マスクの重心が作品の中心から離れている。
    case offCenter
    /// マスクが空。
    case empty
    /// 作品を投影できない（基準が無い・作品の大きさが無い・写真の全体から作ったマスク）。
    case noProjection

    public var label: String {
        switch self {
        case .outsideObject: return "作品の外まで広がっている"
        case .touchesCropEdge: return "切り抜きの端に届いている"
        case .tooLarge: return "広すぎる"
        case .tooSmall: return "小さすぎる"
        case .offCenter: return "作品の位置からずれている"
        case .empty: return "空"
        case .noProjection: return "作品の位置が分からない"
        }
    }
}

/// session.json の `mask.check`。
public struct MaskCheck: Codable, Equatable, Sendable {
    public var status: MaskCheckStatus
    public var reasons: [MaskCheckReason]
    /// マスクのピクセルのうち、作品の輪郭（`silhouetteDilation` 倍に広げたもの）の中にある割合（0〜1）。
    @NullCodable public var insideSilhouetteRatio: Double?
    /// マスクが切り抜き（`inputRegion`）に占める割合（0〜1）。
    @NullCodable public var cropCoverage: Double?
    /// マスクの面積 ÷ 作品の輪郭の面積。
    @NullCodable public var silhouetteAreaRatio: Double?
    /// マスクの重心と作品の中心の距離 ÷ 作品の輪郭の外接長方形の長い辺。
    @NullCodable public var centerOffset: Double?
    /// マスクが届いている切り抜きの辺の数（0〜4）。
    @NullCodable public var touchedCropEdges: Int?

    public init(
        status: MaskCheckStatus, reasons: [MaskCheckReason], insideSilhouetteRatio: Double? = nil, cropCoverage: Double? = nil,
        silhouetteAreaRatio: Double? = nil, centerOffset: Double? = nil, touchedCropEdges: Int? = nil
    ) {
        self.status = status
        self.reasons = reasons
        self.insideSilhouetteRatio = insideSilhouetteRatio
        self.cropCoverage = cropCoverage
        self.silhouetteAreaRatio = silhouetteAreaRatio
        self.centerOffset = centerOffset
        self.touchedCropEdges = touchedCropEdges
    }

    /// 確かめられない（作品を投影できない）。
    public static let unknown = MaskCheck(status: .unknown, reasons: [.noProjection])
}

/// マスクの確かめのしきい値。値を変えるときはここだけを変える。
/// 実機のセッション（小さなマウス 17 枚。円柱は 1 回目の基準が高さ 15 cm・半径 9 cm（大きすぎる）、2 回目が高さ 4 cm・半径 9 cm）で、
/// 作品だけを選んだ写真が ok、撮る人の体・スピーカーとマットの一部を選んだ写真が suspicious になるように決めた値
/// （作品だけの写真の `insideSilhouetteRatio` は 0.99 以上、スピーカーを含む写真は 0.87、体は 0.65）。
/// 輪郭を広げる倍率は、切り抜きの余白（`MaskCropPlanner.marginFactor` 1.2）より小さくする（大きいと切り抜き全体が輪郭の中になる）。
public struct MaskCheckThresholds: Equatable, Sendable {
    /// 作品の輪郭（投影した円柱の凸包）を、外接長方形の中心のまわりにこの倍率で広げてから比べる（円柱は手で合わせた大きさのため）。
    public var silhouetteDilation: Double = 1.05
    /// マスクのうち、広げた輪郭の中にある割合がこれより小さいと `outsideObject`。
    public var minInsideSilhouetteRatio: Double = 0.93
    /// 切り抜きの辺から、短い辺のこの割合の幅の帯を「端」とみなす。
    public var edgeBandFraction: Double = 0.01
    /// 端の帯のうち、マスクがこの割合より多く入っている辺を「届いている」と数える。
    public var minEdgeTouchFraction: Double = 0.05
    /// この数以上の辺に届いていると `touchesCropEdge`。
    public var maxTouchedCropEdges: Int = 2
    /// マスクの面積 ÷ 作品の輪郭の面積がこれより大きいと `tooLarge`。
    public var maxSilhouetteAreaRatio: Double = 1.6
    /// マスクが切り抜きに占める割合がこれより大きいと `tooLarge`。
    public var maxCropCoverage: Double = 0.6
    /// マスクの面積 ÷ 作品の輪郭の面積がこれより小さいと `tooSmall`。
    public var minSilhouetteAreaRatio: Double = 0.03
    /// マスクの重心と作品の中心の距離 ÷ 輪郭の長い辺がこれより大きいと `offCenter`。
    public var maxCenterOffset: Double = 0.35
    /// 確かめる画像の長い辺（ピクセル）。これより大きいマスクは間引いて数える。
    public var analysisMaxSide: Int = 512
    /// 十字のまわりの切り抜き（向きで案内したセッション）：マスクが切り抜きのこの割合より小さいと `tooSmall`（作品が写っていない）。
    public var crosshairMinCoverage: Double = 0.003

    public init() {}

    public static let `default` = MaskCheckThresholds()
}

/// マスクの確かめ（純粋な計算。iPhone のマスク作りと、Mac での確かめの両方で使う）。
public enum MaskPlausibility {
    /// 切り抜き（`plan.region`）の大きさのマスク（1 行 `width` バイト、128 以上が作品）を確かめる。
    /// `width × height` は切り抜きを縮小した大きさでもよい。
    public static func evaluate(
        cropMask: [UInt8], width: Int, height: Int, plan: MaskCropPlan, thresholds: MaskCheckThresholds = .default
    ) -> MaskCheck {
        guard width > 0, height > 0, cropMask.count >= width * height else { return .unknown }
        let region = plan.region
        let sx = Double(width) / Double(max(1, region.width)), sy = Double(height) / Double(max(1, region.height))
        return evaluate(plan: plan, thresholds: thresholds) { ix, iy in
            // 写真のピクセル → 切り抜きのマスクのピクセル。
            let x = Int((Double(ix - region.x) + 0.5) * sx), y = Int((Double(iy - region.y) + 0.5) * sy)
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return cropMask[y * width + x] >= 128
        }
    }

    /// 写真と同じ大きさのマスク（session.json の `masks/<photoId>.png`、1 行 `width` バイト）を確かめる。
    /// `width × height` は写真を縮小した大きさでもよい。
    public static func evaluate(
        fullMask: [UInt8], width: Int, height: Int, plan: MaskCropPlan, thresholds: MaskCheckThresholds = .default
    ) -> MaskCheck {
        guard width > 0, height > 0, fullMask.count >= width * height else { return .unknown }
        let sx = Double(width) / Double(max(1, plan.imageWidth)), sy = Double(height) / Double(max(1, plan.imageHeight))
        return evaluate(plan: plan, thresholds: thresholds) { ix, iy in
            let x = min(width - 1, Int((Double(ix) + 0.5) * sx)), y = min(height - 1, Int((Double(iy) + 0.5) * sy))
            return fullMask[y * width + x] >= 128
        }
    }

    /// `isMask(x, y)`：写真のピクセル (x, y) がマスクの中か。切り抜きを最大 `analysisMaxSide` の格子で間引いて数える。
    public static func evaluate(
        plan: MaskCropPlan, thresholds t: MaskCheckThresholds = .default, isMask: (Int, Int) -> Bool
    ) -> MaskCheck {
        if plan.source == .crosshair { return evaluateCrosshair(plan: plan, thresholds: t, isMask: isMask) }
        guard plan.source == .projectedCylinder, let object = plan.object, object.silhouette.count >= 3 else { return .unknown }
        let region = plan.region
        guard region.width > 0, region.height > 0 else { return .unknown }
        let step = max(1, Int((Double(max(region.width, region.height)) / Double(max(1, t.analysisMaxSide))).rounded(.up)))
        let cols = (region.width + step - 1) / step, rows = (region.height + step - 1) / step

        // 作品の輪郭を外接長方形の中心のまわりに広げる。
        let box = object.boundingBox
        let center = SIMD2(box.midX, box.midY)
        let dilated = object.silhouette.map { center + ($0 - center) * t.silhouetteDilation }
        let silhouetteArea = abs(area(object.silhouette))
        let silhouetteSize = max(box.width, box.height)

        // 端の帯の幅（格子の数）。
        let band = max(1, Int((t.edgeBandFraction * Double(min(cols, rows))).rounded(.up)))
        var edgeHits = [0, 0, 0, 0]  // 左・右・上・下
        var maskCount = 0, insideCount = 0
        var sumX = 0.0, sumY = 0.0

        for r in 0..<rows {
            let iy = region.y + r * step + step / 2
            let cy = Double(iy) + 0.5
            let spans = spansAt(y: cy, polygon: dilated)
            for c in 0..<cols {
                let ix = region.x + c * step + step / 2
                guard isMask(ix, iy) else { continue }
                maskCount += 1
                let cx = Double(ix) + 0.5
                sumX += cx
                sumY += cy
                if spans.contains(where: { cx >= $0.lowerBound && cx < $0.upperBound }) { insideCount += 1 }
                if c < band { edgeHits[0] += 1 }
                if c >= cols - band { edgeHits[1] += 1 }
                if r < band { edgeHits[2] += 1 }
                if r >= rows - band { edgeHits[3] += 1 }
            }
        }

        guard maskCount > 0 else {
            return MaskCheck(status: .suspicious, reasons: [.empty], insideSilhouetteRatio: nil, cropCoverage: 0,
                             silhouetteAreaRatio: 0, centerOffset: nil, touchedCropEdges: 0)
        }
        let samples = Double(cols * rows)
        let cropCoverage = Double(maskCount) / samples
        let inside = Double(insideCount) / Double(maskCount)
        let maskArea = cropCoverage * Double(region.width * region.height)
        let areaRatio = silhouetteArea > 0 ? maskArea / silhouetteArea : .infinity
        let centroid = SIMD2(sumX, sumY) / Double(maskCount)
        let offset = silhouetteSize > 0 ? simd_length(centroid - center) / silhouetteSize : .infinity
        let sideSamples = [rows * band, rows * band, cols * band, cols * band]
        let touched = (0..<4).filter { Double(edgeHits[$0]) > t.minEdgeTouchFraction * Double(max(1, sideSamples[$0])) }.count

        var reasons: [MaskCheckReason] = []
        if inside < t.minInsideSilhouetteRatio { reasons.append(.outsideObject) }
        if touched >= t.maxTouchedCropEdges { reasons.append(.touchesCropEdge) }
        if areaRatio > t.maxSilhouetteAreaRatio || cropCoverage > t.maxCropCoverage { reasons.append(.tooLarge) }
        if areaRatio < t.minSilhouetteAreaRatio { reasons.append(.tooSmall) }
        if offset > t.maxCenterOffset { reasons.append(.offCenter) }
        return MaskCheck(
            status: reasons.isEmpty ? .ok : .suspicious, reasons: reasons,
            insideSilhouetteRatio: round4(inside), cropCoverage: round4(cropCoverage),
            silhouetteAreaRatio: areaRatio.isFinite ? round4(areaRatio) : nil,
            centerOffset: offset.isFinite ? round4(offset) : nil, touchedCropEdges: touched
        )
    }

    /// 十字のまわりの切り抜き（向きで案内したセッション）のマスクを確かめる。作品の輪郭が無いので、輪郭と比べる割合
    /// （`insideSilhouetteRatio`・`silhouetteAreaRatio`）は null。分かることだけで決める：
    /// 空（`empty`）、切り抜きの `crosshairMinCoverage` 未満（`tooSmall`）、切り抜きの `maxCropCoverage` より広い（`tooLarge`）、
    /// 切り抜きの 2 辺以上に届く（`touchesCropEdge`）、十字のまわり（`plan.object`）に 1 つも無く、重心が切り抜きの中心から
    /// 切り抜きの辺の `maxCenterOffset` 倍より離れている（`offCenter`）。
    static func evaluateCrosshair(plan: MaskCropPlan, thresholds t: MaskCheckThresholds, isMask: (Int, Int) -> Bool) -> MaskCheck {
        let region = plan.region
        guard region.width > 0, region.height > 0 else { return .unknown }
        let step = max(1, Int((Double(max(region.width, region.height)) / Double(max(1, t.analysisMaxSide))).rounded(.up)))
        let cols = (region.width + step - 1) / step, rows = (region.height + step - 1) / step
        let focus = plan.object?.boundingBox
        let center = SIMD2(Double(region.x) + Double(region.width) / 2, Double(region.y) + Double(region.height) / 2)
        let band = max(1, Int((t.edgeBandFraction * Double(min(cols, rows))).rounded(.up)))
        var edgeHits = [0, 0, 0, 0]
        var maskCount = 0, focusCount = 0
        var sumX = 0.0, sumY = 0.0
        for r in 0..<rows {
            let iy = region.y + r * step + step / 2
            for c in 0..<cols {
                let ix = region.x + c * step + step / 2
                guard isMask(ix, iy) else { continue }
                maskCount += 1
                let cx = Double(ix) + 0.5, cy = Double(iy) + 0.5
                sumX += cx
                sumY += cy
                if let f = focus, cx >= f.minX, cx < f.maxX, cy >= f.minY, cy < f.maxY { focusCount += 1 }
                if c < band { edgeHits[0] += 1 }
                if c >= cols - band { edgeHits[1] += 1 }
                if r < band { edgeHits[2] += 1 }
                if r >= rows - band { edgeHits[3] += 1 }
            }
        }
        guard maskCount > 0 else {
            return MaskCheck(status: .suspicious, reasons: [.empty], cropCoverage: 0, touchedCropEdges: 0)
        }
        let coverage = Double(maskCount) / Double(cols * rows)
        let centroid = SIMD2(sumX, sumY) / Double(maskCount)
        let offset = simd_length(centroid - center) / Double(max(region.width, region.height))
        let sideSamples = [rows * band, rows * band, cols * band, cols * band]
        let touched = (0..<4).filter { Double(edgeHits[$0]) > t.minEdgeTouchFraction * Double(max(1, sideSamples[$0])) }.count
        var reasons: [MaskCheckReason] = []
        if touched >= t.maxTouchedCropEdges { reasons.append(.touchesCropEdge) }
        if coverage > t.maxCropCoverage { reasons.append(.tooLarge) }
        if coverage < t.crosshairMinCoverage { reasons.append(.tooSmall) }
        if focusCount == 0 && offset > t.maxCenterOffset { reasons.append(.offCenter) }
        return MaskCheck(
            status: reasons.isEmpty ? .ok : .suspicious, reasons: reasons, insideSilhouetteRatio: nil,
            cropCoverage: round4(coverage), silhouetteAreaRatio: nil, centerOffset: round4(offset), touchedCropEdges: touched
        )
    }

    /// 多角形の面積（符号付き。向きで符号が変わる）。
    static func area(_ polygon: [SIMD2<Double>]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// 高さ y の水平線が多角形の中にある x の範囲（偶奇規則）。
    static func spansAt(y: Double, polygon: [SIMD2<Double>]) -> [Range<Double>] {
        var xs: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
            }
        }
        xs.sort()
        var spans: [Range<Double>] = []
        var i = 0
        while i + 1 < xs.count {
            if xs[i + 1] > xs[i] { spans.append(xs[i]..<xs[i + 1]) }
            i += 2
        }
        return spans
    }

    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
