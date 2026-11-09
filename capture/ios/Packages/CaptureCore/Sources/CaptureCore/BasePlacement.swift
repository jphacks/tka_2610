import Foundation
import simd

// 作品の底の中心（基準点）を決める計算。ARKit の平面が見つからないときの代わり（特徴点から推定した机の高さ・
// iPhone の下端で測った机の高さ）と、手で合わせた高さのずれもここで扱う。ARKit には触らない（アプリが値を写して渡す）。

/// 基準点をどの方法で求めたか（session.json の `referenceFrames[].base.source`）。
public enum BasePointSource: String, Codable, Sendable, CaseIterable {
    /// 見つかった平面を延ばした面。
    case existingPlaneInfinite
    /// 見つかった平面の形。
    case existingPlaneGeometry
    /// ARKit が推定した平面。
    case estimatedPlane
    /// 特徴点から推定した机の高さと、画面の中心の線の交点。
    case featurePoints
    /// iPhone の下端を机に当てて測った高さと、画面の中心の線の交点。
    case deviceEdge

    /// ARKit の平面（見つかった・推定した）を使ったか。
    public var isARKitPlane: Bool {
        switch self {
        case .existingPlaneInfinite, .existingPlaneGeometry, .estimatedPlane: return true
        case .featurePoints, .deviceEdge: return false
        }
    }
}

/// 基準点の求め方（session.json の `referenceFrames[].base`。後から足した項目で、前の基準には無い）。
public struct BasePointInfo: Codable, Equatable, Sendable {
    public var source: BasePointSource
    /// 手で合わせた高さ（m。上が正）。`basePointWorld` はこれを足したあとの点。
    public var manualOffsetM: Double
    /// 机の高さの推定に使った特徴点の数（`featurePoints` のときだけ。ほかは null）。
    @NullCodable public var supportPoints: Int?

    public init(source: BasePointSource, manualOffsetM: Double = 0, supportPoints: Int? = nil) {
        self.source = source
        self.manualOffsetM = manualOffsetM
        self.supportPoints = supportPoints
    }
}

/// 世界の半直線（画面の点からカメラが見ている向き）。
public struct Ray: Equatable, Sendable {
    public var origin: SIMD3<Double>
    /// 長さ 1。
    public var direction: SIMD3<Double>

    public init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        self.origin = origin
        let length = simd_length(direction)
        self.direction = length > 0 ? direction / length : SIMD3(0, -1, 0)
    }

    public func point(at distance: Double) -> SIMD3<Double> { origin + distance * direction }

    /// 水平の面 y = `height` との交点。下を向いていない・面がカメラより上・`maxDistance` より遠いときは nil。
    public func intersectHorizontalPlane(height: Double, maxDistance: Double = 3) -> SIMD3<Double>? {
        guard direction.y < -1e-6, height < origin.y else { return nil }
        let t = (height - origin.y) / direction.y
        guard t > 0, t <= maxDistance else { return nil }
        var p = point(at: t)
        p.y = height  // 丸めの誤差を残さない
        return p
    }
}

public enum BasePlacement {
    /// 画面の中心の線がこれより水平に近い（傾きが小さい）ときは、高さを変えても線に沿って動かさず、真上・真下に動かす
    /// （線に沿うと、高さを少し変えただけで遠くへ飛ぶため）。sin(12°)。
    public static let minimumRaySlope: Double = 0.2079

    /// 手で合わせた高さのずれ `offsetM` を基準点に足す。
    /// 合わせた（照準を当てた）ときの画面の中心の線の向き `aimDirection` に沿って動かす：
    /// 机の高さの推定がずれていても、照準を当てた作品の足もとの上に基準点が来るように（真上・真下に動かすと、
    /// 高さは合っても、手前・奥にずれたままになる）。線が水平に近いときは真上・真下に動かす。ずれが 0 なら元の点のまま。
    public static func offset(_ base: SIMD3<Double>, byHeight offsetM: Double, alongAimDirection aimDirection: SIMD3<Double>?) -> SIMD3<Double> {
        guard offsetM != 0 else { return base }
        if let aimDirection, simd_length(aimDirection) > 0 {
            let d = simd_normalize(aimDirection)
            if d.y <= -minimumRaySlope {
                var p = base + d * (offsetM / d.y)
                p.y = base.y + offsetM
                return p
            }
        }
        return base + SIMD3(0, offsetM, 0)
    }

    /// これより高ければ、ARKit の平面（床など）より、特徴点の面（机）を使う（m）。
    public static let preferHigherSurfaceMargin: Double = 0.15

    public struct PlaneCandidate: Equatable, Sendable {
        public var point: SIMD3<Double>
        public var source: BasePointSource
        public init(point: SIMD3<Double>, source: BasePointSource) {
            self.point = point
            self.source = source
        }
    }

    public struct Choice: Equatable, Sendable {
        public var point: SIMD3<Double>
        public var source: BasePointSource
        /// `featurePoints` のときの、面を支える特徴点の数。
        public var supportPoints: Int?
        /// `featurePoints` のときの信頼度（0〜1）。
        public var confidence: Double?

        public init(point: SIMD3<Double>, source: BasePointSource, supportPoints: Int? = nil, confidence: Double? = nil) {
            self.point = point
            self.source = source
            self.supportPoints = supportPoints
            self.confidence = confidence
        }
    }

    /// 照準の点を決める。
    /// 1. iPhone の下端で測った高さ（`pinnedHeight`）があれば、それと画面の中心の線の交点。
    /// 2. ARKit の平面に当たっていれば、それ。ただし、特徴点の面（信頼度が中以上）が平面より 15 cm 以上高く、
    ///    線の上で手前にある（例：床の平面だけが見つかっていて、机は見つかっていない）なら、手前の特徴点の面を使う。
    /// 3. 当たっていなければ、特徴点の面と画面の中心の線の交点。
    public static func choose(ray: Ray, plane: PlaneCandidate?, surface: SurfaceEstimate?, pinnedHeight: Double?,
                              maxDistance: Double = 2) -> Choice? {
        if let pinnedHeight {
            guard let p = ray.intersectHorizontalPlane(height: pinnedHeight, maxDistance: maxDistance) else { return nil }
            return Choice(point: p, source: .deviceEdge, supportPoints: nil, confidence: nil)
        }
        let surfaceHit = surface.flatMap { s in
            ray.intersectHorizontalPlane(height: s.heightY, maxDistance: maxDistance).map { (s, $0) }
        }
        if let plane {
            if let (s, p) = surfaceHit, s.level >= .medium,
               s.heightY - plane.point.y >= preferHigherSurfaceMargin,
               simd_distance(p, ray.origin) < simd_distance(plane.point, ray.origin) {
                return Choice(point: p, source: .featurePoints, supportPoints: s.supportPoints, confidence: s.confidence)
            }
            return Choice(point: plane.point, source: plane.source, supportPoints: nil, confidence: nil)
        }
        if let (s, p) = surfaceHit {
            return Choice(point: p, source: .featurePoints, supportPoints: s.supportPoints, confidence: s.confidence)
        }
        return nil
    }
}
