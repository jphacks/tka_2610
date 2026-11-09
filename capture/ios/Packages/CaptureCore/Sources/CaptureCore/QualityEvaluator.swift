import Foundation

/// 撮影の判定のしきい値。値を変えるときはここだけを変える。実機で調整する前提の初期値。
public struct QualityThresholds: Equatable, Sendable {
    /// 収まりの判定（余白・大きさ）。
    public var inFrame = InFrameThresholds()
    /// これより速く回すと「ゆっくり動かして」（rad/s）。
    public var maxAngularSpeed: Double = 0.5
    /// これより速く動かすと「ゆっくり動かして」（m/s）。
    public var maxLinearSpeed: Double = 0.25
    /// 平均の明るさ（0〜1）がこれより暗いと警告。
    public var minMeanLuma: Double = 0.15
    /// 平均の明るさがこれより明るいと警告（白飛び）。
    public var maxMeanLuma: Double = 0.92
    /// ARKit の ambientIntensity（ルーメン、1000 がふつう）がこれより小さいと警告。
    public var minAmbientIntensity: Double = 250
    /// 露光時間（秒）がこれより長いと、手ぶれしやすいので警告。
    public var maxExposureDuration: Double = 1.0 / 20.0
    /// 撮影前の映像のシャープさ（縮小した Y のラプラシアンの分散）がこれより小さいと警告。
    public var minLiveSharpness: Double = 0.0006
    /// 保存した写真のシャープさ（縮小画像のラプラシアンの分散）がこれより小さいと「ブレ」。
    public var minSavedSharpness: Double = 0.0006
    /// 自動撮影まで、すべて ok が続く回数。
    public var stableSampleCount: Int = 3
    /// 自動撮影まで、すべて ok が続く時間（秒）。
    public var stableDuration: Double = 0.5
    /// 撮影のあと、次の自動撮影までの時間（秒）。
    public var autoCaptureCooldown: Double = 1.2
    /// 方向の多い一覧（`DirectionPlan.isDense`。photogrammetry の 48 方向）での待ち時間（秒）。
    /// 隣の方向が近い（15°）ので、歩きながら次の方向の許容（±7°）を通り過ぎないように短くする。
    /// 安定（`stableSampleCount`・`stableDuration`）は同じだけ求め、撮影は 1 枚ずつ（撮影中は撮らない）。
    public var denseAutoCaptureCooldown: Double = 0.7
    /// 基準があるときにトラッキングできない状態がこれより続くと基準を無効にする（秒）。
    public var trackingLostTimeout: Double = 3.0
    /// 基準点のアンカーがこれより動いたら基準を無効にする（m）。
    public var anchorDriftLimit: Double = 0.03

    public init() {}

    public static let `default` = QualityThresholds()

    /// この一覧で使う、撮影のあと次の自動撮影までの時間（秒）。
    public func autoCaptureCooldown(for plan: DirectionPlan) -> Double {
        plan.isDense ? denseAutoCaptureCooldown : autoCaptureCooldown
    }

    /// この一覧に合わせたしきい値（待ち時間だけ変わる）。
    public func adapted(to plan: DirectionPlan) -> QualityThresholds {
        var t = self
        t.autoCaptureCooldown = autoCaptureCooldown(for: plan)
        return t
    }
}

extension DirectionPlan {
    /// 方向の多い一覧（1 周に 13 方向以上の段がある）。自動撮影の待ち時間を短くする。
    public var isDense: Bool { bands.contains { $0.targets.count > 12 } }
}

public enum CheckKind: String, CaseIterable, Sendable {
    case tracking, inFrame, direction, motion, brightness, sharpness

    public var label: String {
        switch self {
        case .tracking: return "トラッキング"
        case .inFrame: return "収まり"
        case .direction: return "方向"
        case .motion: return "動き"
        case .brightness: return "暗さ"
        case .sharpness: return "ブレ"
        }
    }
}

public struct CheckResult: Equatable, Sendable {
    public var kind: CheckKind
    public var status: CheckStatus
    public var message: String

    public init(kind: CheckKind, status: CheckStatus, message: String) {
        self.kind = kind
        self.status = status
        self.message = message
    }
}

/// 基準の状態（撮影前の判定に使う）。
public enum ReferenceState: Equatable, Sendable {
    /// 基準が無い（設定中を含む）。
    case none
    /// 基準があり、正面がまだ決まっていない（次の写真が正面になる）。
    case awaitingFront
    /// 基準があり、正面も決まっている。
    case ready
}

/// 撮影前の映像 1 枚分の解析結果（ARFrame は持たない）。
public struct LiveFrameSample: Equatable, Sendable {
    public var timestamp: Double
    public var trackingState: TrackingState
    public var trackingReason: TrackingReason?
    public var reference: ReferenceState
    public var projection: ProjectionResult?
    public var direction: DirectionContext?
    public var angularSpeed: Double
    public var linearSpeed: Double
    public var meanLuma: Double?
    public var sharpness: Double?
    public var ambientIntensity: Double?
    public var exposureDuration: Double?
    public var captureInFlight: Bool

    public init(
        timestamp: Double, trackingState: TrackingState, trackingReason: TrackingReason? = nil,
        reference: ReferenceState = .none, projection: ProjectionResult? = nil, direction: DirectionContext? = nil,
        angularSpeed: Double = 0, linearSpeed: Double = 0, meanLuma: Double? = nil, sharpness: Double? = nil,
        ambientIntensity: Double? = nil, exposureDuration: Double? = nil, captureInFlight: Bool = false
    ) {
        self.timestamp = timestamp
        self.trackingState = trackingState
        self.trackingReason = trackingReason
        self.reference = reference
        self.projection = projection
        self.direction = direction
        self.angularSpeed = angularSpeed
        self.linearSpeed = linearSpeed
        self.meanLuma = meanLuma
        self.sharpness = sharpness
        self.ambientIntensity = ambientIntensity
        self.exposureDuration = exposureDuration
        self.captureInFlight = captureInFlight
    }
}

public struct QualityAssessment: Equatable, Sendable {
    public var checks: [CheckResult]
    /// 自動で撮ってよい（すべて ok、未撮影の方向の上、一定時間止まっている、待ち時間の外）。
    public var canAutoCapture: Bool
    /// 手動で撮れる（止めるのはトラッキングできないときと、撮影中のときだけ）。
    public var canManualCapture: Bool
    /// 自動撮影の条件がそろってからの進み具合（0〜1。安定待ちの表示用）。
    public var stabilityProgress: Double
    /// いま一番伝えたい案内。
    public var primaryMessage: String
    /// 自動撮影するときの方向。
    public var autoTargetId: String?

    public init(checks: [CheckResult], canAutoCapture: Bool, canManualCapture: Bool, stabilityProgress: Double, primaryMessage: String, autoTargetId: String?) {
        self.checks = checks
        self.canAutoCapture = canAutoCapture
        self.canManualCapture = canManualCapture
        self.stabilityProgress = stabilityProgress
        self.primaryMessage = primaryMessage
        self.autoTargetId = autoTargetId
    }

    public func check(_ kind: CheckKind) -> CheckResult {
        checks.first { $0.kind == kind } ?? CheckResult(kind: kind, status: .unknown, message: "")
    }

    public func status(_ kind: CheckKind) -> CheckStatus { check(kind).status }

    /// 警告（手動で撮る前に確認を出す項目）。
    public var warnings: [CheckResult] {
        checks.filter { $0.status == .warning || $0.status == .blocked }
    }

    public var hasWarnings: Bool { !warnings.isEmpty }

    /// session.json の `quality.live` にする。
    public func liveRecord(warningsAcknowledged: Bool) -> LiveQualityRecord {
        LiveQualityRecord(
            tracking: status(.tracking), inFrame: status(.inFrame), direction: status(.direction),
            motion: status(.motion), brightness: status(.brightness), sharpness: status(.sharpness),
            warningsAcknowledged: warningsAcknowledged
        )
    }

    public static let initial = QualityAssessment(
        checks: CheckKind.allCases.map { CheckResult(kind: $0, status: .unknown, message: "確認中") },
        canAutoCapture: false, canManualCapture: false, stabilityProgress: 0,
        primaryMessage: "カメラを準備しています", autoTargetId: nil
    )
}

/// 撮影前の判定。入力の並びだけで結果が決まる（時刻は ARFrame の timestamp を使う）。
/// 暗さとブレは警告だけで、撮影を止めない。トラッキングが limited のときは自動撮影だけ止める。
public struct QualityEvaluator: Sendable {
    public var thresholds: QualityThresholds
    private var stableCount = 0
    private var stableSince: Double?
    private var stableTargetId: String?
    private var lastCaptureTimestamp: Double?

    public init(thresholds: QualityThresholds = .default) {
        self.thresholds = thresholds
    }

    /// 撮影が終わった（保存できた・できなかったにかかわらず）。ここから待ち時間を数える。
    public mutating func noteCapture(at timestamp: Double) {
        lastCaptureTimestamp = timestamp
        resetStability()
    }

    public mutating func reset() {
        resetStability()
        lastCaptureTimestamp = nil
    }

    private mutating func resetStability() {
        stableCount = 0
        stableSince = nil
        stableTargetId = nil
    }

    public mutating func evaluate(_ sample: LiveFrameSample) -> QualityAssessment {
        let checks = [
            trackingCheck(sample), inFrameCheck(sample), directionCheck(sample),
            motionCheck(sample), brightnessCheck(sample), sharpnessCheck(sample),
        ]
        let allOK = checks.allSatisfy { $0.status == .ok }
        // 正面を決める 1 枚目は、ユーザーが正面を選んで手で撮る（自動では撮らない）。
        let onUncoveredTarget = sample.reference == .ready && (sample.direction?.isOnUncoveredTarget ?? false)
        let eligible = allOK && onUncoveredTarget && !sample.captureInFlight
        let targetId = eligible ? sample.direction?.matchedTarget?.id : nil

        if eligible {
            if stableTargetId == targetId, stableSince != nil {
                stableCount += 1
            } else {
                stableCount = 1
                stableSince = sample.timestamp
                stableTargetId = targetId
            }
        } else {
            resetStability()
        }

        let elapsed = stableSince.map { sample.timestamp - $0 } ?? 0
        let stable = eligible && stableCount >= thresholds.stableSampleCount && elapsed >= thresholds.stableDuration
        let inCooldown = lastCaptureTimestamp.map { sample.timestamp - $0 < thresholds.autoCaptureCooldown } ?? false
        let canAuto = stable && !inCooldown
        let canManual = sample.trackingState != .notAvailable && !sample.captureInFlight
        let countProgress = Double(stableCount) / Double(max(1, thresholds.stableSampleCount))
        let timeProgress = thresholds.stableDuration > 0 ? elapsed / thresholds.stableDuration : 1
        let progress: Double = eligible ? min(1, min(countProgress, timeProgress)) : 0

        return QualityAssessment(
            checks: checks, canAutoCapture: canAuto, canManualCapture: canManual,
            stabilityProgress: progress, primaryMessage: primaryMessage(checks: checks, sample: sample, eligible: eligible),
            autoTargetId: canAuto ? targetId : nil
        )
    }

    private func primaryMessage(checks: [CheckResult], sample: LiveFrameSample, eligible: Bool) -> String {
        if sample.captureInFlight { return "撮影しています…" }
        let order: [CheckKind] = [.tracking, .inFrame, .motion, .direction, .brightness, .sharpness]
        for kind in order {
            if let check = checks.first(where: { $0.kind == kind }), check.status == .warning || check.status == .blocked {
                return check.message
            }
        }
        if sample.reference == .none { return "作品の底の中心に印を合わせて、基準を設定してください" }
        if eligible { return "そのまま止めてください" }
        return checks.first { $0.kind == .direction }?.message ?? ""
    }

    // MARK: 各項目

    private func trackingCheck(_ s: LiveFrameSample) -> CheckResult {
        switch s.trackingState {
        case .normal:
            return CheckResult(kind: .tracking, status: .ok, message: "位置を追えています")
        case .notAvailable:
            return CheckResult(kind: .tracking, status: .blocked, message: "位置を追えていません。カメラをふさいでいないか確認してください")
        case .limited:
            let message: String
            switch s.trackingReason {
            case .initializing: message = "準備中です。作品のまわりをゆっくり映してください"
            case .relocalizing: message = "位置を探しています。少し前の位置に戻ってください"
            case .excessiveMotion: message = "動きが速すぎます。ゆっくり動かしてください"
            case .insufficientFeatures: message = "模様の少ない場所です。机の上やまわりの物も映してください"
            case nil: message = "位置が不安定です。ゆっくり動かしてください"
            }
            // 手動では撮れる（方向は参考値になる）。自動撮影は止まる（すべて ok ではないため）。
            return CheckResult(kind: .tracking, status: .warning, message: message)
        }
    }

    private func inFrameCheck(_ s: LiveFrameSample) -> CheckResult {
        guard s.reference != .none, let projection = s.projection else {
            return CheckResult(kind: .inFrame, status: .unknown, message: "基準を設定すると収まりを確認します")
        }
        // 高い位置から撮るときは、スマホを下に傾けないと作品が画面に入らない。
        let fromAbove = (s.direction?.elevationDeg ?? 0) >= DirectionContext.raisePhoneElevationDeg
        switch projection.status {
        case .inside:
            return CheckResult(kind: .inFrame, status: .ok, message: "作品が画面に収まっています")
        case .partiallyOutside where fromAbove:
            return CheckResult(kind: .inFrame, status: .warning, message: "作品が画面からはみ出しています。スマホを下に傾けて、作品を画面の中央に入れてください")
        case .behindCamera where fromAbove:
            return CheckResult(kind: .inFrame, status: .warning, message: "作品が画面に入っていません。スマホを下に傾けて、作品を見下ろしてください")
        case .partiallyOutside:
            return CheckResult(kind: .inFrame, status: .warning, message: "作品が画面からはみ出しています。作品を画面の中央に入れるか、少し離れてください")
        case .tooLarge:
            return CheckResult(kind: .inFrame, status: .warning, message: "作品が画面からはみ出しています。少し離れてください")
        case .tooSmall:
            return CheckResult(kind: .inFrame, status: .warning, message: "作品が小さく写っています。もう少し近づいてください")
        case .behindCamera:
            return CheckResult(kind: .inFrame, status: .warning, message: "作品が画面に入っていません。作品にカメラを向けてください")
        }
    }

    private func directionCheck(_ s: LiveFrameSample) -> CheckResult {
        guard s.reference != .none, let direction = s.direction else {
            return CheckResult(kind: .direction, status: .unknown, message: "基準を設定すると撮る方向を案内します")
        }
        if s.reference == .awaitingFront || direction.azimuthDeg == nil {
            // 1 枚目が正面になる。高さも正面の方向（方位 0°）に合っていないと、正面の方向として数えられない（警告だけで撮れる）。
            if direction.frontElevationOK == false {
                return CheckResult(kind: .direction, status: .warning, message: direction.guidance)
            }
            return CheckResult(kind: .direction, status: .ok, message: "正面から撮ってください（1 枚目が正面になります）")
        }
        if direction.allCovered || direction.isOnUncoveredTarget {
            return CheckResult(kind: .direction, status: .ok, message: direction.guidance)
        }
        return CheckResult(kind: .direction, status: .warning, message: direction.guidance)
    }

    private func motionCheck(_ s: LiveFrameSample) -> CheckResult {
        if s.angularSpeed > thresholds.maxAngularSpeed || s.linearSpeed > thresholds.maxLinearSpeed {
            return CheckResult(kind: .motion, status: .warning, message: "ゆっくり動かしてください")
        }
        return CheckResult(kind: .motion, status: .ok, message: "止まっています")
    }

    private func brightnessCheck(_ s: LiveFrameSample) -> CheckResult {
        if let luma = s.meanLuma {
            if luma < thresholds.minMeanLuma {
                return CheckResult(kind: .brightness, status: .warning, message: "暗いです。明るい場所で撮るか、照明をつけてください")
            }
            if luma > thresholds.maxMeanLuma {
                return CheckResult(kind: .brightness, status: .warning, message: "明るすぎます。強い光が直接当たらないようにしてください")
            }
        }
        if let ambient = s.ambientIntensity, ambient < thresholds.minAmbientIntensity {
            return CheckResult(kind: .brightness, status: .warning, message: "部屋が暗いです。照明をつけてください")
        }
        if let exposure = s.exposureDuration, exposure > thresholds.maxExposureDuration {
            return CheckResult(kind: .brightness, status: .warning, message: "暗いのでブレやすくなっています。照明をつけてください")
        }
        guard s.meanLuma != nil else {
            return CheckResult(kind: .brightness, status: .unknown, message: "明るさを確認しています")
        }
        return CheckResult(kind: .brightness, status: .ok, message: "明るさは十分です")
    }

    private func sharpnessCheck(_ s: LiveFrameSample) -> CheckResult {
        guard let sharpness = s.sharpness else {
            return CheckResult(kind: .sharpness, status: .unknown, message: "ピントを確認しています")
        }
        if sharpness < thresholds.minLiveSharpness {
            return CheckResult(kind: .sharpness, status: .warning, message: "ぼやけています。ピントが合うまで少し待つか、ゆっくり動かしてください")
        }
        return CheckResult(kind: .sharpness, status: .ok, message: "くっきり写っています")
    }

    // MARK: 保存した写真

    /// 保存した写真の解析結果を session.json の `quality.saved` にする。
    public func savedQuality(meanLuma: Double, sharpness: Double) -> SavedQuality {
        let brightness: CheckStatus = (meanLuma < thresholds.minMeanLuma || meanLuma > thresholds.maxMeanLuma) ? .warning : .ok
        let blur: CheckStatus = sharpness < thresholds.minSavedSharpness ? .warning : .ok
        return SavedQuality(meanLuma: meanLuma, sharpness: sharpness, brightness: brightness, blur: blur)
    }
}

// MARK: - シャッター

/// シャッターを押したときにすること。
public enum ShutterAction: Equatable, Sendable {
    /// 撮れない（トラッキングできない・撮影中）。
    case unavailable
    /// 基準が無いことを確かめる（「基準を設定する」か「このまま撮る」）。
    case confirmNoReference
    /// 警告を確かめる（「このまま撮る」か「やめる」）。
    case confirmWarnings
    /// そのまま撮る。
    case capture
}

public enum ShutterPolicy {
    /// - Parameters:
    ///   - hasReference: 有効な基準がある（撮影できる状態）。
    ///   - noReferenceAcknowledged: 基準なしで撮ることを、このシャッターで確かめ済み。
    public static func action(
        hasReference: Bool, assessment: QualityAssessment, captureInFlight: Bool, noReferenceAcknowledged: Bool = false
    ) -> ShutterAction {
        guard !captureInFlight, assessment.canManualCapture else { return .unavailable }
        // 基準が無いと方向が記録されず、切り抜きも写真の全体から作るので不正確になる。既定では基準を求める。
        if !hasReference && !noReferenceAcknowledged { return .confirmNoReference }
        return assessment.hasWarnings ? .confirmWarnings : .capture
    }
}
