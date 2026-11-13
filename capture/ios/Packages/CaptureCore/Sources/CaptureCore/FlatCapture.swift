import Foundation
import simd

// 平面の作品（絵・貼り絵など）を真上から 1 枚撮るための型と計算。
// どちらの作品かはユーザーが新しいセッションを作るときに選ぶ（自動で見分けない）。
// 写真で測れたもの（用紙の四隅・実寸・補正した画像）だけを記録し、測れないものは推測で埋めずに null にする。

// MARK: - 作品の種類

/// 作品の種類（session.json の `workKind`）。
public enum WorkKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 立体（工作・粘土など）：まわりから撮る。撮り方は設定で選ぶ（既定は案内なしで自由に撮る。`CaptureGuidance`）。
    case object
    /// 平面（絵・貼り絵など）：真上から 1 枚だけ撮る。基準・マスクは使わない。
    case flat

    public var id: String { rawValue }

    /// 新しいセッションの画面に出す名前。
    public var displayName: String {
        switch self {
        case .object: return "立体（工作・粘土など）"
        case .flat: return "平面（絵・貼り絵など）"
        }
    }

    /// 1 行の説明。
    public var summary: String {
        switch self {
        case .object: return "作品のまわりから撮ります（正面・横・後ろ・真上があると作りやすくなります）"
        case .flat: return "真上から 1 枚だけ撮ります。紙の四隅を見つけて、まっすぐに直します"
        }
    }

    /// 見分けるための手がかり（どちらにするかはユーザーが決める）。
    public var hint: String {
        switch self {
        case .object: return "横から見ても形がある物（箱・人形・粘土など）"
        case .flat: return "横から見るとほぼ紙だけの物（クレヨンの絵、毛糸や紙を貼った絵など）"
        }
    }
}

/// `workKind` の読み書き：キーが無い・null は `object`（後から足した項目なので、前のセッションも読める）。書くときはいつも書く。
@propertyWrapper
public struct WorkKindCoding: Codable, Equatable, Sendable {
    public var wrappedValue: WorkKind

    public init(wrappedValue: WorkKind) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? .object : try container.decode(WorkKind.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// キーが無いときは `object` として読む（合成された init(from:) から呼ばれる）。
    public func decode(_ type: WorkKindCoding.Type, forKey key: Key) throws -> WorkKindCoding {
        try decodeIfPresent(type, forKey: key) ?? WorkKindCoding(wrappedValue: .object)
    }
}

// MARK: - session.json の `photos[].flat`

/// 写真のピクセルの点（保存した写真＝センサーの向き、原点は左上）。JSON では `[x, y]`。
public struct PixelPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ p: SIMD2<Double>) {
        self.init(x: p.x, y: p.y)
    }

    public var simd: SIMD2<Double> { SIMD2(x, y) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        guard values.count == 2 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "[x, y] ではありません"))
        }
        x = values[0]
        y = values[1]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([x, y])
    }
}

/// 用紙の四隅（保存した写真のピクセル）。左上・右上…は、写真を `displayRotationDegClockwise` だけ回して
/// まっすぐ見たときの位置（補正した画像の左上・右上・右下・左下になる）。
public struct FlatQuad: Codable, Equatable, Sendable {
    public var topLeft: PixelPoint
    public var topRight: PixelPoint
    public var bottomRight: PixelPoint
    public var bottomLeft: PixelPoint

    public init(topLeft: PixelPoint, topRight: PixelPoint, bottomRight: PixelPoint, bottomLeft: PixelPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// 左上・右上・右下・左下の順。
    public var points: [SIMD2<Double>] { [topLeft.simd, topRight.simd, bottomRight.simd, bottomLeft.simd] }

    /// 上の辺・下の辺・左の辺・右の辺の長さ（ピクセル）。
    public var edgeLengths: (top: Double, bottom: Double, left: Double, right: Double) {
        let p = points
        return (simd_distance(p[0], p[1]), simd_distance(p[3], p[2]), simd_distance(p[0], p[3]), simd_distance(p[1], p[2]))
    }

    /// 面積（ピクセル²、靴ひもの式）。
    public var area: Double {
        let p = points
        var sum = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// 外接長方形。
    public var boundingBox: PixelRect {
        let p = points
        return PixelRect(minX: p.map(\.x).min()!, minY: p.map(\.y).min()!, maxX: p.map(\.x).max()!, maxY: p.map(\.y).max()!)
    }
}

/// 用紙の実寸（m）。幅は補正した画像の横（上の辺・下の辺）、高さは縦（左の辺・右の辺）。
public struct FlatSheetSize: Codable, Equatable, Sendable {
    public var widthM: Double
    public var heightM: Double
    /// 四隅を当てた面：`existingPlaneGeometry`（ARKit が見つけた平面の形）| `estimatedPlane`（ARKit が推定した平面）。
    public var planeSource: String

    public init(widthM: Double, heightM: Double, planeSource: String) {
        self.widthM = widthM
        self.heightM = heightM
        self.planeSource = planeSource
    }
}

/// 遠近を直してまっすぐにした画像（`rectified/<photoId>.jpg`）。
public struct FlatRectifiedImage: Codable, Equatable, Sendable {
    public var file: String
    public var width: Int
    public var height: Int

    public init(file: String, width: Int, height: Int) {
        self.file = file
        self.width = width
        self.height = height
    }
}

/// 平面の作品の写真で、アプリが測ったもの（session.json の `photos[].flat`）。測れなかった値は null。
public struct FlatPhotoInfo: Codable, Equatable, Sendable {
    public static let visionMethod = "VNDetectRectanglesRequest"

    /// 用紙の四隅。四角が見つからなかったときは null（写真はそのまま全体を保存する）。
    @NullCodable public var corners: FlatQuad?
    /// 四隅の求め方（`VNDetectRectanglesRequest`）。四隅が無いときは null。
    @NullCodable public var cornersMethod: String?
    /// Vision の確からしさ（0〜1）。四隅が無いときは null。
    @NullCodable public var cornersConfidence: Double?
    /// 四隅のどれかが写真の端に近い（用紙が写真からはみ出しているかもしれない）。四隅が無いときは null。
    @NullCodable public var sheetAtFrameEdge: Bool?
    /// 実寸。四隅を ARKit の平面に当てて測れたときだけ。測れなければ null（推測しない）。
    @NullCodable public var size: FlatSheetSize?
    /// 遠近を直した画像。作れたときだけ。
    @NullCodable public var rectified: FlatRectifiedImage?

    public init(corners: FlatQuad? = nil, cornersMethod: String? = nil, cornersConfidence: Double? = nil, sheetAtFrameEdge: Bool? = nil,
                size: FlatSheetSize? = nil, rectified: FlatRectifiedImage? = nil) {
        self.corners = corners
        self.cornersMethod = cornersMethod
        self.cornersConfidence = cornersConfidence
        self.sheetAtFrameEdge = sheetAtFrameEdge
        self.size = size
        self.rectified = rectified
    }

    /// 四角が見つからなかった写真（全体をそのまま保存）。
    public static let noSheet = FlatPhotoInfo()
}

// MARK: - 計算

public enum FlatGeometry {
    /// 用紙の角が写真の端からこの割合（幅・高さに対して）より近ければ、端にかかっているとみなす。
    public static let frameEdgeMarginFraction = 0.02
    /// 用紙の面積がこの割合（写真の面積に対して）より小さければ、近づくよう案内する。
    public static let minimumSheetAreaFraction = 0.15

    /// カメラの光軸が水平から下へ傾いた角度（度）。真下を向くと 90、水平なら 0、上向きは負。
    /// 平面の作品の写真の `direction.elevationDeg` はこの値（作品の中心が分からないので、カメラの向きで測る）。
    public static func lookDownDeg(cameraToWorld: simd_double4x4) -> Double {
        let back = SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        let length = simd_length(back)
        guard length > 1e-9 else { return 0 }
        let forward = -back / length
        return Geometry.degrees(asin(min(1, max(-1, -forward.y))))
    }

    /// 平面の作品の画像の向き：端末の向きが分かればそれ（`DisplayRotation.rotation(deviceOrientation:)`）、
    /// 真上から撮って端末が上向き・下向き（faceUp・faceDown）のときは、縦向きの画面のまま（90）。
    /// 撮る人が画面で見ていた上が、まっすぐにした画像の上になる。
    public static func displayRotation(deviceOrientation: String) -> Int {
        DisplayRotation.rotation(deviceOrientation: deviceOrientation) ?? 90
    }

    /// 写真のピクセル（保存した画像の大きさ `imageSize`）を通る、カメラからの線（世界座標）。
    /// K は `camera.imageWidth × imageHeight`（intrinsicsResolution）の画像のものなので、保存した画像の大きさに合わせて直す。
    public static func ray(throughPixel p: SIMD2<Double>, camera: CameraModel, imageSize: PixelSize) -> Ray {
        let sx = camera.imageWidth / Double(max(1, imageSize.width))
        let sy = camera.imageHeight / Double(max(1, imageSize.height))
        let u = p.x * sx, v = p.y * sy
        let fx = camera.intrinsics[0][0], fy = camera.intrinsics[1][1]
        let cx = camera.intrinsics[2][0], cy = camera.intrinsics[2][1]
        // ARKit のカメラ：+X が画像の右、+Y が画像の上、−Z が前（ピクセルの y は下向き）。
        let local = SIMD3((u - cx) / fx, -(v - cy) / fy, -1.0)
        let m = camera.cameraToWorld
        let rotation = simd_double3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
        return Ray(origin: camera.position, direction: simd_normalize(rotation * local))
    }

    /// 線と平面（点 `planePoint`・法線 `planeNormal`）の交点。平面がカメラの後ろ・線とほぼ平行・`maxDistance` より遠いときは nil。
    public static func intersect(_ ray: Ray, planePoint: SIMD3<Double>, planeNormal: SIMD3<Double>, maxDistance: Double = 5) -> SIMD3<Double>? {
        let n = simd_normalize(planeNormal)
        let denominator = simd_dot(n, ray.direction)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = simd_dot(n, planePoint - ray.origin) / denominator
        guard t > 0, t <= maxDistance, t.isFinite else { return nil }
        return ray.point(at: t)
    }

    /// 世界の四隅（左上・右上・右下・左下）から用紙の幅（上と下の辺の平均）と高さ（左と右の辺の平均）。
    public static func sheetSize(worldCorners c: [SIMD3<Double>]) -> (widthM: Double, heightM: Double)? {
        guard c.count == 4 else { return nil }
        let width = (simd_distance(c[0], c[1]) + simd_distance(c[3], c[2])) / 2
        let height = (simd_distance(c[0], c[3]) + simd_distance(c[1], c[2])) / 2
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        return (width, height)
    }

    /// 写真の四隅を ARKit の平面に当てて、用紙の実寸を測る。どれかの角が平面に当たらなければ nil（推測しない）。
    public static func measureSize(
        corners: FlatQuad, camera: CameraModel, imageSize: PixelSize,
        planePoint: SIMD3<Double>, planeNormal: SIMD3<Double>, planeSource: String
    ) -> FlatSheetSize? {
        var world: [SIMD3<Double>] = []
        for p in corners.points {
            guard let hit = intersect(ray(throughPixel: p, camera: camera, imageSize: imageSize), planePoint: planePoint, planeNormal: planeNormal) else {
                return nil
            }
            world.append(hit)
        }
        guard let size = sheetSize(worldCorners: world) else { return nil }
        return FlatSheetSize(widthM: round4(size.widthM), heightM: round4(size.heightM), planeSource: planeSource)
    }

    /// 写真の中の 4 点（保存した写真のピクセル、順は問わない）を、まっすぐに回して見たときの
    /// 左上・右上・右下・左下に並べる。4 点でない・つぶれている（面積がほぼ 0）ときは nil。
    public static func orderCorners(_ points: [SIMD2<Double>], imageWidth: Int, imageHeight: Int, rotationDegClockwise: Int) -> FlatQuad? {
        guard points.count == 4, imageWidth > 0, imageHeight > 0 else { return nil }
        let display = DisplayRotation.displaySize(width: imageWidth, height: imageHeight, rotationDegClockwise: rotationDegClockwise)
        // まっすぐに回した画像のピクセル（y は下向き）。
        let shown = points.map { p -> SIMD2<Double> in
            let n = SIMD2(p.x / Double(imageWidth), p.y / Double(imageHeight))
            let d = DisplayRotation.displayPoint(fromSensor: n, rotationDegClockwise: rotationDegClockwise)
            return SIMD2(d.x * Double(display.width), d.y * Double(display.height))
        }
        let center = shown.reduce(SIMD2<Double>(0, 0), +) / 4
        // y が下向きなので、角度が増える向きは画面で時計回り（左上 → 右上 → 右下 → 左下）。
        let order = shown.indices.sorted { atan2(shown[$0].y - center.y, shown[$0].x - center.x) < atan2(shown[$1].y - center.y, shown[$1].x - center.x) }
        guard let first = order.indices.min(by: { shown[order[$0]].x + shown[order[$0]].y < shown[order[$1]].x + shown[order[$1]].y }) else { return nil }
        let ring = (0..<4).map { order[(first + $0) % 4] }
        let quad = FlatQuad(
            topLeft: PixelPoint(points[ring[0]]), topRight: PixelPoint(points[ring[1]]),
            bottomRight: PixelPoint(points[ring[2]]), bottomLeft: PixelPoint(points[ring[3]])
        )
        guard quad.area > 1 else { return nil }
        return quad
    }

    /// 四隅のどれかが写真の端から `marginFraction` 以内か（用紙が写真からはみ出しているかもしれない）。
    public static func touchesFrameEdge(_ quad: FlatQuad, imageWidth: Int, imageHeight: Int, marginFraction: Double = frameEdgeMarginFraction) -> Bool {
        let mx = Double(imageWidth) * marginFraction, my = Double(imageHeight) * marginFraction
        return quad.points.contains { $0.x <= mx || $0.y <= my || $0.x >= Double(imageWidth) - mx || $0.y >= Double(imageHeight) - my }
    }

    /// 補正した画像の大きさ（ピクセル）。縦横比は、撮る人が選んだ紙（`declaredSheet`）があればその比（向きは四隅の辺の長さで
    /// 決める：横が縦以上なら横が長い辺）、無ければ実寸が測れたときはその比、どちらも無ければ四隅の辺の長さ（長い方）の比。
    /// 長い辺は、四隅の長い方の辺のピクセル数（元の写真より細かくはしない）。
    public static func rectifiedSize(corners: FlatQuad, size: FlatSheetSize?, declaredSheet: DeclaredSheet? = nil) -> (width: Int, height: Int)? {
        let e = corners.edgeLengths
        let w = max(e.top, e.bottom), h = max(e.left, e.right)
        guard w >= 1, h >= 1 else { return nil }
        let longSide = max(w, h)
        let aspect: Double
        if let declared = declaredSheet?.oriented(horizontal: w, vertical: h), declared.widthM > 0, declared.heightM > 0 {
            aspect = declared.widthM / declared.heightM
        } else if let size, size.widthM > 0, size.heightM > 0 {
            aspect = size.widthM / size.heightM
        } else {
            aspect = w / h
        }
        let width = aspect >= 1 ? longSide : longSide * aspect
        let height = aspect >= 1 ? longSide / aspect : longSide
        return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
    }

    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}

// MARK: - 撮影画面の案内と自動撮影

/// 平面の作品の撮影画面で、今出す案内（いつも 1 つ）。
public enum FlatGuidance: Equatable, Sendable {
    /// 用紙（四角）が見つからない。
    case noSheet
    /// 用紙の角が画面の端にかかっている（切れているかもしれない）。
    case sheetAtEdge
    /// 用紙が小さい（離れすぎ）。
    case sheetSmall
    /// 真上から見下ろしていない（今の傾き → 要る傾き）。
    case tilt(currentDeg: Int, minimumDeg: Int)
    /// 撮れる。
    case ready

    /// 自動で撮ってよい状態か（止めている時間は `FlatShotStabilizer` が見る）。
    public var allowsAutoCapture: Bool { self == .ready }

    /// 案内の文（短く 1 つ）。
    public var message: String {
        switch self {
        case .noSheet: return "作品の真上に iPhone を持ち、紙の全体が画面に入るようにしてください"
        case .sheetAtEdge: return "紙の端が画面からはみ出しそうです。少し離して、紙の全体を入れてください"
        case .sheetSmall: return "もう少し近づいてください（紙の全体は画面に入れたまま）"
        case let .tilt(current, minimum): return "iPhone を水平に近づけて、真上から見下ろしてください（傾き \(current)° → \(minimum)° 以上）"
        case .ready: return "そのまま動かさないでください"
        }
    }

    /// 今の状態から案内を決める。
    /// - Parameters:
    ///   - corners: 見つかった用紙の四隅（写真の 0〜1 の座標、原点は左上。順は問わない）。見つからなければ nil。
    ///   - lookDownDeg: カメラの下向きの傾き（`FlatGeometry.lookDownDeg`）。分からなければ nil。
    public static func evaluate(corners: [SIMD2<Double>]?, lookDownDeg: Double?, plan: DirectionPlan = DirectionPlanPreset.flat1.plan) -> FlatGuidance {
        if let lookDownDeg, Coverage.matchElevationOnly(elevationDeg: lookDownDeg, plan: plan) == nil {
            let minimum = plan.targets.filter(\.anyAzimuth).map { $0.elevationDeg - $0.elevationToleranceDeg }.min() ?? 70
            return .tilt(currentDeg: Int(lookDownDeg.rounded()), minimumDeg: Int(minimum.rounded()))
        }
        guard let corners, corners.count == 4 else { return .noSheet }
        let unitQuad = FlatGeometry.orderCorners(corners.map { $0 * 1000 }, imageWidth: 1000, imageHeight: 1000, rotationDegClockwise: 0)
        guard let quad = unitQuad else { return .noSheet }
        if FlatGeometry.touchesFrameEdge(quad, imageWidth: 1000, imageHeight: 1000) { return .sheetAtEdge }
        if quad.area / 1_000_000 < FlatGeometry.minimumSheetAreaFraction { return .sheetSmall }
        return .ready
    }
}

/// 用紙の四隅が止まっている時間を数えて、自動撮影の進み具合（0〜1）を返す。
public struct FlatShotStabilizer: Sendable {
    /// これだけ止めたら撮る（秒）。
    public var holdSeconds: Double
    /// 角がこれ以上（写真の 0〜1 の座標で）動いたら、数え直す。
    public var maxCornerShift: Double

    private var anchor: [SIMD2<Double>]?
    private var since: Double?

    public init(holdSeconds: Double = 0.8, maxCornerShift: Double = 0.015) {
        self.holdSeconds = holdSeconds
        self.maxCornerShift = maxCornerShift
    }

    public mutating func reset() {
        anchor = nil
        since = nil
    }

    /// 新しい解析の結果を足す。`corners` は写真の 0〜1 の座標（順は解析ごとに同じとは限らないので、近い角どうしで比べる）。
    /// `allowed` が false（案内が ready でない）なら数え直す。
    public mutating func update(corners: [SIMD2<Double>]?, timestamp: Double, allowed: Bool) -> Double {
        guard allowed, let corners, corners.count == 4 else {
            reset()
            return 0
        }
        guard let anchor, let since, Self.maxShift(from: anchor, to: corners) <= maxCornerShift else {
            self.anchor = corners
            self.since = timestamp
            return 0
        }
        return min(1, max(0, (timestamp - since) / max(holdSeconds, 1e-6)))
    }

    /// `a` の各角から、`b` の一番近い角までの距離の最大。
    static func maxShift(from a: [SIMD2<Double>], to b: [SIMD2<Double>]) -> Double {
        a.map { p in b.map { simd_distance(p, $0) }.min() ?? .infinity }.max() ?? .infinity
    }
}

// MARK: - 方向の当てはめ（方位を問わない方向だけ）

extension Coverage {
    /// 方位を問わない方向（真上）だけを、仰角で当てはめる（平面の作品：方位は無い）。当てはまらなければ nil。
    public static func matchElevationOnly(elevationDeg: Double?, plan: DirectionPlan) -> DirectionTarget? {
        guard let elevationDeg, elevationDeg.isFinite else { return nil }
        return plan.targets
            .filter { $0.anyAzimuth && abs(elevationDeg - $0.elevationDeg) <= $0.elevationToleranceDeg }
            .min { abs(elevationDeg - $0.elevationDeg) < abs(elevationDeg - $1.elevationDeg) }
    }
}

// MARK: - 写真の記録

extension PhotoRecorder {
    /// 平面の作品の写真の記録。基準は使わない（`referenceFrameId` は null）。方向は端末の傾きだけで決める：
    /// `elevationDeg` はカメラの下向きの傾き、`azimuthDeg` は null、`distanceM` は四隅を当てた平面までの距離（無ければ null）。
    /// 傾きは重力から決まるので、追跡が `notAvailable` でなければ確定（`confirmed`）とし、真上の許容に入れば `targetId` を付ける。
    public static func makeFlatPhoto(
        session: CaptureSession, photoId: String, sequence: Int, frame: CapturedFrameInfo, context: CaptureContext,
        flat: FlatPhotoInfo, distanceM: Double? = nil
    ) -> Photo {
        let elevation = (FlatGeometry.lookDownDeg(cameraToWorld: frame.cameraToWorld) * 1000).rounded() / 1000
        let confirmed = frame.trackingState != .notAvailable
        let target = confirmed ? Coverage.matchElevationOnly(elevationDeg: elevation, plan: session.directionPlan) : nil
        let direction = DirectionInfo(
            confirmed: confirmed, unconfirmedReason: confirmed ? nil : .trackingNotNormal, targetId: target?.id,
            azimuthDeg: nil, elevationDeg: elevation, distanceM: distanceM.map { ($0 * 10000).rounded() / 10000 }
        )
        let image = ImageInfo(
            file: Photo.imagePath(photoId: photoId), width: frame.imageSize.width, height: frame.imageSize.height,
            displayRotationDegClockwise: DisplayRotation.normalized(context.displayRotationDegClockwise),
            deviceOrientation: context.deviceOrientation
        )
        let camera = CameraInfo(
            arFrameTimestamp: frame.timestamp, cameraToWorld: Matrix4x4(frame.cameraToWorld),
            intrinsics: Matrix3x3(frame.intrinsics), intrinsicsResolution: frame.intrinsicsResolution,
            exposureDurationS: frame.exposureDuration, exposureOffsetEV: frame.exposureOffset,
            trackingState: frame.trackingState, trackingReason: frame.trackingState == .limited ? frame.trackingReason : nil
        )
        return Photo(
            photoId: photoId, sequence: sequence, capturedAt: context.capturedAt, trigger: context.trigger,
            referenceFrameId: nil, image: image, camera: camera, direction: direction,
            quality: PhotoQuality(live: context.liveQuality), mask: .notGenerated, flat: flat
        )
    }
}
