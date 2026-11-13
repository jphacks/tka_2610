import ARKit
import AudioToolbox
import CaptureCore
import SceneKit
import UIKit

/// 立体の作品を自由に撮る撮影（`guidance` が `free`）：案内も自動撮影もなく、シャッターを押すだけで何枚でも撮る。
/// 平面の作品の撮影（`FlatCaptureController`）と同じ系統で、基準（底の中心・円柱）もマスクも作らない。
/// 写真は立体と同じ高解像度のフレーム（captureHighResolutionFrame）。向きはカメラの傾きだけを記録する（`PhotoRecorder.makeFreePhoto`）。
@MainActor
final class FreeCaptureController: ObservableObject {
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
    @Published private(set) var captureInFlight = false
    @Published private(set) var photoCount = 0
    /// 撮影画面の映像の枠の縦横比（縦に持って見た幅 / 高さ）。使っている映像の形式から決める。分からない間は nil（3:4 にする）。
    @Published private(set) var previewAspect: Double?
    @Published var banner: Banner?

    let arView: ARSCNView
    let sessionId: String
    /// 撮る人が新しいセッションで入力した高さ（m）。入力していなければ nil。
    let declaredHeightM: Double?
    private let store: SessionStore
    private let masks: MaskProcessor
    private let onSessionChanged: @MainActor () -> Void
    private let saveQueue = DispatchQueue(label: "memoria.free.save", qos: .userInitiated)
    private var isRunning = false
    private var bannerTask: Task<Void, Never>?

    init(sessionId: String, store: SessionStore, masks: MaskProcessor, onSessionChanged: @escaping @MainActor () -> Void) {
        self.sessionId = sessionId
        self.store = store
        self.masks = masks
        self.onSessionChanged = onSessionChanged
        let session = try? store.loadSession(sessionId)
        declaredHeightM = session?.declaredHeightM
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
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        arView.session.pause()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func didEnterBackground() {
        guard isRunning else { return }
        arView.session.pause()
    }

    func didBecomeActive() {
        guard isRunning else { return }
        runSession()
    }

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        // 机の平面は使わない（向きはカメラの傾きだけを記録する）。
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        previewAspect = configuration.videoFormat.portraitAspect
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: 撮影

    /// シャッター（いつでも撮れる）。
    func shutterTapped() {
        guard isRunning, phase == .capturing, !captureInFlight else { return }
        captureInFlight = true
        let orientation = DeviceInfoProvider.name(of: UIDevice.current.orientation)
        let context = CaptureContext(
            trigger: .manual, referenceFrameId: nil, liveQuality: .unknown, deviceOrientation: orientation,
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
            self?.save(image: CapturedImage(pixelBuffer: pixelBuffer), info: info, context: finalContext)
        }
    }

    /// 写真を保存する（マスクは作らない）。
    nonisolated private func save(image: CapturedImage, info: CapturedFrameInfo, context: CaptureContext) {
        let store = self.store, sessionId = self.sessionId
        saveQueue.async { [weak self] in
            let result: Result<Photo, Error> = autoreleasepool {
                guard let jpeg = JPEGEncoder.shared.jpeg(from: image.pixelBuffer) else { return .failure(CaptureError.encodeFailed) }
                let photoId = SessionStore.newId()
                return Result {
                    try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: jpeg) { session, sequence in
                        PhotoRecorder.makeFreePhoto(session: session, photoId: photoId, sequence: sequence, frame: info, context: context)
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
            // 明るさ・ブレを測る（自由に撮るセッションはマスクを作らない）。
            masks.enqueue(sessionId: sessionId, photoId: photo.photoId)
            onSessionChanged()
            showBanner("撮影しました（\(photoCount) 枚）", isError: false)
        case .failure(let error):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if case .captureFailed? = error as? CaptureError {
                showBanner("撮影できませんでした。もう一度撮影してください", isError: true)
            } else {
                showBanner("保存できませんでした。もう一度撮影してください", isError: true)
            }
            print("[FreeCapture] 失敗: \(error)")
        }
    }

    func showBanner(_ message: String, isError: Bool) {
        banner = Banner(message: message, isError: isError)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// 案内の 1 行目。
    var guidanceText: String {
        switch phase {
        case .starting: return "カメラを準備しています"
        case .unsupported(let message), .failed(let message): return message
        case .capturing: return FreeCaptureText.hint
        }
    }
}
