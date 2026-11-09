import CaptureCore
import Foundation
import SwiftUI

/// 画面の行き先。
enum Route: Hashable {
    case capture(sessionId: String, preferredTargetId: String?)
    case review(sessionId: String)
    case photo(sessionId: String, photoId: String)
    case send(sessionId: String)
    case settings
}

/// 一覧に出すセッションの要約。
struct SessionSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let photoCount: Int
    let confirmedDirections: Int
    let totalDirections: Int
    let maskReady: Int
    let maskProcessing: Int
    let maskFailed: Int
    let transferStatus: TransferDisplayStatus
    let updatedAt: Date
    let firstPhoto: Photo?
}

/// アプリ全体の状態（保存場所・マスクの処理・転送・画面の行き先）。
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let store: SessionStore
    let masks: MaskProcessor
    let transfer: TransferCoordinator

    @Published var path: [Route] = []
    @Published private(set) var sessions: [SessionSummary] = []
    /// どれかのセッションが変わるたびに増える（開いている画面が読み直すため）。
    @Published private(set) var revision = 0
    @Published var alertMessage: String?

    init() {
        let settings = AppSettings()
        self.settings = settings
        // Files アプリからも見えるように Documents の下に置く（UIFileSharingEnabled）。
        let root = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let store = SessionStore(rootDirectory: root)
        self.store = store
        masks = MaskProcessor(store: store, thresholds: settings.thresholds)
        transfer = TransferCoordinator(store: store, settings: settings)
        masks.onChange = { [weak self] _ in self?.sessionChanged() }
        transfer.onChange = { [weak self] _ in self?.sessionChanged() }
        resumeUnfinishedMasks()
        reloadSessions()
    }

    // MARK: 行き先

    /// 今の画面を別の画面に置き換える（撮影 ⇄ 確認を行き来しても戻る先が増えないように）。
    func replaceTop(with route: Route) {
        if !path.isEmpty { path.removeLast() }
        path.append(route)
    }

    func open(_ route: Route) { path.append(route) }

    // MARK: セッション

    func sessionChanged() {
        revision += 1
        reloadSessions()
    }

    func reloadSessions() {
        let store = self.store
        let pending = masks.pendingPhotoIds()
        Task.detached(priority: .utility) {
            let summaries = store.listSessions().map { session -> SessionSummary in
                let covered = Coverage.coveredTargetIds(in: session)
                return SessionSummary(
                    id: session.sessionId, title: session.title, photoCount: session.photos.count,
                    confirmedDirections: covered.count, totalDirections: session.directionPlan.targets.count,
                    maskReady: session.photos.filter { $0.mask.status.hasFile }.count,
                    maskProcessing: session.photos.filter { $0.mask.status == .processing || pending.contains($0.photoId) }.count,
                    maskFailed: session.photos.filter { $0.mask.status == .failed || $0.mask.status == .noObject }.count,
                    transferStatus: store.transferDisplayStatus(session.sessionId),
                    updatedAt: session.updatedAt, firstPhoto: session.photos.first
                )
            }
            await MainActor.run { self.sessions = summaries }
        }
    }

    func loadSession(_ id: String) -> CaptureSession? {
        try? store.loadSession(id)
    }

    func createSession(title: String) -> CaptureSession? {
        do {
            let session = try store.createSession(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                device: DeviceInfoProvider.current(), plan: settings.planPreset.plan
            )
            sessionChanged()
            return session
        } catch {
            alertMessage = "セッションを作れませんでした（\(error.localizedDescription)）"
            return nil
        }
    }

    func deleteSession(_ id: String) {
        do {
            try store.deleteSession(id)
        } catch {
            alertMessage = error.localizedDescription
        }
        sessionChanged()
    }

    func renameSession(_ id: String, title: String) {
        do {
            try store.updateSession(id) { $0.title = title }
        } catch {
            alertMessage = error.localizedDescription
        }
        sessionChanged()
    }

    func isLocked(_ sessionId: String) -> Bool {
        transfer.isSending(sessionId) || store.isBusy(sessionId)
    }

    /// 途中で止まったマスクの処理と、まだ作っていないマスクを作り直す。
    private func resumeUnfinishedMasks() {
        store.recoverInterruptedMasks()
        for session in store.listSessions() {
            // 確かめの結果（mask.check）の無いマスクは、確かめだけする。
            for photo in session.photos where photo.mask.status == .notGenerated || photo.quality.saved == nil
                || (photo.mask.status.hasFile && photo.mask.check == nil) {
                masks.enqueue(sessionId: session.sessionId, photoId: photo.photoId)
            }
        }
    }
}
