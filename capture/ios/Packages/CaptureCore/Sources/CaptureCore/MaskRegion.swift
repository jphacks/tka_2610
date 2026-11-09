import Foundation
import simd

// 作品のマスクを、写真の全体ではなく作品のまわりを切り抜いた画像から作るための計算。
// Vision（VNGenerateForegroundInstanceMaskRequest）に写真の全体を渡すと、作品が小さいときに
// 机やマットのような大きな面を選んでしまう（または何も見つからない）ため。

/// 整数のピクセルの長方形（保存した写真の座標、原点は左上）。session.json の `mask.inputRegion`。
public struct PixelBox: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var rect: PixelRect { PixelRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height)) }
}

/// マスクを作るときに Vision に渡した範囲の決め方。
public enum MaskInputRegionSource: String, Codable, Sendable {
    /// 作品の円柱を写真の姿勢で投影した範囲（に余白を足したもの）。
    case projectedCylinder
    /// 写真の全体（基準が無い・作品がカメラの後ろなどで投影できないとき）。
    case fullImage
}

/// 写真に投影した作品の円柱（保存した写真のピクセル）。
public struct ProjectedObject: Equatable, Sendable {
    /// 外接長方形。
    public var boundingBox: PixelRect
    /// 輪郭（投影した点の凸包、時計回りか反時計回りの多角形）。
    public var silhouette: [SIMD2<Double>]

    public init(boundingBox: PixelRect, silhouette: [SIMD2<Double>]) {
        self.boundingBox = boundingBox
        self.silhouette = silhouette
    }
}

/// Vision に渡す切り抜きの範囲と、写真・切り抜き・物の番号の画像の座標の変換。
public struct MaskCropPlan: Equatable, Sendable {
    /// 切り抜く範囲（写真のピクセル）。`fullImage` のときは写真の全体。
    public var region: PixelBox
    public var source: MaskInputRegionSource
    public var imageWidth: Int
    public var imageHeight: Int
    /// 投影した作品（写真のピクセル）。投影できなかったときは nil。
    public var object: ProjectedObject?

    public init(region: PixelBox, source: MaskInputRegionSource, imageWidth: Int, imageHeight: Int, object: ProjectedObject?) {
        self.region = region
        self.source = source
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.object = object
    }

    public static func fullImage(width: Int, height: Int, object: ProjectedObject? = nil) -> MaskCropPlan {
        MaskCropPlan(region: PixelBox(x: 0, y: 0, width: width, height: height), source: .fullImage, imageWidth: width, imageHeight: height, object: object)
    }

    /// session.json の `mask.inputRegion` に書く値（全体のときは null）。
    public var recordedRegion: PixelBox? { source == .fullImage ? nil : region }

    // MARK: 座標の変換

    /// 写真のピクセル → 切り抜きのピクセル。
    public func cropPoint(fromImage p: SIMD2<Double>) -> SIMD2<Double> {
        p - SIMD2(Double(region.x), Double(region.y))
    }

    /// 切り抜きのピクセル → 写真のピクセル。
    public func imagePoint(fromCrop p: SIMD2<Double>) -> SIMD2<Double> {
        p + SIMD2(Double(region.x), Double(region.y))
    }

    /// 写真の 0〜1 に正規化した点（センサーの向き）→ 物の番号の画像（切り抜きに対する大きさ `mapWidth × mapHeight`）のピクセル。
    /// 切り抜きの外なら nil。
    public func labelMapPixel(fromNormalizedImage n: SIMD2<Double>, mapWidth: Int, mapHeight: Int) -> (x: Int, y: Int)? {
        let c = cropPoint(fromImage: SIMD2(n.x * Double(imageWidth), n.y * Double(imageHeight)))
        guard c.x >= 0, c.y >= 0, c.x < Double(region.width), c.y < Double(region.height), mapWidth > 0, mapHeight > 0 else { return nil }
        let x = Int(c.x * Double(mapWidth) / Double(region.width))
        let y = Int(c.y * Double(mapHeight) / Double(region.height))
        return (min(mapWidth - 1, x), min(mapHeight - 1, y))
    }

    /// 写真のピクセルの長方形 → 物の番号の画像のピクセル。
    public func mapRect(fromImage r: PixelRect, mapWidth: Int, mapHeight: Int) -> PixelRect {
        let o = cropPoint(fromImage: SIMD2(r.x, r.y))
        return PixelRect(x: o.x, y: o.y, width: r.width, height: r.height)
            .scaled(x: Double(mapWidth) / Double(max(1, region.width)), y: Double(mapHeight) / Double(max(1, region.height)))
    }

    /// 自動で選ぶときの作品の範囲（物の番号の画像の座標）。投影できなかったときは nil。
    public func selectionROI(mapWidth: Int, mapHeight: Int) -> PixelRect? {
        object.map { mapRect(fromImage: $0.boundingBox, mapWidth: mapWidth, mapHeight: mapHeight) }
    }

    /// 作品の輪郭（物の番号の画像の座標）。投影できなかったときは nil。
    public func silhouette(mapWidth: Int, mapHeight: Int) -> [SIMD2<Double>]? {
        guard let object else { return nil }
        let sx = Double(mapWidth) / Double(max(1, region.width)), sy = Double(mapHeight) / Double(max(1, region.height))
        return object.silhouette.map { p in
            let c = cropPoint(fromImage: p)
            return SIMD2(c.x * sx, c.y * sy)
        }
    }
}

/// 切り抜きの範囲を決める。
public enum MaskCropPlanner {
    /// 投影した作品の外接長方形を、中心のまわりにこの倍率で広げる（幅・高さそれぞれ）。
    /// 実機の写真（小さなマウス、円柱は大きめ）で 1.0〜2.0 を比べ、1.6 以上では机やマットを選ぶ・何も見つからない写真が多かった。
    public static let marginFactor = 1.2
    /// 最初の切り抜きで作品らしい物が見つからない（何も無い・広すぎる物だけ）ときに、もう一度試す倍率。
    public static let retryMarginFactor = 1.0
    /// 切り抜きの幅・高さの下限（ピクセル。写真より大きくはしない）。
    public static let minimumSide = 512

    /// 写真の姿勢で作品の円柱を投影する（保存した写真のピクセル）。基準・大きさが無い、作品がカメラの後ろなら nil。
    public static func projectObject(photo: Photo, session: CaptureSession) -> ProjectedObject? {
        // 写真を撮ったときの基準の大きさを使う（基準を設定し直すとセッションの大きさは変わるため）。
        guard let reference = session.referenceFrame(id: photo.referenceFrameId),
              let size = session.objectSize(referenceFrameId: photo.referenceFrameId) else { return nil }
        let k = photo.camera.intrinsicsResolution
        let camera = CameraModel(
            cameraToWorld: photo.camera.cameraToWorld.simd, intrinsics: photo.camera.intrinsics.simd,
            imageWidth: Double(k.width), imageHeight: Double(k.height)
        )
        let cylinder = ObjectCylinder(basePoint: reference.basePointWorld.simd, radiusM: size.radiusM, heightM: size.heightM)
        // K の画像と保存した画像の大きさが違うときは、保存した画像に合わせる。
        let sx = Double(photo.image.width) / Double(max(1, k.width))
        let sy = Double(photo.image.height) / Double(max(1, k.height))
        return projectObject(cylinder: cylinder, camera: camera, scaleX: sx, scaleY: sy)
    }

    public static func projectObject(cylinder: ObjectCylinder, camera: CameraModel, scaleX: Double = 1, scaleY: Double = 1) -> ProjectedObject? {
        guard camera.project(cylinder.center) != nil else { return nil }
        let points = cylinder.samplePoints(segments: 32).compactMap { camera.project($0) }.map { SIMD2($0.x * scaleX, $0.y * scaleY) }
        guard points.count >= 3 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let box = PixelRect(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!)
        guard !box.isEmpty else { return nil }
        return ProjectedObject(boundingBox: box, silhouette: Polygon.convexHull(points))
    }

    /// 投影した作品から切り抜きの範囲を決める。作品が無い・写真と重ならないときは写真の全体。
    /// 範囲は中心のまわりに `marginFactor` 倍に広げ、幅・高さを `minimumSide` 以上にし、
    /// 写真からはみ出すときは大きさを保ったまま内側へずらしてから、写真の中に切り詰める。
    public static func plan(
        object: ProjectedObject?, imageWidth: Int, imageHeight: Int,
        marginFactor: Double = marginFactor, minimumSide: Int = minimumSide
    ) -> MaskCropPlan {
        let w = Double(imageWidth), h = Double(imageHeight)
        guard imageWidth > 0, imageHeight > 0, let object,
              object.boundingBox.clamped(width: w, height: h) != nil else {
            return .fullImage(width: imageWidth, height: imageHeight, object: object)
        }
        let box = object.boundingBox
        let cw = min(w, max(box.width * marginFactor, Double(minimumSide)))
        let ch = min(h, max(box.height * marginFactor, Double(minimumSide)))
        let x0 = min(max(box.midX - cw / 2, 0), w - cw)
        let y0 = min(max(box.midY - ch / 2, 0), h - ch)
        let ix0 = max(0, Int(x0.rounded(.down))), iy0 = max(0, Int(y0.rounded(.down)))
        let ix1 = min(imageWidth, Int((x0 + cw).rounded(.up))), iy1 = min(imageHeight, Int((y0 + ch).rounded(.up)))
        return MaskCropPlan(
            region: PixelBox(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0),
            source: .projectedCylinder, imageWidth: imageWidth, imageHeight: imageHeight, object: object
        )
    }

    /// session.json の値（基準・作品の大きさ・写真の姿勢と K）から決める。撮ったあとの写真でも同じ結果になる。
    public static func plan(photo: Photo, session: CaptureSession) -> MaskCropPlan {
        plan(object: projectObject(photo: photo, session: session), imageWidth: photo.image.width, imageHeight: photo.image.height)
    }

    /// 試す順の切り抜き：`marginFactor`、次に `retryMarginFactor`（同じ範囲になるなら省く）。投影できなければ全体だけ。
    public static func plans(object: ProjectedObject?, imageWidth: Int, imageHeight: Int) -> [MaskCropPlan] {
        let first = plan(object: object, imageWidth: imageWidth, imageHeight: imageHeight, marginFactor: marginFactor)
        guard first.source == .projectedCylinder else { return [first] }
        let retry = plan(object: object, imageWidth: imageWidth, imageHeight: imageHeight, marginFactor: retryMarginFactor)
        return retry.region == first.region ? [first] : [first, retry]
    }

    public static func plans(photo: Photo, session: CaptureSession) -> [MaskCropPlan] {
        plans(object: projectObject(photo: photo, session: session), imageWidth: photo.image.width, imageHeight: photo.image.height)
    }

    /// マスクを作ったときの切り抜き（`mask.inputRegion`・`inputRegionSource` の記録から）。記録が無い・写真に収まらないときは nil。
    public static func recordedPlan(photo: Photo, session: CaptureSession) -> MaskCropPlan? {
        let w = photo.image.width, h = photo.image.height
        switch photo.mask.inputRegionSource {
        case .fullImage?:
            return .fullImage(width: w, height: h, object: projectObject(photo: photo, session: session))
        case .projectedCylinder?:
            guard let r = photo.mask.inputRegion, r.x >= 0, r.y >= 0, r.width > 0, r.height > 0, r.maxX <= w, r.maxY <= h else { return nil }
            return MaskCropPlan(region: r, source: .projectedCylinder, imageWidth: w, imageHeight: h, object: projectObject(photo: photo, session: session))
        case nil:
            return nil
        }
    }
}

/// 切り抜きで作ったマスクを、写真と同じ大きさの画像に貼る。
public enum MaskCanvas {
    /// `crop`（`region` の大きさ、1 行 `region.width` バイト）を、`fullWidth × fullHeight` の 0 の画像の `region` の位置に貼る。
    public static func paste(_ crop: [UInt8], region: PixelBox, fullWidth: Int, fullHeight: Int) -> [UInt8] {
        var full = [UInt8](repeating: 0, count: fullWidth * fullHeight)
        guard crop.count >= region.width * region.height else { return full }
        let x0 = max(0, region.x), x1 = min(fullWidth, region.maxX)
        let y0 = max(0, region.y), y1 = min(fullHeight, region.maxY)
        guard x1 > x0, y1 > y0 else { return full }
        crop.withUnsafeBufferPointer { src in
            full.withUnsafeMutableBufferPointer { dst in
                for y in y0..<y1 {
                    let s = (y - region.y) * region.width + (x0 - region.x)
                    let d = y * fullWidth + x0
                    for i in 0..<(x1 - x0) { dst[d + i] = src[s + i] }
                }
            }
        }
        return full
    }
}

/// 多角形の計算（作品の輪郭）。
public enum Polygon {
    /// 凸包（Andrew の monotone chain）。点が 3 つ未満ならそのまま。
    public static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Double>] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// 画像の各行で、多角形の中に入るピクセル（中心が中）の範囲 `x0..<x1`（偶奇規則）。
    public static func rowSpans(_ polygon: [SIMD2<Double>], row y: Int, width: Int) -> [Range<Int>] {
        guard polygon.count >= 3 else { return [] }
        let cy = Double(y) + 0.5
        var xs: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a.y <= cy && b.y > cy) || (b.y <= cy && a.y > cy) {
                xs.append(a.x + (cy - a.y) / (b.y - a.y) * (b.x - a.x))
            }
        }
        xs.sort()
        var spans: [Range<Int>] = []
        var i = 0
        while i + 1 < xs.count {
            // ピクセルの中心 x + 0.5 が [xs[i], xs[i+1]) に入る x。
            let x0 = max(0, Int((xs[i] - 0.5).rounded(.up)))
            let x1 = min(width, Int((xs[i + 1] - 0.5).rounded(.up)))
            if x1 > x0 { spans.append(x0..<x1) }
            i += 2
        }
        return spans
    }
}
