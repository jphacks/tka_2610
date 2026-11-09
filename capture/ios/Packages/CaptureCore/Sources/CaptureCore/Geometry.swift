import Foundation
import simd

/// 作品座標・角度の計算（docs/data-format.md の「決まり」）。
public enum Geometry {
    public static let up = SIMD3<Double>(0, 1, 0)

    /// 正面のカメラが基準点からこれより水平方向に近い（真上にいる）と、正面の向きが決まらない。
    public static let minimumFrontHorizontalDistance: Double = 0.05

    // MARK: 角度

    /// 0 以上 360 未満にする。
    public static func normalizeDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        if value >= 360 { value -= 360 }
        return value
    }

    /// `from` から `to` へ回る角度（−180 より大きく 180 以下）。正なら方位角が増える向き（正面から見て右へ回る）。
    public static func signedAngleDifference(from: Double, to: Double) -> Double {
        var d = normalizeDegrees(to - from)
        if d > 180 { d -= 360 }
        return d
    }

    /// 2 つの方位の差（0〜180）。360° をまたいでも正しい。
    public static func angleDistance(_ a: Double, _ b: Double) -> Double {
        abs(signedAngleDifference(from: a, to: b))
    }

    public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    // MARK: 作品座標

    /// 作品座標 → 世界。原点は基準点、+Y は上、+Z は基準点から正面のカメラへの水平方向、+X = Y × Z。
    /// カメラが基準点の真上近く（水平距離 5 cm 未満）にいて向きが決まらないときは nil。
    public static func objectToWorld(basePoint: SIMD3<Double>, frontCameraPosition: SIMD3<Double>) -> simd_double4x4? {
        var toCamera = frontCameraPosition - basePoint
        toCamera.y = 0
        let horizontal = simd_length(toCamera)
        guard horizontal >= minimumFrontHorizontalDistance else { return nil }
        let z = toCamera / horizontal
        let y = up
        let x = simd_cross(y, z)
        return simd_double4x4(columns: (
            SIMD4(x, 0),
            SIMD4(y, 0),
            SIMD4(z, 0),
            SIMD4(basePoint, 1)
        ))
    }

    /// 作品の中心（基準点から heightM / 2 上）。
    public static func objectCenter(basePoint: SIMD3<Double>, heightM: Double) -> SIMD3<Double> {
        basePoint + SIMD3(0, heightM / 2, 0)
    }

    /// カメラ位置の方位角（度、0〜360）。作品座標での (x, z) の atan2(x, z)。
    public static func azimuth(cameraPosition: SIMD3<Double>, objectToWorld: simd_double4x4) -> Double {
        let p = objectToWorld.inverse * SIMD4(cameraPosition, 1)
        return normalizeDegrees(degrees(atan2(p.x, p.z)))
    }

    /// 仰角（度。見下ろすと正）と、作品の中心からの距離（m）。正面が決まっていなくても計算できる。
    public static func elevationAndDistance(cameraPosition: SIMD3<Double>, basePoint: SIMD3<Double>, heightM: Double) -> (elevationDeg: Double, distanceM: Double) {
        let v = cameraPosition - objectCenter(basePoint: basePoint, heightM: heightM)
        let horizontal = (v.x * v.x + v.z * v.z).squareRoot()
        return (degrees(atan2(v.y, horizontal)), simd_length(v))
    }

    // MARK: 動き

    /// 2 つの姿勢の間の回転の角度（ラジアン）。
    public static func rotationAngle(from a: simd_double4x4, to b: simd_double4x4) -> Double {
        let ra = simd_double3x3(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
                                SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                                SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let rb = simd_double3x3(SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
                                SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                                SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        let r = ra.transpose * rb
        let trace = r[0][0] + r[1][1] + r[2][2]
        let cosine = min(1, max(-1, (trace - 1) / 2))
        return acos(cosine)
    }

    /// 角速度（rad/s）と速さ（m/s）。dt が 0 以下なら nil。
    public static func speeds(from a: simd_double4x4, at t0: Double, to b: simd_double4x4, at t1: Double) -> (angular: Double, linear: Double)? {
        let dt = t1 - t0
        guard dt > 0 else { return nil }
        let angle = rotationAngle(from: a, to: b)
        let distance = simd_length(b.translation - a.translation)
        return (angle / dt, distance / dt)
    }
}

/// 速さを指数移動平均でならす（ARKit の姿勢は 1 フレームごとに少し揺れるため）。
public struct MotionEstimator: Sendable {
    public var smoothing: Double
    public private(set) var angularSpeed: Double = 0
    public private(set) var linearSpeed: Double = 0
    private var last: (transform: simd_double4x4, time: Double)?

    public init(smoothing: Double = 0.3) {
        self.smoothing = smoothing
    }

    public mutating func update(transform: simd_double4x4, timestamp: Double) {
        defer { last = (transform, timestamp) }
        guard let last, let speeds = Geometry.speeds(from: last.transform, at: last.time, to: transform, at: timestamp) else { return }
        // 間が空きすぎた（中断のあと）ときはならさずに入れ直す。
        if timestamp - last.time > 0.5 {
            angularSpeed = speeds.angular
            linearSpeed = speeds.linear
            return
        }
        angularSpeed += smoothing * (speeds.angular - angularSpeed)
        linearSpeed += smoothing * (speeds.linear - linearSpeed)
    }

    public mutating func reset() {
        last = nil
        angularSpeed = 0
        linearSpeed = 0
    }
}

// MARK: - 画面への投影

/// 画像上の長方形（ピクセル、原点は左上）。
public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// 0...width × 0...height に切り詰める。重ならなければ nil。
    public func clamped(width w: Double, height h: Double) -> PixelRect? {
        let r = PixelRect(minX: max(0, minX), minY: max(0, minY), maxX: min(w, maxX), maxY: min(h, maxY))
        return r.isEmpty ? nil : r
    }

    public func scaled(x sx: Double, y sy: Double) -> PixelRect {
        PixelRect(x: x * sx, y: y * sy, width: width * sx, height: height * sy)
    }

    /// 各辺を幅・高さの `fraction` 倍だけ外へ広げる。
    public func expanded(by fraction: Double) -> PixelRect {
        let dx = width * fraction
        let dy = height * fraction
        return PixelRect(x: x - dx, y: y - dy, width: width + 2 * dx, height: height + 2 * dy)
    }
}

/// カメラ（ARKit の決まり：−Z が前、+Y が画像の上、+X が画像の右）。
public struct CameraModel: Equatable, Sendable {
    public var cameraToWorld: simd_double4x4
    public var intrinsics: simd_double3x3
    public var imageWidth: Double
    public var imageHeight: Double

    public init(cameraToWorld: simd_double4x4, intrinsics: simd_double3x3, imageWidth: Double, imageHeight: Double) {
        self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public var position: SIMD3<Double> { cameraToWorld.translation }

    /// 世界の点を画像のピクセルへ。カメラの後ろ（または近すぎる）点は nil。
    public func project(_ world: SIMD3<Double>, minimumDepth: Double = 0.01) -> SIMD2<Double>? {
        let c = cameraToWorld.inverse * SIMD4(world, 1)
        let depth = -c.z
        guard depth > minimumDepth else { return nil }
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        // カメラの +Y は画像の上、ピクセルの y は下向きなので符号を反転する。
        let u = fx * (c.x / depth) + cx
        let v = fy * (-c.y / depth) + cy
        return SIMD2(u, v)
    }
}

/// 作品を囲む円柱（基準点・半径・高さ）。回転しても形が変わらないので、正面が決まる前でも使える。
public struct ObjectCylinder: Equatable, Sendable {
    public var basePoint: SIMD3<Double>
    public var radiusM: Double
    public var heightM: Double

    public init(basePoint: SIMD3<Double>, radiusM: Double, heightM: Double) {
        self.basePoint = basePoint
        self.radiusM = radiusM
        self.heightM = heightM
    }

    public var center: SIMD3<Double> { Geometry.objectCenter(basePoint: basePoint, heightM: heightM) }

    /// 底と上の円周上の点と、底・上の中心。
    public func samplePoints(segments: Int = 16) -> [SIMD3<Double>] {
        var points: [SIMD3<Double>] = [basePoint, basePoint + SIMD3(0, heightM, 0)]
        for i in 0..<segments {
            let a = Double(i) / Double(segments) * 2 * .pi
            let offset = SIMD3(radiusM * cos(a), 0, radiusM * sin(a))
            points.append(basePoint + offset)
            points.append(basePoint + offset + SIMD3(0, heightM, 0))
        }
        return points
    }
}

public struct InFrameThresholds: Equatable, Sendable {
    /// 画像の端から内側に空ける割合（幅・高さに対して）。
    public var marginFraction: Double
    /// 作品の大きさの下限（投影した外接長方形の、幅の割合と高さの割合の大きい方）。
    public var minSizeFraction: Double
    /// 作品の大きさの上限。
    public var maxSizeFraction: Double

    public init(marginFraction: Double = 0.03, minSizeFraction: Double = 0.25, maxSizeFraction: Double = 0.9) {
        self.marginFraction = marginFraction
        self.minSizeFraction = minSizeFraction
        self.maxSizeFraction = maxSizeFraction
    }
}

public enum InFrameStatus: String, Equatable, Sendable {
    /// 全部の点が余白の内側にあり、大きさもちょうどよい。
    case inside
    /// 一部が画面の外（余白の外）か、一部がカメラの後ろ。
    case partiallyOutside
    /// 作品の中心がカメラの後ろ（作品にカメラが向いていない）。
    case behindCamera
    case tooSmall
    case tooLarge
}

public struct ProjectionResult: Equatable, Sendable {
    public var status: InFrameStatus
    /// カメラの前にある点を投影した外接長方形（画像の外にはみ出すこともある）。
    public var boundingBox: PixelRect?
    /// 外接長方形の、幅の割合と高さの割合の大きい方。
    public var sizeFraction: Double?
    /// 作品の中心を投影した位置。
    public var center: SIMD2<Double>?

    public init(status: InFrameStatus, boundingBox: PixelRect?, sizeFraction: Double?, center: SIMD2<Double>?) {
        self.status = status
        self.boundingBox = boundingBox
        self.sizeFraction = sizeFraction
        self.center = center
    }

    public var isOK: Bool { status == .inside }
}

public enum Projection {
    /// 作品の円柱が画面に収まっているかを調べる。
    public static func evaluate(cylinder: ObjectCylinder, camera: CameraModel, thresholds: InFrameThresholds = InFrameThresholds()) -> ProjectionResult {
        let center = camera.project(cylinder.center)
        let projected = cylinder.samplePoints().map { camera.project($0) }
        let visible = projected.compactMap { $0 }
        guard center != nil, !visible.isEmpty else {
            return ProjectionResult(status: .behindCamera, boundingBox: nil, sizeFraction: nil, center: nil)
        }
        let xs = visible.map(\.x), ys = visible.map(\.y)
        let box = PixelRect(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!)
        let size = max(box.width / camera.imageWidth, box.height / camera.imageHeight)

        let mx = camera.imageWidth * thresholds.marginFraction
        let my = camera.imageHeight * thresholds.marginFraction
        let allInFront = visible.count == projected.count
        let allInside = allInFront && visible.allSatisfy {
            $0.x >= mx && $0.x <= camera.imageWidth - mx && $0.y >= my && $0.y <= camera.imageHeight - my
        }
        let status: InFrameStatus
        if !allInside {
            status = size > thresholds.maxSizeFraction ? .tooLarge : .partiallyOutside
        } else if size < thresholds.minSizeFraction {
            status = .tooSmall
        } else if size > thresholds.maxSizeFraction {
            status = .tooLarge
        } else {
            status = .inside
        }
        return ProjectionResult(status: status, boundingBox: box, sizeFraction: size, center: center)
    }
}
