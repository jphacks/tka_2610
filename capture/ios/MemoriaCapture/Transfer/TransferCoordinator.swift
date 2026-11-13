import CaptureCore
import Foundation

/// 送信の状態（画面に出す）。設定した受信側にだけ送る。
@MainActor
final class TransferCoordinator: ObservableObject {
    private let store: SessionStore
    private let settings: AppSettings

    @Published private(set) var sendingSessionId: String?
    @Published private(set) var progress: TransferProgress?
    @Published private(set) var lastOutcome: [String: TransferOutcome] = [:]

    var onChange: (@MainActor (String) -> Void)?
    private var work: Task<TransferOutcome, Never>?

    init(store: SessionStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func isSending(_ sessionId: String) -> Bool { sendingSessionId == sessionId }

    func makeClient() -> TransferClient? {
        guard let url = settings.receiverURL, !settings.trimmedPairingCode.isEmpty else { return nil }
        return TransferClient(receiverURL: url, token: settings.trimmedPairingCode)
    }

    /// 送る（ほかのセッションを送っている間は送らない）。
    func send(sessionId: String) {
        guard sendingSessionId == nil, let client = makeClient() else { return }
        sendingSessionId = sessionId
        progress = nil
        lastOutcome[sessionId] = nil
        let uploader = SessionUploader(store: store, client: client)
        // TransferCoordinator はアプリの間ずっとあり、MainActor の型なので強く持ってよい。
        let coordinator = self
        let work = Task.detached(priority: .userInitiated) {
            await uploader.send(sessionId: sessionId) { progress in
                Task { @MainActor in
                    if coordinator.sendingSessionId == sessionId { coordinator.progress = progress }
                }
            }
        }
        self.work = work
        Task { [weak self] in
            let outcome = await work.value
            guard let self else { return }
            self.lastOutcome[sessionId] = outcome
            self.sendingSessionId = nil
            self.work = nil
            self.onChange?(sessionId)
        }
    }

    /// 送信を止める（受信側には途中までのファイルが残り、次に送ると続きから送る）。
    func cancel() {
        work?.cancel()
    }
}
