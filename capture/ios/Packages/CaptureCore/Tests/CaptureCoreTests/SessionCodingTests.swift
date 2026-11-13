@testable import CaptureCore
import simd
import XCTest

final class SessionCodingTests: XCTestCase {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// docs/data-format.md の例と同じ形のセッション。
    private func exampleSession() -> CaptureSession {
        let created = ISODate.parse("2026-11-09T10:00:00+09:00")!
        var s = CaptureSession(sessionId: "8B0F0000-0000-4000-8000-000000000001", title: "ねこの貯金箱", createdAt: created, device: Fixtures.device, directionPlan: DirectionPlanPreset.ring8.plan)
        s.object = ObjectSize(heightM: 0.15, radiusM: 0.08)
        var ref = ReferenceFrame(id: "ref-1", createdAt: created, basePointWorld: SIMD3(0.1, -0.7, -0.4))
        ref.objectToWorld = try! Matrix4x4(rows: [[1, 0, 0, 0.1], [0, 1, 0, -0.7], [0, 0, 1, -0.4], [0, 0, 0, 1]])
        ref.frontPhotoId = "11111111-0000-4000-8000-000000000001"
        s.referenceFrames = [ref]
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0.2, -0.5, 0.1, 1)
        let photo = Photo(
            photoId: "11111111-0000-4000-8000-000000000001", sequence: 1, capturedAt: created, trigger: .auto, referenceFrameId: "ref-1",
            image: ImageInfo(file: "photos/11111111-0000-4000-8000-000000000001.jpg", width: 4032, height: 3024, displayRotationDegClockwise: 90, deviceOrientation: "portrait"),
            camera: CameraInfo(
                arFrameTimestamp: 12345.678, cameraToWorld: Matrix4x4(camera),
                intrinsics: try! Matrix3x3(rows: [[2900, 0, 2016], [0, 2900, 1512], [0, 0, 1]]),
                intrinsicsResolution: PixelSize(width: 4032, height: 3024), exposureDurationS: 0.01, exposureOffsetEV: nil,
                trackingState: .normal, trackingReason: nil
            ),
            direction: DirectionInfo(confirmed: true, unconfirmedReason: nil, targetId: "a000-e20", azimuthDeg: 3.2, elevationDeg: 21.0, distanceM: 0.42),
            quality: PhotoQuality(
                live: LiveQualityRecord(tracking: .ok, inFrame: .ok, direction: .ok, motion: .ok, brightness: .ok, sharpness: .warning, warningsAcknowledged: true),
                saved: SavedQuality(meanLuma: 0.46, sharpness: 0.0021, brightness: .ok, blur: .ok)
            ),
            mask: MaskInfo(status: .candidate, file: "masks/11111111-0000-4000-8000-000000000001.png", width: 4032, height: 3024, method: MaskInfo.visionMethod, instanceCount: 2, selectedInstances: [1], selection: .auto, error: nil)
        )
        s.photos = [photo]
        return s
    }

    private func json(_ s: CaptureSession) throws -> [String: Any] {
        let data = try SessionJSON.makeEncoder(timeZone: tokyo).encode(s)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTopLevelKeysAndValues() throws {
        let j = try json(exampleSession())
        XCTAssertEqual(Set(j.keys), ["schema", "schemaVersion", "sessionId", "title", "workKind", "createdAt", "updatedAt", "conventions", "device", "object", "referenceFrames", "directionPlan", "photos", "guidance", "declaredSize"])
        XCTAssertTrue(j["guidance"] is NSNull)  // 後から足した項目。null（と無い）は前の方法（baseCylinder）
        XCTAssertTrue(j["declaredSize"] is NSNull)  // 後から足した項目。null（と無い）は「入力していない」
        XCTAssertEqual(j["schema"] as? String, "memoria.capture.session")
        XCTAssertEqual(j["workKind"] as? String, "object")  // 後から足した項目。いつも書く
        XCTAssertEqual(j["schemaVersion"] as? Int, 1)
        XCTAssertEqual(j["createdAt"] as? String, "2026-11-09T10:00:00+09:00")
        let device = try XCTUnwrap(j["device"] as? [String: Any])
        XCTAssertEqual(Set(device.keys), ["model", "systemName", "systemVersion", "appVersion", "appBuild"])
        let object = try XCTUnwrap(j["object"] as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "userAdjusted")
        let conventions = try XCTUnwrap(j["conventions"] as? [String: String])
        XCTAssertTrue(conventions["matrices"]?.contains("行優先") ?? false)
        let plan = try XCTUnwrap(j["directionPlan"] as? [String: Any])
        XCTAssertEqual(plan["id"] as? String, "ring8")
        let target = try XCTUnwrap((plan["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(target.keys), ["id", "azimuthDeg", "elevationDeg", "azimuthToleranceDeg", "elevationToleranceDeg", "anyAzimuth"])
        XCTAssertEqual(target["anyAzimuth"] as? Bool, false)
        XCTAssertEqual(target["id"] as? String, "a000-e20")
    }

    func testReferenceFrameNullsAndRowMajor() throws {
        var s = exampleSession()
        let j = try json(s)
        let ref = try XCTUnwrap((j["referenceFrames"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(ref.keys), ["id", "createdAt", "basePointWorld", "objectToWorld", "frontPhotoId", "invalidatedAt", "invalidationReason", "object", "base", "heading"])
        XCTAssertTrue(ref["heading"] is NSNull)  // 向きで案内した基準だけ
        XCTAssertTrue(ref["object"] is NSNull)  // この項目より前の基準と同じ（セッションの object を使う）
        XCTAssertTrue(ref["base"] is NSNull)  // 基準点の求め方を記録する前の基準と同じ
        XCTAssertEqual(ref["basePointWorld"] as? [Double], [0.1, -0.7, -0.4])
        let m = try XCTUnwrap(ref["objectToWorld"] as? [[Double]])
        XCTAssertEqual(m[0], [1, 0, 0, 0.1])  // 行優先：平行移動は各行の最後
        XCTAssertEqual(m[3], [0, 0, 0, 1])
        XCTAssertTrue(ref["invalidatedAt"] is NSNull)
        XCTAssertTrue(ref["invalidationReason"] is NSNull)

        // 正面が決まる前・無効にしたあと。
        s.referenceFrames[0].objectToWorld = nil
        s.referenceFrames[0].frontPhotoId = nil
        s.referenceFrames[0].invalidatedAt = ISODate.parse("2026-11-09T10:05:00+09:00")
        s.referenceFrames[0].invalidationReason = .anchorDrift
        let j2 = try json(s)
        let ref2 = try XCTUnwrap((j2["referenceFrames"] as? [[String: Any]])?.first)
        XCTAssertTrue(ref2["objectToWorld"] is NSNull)
        XCTAssertTrue(ref2["frontPhotoId"] is NSNull)
        XCTAssertEqual(ref2["invalidationReason"] as? String, "anchorDrift")
        XCTAssertEqual(ref2["invalidatedAt"] as? String, "2026-11-09T10:05:00+09:00")
    }

    func testPhotoKeysNullsAndMatrices() throws {
        let j = try json(exampleSession())
        let photo = try XCTUnwrap((j["photos"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(photo.keys), ["photoId", "sequence", "capturedAt", "trigger", "referenceFrameId", "image", "camera", "direction", "quality", "mask", "flat", "heading"])
        XCTAssertTrue(photo["flat"] is NSNull)  // 立体の作品の写真
        XCTAssertTrue(photo["heading"] is NSNull)  // 向きで案内した写真だけ
        let image = try XCTUnwrap(photo["image"] as? [String: Any])
        XCTAssertEqual(Set(image.keys), ["file", "format", "width", "height", "exifOrientation", "displayRotationDegClockwise", "deviceOrientation"])
        XCTAssertEqual(image["format"] as? String, "jpeg")
        XCTAssertEqual(image["exifOrientation"] as? Int, 1)
        let camera = try XCTUnwrap(photo["camera"] as? [String: Any])
        XCTAssertEqual(Set(camera.keys), ["source", "arFrameTimestamp", "cameraToWorld", "intrinsics", "intrinsicsResolution", "exposureDurationS", "exposureOffsetEV", "trackingState", "trackingReason"])
        XCTAssertEqual(camera["source"] as? String, "captureHighResolutionFrame")
        XCTAssertTrue(camera["exposureOffsetEV"] is NSNull)
        XCTAssertTrue(camera["trackingReason"] is NSNull)
        let k = try XCTUnwrap(camera["intrinsics"] as? [[Double]])
        XCTAssertEqual(k, [[2900, 0, 2016], [0, 2900, 1512], [0, 0, 1]])
        let c2w = try XCTUnwrap(camera["cameraToWorld"] as? [[Double]])
        XCTAssertEqual(c2w[0][3], 0.2)
        XCTAssertEqual(c2w[1][3], -0.5)
        XCTAssertEqual(c2w[3], [0, 0, 0, 1])
        let res = try XCTUnwrap(camera["intrinsicsResolution"] as? [String: Int])
        XCTAssertEqual(res, ["width": 4032, "height": 3024])
        let direction = try XCTUnwrap(photo["direction"] as? [String: Any])
        XCTAssertEqual(Set(direction.keys), ["confirmed", "unconfirmedReason", "targetId", "azimuthDeg", "elevationDeg", "distanceM"])
        XCTAssertTrue(direction["unconfirmedReason"] is NSNull)
        let quality = try XCTUnwrap(photo["quality"] as? [String: Any])
        let live = try XCTUnwrap(quality["live"] as? [String: Any])
        XCTAssertEqual(Set(live.keys), ["tracking", "inFrame", "direction", "motion", "brightness", "sharpness", "warningsAcknowledged"])
        XCTAssertEqual(live["sharpness"] as? String, "warning")
        let saved = try XCTUnwrap(quality["saved"] as? [String: Any])
        XCTAssertEqual(Set(saved.keys), ["meanLuma", "sharpness", "brightness", "blur"])
        let mask = try XCTUnwrap(photo["mask"] as? [String: Any])
        XCTAssertEqual(Set(mask.keys), ["status", "file", "width", "height", "method", "instanceCount", "selectedInstances", "selection", "error", "inputRegion", "inputRegionSource", "check"])
        XCTAssertTrue(mask["check"] is NSNull)
        XCTAssertEqual(mask["method"] as? String, "VNGenerateForegroundInstanceMaskRequest")
        XCTAssertTrue(mask["error"] is NSNull)
    }

    func testNotGeneratedMaskAndMissingSavedAreNull() throws {
        var s = exampleSession()
        s.photos[0].mask = .notGenerated
        s.photos[0].quality.saved = nil
        s.photos[0].referenceFrameId = nil
        s.object = nil
        let j = try json(s)
        XCTAssertTrue(j["object"] is NSNull)
        let photo = try XCTUnwrap((j["photos"] as? [[String: Any]])?.first)
        XCTAssertTrue(photo["referenceFrameId"] is NSNull)
        let mask = try XCTUnwrap(photo["mask"] as? [String: Any])
        XCTAssertEqual(mask["status"] as? String, "notGenerated")
        XCTAssertTrue(mask["file"] is NSNull)
        XCTAssertTrue(mask["width"] is NSNull)
        XCTAssertEqual(mask["selectedInstances"] as? [Int], [])
        let quality = try XCTUnwrap(photo["quality"] as? [String: Any])
        XCTAssertTrue(quality["saved"] is NSNull)
    }

    func testRoundTrip() throws {
        let s = exampleSession()
        let data = try SessionJSON.makeEncoder(timeZone: tokyo).encode(s)
        let decoded = try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data)
        XCTAssertEqual(decoded, s)
        // もう一度書いても同じバイト列（キーの順が安定）。
        XCTAssertEqual(try SessionJSON.makeEncoder(timeZone: tokyo).encode(decoded), data)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("\\/"))
    }

    func testDecodeToleratesMissingOptionalKeysAndFractionalDates() throws {
        let text = """
        {"schema":"memoria.capture.session","schemaVersion":1,"sessionId":"8B0F0000-0000-4000-8000-000000000001","title":"",
         "createdAt":"2026-11-09T01:00:00.123Z","updatedAt":"2026-11-09T10:00:00+09:00","conventions":{},
         "device":{"model":"iPhone15,4","systemName":"iOS","systemVersion":"26.6","appVersion":"0.1.0","appBuild":"1"},
         "referenceFrames":[{"id":"ref-1","createdAt":"2026-11-09T10:00:00+09:00","basePointWorld":[0,0,0]}],
         "directionPlan":{"id":"ring8","targets":[{"id":"a000-e20","azimuthDeg":0,"elevationDeg":20,"azimuthToleranceDeg":20,"elevationToleranceDeg":15}]},"photos":[]}
        """
        let s = try SessionJSON.makeDecoder().decode(CaptureSession.self, from: Data(text.utf8))
        XCTAssertNil(s.object)
        XCTAssertNil(s.declaredSize)  // declaredSize の無い前の版のセッションは「入力していない」
        // workKind の無い前の版のセッションは立体、flat の無い写真は null。
        XCTAssertEqual(s.workKind, .object)
        XCTAssertFalse(s.isFlat)
        // anyAzimuth の無い前の版の方向は、方位で当てはめる方向。
        XCTAssertEqual(s.directionPlan.targets.map(\.anyAzimuth), [false])
        XCTAssertNil(s.referenceFrames[0].objectToWorld)
        XCTAssertTrue(s.referenceFrames[0].isValid)
    }

    func testFloatCleaning() {
        XCTAssertEqual(Double(cleaning: Float(0.1)), 0.1)
        XCTAssertEqual(Double(cleaning: Float(-0.7)), -0.7)
    }
}

final class PhotoRecorderTests: XCTestCase {
    let base = SIMD3<Double>(0.1, -0.7, -0.4)

    func testFirstConfirmedPhotoDefinesFront() {
        var s = Fixtures.session(base: base)
        let position = base + SIMD3(0, 0.075 + 0.15, 0.4)
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: position, to: base))
        let photo = PhotoRecorder.makePhoto(in: &s, photoId: "11111111-0000-4000-8000-000000000001", sequence: 1, frame: frame, context: Fixtures.context(ref: "ref-1"))
        XCTAssertTrue(photo.direction.confirmed)
        XCTAssertEqual(photo.direction.azimuthDeg, 0)
        XCTAssertEqual(photo.direction.targetId, "a000-e20")
        XCTAssertNotNil(s.referenceFrames[0].objectToWorld)
        XCTAssertEqual(s.referenceFrames[0].frontPhotoId, photo.photoId)
        XCTAssertEqual(photo.image.file, "photos/11111111-0000-4000-8000-000000000001.jpg")
        XCTAssertEqual(photo.camera.intrinsicsResolution, PixelSize(width: 1920, height: 1440))

        // 2 枚目：右（+X 側）へ 90° 回った位置。
        let side = base + SIMD3(0.4, 0.075 + 0.15, 0)
        let photo2 = PhotoRecorder.makePhoto(in: &s, photoId: "11111111-0000-4000-8000-000000000002", sequence: 2, frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: side, to: base)), context: Fixtures.context(ref: "ref-1"))
        XCTAssertTrue(photo2.direction.confirmed)
        XCTAssertEqual(photo2.direction.azimuthDeg ?? -1, 90, accuracy: 0.01)
        XCTAssertEqual(photo2.direction.targetId, "a090-e20")
        XCTAssertEqual(s.referenceFrames[0].frontPhotoId, photo.photoId)  // 正面は変わらない
    }

    func testLimitedTrackingPhotoIsUnconfirmedAndDoesNotDefineFront() {
        var s = Fixtures.session(base: base)
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: base + SIMD3(0, 0.2, 0.4), to: base), tracking: .limited, reason: .excessiveMotion)
        let photo = PhotoRecorder.makePhoto(in: &s, photoId: SessionStore.newId(), sequence: 1, frame: frame, context: Fixtures.context(ref: "ref-1"))
        XCTAssertFalse(photo.direction.confirmed)
        XCTAssertEqual(photo.direction.unconfirmedReason, .trackingNotNormal)
        XCTAssertNil(photo.direction.azimuthDeg)
        XCTAssertNotNil(photo.direction.elevationDeg)
        XCTAssertNil(s.referenceFrames[0].objectToWorld)
        XCTAssertEqual(photo.camera.trackingReason, .excessiveMotion)
    }

    func testNoReferenceAndInvalidatedReference() {
        var s = Fixtures.session(base: base)
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: base + SIMD3(0, 0.2, 0.4), to: base))
        let noRef = PhotoRecorder.makePhoto(in: &s, photoId: SessionStore.newId(), sequence: 1, frame: frame, context: Fixtures.context(ref: nil))
        XCTAssertFalse(noRef.direction.confirmed)
        XCTAssertEqual(noRef.direction.unconfirmedReason, .noReference)
        XCTAssertNil(noRef.referenceFrameId)

        s.referenceFrames[0].invalidatedAt = Date()
        s.referenceFrames[0].invalidationReason = .trackingLost
        let invalid = PhotoRecorder.makePhoto(in: &s, photoId: SessionStore.newId(), sequence: 2, frame: frame, context: Fixtures.context(ref: "ref-1"))
        XCTAssertFalse(invalid.direction.confirmed)
        XCTAssertEqual(invalid.direction.unconfirmedReason, .referenceInvalidated)
        XCTAssertNil(s.referenceFrames[0].objectToWorld)
    }
}
