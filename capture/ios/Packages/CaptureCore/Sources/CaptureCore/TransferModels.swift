import CryptoKit
import Foundation

// MARK: - マニフェスト

public struct ManifestEntry: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// 転送するファイルの一覧（docs/transfer-protocol.md）。
public struct TransferManifest: Equatable, Sendable {
    /// path の順（UTF-8 のバイト順）に並べた一覧。
    public let entries: [ManifestEntry]
    public let manifestHash: String

    public init(entries: [ManifestEntry]) {
        let sorted = entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        self.entries = sorted
        manifestHash = Self.computeHash(sorted)
    }

    /// path で並べた各行 `"{path}\t{size}\t{sha256}\n"` をつなげた UTF-8 の SHA-256（小文字の hex）。
    public static func computeHash(_ entries: [ManifestEntry]) -> String {
        let sorted = entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var text = ""
        for e in sorted {
            text += "\(e.path)\t\(e.size)\t\(e.sha256)\n"
        }
        return Hashing.sha256Hex(Data(text.utf8))
    }

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }

    public func entry(path: String) -> ManifestEntry? { entries.first { $0.path == path } }
}

public enum Hashing {
    public static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// ファイルを少しずつ読んでハッシュする（大きな写真をまるごとメモリに載せない）。
    public static func sha256Hex(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            size += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        return (hex(hasher.finalize()), size)
    }
}

// MARK: - 転送の状態（transfer.json。転送しない）

public enum TransferState: Equatable, Sendable {
    case notSent
    case inProgress(uploadId: String?, receiverId: String, manifestHash: String, startedAt: Date)
    case complete(manifestHash: String, receiverId: String, at: Date, receiverPath: String?)
    case failed(message: String, at: Date)
}

extension TransferState: Codable {
    private enum CodingKeys: String, CodingKey {
        case state, uploadId, receiverId, manifestHash, startedAt, completedAt, receiverPath, message, failedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "inProgress":
            self = .inProgress(
                uploadId: try c.decodeIfPresent(String.self, forKey: .uploadId),
                receiverId: try c.decode(String.self, forKey: .receiverId),
                manifestHash: try c.decode(String.self, forKey: .manifestHash),
                startedAt: try c.decode(Date.self, forKey: .startedAt)
            )
        case "complete":
            self = .complete(
                manifestHash: try c.decode(String.self, forKey: .manifestHash),
                receiverId: try c.decode(String.self, forKey: .receiverId),
                at: try c.decode(Date.self, forKey: .completedAt),
                receiverPath: try c.decodeIfPresent(String.self, forKey: .receiverPath)
            )
        case "failed":
            self = .failed(message: try c.decode(String.self, forKey: .message), at: try c.decode(Date.self, forKey: .failedAt))
        default:
            self = .notSent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notSent:
            try c.encode("notSent", forKey: .state)
        case let .inProgress(uploadId, receiverId, manifestHash, startedAt):
            try c.encode("inProgress", forKey: .state)
            try c.encodeIfPresent(uploadId, forKey: .uploadId)
            try c.encode(receiverId, forKey: .receiverId)
            try c.encode(manifestHash, forKey: .manifestHash)
            try c.encode(startedAt, forKey: .startedAt)
        case let .complete(manifestHash, receiverId, at, receiverPath):
            try c.encode("complete", forKey: .state)
            try c.encode(manifestHash, forKey: .manifestHash)
            try c.encode(receiverId, forKey: .receiverId)
            try c.encode(at, forKey: .completedAt)
            try c.encodeIfPresent(receiverPath, forKey: .receiverPath)
        case let .failed(message, at):
            try c.encode("failed", forKey: .state)
            try c.encode(message, forKey: .message)
            try c.encode(at, forKey: .failedAt)
        }
    }
}

/// 一覧に出す転送の状態。
public enum TransferDisplayStatus: Equatable, Sendable {
    case notSent
    /// 送っている途中（または途中で止まった。もう一度送ると続きから）。
    case inProgress
    /// 今の中身を送り終えた。
    case sent
    /// 送ったあとに変わった。
    case modifiedSinceSent
    case failed(String)

    public var label: String {
        switch self {
        case .notSent: return "未送信"
        case .inProgress: return "送信途中"
        case .sent: return "送信済み"
        case .modifiedSinceSent: return "変更あり・未送信"
        case .failed: return "送信失敗"
        }
    }

    /// 送信済みは、今の manifestHash で commit が complete / alreadyComplete を返したときだけ。
    public static func make(state: TransferState, currentManifestHash: String?) -> TransferDisplayStatus {
        switch state {
        case .notSent:
            return .notSent
        case .inProgress:
            return .inProgress
        case let .complete(hash, _, _, _):
            guard let currentManifestHash else { return .modifiedSinceSent }
            return hash == currentManifestHash ? .sent : .modifiedSinceSent
        case let .failed(message, _):
            return .failed(message)
        }
    }
}

// MARK: - 端末だけのメモ（local.json。転送しない）

public struct LocalSessionState: Codable, Equatable, Sendable {
    /// 今までに使った一番大きい撮影順。削除しても番号を使い回さないため。
    public var lastSequence: Int
    /// ファイルのハッシュの控え（大きさと更新時刻が同じなら計算し直さない）。
    public var fileHashes: [String: CachedFileHash]

    public init(lastSequence: Int = 0, fileHashes: [String: CachedFileHash] = [:]) {
        self.lastSequence = lastSequence
        self.fileHashes = fileHashes
    }
}

public struct CachedFileHash: Codable, Equatable, Sendable {
    public var size: Int64
    public var modifiedAt: Double
    public var sha256: String

    public init(size: Int64, modifiedAt: Double, sha256: String) {
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }
}

/// 転送を始めるときに作る、そのときの中身の控え。session.json は中身そのものを持つ。
public struct TransferSnapshot: Sendable {
    public var sessionId: String
    public var manifest: TransferManifest
    public var sessionJSON: Data
    /// path → ファイルの場所（session.json 以外）。
    public var fileURLs: [String: URL]

    public init(sessionId: String, manifest: TransferManifest, sessionJSON: Data, fileURLs: [String: URL]) {
        self.sessionId = sessionId
        self.manifest = manifest
        self.sessionJSON = sessionJSON
        self.fileURLs = fileURLs
    }

    /// 送るファイルの場所（session.json 以外）。ファイルを少しずつ読んで大きさとハッシュを控えと比べ、違えばエラー。
    /// 送るのはこのファイルから（受信側も X-Content-SHA256 で確かめる）。
    public func verifiedFileURL(for path: String) throws -> URL {
        guard path != "session.json", let url = fileURLs[path], let entry = manifest.entry(path: path) else {
            throw TransferError.fileChanged(path)
        }
        let computed: (hash: String, size: Int64)
        do {
            computed = try Hashing.sha256Hex(fileAt: url)
        } catch {
            throw TransferError.fileChanged(path)
        }
        guard computed.size == entry.size, computed.hash == entry.sha256 else {
            throw TransferError.fileChanged(path)
        }
        return url
    }

    /// 送るファイルの中身。session.json は控え、ほかはディスクから読み、ハッシュが控えと違えばエラー。
    public func data(for path: String) throws -> Data {
        if path == "session.json" { return sessionJSON }
        guard let url = fileURLs[path], let entry = manifest.entry(path: path) else {
            throw TransferError.fileChanged(path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TransferError.fileChanged(path)
        }
        guard Int64(data.count) == entry.size, Hashing.sha256Hex(data) == entry.sha256 else {
            throw TransferError.fileChanged(path)
        }
        return data
    }
}
