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
    let workKind: WorkKind
    /// 立体の撮り方（平面は nil）。
    let guidance: CaptureGuidance?
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

/// memoria の Web から頼まれた撮影（撮影だけの画面を出している間）。
struct EmbeddedCapture: Identifiable, Equatable {
    let sessionId: String
    let kind: BridgeCaptureKind
    var id: String { sessionId }
}

/// 撮影だけの画面の終わり方。
enum EmbeddedCaptureOutcome {
    /// 「これで登録」（写真が 1 枚以上ある）。
    case finished(sessionId: String, kind: BridgeCaptureKind)
    /// 「やめる」（撮影データは消した）。
    case cancelled
}

/// アプリ全体の状態（保存場所・マスクの処理・転送・画面の行き先）。
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let store: SessionStore
    let masks: MaskProcessor
    let transfer: TransferCoordinator
    /// 向きで案内したセッションの、撮ったあとの中心と大きさ（切り抜きができたら求める）。
    let headingSizes: HeadingSizeService

    @Published var path: [Route] = []
    @Published private(set) var sessions: [SessionSummary] = []
    /// どれかのセッションが変わるたびに増える（開いている画面が読み直すため）。
    @Published private(set) var revision = 0
    @Published var alertMessage: String?
    /// memoria の Web から頼まれた撮影の画面（出している間だけ値がある）。
    @Published var embeddedCapture: EmbeddedCapture?
    /// 開発用の画面（撮影データの一覧・確認・Mac へ送る・設定）を出しているか。
    @Published var showsDeveloperScreens = false
    /// 撮影だけの画面が終わったときに呼ぶ（Web への返事）。
    private var embeddedCompletion: ((EmbeddedCaptureOutcome) -> Void)?
    /// 「やめる」で消す撮影データ（画面を閉じ終わってから消す。閉じている途中の撮影画面が読まないように）。
    private var sessionToDeleteAfterDismiss: String?

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
        let headingSizes = HeadingSizeService(store: store)
        self.headingSizes = headingSizes
        masks.onChange = { [weak self] sessionId in
            headingSizes.refresh(sessionId: sessionId)
            self?.sessionChanged()
        }
        headingSizes.onChange = { [weak self] _ in self?.sessionChanged() }
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
                    id: session.sessionId, title: session.title, workKind: session.workKind, guidance: session.captureGuidance,
                    photoCount: session.photos.count,
                    confirmedDirections: session.isFlat ? Readiness.make(session: session).doneCount : covered.count,
                    totalDirections: session.directionPlan.targets.count,
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

    /// 新しいセッション。作品の種類で撮り方が決まる（平面は真上から 1 枚、立体は設定の撮り方：自由に撮る（既定）か、案内つきの撮る方向）。
    /// `declaredSize` は撮る人が選んだ・入力した大きさ（平面は紙、立体は高さ。無ければ null）。
    /// `guidance` を渡すと、設定の撮り方の代わりにそれを使う（memoria からの撮影は端末の設定に左右されないよう `.free`）。
    func createSession(title: String, workKind: WorkKind, declaredSize: DeclaredSize? = nil, guidance: CaptureGuidance? = nil) -> CaptureSession? {
        do {
            // 自由に撮るときは撮る方向の一覧も free（`CaptureGuidance.newSession`）。
            let setup = CaptureGuidance.newSession(workKind: workKind, objectPreset: settings.planPreset, preferred: guidance ?? settings.guidance)
            let session = try store.createSession(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                device: DeviceInfoProvider.current(),
                plan: setup.plan,
                workKind: workKind,
                guidance: setup.guidance,
                declaredSize: declaredSize
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

    // MARK: memoria から頼まれた撮影

    /// 撮影だけの画面を出す。撮影データ（題名は空。作品を登録したら付ける）を作り、終わったら `completion` を 1 回呼ぶ。
    func beginEmbeddedCapture(_ request: BridgeCaptureRequest, completion: @escaping (EmbeddedCaptureOutcome) -> Void) -> Result<String, BridgeFailure> {
        guard embeddedCapture == nil, sessionToDeleteAfterDismiss == nil else { return .failure(.busy) }
        guard let session = createSession(title: "", workKind: request.kind.workKind, declaredSize: request.declaredSize, guidance: .free) else {
            alertMessage = nil  // 失敗は Web の画面に出す
            return .failure(.cannotStart)
        }
        showsDeveloperScreens = false
        embeddedCompletion = completion
        embeddedCapture = EmbeddedCapture(sessionId: session.sessionId, kind: request.kind)
        return .success(session.sessionId)
    }

    /// memoria から頼まれた撮影の画面に出ているセッションか（ボタンの文言が「これで登録」になる）。
    func isEmbeddedCapture(_ sessionId: String) -> Bool {
        embeddedCapture?.sessionId == sessionId
    }

    /// 撮影画面の「確認へ」「これで登録」。memoria から頼まれた撮影なら（写真が 1 枚以上あるときだけ）画面を閉じて Web に返し、
    /// そうでなければ確認画面へ移る。
    func finishCapture(sessionId: String) {
        guard let capture = embeddedCapture, capture.sessionId == sessionId else {
            replaceTop(with: .review(sessionId: sessionId))
            return
        }
        guard (loadSession(sessionId)?.photos.count ?? 0) > 0 else { return }
        let completion = embeddedCompletion
        embeddedCompletion = nil
        embeddedCapture = nil
        completion?(.finished(sessionId: sessionId, kind: capture.kind))
    }

    /// 撮影だけの画面の「やめる」。撮影データは、画面を閉じ終わってから消す（`embeddedCaptureDidDismiss`）。
    func cancelEmbeddedCapture() {
        guard let capture = embeddedCapture else { return }
        let completion = embeddedCompletion
        embeddedCompletion = nil
        sessionToDeleteAfterDismiss = capture.sessionId
        embeddedCapture = nil
        completion?(.cancelled)
    }

    /// 撮影だけの画面を閉じ終わった。
    func embeddedCaptureDidDismiss() {
        if let id = sessionToDeleteAfterDismiss {
            sessionToDeleteAfterDismiss = nil
            deleteSession(id)
        }
    }

    /// memoria に作品を登録できた：local.json に作品の id を書き、題名が空なら作品の題名を付ける。
    func linkArtwork(_ created: BridgeArtworkCreated, origin: WebOrigin) -> Result<Void, BridgeFailure> {
        guard let session = loadSession(created.sessionId) else { return .failure(.unknownSession) }
        do {
            try store.updateLocalState(created.sessionId) {
                $0.memoria = MemoriaLink(artworkId: created.artworkId, origin: origin.serialized, linkedAt: Date())
            }
            if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !created.title.isEmpty, !isLocked(created.sessionId) {
                try store.updateSession(created.sessionId) { $0.title = created.title }
            }
        } catch {
            return .failure(.unknownSession)
        }
        sessionChanged()
        return .success(())
    }

    func isLocked(_ sessionId: String) -> Bool {
        transfer.isSending(sessionId) || store.isBusy(sessionId)
    }

    /// 途中で止まったマスクの処理と、まだ作っていないマスクを作り直す。平面の作品・自由に撮るセッションはマスクを作らない（明るさ・ブレだけ）。
    private func resumeUnfinishedMasks() {
        store.recoverInterruptedMasks()
        for session in store.listSessions() {
            if session.usesHeadingGuidance { headingSizes.refresh(sessionId: session.sessionId) }
            if session.isFlat || session.usesFreeCapture {
                for photo in session.photos where photo.quality.saved == nil {
                    masks.enqueue(sessionId: session.sessionId, photoId: photo.photoId)
                }
                continue
            }
            // 確かめの結果（mask.check）の無いマスクは、確かめだけする。
            for photo in session.photos where photo.mask.status == .notGenerated || photo.quality.saved == nil
                || (photo.mask.status.hasFile && photo.mask.check == nil) {
                masks.enqueue(sessionId: session.sessionId, photoId: photo.photoId)
            }
        }
    }
}
