import Foundation
import simd

/// 撮影方向の当てはめ・撮影済みの方向・次に撮る方向。
public enum Coverage {
    /// 方位角・仰角に当てはまる方向（許容の中で一番近いもの。同じ近さなら一覧の順で先のもの）。
    /// 方位角が分からない（正面が決まっていない）ときは nil。方位を問わない方向（真上）は仰角だけで比べる
    /// （真上では水平の成分がほぼ 0 で、方位が定まらないため）。
    public static func match(azimuthDeg: Double?, elevationDeg: Double?, plan: DirectionPlan) -> DirectionTarget? {
        guard let azimuthDeg, let elevationDeg, azimuthDeg.isFinite, elevationDeg.isFinite else { return nil }
        var best: (target: DirectionTarget, score: Double)?
        for target in plan.targets {
            let dAz = target.azimuthDistance(from: azimuthDeg)
            let dEl = abs(elevationDeg - target.elevationDeg)
            guard dAz <= target.azimuthToleranceDeg, dEl <= target.elevationToleranceDeg else { continue }
            // 許容で割って比べる（方位と仰角で許容が違うため）。
            let score = (target.anyAzimuth ? 0 : dAz / max(target.azimuthToleranceDeg, 1e-6)) + dEl / max(target.elevationToleranceDeg, 1e-6)
            if best == nil || score < best!.score {
                best = (target, score)
            }
        }
        return best?.target
    }

    /// 今の基準で撮影済みの方向。数えるのは、今の有効な基準（`activeReferenceFrame`）で撮った、
    /// `direction.confirmed` が true の写真だけ。基準が無い・無効なら空。
    public static func coveredTargetIds(in session: CaptureSession) -> Set<String> {
        guard let reference = session.activeReferenceFrame else { return [] }
        return coveredTargetIds(photos: session.photos, referenceFrameId: reference.id)
    }

    public static func coveredTargetIds(photos: [Photo], referenceFrameId: String) -> Set<String> {
        Set(photos.compactMap { photo -> String? in
            guard photo.referenceFrameId == referenceFrameId, photo.direction.confirmed else { return nil }
            return photo.direction.targetId
        })
    }

    /// 正面（方位 0°）の方向のうち、仰角が一番近いもの（同じ近さなら一覧の順で先）。正面の 1 枚目の高さの案内に使う。
    /// 方位を問わない方向（真上）は正面にならない。
    public static func frontTarget(plan: DirectionPlan, elevationDeg: Double) -> DirectionTarget? {
        plan.targets
            .filter { !$0.anyAzimuth && Geometry.angleDistance($0.azimuthDeg, 0) < 0.5 }
            .min { abs($0.elevationDeg - elevationDeg) < abs($1.elevationDeg - elevationDeg) }
    }

    /// 次に撮る方向（`CaptureRoute.next`）。仰角の段を低い順に 1 段ずつ、段の中では今の方位から近い順
    /// （`route` に歩いている向きがあれば、その向きで前にある順）。`preferredTargetId`（撮り直し）が未撮影ならそれを優先。
    /// 方位が分からないときは、段の中の一覧の順で最初の未撮影の方向。
    public static func nextTarget(
        plan: DirectionPlan, covered: Set<String>, currentAzimuthDeg: Double?, currentElevationDeg: Double?,
        preferredTargetId: String? = nil, route: CaptureRoute = CaptureRoute()
    ) -> DirectionTarget? {
        route.next(plan: plan, covered: covered, currentAzimuthDeg: currentAzimuthDeg, preferredTargetId: preferredTargetId)?.target
    }
}

/// 撮影画面で使う、今のカメラの方向の情報。
public struct DirectionContext: Equatable, Sendable {
    /// 正面が決まっていないときは nil。
    public var azimuthDeg: Double?
    public var elevationDeg: Double
    public var distanceM: Double
    /// 今の方向に当てはまる方向（未撮影・撮影済みどちらも）。
    public var matchedTarget: DirectionTarget?
    public var matchedTargetCovered: Bool
    public var nextTarget: DirectionTarget?
    public var coveredCount: Int
    public var totalCount: Int
    /// 正面が決まっていないとき、1 枚目（正面）を当てはめる方向：方位 0° の方向のうち、今の仰角に一番近いもの。
    /// 正面が決まっているとき・方位 0° の方向が無いときは nil。
    public var frontTarget: DirectionTarget?
    /// 撮り直しが要る方向（撮ったが、切り抜きがうまくいかなかった）。`covered` には入らない。
    public var retakeTargetIds: Set<String>
    /// 次の方向まで回る角度（度、正 = 右）。歩いている向きに沿う（180° を超えることもある）。nil なら近い向き。
    public var travelDeg: Double?
    /// 次の方向の段に、まだ 1 枚も撮っていない（新しい高さで 1 周を始める）。
    public var nextBandIsNew: Bool
    /// 段が 2 つ以上ある一覧か（案内に高さを入れる）。
    public var hasMultipleBands: Bool
    /// 方向を「正面・右・後ろ・左・真上」の名前で案内する一覧か（ai5）。
    public var usesStepNames: Bool

    public init(
        azimuthDeg: Double?, elevationDeg: Double, distanceM: Double, matchedTarget: DirectionTarget?,
        matchedTargetCovered: Bool, nextTarget: DirectionTarget?, coveredCount: Int, totalCount: Int,
        frontTarget: DirectionTarget? = nil, retakeTargetIds: Set<String> = [], travelDeg: Double? = nil,
        nextBandIsNew: Bool = false, hasMultipleBands: Bool = false, usesStepNames: Bool = false
    ) {
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
        self.distanceM = distanceM
        self.matchedTarget = matchedTarget
        self.matchedTargetCovered = matchedTargetCovered
        self.nextTarget = nextTarget
        self.coveredCount = coveredCount
        self.totalCount = totalCount
        self.frontTarget = frontTarget
        self.retakeTargetIds = retakeTargetIds
        self.travelDeg = travelDeg
        self.nextBandIsNew = nextBandIsNew
        self.hasMultipleBands = hasMultipleBands
        self.usesStepNames = usesStepNames
    }

    /// 正面の 1 枚目の高さ（仰角）が、正面の方向の許容の中か。正面が決まっている・正面の方向が無いときは nil。
    public var frontElevationOK: Bool? {
        guard azimuthDeg == nil, let frontTarget else { return nil }
        return abs(elevationDeg - frontTarget.elevationDeg) <= frontTarget.elevationToleranceDeg
    }

    public var allCovered: Bool { coveredCount >= totalCount }
    public var isOnUncoveredTarget: Bool { matchedTarget != nil && !matchedTargetCovered }

    /// 今のカメラ位置と基準から作る。`route` は撮る順の案内の状態（歩いている向き・今の段）。
    public static func make(
        cameraPosition: SIMD3<Double>, basePoint: SIMD3<Double>, heightM: Double, objectToWorld: simd_double4x4?,
        plan: DirectionPlan, covered: Set<String>, preferredTargetId: String? = nil, retake: Set<String> = [],
        route: CaptureRoute = CaptureRoute()
    ) -> DirectionContext {
        let (elevation, distance) = Geometry.elevationAndDistance(cameraPosition: cameraPosition, basePoint: basePoint, heightM: heightM)
        let azimuth = objectToWorld.map { Geometry.azimuth(cameraPosition: cameraPosition, objectToWorld: $0) }
        let matched = Coverage.match(azimuthDeg: azimuth, elevationDeg: elevation, plan: plan)
        let step = route.next(plan: plan, covered: covered, currentAzimuthDeg: azimuth, preferredTargetId: preferredTargetId)
        let coveredCount = plan.targets.filter { covered.contains($0.id) }.count
        let bands = plan.bands
        let nextBandIsNew = step.map { next in
            bands.first { $0.contains(next.target) }?.targets.allSatisfy { !covered.contains($0.id) } ?? false
        } ?? false
        return DirectionContext(
            azimuthDeg: azimuth, elevationDeg: elevation, distanceM: distance, matchedTarget: matched,
            matchedTargetCovered: matched.map { covered.contains($0.id) } ?? false, nextTarget: step?.target,
            coveredCount: coveredCount, totalCount: plan.targets.count,
            frontTarget: azimuth == nil ? Coverage.frontTarget(plan: plan, elevationDeg: elevation) : nil,
            retakeTargetIds: retake.intersection(plan.targets.map(\.id)).subtracting(covered),
            travelDeg: azimuth == nil ? nil : step?.travelDeg, nextBandIsNew: nextBandIsNew, hasMultipleBands: bands.count > 1,
            usesStepNames: plan.usesStepNames
        )
    }

    /// 次の方向へ動くための案内。
    public var guidance: String {
        guard let azimuthDeg else { return frontGuidance }
        if allCovered { return "すべての方向を撮影しました。追加で撮るか、確認へ進んでください" }
        if isOnUncoveredTarget {
            if let matchedTarget, retakeTargetIds.contains(matchedTarget.id) {
                return "\(Self.label(matchedTarget, named: usesStepNames)) を撮り直します。この方向で撮影できます"
            }
            if usesStepNames, let name = matchedTarget?.stepName { return "\(name)：この方向で撮影できます" }
            return "この方向で撮影できます"
        }
        guard let next = nextTarget else { return "すべての方向を撮影しました" }
        let retakePrefix = retakeTargetIds.contains(next.id)
            ? "\(Self.label(next, named: usesStepNames)) の写真の切り抜きがうまくいきませんでした。もう一度撮ります。" : ""
        let dEl = next.elevationDeg - elevationDeg
        let elevationOff = abs(dEl) > next.elevationToleranceDeg
        // 方位を問わない方向（真上）：高さだけを合わせる（回る向きは言わない）。
        if next.anyAzimuth {
            return retakePrefix + (elevationOff ? Self.elevationMessage(target: next, currentElevationDeg: elevationDeg) : "この方向で撮影できます")
        }
        // 新しい高さの 1 周を始めるときは、まず高さを伝える。
        if elevationOff && nextBandIsNew {
            return retakePrefix + Self.bandStartMessage(next, fromElevationDeg: elevationDeg)
        }
        // 真上の近くでは方位が定まらないので、回る向きより先に高さを戻してもらう。
        if elevationOff && elevationDeg >= Geometry.unstableAzimuthElevationDeg {
            return retakePrefix + Self.elevationMessage(target: next, currentElevationDeg: elevationDeg)
        }
        let dAz = travelDeg ?? next.travel(from: azimuthDeg)
        if abs(dAz) > next.azimuthToleranceDeg {
            let side = dAz > 0 ? "右" : "左"
            let prefix = retakePrefix.isEmpty && matchedTargetCovered ? "この方向は撮影済みです。" : ""
            let stepPrefix = retakePrefix.isEmpty && usesStepNames ? next.stepName.map { "次は\($0)です。" } ?? "" : ""
            return "\(retakePrefix)\(prefix)\(stepPrefix)もう少し\(side)へ回ってください（あと \(Int(abs(dAz).rounded()))°）"
        }
        if elevationOff {
            return retakePrefix + Self.elevationMessage(target: next, currentElevationDeg: elevationDeg)
        }
        return retakePrefix + "この方向で撮影できます"
    }

    /// 高く上から撮る方向（これ以上の仰角）は、スマホを上げて下に傾ける案内にする。
    public static let raisePhoneElevationDeg: Double = 60

    /// 真上（方位を問わない方向）を撮るときの案内。
    public static let topMessage = "最後に真上から撮ります。iPhone を作品の真上に持ち上げて、画面を下に向けてください"

    /// 高さが合っていないときの案内（同じ段の中）。
    static func elevationMessage(target: DirectionTarget, currentElevationDeg: Double) -> String {
        let now = Int(currentElevationDeg.rounded()), goal = DirectionTarget.formatDegrees(target.elevationDeg)
        if target.anyAzimuth {
            let lowest = DirectionTarget.formatDegrees(target.elevationDeg - target.elevationToleranceDeg)
            return topMessage + "（高さ \(now)° → \(lowest)° 以上）"
        }
        let heights = "（高さ \(now)° → \(goal)°）"
        if target.elevationDeg > currentElevationDeg {
            if target.elevationDeg >= raisePhoneElevationDeg {
                return "スマホをもっと高く上げて、下に傾けて作品を見下ろしてください" + heights
            }
            return "もう少し上から見下ろして撮ってください" + heights
        }
        return "もう少し低い位置から撮ってください" + heights
    }

    /// 新しい高さの 1 周を始めるときの案内（例：「次は少し上から（45°）一周します」）。
    public static func bandStartMessage(_ target: DirectionTarget, fromElevationDeg current: Double) -> String {
        if target.anyAzimuth { return topMessage }
        let goal = DirectionTarget.formatDegrees(target.elevationDeg)
        if target.elevationDeg < current {
            return "次は低い位置（\(goal)°）に戻って撮ります。スマホを下げてください"
        }
        if target.elevationDeg >= raisePhoneElevationDeg {
            return "次は高い位置から（\(goal)°）一周します。スマホを頭の高さまで上げ、下に傾けて作品を見下ろしてください"
        }
        return "次は少し上から（\(goal)°）一周します。スマホを少し高く上げて、作品を見下ろしてください"
    }

    /// 正面が決まっていないときの案内（1 枚目の高さも正面の方向に合わせる）。
    private var frontGuidance: String {
        let base = "正面から撮ってください（1 枚目が正面になります）"
        guard let frontTarget, frontElevationOK == false else { return base }
        let now = Int(elevationDeg.rounded()), goal = Int(frontTarget.elevationDeg.rounded())
        let move = elevationDeg > frontTarget.elevationDeg ? "もう少し低い位置から" : "もう少し高い位置から"
        return "正面の 1 枚目は、\(move)撮ってください（高さ \(now)° → \(goal)°）"
    }

    /// 方向の短い名前（「45°」「22.5°」。低い段より上の方向は「90°・高さ 50°」、方位を問わない方向は「真上」）。
    /// `named` なら（ai5）、前後左右も「正面」「右」「後ろ」「左」。
    public static func label(_ target: DirectionTarget, named: Bool = false) -> String {
        if target.anyAzimuth { return target.stepName ?? "上" }
        if named, let name = target.stepName { return name }
        let az = "\(DirectionTarget.formatDegrees(target.azimuthDeg))°"
        return target.elevationDeg > 30 ? az + "・高さ \(DirectionTarget.formatDegrees(target.elevationDeg))°" : az
    }
}
