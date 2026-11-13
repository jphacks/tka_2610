import Foundation
import simd

// 向き（heading）で案内する立体の作品の撮影（`guidance: "heading"`）。
// 作品を画面の中央の十字に合わせて正面を手で撮り、そのときの iPhone の向きを覚える。
// 作品が画面の中央にあるまま、向きがちょうど 90°・180°・270° 回った位置が、右・後ろ・左の真横になる
// （作品の位置を知らなくてよい）。高さは見下ろす角度（15° 前後）、真上は 75° 以上。
// ARKit の位置は「その場で回しただけではないか」の確かめにだけ使い、精度には使わない。
// 作品の中心と大きさは、撮ったあとに写真の中心の線（光軸）が交わる点と切り抜きから求める（HeadingDerivation.swift）。

// MARK: - 案内のしかた

/// 立体の作品の撮影の案内のしかた（session.json の `guidance`。後から足した項目）。
public enum CaptureGuidance: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 底の中心に印を合わせ、円柱を合わせてから、作品の位置から方向を案内する（前の方法）。キーが無い・null もこれ。
    case baseCylinder
    /// 作品を画面の中央の十字に合わせ、iPhone の向き（正面から何度回ったか）で案内する。底の中心・円柱は使わない。
    case heading
    /// 案内なしで、自由に何枚でも撮る（後から足した値）。基準もマスクも作らず、向きはカメラの傾きだけを記録する。
    /// 撮る方向の一覧はいつも `free`（方向は 0 個）。FreeCapture.swift。
    case free

    public var id: String { rawValue }

    /// 新しい立体の作品のセッションの既定。
    public static let `default`: CaptureGuidance = .free

    public var displayName: String {
        switch self {
        case .free: return "自由に撮る（標準）"
        case .heading: return "向きで案内"
        case .baseCylinder: return "底の中心と円柱で案内（前の方法）"
        }
    }

    public var summary: String {
        switch self {
        case .free: return "案内なしで、シャッターを押して何枚でも撮ります。正面・横・後ろ・真上があると作りやすくなります"
        case .heading: return "作品を十字に合わせて正面を撮り、まわりを歩くだけ。底の中心・円柱の設定はありません"
        case .baseCylinder: return "先に底の中心と円柱を合わせてから撮ります"
        }
    }

    /// 新しいセッションの案内：平面の作品は無し（null）。自由に撮るはどの一覧でも選べる（一覧は `free` になる。
    /// `newSession`）。向きの案内は AI 用 5 方向（ai5）だけで使え、ほかの一覧（48 方向など）はいつも底の中心と円柱。
    public static func resolve(preferred: CaptureGuidance, plan: DirectionPlan, workKind: WorkKind) -> CaptureGuidance? {
        guard workKind == .object else { return nil }
        if preferred == .free { return .free }
        return preferred == .heading && supportsHeading(plan) ? .heading : .baseCylinder
    }

    /// 新しいセッションの撮る方向の一覧と案内のしかた：平面は flat1（案内なし）、立体で自由に撮るなら `free` の一覧、
    /// それ以外は設定の一覧（`objectPreset`）と `resolve` の案内。
    public static func newSession(workKind: WorkKind, objectPreset: DirectionPlanPreset, preferred: CaptureGuidance) -> (plan: DirectionPlan, guidance: CaptureGuidance?) {
        let plan = DirectionPlanPreset.plan(for: workKind, objectPreset: objectPreset)
        let guidance = resolve(preferred: preferred, plan: plan, workKind: workKind)
        return (guidance == .free ? DirectionPlanPreset.free.plan : plan, guidance)
    }

    /// 向きで案内できる一覧か（ai5 だけ）。
    public static func supportsHeading(_ plan: DirectionPlan) -> Bool {
        plan.id == DirectionPlanPreset.ai5.rawValue
    }
}

extension CaptureSession {
    /// このセッションの案内のしかた。平面の作品は nil、`guidance` の無い（それより前の）立体のセッションは `baseCylinder`。
    public var captureGuidance: CaptureGuidance? {
        isFlat ? nil : (guidance ?? .baseCylinder)
    }

    /// 向きで案内するセッションか。
    public var usesHeadingGuidance: Bool { captureGuidance == .heading }

    /// 案内なしで自由に撮るセッションか（`guidance` が `free`。基準・マスクを使わない）。
    public var usesFreeCapture: Bool { captureGuidance == .free }
}

// MARK: - session.json の項目

/// 基準の、向きの案内の記録（session.json の `referenceFrames[].heading`。向きで案内した基準だけ。ほかは null）。
public struct HeadingReference: Codable, Equatable, Sendable {
    /// 正面の写真の画面の中心の線の水平の向き（度、世界座標。`HeadingMath.headingDeg`）。正面を撮るまでは null。
    @NullCodable public var frontHeadingDeg: Double?
    /// 正面の写真の見下ろす角度（度）。正面を撮るまでは null。
    @NullCodable public var frontPitchDeg: Double?
    /// 撮ったあとに写真の姿勢と切り抜きから求めた、作品の中心・座標・大きさ。まだ求めていなければ null。
    @NullCodable public var derivation: HeadingDerivation?

    public init(frontHeadingDeg: Double? = nil, frontPitchDeg: Double? = nil, derivation: HeadingDerivation? = nil) {
        self.frontHeadingDeg = frontHeadingDeg
        self.frontPitchDeg = frontPitchDeg
        self.derivation = derivation
    }
}

/// 撮る前に確かめた、カメラの位置（その場で回しただけではないか）の結果。
public enum HeadingPositionStatus: String, Codable, Sendable {
    /// 作品のまわりを歩いた位置から、作品を中央に入れている（と ARKit の位置から言える）。
    case ok
    /// その場で iPhone を回しただけ・作品が画面の中央に無い（今の線と前の写真の線が、作品のあるはずの所で交わらない）。
    case notWalkedAround
    /// 確かめていない（正面の写真そのもの・正面がまだ無い・線が水平にならない）。
    case notChecked
}

/// 写真ごとの向きの記録（session.json の `photos[].heading`。向きで案内した写真だけ。ほかは null）。
public struct PhotoHeadingInfo: Codable, Equatable, Sendable {
    /// 正面の写真から、画面の中心の線の水平の向きが回った角度（度、0〜360。右へ回り込むと増える）。正面が無い・真下を向いていれば null。
    @NullCodable public var relativeHeadingDeg: Double?
    /// 見下ろす角度（度。カメラの光軸が水平から下へ傾いた角度、真下が 90）。
    public var pitchDeg: Double
    /// 撮る前の位置の確かめ。
    public var position: HeadingPositionStatus
    /// 撮ったときに推定した、作品（の推定の位置）までの水平の距離（m）。分からなければ null。
    @NullCodable public var estimatedDistanceM: Double?

    public init(relativeHeadingDeg: Double?, pitchDeg: Double, position: HeadingPositionStatus, estimatedDistanceM: Double?) {
        self.relativeHeadingDeg = relativeHeadingDeg
        self.pitchDeg = pitchDeg
        self.position = position
        self.estimatedDistanceM = estimatedDistanceM
    }
}

// MARK: - 角度

public enum HeadingMath {
    /// カメラの前（−Z）の向き（長さ 1）。
    public static func forward(_ cameraToWorld: simd_double4x4) -> SIMD3<Double> {
        let back = SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        let length = simd_length(back)
        return length > 1e-12 ? -back / length : SIMD3(0, 0, -1)
    }

    /// 向き `direction` の水平の向き（度、0〜360）：atan2(−x, −z)。−Z を向くと 0、−X を向くと 90
    /// （+Y まわりに右手で回ると増える。正面から右（+X 側）へ回り込んだカメラの向きが +90 になる）。
    /// ほぼ真上・真下を向いて水平の成分が無いときは nil。
    public static func headingDeg(direction d: SIMD3<Double>) -> Double? {
        let horizontal = (d.x * d.x + d.z * d.z).squareRoot()
        guard horizontal > 1e-6, horizontal.isFinite else { return nil }
        return Geometry.normalizeDegrees(Geometry.degrees(atan2(-d.x, -d.z)))
    }

    public static func headingDeg(cameraToWorld: simd_double4x4) -> Double? {
        headingDeg(direction: forward(cameraToWorld))
    }

    /// 見下ろす角度（度）：光軸が水平から下へ傾いた角度。真下が 90、水平が 0、上向きは負。
    public static func pitchDeg(direction d: SIMD3<Double>) -> Double {
        let n = simd_length(d) > 0 ? simd_normalize(d) : SIMD3(0, 0, -1)
        return Geometry.degrees(asin(min(1, max(-1, -n.y))))
    }

    public static func pitchDeg(cameraToWorld: simd_double4x4) -> Double {
        pitchDeg(direction: forward(cameraToWorld))
    }

    /// 水平の向き（度）から、その向きを向いたときの前の水平の単位ベクトル (x, z)。
    public static func horizontalForward(headingDeg: Double) -> SIMD2<Double> {
        let a = Geometry.radians(headingDeg)
        return SIMD2(-sin(a), -cos(a))
    }

    /// 写真の画面の中心（十字）を通る線（世界座標）。保存した画像の中心のピクセル（幅・高さの半分）を K で戻す。
    public static func centerRay(cameraToWorld: simd_double4x4, intrinsics: simd_double3x3, intrinsicsResolution: PixelSize, imageSize: PixelSize) -> Ray {
        let camera = CameraModel(cameraToWorld: cameraToWorld, intrinsics: intrinsics,
                                 imageWidth: Double(intrinsicsResolution.width), imageHeight: Double(intrinsicsResolution.height))
        return FlatGeometry.ray(throughPixel: SIMD2(Double(imageSize.width) / 2, Double(imageSize.height) / 2), camera: camera, imageSize: imageSize)
    }

    public static func centerRay(of photo: Photo) -> Ray {
        centerRay(cameraToWorld: photo.camera.cameraToWorld.simd, intrinsics: photo.camera.intrinsics.simd,
                  intrinsicsResolution: photo.camera.intrinsicsResolution,
                  imageSize: PixelSize(width: photo.image.width, height: photo.image.height))
    }

    public static func centerRay(of frame: CapturedFrameInfo) -> Ray {
        centerRay(cameraToWorld: frame.cameraToWorld, intrinsics: frame.intrinsics, intrinsicsResolution: frame.intrinsicsResolution, imageSize: frame.imageSize)
    }
}

// MARK: - 位置の確かめ（その場で回しただけではないか）

/// 位置の確かめの結果と、そのとき分かった距離。
public struct HeadingPositionCheck: Equatable, Sendable {
    public var status: HeadingPositionStatus
    /// 今のカメラから作品（の推定の位置）までの水平の距離（m）。分からなければ nil。
    public var distanceM: Double?
    /// 正面の写真のカメラから作品までの水平の距離（m）。分からなければ nil。
    public var frontDistanceM: Double?

    public init(status: HeadingPositionStatus, distanceM: Double? = nil, frontDistanceM: Double? = nil) {
        self.status = status
        self.distanceM = distanceM
        self.frontDistanceM = frontDistanceM
    }

    public static let notChecked = HeadingPositionCheck(status: .notChecked)
    public var isOK: Bool { status == .ok }
}

/// ARKit の位置を、精度ではなく「作品のまわりを歩いたか」の確かめにだけ使う。
/// 向きだけなら、その場で iPhone を回しても条件を満たしてしまう（作品は画面の外）ため。
/// 考え方：今の画面の中心の線と、前の写真（正面など）の線を水平に投影すると、作品のあるはずの所で、
/// 両方のカメラの前のありそうな距離で交わる。その場で回すと、交わる点がカメラのすぐそば（か後ろ）になる。
/// 値はおおまか（実機の調整が要る初期値）。変えるときはここだけ。
public enum HeadingPosition {
    /// 作品までの距離として認める範囲（m、水平）。
    public static let minimumRangeM = 0.08
    public static let maximumRangeM = 2.5
    /// 横・後ろ・真上は、正面を撮った位置からこれ以上（m、水平）動いていること。
    public static let minimumWalkM = 0.10
    /// 正面の線とこれ以上の角度がある線は、2 本の交点で確かめる（後ろは別：ほぼ平行で交点が決まらない）。
    public static let intersectionMinAngleDeg = 35.0
    /// 2 本の交点までの距離の比（今 ÷ 正面）がこの範囲の外なら、交わり方がおかしいとみなす。
    public static let maximumDistanceRatio = 3.0
    /// 推定した作品の位置から、今の線が外れてよい距離：max(これ, 距離 × `missFraction`)。
    public static let minimumMissM = 0.05
    public static let missFraction = 0.3
    /// 後ろ：正面の線から横にずれてよい距離：max(これ, 正面のカメラからの距離 × `backLateralFraction`)。
    public static let backMinimumLateralM = 0.08
    public static let backLateralFraction = 0.2
    /// 真上：作品の推定の位置から水平にずれてよい距離：max(これ, 正面の距離 × `topRadiusFraction`)。
    public static let topMinimumRadiusM = 0.12
    public static let topRadiusFraction = 0.6
    /// これ以上見下ろしていたら、真上の確かめをする（線の水平の向きが定まらない）。
    public static let topPitchDeg = 60.0
    /// 推定に使う線の組の「交わりやすさ」の下限（`AxisSolver.horizontal` の最小固有値。2 本なら 1 − |cos 角度|、35° で 0.18）。
    public static let minimumConditioning = 0.15

    /// 今のカメラの線 `current` を確かめる。
    /// - Parameters:
    ///   - relativeHeadingDeg: 正面からの向きの差（度）。分からなければ nil（確かめない）。
    ///   - front: 正面の写真の画面の中心の線。
    ///   - shots: ほかに撮った写真（正面・横・後ろ・左。真上は除く）の画面の中心の線。作品の位置の推定に使う。
    public static func evaluate(current: Ray, relativeHeadingDeg: Double?, pitchDeg: Double, front: Ray, shots: [Ray]) -> HeadingPositionCheck {
        guard let relativeHeadingDeg, let df = horizontalDirection(front.direction) else { return .notChecked }
        let pf = SIMD2(front.origin.x, front.origin.z), pc = SIMD2(current.origin.x, current.origin.z)
        let walked = simd_distance(pf, pc)
        let estimate = horizontalEstimate([front] + shots)
        let frontDistance = estimate.map { simd_dot($0 - pf, df) }.flatMap { $0 >= minimumRangeM ? $0 : nil }
        let usable = frontDistance != nil ? estimate : nil

        // 真上（ほぼ真下を向いている）：カメラが作品の上にいるか。
        if pitchDeg >= topPitchDeg {
            guard walked >= minimumWalkM || usable != nil else { return HeadingPositionCheck(status: .notWalkedAround) }
            if let e = usable, let fd = frontDistance {
                let ok = simd_distance(pc, e) <= max(topMinimumRadiusM, topRadiusFraction * fd)
                return HeadingPositionCheck(status: ok ? .ok : .notWalkedAround, distanceM: nil, frontDistanceM: fd)
            }
            // 推定が無い：正面の線の上（作品のあるはずの所）の上にいるか。
            let v = pc - pf
            let along = simd_dot(v, df), lateral = abs(cross(df, v))
            let ok = along >= minimumRangeM && along <= maximumRangeM && lateral <= max(topMinimumRadiusM, 0.35 * along)
            return HeadingPositionCheck(status: ok ? .ok : .notWalkedAround)
        }
        guard let dc = horizontalDirection(current.direction) else { return .notChecked }
        let delta = Geometry.angleDistance(relativeHeadingDeg, 0)
        let nearFront = delta < intersectionMinAngleDeg
        if !nearFront && walked < minimumWalkM { return HeadingPositionCheck(status: .notWalkedAround) }

        // 作品の位置の推定があれば、今の線がその近くを通るか。
        if let e = usable, let fd = frontDistance {
            let t = simd_dot(e - pc, dc)
            let miss = abs(cross(dc, e - pc))
            let ok = t >= minimumRangeM && t <= maximumRangeM && miss <= max(minimumMissM, missFraction * t)
            return HeadingPositionCheck(status: ok ? .ok : .notWalkedAround, distanceM: t, frontDistanceM: fd)
        }

        if nearFront {
            // 正面の撮り直し：正面のカメラの近く（線の上）から、作品を越えないこと。
            let v = pc - pf
            let ok = abs(cross(df, v)) <= 0.15 && simd_dot(v, df) <= 0.3
            return HeadingPositionCheck(status: ok ? .ok : .notWalkedAround)
        }
        if delta <= 180 - intersectionMinAngleDeg {
            // 横：2 本の線の交点が、両方のカメラの前のありそうな距離にある。
            guard let (s, t) = intersect(pf, df, pc, dc) else { return HeadingPositionCheck(status: .notWalkedAround) }
            let inRange = s >= minimumRangeM && s <= maximumRangeM && t >= minimumRangeM && t <= maximumRangeM
            let ratio = t / max(s, 1e-9)
            let ok = inRange && ratio <= maximumDistanceRatio && ratio >= 1 / maximumDistanceRatio
            return HeadingPositionCheck(status: ok ? .ok : .notWalkedAround, distanceM: ok ? t : nil, frontDistanceM: ok ? s : nil)
        }
        // 後ろ：正面の線の先（作品の向こう）にいて、線から大きく横にずれていない。
        let v = pc - pf
        let along = simd_dot(v, df), lateral = abs(cross(df, v))
        let ok = along >= 2 * minimumRangeM && along <= 2 * maximumRangeM && lateral <= max(backMinimumLateralM, backLateralFraction * along)
        return HeadingPositionCheck(status: ok ? .ok : .notWalkedAround)
    }

    /// 水平の線（正面・横など）が一番近づく点（水平の位置）。線が 2 本未満・ほぼ平行なら nil。
    public static func horizontalEstimate(_ rays: [Ray]) -> SIMD2<Double>? {
        let lines = rays.compactMap { r -> (SIMD2<Double>, SIMD2<Double>)? in
            horizontalDirection(r.direction).map { (SIMD2(r.origin.x, r.origin.z), $0) }
        }
        guard lines.count >= 2 else { return nil }
        var a = simd_double2x2(0), b = SIMD2<Double>(0, 0)
        for (p, d) in lines {
            let m = simd_double2x2(SIMD2(1 - d.x * d.x, -d.x * d.y), SIMD2(-d.x * d.y, 1 - d.y * d.y))
            a += m
            b += m * p
        }
        // 2 × 2 の対称行列の小さい方の固有値。
        let tr = a[0][0] + a[1][1], det = a.determinant
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        guard tr / 2 - disc >= minimumConditioning, abs(det) > 1e-12 else { return nil }
        return a.inverse * b
    }

    /// 2 本の水平の線 p + s·d と q + t·e の交点の (s, t)。ほぼ平行なら nil。
    static func intersect(_ p: SIMD2<Double>, _ d: SIMD2<Double>, _ q: SIMD2<Double>, _ e: SIMD2<Double>) -> (Double, Double)? {
        let den = cross(d, e)
        guard abs(den) > 1e-6 else { return nil }
        let w = q - p
        return (cross(w, e) / den, cross(w, d) / den)
    }

    /// 向きの水平の成分（長さ 1、(x, z)）。ほぼ真上・真下なら nil。
    static func horizontalDirection(_ v: SIMD3<Double>) -> SIMD2<Double>? {
        let h = SIMD2(v.x, v.z)
        let length = simd_length(h)
        return length > 0.2 ? h / length : nil
    }

    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
}

// MARK: - 撮影画面の案内

/// 作品までの距離の目安（正面を撮ったときと比べる。撮るのは止めない）。
public enum HeadingDistanceHint: String, Equatable, Sendable {
    case closer, farther

    /// 正面との距離の比がこれより大きければ「近づいて」、`fartherRatio` より小さければ「離れて」。
    public static let closerRatio = 1.35
    public static let fartherRatio = 0.7

    public static func make(distanceM: Double?, frontDistanceM: Double?) -> HeadingDistanceHint? {
        guard let d = distanceM, let f = frontDistanceM, f > 0 else { return nil }
        let r = d / f
        if r > closerRatio { return .closer }
        if r < fartherRatio { return .farther }
        return nil
    }

    public var message: String {
        switch self {
        case .closer: return "正面のときより遠いようです。少し近づいてください"
        case .farther: return "正面のときより近いようです。少し離れてください"
        }
    }
}

/// 撮影画面の十字の色。
public enum CrosshairState: Equatable, Sendable {
    /// 向き・高さを合わせている途中（白）。
    case aligning
    /// 向き・高さは合っているが、作品のまわりを歩いていない（橙）。
    case notWalked
    /// ここで撮れる（緑）。
    case ready
}

/// 向きで案内するときの、今のカメラの向きの情報（撮影前の解析 1 回ごと）。
public struct HeadingContext: Equatable, Sendable {
    /// 正面の写真がある（向きの差が測れる）。
    public var hasFront: Bool
    /// 正面からの向きの差（度、0〜360）。正面が無い・真下を向いていれば nil。
    public var relativeHeadingDeg: Double?
    /// 見下ろす角度（度）。
    public var pitchDeg: Double
    /// 向き・高さが許容の中にある方向（位置は問わない）。
    public var matchedTarget: DirectionTarget?
    public var matchedTargetCovered: Bool
    public var nextTarget: DirectionTarget?
    /// 次の方向まで回る角度（度、正 = 右へ回り込む）。
    public var travelDeg: Double?
    /// 位置の確かめ（その場で回しただけではないか）。
    public var position: HeadingPositionCheck
    public var coveredCount: Int
    public var totalCount: Int
    /// 正面がまだ無いとき、1 枚目を当てはめる方向（方位 0°）。
    public var frontTarget: DirectionTarget?
    public var retakeTargetIds: Set<String>

    public init(
        hasFront: Bool, relativeHeadingDeg: Double?, pitchDeg: Double, matchedTarget: DirectionTarget?, matchedTargetCovered: Bool,
        nextTarget: DirectionTarget?, travelDeg: Double?, position: HeadingPositionCheck, coveredCount: Int, totalCount: Int,
        frontTarget: DirectionTarget?, retakeTargetIds: Set<String>
    ) {
        self.hasFront = hasFront
        self.relativeHeadingDeg = relativeHeadingDeg
        self.pitchDeg = pitchDeg
        self.matchedTarget = matchedTarget
        self.matchedTargetCovered = matchedTargetCovered
        self.nextTarget = nextTarget
        self.travelDeg = travelDeg
        self.position = position
        self.coveredCount = coveredCount
        self.totalCount = totalCount
        self.frontTarget = frontTarget
        self.retakeTargetIds = retakeTargetIds
    }

    public var allCovered: Bool { coveredCount >= totalCount }

    /// 1 枚目（正面）の見下ろす角度が、正面の方向の許容の中か。正面が決まっている・正面の方向が無ければ nil。
    public var frontPitchOK: Bool? {
        guard !hasFront, let frontTarget else { return nil }
        return abs(pitchDeg - frontTarget.elevationDeg) <= frontTarget.elevationToleranceDeg
    }

    /// 今の方向で撮れる：まだ撮っていない方向の向き・高さの許容の中で、位置の確かめも ok。
    public var isOnUncoveredTarget: Bool { matchedTarget != nil && !matchedTargetCovered && position.isOK }

    /// 正面からの距離の目安（横・後ろで、位置の確かめが ok のときだけ）。
    public var distanceHint: HeadingDistanceHint? {
        guard position.isOK, let target = matchedTarget, !target.anyAzimuth, Geometry.angleDistance(target.azimuthDeg, 0) > 1 else { return nil }
        return HeadingDistanceHint.make(distanceM: position.distanceM, frontDistanceM: position.frontDistanceM)
    }

    public var crosshair: CrosshairState {
        guard matchedTarget != nil, !matchedTargetCovered else { return .aligning }
        return position.isOK ? .ready : .notWalked
    }

    /// 今の情報を作る。`route` は撮る順の案内の状態（歩いている向き）。方位の代わりに正面からの向きの差を使う。
    public static func make(
        relativeHeadingDeg: Double?, pitchDeg: Double, hasFront: Bool, position: HeadingPositionCheck,
        plan: DirectionPlan, covered: Set<String>, preferredTargetId: String? = nil, retake: Set<String> = [],
        route: CaptureRoute = CaptureRoute()
    ) -> HeadingContext {
        let azimuth = hasFront ? relativeHeadingDeg : nil
        // 真上は向きを問わないので、向きの差が分からなくても（真下を向いていても）高さだけで当てはめる。
        let matched = hasFront
            ? (Coverage.match(azimuthDeg: azimuth ?? 0, elevationDeg: pitchDeg, plan: plan).flatMap { azimuth != nil || $0.anyAzimuth ? $0 : nil })
            : nil
        let step = route.next(plan: plan, covered: covered, currentAzimuthDeg: azimuth, preferredTargetId: preferredTargetId)
        return HeadingContext(
            hasFront: hasFront, relativeHeadingDeg: azimuth, pitchDeg: pitchDeg, matchedTarget: matched,
            matchedTargetCovered: matched.map { covered.contains($0.id) } ?? false,
            nextTarget: hasFront ? step?.target : Coverage.frontTarget(plan: plan, elevationDeg: pitchDeg),
            travelDeg: azimuth == nil ? nil : step?.travelDeg, position: position,
            coveredCount: plan.targets.filter { covered.contains($0.id) }.count, totalCount: plan.targets.count,
            frontTarget: hasFront ? nil : Coverage.frontTarget(plan: plan, elevationDeg: pitchDeg),
            retakeTargetIds: retake.intersection(plan.targets.map(\.id)).subtracting(covered)
        )
    }

    /// 案内の 1 行（短く 1 つの指示）。
    public var guidance: String {
        guard hasFront else {
            if let frontTarget, frontPitchOK == false {
                let now = Int(pitchDeg.rounded()), goal = Int(frontTarget.elevationDeg.rounded())
                let move = pitchDeg > frontTarget.elevationDeg ? "もう少し低い位置から" : "もう少し上から見下ろして"
                return "正面の 1 枚目は、\(move)撮ってください（高さ \(now)° → \(goal)°）"
            }
            return "作品を十字に合わせて、正面から撮ってください（1 枚目が正面）"
        }
        if allCovered { return "すべての方向を撮影しました。追加で撮るか、確認へ進んでください" }
        if let matchedTarget, !matchedTargetCovered {
            let name = matchedTarget.stepName ?? DirectionContext.label(matchedTarget, named: true)
            if !position.isOK {
                return matchedTarget.anyAzimuth
                    ? "作品の真上に移ってください（作品は十字に）"
                    : "その場で回さず、作品のまわりを歩いてください（作品は十字に）"
            }
            if retakeTargetIds.contains(matchedTarget.id) { return "\(name)を撮り直します。ここで撮れます" }
            return "\(name)：ここで撮れます"
        }
        guard let next = nextTarget else { return "すべての方向を撮影しました" }
        let name = next.stepName ?? DirectionContext.label(next, named: true)
        let retakePrefix = retakeTargetIds.contains(next.id) ? "\(name)を撮り直します。" : ""
        let dEl = next.elevationDeg - pitchDeg
        let pitchOff = abs(dEl) > next.elevationToleranceDeg
        if next.anyAzimuth {
            guard pitchOff else { return retakePrefix + "真上：ここで撮れます" }
            let lowest = DirectionTarget.formatDegrees(next.elevationDeg - next.elevationToleranceDeg)
            return retakePrefix + DirectionContext.topMessage + "（高さ \(Int(pitchDeg.rounded()))° → \(lowest)° 以上）"
        }
        // ほぼ真下を向いていると向きが定まらないので、先に高さを戻してもらう。
        if pitchOff && pitchDeg >= HeadingPosition.topPitchDeg {
            return retakePrefix + "iPhone を起こして、作品を横から見てください（高さ \(Int(pitchDeg.rounded()))° → \(DirectionTarget.formatDegrees(next.elevationDeg))°）"
        }
        if let relativeHeadingDeg {
            let d = travelDeg ?? next.travel(from: relativeHeadingDeg)
            if abs(d) > next.azimuthToleranceDeg {
                let side = d > 0 ? "右" : "左"
                let prefix = retakePrefix.isEmpty ? "次は\(name)。" : retakePrefix
                return "\(prefix)\(side)へ回ってください（あと \(Int(abs(d).rounded()))°）"
            }
        }
        if pitchOff {
            let heights = "（高さ \(Int(pitchDeg.rounded()))° → \(DirectionTarget.formatDegrees(next.elevationDeg))°）"
            return retakePrefix + (dEl > 0 ? "もう少し上から見下ろしてください" : "もう少し低い位置から撮ってください") + heights
        }
        return retakePrefix + "\(name)：ここで撮れます"
    }
}
