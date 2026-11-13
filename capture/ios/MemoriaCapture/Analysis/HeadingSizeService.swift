import CaptureCore
import Foundation

/// 向きで案内したセッション（guidance: heading）で、撮ったあとに作品の中心を求め直し、切り抜きができたら大きさを求めて
/// session.json に書く（計算は CaptureCore の `HeadingSizer.refresh`。Mac の memoria-pack も同じ計算を使う）。
/// 撮影画面を閉じたあとも切り抜きは作られるので、アプリ全体で 1 つ持ち、切り抜きができるたびに呼ぶ。
final class HeadingSizeService: @unchecked Sendable {
    private let store: SessionStore
    private let queue = DispatchQueue(label: "memoria.heading.size", qos: .utility)
    private let lock = NSLock()
    private var scheduled: Set<String> = []

    /// 変わったセッション（メインスレッドで呼ぶ）。
    var onChange: (@MainActor (String) -> Void)?

    init(store: SessionStore) {
        self.store = store
    }

    /// 少し待ってから（続けて呼ばれたらまとめて）求める。向きで案内したセッションでなければ何もしない。
    func refresh(sessionId: String) {
        let inserted = lock.withLock { scheduled.insert(sessionId).inserted }
        guard inserted else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.withLock { _ = self.scheduled.remove(sessionId) }
            self.run(sessionId: sessionId)
        }
    }

    private func run(sessionId: String) {
        // 送信中は変えない（送り終わったら、次に切り抜きが変わったときか、起動したときに求める）。
        guard !store.isBusy(sessionId), let session = try? store.loadSession(sessionId), session.usesHeadingGuidance else { return }
        // マスクの外接長方形を先に読んでおき（重い）、session.json はロックの中で読み直してから同じ計算をする。
        var bounds: [String: MaskBounds] = [:]
        let load: (Photo) -> MaskBounds? = { photo in
            if let b = bounds[photo.photoId] { return b }
            guard let file = photo.mask.file,
                  let image = ImageLoading.thumbnail(url: self.store.fileURL(sessionId, path: file), maxPixel: 1008),
                  let gray = ImageLoading.grayBuffer(from: image),
                  let b = MaskBounds.of(pixels: gray.pixels, width: gray.width, height: gray.height) else { return nil }
            bounds[photo.photoId] = b
            return b
        }
        var copy = session
        let changed = autoreleasepool { HeadingSizer.refresh(session: &copy, maskBounds: load) }
        guard changed else { return }
        do {
            let updated = try store.updateSession(sessionId) { s in
                autoreleasepool { HeadingSizer.refresh(session: &s, maskBounds: load) }
            }
            if let d = updated.referenceFrames.last?.heading?.derivation?.size {
                print("[Heading] 大きさ \(d.status) \(d.widthM.map { String(format: "%.1f", $0 * 100) } ?? "-") × \(d.depthM.map { String(format: "%.1f", $0 * 100) } ?? "-") × \(d.heightM.map { String(format: "%.1f", $0 * 100) } ?? "-") cm")
            }
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onChange?(sessionId) } }
        } catch {
            print("[Heading] 大きさを書けませんでした: \(error)")
        }
    }
}
