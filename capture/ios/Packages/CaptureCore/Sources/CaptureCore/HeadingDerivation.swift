import Foundation
import simd

// 向きで案内したセッション（`guidance: "heading"`）で、撮ったあとに写真の姿勢から、前の方法で撮る前に決めていたもの
// （作品の中心・作品座標 objectToWorld・写真ごとの方位・仰角・距離）を求める。
// 作品の中心 = 写真の画面の中心の線（十字。ほぼ光軸）に一番近い点（最小二乗）。線がどれだけ外れているか（残差）も記録する。
// 線が足りない・ほぼ平行なときは「分からない」にして、推測した値を入れない。

// MARK: - 線の交わる点

/// 何本かの線に一番近い点（最小二乗）。
public struct AxisSolution: Equatable, Sendable {
    public var point: SIMD3<Double>
    /// Σ(I − d dᵀ) の一番小さい固有値。線どうしの角度が小さい（ほぼ平行）ほど 0 に近い。2 本なら 1 − |cos 角度|。
    public var conditioning: Double
    /// 線ごとの、点からの距離（m）。
    public var misses: [Double]
    /// 線ごとの、カメラから点の足までの距離（m。負ならカメラの後ろ）。
    public var depths: [Double]

    public var rms: Double {
        misses.isEmpty ? 0 : (misses.map { $0 * $0 }.reduce(0, +) / Double(misses.count)).squareRoot()
    }
}

public enum AxisSolver {
    /// 線（向きは長さ 1）に一番近い点。2 本未満・解けないときは nil。
    public static func solve(_ rays: [Ray]) -> AxisSolution? {
        guard rays.count >= 2 else { return nil }
        var a = simd_double3x3(0)
        var b = SIMD3<Double>(0, 0, 0)
        for r in rays {
            let d = r.direction
            let m = simd_double3x3(diagonal: SIMD3(1, 1, 1)) - simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
            a += m
            b += m * r.origin
        }
        let conditioning = smallestEigenvalue(a)
        guard abs(a.determinant) > 1e-12 else { return nil }
        let x = a.inverse * b
        guard x.x.isFinite, x.y.isFinite, x.z.isFinite else { return nil }
        var misses: [Double] = [], depths: [Double] = []
        for r in rays {
            let v = x - r.origin
            let t = simd_dot(v, r.direction)
            depths.append(t)
            misses.append(simd_length(v - t * r.direction))
        }
        return AxisSolution(point: x, conditioning: conditioning, misses: misses, depths: depths)
    }

    /// 対称な 3 × 3 行列の一番小さい固有値（三角関数を使う閉じた式）。
    public static func smallestEigenvalue(_ m: simd_double3x3) -> Double {
        let a00 = m[0][0], a11 = m[1][1], a22 = m[2][2]
        let a01 = m[1][0], a02 = m[2][0], a12 = m[2][1]
        let p1 = a01 * a01 + a02 * a02 + a12 * a12
        if p1 < 1e-18 { return min(a00, a11, a22) }
        let q = (a00 + a11 + a22) / 3
        let p2 = (a00 - q) * (a00 - q) + (a11 - q) * (a11 - q) + (a22 - q) * (a22 - q) + 2 * p1
        let p = (p2 / 6).squareRoot()
        let bm = (1 / p) * (m - simd_double3x3(diagonal: SIMD3(q, q, q)))
        let r = min(1, max(-1, bm.determinant / 2))
        let phi = acos(r) / 3
        // 固有値は q + 2p·cos(φ)、q + 2p·cos(φ + 2π/3)、q + 2p·cos(φ + 4π/3)。一番小さいのは最後。
        return q + 2 * p * cos(phi + 2 * .pi / 3)
    }
}

// MARK: - session.json の `referenceFrames[].heading.derivation`

public enum HeadingDerivationStatus: String, Codable, Sendable {
    /// 線がよく交わった（写真 3 枚以上・残差が小さい）。
    case ok
    /// 求めたが当てにしにくい（写真が 2 枚だけ・残差が大きい）。`reasons` を見る。
    case lowConfidence
    /// 求められない（写真が足りない・線がほぼ平行・点がカメラの後ろ）。中心も座標も null。
    case unknown
}

public enum HeadingDerivationReason: String, Codable, Sendable {
    /// 正面の写真が無い（向きが決まらない）。
    case noFront
    /// 使える写真が 2 枚未満。
    case tooFewPhotos
    /// 写真が 2 枚だけ（線の外れ方を確かめられない）。
    case onlyTwoPhotos
    /// 線がほぼ平行（正面と後ろだけなど）で、交わる点が決まらない。
    case nearParallelAxes
    /// 交わる点がカメラの後ろ（作品を画面の中央に入れていない写真がある）。
    case behindCamera
    /// 線が大きく外れている（作品を十字に合わせられていない写真があるか、位置がずれた）。
    case largeResidual
    /// 1 枚だけ大きく外れていたので、その写真を除いて求めた。
    case outlierExcluded
}

/// objectToWorld の原点の高さ。
public enum HeadingOrigin: String, Codable, Sendable {
    /// 作品を置いた面（机）の高さ。`basePointWorld` と同じ点（前の方法と同じ「底の中心」）。
    case base
    /// 机の高さが分からないので、求めた中心（`centerWorld`）。y = 0 は底ではない。
    case center
}

/// 写真ごとの線の外れ方。
public struct HeadingAxisMiss: Codable, Equatable, Sendable {
    public var photoId: String
    /// 求めた中心から、この写真の画面の中心の線までの距離（m）。
    public var missM: Double
    /// カメラから、中心に一番近い線の上の点までの距離（m）。
    public var distanceM: Double

    public init(photoId: String, missM: Double, distanceM: Double) {
        self.photoId = photoId
        self.missM = missM
        self.distanceM = distanceM
    }
}

/// 撮ったあとに写真から求めた、作品の中心・座標・大きさ（session.json の `referenceFrames[].heading.derivation`）。
public struct HeadingDerivation: Codable, Equatable, Sendable {
    public static let methodName = "opticalAxesLeastSquares"

    /// 求め方：`opticalAxesLeastSquares`（各写真の画面の中心を通る線に一番近い点）。
    public var method: String
    public var status: HeadingDerivationStatus
    public var reasons: [HeadingDerivationReason]
    /// 中心を求めるのに使った写真（方向ごとの代表の写真）。
    public var photoIds: [String]
    /// 大きく外れていたので除いた写真。
    public var excludedPhotoIds: [String]
    /// 作品の中心（世界座標、m）。分からなければ null。
    @NullCodable public var centerWorld: Vector3?
    /// 線の外れ方の二乗平均・最大（m）。分からなければ null。
    @NullCodable public var residualRmsM: Double?
    @NullCodable public var residualMaxM: Double?
    public var perPhoto: [HeadingAxisMiss]
    /// objectToWorld の原点：`base`（机の面）か `center`（机の高さが分からない）。中心が分からなければ null。
    @NullCodable public var origin: HeadingOrigin?
    /// 切り抜きから求めたおおよその大きさ。まだ求めていない（切り抜きを作っている）ときは null。
    @NullCodable public var size: HeadingSizeEstimate?

    public init(
        status: HeadingDerivationStatus, reasons: [HeadingDerivationReason], photoIds: [String], excludedPhotoIds: [String] = [],
        centerWorld: SIMD3<Double>?, residualRmsM: Double?, residualMaxM: Double?, perPhoto: [HeadingAxisMiss],
        origin: HeadingOrigin? = nil, size: HeadingSizeEstimate? = nil
    ) {
        method = Self.methodName
        self.status = status
        self.reasons = reasons
        self.photoIds = photoIds
        self.excludedPhotoIds = excludedPhotoIds
        self.centerWorld = centerWorld.map(Vector3.init)
        self.residualRmsM = residualRmsM
        self.residualMaxM = residualMaxM
        self.perPhoto = perPhoto
        self.origin = origin
        self.size = size
    }

    public static func unknown(_ reason: HeadingDerivationReason, photoIds: [String] = []) -> HeadingDerivation {
        HeadingDerivation(status: .unknown, reasons: [reason], photoIds: photoIds, centerWorld: nil, residualRmsM: nil, residualMaxM: nil, perPhoto: [])
    }
}

/// 作品を置いた面（机）の高さ。アプリが ARKit の平面や特徴点から測って渡す。
public struct SupportSurface: Equatable, Sendable {
    public var heightY: Double
    public var source: BasePointSource
    public var supportPoints: Int?

    public init(heightY: Double, source: BasePointSource, supportPoints: Int? = nil) {
        self.heightY = heightY
        self.source = source
        self.supportPoints = supportPoints
    }
}

// MARK: - 求める

public enum HeadingDeriver {
    /// これ以下の「交わりやすさ」（`AxisSolution.conditioning`）では中心を決めない（2 本なら約 32° 未満の角度）。
    public static let minimumConditioning = 0.15
    /// 中心がカメラからこれより近い（後ろを含む）写真があれば、その写真を除くか、分からないにする（m）。
    public static let minimumDepthM = 0.05
    /// 線の外れ方の二乗平均がこれ以下なら ok（m）。十字の合わせ方の誤差（30 cm で数度）を見込んだ値。
    public static let okResidualRmsM = 0.02
    /// 4 枚以上のとき、1 枚を除いて求めた中心から、除いた写真の線が max(これ, 残りの残差の 3 倍) より外れていれば、その 1 枚を除く。
    public static let outlierMinimumM = 0.03
    /// 机の面が中心よりこれ以上下にあるなら、作品を置いた面ではない（床など）とみなす（m）。
    public static let maximumSurfaceDropM = 0.4

    /// 中心を求めるのに使う写真：基準の方向ごとの代表の写真（追加の写真・方向の外の写真は使わない）。追跡が normal の写真だけ。
    public static func representativePhotos(session: CaptureSession, frameId: String) -> [Photo] {
        let progress = Coverage.progress(in: session, referenceFrameId: frameId)
        let ids = Set(progress.targets.compactMap(\.photoId))
        return session.photos
            .filter { ids.contains($0.photoId) && $0.camera.trackingState == .normal }
            .sorted { $0.sequence < $1.sequence }
    }

    /// 写真の線から中心を求める（中心だけ。原点・大きさは入らない）。
    public static func solveCenter(photos: [(id: String, ray: Ray)]) -> HeadingDerivation {
        var used = photos
        guard used.count >= 2 else { return .unknown(.tooFewPhotos, photoIds: used.map(\.id)) }
        var reasons: [HeadingDerivationReason] = []
        var excluded: [String] = []
        guard var solution = AxisSolver.solve(used.map(\.ray)), solution.conditioning >= minimumConditioning else {
            return .unknown(.nearParallelAxes, photoIds: used.map(\.id))
        }
        // カメラの後ろ（か近すぎる）：4 枚以上なら一番ひどい 1 枚を除いて求め直す。
        if let worst = solution.depths.indices.min(by: { solution.depths[$0] < solution.depths[$1] }), solution.depths[worst] < minimumDepthM {
            guard used.count >= 4 else { return .unknown(.behindCamera, photoIds: used.map(\.id)) }
            excluded.append(used[worst].id)
            used.remove(at: worst)
            reasons.append(.outlierExcluded)
            guard let again = AxisSolver.solve(used.map(\.ray)), again.conditioning >= minimumConditioning else {
                return .unknown(.nearParallelAxes, photoIds: used.map(\.id))
            }
            guard again.depths.allSatisfy({ $0 >= minimumDepthM }) else { return .unknown(.behindCamera, photoIds: used.map(\.id)) }
            solution = again
        } else if used.count >= 4 {
            // 1 枚だけ大きく外れている（作品を十字に合わせていなかった）なら、除いて求め直す。
            // 外れた 1 枚は中心を引っぱるので、1 枚ずつ除いて求め、除いた写真が残りの中心から大きく外れるものを探す。
            var best: (index: Int, solution: AxisSolution, miss: Double)?
            for i in used.indices {
                var trial = used
                trial.remove(at: i)
                guard let again = AxisSolver.solve(trial.map(\.ray)), again.conditioning >= minimumConditioning,
                      again.depths.allSatisfy({ $0 >= minimumDepthM }) else { continue }
                let r = used[i].ray, v = again.point - r.origin
                let miss = simd_length(v - simd_dot(v, r.direction) * r.direction)
                if miss > max(outlierMinimumM, 3 * again.rms), best.map({ again.rms < $0.solution.rms }) ?? true {
                    best = (i, again, miss)
                }
            }
            if let best {
                excluded.append(used[best.index].id)
                used.remove(at: best.index)
                solution = best.solution
                reasons.append(.outlierExcluded)
            }
        }
        if used.count == 2 { reasons.append(.onlyTwoPhotos) }
        let rms = solution.rms
        if rms > okResidualRmsM { reasons.append(.largeResidual) }
        let status: HeadingDerivationStatus = used.count >= 3 && rms <= okResidualRmsM ? .ok : .lowConfidence
        let perPhoto = used.indices.map { HeadingAxisMiss(photoId: used[$0].id, missM: round4(solution.misses[$0]), distanceM: round4(solution.depths[$0])) }
        return HeadingDerivation(
            status: status, reasons: reasons, photoIds: used.map(\.id), excludedPhotoIds: excluded,
            centerWorld: SIMD3(round5(solution.point.x), round5(solution.point.y), round5(solution.point.z)),
            residualRmsM: round4(rms), residualMaxM: round4(solution.misses.max() ?? 0), perPhoto: perPhoto
        )
    }

    /// 作品座標 → 世界。原点は (中心の x, `originY`, 中心の z)、+Y は上、+Z は正面の写真の向きの反対（作品から正面のカメラへ）、+X = Y × Z。
    public static func objectToWorld(center: SIMD3<Double>, frontHeadingDeg: Double, originY: Double) -> simd_double4x4 {
        let a = Geometry.radians(frontHeadingDeg)
        let z = SIMD3(sin(a), 0, cos(a))
        let y = SIMD3<Double>(0, 1, 0)
        let x = simd_cross(y, z)
        return simd_double4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(center.x, originY, center.z, 1)))
    }

    /// 基準 `frameId` の中心・座標・写真ごとの方向を求め直して `session` に書く。中身が変わったら true。
    /// - 中心：方向ごとの代表の写真の画面の中心の線から（`solveCenter`）。
    /// - 原点：机の面 `surface`（無ければ前に測った机の面）が中心の下 `maximumSurfaceDropM` 以内にあればその高さ（`base`）、
    ///   無ければ中心そのもの（`center`。底の高さは分からないとする）。
    /// - 写真ごとの `direction`：方位・仰角・距離を、求めた中心から測った値にする（`targetId` は撮ったときのまま）。
    /// - 大きさ：使う写真か中心が変わったら null に戻す（切り抜きから求め直す。`HeadingSizer`）。
    @discardableResult
    public static func update(session: inout CaptureSession, frameId: String, surface: SupportSurface? = nil) -> Bool {
        guard let index = session.referenceFrames.firstIndex(where: { $0.id == frameId }),
              var heading = session.referenceFrames[index].heading else { return false }
        let original = session
        var frame = session.referenceFrames[index]
        let previous = heading.derivation

        var derivation: HeadingDerivation
        if let frontHeading = heading.frontHeadingDeg {
            let photos = representativePhotos(session: session, frameId: frameId)
            derivation = solveCenter(photos: photos.map { ($0.photoId, HeadingMath.centerRay(of: $0)) })
            if let center = derivation.centerWorld?.simd {
                // 机の面：今回測れなければ、前に測った面（basePointWorld の高さ）を使う。
                let known = surface ?? frame.basePointWorld.flatMap { p in frame.base.map { SupportSurface(heightY: p.simd.y, source: $0.source, supportPoints: $0.supportPoints) } }
                if let s = known, s.heightY < center.y, center.y - s.heightY <= maximumSurfaceDropM {
                    derivation.origin = .base
                    frame.basePointWorld = Vector3(SIMD3(center.x, round5(s.heightY), center.z))
                    frame.base = BasePointInfo(source: s.source, manualOffsetM: 0, supportPoints: s.supportPoints)
                } else {
                    derivation.origin = .center
                    frame.basePointWorld = nil
                    frame.base = nil
                }
                let originY = frame.basePointWorld?.simd.y ?? center.y
                frame.objectToWorld = Matrix4x4(objectToWorld(center: center, frontHeadingDeg: frontHeading, originY: originY))
                // 使う写真と中心が前と同じなら、切り抜きから求めた大きさをそのまま残す。
                if let previous, previous.photoIds == derivation.photoIds, previous.centerWorld == derivation.centerWorld {
                    derivation.size = previous.size
                }
            } else {
                frame.objectToWorld = nil
                frame.basePointWorld = nil
                frame.base = nil
            }
        } else {
            derivation = .unknown(.noFront)
            frame.objectToWorld = nil
        }
        heading.derivation = derivation
        frame.heading = heading
        session.referenceFrames[index] = frame

        // 写真ごとの方向：中心が分かれば中心から、分からなければ撮ったときの向き（向きの差・見下ろす角度）に戻す。
        let center = derivation.centerWorld?.simd
        let objectToWorld = frame.objectToWorld?.simd
        for i in session.photos.indices where session.photos[i].referenceFrameId == frameId {
            var direction = session.photos[i].direction
            if let center, let objectToWorld {
                let position = session.photos[i].camera.cameraToWorld.simd.translation
                let v = position - center
                let horizontal = (v.x * v.x + v.z * v.z).squareRoot()
                direction.azimuthDeg = round3(Geometry.normalizeDegrees(Geometry.azimuth(cameraPosition: position, objectToWorld: objectToWorld)))
                direction.elevationDeg = round3(Geometry.degrees(atan2(v.y, horizontal)))
                direction.distanceM = round4(simd_length(v))
            } else if let info = session.photos[i].heading {
                direction.azimuthDeg = info.relativeHeadingDeg
                direction.elevationDeg = round3(info.pitchDeg)
                direction.distanceM = info.estimatedDistanceM
            }
            session.photos[i].direction = direction
        }
        return session != original
    }

    /// 大きさを書く（中心が同じときだけ。違えば何もしない）。中身が変わったら true。
    @discardableResult
    public static func setSize(_ size: HeadingSizeEstimate, session: inout CaptureSession, frameId: String, forCenter center: Vector3?) -> Bool {
        guard let index = session.referenceFrames.firstIndex(where: { $0.id == frameId }),
              var derivation = session.referenceFrames[index].heading?.derivation,
              derivation.centerWorld == center, derivation.size != size else { return false }
        derivation.size = size
        session.referenceFrames[index].heading?.derivation = derivation
        return true
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
    static func round5(_ v: Double) -> Double { (v * 100000).rounded() / 100000 }
}

// MARK: - 作品を置いた面（机）

public enum SupportSurfaceFinder {
    /// 作品の中心のまわり（水平に `radiusM` 以内）で、中心より下（`HeadingDeriver.maximumSurfaceDropM` 以内）にある
    /// ARKit の特徴点から、作品を置いた面の高さを推定する（前の方法の「特徴点から推定した机の高さ」と同じ度数分布の山）。
    /// 信頼度が中より低ければ nil（推測しない）。
    public static func fromFeaturePoints(_ points: [SIMD3<Double>], center: SIMD3<Double>, radiusM: Double = 0.25) -> SupportSurface? {
        var samples: [(y: Double, weight: Double)] = []
        for p in points where p.y < center.y - 0.003 && p.y > center.y - HeadingDeriver.maximumSurfaceDropM {
            let r = ((p.x - center.x) * (p.x - center.x) + (p.z - center.z) * (p.z - center.z)).squareRoot()
            guard r <= radiusM else { continue }
            samples.append((p.y, 1 - 0.7 * r / radiusM))
        }
        guard let estimate = FeaturePointSurfaceEstimator.estimate(samples: samples).estimate, estimate.level >= .medium else { return nil }
        return SupportSurface(heightY: estimate.heightY, source: .featurePoints, supportPoints: estimate.supportPoints)
    }
}
