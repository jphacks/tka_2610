import ARKit
import AudioToolbox
import CaptureCore
import SceneKit
import UIKit

/// 平面の作品（絵・貼り絵など）の撮影：基準（底の中心・円柱）を作らず、真上から 1 枚撮る。
/// 画面には用紙の輪郭（Vision の四角）を重ねる。写真は立体と同じ高解像度のフレーム（captureHighResolutionFrame）。
/// 撮ったあとに、その写真で用紙を見つけ直し、ARKit の平面に四隅を当てて実寸を測り、遠近を直した画像を作る。
/// 撮る人が紙の大きさを選んだとき（`declaredSize.sheet`）は、補正した画像の縦横比にその紙を使う（ARKit の平面で測った実寸は補助）。
/// 判定と計算は CaptureCore（`FlatGuidance`・`FlatShotStabilizer`・`FlatGeometry`）。
@MainActor
final class FlatCaptureController: ObservableObject {
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

    /// 撮った写真の結果（撮影画面に出す）。
    struct LastShot: Equatable {
        let photoId: String
        let sheetFound: Bool
        let sheetAtEdge: Bool
        let overhead: Bool
        let sizeText: String?
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var guidance: FlatGuidance = .noSheet
    /// 用紙の輪郭（画面の座標。左上・右上・右下・左下の順とは限らない）。見つかっていなければ nil。
    @Published private(set) var outline: [CGPoint]?
    /// 自動撮影までの進み具合（0〜1）。
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var lookDownDeg: Double?
    @Published private(set) var captureInFlight = false
    @Published private(set) var photoCount = 0
    /// 撮影画面の映像の枠の縦横比（縦に持って見た幅 / 高さ）。使っている映像の形式から決める。分からない間は nil（3:4 にする）。
    @Published private(set) var previewAspect: Double?
    @Published private(set) var lastShot: LastShot?
    @Published var banner: Banner?
    @Published var autoCaptureEnabled: Bool

    let arView: ARSCNView
    let sessionId: String
    /// 撮る人が新しいセッションで選んだ紙。選んでいなければ nil。
    let declaredSheet: DeclaredSheet?
    private let store: SessionStore
    private let masks: MaskProcessor
    private let onSessionChanged: @MainActor () -> Void
    private let detectQueue = DispatchQueue(label: "memoria.flat.detect", qos: .userInitiated)
    private let saveQueue = DispatchQueue(label: "memoria.flat.save", qos: .userInitiated)
    private var timer: Timer?
    private var detecting = false
    private var stabilizer = FlatShotStabilizer()
    /// 最後に見つかった用紙の四隅（写真の 0〜1、原点は左上）。
    private var lastCorners: [SIMD2<Double>]?
    /// 自動撮影を待っている（撮ったあとは、用紙が画面から外れるまで自動では撮らない）。
    private var autoArmed = true
    private var isRunning = false
    private var bannerTask: Task<Void, Never>?
    private var plan: DirectionPlan

    init(sessionId: String, store: SessionStore, settings: AppSettings, masks: MaskProcessor, onSessionChanged: @escaping @MainActor () -> Void) {
        self.sessionId = sessionId
        self.store = store
        self.masks = masks
        self.onSessionChanged = onSessionChanged
        autoCaptureEnabled = settings.autoCaptureEnabled
        let session = try? store.loadSession(sessionId)
        plan = session?.directionPlan ?? DirectionPlanPreset.flat1.plan
        declaredSheet = session?.declaredSheet
        photoCount = session?.photos.count ?? 0
        arView = ARSCNView(frame: .zero)
        arView.scene = SCNScene()
        arView.automaticallyUpdatesLighting = false
        arView.autoenablesDefaultLighting = false
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
        runSession()
        phase = .capturing
        startTimer()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopTimer()
        arView.session.pause()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func didEnterBackground() {
        guard isRunning else { return }
        stopTimer()
        arView.session.pause()
    }

    func didBecomeActive() {
        guard isRunning else { return }
        runSession()
        startTimer()
    }

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        // 用紙の四隅を当てる机の平面を探す（実寸を測るため）。見つからなくても撮れる。
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        stabilizer.reset()
        previewAspect = configuration.videoFormat.portraitAspect
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func startTimer() {
        timer?.invalidate()
        // 約 10 回 / 秒（Vision の四角の検出は 1 つずつ。前の結果を待っている間は飛ばす）。
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        detecting = false
    }

    // MARK: 用紙の検出（撮影前）

    private func tick() {
        guard phase == .capturing, !detecting, arView.bounds.width > 0, let frame = arView.session.currentFrame else { return }
        // 輪郭は ARSCNView の座標で出す（撮影画面は ARSCNView を写真と同じ縦横比にするので、写真の端＝画面の映像の端）。
        let viewport = arView.bounds.size
        let resolution = frame.camera.imageResolution
        let lookDown = FlatGeometry.lookDownDeg(cameraToWorld: simd_double4x4(fast: frame.camera.transform))
        let timestamp = frame.timestamp
        let buffer = CapturedImage(pixelBuffer: frame.capturedImage)
        detecting = true
        detectQueue.async { [weak self] in
            let result = SheetDetector.detect(pixelBuffer: buffer.pixelBuffer)
            onMain { self?.handle(result, timestamp: timestamp, lookDown: lookDown, resolution: resolution, viewport: viewport) }
        }
    }

    private func handle(_ result: SheetDetector.Result?, timestamp: Double, lookDown: Double, resolution: CGSize, viewport: CGSize) {
        detecting = false
        guard isRunning, phase == .capturing else { return }
        let corners = result?.corners
        lastCorners = corners
        lookDownDeg = lookDown
        outline = corners?.map { p in
            let v = CameraPreview.viewPoint(fromSensor: p, imageWidth: Double(resolution.width), imageHeight: Double(resolution.height),
                                            viewWidth: Double(viewport.width), viewHeight: Double(viewport.height))
            return CGPoint(x: v.x, y: v.y)
        }
        let next = FlatGuidance.evaluate(corners: corners, lookDownDeg: lookDown, plan: plan)
        if guidance != next { guidance = next }
        if next == .noSheet { autoArmed = true }
        let allowed = autoCaptureEnabled && autoArmed && !captureInFlight && next.allowsAutoCapture
        let progress = stabilizer.update(corners: corners, timestamp: timestamp, allowed: allowed)
        holdProgress = (progress * 10).rounded() / 10
        if progress >= 1 {
            stabilizer.reset()
            holdProgress = 0
            capture(trigger: .auto)
        }
    }

    // MARK: 撮影

    /// シャッター（手動）。用紙が見つからない・真上でないときも撮れる（撮ったあとに知らせる）。
    func shutterTapped() {
        capture(trigger: .manual)
    }

    private func capture(trigger: CaptureTrigger) {
        guard isRunning, phase == .capturing, !captureInFlight else { return }
        captureInFlight = true
        autoArmed = false
        let state = guidance
        let live = LiveQualityRecord(
            tracking: .unknown,
            inFrame: state == .noSheet || state == .sheetAtEdge ? .warning : .ok,
            direction: { if case .tilt = state { return .warning } else { return .ok } }(),
            motion: .unknown, brightness: .unknown, sharpness: .unknown, warningsAcknowledged: false
        )
        let orientation = DeviceInfoProvider.name(of: UIDevice.current.orientation)
        let context = CaptureContext(
            trigger: trigger, referenceFrameId: nil, liveQuality: live, deviceOrientation: orientation,
            displayRotationDegClockwise: FlatGeometry.displayRotation(deviceOrientation: orientation), capturedAt: Date()
        )
        arView.session.captureHighResolutionFrame { [weak self] frame, error in
            guard let frame else {
                let message = error?.localizedDescription ?? "不明なエラー"
                onMain { self?.finishCapture(.failure(CaptureError.captureFailed(message))) }
                return
            }
            let pixelBuffer = frame.capturedImage
            let camera = frame.camera
            let (trackingState, reason) = camera.trackingState.core
            var live = context.liveQuality
            live.tracking = trackingState == .normal ? .ok : .warning
            var finalContext = context
            finalContext.liveQuality = live
            let info = CapturedFrameInfo(
                cameraToWorld: simd_double4x4(cleaning: camera.transform),
                intrinsics: simd_double3x3(cleaning: camera.intrinsics),
                intrinsicsResolution: PixelSize(width: Int(camera.imageResolution.width), height: Int(camera.imageResolution.height)),
                imageSize: PixelSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
                timestamp: frame.timestamp,
                exposureDuration: camera.exposureDuration > 0 ? camera.exposureDuration : nil,
                exposureOffset: camera.exposureOffset.isFinite ? Double(cleaning: camera.exposureOffset) : nil,
                trackingState: trackingState, trackingReason: reason
            )
            self?.detectSheet(image: CapturedImage(pixelBuffer: pixelBuffer), info: info, context: finalContext)
        }
    }

    /// 1. 撮った写真そのもので用紙を見つける（撮影前の検出は使わない：別のフレーム・別の解像度のため）。
    nonisolated private func detectSheet(image: CapturedImage, info: CapturedFrameInfo, context: CaptureContext) {
        saveQueue.async { [weak self] in
            let size = info.imageSize
            var quad: FlatQuad?
            var confidence: Double?
            if let result = SheetDetector.detect(pixelBuffer: image.pixelBuffer, minimumSize: 0.1) {
                let pixels = result.corners.map { SIMD2($0.x * Double(size.width), $0.y * Double(size.height)) }
                quad = FlatGeometry.orderCorners(pixels, imageWidth: size.width, imageHeight: size.height,
                                                 rotationDegClockwise: context.displayRotationDegClockwise)
                confidence = quad == nil ? nil : (result.confidence * 1000).rounded() / 1000
            }
            onMain { self?.findPlane(image: image, info: info, context: context, quad: quad, confidence: confidence) }
        }
    }

    /// 2. 用紙の中心を通る線で ARKit の平面を探す（見つかった平面の形 → 推定した平面の順）。平面が無ければ実寸は測らない。
    private func findPlane(image: CapturedImage, info: CapturedFrameInfo, context: CaptureContext, quad: FlatQuad?, confidence: Double?) {
        var plane: (point: SIMD3<Double>, normal: SIMD3<Double>, source: String)?
        if let quad {
            let camera = CameraModel(cameraToWorld: info.cameraToWorld, intrinsics: info.intrinsics,
                                     imageWidth: Double(info.intrinsicsResolution.width), imageHeight: Double(info.intrinsicsResolution.height))
            let center = quad.points.reduce(SIMD2<Double>(0, 0), +) / 4
            let ray = FlatGeometry.ray(throughPixel: center, camera: camera, imageSize: info.imageSize)
            let chain: [(ARRaycastQuery.Target, String)] = [(.existingPlaneGeometry, "existingPlaneGeometry"), (.estimatedPlane, "estimatedPlane")]
            for (target, source) in chain where plane == nil {
                let query = ARRaycastQuery(origin: SIMD3<Float>(ray.origin), direction: SIMD3<Float>(ray.direction), allowing: target, alignment: .horizontal)
                let hits = arView.session.raycast(query).compactMap { result -> (SIMD3<Double>, SIMD3<Double>)? in
                    let t = result.worldTransform
                    let p = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
                    let n = SIMD3<Double>(Double(t.columns.1.x), Double(t.columns.1.y), Double(t.columns.1.z))
                    guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.y < ray.origin.y, simd_length(n) > 0.5 else { return nil }
                    return (p, n)
                }
                if let nearest = hits.min(by: { simd_distance($0.0, ray.origin) < simd_distance($1.0, ray.origin) }) {
                    plane = (nearest.0, nearest.1, source)
                }
            }
        }
        save(image: image, info: info, context: context, quad: quad, confidence: confidence, plane: plane)
    }

    /// 3. 実寸を測り、遠近を直した画像と元の写真を保存する。
    nonisolated private func save(image: CapturedImage, info: CapturedFrameInfo, context: CaptureContext, quad: FlatQuad?, confidence: Double?,
                                  plane: (point: SIMD3<Double>, normal: SIMD3<Double>, source: String)?) {
        let store = self.store, sessionId = self.sessionId, declaredSheet = self.declaredSheet
        saveQueue.async { [weak self] in
            let result: Result<Photo, Error> = autoreleasepool {
                guard let jpeg = JPEGEncoder.shared.jpeg(from: image.pixelBuffer) else { return .failure(CaptureError.encodeFailed) }
                let camera = CameraModel(cameraToWorld: info.cameraToWorld, intrinsics: info.intrinsics,
                                         imageWidth: Double(info.intrinsicsResolution.width), imageHeight: Double(info.intrinsicsResolution.height))
                var flat = FlatPhotoInfo.noSheet
                var distance: Double?
                var rectified: Data?
                if let quad {
                    flat.corners = quad
                    flat.cornersMethod = FlatPhotoInfo.visionMethod
                    flat.cornersConfidence = confidence
                    flat.sheetAtFrameEdge = FlatGeometry.touchesFrameEdge(quad, imageWidth: info.imageSize.width, imageHeight: info.imageSize.height)
                    if let plane {
                        flat.size = FlatGeometry.measureSize(corners: quad, camera: camera, imageSize: info.imageSize,
                                                             planePoint: plane.point, planeNormal: plane.normal, planeSource: plane.source)
                        let center = quad.points.reduce(SIMD2<Double>(0, 0), +) / 4
                        let ray = FlatGeometry.ray(throughPixel: center, camera: camera, imageSize: info.imageSize)
                        distance = FlatGeometry.intersect(ray, planePoint: plane.point, planeNormal: plane.normal).map { simd_distance($0, ray.origin) }
                    }
                    if let out = FlatGeometry.rectifiedSize(corners: quad, size: flat.size, declaredSheet: declaredSheet),
                       let data = SheetRectifier.shared.rectifiedJPEG(pixelBuffer: image.pixelBuffer, corners: quad, width: out.width, height: out.height) {
                        rectified = data
                        flat.rectified = FlatRectifiedImage(file: "", width: out.width, height: out.height)
                    }
                }
                let photoId = SessionStore.newId()
                let record = flat, measuredDistance = distance
                return Result {
                    try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: jpeg, rectifiedJPEG: rectified) { session, sequence in
                        PhotoRecorder.makeFlatPhoto(session: session, photoId: photoId, sequence: sequence, frame: info, context: context,
                                                    flat: record, distanceM: measuredDistance)
                    }
                }
            }
            onMain { self?.finishCapture(result) }
        }
    }

    private func finishCapture(_ result: Result<Photo, Error>) {
        captureInFlight = false
        switch result {
        case .success(let photo):
            AudioServicesPlaySystemSound(1108)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            photoCount = (try? store.loadSession(sessionId))?.photos.count ?? photoCount + 1
            // 明るさ・ブレを測る（平面の作品はマスクを作らない）。
            masks.enqueue(sessionId: sessionId, photoId: photo.photoId)
            onSessionChanged()
            let flat = photo.flat
            let size = flat?.size.map { String(format: "%.1f × %.1f cm", $0.widthM * 100, $0.heightM * 100) }
            lastShot = LastShot(photoId: photo.photoId, sheetFound: flat?.corners != nil, sheetAtEdge: flat?.sheetAtFrameEdge == true,
                                overhead: photo.direction.targetId != nil, sizeText: size)
            if flat?.corners == nil {
                showBanner("紙が見つからないまま撮りました（写真の全体を保存しました）", isError: true)
            } else if flat?.sheetAtFrameEdge == true {
                showBanner("紙の端が写真の端にかかっています。切れていないか確認してください", isError: true)
            } else if photo.direction.targetId == nil {
                showBanner("真上から撮れていません。必要なら撮り直してください", isError: true)
            } else {
                showBanner("撮影しました", isError: false)
            }
        case .failure(let error):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if case .captureFailed? = error as? CaptureError {
                showBanner("撮影できませんでした。もう一度撮影してください", isError: true)
            } else {
                showBanner("保存できませんでした。もう一度撮影してください", isError: true)
            }
            print("[FlatCapture] 失敗: \(error)")
        }
    }

    func showBanner(_ message: String, isError: Bool) {
        banner = Banner(message: message, isError: isError)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// 案内の 1 行目。
    var guidanceText: String {
        switch phase {
        case .starting: return "カメラを準備しています"
        case .unsupported(let message), .failed(let message): return message
        case .capturing:
            if guidance == .ready && !autoCaptureEnabled { return "シャッターを押してください" }
            if guidance == .ready && !autoArmed { return "撮れました。撮り直すときはシャッターを押してください" }
            return guidance.message
        }
    }
}
