import ARKit
import CaptureCore
import Foundation

/// メインスレッドで次の処理をする（Swift 5 モードでも MainActor の関数を呼べるように）。
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

extension simd_double4x4 {
    /// 毎フレーム使うので、文字を経由しない速い変換。
    init(fast m: simd_float4x4) {
        self.init(columns: (
            SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1), SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3)
        ))
    }
}

extension simd_double3x3 {
    init(fast m: simd_float3x3) {
        self.init(columns: (SIMD3<Double>(m.columns.0), SIMD3<Double>(m.columns.1), SIMD3<Double>(m.columns.2)))
    }
}

extension ARCamera.TrackingState {
    var core: (TrackingState, TrackingReason?) {
        switch self {
        case .normal: return (.normal, nil)
        case .notAvailable: return (.notAvailable, nil)
        case .limited(let reason):
            switch reason {
            case .initializing: return (.limited, .initializing)
            case .relocalizing: return (.limited, .relocalizing)
            case .excessiveMotion: return (.limited, .excessiveMotion)
            case .insufficientFeatures: return (.limited, .insufficientFeatures)
            @unknown default: return (.limited, nil)
            }
        }
    }
}

/// 撮影前の解析に使う、今の基準の写し（AR のスレッドから読む）。
struct LiveReference: Sendable {
    var state: ReferenceState = .none
    var basePoint: SIMD3<Double>?
    var heightM: Double = 0.15
    var radiusM: Double = 0.08
    var objectToWorld: simd_double4x4?
    var anchorId: UUID?
    var plan: DirectionPlan
    var covered: Set<String> = []
    /// 撮り直しが要る方向（`covered` に入らない）。
    var retake: Set<String> = []
    var preferredTargetId: String?
}

/// 撮影前の映像の解析の結果（メインスレッドへ渡す）。
struct LiveAnalysis: Sendable {
    var sample: LiveFrameSample
    /// 作品の中心（0〜1。ピントと露出の位置に使う）。
    var normalizedCenter: CGPoint?
}

/// ARSession の delegate（専用のキューで受ける）。ARFrame は呼び出しの中でだけ触り、持ち続けない。
/// 必要な値（姿勢・K・縮小した Y）だけを写して、解析は別のキューで行う。前の解析が終わっていなければ捨てる。
final class ARFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    let delegateQueue = DispatchQueue(label: "memoria.ar.delegate", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "memoria.ar.analysis", qos: .userInitiated)
    private let thresholds: QualityThresholds
    /// 解析の間隔（秒）。約 8 Hz。
    private let analysisInterval: TimeInterval = 1.0 / 8.0

    private let lock = NSLock()
    private var _reference: LiveReference
    private var analysisBusy = false
    /// 撮る順の案内の状態（歩いている向き・今の段）。analysisQueue の中だけで使う（解析は 1 つずつ）。
    private var route = CaptureRoute()

    // delegateQueue の中だけで使う。
    private var motion = MotionEstimator()
    private var lastAnalysisTime: TimeInterval = 0
    private var notAvailableSince: TimeInterval?
    private var trackingLostReported = false
    private var lastDriftCheck: TimeInterval = 0
    private var driftReported = false

    var onAnalysis: (@MainActor (LiveAnalysis) -> Void)?
    var onReferenceLost: (@MainActor (InvalidationReason) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    var onInterruptionEnded: (@MainActor () -> Void)?
    var onFailed: (@MainActor (Error) -> Void)?

    init(thresholds: QualityThresholds, plan: DirectionPlan) {
        self.thresholds = thresholds
        _reference = LiveReference(plan: plan)
    }

    var reference: LiveReference {
        get { lock.withLock { _reference } }
        set {
            lock.withLock {
                if newValue.anchorId != _reference.anchorId || newValue.state != _reference.state {
                    // 新しい基準になったら、見失い・ずれの判定をやり直す。
                    delegateQueue.async { [weak self] in
                        self?.trackingLostReported = false
                        self?.driftReported = false
                        self?.notAvailableSince = nil
                    }
                }
                if newValue.anchorId != _reference.anchorId || newValue.plan != _reference.plan || newValue.objectToWorld == nil {
                    // 基準（作品座標）が変わったら、歩いている向き・今の段も数え直す。
                    analysisQueue.async { [weak self] in self?.route.reset() }
                }
                _reference = newValue
            }
        }
    }

    func resetMotion() {
        delegateQueue.async { [weak self] in self?.motion.reset() }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let t = frame.timestamp
        let transform = simd_double4x4(fast: camera.transform)
        motion.update(transform: transform, timestamp: t)
        let (state, reason) = camera.trackingState.core
        let ref = reference
        let hasReference = ref.state != .none

        // 基準があるのに、トラッキングできない状態が続いた → 基準を無効にする。
        if state == .notAvailable {
            if notAvailableSince == nil { notAvailableSince = t }
            if hasReference, !trackingLostReported, let since = notAvailableSince, t - since > thresholds.trackingLostTimeout {
                trackingLostReported = true
                let handler = onReferenceLost
                onMain { handler?(.trackingLost) }
            }
        } else {
            notAvailableSince = nil
        }

        // 基準点のアンカーのずれを 1 秒ごとに見る。
        if hasReference, let anchorId = ref.anchorId, let base = ref.basePoint, !driftReported, t - lastDriftCheck >= 1 {
            lastDriftCheck = t
            if let anchor = frame.anchors.first(where: { $0.identifier == anchorId }) {
                let p = SIMD3<Double>(Double(anchor.transform.columns.3.x), Double(anchor.transform.columns.3.y), Double(anchor.transform.columns.3.z))
                if simd_distance(p, base) > thresholds.anchorDriftLimit {
                    driftReported = true
                    let handler = onReferenceLost
                    onMain { handler?(.anchorDrift) }
                }
            }
        }

        // 解析は約 8 Hz。前の解析が終わっていなければこのフレームは捨てる。
        guard t - lastAnalysisTime >= analysisInterval else { return }
        let busy = lock.withLock { () -> Bool in
            if analysisBusy { return true }
            analysisBusy = true
            return false
        }
        guard !busy else { return }
        lastAnalysisTime = t

        let resolution = camera.imageResolution
        let cameraModel = CameraModel(
            cameraToWorld: transform, intrinsics: simd_double3x3(fast: camera.intrinsics),
            imageWidth: Double(resolution.width), imageHeight: Double(resolution.height)
        )
        var projection: ProjectionResult?
        if hasReference, let base = ref.basePoint {
            let cylinder = ObjectCylinder(basePoint: base, radiusM: ref.radiusM, heightM: ref.heightM)
            projection = Projection.evaluate(cylinder: cylinder, camera: cameraModel, thresholds: thresholds.inFrame)
        }
        let fullWidth = Double(resolution.width), fullHeight = Double(resolution.height)
        let roi = projection?.boundingBox?.expanded(by: 0.05).clamped(width: fullWidth, height: fullHeight)
            ?? PixelRect(x: fullWidth * 0.25, y: fullHeight * 0.25, width: fullWidth * 0.5, height: fullHeight * 0.5)
        // Y 面の縮小した写しだけを持ち出す（フレームとピクセルバッファは持たない）。
        let luma = PixelBufferLuma.downsampledLuma(frame.capturedImage, roi: roi)
        let ambient = frame.lightEstimate.map { Double($0.ambientIntensity) }
        let exposure = camera.exposureDuration > 0 ? camera.exposureDuration : nil
        let angular = motion.angularSpeed, linear = motion.linearSpeed

        analysisQueue.async { [weak self] in
            guard let self else { return }
            let metrics = luma.flatMap { ImageMetrics.computeOnSamples($0) }
            var direction: DirectionContext?
            if hasReference, let base = ref.basePoint {
                let azimuth = ref.objectToWorld.map { Geometry.azimuth(cameraPosition: transform.translation, objectToWorld: $0) }
                self.route.update(azimuthDeg: azimuth, plan: ref.plan, covered: ref.covered)
                direction = DirectionContext.make(
                    cameraPosition: transform.translation, basePoint: base, heightM: ref.heightM,
                    objectToWorld: ref.objectToWorld, plan: ref.plan, covered: ref.covered,
                    preferredTargetId: ref.preferredTargetId, retake: ref.retake, route: self.route
                )
            }
            let sample = LiveFrameSample(
                timestamp: t, trackingState: state, trackingReason: reason, reference: ref.state,
                projection: projection, direction: direction, angularSpeed: angular, linearSpeed: linear,
                meanLuma: metrics?.meanLuma, sharpness: metrics?.laplacianVariance,
                ambientIntensity: ambient, exposureDuration: exposure
            )
            let center = projection?.center.map { CGPoint(x: $0.x / fullWidth, y: $0.y / fullHeight) }
            let analysis = LiveAnalysis(sample: sample, normalizedCenter: center)
            let handler = self.onAnalysis
            onMain { [weak self] in
                handler?(analysis)
                self?.lock.withLock { self?.analysisBusy = false }
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        let handler = onInterrupted
        onMain { handler?() }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        let handler = onInterruptionEnded
        onMain { handler?() }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let handler = onFailed
        onMain { handler?(error) }
    }
}
