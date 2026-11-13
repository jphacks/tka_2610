import Foundation

// memoria（tka_2610 の Web）とアプリの橋渡し（取り決め v1。docs/web-bridge.md）。
// アプリは memoria を WKWebView で開き、Web の「3D 生成で追加」から頼まれたときだけネイティブの撮影画面を出す。
// ここには、WebKit を使わない部分（接続先の判定・知らせの読み方と確かめ・返事の形・Web に渡す写真の選び方・
// `window.MemoriaNative` の中身・家のリンクの読み方）を置く。WebKit とのやりとりはアプリの Web/MemoriaBridge.swift。

// MARK: - 取り決めの版と名前

public enum WebBridgeProtocol {
    /// 取り決めの版（`window.MemoriaNative.version`）。
    public static let version = 1
    /// `window.webkit.messageHandlers.<名前>` の名前。
    public static let handlerName = "memoria"
    /// Web に渡す写真の形。
    public static let imageMime = "image/jpeg"
    /// Web に渡す写真の長い辺（ピクセル）と JPEG の質。
    public static let imageMaxPixel = 2048
    public static let imageJPEGQuality = 0.85
}

// MARK: - 接続先（オリジン）

/// アプリが開く memoria の接続先（`scheme://host[:port]`。Info.plist の `MemoriaWebURL`）。
/// この接続先のページだけをアプリの中で開き、この接続先のメインのフレームからの知らせだけを受ける。
public struct WebOrigin: Equatable, Sendable {
    /// `http` か `https`（小文字）。
    public let scheme: String
    /// ホスト名（小文字）。
    public let host: String
    /// 書いてあるポート。既定のポート（http は 80、https は 443）なら nil。
    public let port: Int?

    /// `https://example.com`・`http://mac.local:8080` のような文字から作る。末尾の `/` だけは許す。
    /// http・https 以外、ホストが無い、パス・クエリ・ユーザー名が付いているときは nil（設定の間違いを見逃さないため）。
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        self.scheme = scheme
        self.host = host
        let defaultPort = Self.defaultPort(scheme)
        if let port = components.port {
            guard (1...65535).contains(port) else { return nil }
            self.port = port == defaultPort ? nil : port
        } else {
            self.port = nil
        }
    }

    static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    /// 使うポート（書いていなければ既定のポート）。
    public var effectivePort: Int { port ?? Self.defaultPort(scheme) }

    /// `https://example.com`・`http://mac.local:8080`（末尾の `/` なし）。
    public var serialized: String {
        port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// 一番上のページ（`<origin>/`）。
    public var rootURL: URL { URL(string: serialized + "/")! }

    /// 同じ接続先の URL か（scheme・ホスト・ポートがすべて同じ）。
    public func contains(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        return matches(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// WebKit の `WKSecurityOrigin`（`protocol`・`host`・`port`。既定のポートは 0）と同じ接続先か。
    public func matches(scheme: String, host: String, port: Int) -> Bool {
        let scheme = scheme.lowercased()
        guard scheme == self.scheme, host.lowercased() == self.host else { return false }
        return (port == 0 ? Self.defaultPort(scheme) : port) == effectivePort
    }
}

// MARK: - 家のリンク（「家を引き継ぐ」）

/// memoria の体験用の家の番号（32 桁の 16 進数。Cookie `memoria_house`）。`/house` の画面に出るリンク
/// `<origin>/?house=<番号>` を開くと、その家に切り替わる（tka_2610 の cloudflare/src/house.rs）。
public enum HouseLink {
    /// 貼り付けた文字から家の番号を読む：番号そのもの（32 桁の 16 進数）か、`house=<番号>` の付いた URL。
    /// 大文字は小文字にする。読めなければ nil（`house=new` も受け付けない）。
    public static func houseId(fromUserInput text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidId(trimmed.lowercased()) { return trimmed.lowercased() }
        guard let components = URLComponents(string: trimmed),
              let value = components.queryItems?.first(where: { $0.name == "house" })?.value?.lowercased(),
              isValidId(value) else { return nil }
        return value
    }

    /// 32 桁の小文字の 16 進数か。
    public static func isValidId(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// アプリの接続先でその家に切り替える URL（`<origin>/?house=<番号>`）。リンクがほかの接続先のものでも、番号だけを使う。
    public static func switchURL(origin: WebOrigin, houseId: String) -> URL {
        URL(string: "\(origin.serialized)/?house=\(houseId)")!
    }
}

// MARK: - memoria の作品とのつながり（local.json）

/// 撮影から memoria に登録した作品（local.json の `memoria`。Mac へは送らない）。
public struct MemoriaLink: Codable, Equatable, Sendable {
    /// memoria の作品の id（Web から受け取ったまま）。
    public var artworkId: String
    /// 登録した memoria の接続先（`https://example.com`）。
    public var origin: String
    /// 登録を知らされた日時。
    public var linkedAt: Date

    public init(artworkId: String, origin: String, linkedAt: Date) {
        self.artworkId = artworkId
        self.origin = origin
        self.linkedAt = linkedAt
    }
}

// MARK: - Web からの知らせ

/// 撮る作品の種類（Web の言い方）。
public enum BridgeCaptureKind: String, Codable, Sendable, CaseIterable {
    /// 立体（工作・粘土など）。memoria では `craft`。
    case object
    /// 平面（絵・貼り絵など）。memoria では `drawing`。
    case flat

    public var workKind: WorkKind {
        switch self {
        case .object: return .object
        case .flat: return .flat
        }
    }
}

/// 撮影の頼み（`startCapture`）を確かめたもの。
public struct BridgeCaptureRequest: Equatable, Sendable {
    public var kind: BridgeCaptureKind
    /// 撮る人が選んだ・入力した大きさ（平面は紙、立体は高さ）。どちらも無ければ nil。
    public var declaredSize: DeclaredSize?

    public init(kind: BridgeCaptureKind, declaredSize: DeclaredSize? = nil) {
        self.kind = kind
        self.declaredSize = declaredSize?.normalized(for: kind.workKind)
    }
}

/// 作品を登録できた知らせ（`artworkCreated`）。
public struct BridgeArtworkCreated: Equatable, Sendable {
    public var sessionId: String
    public var artworkId: String
    /// 作品の題名（前後の空白を除いたもの。無ければ空）。
    public var title: String

    public init(sessionId: String, artworkId: String, title: String) {
        self.sessionId = sessionId
        self.artworkId = artworkId
        self.title = title
    }
}

/// Web からの知らせ（`postMessage({ type, ... })`）。
public enum BridgeRequest: Equatable, Sendable {
    case startCapture(BridgeCaptureRequest)
    case pendingCapture
    case artworkCreated(BridgeArtworkCreated)
    case openSessions

    /// 作品の id・題名に使う長さの上限（文字）。
    public static let maxTextLength = 200

    /// `WKScriptMessage.body`（JS のオブジェクトを Foundation の型にしたもの）を読んで確かめる。
    /// 使わない項目（平面の `heightCm`、立体の `sheetId`）は無視する。
    public static func parse(_ body: Any?) -> Result<BridgeRequest, BridgeFailure> {
        guard let dict = body as? [String: Any] else { return .failure(.invalidMessage) }
        guard let type = dict["type"] as? String else { return .failure(.invalidMessage) }
        switch type {
        case "startCapture":
            return parseStartCapture(dict).map { .startCapture($0) }
        case "pendingCapture":
            return .success(.pendingCapture)
        case "artworkCreated":
            return parseArtworkCreated(dict).map { .artworkCreated($0) }
        case "openSessions":
            return .success(.openSessions)
        default:
            return .failure(.unknownType(String(type.prefix(40))))
        }
    }

    static func parseStartCapture(_ dict: [String: Any]) -> Result<BridgeCaptureRequest, BridgeFailure> {
        guard let raw = dict["kind"] as? String, let kind = BridgeCaptureKind(rawValue: raw) else { return .failure(.invalidKind) }
        switch kind {
        case .flat:
            let value = dict["sheetId"]
            if isAbsent(value) { return .success(BridgeCaptureRequest(kind: .flat)) }
            guard let id = value as? String else { return .failure(.invalidSheet) }
            if id.isEmpty { return .success(BridgeCaptureRequest(kind: .flat)) }
            guard let preset = SheetPreset(rawValue: id) else { return .failure(.invalidSheet) }
            return .success(BridgeCaptureRequest(kind: .flat, declaredSize: DeclaredSize(sheet: DeclaredSheet(preset))))
        case .object:
            let value = dict["heightCm"]
            if isAbsent(value) { return .success(BridgeCaptureRequest(kind: .object)) }
            guard let cm = number(value), let heightM = DeclaredSize.heightM(centimetres: cm) else { return .failure(.invalidHeight) }
            return .success(BridgeCaptureRequest(kind: .object, declaredSize: DeclaredSize(heightM: heightM)))
        }
    }

    static func parseArtworkCreated(_ dict: [String: Any]) -> Result<BridgeArtworkCreated, BridgeFailure> {
        guard let sessionId = dict["sessionId"] as? String, SessionStore.isValidId(sessionId) else { return .failure(.unknownSession) }
        let artworkId: String
        if let text = dict["artworkId"] as? String {
            artworkId = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let n = number(dict["artworkId"]), n.isFinite, n == n.rounded(), abs(n) < 1e15 {
            artworkId = String(Int64(n))
        } else {
            return .failure(.invalidArtwork)
        }
        guard !artworkId.isEmpty, artworkId.count <= maxTextLength else { return .failure(.invalidArtwork) }
        let rawTitle = (dict["title"] as? String) ?? ""
        let title = String(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextLength))
        return .success(BridgeArtworkCreated(sessionId: sessionId, artworkId: artworkId, title: title))
    }

    /// 項目が無い・null（JS の undefined は項目ごと無くなる）。
    static func isAbsent(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    /// JS の数（NSNumber。true・false は数として扱わない）。
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}

/// 知らせを受けられなかったときの返事。`message` は Web がそのまま画面に出す文言（Promise が失敗し、Error の message になる）。
public enum BridgeFailure: Error, Equatable, Sendable {
    /// 知らせの形が正しくない（オブジェクトでない・`type` が無い）。
    case invalidMessage
    /// 知らない `type`。
    case unknownType(String)
    /// `kind` が `object`・`flat` のどちらでもない。
    case invalidKind
    /// `sheetId` が紙の一覧（`SheetPreset`）に無い。
    case invalidSheet
    /// `heightCm` が数でない・0.5〜300 cm の外。
    case invalidHeight
    /// `sessionId` の撮影データが見つからない。
    case unknownSession
    /// `artworkId` が空・形が正しくない。
    case invalidArtwork
    /// 撮影の画面がすでに開いている。
    case busy
    /// 設定した接続先のメインのフレームからの知らせではない。
    case notAllowed
    /// 撮影データを作れなかった。
    case cannotStart
    /// 撮った写真を読めなかった・JPEG にできなかった。
    case imageUnavailable
    /// カメラが許可されていない。
    case cameraDenied
    /// この端末では撮影できない（ARKit のワールドトラッキングに対応していない）。
    case unsupportedDevice

    public var message: String {
        switch self {
        case .invalidMessage: return "アプリへの知らせの形が正しくありません"
        case .unknownType(let type): return "アプリが知らない知らせです（\(type)）"
        case .invalidKind: return "作品の種類が正しくありません"
        case .invalidSheet: return "紙の大きさが一覧にありません"
        case .invalidHeight:
            return "高さは \(BridgeFailure.cmText(DeclaredSize.minimumHeightCm))〜\(BridgeFailure.cmText(DeclaredSize.maximumHeightCm)) cm で入れてください"
        case .unknownSession: return "撮影データが見つかりません"
        case .invalidArtwork: return "作品の番号が正しくありません"
        case .busy: return "撮影の画面がすでに開いています"
        case .notAllowed: return "このページからは撮影できません"
        case .cannotStart: return "撮影を始められませんでした"
        case .imageUnavailable: return "撮った写真を読み込めませんでした"
        case .cameraDenied: return "カメラが許可されていません。「設定」アプリの「Memoria」でカメラをオンにしてください"
        case .unsupportedDevice: return "この端末では撮影できません"
        }
    }

    static func cmText(_ cm: Double) -> String {
        cm == cm.rounded() ? String(Int(cm)) : String(cm)
    }
}

// MARK: - 返事

/// 撮影の結果（`startCapture`・`pendingCapture` の返事）。
public struct BridgeCaptureResult: Equatable, Sendable {
    public var kind: BridgeCaptureKind
    public var sessionId: String
    /// 撮った写真の枚数（Web に渡すのは代表の 1 枚だけ）。
    public var photoCount: Int
    public var mime: String
    /// 代表の写真（まっすぐに回した JPEG）の base64。
    public var imageBase64: String

    public init(kind: BridgeCaptureKind, sessionId: String, photoCount: Int, mime: String = WebBridgeProtocol.imageMime, imageBase64: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.photoCount = photoCount
        self.mime = mime
        self.imageBase64 = imageBase64
    }

    /// 返事のオブジェクト（JS では `{ kind, sessionId, photoCount, mime, image }`。image は data: の付かない base64）。
    public var replyObject: [String: Any] {
        ["kind": kind.rawValue, "sessionId": sessionId, "photoCount": photoCount, "mime": mime, "image": imageBase64]
    }
}

public enum BridgeReply {
    /// 撮影をやめたとき（`startCapture` の返事）。
    public static var cancelled: [String: Any] { ["cancelled": true] }
    /// 受け付けたとき（`artworkCreated`・`openSessions` の返事）。
    public static var ok: [String: Any] { ["ok": true] }
}

// MARK: - window.MemoriaNative

/// 読み込み時に Web に入れる `window.MemoriaNative`（`{ capture: true, version: 1, sheets: [{id, label}], heightCm: {min, max}}`）。
public struct NativeCaptureInfo: Encodable, Equatable, Sendable {
    public struct Sheet: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
    }

    public struct HeightRange: Encodable, Equatable, Sendable {
        public var min: Double
        public var max: Double
    }

    public var capture: Bool
    public var version: Int
    public var sheets: [Sheet]
    public var heightCm: HeightRange

    /// 今のアプリの値。紙の一覧は `SheetPreset`（「その他」は Web からは選べない）、高さの範囲は `DeclaredSize`。
    public static let current = NativeCaptureInfo(
        capture: true, version: WebBridgeProtocol.version,
        sheets: SheetPreset.allCases.map { Sheet(id: $0.rawValue, label: $0.label) },
        heightCm: HeightRange(min: DeclaredSize.minimumHeightCm, max: DeclaredSize.maximumHeightCm)
    )

    /// JSON（キーの順は決まった順）。
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encodable の値だけなので失敗しない。
        return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// ページの読み込みの初め（document start）に入れるスクリプト。
    public func userScriptSource() -> String {
        "window.MemoriaNative = Object.freeze(\(json()));"
    }
}

// MARK: - Web に渡す写真

/// memoria の作品追加のフォームに渡す代表の写真。
public struct RepresentativePhoto: Equatable, Sendable {
    public var photoId: String
    /// セッションのフォルダからの場所（`photos/<id>.jpg` か `rectified/<id>.jpg`）。
    public var file: String
    /// まっすぐ見るために時計回りに回す角度（補正した画像は 0）。
    public var rotationDegClockwise: Int
    /// 平面の作品の、遠近を直した画像か。
    public var isRectified: Bool

    public init(photoId: String, file: String, rotationDegClockwise: Int, isRectified: Bool) {
        self.photoId = photoId
        self.file = file
        self.rotationDegClockwise = rotationDegClockwise
        self.isRectified = isRectified
    }

    /// 平面の作品は一番新しい写真（撮り直すと一番新しい写真が代表）の、遠近を直した画像（無ければ元の写真をまっすぐに回したもの）。
    /// 立体の作品は最初の写真。写真が無ければ nil。
    public static func pick(session: CaptureSession) -> RepresentativePhoto? {
        if session.isFlat {
            guard let latest = session.photos.max(by: { $0.sequence < $1.sequence }) else { return nil }
            if let file = latest.flat?.rectified?.file {
                return RepresentativePhoto(photoId: latest.photoId, file: file, rotationDegClockwise: 0, isRectified: true)
            }
            return original(latest)
        }
        guard let first = session.photos.min(by: { $0.sequence < $1.sequence }) else { return nil }
        return original(first)
    }

    static func original(_ photo: Photo) -> RepresentativePhoto {
        RepresentativePhoto(photoId: photo.photoId, file: photo.image.file,
                            rotationDegClockwise: DisplayRotation.normalized(photo.image.displayRotationDegClockwise), isRectified: false)
    }
}
