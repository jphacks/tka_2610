import Foundation

public struct DirectionTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var azimuthDeg: Double
    public var elevationDeg: Double
    public var azimuthToleranceDeg: Double
    public var elevationToleranceDeg: Double

    public init(id: String, azimuthDeg: Double, elevationDeg: Double, azimuthToleranceDeg: Double, elevationToleranceDeg: Double) {
        self.id = id
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
        self.azimuthToleranceDeg = azimuthToleranceDeg
        self.elevationToleranceDeg = elevationToleranceDeg
    }

    /// `a000-e20` の形の id。方位は 0〜360 の整数を 3 桁、端数があれば小数 1 桁を付ける（`a022.5-e45`）。
    /// 仰角は整数 2 桁（負なら `m` を付ける）。同じ方位・仰角からはいつも同じ id になる。
    public static func makeId(azimuthDeg: Double, elevationDeg: Double) -> String {
        var az = (Geometry.normalizeDegrees(azimuthDeg) * 10).rounded() / 10
        if az >= 360 { az -= 360 }
        let el = Int(elevationDeg.rounded())
        let elText = el < 0 ? String(format: "m%02d", -el) : String(format: "%02d", el)
        return "a" + formatAzimuthForId(az) + "-e" + elText
    }

    /// 方位を id の形にする（整数なら `045`、端数があれば `022.5`）。
    static func formatAzimuthForId(_ az: Double) -> String {
        let whole = az.rounded()
        if abs(az - whole) < 0.05 { return String(format: "%03d", Int(whole)) }
        return String(format: "%05.1f", az)
    }

    /// 角度を画面に出す形にする（整数なら `45`、端数があれば `22.5`）。
    public static func formatDegrees(_ degrees: Double) -> String {
        let whole = degrees.rounded()
        if abs(degrees - whole) < 0.05 { return "\(Int(whole))" }
        return String(format: "%.1f", degrees)
    }

    public static func make(azimuthDeg: Double, elevationDeg: Double, azimuthTolerance: Double, elevationTolerance: Double) -> DirectionTarget {
        DirectionTarget(
            id: makeId(azimuthDeg: azimuthDeg, elevationDeg: elevationDeg),
            azimuthDeg: azimuthDeg, elevationDeg: elevationDeg,
            azimuthToleranceDeg: azimuthTolerance, elevationToleranceDeg: elevationTolerance
        )
    }
}

/// 撮影する方向の一覧（session.json の `directionPlan`）。
public struct DirectionPlan: Codable, Equatable, Sendable {
    public var id: String
    public var targets: [DirectionTarget]

    public init(id: String, targets: [DirectionTarget]) {
        self.id = id
        self.targets = targets
    }

    public func target(id: String?) -> DirectionTarget? {
        guard let id else { return nil }
        return targets.first { $0.id == id }
    }

    /// 仰角ごとの段（低い順）。段の中は方位の順。
    public var bands: [ElevationBand] {
        var result: [ElevationBand] = []
        for target in targets {
            if let i = result.firstIndex(where: { ElevationBand.sameElevation($0.elevationDeg, target.elevationDeg) }) {
                result[i].targets.append(target)
            } else {
                result.append(ElevationBand(elevationDeg: target.elevationDeg, targets: [target]))
            }
        }
        for i in result.indices {
            result[i].targets.sort { Geometry.normalizeDegrees($0.azimuthDeg) < Geometry.normalizeDegrees($1.azimuthDeg) }
        }
        return result.sorted { $0.elevationDeg < $1.elevationDeg }
    }

    /// 方向の入っている段。
    public func band(of target: DirectionTarget) -> ElevationBand? {
        bands.first { ElevationBand.sameElevation($0.elevationDeg, target.elevationDeg) }
    }
}

/// 同じ仰角の撮影方向（1 周）。
public struct ElevationBand: Equatable, Sendable, Identifiable {
    public var elevationDeg: Double
    /// 方位の順（0° から右回り）。
    public var targets: [DirectionTarget]

    public init(elevationDeg: Double, targets: [DirectionTarget]) {
        self.elevationDeg = elevationDeg
        self.targets = targets
    }

    public var id: String { DirectionTarget.formatDegrees(elevationDeg) }

    public func contains(_ target: DirectionTarget) -> Bool { Self.sameElevation(elevationDeg, target.elevationDeg) }

    static func sameElevation(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }
}

/// 撮影方向のプリセット。値を変えるときはここだけを変える。
/// 一覧にない方向の写真（追加撮影）はいつでも撮れる（`targetId` が null になる）。
public enum DirectionPlanPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 既定。Mac の写真測量（RealityKit の PhotogrammetrySession）用に、3 つの高さで 48 方向。
    /// 仰角 20° で 15° ごとに 24、45° で 22.5° ごとに 16、70° で 45° ごとに 8。
    case photogrammetry
    /// 仰角 20° で 45° ごとに 8 方向。
    case ring8
    /// 仰角 20° で 0 / 90 / 180 / 270 の 4 方向。
    case ring4
    /// ring8 に、仰角 50° で 90° ごとの 4 方向を足した 12 方向。
    case ring8plusHigh

    public var id: String { rawValue }

    /// 新しく作るセッションの既定（今あるセッションは session.json の `directionPlan` のまま）。
    public static let `default`: DirectionPlanPreset = .photogrammetry

    /// 方位の許容（±度）。ring8・ring4・ring8plusHigh。
    public static let azimuthTolerance: Double = 20
    /// 仰角の許容（±度）。ring8・ring4・ring8plusHigh。
    public static let elevationTolerance: Double = 15
    /// ふつうの高さの仰角。
    public static let lowElevation: Double = 20
    /// 上から撮る方向の仰角（ring8plusHigh）。
    public static let highElevation: Double = 50

    /// photogrammetry の段：仰角・方位の間隔・方位の許容。仰角の許容はどの段も ±10°（段の間に隙間を残す）。
    /// 隣の方向と許容が重ならない（15° 間隔に ±7°、22.5° 間隔に ±10°、45° 間隔に ±20°）。
    public static let photogrammetryBands: [(elevation: Double, step: Double, azimuthTolerance: Double)] = [
        (20, 15, 7), (45, 22.5, 10), (70, 45, 20),
    ]
    public static let photogrammetryElevationTolerance: Double = 10

    public var displayName: String {
        switch self {
        case .photogrammetry: return "3D 用 48 方向（標準）"
        case .ring8: return "8 方向"
        case .ring4: return "4 方向（かんたん）"
        case .ring8plusHigh: return "8 方向 + 上から 4 方向"
        }
    }

    /// 設定画面に出す 1 行の説明。
    public var summary: String {
        switch self {
        case .photogrammetry: return "Mac で写真から 3D を作る用。48 枚・約 3〜5 分"
        case .ring8: return "まわりを 1 周。8 枚・約 1 分"
        case .ring4: return "前後左右だけ。4 枚"
        case .ring8plusHigh: return "1 周と、上から 4 枚。12 枚"
        }
    }

    public var plan: DirectionPlan {
        DirectionPlan(id: rawValue, targets: targets)
    }

    private var targets: [DirectionTarget] {
        func ring(step: Double, elevation: Double, azTol: Double = Self.azimuthTolerance, elTol: Double = Self.elevationTolerance) -> [DirectionTarget] {
            let count = Int((360 / step).rounded())
            return (0..<count).map {
                DirectionTarget.make(azimuthDeg: Double($0) * step, elevationDeg: elevation, azimuthTolerance: azTol, elevationTolerance: elTol)
            }
        }
        switch self {
        case .photogrammetry:
            return Self.photogrammetryBands.flatMap {
                ring(step: $0.step, elevation: $0.elevation, azTol: $0.azimuthTolerance, elTol: Self.photogrammetryElevationTolerance)
            }
        case .ring8:
            return ring(step: 45, elevation: Self.lowElevation)
        case .ring4:
            return ring(step: 90, elevation: Self.lowElevation)
        case .ring8plusHigh:
            return ring(step: 45, elevation: Self.lowElevation) + ring(step: 90, elevation: Self.highElevation)
        }
    }
}
