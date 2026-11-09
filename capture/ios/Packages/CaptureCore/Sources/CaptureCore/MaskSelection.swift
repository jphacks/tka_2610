import Foundation

/// Vision の物の番号の画像（0 = 背景、1… = 物）。
public struct InstanceLabelMap: Equatable, Sendable {
    public var labels: [UInt8]
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int

    public init(labels: [UInt8], width: Int, height: Int, bytesPerRow: Int? = nil) {
        self.labels = labels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow ?? width
    }

    public func label(x: Int, y: Int) -> Int {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return Int(labels[y * bytesPerRow + x])
    }

    /// 背景以外の番号（小さい順）。
    public var instanceLabels: [Int] {
        var seen = [Bool](repeating: false, count: 256)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width { seen[Int(labels[row + x])] = true }
        }
        return (1..<256).filter { seen[$0] }
    }
}

/// 作品の物を自動で選ぶ（投影した作品の範囲と重なる物）。
public enum MaskInstanceSelector {
    /// 重なりの一番大きい物に加えて、その半分以上重なり、かつ自分の面積の半分以上が範囲の中にある物も選ぶ。
    public static let secondaryOverlapRatio = 0.5
    public static let secondaryInsideRatio = 0.5

    /// - Parameters:
    ///   - roi: 作品の範囲（ラベル画像の座標）。nil なら画像の中央の半分の範囲。
    /// - Returns: 選んだ番号（小さい順）。物が 1 つだけならそれ、範囲と重なる物が無ければ空。
    public static func autoSelect(map: InstanceLabelMap, roi: PixelRect?) -> [Int] {
        let all = map.instanceLabels
        if all.isEmpty { return [] }
        if all.count == 1 { return all }

        let w = Double(map.width), h = Double(map.height)
        let area = roi ?? PixelRect(x: w * 0.25, y: h * 0.25, width: w * 0.5, height: h * 0.5)
        var total = [Int](repeating: 0, count: 256)
        var inside = [Int](repeating: 0, count: 256)
        let clamped = area.clamped(width: w, height: h)
        let x0 = clamped.map { Int($0.minX) } ?? 0, x1 = clamped.map { Int($0.maxX.rounded(.up)) } ?? 0
        let y0 = clamped.map { Int($0.minY) } ?? 0, y1 = clamped.map { Int($0.maxY.rounded(.up)) } ?? 0
        for y in 0..<map.height {
            let row = y * map.bytesPerRow
            let rowInside = y >= y0 && y < y1
            for x in 0..<map.width {
                let l = Int(map.labels[row + x])
                guard l != 0 else { continue }
                total[l] += 1
                if rowInside && x >= x0 && x < x1 { inside[l] += 1 }
            }
        }
        guard let best = all.max(by: { inside[$0] < inside[$1] || (inside[$0] == inside[$1] && $0 > $1) }),
              inside[best] > 0 else { return [] }
        return all.filter { l in
            if l == best { return true }
            guard inside[l] > 0, total[l] > 0 else { return false }
            return Double(inside[l]) >= secondaryOverlapRatio * Double(inside[best])
                && Double(inside[l]) / Double(total[l]) >= secondaryInsideRatio
        }
    }

    /// 選んだ物が画像（切り抜き）のこの割合より広いと、作品ではなく机やマットだとみなす。
    public static let tooLargeCoverage = 0.85

    /// `autoSelect(map:roi:)` で選んだ物が画像のほとんど（`tooLargeCoverage` より広い）を占め、
    /// ほかに広すぎない物があるときは、その中で作品の輪郭（`silhouette`、無ければ `roi`）と一番よく重なる物（IoU）に替える。
    /// 重なる物が無ければ、もとの選び方のまま。
    public static func autoSelect(map: InstanceLabelMap, roi: PixelRect?, silhouette: [SIMD2<Double>]?) -> [Int] {
        let selected = autoSelect(map: map, roi: roi)
        let all = map.instanceLabels
        let pixels = map.width * map.height
        guard all.count > 1, pixels > 0 else { return selected }
        let total = counts(map)
        let selectedArea = selected.reduce(0) { $0 + total[$1] }
        guard Double(selectedArea) > tooLargeCoverage * Double(pixels) else { return selected }

        let polygon = silhouette ?? roi.map { [SIMD2($0.minX, $0.minY), SIMD2($0.maxX, $0.minY), SIMD2($0.maxX, $0.maxY), SIMD2($0.minX, $0.maxY)] }
        guard let polygon, polygon.count >= 3 else { return selected }
        let candidates = all.filter { Double(total[$0]) <= tooLargeCoverage * Double(pixels) }
        guard !candidates.isEmpty else { return selected }

        // 輪郭の中のピクセル数と、物ごとの輪郭の中のピクセル数。
        var insidePolygon = 0
        var overlap = [Int](repeating: 0, count: 256)
        for y in 0..<map.height {
            let row = y * map.bytesPerRow
            for span in Polygon.rowSpans(polygon, row: y, width: map.width) {
                insidePolygon += span.count
                for x in span { overlap[Int(map.labels[row + x])] += 1 }
            }
        }
        func iou(_ l: Int) -> Double {
            let union = total[l] + insidePolygon - overlap[l]
            return union > 0 ? Double(overlap[l]) / Double(union) : 0
        }
        guard let best = candidates.max(by: { iou($0) < iou($1) || (iou($0) == iou($1) && $0 > $1) }), overlap[best] > 0 else {
            return selected
        }
        return [best]
    }

    /// 番号ごとのピクセル数。
    static func counts(_ map: InstanceLabelMap) -> [Int] {
        var total = [Int](repeating: 0, count: 256)
        for y in 0..<map.height {
            let row = y * map.bytesPerRow
            for x in 0..<map.width { total[Int(map.labels[row + x])] += 1 }
        }
        return total
    }

    /// 選んだ物が画像に占める割合（0〜1）。
    public static func coverage(map: InstanceLabelMap, selected: [Int]) -> Double {
        let pixels = map.width * map.height
        guard pixels > 0 else { return 0 }
        let total = counts(map)
        return Double(selected.reduce(0) { $0 + (($1 > 0 && $1 < 256) ? total[$1] : 0) }) / Double(pixels)
    }

    /// 作品らしい選び方か（何か選んでいて、画像のほとんどを占める物ではない）。
    /// そうでなければ、もっと狭い切り抜きで作り直してみる。
    public static func isPlausible(map: InstanceLabelMap, selected: [Int]) -> Bool {
        !selected.isEmpty && coverage(map: map, selected: selected) <= tooLargeCoverage
    }

    /// 選んだ物の中に `label` があれば外し、無ければ足す（0 = 背景は何もしない）。
    public static func toggle(_ label: Int, in selected: [Int]) -> [Int] {
        guard label > 0 else { return selected }
        if selected.contains(label) { return selected.filter { $0 != label } }
        return (selected + [label]).sorted()
    }

    /// 選んだ結果からマスクの状態を決める。
    public static func status(for selected: [Int]) -> MaskStatus {
        selected.isEmpty ? .noObject : .candidate
    }
}

/// 表示用の回転（`displayRotationDegClockwise`）と、保存した画像（センサーの向き）の座標の変換。
/// 座標は 0〜1 に正規化した値（左上が原点）。
public enum DisplayRotation {
    /// 0・90・180・270 のどれかにする。
    public static func normalized(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360 / 90 * 90
    }

    /// センサーの画像の点 → 時計回りに回して表示した画像の点。
    public static func displayPoint(fromSensor p: SIMD2<Double>, rotationDegClockwise: Int) -> SIMD2<Double> {
        switch normalized(rotationDegClockwise) {
        case 90: return SIMD2(1 - p.y, p.x)
        case 180: return SIMD2(1 - p.x, 1 - p.y)
        case 270: return SIMD2(p.y, 1 - p.x)
        default: return p
        }
    }

    /// 表示した画像の点 → センサーの画像の点（タップした位置から物の番号を引くため）。
    public static func sensorPoint(fromDisplay d: SIMD2<Double>, rotationDegClockwise: Int) -> SIMD2<Double> {
        switch normalized(rotationDegClockwise) {
        case 90: return SIMD2(d.y, 1 - d.x)
        case 180: return SIMD2(1 - d.x, 1 - d.y)
        case 270: return SIMD2(1 - d.y, d.x)
        default: return d
        }
    }

    /// 表示したときの幅と高さ。
    public static func displaySize(width: Int, height: Int, rotationDegClockwise: Int) -> (width: Int, height: Int) {
        normalized(rotationDegClockwise) % 180 == 0 ? (width, height) : (height, width)
    }

    /// 端末の重力（世界の上）をカメラ座標で見た向き（x: 画像の右、y: 画像の上）から、
    /// まっすぐ見るための時計回りの角度。端末の向きが分からない（上向き・下向き）ときの代わり。
    public static func rotationFromGravity(upInCameraX ux: Double, upInCameraY uy: Double) -> Int {
        if abs(uy) >= abs(ux) {
            return uy >= 0 ? 0 : 180
        }
        // 世界の上が画像の左にある → 時計回りに 90° 回すと上になる。
        return ux < 0 ? 90 : 270
    }

    /// UIDeviceOrientation の名前から。背面カメラのセンサーは、ホームボタン（下端）が右の横向き
    /// （UIDeviceOrientation.landscapeLeft）でまっすぐになる。
    public static func rotation(deviceOrientation: String) -> Int? {
        switch deviceOrientation {
        case "portrait": return 90
        case "portraitUpsideDown": return 270
        case "landscapeLeft": return 0
        case "landscapeRight": return 180
        default: return nil
        }
    }
}
