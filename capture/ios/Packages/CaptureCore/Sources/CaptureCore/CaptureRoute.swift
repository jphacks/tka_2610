import Foundation

// 撮る順の案内：仰角の段（低い順）を 1 段ずつ、歩いている向きのまま 1 周する。
// 方向が多い（photogrammetry の 48 方向）ときに、近い方向へ行ったり来たり（ジグザグ）しないため。

/// 作品のまわりを回る向き。
public enum WalkDirection: Int, Equatable, Sendable {
    /// 方位が増える向き（正面から見て右へ回り込む。案内は「右へ」）。
    case increasing = 1
    /// 方位が減る向き（案内は「左へ」）。
    case decreasing = -1
}

/// 次に撮る方向と、そこまで回る角度。
public struct RouteStep: Equatable, Sendable {
    public var target: DirectionTarget
    /// 回る角度（度、正 = 方位が増える向き = 右）。歩いている向きに沿って選んだときは、180° を超えることもある。
    public var travelDeg: Double

    public init(target: DirectionTarget, travelDeg: Double) {
        self.target = target
        self.travelDeg = travelDeg
    }
}

/// 撮る順の案内の状態（歩いている向き・今の段）。撮影前の解析 1 回ごとに `update` する。
/// 状態は今の基準の中だけで使う（基準が変わったら `reset`）。
public struct CaptureRoute: Equatable, Sendable {
    /// 歩いている向き。まだ分からなければ nil。
    public private(set) var walk: WalkDirection?
    /// 今の段（仰角）。撮る方向が残っていなければ nil。
    public private(set) var bandElevationDeg: Double?
    private var lastAzimuthDeg: Double?
    /// 同じ向きに回った角度（±`walkDetectionDeg` で止める。逆向きと決めるには 2 倍回る必要がある）。
    private var accumulatedDeg: Double = 0

    /// この角度だけ同じ向きに回ったら、その向きに歩いているとみなす。
    public static let walkDetectionDeg: Double = 10
    /// 1 回でこれより大きく方位が変わったら、飛び（真上を通った・正面が決まった）とみなして数えない。
    public static let maxSampleStepDeg: Double = 45
    /// 歩いている向きの後ろにある方向は、前にある方向までの角度の 1/3 より近いときだけ戻って撮る。
    public static let backtrackRatio: Double = 1.0 / 3.0

    public init() {}

    public mutating func reset() {
        self = CaptureRoute()
    }

    /// 今の方位と撮影済みの方向で、歩いている向きと今の段を更新する。
    /// `elevationDeg` が `Geometry.unstableAzimuthElevationDeg` 以上（ほぼ真上）のときは方位が定まらないので、歩く向きには数えない。
    public mutating func update(azimuthDeg: Double?, elevationDeg: Double? = nil, plan: DirectionPlan, covered: Set<String>) {
        let steady = elevationDeg.map { $0 < Geometry.unstableAzimuthElevationDeg } ?? true
        if let azimuthDeg, azimuthDeg.isFinite, steady {
            if let last = lastAzimuthDeg {
                let d = Geometry.signedAngleDifference(from: last, to: azimuthDeg)
                if abs(d) <= Self.maxSampleStepDeg {
                    accumulatedDeg = min(Self.walkDetectionDeg, max(-Self.walkDetectionDeg, accumulatedDeg + d))
                    if accumulatedDeg >= Self.walkDetectionDeg { walk = .increasing }
                    if accumulatedDeg <= -Self.walkDetectionDeg { walk = .decreasing }
                }
            }
            lastAzimuthDeg = azimuthDeg
        } else {
            lastAzimuthDeg = nil
        }
        bandElevationDeg = Self.activeBand(plan: plan, covered: covered, current: bandElevationDeg)?.elevationDeg
    }

    /// 今の段：今の段に撮る方向が残っていればそのまま。残っていなければ、上の段で残っている一番低い段、
    /// 上に無ければ一番低い段（下の段の撮り直し）。
    public static func activeBand(plan: DirectionPlan, covered: Set<String>, current: Double?) -> ElevationBand? {
        let bands = plan.bands.filter { band in band.targets.contains { !covered.contains($0.id) } }
        if let current, let band = bands.first(where: { ElevationBand.sameElevation($0.elevationDeg, current) }) {
            return band
        }
        if let current, let higher = bands.first(where: { $0.elevationDeg > current }) {
            return higher
        }
        return bands.first
    }

    /// 次に撮る方向。
    /// - `preferredTargetId`（確認画面から選んだ撮り直し）が未撮影ならそれ。
    /// - それ以外は今の段（`bandElevationDeg`、無ければ一番低い段）の中から。歩いている向きが分かっていれば、
    ///   その向きで前にある一番近い方向（許容の中なら少し後ろでもそれ）。後ろの方向は、前の方向よりずっと近いときだけ。
    ///   向きが分からなければ一番近い方向（同じ近さなら一覧の順）。
    /// - 方位が分からないときは、段の中の一覧の順で最初の未撮影の方向。
    public func next(
        plan: DirectionPlan, covered: Set<String>, currentAzimuthDeg: Double?, preferredTargetId: String? = nil
    ) -> RouteStep? {
        let remaining = plan.targets.filter { !covered.contains($0.id) }
        func step(_ target: DirectionTarget) -> RouteStep {
            RouteStep(target: target, travelDeg: currentAzimuthDeg.map { target.travel(from: $0) } ?? 0)
        }
        if let preferredTargetId, let preferred = remaining.first(where: { $0.id == preferredTargetId }) {
            return step(preferred)
        }
        guard let band = Self.activeBand(plan: plan, covered: covered, current: bandElevationDeg) else { return nil }
        let candidates = plan.targets.filter { band.contains($0) && !covered.contains($0.id) }
        // 方位を問わない方向（真上）は、どこからでも撮れるので回らなくてよい。
        if let free = candidates.first(where: \.anyAzimuth) { return RouteStep(target: free, travelDeg: 0) }
        guard let azimuth = currentAzimuthDeg, azimuth.isFinite else { return candidates.first.map(step) }

        guard let walk else {
            // 向きが分からない：一番近い方向（同じ近さなら一覧の順）。
            var best: DirectionTarget?
            var bestDistance = Double.infinity
            for target in candidates {
                let d = target.azimuthDistance(from: azimuth)
                if d < bestDistance - 1e-9 {
                    best = target
                    bestDistance = d
                }
            }
            return best.map(step)
        }

        let sign = Double(walk.rawValue)
        // 前（歩いている向き）へ回る角度 0〜360 と、後ろへ戻る角度。
        var nearBehind: (target: DirectionTarget, back: Double)?
        var ahead: (target: DirectionTarget, forward: Double)?
        var behind: (target: DirectionTarget, back: Double)?
        for target in candidates {
            let forward = Geometry.normalizeDegrees(sign * (target.azimuthDeg - azimuth))
            let back = forward < 1e-9 ? 0 : 360 - forward
            if back > 0, back <= target.azimuthToleranceDeg, nearBehind.map({ back < $0.back - 1e-9 }) ?? true {
                nearBehind = (target, back)
                continue
            }
            if ahead.map({ forward < $0.forward - 1e-9 }) ?? true { ahead = (target, forward) }
            if back > 0, behind.map({ back < $0.back - 1e-9 }) ?? true { behind = (target, back) }
        }
        // 少し通り過ぎただけ（許容の中）なら、そこで撮れる。
        if let nearBehind { return RouteStep(target: nearBehind.target, travelDeg: -sign * nearBehind.back) }
        guard let ahead else { return nil }
        if let behind, behind.back < ahead.forward * Self.backtrackRatio {
            return RouteStep(target: behind.target, travelDeg: -sign * behind.back)
        }
        return RouteStep(target: ahead.target, travelDeg: sign * ahead.forward)
    }
}
