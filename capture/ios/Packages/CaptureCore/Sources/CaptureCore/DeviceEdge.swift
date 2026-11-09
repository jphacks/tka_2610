import Foundation
import simd

/// iPhone の形と、メインカメラ（広角。ARKit のワールドトラッキングが使うカメラ）の位置。
/// 「iPhone の下端を机に当てて測る」で、カメラの位置から下端（机に当たっているところ）までの距離に使う。
///
/// 値は Apple の寸法図（Accessory Design Guidelines の Dimensional Drawings）から読んだ「おおよそ」の値：
/// - iPhone 15（iPhone15,4）：本体 147.64 × 71.62 × 7.80 mm。図ではレンズの中心に寸法が無いので、裏面の図
///   （上端・左端の 0.00 と 37.15・64.96 の線を物差しにする）から測った。メインカメラ（REAR CAMERA 2、
///   見える角度 75.55°。左上の REAR CAMERA 1 は 121.83° の超広角）は、裏から見て上端から約 25.6 mm、左端から約 25.6 mm。
///   図を読む誤差は ±0.5 mm くらい。
/// - iPhone 16（iPhone17,3）：本体 147.64 × 71.63 × 7.81 mm。メインカメラ（REAR CAMERA 2、84°。上の REAR CAMERA 1 は
///   123° の超広角）は、図の寸法で上端から 31.34 mm、左端から 13.62 mm。
/// - Plus（iPhone15,5・iPhone17,4）：本体の大きさは Apple の仕様の値。カメラの位置は、同じ世代の Plus でない機種と
///   同じ（角からの距離が同じ）とみなしている（図では確かめていない）。
/// - カメラの光学中心は、裏面（裏のガラス）の上にあるとみなす（実際は 1〜2 mm ずれる）。
/// - 知らない機種は、よくある大きさの値を使う（下端までの距離が 1 cm くらい違うこともある）。
public struct DeviceCameraProfile: Equatable, Sendable {
    public var name: String
    public var heightM: Double
    public var widthM: Double
    public var thicknessM: Double
    /// 本体の角の丸み（画面の面で見た半径。m）。おおよそ。傾けて当てたときだけ効く。
    public var cornerRadiusM: Double
    /// 裏から見て、上端からメインカメラの中心まで（m）。
    public var cameraFromTopM: Double
    /// 裏から見て、左端（画面から見ると右端）からメインカメラの中心まで（m）。
    public var cameraFromSideM: Double
    /// 寸法図から読んだ機種か（false なら「おおよそ」と出す）。
    public var isKnownModel: Bool

    public init(name: String, heightM: Double, widthM: Double, thicknessM: Double, cornerRadiusM: Double,
                cameraFromTopM: Double, cameraFromSideM: Double, isKnownModel: Bool) {
        self.name = name
        self.heightM = heightM
        self.widthM = widthM
        self.thicknessM = thicknessM
        self.cornerRadiusM = cornerRadiusM
        self.cameraFromTopM = cameraFromTopM
        self.cameraFromSideM = cameraFromSideM
        self.isKnownModel = isKnownModel
    }

    public static let iPhone15 = DeviceCameraProfile(
        name: "iPhone 15", heightM: 0.14764, widthM: 0.07162, thicknessM: 0.0078, cornerRadiusM: 0.012,
        cameraFromTopM: 0.0256, cameraFromSideM: 0.0256, isKnownModel: true)
    public static let iPhone15Plus = DeviceCameraProfile(
        name: "iPhone 15 Plus", heightM: 0.16087, widthM: 0.07776, thicknessM: 0.0078, cornerRadiusM: 0.013,
        cameraFromTopM: 0.0256, cameraFromSideM: 0.0256, isKnownModel: true)
    public static let iPhone16 = DeviceCameraProfile(
        name: "iPhone 16", heightM: 0.14764, widthM: 0.07163, thicknessM: 0.00781, cornerRadiusM: 0.012,
        cameraFromTopM: 0.03134, cameraFromSideM: 0.01362, isKnownModel: true)
    public static let iPhone16Plus = DeviceCameraProfile(
        name: "iPhone 16 Plus", heightM: 0.16088, widthM: 0.07781, thicknessM: 0.0078, cornerRadiusM: 0.013,
        cameraFromTopM: 0.03134, cameraFromSideM: 0.01362, isKnownModel: true)
    /// 知らない機種（6.1 インチくらいの大きさ）。
    public static let generic = DeviceCameraProfile(
        name: "iPhone", heightM: 0.147, widthM: 0.0715, thicknessM: 0.008, cornerRadiusM: 0.012,
        cameraFromTopM: 0.022, cameraFromSideM: 0.018, isKnownModel: false)

    /// 機種の識別子（`iPhone15,4` など）から。知らない機種は `generic`。
    public static func forModel(_ identifier: String) -> DeviceCameraProfile {
        switch identifier {
        case "iPhone15,4": return .iPhone15
        case "iPhone15,5": return .iPhone15Plus
        case "iPhone17,3": return .iPhone16
        case "iPhone17,4": return .iPhone16Plus
        default: return .generic
        }
    }

    /// メインカメラから、下端の中央（厚みの真ん中）までのベクトル（ARKit のカメラの座標）。
    ///
    /// ARKit のカメラの座標は、センサーの横長の向きに固定（画面の向きでは変わらない）：
    /// +X は本体の長い辺に沿って、上端（前面カメラ）から下端へ。+Y はホームボタン（下端）を右にした横向きで上、
    /// つまり画面から見て本体の右。+Z は画面の側（画面から外へ）。
    /// 裏から見て左上にあるメインカメラは、画面から見ると右上にある。
    public var bottomEdgeOffsetInCamera: SIMD3<Double> {
        SIMD3(
            heightM - cameraFromTopM,          // 下へ（+X）
            -(widthM / 2 - cameraFromSideM),   // 画面から見て左へ（本体の中央へ）
            thicknessM / 2                     // 裏面から厚みの真ん中へ（画面の側）
        )
    }
}

/// 「iPhone の下端を机に当てて測る」の計算。
public enum DeviceEdgeMeasurement {
    /// iPhone を立てているとみなす、本体の下向き（カメラの +X）と真下のなす角の上限（度）。
    public static let maxTiltDeg: Double = 20

    /// 本体の下向き（カメラの +X）と、真下のなす角（度）。縦に立てて真っすぐなら 0。
    public static func tiltFromUprightDeg(cameraToWorld: simd_double4x4) -> Double {
        let down = simd_normalize(SIMD3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z))
        return Geometry.degrees(acos(min(1, max(-1, -down.y))))
    }

    public static func isUpright(cameraToWorld: simd_double4x4) -> Bool {
        tiltFromUprightDeg(cameraToWorld: cameraToWorld) <= maxTiltDeg
    }

    /// 下端の中央（厚みの真ん中）の世界の位置。
    public static func bottomEdgeCenter(cameraToWorld: simd_double4x4, profile: DeviceCameraProfile) -> SIMD3<Double> {
        let p = cameraToWorld * SIMD4(profile.bottomEdgeOffsetInCamera, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// 机の高さ（世界の y）：本体の一番低いところ。
    ///
    /// 本体を「角を丸めた長方形（画面の面）に厚みを付けたもの」とみなし、下の 2 つの角の丸み（中心と半径）と、
    /// 表・裏の 2 面の組（4 つの円）のうち一番低い点を使う。真っすぐ立てていれば下端の中央の高さと同じで、
    /// 少し傾けて角や縁で当たっていても、当たっているところの高さになる。
    public static func tableHeight(cameraToWorld: simd_double4x4, profile: DeviceCameraProfile) -> Double {
        let edge = profile.bottomEdgeOffsetInCamera
        let r = profile.cornerRadiusM
        let halfSpan = max(0, profile.widthM / 2 - r)
        // 画面の面の法線（カメラの +Z）。円（画面の面の中）の一番低い点は、中心から r·√(1 − n_y²) 下。
        let n = simd_normalize(SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z))
        let drop = r * (max(0, 1 - n.y * n.y)).squareRoot()
        var lowest = Double.infinity
        for side in [-1.0, 1.0] {
            for face in [-1.0, 1.0] {
                // 角の丸みの中心：下端から r 上（−X）、本体の中央から左右へ halfSpan、厚みの表・裏。
                let local = SIMD3(edge.x - r, edge.y + side * halfSpan, edge.z + face * profile.thicknessM / 2)
                let world = cameraToWorld * SIMD4(local, 1)
                lowest = min(lowest, world.y - drop)
            }
        }
        return lowest
    }
}

/// 端末を動かさずに持っている時間を数える（「iPhone の下端を机に当てて測る」の自動の測定）。
/// 動き始めた姿勢から、位置か向きが閾値より動いたら数え直す。
public struct StillnessTracker: Sendable {
    public var maxTranslationM: Double
    public var maxRotationDeg: Double
    private var anchor: (transform: simd_double4x4, time: Double)?

    public init(maxTranslationM: Double = 0.004, maxRotationDeg: Double = 1.5) {
        self.maxTranslationM = maxTranslationM
        self.maxRotationDeg = maxRotationDeg
    }

    /// 姿勢を足し、動かさずにいる時間（秒）を返す。
    public mutating func update(transform: simd_double4x4, timestamp: Double) -> Double {
        guard let anchor else {
            self.anchor = (transform, timestamp)
            return 0
        }
        let moved = simd_distance(transform.translation, anchor.transform.translation) > maxTranslationM
            || Geometry.degrees(Geometry.rotationAngle(from: anchor.transform, to: transform)) > maxRotationDeg
        if moved || timestamp < anchor.time {
            self.anchor = (transform, timestamp)
            return 0
        }
        return timestamp - anchor.time
    }

    public mutating func reset() {
        anchor = nil
    }
}

extension Array where Element == Double {
    /// 中央値（空なら nil）。
    public var median: Double? {
        guard !isEmpty else { return nil }
        let s = sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
