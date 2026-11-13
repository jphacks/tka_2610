import Foundation

public struct DirectionTarget: Equatable, Sendable, Identifiable {
    public var id: String
    /// 方位（度）。`anyAzimuth` のときは意味を持たない（0 を入れる）。
    public var azimuthDeg: Double
    public var elevationDeg: Double
    /// 方位の許容（±度）。`anyAzimuth` のときは 180（古い読み手が方位で弾かないように）。
    public var azimuthToleranceDeg: Double
    public var elevationToleranceDeg: Double
    /// 方位を問わない方向（真上から撮る `top-e90` など）。仰角だけで当てはめ、案内でも回る向きを言わない。
    /// session.json の `anyAzimuth`（書くときはいつも書く。読むときにキーが無ければ false＝この項目より前のセッション）。
    public var anyAzimuth: Bool

    public init(id: String, azimuthDeg: Double, elevationDeg: Double, azimuthToleranceDeg: Double, elevationToleranceDeg: Double, anyAzimuth: Bool = false) {
        self.id = id
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
        self.azimuthToleranceDeg = azimuthToleranceDeg
        self.elevationToleranceDeg = elevationToleranceDeg
        self.anyAzimuth = anyAzimuth
    }

    /// 方位 `azimuthDeg` からこの方向までの差（0〜180）。方位を問わない方向はいつも 0。
    public func azimuthDistance(from azimuthDeg: Double) -> Double {
        anyAzimuth ? 0 : Geometry.angleDistance(azimuthDeg, self.azimuthDeg)
    }

    /// `from` からこの方向へ回る角度（正 = 右）。方位を問わない方向はいつも 0（回らなくてよい）。
    public func travel(from azimuthDeg: Double) -> Double {
        anyAzimuth ? 0 : Geometry.signedAngleDifference(from: azimuthDeg, to: self.azimuthDeg)
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

    /// 方位を問わない方向の id：`top-e90` の形（仰角は makeId と同じ書き方）。
    public static func makeTopId(elevationDeg: Double) -> String {
        let el = Int(elevationDeg.rounded())
        return "top-e" + (el < 0 ? String(format: "m%02d", -el) : String(format: "%02d", el))
    }

    /// 方位を問わない方向（真上など）。session.json では azimuthDeg 0・azimuthToleranceDeg 180・anyAzimuth true。
    public static func top(elevationDeg: Double, elevationTolerance: Double) -> DirectionTarget {
        DirectionTarget(
            id: makeTopId(elevationDeg: elevationDeg), azimuthDeg: 0, elevationDeg: elevationDeg,
            azimuthToleranceDeg: 180, elevationToleranceDeg: elevationTolerance, anyAzimuth: true
        )
    }

    /// 前後左右・真上の短い名前（方位を問わない方向は「真上」、方位 0/90/180/270 は「正面・右・後ろ・左」）。ほかは nil。
    public var stepName: String? {
        if anyAzimuth { return "真上" }
        let az = Geometry.normalizeDegrees(azimuthDeg)
        for (deg, name) in [(0.0, "正面"), (90, "右"), (180, "後ろ"), (270, "左")] where Geometry.angleDistance(az, deg) < 0.05 {
            return name
        }
        return nil
    }
}

extension DirectionTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, azimuthDeg, elevationDeg, azimuthToleranceDeg, elevationToleranceDeg, anyAzimuth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        azimuthDeg = try c.decode(Double.self, forKey: .azimuthDeg)
        elevationDeg = try c.decode(Double.self, forKey: .elevationDeg)
        azimuthToleranceDeg = try c.decode(Double.self, forKey: .azimuthToleranceDeg)
        elevationToleranceDeg = try c.decode(Double.self, forKey: .elevationToleranceDeg)
        anyAzimuth = try c.decodeIfPresent(Bool.self, forKey: .anyAzimuth) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(azimuthDeg, forKey: .azimuthDeg)
        try c.encode(elevationDeg, forKey: .elevationDeg)
        try c.encode(azimuthToleranceDeg, forKey: .azimuthToleranceDeg)
        try c.encode(elevationToleranceDeg, forKey: .elevationToleranceDeg)
        try c.encode(anyAzimuth, forKey: .anyAzimuth)
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

    /// 方向を「正面・右・後ろ・左・真上」の名前で案内する一覧（ai5）。
    public var usesStepNames: Bool { id == DirectionPlanPreset.ai5.rawValue }

    /// 平面の作品（絵・貼り絵など）を真上から 1 枚撮る一覧（flat1）。基準（底の中心・円柱）を使わず、マスクも作らない。
    public var isFlat: Bool { id == DirectionPlanPreset.flat1.rawValue }

    /// 立体の作品を案内なしで自由に撮る一覧（free。方向は 0 個）。基準を使わず、マスクも作らない。
    public var isFree: Bool { id == DirectionPlanPreset.free.rawValue }

    /// 撮る前に基準（底の中心・円柱）を決める一覧か。flat1・free は基準を作らない（方向は端末の傾きだけで決める）。
    public var needsReference: Bool { !isFlat && !isFree }

    /// 方向の名前（画面に出す）。ai5・flat1 は「正面」「右」…「真上」、ほかは「45°・高さ 20°」。方位を問わない方向は「真上（高さ 90°）」。
    public func displayName(of target: DirectionTarget) -> String {
        if usesStepNames || isFlat, let name = target.stepName { return name }
        let el = DirectionTarget.formatDegrees(target.elevationDeg)
        if target.anyAzimuth { return "\(target.stepName ?? "上")（高さ \(el)°）" }
        return "\(DirectionTarget.formatDegrees(target.azimuthDeg))°・高さ \(el)°"
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
    /// 既定。AI に 3D を推論させる用の 5 方向：仰角 15° の正面・右・後ろ・左（`a000-e15`・`a090-e15`・`a180-e15`・`a270-e15`）と、
    /// 真上（`top-e90`。方位を問わない：仰角 75° 以上ならどの方位でもよい）。撮る順は 正面 → 近い横 → … → 真上。
    case ai5
    /// Mac の写真測量（RealityKit の PhotogrammetrySession）用に、3 つの高さで 48 方向。
    /// 仰角 20° で 15° ごとに 24、45° で 22.5° ごとに 16、70° で 45° ごとに 8。
    case photogrammetry
    /// 仰角 20° で 45° ごとに 8 方向。
    case ring8
    /// 仰角 20° で 0 / 90 / 180 / 270 の 4 方向。
    case ring4
    /// ring8 に、仰角 50° で 90° ごとの 4 方向を足した 12 方向。
    case ring8plusHigh
    /// 平面の作品（`workKind` が `flat`）：真上から 1 枚（`top-e90`。方位を問わない、iPhone の傾きが 70° 以上）。
    /// 立体の作品の一覧ではないので、設定画面の「撮る方向」には出さない（`objectPresets`）。
    case flat1
    /// 立体の作品を自由に撮る（`guidance` が `free`）：方向は 0 個（何枚でも、どの向きでも撮れる。`targetId` はいつも null）。
    /// 設定画面の「撮る方向」には出さない（`objectPresets`）。
    case free

    public var id: String { rawValue }

    /// 新しく作るセッションの既定（今あるセッションは session.json の `directionPlan` のまま）。
    public static let `default`: DirectionPlanPreset = .ai5

    /// 立体の作品の撮り方（設定画面で選べる一覧）。flat1 は「平面」を選んだセッション、free は自由に撮るセッションだけが使う。
    public static var objectPresets: [DirectionPlanPreset] { allCases.filter { $0 != .flat1 && $0 != .free } }

    /// 作品の種類で決まる一覧：平面は flat1、立体は `objectPreset`（設定で選んだもの。flat1・free が渡されたら既定）。
    /// 自由に撮るセッションの一覧は `CaptureGuidance.newSession` が free にする。
    public static func plan(for kind: WorkKind, objectPreset: DirectionPlanPreset) -> DirectionPlan {
        switch kind {
        case .flat: return DirectionPlanPreset.flat1.plan
        case .object: return (objectPresets.contains(objectPreset) ? objectPreset : DirectionPlanPreset.default).plan
        }
    }

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

    /// ai5 の横の 4 方向：仰角・方位の許容・仰角の許容。
    public static let ai5SideElevation: Double = 15
    public static let ai5SideAzimuthTolerance: Double = 15
    public static let ai5SideElevationTolerance: Double = 12
    /// ai5 の真上：仰角 90°、許容 ±15°（75° 以上で当てはまる）。方位は問わない。
    public static let ai5TopElevation: Double = 90
    public static let ai5TopElevationTolerance: Double = 15
    /// flat1 の真上：仰角 90°、許容 ±20°（iPhone の傾きが 70° 以上で当てはまる）。平面の作品では仰角は
    /// 作品の中心からではなく、カメラの向き（光軸が水平から下へ傾いた角度）で測る（`FlatGeometry.lookDownDeg`）。
    public static let flatTopElevation: Double = 90
    public static let flatTopElevationTolerance: Double = 20

    public var displayName: String {
        switch self {
        case .ai5: return "AI 用 5 方向（標準）"
        case .photogrammetry: return "3D 用 48 方向"
        case .ring8: return "8 方向"
        case .ring4: return "4 方向（かんたん）"
        case .ring8plusHigh: return "8 方向 + 上から 4 方向"
        case .flat1: return "平面（真上から 1 枚）"
        case .free: return "自由に撮る"
        }
    }

    /// 設定画面に出す 1 行の説明。
    public var summary: String {
        switch self {
        case .ai5: return "AI に推論させる用。4 方向 + 真上の 5 枚"
        case .photogrammetry: return "Mac で写真から 3D を作る用。48 枚・約 3〜5 分"
        case .ring8: return "まわりを 1 周。8 枚・約 1 分"
        case .ring4: return "前後左右だけ。4 枚"
        case .ring8plusHigh: return "1 周と、上から 4 枚。12 枚"
        case .flat1: return "絵・貼り絵などを真上から 1 枚"
        case .free: return "案内なしで何枚でも"
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
        case .ai5:
            return ring(step: 90, elevation: Self.ai5SideElevation, azTol: Self.ai5SideAzimuthTolerance, elTol: Self.ai5SideElevationTolerance)
                + [DirectionTarget.top(elevationDeg: Self.ai5TopElevation, elevationTolerance: Self.ai5TopElevationTolerance)]
        case .flat1:
            return [DirectionTarget.top(elevationDeg: Self.flatTopElevation, elevationTolerance: Self.flatTopElevationTolerance)]
        case .free:
            return []
        }
    }
}
