import ARKit
import AVFoundation
import CaptureCore
import Foundation
import WebKit

/// memoria の Web からの知らせを受ける（`window.webkit.messageHandlers.memoria.postMessage(...)`。取り決め v1、docs/web-bridge.md）。
///
/// `WKScriptMessageHandlerWithReply` なので、Web の `postMessage` は Promise を返す。返事は `(結果, nil)`、
/// 受けられないときは `(nil, 文言)`（Web では Promise が失敗し、文言がそのまま画面に出る）。
/// 受けるのは、設定した接続先のメインのフレームからの知らせだけ。知らせの読み方と確かめは CaptureCore の `BridgeRequest`。
@MainActor
final class MemoriaBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var web: MemoriaWebController?
    private weak var model: AppModel?

    /// 渡しそびれた撮影の結果（撮影中に Web のページが入れ替わったとき）。`pendingCapture` で 1 回だけ渡す。
    /// 作っている途中（JPEG にしている間）でも、終わるのを待ってから渡す。
    private var pending: Task<BridgeCaptureResult?, Never>?
    private var pendingSessionId: String?

    init(model: AppModel) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let frame = message.frameInfo
        guard let web, let model, let origin = web.origin, frame.isMainFrame,
              origin.matches(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port) else {
            return (nil, BridgeFailure.notAllowed.message)
        }
        switch BridgeRequest.parse(message.body) {
        case .failure(let failure):
            return (nil, failure.message)
        case .success(.startCapture(let request)):
            return await startCapture(request, web: web, model: model)
        case .success(.pendingCapture):
            return await takePending()
        case .success(.artworkCreated(let created)):
            switch model.linkArtwork(created, origin: origin) {
            case .failure(let failure):
                return (nil, failure.message)
            case .success:
                if pendingSessionId == created.sessionId {
                    pending = nil
                    pendingSessionId = nil
                }
                return (BridgeReply.ok, nil)
            }
        case .success(.openSessions):
            if model.embeddedCapture == nil { model.showsDeveloperScreens = true }
            return (BridgeReply.ok, nil)
        }
    }

    // MARK: 撮影

    private func startCapture(_ request: BridgeCaptureRequest, web: MemoriaWebController, model: AppModel) async -> (Any?, String?) {
        guard ARWorldTrackingConfiguration.isSupported else { return (nil, BridgeFailure.unsupportedDevice.message) }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return (nil, BridgeFailure.cameraDenied.message)
        default: break  // まだ聞いていなければ、撮影の画面で聞く
        }
        guard model.embeddedCapture == nil else { return (nil, BridgeFailure.busy.message) }
        // 新しく撮るので、前に渡しそびれた結果は捨てる（撮影データは iPhone に残る）。
        pending = nil
        pendingSessionId = nil

        let generation = web.pageGeneration
        var failure: BridgeFailure?
        let outcome: EmbeddedCaptureOutcome? = await withCheckedContinuation { continuation in
            let started = model.beginEmbeddedCapture(request) { outcome in continuation.resume(returning: outcome) }
            if case .failure(let error) = started {
                failure = error
                continuation.resume(returning: nil)
            }
        }
        guard let outcome else { return (nil, (failure ?? .cannotStart).message) }
        defer { web.captureEnded() }

        switch outcome {
        case .cancelled:
            return (BridgeReply.cancelled, nil)
        case let .finished(sessionId, kind):
            let store = model.store
            let task = Task.detached(priority: .userInitiated) {
                Self.makeResult(store: store, sessionId: sessionId, kind: kind)
            }
            // 頼んだページがもう無い（撮影中に Web の処理が落ちた・読み込み直した）なら、pendingCapture で渡す。
            if web.pageGeneration != generation { return keepPending(task, sessionId: sessionId) }
            let result = await task.value
            if web.pageGeneration != generation { return keepPending(task, sessionId: sessionId) }
            guard let result else { return (nil, BridgeFailure.imageUnavailable.message) }
            return (result.replyObject, nil)
        }
    }

    private func keepPending(_ task: Task<BridgeCaptureResult?, Never>, sessionId: String) -> (Any?, String?) {
        pending = task
        pendingSessionId = sessionId
        // この返事は、もう無いページへのもの（届かない）。
        return (nil, BridgeFailure.imageUnavailable.message)
    }

    private func takePending() async -> (Any?, String?) {
        guard let task = pending else { return (NSNull(), nil) }
        pending = nil
        pendingSessionId = nil
        guard let result = await task.value else { return (NSNull(), nil) }
        return (result.replyObject, nil)
    }

    /// 代表の写真をまっすぐに回した JPEG（長い辺 2048）にして、結果を作る。main スレッドの外で呼ぶ。
    nonisolated static func makeResult(store: SessionStore, sessionId: String, kind: BridgeCaptureKind) -> BridgeCaptureResult? {
        guard let session = try? store.loadSession(sessionId), let pick = RepresentativePhoto.pick(session: session) else { return nil }
        let url = store.fileURL(sessionId, path: pick.file)
        guard let jpeg = ImageLoading.uprightJPEG(
            url: url, rotation: pick.rotationDegClockwise,
            maxPixel: WebBridgeProtocol.imageMaxPixel, quality: WebBridgeProtocol.imageJPEGQuality
        ) else { return nil }
        return BridgeCaptureResult(kind: kind, sessionId: sessionId, photoCount: session.photos.count, imageBase64: jpeg.base64EncodedString())
    }
}
