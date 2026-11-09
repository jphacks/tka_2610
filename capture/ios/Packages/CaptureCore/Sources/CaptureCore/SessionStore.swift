import Foundation

public enum SessionStoreError: Error, Equatable, LocalizedError {
    case invalidId(String)
    case notFound(String)
    case photoNotFound(String)
    /// 転送中なので変更できない。
    case sessionBusy(String)
    case writeFailed(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidId(let id): return "ID の形が正しくありません: \(id)"
        case .notFound(let id): return "セッションが見つかりません: \(id)"
        case .photoNotFound(let id): return "写真が見つかりません: \(id)"
        case .sessionBusy: return "送信中のため変更できません"
        case .writeFailed(let message): return "保存できませんでした: \(message)"
        case .unreadable(let message): return "読み込めませんでした: \(message)"
        }
    }
}

/// 撮影セッションの保存場所。
///
/// ```
/// <root>/Sessions/<sessionId>/
///   session.json   photos/<photoId>.jpg   masks/<photoId>.png
///   transfer.json  転送の状態（転送しない）
///   local.json     撮影順の控え・ハッシュの控え（転送しない）
/// ```
///
/// 書き込みは一時ファイルに書いてから置き換える（`Data.write(options: .atomic)`）。
/// セッションの変更は 1 つのロックの中でディスクから読み直して行うので、どのスレッドから呼んでもよい。
public final class SessionStore: @unchecked Sendable {
    public let sessionsDirectory: URL
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var busySessions: Set<String> = []
    private let timeZone: TimeZone

    /// ファイルを書く処理（テストで失敗させるために差し替えられる）。
    public var writeData: @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }

    /// - Parameter rootDirectory: この下に `Sessions/` を作る。
    public init(rootDirectory: URL, fileManager: FileManager = .default, timeZone: TimeZone = .current) {
        sessionsDirectory = rootDirectory.appendingPathComponent("Sessions", isDirectory: true)
        self.fileManager = fileManager
        self.timeZone = timeZone
    }

    /// iOS では Application Support（Files アプリにも見せる場合は Documents を渡す）。
    public static func defaultRootDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    public static func isValidId(_ id: String) -> Bool {
        id.range(of: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$", options: .regularExpression) != nil
    }

    public static func newId() -> String { UUID().uuidString.uppercased() }

    // MARK: 場所

    public func sessionDirectory(_ sessionId: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionId, isDirectory: true)
    }

    public func sessionFileURL(_ sessionId: String) -> URL {
        sessionDirectory(sessionId).appendingPathComponent("session.json")
    }

    public func fileURL(_ sessionId: String, path: String) -> URL {
        sessionDirectory(sessionId).appendingPathComponent(path)
    }

    public func photoURL(_ sessionId: String, photoId: String) -> URL {
        fileURL(sessionId, path: Photo.imagePath(photoId: photoId))
    }

    public func maskURL(_ sessionId: String, photoId: String) -> URL {
        fileURL(sessionId, path: Photo.maskPath(photoId: photoId))
    }

    private func transferURL(_ sessionId: String) -> URL {
        sessionDirectory(sessionId).appendingPathComponent("transfer.json")
    }

    private func localURL(_ sessionId: String) -> URL {
        sessionDirectory(sessionId).appendingPathComponent("local.json")
    }

    // MARK: 転送中の印

    /// 転送中のセッションは変更できなくする（変更しようとすると `.sessionBusy`）。
    public func setBusy(_ sessionId: String, _ busy: Bool) {
        lock.lock(); defer { lock.unlock() }
        if busy { busySessions.insert(sessionId) } else { busySessions.remove(sessionId) }
    }

    public func isBusy(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return busySessions.contains(sessionId)
    }

    /// 転送中でなければ印を付けて true（同時に 2 つ送らないため）。
    public func tryMarkBusy(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busySessions.contains(sessionId) else { return false }
        busySessions.insert(sessionId)
        return true
    }

    private func ensureWritable(_ sessionId: String) throws {
        guard Self.isValidId(sessionId) else { throw SessionStoreError.invalidId(sessionId) }
        guard !busySessions.contains(sessionId) else { throw SessionStoreError.sessionBusy(sessionId) }
    }

    // MARK: 読み書き

    private func encode(_ session: CaptureSession) throws -> Data {
        try SessionJSON.makeEncoder(timeZone: timeZone).encode(session)
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try writeData(data, url)
        } catch {
            throw SessionStoreError.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func writeSession(_ session: CaptureSession) throws {
        try write(try encode(session), to: sessionFileURL(session.sessionId))
    }

    private func readSession(_ sessionId: String) throws -> CaptureSession {
        guard Self.isValidId(sessionId) else { throw SessionStoreError.invalidId(sessionId) }
        let url = sessionFileURL(sessionId)
        guard fileManager.fileExists(atPath: url.path) else { throw SessionStoreError.notFound(sessionId) }
        do {
            return try SessionJSON.makeDecoder().decode(CaptureSession.self, from: Data(contentsOf: url))
        } catch {
            throw SessionStoreError.unreadable("\(sessionId): \(error)")
        }
    }

    /// session.json の今のバイト列（転送の控えに使う）。
    public func sessionData(_ sessionId: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidId(sessionId) else { throw SessionStoreError.invalidId(sessionId) }
        do {
            return try Data(contentsOf: sessionFileURL(sessionId))
        } catch {
            throw SessionStoreError.notFound(sessionId)
        }
    }

    public func createSession(title: String, device: DeviceInfo, plan: DirectionPlan, now: Date = Date()) throws -> CaptureSession {
        lock.lock(); defer { lock.unlock() }
        let id = Self.newId()
        let session = CaptureSession(sessionId: id, title: title, createdAt: now, device: device, directionPlan: plan)
        let dir = sessionDirectory(id)
        do {
            try fileManager.createDirectory(at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: dir.appendingPathComponent("masks"), withIntermediateDirectories: true)
        } catch {
            throw SessionStoreError.writeFailed(error.localizedDescription)
        }
        do {
            try writeSession(session)
        } catch {
            try? fileManager.removeItem(at: dir)
            throw error
        }
        return session
    }

    /// 読めるセッションの一覧（新しく更新した順）。読めないフォルダは飛ばす。
    public func listSessions() -> [CaptureSession] {
        lock.lock(); defer { lock.unlock() }
        guard let names = try? fileManager.contentsOfDirectory(atPath: sessionsDirectory.path) else { return [] }
        return names.filter(Self.isValidId).compactMap { try? loadSessionLocked($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// セッションを読む。写真のファイルが無い写真は一覧から外し、マスクのファイルが無いマスクは失敗にする
    /// （直したら保存し直す。転送中は直さずに返すだけ）。余分なファイルは無視する。
    public func loadSession(_ sessionId: String) throws -> CaptureSession {
        lock.lock(); defer { lock.unlock() }
        return try loadSessionLocked(sessionId)
    }

    private func loadSessionLocked(_ sessionId: String) throws -> CaptureSession {
        var session = try readSession(sessionId)
        let original = session
        session.photos.removeAll { photo in
            !fileManager.fileExists(atPath: fileURL(sessionId, path: photo.image.file).path)
        }
        for i in session.photos.indices where session.photos[i].mask.status.hasFile {
            let path = session.photos[i].mask.file ?? Photo.maskPath(photoId: session.photos[i].photoId)
            if !fileManager.fileExists(atPath: fileURL(sessionId, path: path).path) {
                session.photos[i].mask = .failed("maskFileMissing", instanceCount: session.photos[i].mask.instanceCount)
            }
        }
        if session != original && !busySessions.contains(sessionId) {
            try? writeSession(session)
        }
        return session
    }

    /// セッションを変える。中身が変わったときだけ `updatedAt` を進めて保存する。
    @discardableResult
    public func updateSession(_ sessionId: String, now: Date = Date(), _ mutate: (inout CaptureSession) throws -> Void) throws -> CaptureSession {
        lock.lock(); defer { lock.unlock() }
        try ensureWritable(sessionId)
        var session = try loadSessionLocked(sessionId)
        let original = session
        try mutate(&session)
        guard session != original else { return session }
        session.updatedAt = now
        try writeSession(session)
        return session
    }

    /// 写真を足す。JPEG を書けてから写真の記録を作り、session.json を書けなかったら JPEG を消して失敗にする。
    /// 撮影順は、削除した写真の番号も使い回さない。
    /// - Parameter build: セッション（基準の正面を決めるために変えてよい）と撮影順から写真の記録を作る。
    @discardableResult
    public func addPhoto(
        sessionId: String, photoId: String, jpegData: Data, now: Date = Date(),
        build: (inout CaptureSession, Int) throws -> Photo
    ) throws -> Photo {
        lock.lock(); defer { lock.unlock() }
        try ensureWritable(sessionId)
        guard Self.isValidId(photoId) else { throw SessionStoreError.invalidId(photoId) }
        var session = try loadSessionLocked(sessionId)
        var local = loadLocalStateLocked(sessionId)
        let sequence = max(local.lastSequence, session.photos.map(\.sequence).max() ?? 0) + 1

        let photoURL = photoURL(sessionId, photoId: photoId)
        try? fileManager.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(jpegData, to: photoURL)
        do {
            local.lastSequence = sequence
            try saveLocalStateLocked(sessionId, local)
            var photo = try build(&session, sequence)
            photo.photoId = photoId
            photo.sequence = sequence
            photo.image.file = Photo.imagePath(photoId: photoId)
            session.photos.append(photo)
            session.updatedAt = now
            try writeSession(session)
            return photo
        } catch {
            try? fileManager.removeItem(at: photoURL)
            throw error
        }
    }

    /// マスクの PNG を書いて、写真のマスクの記録を変える。session.json を書けなければ PNG を消す。
    public func saveMask(sessionId: String, photoId: String, pngData: Data, now: Date = Date(), mask: MaskInfo) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureWritable(sessionId)
        var session = try loadSessionLocked(sessionId)
        guard let index = session.photos.firstIndex(where: { $0.photoId == photoId }) else {
            throw SessionStoreError.photoNotFound(photoId)
        }
        let url = maskURL(sessionId, photoId: photoId)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(pngData, to: url)
        var updated = mask
        updated.file = Photo.maskPath(photoId: photoId)
        session.photos[index].mask = updated
        session.updatedAt = now
        do {
            try writeSession(session)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// 写真を消す（記録を先に消してから、写真とマスクのファイルを消す）。
    public func deletePhoto(sessionId: String, photoId: String, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureWritable(sessionId)
        var session = try loadSessionLocked(sessionId)
        guard session.photos.contains(where: { $0.photoId == photoId }) else { throw SessionStoreError.photoNotFound(photoId) }
        var local = loadLocalStateLocked(sessionId)
        local.lastSequence = max(local.lastSequence, session.photos.map(\.sequence).max() ?? 0)
        try? saveLocalStateLocked(sessionId, local)
        session.photos.removeAll { $0.photoId == photoId }
        session.updatedAt = now
        try writeSession(session)
        try? fileManager.removeItem(at: photoURL(sessionId, photoId: photoId))
        try? fileManager.removeItem(at: maskURL(sessionId, photoId: photoId))
    }

    public func deleteSession(_ sessionId: String) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureWritable(sessionId)
        let dir = sessionDirectory(sessionId)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        do {
            try fileManager.removeItem(at: dir)
        } catch {
            throw SessionStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// 起動したときに、途中で止まったマスクの処理（processing）を未生成に戻す。戻した写真の (sessionId, photoId)。
    @discardableResult
    public func recoverInterruptedMasks() -> [(sessionId: String, photoId: String)] {
        lock.lock(); defer { lock.unlock() }
        var recovered: [(String, String)] = []
        for session in listSessions() where !busySessions.contains(session.sessionId) {
            let ids = session.photos.filter { $0.mask.status == .processing }.map(\.photoId)
            guard !ids.isEmpty else { continue }
            _ = try? updateSession(session.sessionId, now: session.updatedAt) { s in
                for i in s.photos.indices where ids.contains(s.photos[i].photoId) {
                    s.photos[i].mask = .notGenerated
                }
            }
            recovered += ids.map { (session.sessionId, $0) }
        }
        return recovered
    }

    // MARK: transfer.json・local.json

    public func loadTransferState(_ sessionId: String) -> TransferState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: transferURL(sessionId)),
              let state = try? SessionJSON.makeDecoder().decode(TransferState.self, from: data) else { return .notSent }
        return state
    }

    public func saveTransferState(_ sessionId: String, _ state: TransferState) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidId(sessionId) else { throw SessionStoreError.invalidId(sessionId) }
        try write(try SessionJSON.makeEncoder(timeZone: timeZone).encode(state), to: transferURL(sessionId))
    }

    public func loadLocalState(_ sessionId: String) -> LocalSessionState {
        lock.lock(); defer { lock.unlock() }
        return loadLocalStateLocked(sessionId)
    }

    private func loadLocalStateLocked(_ sessionId: String) -> LocalSessionState {
        guard let data = try? Data(contentsOf: localURL(sessionId)),
              let state = try? JSONDecoder().decode(LocalSessionState.self, from: data) else { return LocalSessionState() }
        return state
    }

    private func saveLocalStateLocked(_ sessionId: String, _ state: LocalSessionState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(state), to: localURL(sessionId))
    }

    // MARK: 転送の一覧

    /// 送るファイルの path：session.json、全写真、candidate / confirmed のマスク。
    public static func transferPaths(for session: CaptureSession) -> [String] {
        var paths = ["session.json"]
        for photo in session.photos {
            paths.append(photo.image.file)
            if photo.mask.status.hasFile, let file = photo.mask.file { paths.append(file) }
        }
        return paths
    }

    /// 今の中身の控え（session.json のバイト列と、各ファイルのハッシュ）。ハッシュは local.json に控えて使い回す。
    public func makeTransferSnapshot(_ sessionId: String) throws -> TransferSnapshot {
        lock.lock(); defer { lock.unlock() }
        let session = try loadSessionLocked(sessionId)
        let json = try Data(contentsOf: sessionFileURL(sessionId))
        var local = loadLocalStateLocked(sessionId)
        var entries = [ManifestEntry(path: "session.json", size: Int64(json.count), sha256: Hashing.sha256Hex(json))]
        var urls: [String: URL] = [:]
        var cache: [String: CachedFileHash] = [:]
        for path in Self.transferPaths(for: session) where path != "session.json" {
            let url = fileURL(sessionId, path: path)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let hash: String
            if let cached = local.fileHashes[path], cached.size == size, cached.modifiedAt == modified {
                hash = cached.sha256
            } else {
                let computed = try Hashing.sha256Hex(fileAt: url)
                hash = computed.hash
            }
            cache[path] = CachedFileHash(size: size, modifiedAt: modified, sha256: hash)
            entries.append(ManifestEntry(path: path, size: size, sha256: hash))
            urls[path] = url
        }
        if cache != local.fileHashes {
            local.fileHashes = cache
            try? saveLocalStateLocked(sessionId, local)
        }
        return TransferSnapshot(sessionId: sessionId, manifest: TransferManifest(entries: entries), sessionJSON: json, fileURLs: urls)
    }

    /// 一覧に出す転送の状態（今の manifestHash と比べる）。
    public func transferDisplayStatus(_ sessionId: String) -> TransferDisplayStatus {
        let state = loadTransferState(sessionId)
        if case .complete = state {
            let hash = try? makeTransferSnapshot(sessionId).manifest.manifestHash
            return TransferDisplayStatus.make(state: state, currentManifestHash: hash)
        }
        return TransferDisplayStatus.make(state: state, currentManifestHash: nil)
    }
}
