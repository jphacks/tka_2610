import Foundation
import simd

// MARK: - 明示的に null を書く Optional

/// `nil` のときもキーを残して `null` を書く Optional。
/// session.json はキーが無いのではなく `null` を入れる決まりなので、合成された Codable の
/// `encodeIfPresent`（キーを省く）を使わないためのラッパー。読むときはキーが無くても `nil` にする。
@propertyWrapper
public struct NullCodable<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = wrappedValue {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    /// キーが無いときも `nil` として読む（合成された init(from:) から呼ばれる）。
    public func decode<V>(_ type: NullCodable<V>.Type, forKey key: Key) throws -> NullCodable<V> {
        try decodeIfPresent(type, forKey: key) ?? NullCodable(wrappedValue: nil)
    }
}

// MARK: - 行列（行優先の入れ子の配列）

/// 4 × 4 行列。JSON では行優先（`m[row][col]`）の入れ子の配列。
/// simd は列優先（`columns[col][row]`）なので、書くときと読むときに入れ替える。
public struct Matrix4x4: Codable, Equatable, Sendable {
    public var simd: simd_double4x4

    public init(_ simd: simd_double4x4) {
        self.simd = simd
    }

    public init(rows: [[Double]]) throws {
        guard rows.count == 4, rows.allSatisfy({ $0.count == 4 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "4x4 行列ではありません"))
        }
        var m = simd_double4x4()
        for r in 0..<4 { for c in 0..<4 { m[c][r] = rows[r][c] } }
        simd = m
    }

    public var rows: [[Double]] {
        (0..<4).map { r in (0..<4).map { c in simd[c][r] } }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rows: try container.decode([[Double]].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rows)
    }

    public static func == (a: Matrix4x4, b: Matrix4x4) -> Bool { a.rows == b.rows }
}

/// 3 × 3 行列（カメラの K など）。JSON では行優先。
public struct Matrix3x3: Codable, Equatable, Sendable {
    public var simd: simd_double3x3

    public init(_ simd: simd_double3x3) {
        self.simd = simd
    }

    public init(rows: [[Double]]) throws {
        guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "3x3 行列ではありません"))
        }
        var m = simd_double3x3()
        for r in 0..<3 { for c in 0..<3 { m[c][r] = rows[r][c] } }
        simd = m
    }

    public var rows: [[Double]] {
        (0..<3).map { r in (0..<3).map { c in simd[c][r] } }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rows: try container.decode([[Double]].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rows)
    }

    public static func == (a: Matrix3x3, b: Matrix3x3) -> Bool { a.rows == b.rows }
}

/// 3 次元の点。JSON では `[x, y, z]`。
public struct Vector3: Codable, Equatable, Sendable {
    public var simd: SIMD3<Double>

    public init(_ simd: SIMD3<Double>) {
        self.simd = simd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        guard values.count == 3 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "[x, y, z] ではありません"))
        }
        simd = SIMD3(values[0], values[1], values[2])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([simd.x, simd.y, simd.z])
    }
}

// MARK: - Float → Double

extension Double {
    /// ARKit の Float を JSON 用の Double にする。`Double(Float(0.1))` は 0.10000000149011612 に
    /// なるので、Float の最短の 10 進表現を経由して読みやすい値にする（値の精度は Float のまま）。
    public init(cleaning value: Float) {
        if value.isFinite, let parsed = Double(value.description) {
            self = parsed
        } else {
            self = Double(value)
        }
    }
}

extension simd_double4x4 {
    public init(cleaning m: simd_float4x4) {
        self.init(columns: (
            SIMD4(Double(cleaning: m.columns.0.x), Double(cleaning: m.columns.0.y), Double(cleaning: m.columns.0.z), Double(cleaning: m.columns.0.w)),
            SIMD4(Double(cleaning: m.columns.1.x), Double(cleaning: m.columns.1.y), Double(cleaning: m.columns.1.z), Double(cleaning: m.columns.1.w)),
            SIMD4(Double(cleaning: m.columns.2.x), Double(cleaning: m.columns.2.y), Double(cleaning: m.columns.2.z), Double(cleaning: m.columns.2.w)),
            SIMD4(Double(cleaning: m.columns.3.x), Double(cleaning: m.columns.3.y), Double(cleaning: m.columns.3.z), Double(cleaning: m.columns.3.w))
        ))
    }

    /// 平行移動の部分（カメラの位置など）。
    public var translation: SIMD3<Double> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension simd_double3x3 {
    public init(cleaning m: simd_float3x3) {
        self.init(columns: (
            SIMD3(Double(cleaning: m.columns.0.x), Double(cleaning: m.columns.0.y), Double(cleaning: m.columns.0.z)),
            SIMD3(Double(cleaning: m.columns.1.x), Double(cleaning: m.columns.1.y), Double(cleaning: m.columns.1.z)),
            SIMD3(Double(cleaning: m.columns.2.x), Double(cleaning: m.columns.2.y), Double(cleaning: m.columns.2.z))
        ))
    }
}

// MARK: - 時刻（ISO 8601、タイムゾーン付き）

public enum ISODate {
    /// `2026-11-09T10:00:00+09:00` の形（UTC のときは `Z`）。
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone).format(date)
    }

    public static func parse(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(timeZoneSeparator: .colon).parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true).parse(string) { return date }
        return nil
    }
}

public enum SessionJSON {
    /// session.json を書くときのエンコーダー。キーは辞書順、整形あり、`/` はエスケープしない。
    public static func makeEncoder(timeZone: TimeZone = .current) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODate.string(date, timeZone: timeZone))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "ISO 8601 の時刻ではありません: \(text)")
            }
            return date
        }
        return decoder
    }
}
