import ARKit
import AudioToolbox
import CaptureCore
import SceneKit
import UIKit

/// 向きで案内する立体の作品の撮影（guidance: heading）。底の中心・円柱は決めない。
/// 作品を画面の中央の十字に合わせて正面を手で撮り、そのときの iPhone の向きを覚える。そこから右・後ろ・左（90°・180°・270°）と
/// 真上を、向き・見下ろす角度と「その場で回しただけではないか」（ARKit の位置）で案内し、条件がそろって止まると自動で撮る。
/// 撮るたびに、方向ごとの代表の写真の線から作品の中心を求め直し、session.json の基準に書く（CaptureCore の HeadingDeriver）。
/// 机の面の高さは、AR が動いている今だけ測れるので、ここで ARKit の平面・特徴点から測って渡す。
@MainActor
final class HeadingCaptureController: ObservableObject {
    enum Phase: Equatable {
        case starting
        case unsupported(String)
        case capturing
        case failed(String)
    }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var assessment = QualityAssessment.initial
    @Published private(set) var heading: HeadingContext?
    @Published private(set) var progress: CoverageProgress
    @Published private(set) var plan: DirectionPlan
    @Published private(set) var captureInFlight = false
    @Published private(set) var photoCount = 0
    /// 撮影画面の映像の枠の縦横比（縦に持って見た幅 / 高さ）。使っている映像の形式から決める。分からない間は nil（3:4 にする）。
    @Published private(set) var previewAspect: Double?
    @Published private(set) var maskBacklog = 0
    /// 今の基準の正面を撮った。
    @Published private(set) var hasFront = false
    @Published var banner: Banner?
    @Published var showWarningsSheet = false
    @Published var autoCaptureEnabled: Bool

    let arView: ARSCNView
    let sessionId: String
    private let store: SessionStore
    private let masks: MaskProcessor
    private let onSessionChanged: @MainActor () -> Void
    private let processor: ARFrameProcessor
    private let focus = FocusController()
    private var evaluator: QualityEvaluator
    private let preferredTargetId: String?

    /// 今の基準（正面を撮ると作られる）。
    private var activeReferenceId: String?
    private var live = HeadingLiveReference()
    private var covered: Set<String> = []
    private var lastRetakeIds: Set<String> = []
    /// 前に中心を求めたときの代表の写真（変わったら求め直す）。
    private var lastRepresentatives: [String] = []
    /// 最近の特徴点（世界座標と時刻）。机の面の高さの推定に使う。
    private var featurePoints: [(point: SIMD3<Double>, time: Double)] = []
    private var pointsTimer: Timer?
    private var lastSampleTimestamp: Double = 0
    private var isRunning = false
    private var wasBackgrounded = false
    private var bannerTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "memoria.heading.save", qos: .userInitiated)

    /// 特徴点をためる時間（秒）と数の上限。
    private static let pointsWindowSeconds = 4.0
    private static let maxPoints = 4000
    /// 切り抜きの処理がこれより多く遅れたら知らせる（撮影は続ける）。
    static let maskBacklogNoticeCount = 6
    /// 見つかった平面を延ばして使うのは、平面の縁からこの距離まで。
    private static let infinitePlaneMargin: Float = 0.6

    init(sessionId: String, preferredTargetId: String?, store: SessionStore, settings: AppSettings, masks: MaskProcessor,
         onSessionChanged: @escaping @MainActor () -> Void) {
        self.sessionId = sessionId
        self.preferredTargetId = preferredTargetId
        self.store = store
        self.masks = masks
        self.onSessionChanged = onSessionChanged
        autoCaptureEnabled = settings.autoCaptureEnabled
        let session = try? store.loadSession(sessionId)
        let initialPlan = session?.directionPlan ?? DirectionPlanPreset.ai5.plan
        evaluator = QualityEvaluator(thresholds: settings.thresholds.adapted(to: initialPlan))
        plan = initialPlan
        progress = .empty(plan: initialPlan)
        photoCount = session?.photos.count ?? 0
        processor = ARFrameProcessor(thresholds: settings.thresholds, plan: initialPlan)
        arView = ARSCNView(frame: .zero)
        arView.scene = SCNScene()
        arView.automaticallyUpdatesLighting = false
        arView.autoenablesDefaultLighting = false
        arView.session.delegateQueue = processor.delegateQueue
        arView.session.delegate = processor

        processor.onAnalysis = { [weak self] in self?.handle($0) }
        processor.onReferenceLost = { [weak self] reason in
            // 向きの案内ではアンカーを置かないので、ここに来るのは位置を見失ったときだけ。
            self?.invalidateFrame(reason, message: "位置を見失いました。正面からもう一度撮ってください")
        }
        processor.onInterrupted = { [weak self] in
            self?.invalidateFrame(.sessionInterrupted, message: "中断されました。正面からもう一度撮ってください")
        }
        processor.onInterruptionEnded = { [weak self] in
            guard let self, self.isRunning else { return }
            self.runSession()
        }
        processor.onFailed = { [weak self] error in
            guard let self else { return }
            self.invalidateFrame(.sessionInterrupted, message: nil)
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
        // 前の AR セッションの基準は、世界座標が違うので使えない（正面から撮り直す）。
        invalidateStaleReferences()
        runSession()
        phase = .capturing
        refreshFromStore()
        pointsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.collectFeaturePoints() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pointsTimer?.invalidate()
        pointsTimer = nil
        invalidateFrame(.sessionInterrupted, message: nil)
        arView.session.pause()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func didEnterBackground() {
        guard isRunning else { return }
        wasBackgrounded = true
        arView.session.pause()
    }

    /// アプリが前に戻った：中断と同じに扱う（世界座標が変わるので、正面から撮り直す）。
    func didBecomeActive() {
        guard isRunning, wasBackgrounded else { return }
        wasBackgrounded = false
        invalidateFrame(.sessionInterrupted, message: activeReferenceId == nil ? nil : "中断されました。正面からもう一度撮ってください")
        runSession()
    }

    func retryAfterFailure() {
        guard isRunning else {
            start()
            return
        }
        runSession()
        phase = .capturing
    }

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        // 机の平面は、撮ったあとに底の高さ（作品座標の原点）を決めるのに使う。見つからなくても撮れる。
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        configuration.isLightEstimationEnabled = true
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        featurePoints = []
        processor.resetMotion()
        focus.reset()
        evaluator.reset()
        previewAspect = configuration.videoFormat.portraitAspect
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
        activeReferenceId = nil
        onSessionChanged()
    }

    /// 今の基準を無効にする（写真は残る）。次の写真が新しい正面になる。
    private func invalidateFrame(_ reason: InvalidationReason, message: String?) {
        let hadFrame = activeReferenceId != nil
        if let id = activeReferenceId {
            _ = try? store.updateSession(sessionId) { s in
                if let i = s.referenceFrames.firstIndex(where: { $0.id == id }), s.referenceFrames[i].isValid {
                    s.referenceFrames[i].invalidatedAt = Date()
                    s.referenceFrames[i].invalidationReason = reason
                }
            }
            onSessionChanged()
        }
        activeReferenceId = nil
        live = HeadingLiveReference()
        lastRepresentatives = []
        refreshFromStore()
        if let message, hadFrame { showBanner(message, isError: true) }
    }

    /// 「正面からやり直す」（作品を動かしたとき・正面を撮り直したいとき）。
    func restartFront() {
        invalidateFrame(.userReset, message: nil)
        showBanner("正面からやり直します。作品を十字に合わせて正面を撮ってください", isError: false)
    }

    func sessionDidChange() {
        guard isRunning, !captureInFlight else { return }
        refreshFromStore()
    }

    // MARK: 状態

    private func refreshFromStore() {
        guard let session = try? store.loadSession(sessionId) else { return }
        photoCount = session.photos.count
        plan = session.directionPlan
        let pendingMasks = masks.pendingPhotoIds()
        maskBacklog = session.photos.filter { pendingMasks.contains($0.photoId) || $0.mask.status == .processing }.count
        if let id = activeReferenceId, let frame = session.referenceFrame(id: id), frame.isValid {
            live = HeadingLiveReference.make(session: session, frameId: id)
            progress = Coverage.progress(in: session, referenceFrameId: id)
        } else {
            activeReferenceId = nil
            live = HeadingLiveReference()
            progress = .empty(plan: plan)
        }
        hasFront = live.hasFront
        covered = progress.coveredForCapture
        let retake = progress.retakeIds
        let newRetakes = retake.subtracting(lastRetakeIds)
        lastRetakeIds = retake
        if let first = plan.targets.first(where: { newRetakes.contains($0.id) }) {
            showBanner("\(plan.displayName(of: first)) の写真の切り抜きがうまくいきませんでした。もう一度撮ります", isError: true)
        }
        pushReference()
        deriveIfNeeded(session)
    }

    private func pushReference() {
        var reference = LiveReference(plan: plan)
        reference.state = hasFront ? .ready : .awaitingFront
        reference.covered = covered
        reference.retake = progress.retakeIds
        reference.preferredTargetId = preferredTargetId
        reference.heading = live
        processor.reference = reference
    }

    /// 代表の写真が変わったら、作品の中心・座標・写真ごとの方向を求め直して session.json に書く（撮ったあとに求める）。
    /// 机の面は、AR が動いている今、求めた中心の真下の ARKit の平面か、まわりの特徴点から測る。
    private func deriveIfNeeded(_ session: CaptureSession) {
        guard let id = activeReferenceId, hasFront else { return }
        let representatives = HeadingDeriver.representativePhotos(session: session, frameId: id).map(\.photoId)
        guard representatives != lastRepresentatives else { return }
        lastRepresentatives = representatives
        guard representatives.count >= 2 else { return }
        let photos = session.photos.filter { representatives.contains($0.photoId) }
        let center = HeadingDeriver.solveCenter(photos: photos.map { ($0.photoId, HeadingMath.centerRay(of: $0)) }).centerWorld?.simd
        let surface = center.flatMap(measureSurface(below:))
        do {
            let updated = try store.updateSession(sessionId) { s in
                HeadingDeriver.update(session: &s, frameId: id, surface: surface)
            }
            if let d = updated.referenceFrame(id: id)?.heading?.derivation {
                print("[Heading] 中心 \(d.status.rawValue) 残差 \(d.residualRmsM.map { String(format: "%.1f cm", $0 * 100) } ?? "-") 原点 \(d.origin?.rawValue ?? "-")")
            }
            onSessionChanged()
        } catch {
            print("[Heading] 中心を書けませんでした: \(error)")
        }
    }

    /// 求めた中心の真下の、作品を置いた面の高さ。ARKit の平面（延ばした面は縁から 0.6 m まで → 平面の形）、無ければ特徴点。
    private func measureSurface(below center: SIMD3<Double>) -> SupportSurface? {
        let origin = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
        let chain: [(ARRaycastQuery.Target, BasePointSource)] = [
            (.existingPlaneInfinite, .existingPlaneInfinite), (.existingPlaneGeometry, .existingPlaneGeometry),
        ]
        for (target, source) in chain {
            let query = ARRaycastQuery(origin: origin, direction: SIMD3(0, -1, 0), allowing: target, alignment: .horizontal)
            let hits = arView.session.raycast(query).compactMap { result -> Double? in
                let p = result.worldTransform.columns.3
                guard p.y.isFinite, Double(p.y) < center.y, center.y - Double(p.y) <= HeadingDeriver.maximumSurfaceDropM else { return nil }
                if target == .existingPlaneInfinite {
                    guard let plane = result.anchor as? ARPlaneAnchor,
                          Self.isNear(plane, worldPoint: SIMD3(p.x, p.y, p.z), margin: Self.infinitePlaneMargin) else { return nil }
                }
                return Double(cleaning: p.y)
            }
            // 一番高い面（作品のすぐ下の机。床ではなく）。
            if let y = hits.max() { return SupportSurface(heightY: y, source: source) }
        }
        let now = arView.session.currentFrame?.timestamp ?? 0
        return SupportSurfaceFinder.fromFeaturePoints(featurePoints.filter { now - $0.time <= Self.pointsWindowSeconds }.map(\.point), center: center)
    }

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

    /// 最近の特徴点をためる（約 2 回 / 秒。フレームは持ち続けない）。
    private func collectFeaturePoints() {
        guard isRunning, let frame = arView.session.currentFrame, let raw = frame.rawFeaturePoints else { return }
        let t = frame.timestamp
        featurePoints.removeAll { t - $0.time > Self.pointsWindowSeconds }
        featurePoints += raw.points.map { (SIMD3<Double>($0), t) }
        if featurePoints.count > Self.maxPoints { featurePoints.removeFirst(featurePoints.count - Self.maxPoints) }
    }

    // MARK: 撮影前の判定

    private func handle(_ analysis: LiveAnalysis) {
        guard isRunning else { return }
        var sample = analysis.sample
        sample.captureInFlight = captureInFlight
        if phase != .capturing { sample.heading = nil }
        lastSampleTimestamp = sample.timestamp
        assessment = evaluator.evaluate(sample)
        if heading != sample.heading { heading = sample.heading }
        if let center = analysis.normalizedCenter, phase == .capturing { focus.focus(at: center) }
        if phase == .capturing, autoCaptureEnabled, hasFront, assessment.canAutoCapture, !showWarningsSheet {
            capture(trigger: .auto, warningsAcknowledged: false)
        }
    }

    // MARK: 撮影

    /// シャッター（手動）。いつでも撮れる：狙った向きの外でも、測った向きのまま保存し、確認画面で知らせる。
    func shutterTapped() {
        switch ShutterPolicy.action(hasReference: phase == .capturing, assessment: assessment, captureInFlight: captureInFlight) {
        case .unavailable, .confirmNoReference: break
        case .confirmWarnings: showWarningsSheet = true
        case .capture: capture(trigger: .manual, warningsAcknowledged: false)
        }
    }

    func captureAcknowledgingWarnings() {
        showWarningsSheet = false
        capture(trigger: .manual, warningsAcknowledged: true)
    }

    private func capture(trigger: CaptureTrigger, warningsAcknowledged: Bool) {
        guard isRunning, phase == .capturing, !captureInFlight else { return }
        guard assessment.canManualCapture || trigger == .auto else { return }
        // 自動撮影は、正面を撮ったあとだけ（正面は撮る人が選んで手で撮る）。
        guard trigger == .manual || hasFront else { return }
        captureInFlight = true
        let context = CaptureContext(
            trigger: trigger, referenceFrameId: activeReferenceId,
            liveQuality: assessment.liveRecord(warningsAcknowledged: warningsAcknowledged),
            deviceOrientation: DeviceInfoProvider.name(of: UIDevice.current.orientation),
            displayRotationDegClockwise: 0, capturedAt: Date()
        )
        let startNewFrame = activeReferenceId == nil
        arView.session.captureHighResolutionFrame { [weak self] frame, error in
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
            self?.save(image: CapturedImage(pixelBuffer: pixelBuffer), info: info, context: finalContext, startNewFrame: startNewFrame)
        }
    }

    nonisolated private func save(image: CapturedImage, info: CapturedFrameInfo, context: CaptureContext, startNewFrame: Bool) {
        let store = self.store, sessionId = self.sessionId
        saveQueue.async { [weak self] in
            let result: Result<Photo, Error> = autoreleasepool {
                guard let jpeg = JPEGEncoder.shared.jpeg(from: image.pixelBuffer) else { return .failure(CaptureError.encodeFailed) }
                let photoId = SessionStore.newId()
                return Result {
                    try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: jpeg) { session, sequence in
                        PhotoRecorder.makeHeadingPhoto(in: &session, photoId: photoId, sequence: sequence, frame: info, context: context,
                                                       startNewFrame: startNewFrame)
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
            let wasFront = !hasFront
            if activeReferenceId == nil { activeReferenceId = photo.referenceFrameId }
            refreshFromStore()
            masks.enqueue(sessionId: sessionId, photoId: photo.photoId)
            onSessionChanged()
            if wasFront && hasFront {
                showBanner(photo.direction.targetId == nil
                           ? "正面を決めました（高さが外れていたので、正面はあとで撮り直します）。作品のまわりを歩いてください"
                           : "正面を撮りました。作品を十字に入れたまま、まわりを歩いてください", isError: photo.direction.targetId == nil)
            } else if !photo.direction.confirmed {
                showBanner("保存しました（方向は参考値です）", isError: false)
            } else if photo.direction.targetId == nil {
                showBanner(photo.heading?.position == .notWalkedAround
                           ? "保存しました。その場で回した写真なので、方向には数えません"
                           : "保存しました（狙った向きの外。確認画面で知らせます）", isError: true)
            }
        case .failure(let error):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if case .captureFailed? = error as? CaptureError {
                showBanner("撮影できませんでした。もう一度撮影してください", isError: true)
            } else {
                showBanner("保存できませんでした。もう一度撮影してください", isError: true)
            }
            print("[HeadingCapture] 失敗: \(error)")
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

    var isComplete: Bool { phase == .capturing && progress.isComplete }

    var maskBacklogNotice: String? {
        maskBacklog > Self.maskBacklogNoticeCount ? "切り抜きを処理中（残り \(maskBacklog) 枚）" : nil
    }

    /// 案内の 1 行目。
    var guidanceText: String {
        switch phase {
        case .starting: return "カメラを準備しています"
        case .unsupported(let message), .failed(let message): return message
        case .capturing: return assessment.primaryMessage
        }
    }

    /// 案内の 2 行目（距離の目安。撮るのは止めない）。
    var guidanceTip: String? {
        heading?.distanceHint?.message
    }

    var crosshair: CrosshairState { heading?.crosshair ?? .aligning }
}
