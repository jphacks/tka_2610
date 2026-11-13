@testable import CaptureCore
import XCTest

/// 撮る人が選んだ・入力した大きさ（session.json の `declaredSize`）。
final class DeclaredSizeTests: XCTestCase {
    func testSheetPresetValues() {
        XCTAssertEqual(SheetPreset.allCases.map(\.rawValue), ["yatsugiri", "yotsugiri", "a4", "b4", "a3", "b5"])
        let expected: [SheetPreset: (String, Int, Int)] = [
            .yatsugiri: ("八つ切", 271, 392), .yotsugiri: ("四つ切", 392, 542), .a4: ("A4", 210, 297),
            .b4: ("B4", 257, 364), .a3: ("A3", 297, 420), .b5: ("B5", 182, 257),
        ]
        for preset in SheetPreset.allCases {
            let e = expected[preset]!
            XCTAssertEqual(preset.displayName, e.0)
            XCTAssertEqual(preset.shortSideMm, e.1)
            XCTAssertEqual(preset.longSideMm, e.2)
            XCTAssertLessThan(preset.shortSideM, preset.longSideM)
        }
        XCTAssertEqual(SheetPreset.yatsugiri.shortSideM, 0.271)
        XCTAssertEqual(SheetPreset.yatsugiri.longSideM, 0.392)
        XCTAssertEqual(SheetPreset.yatsugiri.label, "八つ切（27.1 × 39.2 cm）")
        let sheet = DeclaredSheet(.a4)
        XCTAssertEqual(sheet, DeclaredSheet(id: "a4", longSideM: 0.297, shortSideM: 0.21))
        XCTAssertEqual(sheet.preset, .a4)
        XCTAssertEqual(sheet.displayName, "A4")
        XCTAssertEqual(DeclaredSheet(id: "legal", longSideM: 0.5, shortSideM: 0.3).displayName, "legal")
    }

    private func session(_ kind: WorkKind, _ declared: DeclaredSize?) -> CaptureSession {
        CaptureSession(sessionId: "8B0F0000-0000-4000-8000-000000000001", title: "", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                       device: Fixtures.device, directionPlan: kind == .flat ? DirectionPlanPreset.flat1.plan : DirectionPlanPreset.ai5.plan,
                       workKind: kind, guidance: kind == .flat ? nil : .heading, declaredSize: declared)
    }

    func testJSONShapeAndRoundTrip() throws {
        let flat = session(.flat, DeclaredSize(sheet: DeclaredSheet(.yatsugiri)))
        let data = try SessionJSON.makeEncoder().encode(flat)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let declared = try XCTUnwrap(j["declaredSize"] as? [String: Any])
        XCTAssertEqual(Set(declared.keys), ["sheet", "heightM"])
        XCTAssertTrue(declared["heightM"] is NSNull)
        let sheet = try XCTUnwrap(declared["sheet"] as? [String: Any])
        XCTAssertEqual(Set(sheet.keys), ["id", "longSideM", "shortSideM"])
        XCTAssertEqual(sheet["id"] as? String, "yatsugiri")
        XCTAssertEqual(sheet["longSideM"] as? Double, 0.392)
        XCTAssertEqual(sheet["shortSideM"] as? Double, 0.271)
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data), flat)
        XCTAssertEqual(flat.declaredSheet?.id, "yatsugiri")
        XCTAssertNil(flat.declaredHeightM)

        let object = session(.object, DeclaredSize(heightM: 0.12))
        let data2 = try SessionJSON.makeEncoder().encode(object)
        let j2 = try XCTUnwrap(JSONSerialization.jsonObject(with: data2) as? [String: Any])
        let declared2 = try XCTUnwrap(j2["declaredSize"] as? [String: Any])
        XCTAssertTrue(declared2["sheet"] is NSNull)
        XCTAssertEqual(declared2["heightM"] as? Double, 0.12)
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data2), object)
        XCTAssertEqual(object.declaredHeightM, 0.12)
        XCTAssertNil(object.declaredSheet)

        // 入力していない：null を書く。
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionJSON.makeEncoder().encode(session(.object, nil))) as? [String: Any])
        XCTAssertTrue(none["declaredSize"] is NSNull)
    }

    private func decode(_ declaredJSON: String) throws -> CaptureSession {
        let text = """
        {"schema":"memoria.capture.session","schemaVersion":1,"sessionId":"8B0F0000-0000-4000-8000-000000000001","title":""\(declaredJSON),
         "workKind":"flat","createdAt":"2026-11-09T10:00:00+09:00","updatedAt":"2026-11-09T10:00:00+09:00","conventions":{},
         "device":{"model":"iPhone15,4","systemName":"iOS","systemVersion":"26.6","appVersion":"0.1.0","appBuild":"1"},
         "referenceFrames":[],"directionPlan":{"id":"flat1","targets":[]},"photos":[]}
        """
        return try SessionJSON.makeDecoder().decode(CaptureSession.self, from: Data(text.utf8))
    }

    func testMissingOrNullKeysReadAsNotEntered() throws {
        XCTAssertNil(try decode("").declaredSize)
        XCTAssertNil(try decode(#","declaredSize":null"#).declaredSize)
        // 中の項目のキーが無くても読める。
        let onlySheet = try decode(#","declaredSize":{"sheet":{"id":"a4","longSideM":0.297,"shortSideM":0.21}}"#)
        XCTAssertEqual(onlySheet.declaredSheet, DeclaredSheet(.a4))
        XCTAssertNil(onlySheet.declaredSize?.heightM)
        XCTAssertEqual(try decode(#","declaredSize":{}"#).declaredSize, DeclaredSize())
        XCTAssertThrowsError(try decode(#","declaredSize":{"sheet":{"id":"a4"}}"#))
    }

    func testNormalizedForWorkKind() {
        let both = DeclaredSize(sheet: DeclaredSheet(.a3), heightM: 0.1)
        XCTAssertEqual(both.normalized(for: .flat), DeclaredSize(sheet: DeclaredSheet(.a3)))
        XCTAssertEqual(both.normalized(for: .object), DeclaredSize(heightM: 0.1))
        XCTAssertNil(DeclaredSize(sheet: DeclaredSheet(.a3)).normalized(for: .object))
        XCTAssertNil(DeclaredSize(heightM: 0.1).normalized(for: .flat))
        XCTAssertNil(DeclaredSize().normalized(for: .flat))
        // セッションを作るときに合わせる。
        XCTAssertEqual(session(.flat, both).declaredSize, DeclaredSize(sheet: DeclaredSheet(.a3)))
        XCTAssertNil(session(.object, DeclaredSize(sheet: DeclaredSheet(.a3))).declaredSize)
        XCTAssertNil(session(.flat, DeclaredSize()).declaredSize)
    }

    func testOrientation() throws {
        let sheet = DeclaredSheet(.yatsugiri)
        let landscape = try XCTUnwrap(sheet.oriented(horizontal: 1000, vertical: 700))
        XCTAssertEqual(landscape.widthM, 0.392)
        XCTAssertEqual(landscape.heightM, 0.271)
        let portrait = try XCTUnwrap(sheet.oriented(horizontal: 700, vertical: 1000))
        XCTAssertEqual(portrait.widthM, 0.271)
        XCTAssertEqual(portrait.heightM, 0.392)
        let square = try XCTUnwrap(sheet.oriented(horizontal: 800, vertical: 800))
        XCTAssertEqual(square.widthM, 0.392)  // 横が縦以上なら横が長い辺
        XCTAssertNil(sheet.oriented(horizontal: 0, vertical: 800))
        XCTAssertNil(sheet.oriented(horizontal: .nan, vertical: 800))

        // 四隅（まっすぐに見たときの順）から：縦長の紙。
        let tall = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 600, y: 110),
                            bottomRight: PixelPoint(x: 610, y: 900), bottomLeft: PixelPoint(x: 95, y: 905))
        let fromCorners = try XCTUnwrap(sheet.oriented(corners: tall))
        XCTAssertEqual(fromCorners.widthM, 0.271)
        XCTAssertEqual(fromCorners.heightM, 0.392)
    }

    func testHeightInput() throws {
        XCTAssertEqual(DeclaredSize.heightM(fromCentimetres: "12"), 0.12)
        XCTAssertEqual(DeclaredSize.heightM(fromCentimetres: " 12.5 "), 0.125)
        XCTAssertEqual(DeclaredSize.heightM(fromCentimetres: "12,5"), 0.125)
        XCTAssertEqual(DeclaredSize.heightM(fromCentimetres: "１２．５"), 0.125)
        XCTAssertEqual(DeclaredSize.heightM(fromCentimetres: "0.5"), 0.005)
        XCTAssertEqual(DeclaredSize.heightM(fromCentimetres: "300"), 3.0)
        XCTAssertEqual(try XCTUnwrap(DeclaredSize.heightM(fromCentimetres: "7.123")), 0.0712, accuracy: 1e-12)
        for bad in ["", "  ", "0.4", "0", "-3", "300.1", "abc", "12cm", "nan", "inf"] {
            XCTAssertNil(DeclaredSize.heightM(fromCentimetres: bad), bad)
        }
    }

    func testCustomSheet() throws {
        let sheet = try XCTUnwrap(DeclaredSheet.custom(fromCentimetres: "30", "21"))
        XCTAssertEqual(sheet.id, "custom")
        XCTAssertTrue(sheet.isCustom)
        XCTAssertNil(sheet.preset)
        XCTAssertEqual(sheet.longSideM, 0.3)
        XCTAssertEqual(sheet.shortSideM, 0.21)
        XCTAssertEqual(sheet.displayName, "その他")
        XCTAssertEqual(sheet.labelWithSize, "その他（21.0 × 30.0 cm）")
        // 縦・横の順は問わない（長い辺は大きい方）。
        XCTAssertEqual(DeclaredSheet.custom(fromCentimetres: "21", "30"), sheet)
        XCTAssertEqual(DeclaredSheet.custom(fromCentimetres: "２１，５", " 30 ")?.shortSideM, 0.215)
        XCTAssertEqual(DeclaredSheet.custom(fromCentimetres: "1", "300")?.longSideM, 3.0)
        for (a, b) in [("", "30"), ("21", ""), ("0.9", "30"), ("21", "300.1"), ("abc", "30"), ("-21", "30")] {
            XCTAssertNil(DeclaredSheet.custom(fromCentimetres: a, b), "\(a) × \(b)")
        }
        XCTAssertEqual(DeclaredSheet(.yatsugiri).labelWithSize, "八つ切（27.1 × 39.2 cm）")
        // 向きの決め方は一覧の紙と同じ。
        let portrait = try XCTUnwrap(sheet.oriented(horizontal: 700, vertical: 1000))
        XCTAssertEqual(portrait.widthM, 0.21)
        XCTAssertEqual(portrait.heightM, 0.3)
        // session.json では id "custom" のまま読み書きする。
        let flat = session(.flat, DeclaredSize(sheet: sheet))
        let data = try SessionJSON.makeEncoder().encode(flat)
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data).declaredSheet, sheet)
    }

    func testRectifiedSizeUsesDeclaredSheet() throws {
        let landscapeQuad = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 1100, y: 100),
                                     bottomRight: PixelPoint(x: 1100, y: 800), bottomLeft: PixelPoint(x: 100, y: 800))
        let declared = DeclaredSheet(.yatsugiri)
        let out = try XCTUnwrap(FlatGeometry.rectifiedSize(corners: landscapeQuad, size: nil, declaredSheet: declared))
        XCTAssertEqual(out.width, 1000)
        XCTAssertEqual(out.height, Int((1000 / (0.392 / 0.271)).rounded()))
        // 選んだ紙は測った実寸より優先する（向きは四隅で決める）。
        let measured = FlatSheetSize(widthM: 0.297, heightM: 0.21, planeSource: "estimatedPlane")
        let both = try XCTUnwrap(FlatGeometry.rectifiedSize(corners: landscapeQuad, size: measured, declaredSheet: declared))
        XCTAssertEqual(both.width, out.width)
        XCTAssertEqual(both.height, out.height)
        // 選んでいなければ今までどおり。
        let old = try XCTUnwrap(FlatGeometry.rectifiedSize(corners: landscapeQuad, size: measured))
        XCTAssertEqual(old.height, Int((1000 / (0.297 / 0.21)).rounded()))
        // 縦長の四隅：横が短い辺。
        let portraitQuad = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 800, y: 100),
                                    bottomRight: PixelPoint(x: 800, y: 1100), bottomLeft: PixelPoint(x: 100, y: 1100))
        let tall = try XCTUnwrap(FlatGeometry.rectifiedSize(corners: portraitQuad, size: nil, declaredSheet: declared))
        XCTAssertEqual(tall.height, 1000)
        XCTAssertEqual(tall.width, Int((1000 * 0.271 / 0.392).rounded()))
    }
}

final class DeclaredSizeStoreTests: XCTestCase {
    var root: URL!
    var store: SessionStore!

    override func setUp() {
        root = Fixtures.tempDirectory()
        store = SessionStore(rootDirectory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateSessionKeepsDeclaredSize() throws {
        let flat = try store.createSession(title: "えのぐの絵", device: Fixtures.device, plan: DirectionPlanPreset.flat1.plan, workKind: .flat,
                                           declaredSize: DeclaredSize(sheet: DeclaredSheet(.yotsugiri)))
        XCTAssertEqual(try store.loadSession(flat.sessionId).declaredSheet, DeclaredSheet(.yotsugiri))

        let object = try store.createSession(title: "はこ", device: Fixtures.device, plan: DirectionPlanPreset.ai5.plan, workKind: .object,
                                             guidance: .heading, declaredSize: DeclaredSize(heightM: 0.12))
        let loaded = try store.loadSession(object.sessionId)
        XCTAssertEqual(loaded.declaredHeightM, 0.12)
        XCTAssertEqual(loaded.guidance, .heading)

        // 今までの呼び方（大きさを渡さない）は null。
        let plain = try store.createSession(title: "", device: Fixtures.device, plan: DirectionPlanPreset.ai5.plan)
        XCTAssertNil(try store.loadSession(plain.sessionId).declaredSize)
    }
}
