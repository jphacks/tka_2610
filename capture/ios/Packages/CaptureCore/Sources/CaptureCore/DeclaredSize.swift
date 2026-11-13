import Foundation

// 撮る人が選んだ・入力した作品の大きさ（session.json の `declaredSize`。後から足した項目）。
// AR で測った値ではない：平面の作品は紙の大きさを一覧から選び、立体の作品は高さを入力する（どちらも省略できる）。
// 机の面（ARKit の平面）が見つからなくても変わらない。ARKit の平面で測った実寸（`photos[].flat.size`）は補助として今までの場所に残す。

// MARK: - 紙の一覧

/// 平面の作品の紙の大きさの一覧（一覧はここ 1 か所。表示名は日本語）。
public enum SheetPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case yatsugiri, yotsugiri, a4, b4, a3, b5

    public var id: String { rawValue }

    /// 一覧に出す名前。
    public var displayName: String {
        switch self {
        case .yatsugiri: return "八つ切"
        case .yotsugiri: return "四つ切"
        case .a4: return "A4"
        case .b4: return "B4"
        case .a3: return "A3"
        case .b5: return "B5"
        }
    }

    /// 短い辺（mm）。
    public var shortSideMm: Int {
        switch self {
        case .yatsugiri: return 271
        case .yotsugiri: return 392
        case .a4: return 210
        case .b4: return 257
        case .a3: return 297
        case .b5: return 182
        }
    }

    /// 長い辺（mm）。
    public var longSideMm: Int {
        switch self {
        case .yatsugiri: return 392
        case .yotsugiri: return 542
        case .a4: return 297
        case .b4: return 364
        case .a3: return 420
        case .b5: return 257
        }
    }

    public var shortSideM: Double { Double(shortSideMm) / 1000 }
    public var longSideM: Double { Double(longSideMm) / 1000 }

    /// 一覧の 1 行（例：「八つ切（27.1 × 39.2 cm）」）。
    public var label: String {
        "\(displayName)（\(Self.cmText(shortSideMm)) × \(Self.cmText(longSideMm)) cm）"
    }

    static func cmText(_ mm: Int) -> String { String(format: "%.1f", Double(mm) / 10) }
}

// MARK: - session.json の `declaredSize`

/// 一覧から選んだ紙（session.json の `declaredSize.sheet`）。縦・横の向きは書かない（使う側で決める）。
public struct DeclaredSheet: Codable, Equatable, Sendable {
    /// 一覧の id（`SheetPreset` の rawValue）。
    public var id: String
    public var longSideM: Double
    public var shortSideM: Double

    public init(id: String, longSideM: Double, shortSideM: Double) {
        self.id = id
        self.longSideM = longSideM
        self.shortSideM = shortSideM
    }

    public init(_ preset: SheetPreset) {
        self.init(id: preset.rawValue, longSideM: preset.longSideM, shortSideM: preset.shortSideM)
    }

    /// 一覧に無い大きさを撮る人が入力した紙の id（「その他」）。
    public static let customId = "custom"

    /// 撮る人が縦と横を入力した紙（「その他」）。長い辺は大きい方、短い辺は小さい方（向きは書かない）。
    public static func custom(sideAM: Double, sideBM: Double) -> DeclaredSheet {
        DeclaredSheet(id: customId, longSideM: max(sideAM, sideBM), shortSideM: min(sideAM, sideBM))
    }

    /// 「その他」で入力できる辺の範囲（cm）。
    public static let minimumCustomSideCm = 1.0
    public static let maximumCustomSideCm = 300.0

    /// 「その他」の縦と横の入力（cm の文字列）から紙を作る。どちらかが空・数でない・範囲（1〜300 cm）の外なら nil
    /// （紙は選んでいない扱い。推測で埋めない）。読み方は高さの入力と同じ（全角・「,」も読む。0.1 mm に丸める）。
    public static func custom(fromCentimetres sideA: String, _ sideB: String) -> DeclaredSheet? {
        guard let a = DeclaredSize.metres(fromCentimetres: sideA, minimumCm: minimumCustomSideCm, maximumCm: maximumCustomSideCm),
              let b = DeclaredSize.metres(fromCentimetres: sideB, minimumCm: minimumCustomSideCm, maximumCm: maximumCustomSideCm) else { return nil }
        return custom(sideAM: a, sideBM: b)
    }

    /// 一覧の紙（一覧に無い id なら nil）。
    public var preset: SheetPreset? { SheetPreset(rawValue: id) }

    /// 撮る人が大きさを入力した紙（「その他」）か。
    public var isCustom: Bool { id == Self.customId }

    /// 表示名（「その他」は「その他」、一覧に無いほかの id はその id）。
    public var displayName: String { preset?.displayName ?? (isCustom ? "その他" : id) }

    /// 寸法付きの表示名（例：「八つ切（27.1 × 39.2 cm）」「その他（21.0 × 30.0 cm）」）。
    public var labelWithSize: String {
        "\(displayName)（\(String(format: "%.1f", shortSideM * 100)) × \(String(format: "%.1f", longSideM * 100)) cm）"
    }

    /// 画像の横・縦（ピクセルなど、比が分かればよい）に合わせた紙の幅・高さ（m）。
    /// 横が縦以上なら横 = 長い辺、そうでなければ横 = 短い辺。横・縦が正の数でなければ nil（向きを決めない）。
    public func oriented(horizontal: Double, vertical: Double) -> (widthM: Double, heightM: Double)? {
        guard horizontal.isFinite, vertical.isFinite, horizontal > 0, vertical > 0 else { return nil }
        return horizontal >= vertical ? (longSideM, shortSideM) : (shortSideM, longSideM)
    }

    /// 紙の四隅（まっすぐに見たときの左上・右上・右下・左下）から向きを決める。横は上と下の辺の長い方、
    /// 縦は左と右の辺の長い方（`FlatGeometry.rectifiedSize` と同じ）。
    public func oriented(corners: FlatQuad) -> (widthM: Double, heightM: Double)? {
        let e = corners.edgeLengths
        return oriented(horizontal: max(e.top, e.bottom), vertical: max(e.left, e.right))
    }
}

/// 撮る人が選んだ・入力した大きさ（session.json の `declaredSize`）。入力していない項目は null。
/// セッションに書くのは、どちらかが入っているときだけ（どちらも無ければ `declaredSize` 自体を null にする）。
public struct DeclaredSize: Codable, Equatable, Sendable {
    /// 平面の作品：一覧から選んだ紙。選んでいない（「わからない」）・立体の作品は null。
    @NullCodable public var sheet: DeclaredSheet?
    /// 立体の作品：入力した高さ（m）。入力していない・平面の作品は null。
    @NullCodable public var heightM: Double?

    public init(sheet: DeclaredSheet? = nil, heightM: Double? = nil) {
        self.sheet = sheet
        self.heightM = heightM
    }

    public var isEmpty: Bool { sheet == nil && heightM == nil }

    /// 作品の種類に合わせる：平面は紙だけ、立体は高さだけを残す。どちらも無ければ nil。
    public func normalized(for workKind: WorkKind) -> DeclaredSize? {
        let size = DeclaredSize(sheet: workKind == .flat ? sheet : nil, heightM: workKind == .object ? heightM : nil)
        return size.isEmpty ? nil : size
    }

    /// 高さの入力で受け付ける範囲（cm）。
    public static let minimumHeightCm = 0.5
    public static let maximumHeightCm = 300.0

    /// 高さの入力（cm の文字列）を m にする。空・数でない・範囲（0.5〜300 cm）の外は nil（推測で埋めない）。
    /// 全角の数字・小数点と、小数点の「,」も読む。値は 0.1 mm に丸める。
    public static func heightM(fromCentimetres text: String) -> Double? {
        metres(fromCentimetres: text, minimumCm: minimumHeightCm, maximumCm: maximumHeightCm)
    }

    /// cm の入力（文字列）を m にする。空・数でない・`minimumCm`〜`maximumCm` の外は nil。
    /// 全角の数字・小数点と、小数点の「,」も読む。値は 0.1 mm に丸める。
    public static func metres(fromCentimetres text: String, minimumCm: Double, maximumCm: Double) -> Double? {
        let halfWidth: [Character: Character] = [
            "０": "0", "１": "1", "２": "2", "３": "3", "４": "4", "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
            "．": ".", "，": ".", ",": ".",
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = String(trimmed.map { halfWidth[$0] ?? $0 })
        guard !normalized.isEmpty, let cm = Double(normalized) else { return nil }
        return metres(centimetres: cm, minimumCm: minimumCm, maximumCm: maximumCm)
    }

    /// 高さ（cm の数。memoria の Web からの撮影の頼み `heightCm`）を m にする。範囲（0.5〜300 cm）の外・有限でない数は nil。
    /// 文字の入力と同じく 0.1 mm に丸める。
    public static func heightM(centimetres cm: Double) -> Double? {
        metres(centimetres: cm, minimumCm: minimumHeightCm, maximumCm: maximumHeightCm)
    }

    /// cm の数を m にする。有限でない・`minimumCm`〜`maximumCm` の外は nil。値は 0.1 mm に丸める。
    public static func metres(centimetres cm: Double, minimumCm: Double, maximumCm: Double) -> Double? {
        guard cm.isFinite, cm >= minimumCm, cm <= maximumCm else { return nil }
        return (cm * 100).rounded() / 10000
    }
}

extension CaptureSession {
    /// 平面の作品で選んだ紙。選んでいない・立体の作品は nil。
    public var declaredSheet: DeclaredSheet? { isFlat ? declaredSize?.sheet : nil }

    /// 立体の作品で入力した高さ（m）。入力していない・平面の作品は nil。
    public var declaredHeightM: Double? { isFlat ? nil : declaredSize?.heightM }
}
