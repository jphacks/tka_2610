import Foundation
import simd

/// 信頼度の段階（画面に「高・中・低」で出す）。
public enum SurfaceConfidenceLevel: Int, Comparable, Sendable {
    case low = 0, medium, high

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public init(confidence: Double) {
        self = confidence >= 0.7 ? .high : (confidence >= 0.45 ? .medium : .low)
    }

    public var label: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}

/// 特徴点から推定した水平の面（机の上面）。
public struct SurfaceEstimate: Equatable, Sendable {
    /// 面の高さ（世界の y、m）。
    public var heightY: Double
    /// 面を支える（面の高さ ±1 cm にある）特徴点の数。
    public var supportPoints: Int
    /// 面の近く（±1.5 cm）の点の高さのばらつき（重み付きの標準偏差、m）。
    public var spreadM: Double
    /// 0〜1。点の数とばらつきから決める。
    public var confidence: Double

    public init(heightY: Double, supportPoints: Int, spreadM: Double, confidence: Double) {
        self.heightY = heightY
        self.supportPoints = supportPoints
        self.spreadM = spreadM
        self.confidence = confidence
    }

    public var level: SurfaceConfidenceLevel { SurfaceConfidenceLevel(confidence: confidence) }
}

/// 探した結果（面が見つからないときも、進み具合を出すために点の数を返す）。
public struct SurfaceSearch: Equatable, Sendable {
    public var estimate: SurfaceEstimate?
    /// 画面の中心の線のまわり（円錐の中）にあった点の数。
    public var conePoints: Int
    /// 一番よい面を支える点の数（面として認めなかったものも含む）。
    public var bestSupport: Int
    /// 進み具合（0〜1。支える点の数が足りるまで）。
    public var progress: Double

    public static let empty = SurfaceSearch(estimate: nil, conePoints: 0, bestSupport: 0, progress: 0)
}

/// ARKit の特徴点（`ARFrame.rawFeaturePoints`）から、画面の中心の線のまわりの水平の面（机）の高さを推定する。
///
/// - 点は、カメラより下で、画面の中心の線を軸とする円錐の中にあるものだけを使う（線に近いほど重い）。
/// - 最近 `windowSeconds` 秒の点をためる（同じ特徴点は新しい位置で置き換える。数に上限がある）。
/// - y の 5 mm ごとの重み付きの度数分布の山を探し、点が十分あって、ばらつきの小さい山を面とする。
///   山がいくつかあるとき（床と机など）は、一番重い山の 3 割以上ある山のうち一番高いもの（線の上で手前の面）を使う。
///
/// 机の白い部分には点がほとんど出ないので、机の模様・作品の足もと・まわりの物の点を使うことになる。
/// 1 点ごとの誤差は数 mm〜1 cm あるため、たくさんの点の山の位置を使い、それでも数 mm の誤差は残る（手で合わせられる）。
public struct FeaturePointSurfaceEstimator: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// 使う円錐の半分の角度（度）。
        public var coneHalfAngleDeg: Double = 15
        /// ためるときの円錐の半分の角度（度）。照準を少し動かしても、ためた点を使えるように広めにする。
        public var bufferConeHalfAngleDeg: Double = 30
        /// 線からの距離の上限（m）。
        public var maxRadiusM: Double = 0.15
        /// カメラからの距離（線の方向）の範囲（m）。
        public var minRangeM: Double = 0.08
        public var maxRangeM: Double = 1.5
        /// カメラよりこれだけ下の点だけを使う（m）。
        public var minBelowCameraM: Double = 0.03
        public var binSizeM: Double = 0.005
        /// 面の高さを求める幅（± m）。
        public var peakHalfWidthM: Double = 0.010
        /// ばらつきを見る幅（± m）。一様に散らばった点（作品の側面など）は 8.7 mm になり、面と認めない。
        public var spreadHalfWidthM: Double = 0.015
        /// 面として認める、支える点の数の下限。
        public var minSupport: Int = 12
        /// 面として認める、ばらつきの上限（m）。
        public var maxSpreadM: Double = 0.0065
        /// 一番重い山に対して、これ以上の重さの山を候補にする。
        public var competingPeakFraction: Double = 0.3
        /// 山の間の最小の間隔（m）。これより近い山は 1 つにまとめる。
        public var minPeakSeparationM: Double = 0.03
        /// ためる時間（秒）。
        public var windowSeconds: Double = 1.5
        /// ためる点の数の上限。
        public var maxBufferedPoints: Int = 2000

        public init() {}
    }

    public var configuration: Configuration
    private var buffer: [UInt64: (position: SIMD3<Double>, time: Double)] = [:]
    private var nextSyntheticId: UInt64 = 1 << 63

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var bufferedCount: Int { buffer.count }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// 1 フレームの特徴点を足す。`identifiers` は ARKit の特徴点の番号（同じ点は置き換える）。無ければ別々の点とする。
    public mutating func add(points: [SIMD3<Double>], identifiers: [UInt64]?, ray: Ray, timestamp: Double) {
        let c = configuration
        let cosCone = cos(Geometry.radians(c.bufferConeHalfAngleDeg))
        let useIds = identifiers?.count == points.count
        for (i, p) in points.enumerated() {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.y <= ray.origin.y - c.minBelowCameraM else { continue }
            let v = p - ray.origin
            let along = simd_dot(v, ray.direction)
            guard along >= c.minRangeM, along <= c.maxRangeM else { continue }
            let length = simd_length(v)
            guard length > 0, along / length >= cosCone else { continue }
            let id: UInt64
            if useIds, let ids = identifiers {
                id = ids[i]
            } else {
                id = nextSyntheticId
                nextSyntheticId &+= 1
            }
            buffer[id] = (p, timestamp)
        }
        prune(now: timestamp)
    }

    /// 古い点と、上限を超えた点を捨てる。
    public mutating func prune(now: Double) {
        let oldest = now - configuration.windowSeconds
        if buffer.values.contains(where: { $0.time < oldest }) {
            buffer = buffer.filter { $0.value.time >= oldest }
        }
        let excess = buffer.count - configuration.maxBufferedPoints
        if excess > 0 {
            let drop = buffer.sorted { $0.value.time < $1.value.time }.prefix(excess).map(\.key)
            for key in drop { buffer[key] = nil }
        }
    }

    /// 今の画面の中心の線のまわりの面を探す。
    public func search(ray: Ray) -> SurfaceSearch {
        Self.search(points: buffer.values.map(\.position), ray: ray, configuration: configuration)
    }

    /// 点の集まりから、線のまわりの面を探す（ためずに 1 回で）。
    public static func search(points: [SIMD3<Double>], ray: Ray, configuration c: Configuration = Configuration()) -> SurfaceSearch {
        let tanCone = tan(Geometry.radians(c.coneHalfAngleDeg))
        var samples: [(y: Double, weight: Double)] = []
        samples.reserveCapacity(points.count)
        for p in points {
            guard p.y <= ray.origin.y - c.minBelowCameraM else { continue }
            let v = p - ray.origin
            let along = simd_dot(v, ray.direction)
            guard along >= c.minRangeM, along <= c.maxRangeM else { continue }
            let radial = simd_length(v - along * ray.direction)
            let limit = min(c.maxRadiusM, along * tanCone)
            guard radial <= limit else { continue }
            // 線に近いほど重い（線の上で 1、円錐の縁で 0.3）。
            samples.append((p.y, 1 - 0.7 * radial / limit))
        }
        return estimate(samples: samples, configuration: c)
    }

    /// 高さと重みの組から、水平の面を探す。
    public static func estimate(samples: [(y: Double, weight: Double)], configuration c: Configuration = Configuration()) -> SurfaceSearch {
        guard !samples.isEmpty else { return .empty }
        // 5 mm ごとの度数分布（重み付き）。
        var bins: [Int: Double] = [:]
        for s in samples { bins[Int((s.y / c.binSizeM).rounded(.down)), default: 0] += s.weight }
        // [1, 2, 1] でならした値の、まわりより大きい山。
        func smoothed(_ k: Int) -> Double { (bins[k - 1] ?? 0) + 2 * (bins[k] ?? 0) + (bins[k + 1] ?? 0) }
        let keys = Set(bins.keys.flatMap { [$0 - 1, $0, $0 + 1] })
        let separation = max(1, Int((c.minPeakSeparationM / c.binSizeM).rounded()))
        var peaks: [(bin: Int, value: Double)] = keys.map { ($0, smoothed($0)) }.filter { $0.value > 0 }
        peaks.sort { $0.value != $1.value ? $0.value > $1.value : $0.bin > $1.bin }
        var kept: [Int] = []
        for peak in peaks where !kept.contains(where: { abs($0 - peak.bin) < separation }) {
            kept.append(peak.bin)
        }

        struct Candidate {
            var height: Double, mass: Double, support: Int, spread: Double
        }
        var candidates: [Candidate] = []
        for bin in kept {
            var center = (Double(bin) + 0.5) * c.binSizeM
            // 山の中の点の重み付きの平均で、高さを 2 回詰める。
            for _ in 0..<2 {
                var sw = 0.0, swy = 0.0
                for s in samples where abs(s.y - center) <= c.peakHalfWidthM {
                    sw += s.weight
                    swy += s.weight * s.y
                }
                if sw > 0 { center = swy / sw }
            }
            var mass = 0.0, support = 0
            var sw = 0.0, swy = 0.0, swyy = 0.0
            for s in samples {
                let d = abs(s.y - center)
                if d <= c.peakHalfWidthM {
                    mass += s.weight
                    support += 1
                }
                if d <= c.spreadHalfWidthM {
                    sw += s.weight
                    swy += s.weight * s.y
                    swyy += s.weight * s.y * s.y
                }
            }
            let mean = sw > 0 ? swy / sw : center
            let variance = sw > 0 ? max(0, swyy / sw - mean * mean) : 0
            candidates.append(Candidate(height: center, mass: mass, support: support, spread: variance.squareRoot()))
        }
        let bestSupport = candidates.map(\.support).max() ?? 0
        let progress = min(1, Double(bestSupport) / Double(max(1, c.minSupport)))
        let conePoints = samples.count
        let accepted = candidates.filter { $0.support >= c.minSupport && $0.spread <= c.maxSpreadM }
        guard let maxMass = accepted.map(\.mass).max() else {
            return SurfaceSearch(estimate: nil, conePoints: conePoints, bestSupport: bestSupport, progress: min(progress, 0.95))
        }
        // 十分重い山のうち、一番高いもの（下を向いた線の上で、一番手前の面）。
        let chosen = accepted.filter { $0.mass >= c.competingPeakFraction * maxMass }.max { $0.height < $1.height }!
        let supportScore = min(1, Double(chosen.support) / Double(4 * c.minSupport))
        let spreadScore = max(0, 1 - chosen.spread / c.maxSpreadM)
        let confidence = 0.6 * supportScore + 0.4 * spreadScore
        let estimate = SurfaceEstimate(heightY: chosen.height, supportPoints: chosen.support, spreadM: chosen.spread, confidence: confidence)
        return SurfaceSearch(estimate: estimate, conePoints: conePoints, bestSupport: bestSupport, progress: 1)
    }
}
