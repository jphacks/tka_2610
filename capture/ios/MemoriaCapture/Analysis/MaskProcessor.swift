import CaptureCore
import Foundation

/// 保存した写真の解析（明るさ・ブレ）とマスク作りを、1 枚ずつ順番に行う（メモリを抑えるため）。
final class MaskProcessor: @unchecked Sendable {
    private let store: SessionStore
    private let evaluator: QualityEvaluator
    private let queue = DispatchQueue(label: "memoria.masks", qos: .utility)
    private let lock = NSLock()
    private var pending: Set<String> = []

    /// 変わったセッション（メインスレッドで呼ぶ）。
    var onChange: (@MainActor (String) -> Void)?

    init(store: SessionStore, thresholds: QualityThresholds) {
        self.store = store
        evaluator = QualityEvaluator(thresholds: thresholds)
    }

    func pendingPhotoIds() -> Set<String> {
        lock.withLock { pending }
    }

    func hasPending(sessionId: String) -> Bool {
        let ids = pendingPhotoIds()
        guard !ids.isEmpty, let session = try? store.loadSession(sessionId) else { return false }
        return session.photos.contains { ids.contains($0.photoId) || $0.mask.status == .processing }
    }

    /// マスクの作り方。
    enum Job: Sendable {
        /// 撮ったあと・起動したとき：明るさ・ブレを測り、マスクが未生成なら作る。
        case initial
        /// 切り抜きを作り直す（元写真は変えない）。`includeConfirmed` が false なら、確認済みのマスクは残す。
        case regenerate(includeConfirmed: Bool)
    }

    /// 写真の解析とマスク作りを順番待ちに入れる（1 枚ずつ順番に処理する。同じ写真が待っていれば何もしない）。
    func enqueue(sessionId: String, photoId: String, job: Job = .initial) {
        let inserted = lock.withLock { pending.insert(photoId).inserted }
        guard inserted else { return }
        queue.async { [weak self] in
            self?.process(sessionId: sessionId, photoId: photoId, job: job)
        }
    }

    /// 切り抜きを作り直す。`includeConfirmed` が false なら確認済み（confirmed）の写真は除く。
    func regenerate(sessionId: String, photoIds: [String], includeConfirmed: Bool) {
        for id in photoIds { enqueue(sessionId: sessionId, photoId: id, job: .regenerate(includeConfirmed: includeConfirmed)) }
        notify(sessionId)
    }

    private func notify(_ sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?(sessionId) }
        }
    }

    private func process(sessionId: String, photoId: String, job: Job) {
        defer {
            lock.withLock { _ = pending.remove(photoId) }
            notify(sessionId)
        }
        // 送信中なら少し待ってからやり直す（送信中のセッションは変えない）。
        if store.isBusy(sessionId) {
            lock.withLock { _ = pending.remove(photoId) }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.enqueue(sessionId: sessionId, photoId: photoId, job: job) }
            return
        }
        guard let session = try? store.loadSession(sessionId), let photo = session.photo(id: photoId) else { return }
        let imageURL = store.photoURL(sessionId, photoId: photoId)
        let region = SavedPhotoAnalyzer.objectRegion(photo: photo, session: session)

        autoreleasepool {
            // 1. 保存した写真の明るさ・シャープさ。
            if photo.quality.saved == nil,
               let metrics = SavedPhotoAnalyzer.metrics(jpegURL: imageURL, imageSize: PixelSize(width: photo.image.width, height: photo.image.height), roi: region) {
                let saved = evaluator.savedQuality(meanLuma: round(metrics.meanLuma, 4), sharpness: round(metrics.laplacianVariance, 6))
                _ = try? store.updateSession(sessionId) { s in
                    if let i = s.photos.firstIndex(where: { $0.photoId == photoId }) { s.photos[i].quality.saved = saved }
                }
            }
            // 2. マスク。最初は未生成のときだけ（ユーザーが選んだもの・確定したものは作り直さない）。
            //    作り直しは、確認済みを除く指定なら確認済みを残す。
            switch job {
            case .initial:
                // 前の版で作ったマスク（確かめの結果が無い）は、作り直さずに確かめだけする。
                if photo.mask.status.hasFile, photo.mask.check == nil {
                    checkExistingMask(sessionId: sessionId, photo: photo, session: session)
                    return
                }
                guard photo.mask.status == .notGenerated || photo.mask.status == .processing else { return }
            case .regenerate(let includeConfirmed):
                guard includeConfirmed || photo.mask.status != .confirmed else { return }
            }
            setMask(sessionId: sessionId, photoId: photoId, MaskInfo(status: .processing, method: MaskInfo.visionMethod))
            notify(sessionId)
            var tried: MaskCropPlan?
            do {
                // 作品のまわりを切り抜いて Vision に渡す。作品らしい物が見つからなければ、もっと狭い切り抜きで試す。
                let image = try MaskGenerator.loadImage(url: imageURL)
                var best: (analysis: InstanceAnalysis, selected: [Int])?
                for plan in MaskCropPlanner.plans(photo: photo, session: session) {
                    tried = tried ?? plan
                    let analysis = try MaskGenerator.analyze(image: image, plan: plan)
                    let selected = analysis.autoSelect()
                    if let map = analysis.labelMap, MaskInstanceSelector.isPlausible(map: map, selected: selected) {
                        best = (analysis, selected)
                        break
                    }
                    // 作品らしくなくても、最初に何か選べた結果を残す（ユーザーが選び直せるように）。
                    if best == nil || (best!.selected.isEmpty && !selected.isEmpty) { best = (analysis, selected) }
                }
                guard let best else { throw MaskGeneratorError.visionFailed("noPlan") }
                try saveSelection(sessionId: sessionId, photo: photo, analysis: best.analysis, selected: best.selected, selection: .auto)
            } catch {
                // 失敗しても写真は残す。前のマスクのファイルは使わないので消す。
                try? FileManager.default.removeItem(at: store.maskURL(sessionId, photoId: photoId))
                setMask(sessionId: sessionId, photoId: photoId, .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, plan: tried))
            }
        }
    }

    /// 保存したマスクを作品の輪郭と比べて、`mask.check` を書く（マスクと状態は変えない）。
    private func checkExistingMask(sessionId: String, photo: Photo, session: CaptureSession) {
        let plan = MaskCropPlanner.recordedPlan(photo: photo, session: session)
        guard let check = MaskGenerator.checkSavedMask(url: store.maskURL(sessionId, photoId: photo.photoId), plan: plan) else { return }
        _ = try? store.updateSession(sessionId) { s in
            if let i = s.photos.firstIndex(where: { $0.photoId == photo.photoId }), s.photos[i].mask.status.hasFile, s.photos[i].mask.check == nil {
                s.photos[i].mask.check = check
            }
        }
    }

    private func setMask(sessionId: String, photoId: String, _ mask: MaskInfo) {
        _ = try? store.updateSession(sessionId) { s in
            if let i = s.photos.firstIndex(where: { $0.photoId == photoId }) { s.photos[i].mask = mask }
        }
    }

    /// 選んだ物でマスクを作って保存する（何も選ばなければ noObject）。
    private func saveSelection(sessionId: String, photo: Photo, analysis: InstanceAnalysis, selected: [Int], selection: MaskSelectionKind) throws {
        let count = analysis.instanceCount
        let plan = analysis.plan
        guard !selected.isEmpty else {
            setMask(sessionId: sessionId, photoId: photo.photoId, MaskInfo(status: .noObject, method: MaskInfo.visionMethod, instanceCount: count, selection: selection).recording(plan))
            try? FileManager.default.removeItem(at: store.maskURL(sessionId, photoId: photo.photoId))
            return
        }
        let result = try MaskGenerator.maskPNG(analysis: analysis, instances: selected)
        guard result.width == photo.image.width, result.height == photo.image.height else {
            try? FileManager.default.removeItem(at: store.maskURL(sessionId, photoId: photo.photoId))
            setMask(sessionId: sessionId, photoId: photo.photoId, .failed("maskSizeMismatch \(result.width)x\(result.height)", instanceCount: count, plan: plan))
            return
        }
        try store.saveMask(sessionId: sessionId, photoId: photo.photoId, pngData: result.png, mask: MaskInfo(
            status: .candidate, width: result.width, height: result.height, method: MaskInfo.visionMethod,
            instanceCount: count, selectedInstances: selected, selection: selection, check: result.check
        ).recording(plan))
    }

    // MARK: 確認画面から

    /// 対象を選び直すための解析（物の番号の画像）。マスクを作ったときの切り抜き（記録があれば）を使うので、
    /// 記録した物の番号がそのまま使える。記録が無ければ新しく決めた切り抜き。
    func analyzeForEditing(sessionId: String, photoId: String, completion: @escaping @MainActor (Result<InstanceAnalysis, Error>) -> Void) {
        let store = self.store
        let url = store.photoURL(sessionId, photoId: photoId)
        queue.async {
            let result = Result { () throws -> InstanceAnalysis in
                let session = try store.loadSession(sessionId)
                guard let photo = session.photo(id: photoId) else { throw SessionStoreError.photoNotFound(photoId) }
                let plan = MaskCropPlanner.recordedPlan(photo: photo, session: session) ?? MaskCropPlanner.plan(photo: photo, session: session)
                return try autoreleasepool { try MaskGenerator.analyze(imageURL: url, plan: plan) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// ユーザーが選んだ物でマスクを作り直す（selection = user、status = candidate）。
    func applyUserSelection(sessionId: String, photoId: String, analysis: InstanceAnalysis, selected: [Int], completion: @escaping @MainActor (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var failure: Error?
            autoreleasepool {
                do {
                    guard let photo = try self.store.loadSession(sessionId).photo(id: photoId) else { throw SessionStoreError.photoNotFound(photoId) }
                    try self.saveSelection(sessionId: sessionId, photo: photo, analysis: analysis, selected: selected, selection: .user)
                } catch {
                    failure = error
                }
            }
            self.notify(sessionId)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
    }

    private func round(_ value: Double, _ digits: Int) -> Double {
        let p = pow(10, Double(digits))
        return (value * p).rounded() / p
    }
}
