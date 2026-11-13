@testable import CaptureCore
import simd
import XCTest

final class CoverageTests: XCTestCase {
    let plan = DirectionPlanPreset.ring8.plan

    func testPresets() {
        XCTAssertEqual(DirectionPlanPreset.ring8.plan.targets.map(\.azimuthDeg), [0, 45, 90, 135, 180, 225, 270, 315])
        XCTAssertEqual(DirectionPlanPreset.ring8.plan.targets.first?.id, "a000-e20")
        XCTAssertEqual(DirectionPlanPreset.ring8.plan.targets.first?.azimuthToleranceDeg, 20)
        XCTAssertEqual(DirectionPlanPreset.ring8.plan.targets.first?.elevationToleranceDeg, 15)
        XCTAssertEqual(DirectionPlanPreset.ring4.plan.targets.map(\.id), ["a000-e20", "a090-e20", "a180-e20", "a270-e20"])
        let high = DirectionPlanPreset.ring8plusHigh.plan.targets
        XCTAssertEqual(high.count, 12)
        XCTAssertEqual(high.suffix(4).map(\.id), ["a000-e50", "a090-e50", "a180-e50", "a270-e50"])
    }

    func testMatchWithWrapAround() {
        XCTAssertEqual(Coverage.match(azimuthDeg: 350, elevationDeg: 20, plan: plan)?.id, "a000-e20")
        XCTAssertEqual(Coverage.match(azimuthDeg: 10, elevationDeg: 25, plan: plan)?.id, "a000-e20")
        XCTAssertEqual(Coverage.match(azimuthDeg: 334, elevationDeg: 20, plan: plan)?.id, "a315-e20")
        XCTAssertNil(Coverage.match(azimuthDeg: 339, elevationDeg: 20, plan: plan))  // 315 から 24°、0 から 21°
        // 方位は合うが仰角が外れている。
        XCTAssertNil(Coverage.match(azimuthDeg: 0, elevationDeg: 40, plan: plan))
        XCTAssertNil(Coverage.match(azimuthDeg: nil, elevationDeg: 20, plan: plan))
        // 2 つの間（22.5°）はどちらの許容（±20°）にも入らない。
        XCTAssertNil(Coverage.match(azimuthDeg: 22.5, elevationDeg: 20, plan: plan))
        XCTAssertEqual(Coverage.match(azimuthDeg: 26, elevationDeg: 20, plan: plan)?.id, "a045-e20")
        // 許容が重なるときは近い方、同じ近さなら一覧の順で先。
        let wide = DirectionPlan(id: "wide", targets: [
            DirectionTarget.make(azimuthDeg: 0, elevationDeg: 20, azimuthTolerance: 40, elevationTolerance: 15),
            DirectionTarget.make(azimuthDeg: 45, elevationDeg: 20, azimuthTolerance: 40, elevationTolerance: 15),
        ])
        XCTAssertEqual(Coverage.match(azimuthDeg: 22.5, elevationDeg: 20, plan: wide)?.id, "a000-e20")
        XCTAssertEqual(Coverage.match(azimuthDeg: 23, elevationDeg: 20, plan: wide)?.id, "a045-e20")
    }

    func testMatchPrefersElevationInHighPlan() {
        let high = DirectionPlanPreset.ring8plusHigh.plan
        XCTAssertEqual(Coverage.match(azimuthDeg: 0, elevationDeg: 45, plan: high)?.id, "a000-e50")
        XCTAssertEqual(Coverage.match(azimuthDeg: 0, elevationDeg: 30, plan: high)?.id, "a000-e20")
    }

    private func photo(ref: String?, confirmed: Bool, target: String?) -> Photo {
        Photo(
            photoId: SessionStore.newId(), sequence: 1, capturedAt: Date(), trigger: .auto, referenceFrameId: ref,
            image: ImageInfo(file: "photos/x.jpg", width: 1, height: 1, displayRotationDegClockwise: 90, deviceOrientation: "portrait"),
            camera: CameraInfo(arFrameTimestamp: 0, cameraToWorld: Matrix4x4(matrix_identity_double4x4), intrinsics: Matrix3x3(matrix_identity_double3x3), intrinsicsResolution: PixelSize(width: 1, height: 1), exposureDurationS: nil, exposureOffsetEV: nil, trackingState: .normal, trackingReason: nil),
            direction: DirectionInfo(confirmed: confirmed, unconfirmedReason: confirmed ? nil : .trackingNotNormal, targetId: target, azimuthDeg: 0, elevationDeg: 20, distanceM: 0.4),
            quality: PhotoQuality(live: .unknown), mask: .notGenerated
        )
    }

    func testCoverageCountsOnlyConfirmedPhotosInCurrentValidReference() {
        var s = Fixtures.session()
        s.referenceFrames[0].invalidatedAt = Date()
        s.referenceFrames[0].invalidationReason = .sessionInterrupted
        s.referenceFrames.append(ReferenceFrame(id: "ref-2", createdAt: Date(), basePointWorld: .zero))
        s.photos = [
            photo(ref: "ref-1", confirmed: true, target: "a000-e20"),   // 前の基準
            photo(ref: "ref-2", confirmed: false, target: "a045-e20"),  // 参考値
            photo(ref: "ref-2", confirmed: true, target: "a090-e20"),
            photo(ref: nil, confirmed: false, target: nil),
        ]
        XCTAssertEqual(Coverage.coveredTargetIds(in: s), ["a090-e20"])

        // 今の基準も無効になったら何も数えない。
        s.referenceFrames[1].invalidatedAt = Date()
        XCTAssertEqual(Coverage.coveredTargetIds(in: s), [])
    }

    func testNextTargetIsNearestUncoveredWithStableTies() {
        // 今 100°。45° と 135° は同じ近さ → 一覧の順で 45°。
        let next = Coverage.nextTarget(plan: plan, covered: ["a090-e20"], currentAzimuthDeg: 90, currentElevationDeg: 20)
        XCTAssertEqual(next?.id, "a045-e20")
        // 360° をまたぐ。
        let wrap = Coverage.nextTarget(plan: plan, covered: ["a000-e20"], currentAzimuthDeg: 350, currentElevationDeg: 20)
        XCTAssertEqual(wrap?.id, "a315-e20")
        // 撮り直しの方向を優先。
        let preferred = Coverage.nextTarget(plan: plan, covered: [], currentAzimuthDeg: 0, currentElevationDeg: 20, preferredTargetId: "a180-e20")
        XCTAssertEqual(preferred?.id, "a180-e20")
        // 方位が分からなければ一覧の最初の未撮影。
        XCTAssertEqual(Coverage.nextTarget(plan: plan, covered: ["a000-e20"], currentAzimuthDeg: nil, currentElevationDeg: nil)?.id, "a045-e20")
        // 全部撮った。
        XCTAssertNil(Coverage.nextTarget(plan: plan, covered: Set(plan.targets.map(\.id)), currentAzimuthDeg: 0, currentElevationDeg: 20))
    }

    func testGuidanceDirectionWords() throws {
        let base = SIMD3<Double>(0, 0, 0)
        let m = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: SIMD3(0, 0, 1)))
        // 正面（0°）は撮影済み → 次は 45°（右）。
        let position = Fixtures.position(base: base, height: 0.15, azimuth: 0, elevation: 20, distance: 0.5)
        let ctx = DirectionContext.make(cameraPosition: position, basePoint: base, heightM: 0.15, objectToWorld: m, plan: plan, covered: ["a000-e20"])
        XCTAssertEqual(ctx.matchedTarget?.id, "a000-e20")
        XCTAssertTrue(ctx.matchedTargetCovered)
        XCTAssertEqual(ctx.nextTarget?.id, "a045-e20")
        XCTAssertTrue(ctx.guidance.contains("右"), ctx.guidance)
        // 0° と 45° を撮った、今 10° → 次は 315°（左）。
        let ctx2 = DirectionContext.make(
            cameraPosition: Fixtures.position(base: base, height: 0.15, azimuth: 10, elevation: 20, distance: 0.5),
            basePoint: base, heightM: 0.15, objectToWorld: m, plan: plan, covered: ["a000-e20", "a045-e20"]
        )
        XCTAssertEqual(ctx2.nextTarget?.id, "a315-e20")
        XCTAssertTrue(ctx2.guidance.contains("左"), ctx2.guidance)
        // 方位は合っているが低すぎる → 上から。
        let ctx3 = DirectionContext.make(
            cameraPosition: Fixtures.position(base: base, height: 0.15, azimuth: 45, elevation: -10, distance: 0.5),
            basePoint: base, heightM: 0.15, objectToWorld: m, plan: plan, covered: ["a000-e20"]
        )
        XCTAssertNil(ctx3.matchedTarget)
        XCTAssertTrue(ctx3.guidance.contains("上から"), ctx3.guidance)
    }
}
