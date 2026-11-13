import ARKit
import AudioToolbox
import CaptureCore
import SceneKit
import UIKit

/// 撮影画面の AR と撮影の制御（基準の設定・撮影前の判定・captureHighResolutionFrame・保存）。
@MainActor
final class CaptureController: ObservableObject {
    enum Phase: Equatable {
        case starting
        case unsupported(String)
        /// 作品の底の中心を探している（照準を平面に当てる）。
        case placingBase
        /// iPhone の下端を机に当てて、机の高さを測っている（平面が見つからないとき）。
        case measuringEdge
        /// 円柱の高さ・半径を合わせている。
        case adjustingSize
        /// 基準があり、撮影できる。
        case capturing
        case failed(String)
    }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    /// 「iPhone の下端を机に当てて測る」の今の様子。
    enum EdgeStatus: Equatable {
        /// 位置を確かめている（トラッキングが normal でない）。
        case tracking
        /// iPhone が立っていない。
        case notUpright
        /// 立てて止めている（`edgeStillProgress` が 1 になったら測る）。
        case holding
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var hasPlaneHit = false
    /// カメラより下に水平の平面が 1 つ以上見つかっている（底の中心を探している間）。
    @Published private(set) var hasDetectedPlane = false
    /// 照準が当たった方法（当たっていなければ nil）。
    @Published private(set) var reticleSource: BasePointSource?
    /// 特徴点から推定した机の高さの信頼度と、支える点の数（照準が `featurePoints` のとき）。
    @Published private(set) var surfaceLevel: SurfaceConfidenceLevel?
    @Published private(set) var surfaceSupport = 0
    /// 机の高さの推定の進み具合（0〜1。照準が無いときの「机の高さを推定中…」）。
    @Published private(set) var surfaceProgress: Double = 0
    /// 照準が当たらないまま `fallbackDelay` 秒たった（代わりの方法を出す）。
    @Published private(set) var showFallbacks = false
    /// iPhone の下端で測った机の高さを使っている。
    @Published private(set) var hasPinnedHeight = false
    /// 手で合わせた底の高さ（cm。上が正）。照準を当て直しても残す。
    @Published private(set) var heightOffsetCm: Double = 0 { didSet { applyHeightOffset() } }
    /// 「iPhone の下端を机に当てて測る」の様子と、止めている時間の進み具合（0〜1）。
    @Published private(set) var edgeStatus: EdgeStatus = .tracking
    @Published private(set) var edgeStillProgress: Double = 0
    /// 測り始めてから iPhone を十分下げた（机に当てたとみなせる）。下げる前は自動では測らず、「測る」を待つ。
    @Published private(set) var edgeLowered = false
    /// 平面が見つからないまま時間がたった（白い机のこつを出す）。
    @Published private(set) var showPlaneTip = false
    @Published var heightCm: Double = 15 { didSet { updateObjectPreview() } }
    @Published var radiusCm: Double = 8 { didSet { updateObjectPreview() } }
    @Published private(set) var assessment = QualityAssessment.initial
    @Published private(set) var direction: DirectionContext?
    /// 撮影中に撮ったとみなす方向（そろった ＋ 確認中）。次に撮る方向・自動撮影はこれ以外から選ぶ。
    @Published private(set) var covered: Set<String> = []
    /// 今の基準の方向ごとの状態（そろった・確認中・撮り直し・未撮影）。
    @Published private(set) var progress: CoverageProgress
    @Published private(set) var plan: DirectionPlan
    @Published private(set) var captureInFlight = false
    @Published private(set) var photoCount = 0
    /// このセッションで、切り抜きの順番待ち・作成中の写真の数（撮影は止めない）。
    @Published private(set) var maskBacklog = 0
    @Published private(set) var referenceState: ReferenceState = .none
    @Published var banner: Banner?
    @Published var showWarningsSheet = false
    /// 基準が無いときにシャッターを押した（「基準を設定する」か「このまま撮る」）。
    @Published var showNoReferenceDialog = false
    @Published var autoCaptureEnabled: Bool

    static let heightRangeCm: ClosedRange<Double> = 3...60
    /// 切り抜きの処理がこれより多く遅れたら、撮影画面に「切り抜きを処理中（残り n 枚）」を出す（撮影は続ける）。
    static let maskBacklogNoticeCount = 6
    static let radiusRangeCm: ClosedRange<Double> = 2...40
    /// 手で合わせる底の高さの範囲と、1 回で動かす量（cm）。
    static let heightOffsetRangeCm: ClosedRange<Double> = -5...5
    static let heightOffsetStepCm: Double = 0.5

    let arView: ARSCNView
    let sessionId: String
    private let store: SessionStore
    private let thresholds: QualityThresholds
    private let masks: MaskProcessor
    private let onSessionChanged: @MainActor () -> Void
    private let processor: ARFrameProcessor
    private let overlay = SceneOverlay()
    private let focus = FocusController()
    private var evaluator: QualityEvaluator
    private let preferredTargetId: String?

    private var activeReferenceId: String?
    private var basePoint: SIMD3<Double>?
    private var objectToWorld: simd_double4x4?
    private var baseAnchor: ARAnchor?
    private var lastHit: SIMD3<Double>?
    /// 照準の点（手で合わせた高さを足す前）と、そのときの画面の中心の線の向き・求め方。
    private var lastRawHit: SIMD3<Double>?
    private var lastAimDirection: SIMD3<Double>?
    private var lastSupportPoints: Int?
    /// 「ここが底の中心」を押したときの値（手で合わせた高さは、これに足す）。
    private var rawBase: SIMD3<Double>?
    private var aimDirection: SIMD3<Double>?
    private var baseInfo: BasePointInfo?
    /// 特徴点から机の高さを推定する（約 10 Hz で点を足す）。
    private var surfaceEstimator = FeaturePointSurfaceEstimator()
    private var surfaceSearch = SurfaceSearch.empty
    /// iPhone の下端で測った机の高さ（世界の y）。
    private var pinnedHeight: Double?
    private let deviceProfile = DeviceCameraProfile.forModel(DeviceInfoProvider.modelIdentifier)
    private var edgeTimer: Timer?
    private var stillness = StillnessTracker()
    private var edgeSamples: [Double] = []
    /// 測り始めたときのカメラの高さ。
    private var edgeStartCameraY: Double?
    private var reticleTimer: Timer?
    /// 照準の位置（少しならす）。最後に当たった時刻から `reticleHoldSeconds` の間は、外れても残す。
    private var smoothedHit: SIMD3<Float>?
    private var lastHitTime: TimeInterval = 0
    /// 照準が当たっている平面のアンカー（格子を黄色にする）。
    private var targetPlaneId: UUID?
    private var reticleTick = 0
    private var placingStartedAt: TimeInterval = 0
    /// この基準の設定で、平面が一度でも見つかった（見つかったら案内の動画は二度と出さない）。
    private var planeEverFound = false
    /// この基準の設定で、案内の動画を一度出した（自分で閉じたあとに出し直して、ちらつかないように）。
    private var coachingStarted = false
    /// この基準の設定で、案内の動画を閉じた（照準が当たった・代わりの方法を出した）。二度と出さない。
    private var coachingFinished = false
    private let coaching = ARCoachingOverlayView()
    private var lastSampleTimestamp: Double = 0
    private var isRunning = false
    private var wasBackgrounded = false
    private var bannerTask: Task<Void, Never>?
    private var lastMarkerKey = ""
    /// 前に読んだときの撮り直しの方向（新しく撮り直しになった方向だけ知らせる）。
    private var lastRetakeIds: Set<String> = []
    /// 前の解析で案内した段（仰角）。段が変わったら知らせる。
    private var lastGuideBand: Double?
    private let saveQueue = DispatchQueue(label: "memoria.capture.save", qos: .userInitiated)

    init(sessionId: String, preferredTargetId: String?, store: SessionStore, settings: AppSettings, masks: MaskProcessor, onSessionChanged: @escaping @MainActor () -> Void) {
        self.sessionId = sessionId
        self.preferredTargetId = preferredTargetId
        self.store = store
        thresholds = settings.thresholds
        self.masks = masks
        self.onSessionChanged = onSessionChanged
        autoCaptureEnabled = settings.autoCaptureEnabled
        let session = try? store.loadSession(sessionId)
        let initialPlan = session?.directionPlan ?? DirectionPlanPreset.default.plan
        // 方向の多い一覧（photogrammetry）は、自動撮影の待ち時間を短くする（安定は同じだけ求める）。
        evaluator = QualityEvaluator(thresholds: settings.thresholds.adapted(to: initialPlan))
        plan = initialPlan
        progress = .empty(plan: initialPlan)
        photoCount = session?.photos.count ?? 0
        if let object = session?.object {
            heightCm = min(Self.heightRangeCm.upperBound, max(Self.heightRangeCm.lowerBound, object.heightM * 100))
            radiusCm = min(Self.radiusRangeCm.upperBound, max(Self.radiusRangeCm.lowerBound, object.radiusM * 100))
        }
        processor = ARFrameProcessor(thresholds: settings.thresholds, plan: initialPlan)

        arView = ARSCNView(frame: .zero)
        arView.scene = SCNScene()
        arView.automaticallyUpdatesLighting = false
        arView.autoenablesDefaultLighting = false
        arView.session.delegateQueue = processor.delegateQueue
        arView.session.delegate = processor
        overlay.attach(to: arView)
        // 平面を探すときの Apple の案内（動画）。出し入れはこちらで決める。下のボタンは SwiftUI の層で、この上にある。
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = false
        coaching.isUserInteractionEnabled = false
        coaching.frame = arView.bounds
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)

        processor.onAnalysis = { [weak self] in self?.handle($0) }
        processor.onReferenceLost = { [weak self] reason in
            let message = reason == .anchorDrift
                ? "作品の位置がずれました。基準を設定し直してください"
                : "位置を見失いました。基準を設定し直してください"
            self?.invalidateReference(reason, message: message)
        }
        processor.onInterrupted = { [weak self] in
            self?.invalidateReference(.sessionInterrupted, message: "中断されました。基準を設定し直してください")
        }
        processor.onInterruptionEnded = { [weak self] in
            guard let self, self.isRunning else { return }
            self.runSession()
            self.beginPlacingBase()
        }
        processor.onFailed = { [weak self] error in
            guard let self else { return }
            self.invalidateReference(.sessionInterrupted, message: nil)
            self.stopReticle()
            self.stopEdgeTimer()
            self.phase = .failed("AR を開始できませんでした（\(error.localizedDescription)）")
        }
    }

    // MARK: 開始・停止

    func start() {
        guard !isRunning else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            phase = .unsupported("この端末（またはシミュレーター）は AR のワールドトラッキングに対応していません。")
            return
        }
        isRunning = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // 前の AR セッションの基準は、世界座標が違うので使えない。
        invalidateStaleReferences()
        runSession()
        beginPlacingBase()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopReticle()
        stopEdgeTimer()
        invalidateReference(.sessionInterrupted, message: nil)
        arView.session.pause()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// アプリが裏へ回った。
    func didEnterBackground() {
        guard isRunning else { return }
        wasBackgrounded = true
        stopReticle()
        stopEdgeTimer()
        arView.session.pause()
    }

    /// アプリが前に戻った：中断と同じに扱い、基準を設定し直す。
    func didBecomeActive() {
        guard isRunning, wasBackgrounded else { return }
        wasBackgrounded = false
        invalidateReference(.sessionInterrupted, message: activeReferenceId == nil ? nil : "中断されました。基準を設定し直してください")
        runSession()
        beginPlacingBase()
    }

    func retryAfterFailure() {
        guard isRunning else {
            start()
            return
        }
        runSession()
        beginPlacingBase()
    }

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        configuration.isLightEstimationEnabled = true
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        baseAnchor = nil
        // 世界の座標が変わるので、ためた特徴点と測った机の高さは使えない。
        surfaceEstimator.reset()
        pinnedHeight = nil
        hasPinnedHeight = false
        processor.resetMotion()
        focus.reset()
        evaluator.reset()
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func invalidateStaleReferences() {
        _ = try? store.updateSession(sessionId) { s in
            let now = Date()
            for i in s.referenceFrames.indices where s.referenceFrames[i].isValid {
                s.referenceFrames[i].invalidatedAt = now
                s.referenceFrames[i].invalidationReason = .sessionInterrupted
            }
        }
        onSessionChanged()
    }

    // MARK: 基準

    /// 底の中心を探し始める。`reaim` が true（「位置を合わせ直す」・机の高さを測ったあと）なら、
    /// 手で合わせた高さ・測った机の高さ・ためた特徴点を残す。
    func beginPlacingBase(reaim: Bool = false) {
        guard isRunning else { return }
        stopEdgeTimer()
        phase = .placingBase
        basePoint = nil
        rawBase = nil
        aimDirection = nil
        baseInfo = nil
        overlay.hideObject()
        stopReticle()
        if !reaim {
            heightOffsetCm = 0
            pinnedHeight = nil
            hasPinnedHeight = false
            surfaceEstimator.reset()
        }
        surfaceSearch = .empty
        placingStartedAt = CACurrentMediaTime()
        planeEverFound = false
        coachingStarted = false
        coachingFinished = reaim
        reticleTick = 0
        reticleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReticle() }
        }
    }

    private func stopReticle() {
        reticleTimer?.invalidate()
        reticleTimer = nil
        overlay.showReticle(at: nil)
        overlay.hidePlanes()
        setCoaching(active: false)
        smoothedHit = nil
        lastHit = nil
        lastRawHit = nil
        lastAimDirection = nil
        lastSupportPoints = nil
        targetPlaneId = nil
        set(\.hasPlaneHit, false)
        set(\.hasDetectedPlane, false)
        set(\.reticleSource, nil)
        set(\.surfaceLevel, nil)
        set(\.surfaceSupport, 0)
        set(\.surfaceProgress, 0)
        set(\.showFallbacks, false)
        set(\.showPlaneTip, false)
    }

    /// 照準を外れても残す時間（秒）。ちらつかないように。
    private static let reticleHoldSeconds: TimeInterval = 0.5
    /// これより近い位置へ動いたときだけならす（離れたら、すぐそこへ移す）。
    private static let reticleSmoothingRadius: Float = 0.05
    private static let reticleSmoothing: Float = 0.35
    /// 見つかった平面を延ばして使うのは、平面の縁からこの距離まで（机の平面を延ばした面が、机の外の床を指したときに当たらないように）。
    private static let infinitePlaneMargin: Float = 0.6
    /// 平面が見つからないまま、この時間（秒）がたったら白い机のこつを出す。
    private static let planeTipDelay: TimeInterval = 15
    /// 照準が当たらないまま、この時間（秒）がたったら代わりの方法（机の高さの推定の様子・iPhone の下端で測る）を出す。
    private static let fallbackDelay: TimeInterval = 10

    private func updateReticle() {
        guard phase == .placingBase, arView.bounds.width > 0 else { return }
        let now = CACurrentMediaTime()
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // 画面の中心の線（カメラの位置と向き）。
        let ray = arView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .horizontal).map {
            Ray(origin: SIMD3<Double>($0.origin), direction: SIMD3<Double>($0.direction))
        }
        // フレームから要る値だけを写す（フレームは持ち続けない）。特徴点は 2 回に 1 回（約 10 Hz）。
        let readPoints = reticleTick % 2 == 0 && pinnedHeight == nil
        typealias Cloud = (points: [SIMD3<Double>], ids: [UInt64], time: Double)
        guard let snapshot = { () -> (SIMD3<Float>, [ARPlaneAnchor], Cloud?)? in
            guard let frame = arView.session.currentFrame else { return nil }
            let c = frame.camera.transform.columns.3
            let camera = SIMD3<Float>(c.x, c.y, c.z)
            // カメラより下の水平の平面（机・床）。天井や、カメラより上の面は使わない。
            let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
                .filter { $0.alignment == .horizontal && $0.transform.columns.3.y < camera.y }
            var cloud: Cloud?
            if readPoints, let raw = frame.rawFeaturePoints {
                cloud = (raw.points.map { SIMD3<Double>($0) }, raw.identifiers, frame.timestamp)
            }
            return (camera, planes, cloud)
        }() else { return }
        let (camera, planes, cloud) = snapshot
        if !planes.isEmpty { planeEverFound = true }

        if let ray, readPoints {
            if let cloud {
                surfaceEstimator.add(points: cloud.points, identifiers: cloud.ids, ray: ray, timestamp: cloud.time)
            }
            surfaceSearch = surfaceEstimator.search(ray: ray)
        }

        let planeHit = raycastBase(from: center, camera: camera)
        let choice: BasePlacement.Choice?
        if let ray {
            choice = BasePlacement.choose(
                ray: ray,
                plane: planeHit.map { BasePlacement.PlaneCandidate(point: SIMD3<Double>($0.position), source: $0.source) },
                surface: surfaceSearch.estimate, pinnedHeight: pinnedHeight
            )
        } else {
            choice = planeHit.map { BasePlacement.Choice(point: SIMD3<Double>($0.position), source: $0.source, supportPoints: nil, confidence: nil) }
        }

        if let choice {
            let position = SIMD3<Float>(choice.point)
            if let s = smoothedHit, simd_distance(s, position) < Self.reticleSmoothingRadius {
                smoothedHit = s + Self.reticleSmoothing * (position - s)
            } else {
                smoothedHit = position
            }
            lastHitTime = now
            targetPlaneId = choice.source.isARKitPlane ? planeHit?.planeId : nil
            lastAimDirection = ray?.direction
            lastSupportPoints = choice.supportPoints
            set(\.reticleSource, choice.source)
            set(\.surfaceLevel, choice.source == .featurePoints ? choice.confidence.map(SurfaceConfidenceLevel.init(confidence:)) : nil)
            set(\.surfaceSupport, choice.supportPoints ?? 0)
        } else if now - lastHitTime > Self.reticleHoldSeconds {
            smoothedHit = nil
            targetPlaneId = nil
            set(\.reticleSource, nil)
            set(\.surfaceLevel, nil)
            set(\.surfaceSupport, 0)
        }

        if let p = smoothedHit {
            let raw = SIMD3(Double(cleaning: p.x), Double(cleaning: p.y), Double(cleaning: p.z))
            lastRawHit = raw
            // 手で合わせた高さを足す（画面の中心の線に沿って。照準は画面の中心に残る）。
            let shown = BasePlacement.offset(raw, byHeight: heightOffsetCm / 100, alongAimDirection: lastAimDirection)
            lastHit = shown
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(SIMD3<Float>(shown), 1)
            overlay.showReticle(at: transform, style: reticleStyle)
        } else {
            lastHit = nil
            lastRawHit = nil
            overlay.showReticle(at: nil)
        }
        overlay.showPlanes(planes, highlightedId: targetPlaneId, refreshGeometry: reticleTick % 4 == 0)
        reticleTick += 1

        let sinceHit = now - max(placingStartedAt, lastHitTime)
        set(\.hasPlaneHit, lastHit != nil)
        set(\.hasDetectedPlane, !planes.isEmpty)
        set(\.surfaceProgress, (surfaceSearch.progress * 20).rounded() / 20)
        set(\.showFallbacks, lastHit == nil && sinceHit >= Self.fallbackDelay)
        set(\.showPlaneTip, !planeEverFound && now - placingStartedAt >= Self.planeTipDelay)
        // Apple の案内の動画は、はじめに何も当たらないときだけ出す。照準が当たった・代わりの方法を出したら閉じて、二度と出さない。
        if planeEverFound || lastHit != nil || showFallbacks {
            coachingFinished = true
            setCoaching(active: false)
        } else if !coachingStarted && !coachingFinished {
            coachingStarted = true
            setCoaching(active: true)
        }
    }

    /// 照準の見た目（求め方ごとの色）。
    private var reticleStyle: SceneOverlay.ReticleStyle {
        switch reticleSource {
        case .featurePoints?:
            let level = surfaceLevel ?? .low
            return .estimatedHeight(confidence: level == .high ? 1 : (level == .medium ? 0.6 : 0.2))
        case .deviceEdge?: return .deviceEdge
        default: return .plane
        }
    }

    private struct BaseHit {
        let position: SIMD3<Float>
        let source: BasePointSource
        let planeId: UUID?
    }

    /// 画面の点から、作品の底を置く水平の面を探す。
    /// 1. 見つかった平面を延ばした面（作品の下で模様が無くても、机の高さがそのまま分かる）
    /// 2. 見つかった平面の形
    /// 3. 推定した平面
    /// それぞれ、カメラより下で一番近い当たりを使う（床と机が両方あれば、手前の机）。
    /// 当たらないとき・床にしか当たらないときは、特徴点から推定した机の高さを使う（`BasePlacement.choose`）。
    private func raycastBase(from point: CGPoint, camera: SIMD3<Float>) -> BaseHit? {
        let chain: [(ARRaycastQuery.Target, BasePointSource)] = [
            (.existingPlaneInfinite, .existingPlaneInfinite),
            (.existingPlaneGeometry, .existingPlaneGeometry),
            (.estimatedPlane, .estimatedPlane),
        ]
        for (target, source) in chain {
            guard let query = arView.raycastQuery(from: point, allowing: target, alignment: .horizontal) else { continue }
            let hits = arView.session.raycast(query).map { result -> (SIMD3<Float>, ARRaycastResult) in
                let c = result.worldTransform.columns.3
                return (SIMD3(c.x, c.y, c.z), result)
            }
            for (position, result) in hits.sorted(by: { simd_distance($0.0, camera) < simd_distance($1.0, camera) }) {
                guard position.x.isFinite, position.y.isFinite, position.z.isFinite, position.y < camera.y else { continue }
                if target == .existingPlaneInfinite {
                    guard let plane = result.anchor as? ARPlaneAnchor,
                          Self.isNear(plane, worldPoint: position, margin: Self.infinitePlaneMargin) else { continue }
                }
                return BaseHit(position: position, source: source, planeId: (result.anchor as? ARPlaneAnchor)?.identifier)
            }
        }
        return nil
    }

    /// 点が、平面の縁（アンカーの座標で縁の点を囲む四角）から `margin` 以内か。
    private static func isNear(_ plane: ARPlaneAnchor, worldPoint: SIMD3<Float>, margin: Float) -> Bool {
        let boundary = plane.geometry.boundaryVertices
        guard !boundary.isEmpty else { return false }
        let local = simd_mul(simd_inverse(plane.transform), SIMD4(worldPoint, 1))
        var minX = Float.infinity, maxX = -Float.infinity, minZ = Float.infinity, maxZ = -Float.infinity
        for v in boundary {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minZ = min(minZ, v.z); maxZ = max(maxZ, v.z)
        }
        return local.x >= minX - margin && local.x <= maxX + margin && local.z >= minZ - margin && local.z <= maxZ + margin
    }

    /// 平面を探す案内の動画を出す・しまう（同じ状態なら何もしない）。
    private func setCoaching(active: Bool) {
        guard coaching.isActive != active else { return }
        coaching.setActive(active, animated: true)
    }

    /// 値が変わったときだけ書く（毎秒 20 回の更新で、画面を毎回描き直さないように）。
    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<CaptureController, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// 「ここが底の中心」
    func confirmBasePoint() {
        guard phase == .placingBase, let raw = lastRawHit, let source = reticleSource else { return }
        rawBase = raw
        aimDirection = lastAimDirection
        baseInfo = BasePointInfo(source: source, manualOffsetM: 0, supportPoints: source == .featurePoints ? lastSupportPoints : nil)
        stopReticle()
        phase = .adjustingSize
        applyHeightOffset()
    }

    // MARK: 底の高さを手で合わせる

    /// 底の高さを `steps` 段（1 段 0.5 cm）上げる・下げる。
    func nudgeHeight(steps: Int) {
        let value = heightOffsetCm + Double(steps) * Self.heightOffsetStepCm
        let clamped = min(Self.heightOffsetRangeCm.upperBound, max(Self.heightOffsetRangeCm.lowerBound, value))
        heightOffsetCm = (clamped * 10).rounded() / 10
    }

    func resetHeightOffset() {
        heightOffsetCm = 0
    }

    /// 手で合わせた高さを基準点に足す（「ここが底の中心」を押したときの画面の中心の線に沿って。線が水平に近ければ真上・真下）。
    private func applyHeightOffset() {
        guard phase == .adjustingSize, let rawBase else { return }
        basePoint = BasePlacement.offset(rawBase, byHeight: heightOffsetCm / 100, alongAimDirection: aimDirection)
        updateObjectPreview()
    }

    /// 「位置を合わせ直す」：手で合わせた高さ・測った机の高さを残したまま、照準を当て直す。
    func reaimBase() {
        beginPlacingBase(reaim: true)
    }

    // MARK: iPhone の下端を机に当てて測る

    /// 動かさずにこの時間（秒）持っていたら測る。
    private static let edgeHoldSeconds: Double = 1.0
    /// 測り始めてから、カメラがこれだけ下がったら（m）、机に当てたとみなして自動で測る。
    /// 空中で立てて止めただけで測ってしまわないように（下げていなければ「測る」を押して測る）。
    private static let edgeMinimumDescentM: Double = 0.05

    func beginEdgeMeasurement() {
        guard isRunning, phase == .placingBase || phase == .adjustingSize else { return }
        stopReticle()
        overlay.hideObject()
        phase = .measuringEdge
        stillness.reset()
        edgeSamples = []
        edgeStartCameraY = nil
        edgeLowered = false
        edgeStatus = .tracking
        edgeStillProgress = 0
        edgeTimer?.invalidate()
        edgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateEdgeMeasurement() }
        }
    }

    private func stopEdgeTimer() {
        edgeTimer?.invalidate()
        edgeTimer = nil
    }

    private func updateEdgeMeasurement() {
        guard phase == .measuringEdge, let frame = arView.session.currentFrame else { return }
        let pose = simd_double4x4(fast: frame.camera.transform)
        let timestamp = frame.timestamp
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        guard trackingNormal else {
            stillness.reset()
            edgeSamples = []
            set(\.edgeStatus, .tracking)
            set(\.edgeStillProgress, 0)
            return
        }
        if edgeStartCameraY == nil { edgeStartCameraY = pose.translation.y }
        if let start = edgeStartCameraY, start - pose.translation.y >= Self.edgeMinimumDescentM {
            set(\.edgeLowered, true)
        }
        guard DeviceEdgeMeasurement.isUpright(cameraToWorld: pose) else {
            stillness.reset()
            edgeSamples = []
            set(\.edgeStatus, .notUpright)
            set(\.edgeStillProgress, 0)
            return
        }
        let still = stillness.update(transform: pose, timestamp: timestamp)
        if still == 0 { edgeSamples = [] }
        edgeSamples.append(DeviceEdgeMeasurement.tableHeight(cameraToWorld: pose, profile: deviceProfile))
        set(\.edgeStatus, .holding)
        set(\.edgeStillProgress, (min(1, still / Self.edgeHoldSeconds) * 10).rounded() / 10)
        if edgeLowered, still >= Self.edgeHoldSeconds, let height = edgeSamples.median {
            finishEdgeMeasurement(height: height)
        }
    }

    /// 「測る」：立てていてトラッキングが normal なら、すぐ測る（止めていた間の中央値）。
    func measureEdgeNow() {
        guard phase == .measuringEdge, edgeStatus == .holding, let height = edgeSamples.median else { return }
        finishEdgeMeasurement(height: height)
    }

    var canMeasureEdgeNow: Bool { phase == .measuringEdge && edgeStatus == .holding }

    func cancelEdgeMeasurement() {
        guard phase == .measuringEdge else { return }
        beginPlacingBase(reaim: true)
    }

    private func finishEdgeMeasurement(height: Double) {
        stopEdgeTimer()
        pinnedHeight = height
        hasPinnedHeight = true
        heightOffsetCm = 0
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showBanner(deviceProfile.isKnownModel
                   ? "机の高さを測りました。少し離れて、印を作品の底の中心に合わせてください"
                   : "机の高さを測りました（この機種はおおよそ）。少し離れて、印を作品の底の中心に合わせてください",
                   isError: false)
        beginPlacingBase(reaim: true)
    }

    /// 測った机の高さをやめて、自動（平面・特徴点）に戻す。
    func clearPinnedHeight() {
        pinnedHeight = nil
        hasPinnedHeight = false
        smoothedHit = nil
    }

    /// 特徴点でためた机の高さを捨てて、推定し直す。
    func restartSurfaceEstimate() {
        surfaceEstimator.reset()
        surfaceSearch = .empty
        smoothedHit = nil
    }

    private func updateObjectPreview() {
        guard phase == .adjustingSize || phase == .capturing else { return }
        overlay.showObject(base: basePoint, radiusM: radiusCm / 100, heightM: heightCm / 100)
    }

    /// 「基準を確定」：基準を記録し、基準点にアンカーを置く。正面は次の確定した写真で決まる。
    func confirmReference() {
        guard phase == .adjustingSize, let base = basePoint else { return }
        let heightM = (heightCm * 10).rounded() / 1000, radiusM = (radiusCm * 10).rounded() / 1000
        // 基準点の求め方と、手で合わせた高さ（mm に丸める）。basePointWorld は高さを足したあとの点。
        var info = baseInfo ?? BasePointInfo(source: .estimatedPlane)
        info.manualOffsetM = (heightOffsetCm * 10).rounded() / 1000
        let session: CaptureSession
        do {
            session = try store.updateSession(sessionId) { s in
                let now = Date()
                for i in s.referenceFrames.indices where s.referenceFrames[i].isValid {
                    s.referenceFrames[i].invalidatedAt = now
                    s.referenceFrames[i].invalidationReason = .userReset
                }
                // 大きさは基準ごとに残す（前の基準の写真は、前の大きさで切り抜き・確かめをする）。
                // セッションの object は「最後に設定した大きさ」として前の版のために残す。
                let size = ObjectSize(heightM: heightM, radiusM: radiusM)
                s.referenceFrames.append(ReferenceFrame(id: s.nextReferenceFrameId, createdAt: now, basePointWorld: base, object: size, base: info))
                s.object = size
            }
        } catch {
            showBanner("基準を保存できませんでした（\(error.localizedDescription)）", isError: true)
            return
        }
        activeReferenceId = session.referenceFrames.last?.id
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(Float(base.x), Float(base.y), Float(base.z), 1)
        let anchor = ARAnchor(name: "memoria-base", transform: transform)
        arView.session.add(anchor: anchor)
        baseAnchor = anchor
        objectToWorld = nil
        referenceState = .awaitingFront
        phase = .capturing
        evaluator.reset()
        onSessionChanged()
        refreshFromStore()
        updateObjectPreview()
    }

    /// 「基準をやり直す」（作品を動かしたときも）。
    func resetReference() {
        invalidateReference(.userReset, message: nil)
        beginPlacingBase()
    }

    /// 今の基準を無効にする。写真は残るが、撮影済みの方向は数えなくなる。
    private func invalidateReference(_ reason: InvalidationReason, message: String?) {
        if let id = activeReferenceId {
            _ = try? store.updateSession(sessionId) { s in
                if let i = s.referenceFrames.firstIndex(where: { $0.id == id }), s.referenceFrames[i].isValid {
                    s.referenceFrames[i].invalidatedAt = Date()
                    s.referenceFrames[i].invalidationReason = reason
                }
            }
            onSessionChanged()
        }
        let hadReference = activeReferenceId != nil
        activeReferenceId = nil
        objectToWorld = nil
        referenceState = .none
        covered = []
        progress = .empty(plan: plan)
        lastRetakeIds = []
        lastGuideBand = nil
        direction = nil
        if let anchor = baseAnchor { arView.session.remove(anchor: anchor) }
        baseAnchor = nil
        overlay.hideObject()
        pushReference()
        if let message, hadReference || reason == .sessionInterrupted { showBanner(message, isError: true) }
        if isRunning, phase == .capturing || phase == .adjustingSize {
            beginPlacingBase()
        }
    }

    /// セッションが変わった（マスクができた・確認画面で変えたなど）。撮影済みの方向を読み直す。
    func sessionDidChange() {
        guard isRunning, !captureInFlight else { return }
        refreshFromStore()
    }

    /// 保存した中身から、撮影済みの方向・正面・枚数を読み直す。
    /// 方向は、マスクが使える写真があって「そろった」、マスクを作っている間は「確認中」（撮ったとみなす）、
    /// マスクがうまくいかなければ「撮り直し」（撮っていないとみなす → 自動撮影がまた狙う）。
    private func refreshFromStore() {
        guard let session = try? store.loadSession(sessionId) else { return }
        photoCount = session.photos.count
        plan = session.directionPlan
        let pendingMasks = masks.pendingPhotoIds()
        maskBacklog = session.photos.filter { pendingMasks.contains($0.photoId) || $0.mask.status == .processing }.count
        if let id = activeReferenceId, let reference = session.referenceFrame(id: id), reference.isValid {
            objectToWorld = reference.objectToWorld?.simd
            referenceState = objectToWorld == nil ? .awaitingFront : .ready
            progress = Coverage.progress(in: session, referenceFrameId: id)
        } else {
            progress = .empty(plan: plan)
        }
        covered = progress.coveredForCapture
        let retake = progress.retakeIds
        let newRetakes = retake.subtracting(lastRetakeIds)
        lastRetakeIds = retake
        if let first = plan.targets.first(where: { newRetakes.contains($0.id) }) {
            showBanner("\(DirectionContext.label(first, named: plan.usesStepNames)) の写真の切り抜きがうまくいきませんでした。もう一度撮ります", isError: true)
        }
        pushReference()
        updateMarkers(next: direction?.nextTarget, force: true)
    }

    /// 切り抜きの処理が遅れているときの表示（遅れていなければ nil）。
    var maskBacklogNotice: String? {
        maskBacklog > Self.maskBacklogNoticeCount ? "切り抜きを処理中（残り \(maskBacklog) 枚）" : nil
    }

    /// すべての方向がそろった（確認中を含まない）。
    var isComplete: Bool { phase == .capturing && progress.isComplete }

    private func pushReference() {
        var reference = LiveReference(plan: plan)
        reference.state = referenceState
        reference.basePoint = activeReferenceId == nil ? nil : basePoint
        reference.heightM = heightCm / 100
        reference.radiusM = radiusCm / 100
        reference.objectToWorld = objectToWorld
        reference.anchorId = baseAnchor?.identifier
        reference.covered = covered
        reference.retake = progress.retakeIds
        reference.preferredTargetId = preferredTargetId
        processor.reference = reference
    }

    /// 撮る方向の印。今の段（次に撮る方向の段）の印だけを出し、ほかの段は撮った印だけを薄く出す。
    private func updateMarkers(next: DirectionTarget?, force: Bool = false) {
        let nextId = next?.id
        let band = next?.elevationDeg
        // 状態は一覧の順に並べて比べる（毎回の解析で呼ぶので、並べ替えはしない）。
        let stateKey = progress.targets.map { $0.state.rawValue.prefix(2) }.joined()
        let key = "\(objectToWorld != nil)|\(stateKey)|\(nextId ?? "")|\(band.map { "\($0)" } ?? "")"
        guard force || key != lastMarkerKey else { return }
        lastMarkerKey = key
        let states = Dictionary(uniqueKeysWithValues: progress.targets.map { ($0.target.id, $0.state) })
        overlay.showMarkers(plan: plan, objectToWorld: objectToWorld, heightM: heightCm / 100, radiusM: radiusCm / 100,
                            states: states, nextId: nextId, activeBandElevation: band)
    }

    /// 次に撮る方向の段が変わった（1 周がそろった）ら知らせる。
    private func announceBandChange(_ direction: DirectionContext?) {
        guard let direction, direction.hasMultipleBands, direction.azimuthDeg != nil else { return }
        guard let next = direction.nextTarget else {
            lastGuideBand = nil
            return
        }
        defer { lastGuideBand = next.elevationDeg }
        guard let previous = lastGuideBand, abs(previous - next.elevationDeg) >= 0.5 else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showBanner(DirectionContext.bandStartMessage(next, fromElevationDeg: previous), isError: false)
    }

    // MARK: 撮影前の判定

    private func handle(_ analysis: LiveAnalysis) {
        guard isRunning else { return }
        var sample = analysis.sample
        sample.captureInFlight = captureInFlight
        // 設定中・基準なしのときは、収まりと方向は分からない扱い。
        if phase != .capturing {
            sample.reference = .none
            sample.projection = nil
            sample.direction = nil
        }
        lastSampleTimestamp = sample.timestamp
        assessment = evaluator.evaluate(sample)
        direction = sample.direction
        if phase == .capturing {
            updateMarkers(next: sample.direction?.nextTarget)
            announceBandChange(sample.direction)
        }
        if let center = analysis.normalizedCenter, phase == .capturing {
            focus.focus(at: center)
        }
        if phase == .capturing, autoCaptureEnabled, assessment.canAutoCapture, !showWarningsSheet, !showNoReferenceDialog {
            capture(trigger: .auto, warningsAcknowledged: false)
        }
    }

    // MARK: 撮影

    /// 有効な基準があり、撮影できる状態か。
    var hasReference: Bool { phase == .capturing && activeReferenceId != nil }

    /// シャッター（手動）。基準が無ければ先に基準を設定するか確かめる。警告があれば確認を出す。
    func shutterTapped() {
        handleShutter(noReferenceAcknowledged: false)
    }

    private func handleShutter(noReferenceAcknowledged: Bool) {
        switch ShutterPolicy.action(hasReference: hasReference, assessment: assessment, captureInFlight: captureInFlight,
                                    noReferenceAcknowledged: noReferenceAcknowledged) {
        case .unavailable: break
        case .confirmNoReference: showNoReferenceDialog = true
        case .confirmWarnings: showWarningsSheet = true
        case .capture: capture(trigger: .manual, warningsAcknowledged: false)
        }
    }

    /// 基準なしの確認で「このまま撮る」：今までどおり撮る（方向は参考値、切り抜きは写真の全体から）。
    func captureWithoutReference() {
        showNoReferenceDialog = false
        handleShutter(noReferenceAcknowledged: true)
    }

    /// 基準なしの確認で「基準を設定する」。
    func setReferenceFromDialog() {
        showNoReferenceDialog = false
        switch phase {
        case .placingBase, .adjustingSize, .measuringEdge: break  // すでに設定している
        default: beginPlacingBase()
        }
    }

    /// 警告を確認して「このまま撮る」。
    func captureAcknowledgingWarnings() {
        showWarningsSheet = false
        capture(trigger: .manual, warningsAcknowledged: true)
    }

    private func capture(trigger: CaptureTrigger, warningsAcknowledged: Bool) {
        // 撮影は 1 枚ずつ。撮っている間の要求は無視する。
        guard isRunning, !captureInFlight else { return }
        guard assessment.canManualCapture || trigger == .auto else { return }
        // 自動撮影は、正面が決まった有効な基準があるときだけ（基準なしでは撮らない）。
        guard trigger == .manual || (hasReference && referenceState == .ready) else { return }
        captureInFlight = true
        let context = CaptureContext(
            trigger: trigger,
            referenceFrameId: phase == .capturing ? activeReferenceId : nil,
            liveQuality: assessment.liveRecord(warningsAcknowledged: warningsAcknowledged),
            deviceOrientation: DeviceInfoProvider.name(of: UIDevice.current.orientation),
            displayRotationDegClockwise: 0,
            capturedAt: Date()
        )
        arView.session.captureHighResolutionFrame { [weak self] frame, error in
            // 返ってきたフレームから、写真と姿勢・K・時刻・露出をまとめて取る（currentFrame は使わない）。
            guard let frame else {
                let message = error?.localizedDescription ?? "不明なエラー"
                onMain { self?.finishCapture(.failure(CaptureError.captureFailed(message))) }
                return
            }
            let pixelBuffer = frame.capturedImage
            let camera = frame.camera
            let (state, reason) = camera.trackingState.core
            let info = CapturedFrameInfo(
                cameraToWorld: simd_double4x4(cleaning: camera.transform),
                intrinsics: simd_double3x3(cleaning: camera.intrinsics),
                intrinsicsResolution: PixelSize(width: Int(camera.imageResolution.width), height: Int(camera.imageResolution.height)),
                imageSize: PixelSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
                timestamp: frame.timestamp,
                exposureDuration: camera.exposureDuration > 0 ? camera.exposureDuration : nil,
                exposureOffset: camera.exposureOffset.isFinite ? Double(cleaning: camera.exposureOffset) : nil,
                trackingState: state, trackingReason: reason
            )
            var finalContext = context
            finalContext.displayRotationDegClockwise = DisplayRotation.rotation(deviceOrientation: context.deviceOrientation)
                ?? DisplayRotation.rotationFromGravity(upInCameraX: Double(camera.transform.columns.0.y), upInCameraY: Double(camera.transform.columns.1.y))
            self?.save(image: CapturedImage(pixelBuffer: pixelBuffer), info: info, context: finalContext)
        }
    }

    nonisolated private func save(image: CapturedImage, info: CapturedFrameInfo, context: CaptureContext) {
        let store = self.store, sessionId = self.sessionId
        saveQueue.async { [weak self] in
            let result: Result<Photo, Error> = autoreleasepool {
                if !info.intrinsicsMatchImage {
                    // 黙って K を直さない：画像の大きさと K の画像の大きさを両方記録する。
                    print("[Capture] imageResolution \(info.intrinsicsResolution) と画像 \(info.imageSize) が違います")
                }
                guard let jpeg = JPEGEncoder.shared.jpeg(from: image.pixelBuffer) else {
                    return .failure(CaptureError.encodeFailed)
                }
                let photoId = SessionStore.newId()
                return Result {
                    try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: jpeg) { session, sequence in
                        PhotoRecorder.makePhoto(in: &session, photoId: photoId, sequence: sequence, frame: info, context: context)
                    }
                }
            }
            onMain { self?.finishCapture(result) }
        }
    }

    private func finishCapture(_ result: Result<Photo, Error>) {
        captureInFlight = false
        evaluator.noteCapture(at: lastSampleTimestamp)
        switch result {
        case .success(let photo):
            AudioServicesPlaySystemSound(1108)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            refreshFromStore()
            masks.enqueue(sessionId: sessionId, photoId: photo.photoId)
            onSessionChanged()
            if !photo.direction.confirmed {
                showBanner("保存しました（方向は参考値です）", isError: false)
            }
        case .failure(let error):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            switch error as? CaptureError {
            case .captureFailed?:
                showBanner("撮影できませんでした。もう一度撮影してください", isError: true)
            default:
                showBanner("保存できませんでした。もう一度撮影してください", isError: true)
            }
            print("[Capture] 失敗: \(error)")
        }
    }

    // MARK: 表示

    func showBanner(_ message: String, isError: Bool) {
        banner = Banner(message: message, isError: isError)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// 案内の 1 行目（いつも 1 つの指示だけ）。
    var guidanceText: String {
        switch phase {
        case .starting: return "カメラを準備しています"
        case .unsupported(let message), .failed(let message): return message
        case .placingBase:
            if hasPlaneHit {
                return "\(reticleColorName)印を作品の底の中心（机に接するところ）に合わせて「ここが底の中心」を押してください"
            }
            if hasPinnedHeight { return "測った机の高さで探しています。机の作品のあたりへ iPhone を向けてください" }
            if showFallbacks { return "机が見つかりません。下の「iPhone の下端を机に当てて測る」でも合わせられます" }
            if hasDetectedPlane { return "作品の真下（底の中心）に印を合わせてください" }
            return "机の上を横にゆっくり動かして映してください（机の模様や物が映ると見つかりやすい）"
        case .measuringEdge:
            switch edgeStatus {
            case .tracking: return "そのまま少し待ってください（位置を確かめています）"
            case .notUpright: return "iPhone を縦にまっすぐ立て、下の端を作品のすぐ横の机に当ててください（カメラは作品へ）"
            case .holding:
                return edgeLowered ? "下の端を机に当てたまま、動かさないでください" : "下の端を机に当てて「測る」を押してください"
            }
        case .adjustingSize: return "円柱が作品をちょうど囲むように、高さと半径を合わせてください。輪が机に載って見えないときは「底の高さ」で合わせます"
        case .capturing: return assessment.primaryMessage
        }
    }

    private var reticleColorName: String {
        switch reticleSource {
        case .featurePoints?: return "水色の"
        case .deviceEdge?: return "紫色の"
        default: return "黄色い"
        }
    }

    /// 案内の 2 行目（こつ。無ければ nil）。
    var guidanceTip: String? {
        switch phase {
        case .placingBase:
            if reticleSource == .featurePoints {
                return "机の高さは推定です。輪が机に載って見えないときは、次の画面の「底の高さ」で合わせてください"
            }
            guard showPlaneTip, !hasPlaneHit else { return nil }
            return "白い机は見つけにくいので、新聞紙や柄のある布を作品の下に敷くと見つかりやすくなります"
        case .measuringEdge:
            return "作品のすぐ横（10 cm 以内）で測ると正確です。1 秒止めると自動で測ります"
        default:
            return nil
        }
    }

    /// 今使っている方法（照準が当たっているとき・大きさを合わせているとき）。
    var methodText: String? {
        let source: BasePointSource?
        switch phase {
        case .placingBase: source = reticleSource
        case .adjustingSize: source = baseInfo?.source
        default: source = nil
        }
        guard let source else { return nil }
        switch source {
        case .existingPlaneInfinite, .existingPlaneGeometry: return "見つかった机の平面を使っています"
        case .estimatedPlane: return "ARKit が推定した平面を使っています"
        case .featurePoints:
            if phase == .placingBase, let level = surfaceLevel {
                return "推定した机の高さを使っています（信頼度 \(level.label)・点 \(surfaceSupport)）"
            }
            if let n = baseInfo?.supportPoints { return "推定した机の高さを使っています（点 \(n)）" }
            return "推定した机の高さを使っています"
        case .deviceEdge:
            return deviceProfile.isKnownModel
                ? "iPhone の下端で測った机の高さを使っています"
                : "iPhone の下端で測った机の高さ（この機種はおおよそ）を使っています"
        }
    }

    /// 底の高さの表示（例：「+0.5 cm」）。
    var heightOffsetText: String {
        heightOffsetCm == 0 ? "±0 cm" : String(format: "%+.1f cm", heightOffsetCm)
    }
}

/// 保存のキューへ渡すピクセルバッファ（JPEG にするまでの間だけ持つ。ARFrame は持たない）。
struct CapturedImage: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

enum CaptureError: Error {
    case captureFailed(String)
    case encodeFailed
}
