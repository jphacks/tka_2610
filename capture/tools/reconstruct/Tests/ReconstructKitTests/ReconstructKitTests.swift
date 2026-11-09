import XCTest
import simd
import CaptureCore
@testable import ReconstructKit

final class ReconstructKitTests: XCTestCase {
    // MARK: - Fixtures

    let plan = DirectionPlan(id: "test", targets: [
        DirectionTarget(id: "a000-e20", azimuthDeg: 0, elevationDeg: 20, azimuthToleranceDeg: 20, elevationToleranceDeg: 15),
    ])

    func photo(_ seq: Int, mask: MaskInfo, confirmed: Bool = true, target: String? = "a000-e20",
               cameraToWorld: simd_double4x4 = matrix_identity_double4x4, fx: Double = 3067.4) -> Photo {
        let id = String(format: "00000000-0000-4000-8000-%012d", seq)
        return Photo(
            photoId: id, sequence: seq, capturedAt: Date(timeIntervalSince1970: Double(seq)), trigger: .auto,
            referenceFrameId: confirmed ? "ref-1" : nil,
            image: ImageInfo(file: Photo.imagePath(photoId: id), width: 4032, height: 3024, displayRotationDegClockwise: 90, deviceOrientation: "portrait"),
            camera: CameraInfo(arFrameTimestamp: 0, cameraToWorld: Matrix4x4(cameraToWorld),
                               intrinsics: Matrix3x3(simd_double3x3(rows: [SIMD3(fx, 0, 2016), SIMD3(0, fx, 1512), SIMD3(0, 0, 1)])),
                               intrinsicsResolution: PixelSize(width: 4032, height: 3024),
                               exposureDurationS: nil, exposureOffsetEV: nil, trackingState: .normal, trackingReason: nil),
            direction: DirectionInfo(confirmed: confirmed, unconfirmedReason: confirmed ? nil : .noReference, targetId: confirmed ? target : nil,
                                     azimuthDeg: nil, elevationDeg: nil, distanceM: nil),
            quality: PhotoQuality(live: .unknown),
            mask: mask
        )
    }

    func candidate(_ id: Int, check: MaskCheckStatus?) -> MaskInfo {
        MaskInfo(status: .candidate, file: Photo.maskPath(photoId: String(format: "00000000-0000-4000-8000-%012d", id)),
                 width: 4032, height: 3024, check: check.map { MaskCheck(status: $0, reasons: $0 == .ok ? [] : [.tooLarge]) })
    }

    func session(_ photos: [Photo]) -> CaptureSession {
        var s = CaptureSession(sessionId: "S", title: "", createdAt: Date(timeIntervalSince1970: 0),
                               device: DeviceInfo(model: "", systemName: "iOS", systemVersion: "", appVersion: "", appBuild: ""),
                               directionPlan: plan)
        s.referenceFrames = [ReferenceFrame(id: "ref-1", createdAt: Date(timeIntervalSince1970: 0), basePointWorld: .zero)]
        s.photos = photos
        return s
    }

    // MARK: - Masks and inclusion

    func testAutoMaskRule() {
        XCTAssertTrue(InputPlanner.autoMaskDecision(photo(1, mask: MaskInfo(status: .confirmed, file: "m"))).use)
        XCTAssertTrue(InputPlanner.autoMaskDecision(photo(1, mask: candidate(1, check: nil))).use)
        XCTAssertTrue(InputPlanner.autoMaskDecision(photo(1, mask: candidate(1, check: .ok))).use)
        XCTAssertFalse(InputPlanner.autoMaskDecision(photo(1, mask: candidate(1, check: .suspicious))).use)
        XCTAssertFalse(InputPlanner.autoMaskDecision(photo(1, mask: candidate(1, check: .unknown))).use)
        XCTAssertFalse(InputPlanner.autoMaskDecision(photo(1, mask: MaskInfo(status: .noObject))).use)
        XCTAssertFalse(InputPlanner.autoMaskDecision(photo(1, mask: MaskInfo(status: .failed))).use)
    }

    func testPlanAllKeepsPhotosWithoutUsableMask() {
        let s = session([photo(1, mask: candidate(1, check: .suspicious)), photo(2, mask: MaskInfo(status: .noObject))])
        var options = Options(session: "S")
        options.masks = .auto
        let planned = InputPlanner.plan(session: s, folder: URL(fileURLWithPath: "/x"), options: options, fileExists: { _ in true })
        XCTAssertEqual(planned.map(\.included), [true, true])
        XCTAssertEqual(planned.map(\.maskUsed), [false, false])

        options.masks = .on
        let on = InputPlanner.plan(session: s, folder: URL(fileURLWithPath: "/x"), options: options, fileExists: { _ in true })
        XCTAssertEqual(on.map(\.maskUsed), [true, false])
    }

    func testIncludeGoodExcludesUnconfirmedBadMaskAndSuperseded() {
        let s = session([
            photo(1, mask: candidate(1, check: .ok)),                       // superseded by #3
            photo(2, mask: candidate(2, check: .ok), confirmed: false),     // direction not confirmed
            photo(3, mask: candidate(3, check: .ok)),                       // representative
            photo(4, mask: candidate(4, check: .suspicious)),               // no usable mask
        ])
        var options = Options(session: "S")
        options.include = .good
        let planned = InputPlanner.plan(session: s, folder: URL(fileURLWithPath: "/x"), options: options, fileExists: { _ in true })
        XCTAssertEqual(planned.map(\.included), [false, false, true, false])
        XCTAssertTrue(planned[0].exclusionReason!.contains("superseded by #3"))
        XCTAssertTrue(planned[1].exclusionReason!.contains("direction not confirmed"))
        XCTAssertTrue(planned[3].exclusionReason!.contains("no usable mask"))
        XCTAssertTrue(planned.allSatisfy { $0.included || $0.exclusionReason != nil })
    }

    func testFramesFilterAndMissingImage() {
        let s = session([photo(1, mask: candidate(1, check: .ok)), photo(2, mask: candidate(2, check: .ok), confirmed: false)])
        var options = Options(session: "S")
        options.frames = ["none"]
        let planned = InputPlanner.plan(session: s, folder: URL(fileURLWithPath: "/x"), options: options, fileExists: { _ in true })
        XCTAssertEqual(planned.map(\.included), [false, true])
        let missing = InputPlanner.plan(session: s, folder: URL(fileURLWithPath: "/x"), options: Options(session: "S"),
                                        fileExists: { !$0.path.contains("photos/") })
        XCTAssertEqual(missing.map(\.included), [false, false])
    }

    // MARK: - Gravity

    func testGravityForLevelLandscapeCamera() {
        // Identity pose: image up = world up, so gravity is −Y in the camera frame.
        let g = Gravity.inCameraFrame(cameraToWorld: matrix_identity_double4x4)
        XCTAssertEqual(g, SIMD3(0, -1, 0))
        // The device is then held with its top edge to the left, its right edge pointing up: gravity along −X.
        XCTAssertEqual(Gravity.deviceFrame(fromCamera: g), SIMD3(-1, 0, 0))
    }

    func testGravityForPortraitCameraLookingDown() {
        // Real photo #1 of the mouse session (portrait, looking down about 40°).
        let rows: [[Double]] = [[-0.010434496, 0.9989498, -0.044615306, 0], [-0.7497826, 0.021704549, 0.66132814, 0],
                                [0.66160196, 0.040352415, 0.7487687, 0], [0, 0, 0, 1]]
        let m = try! Matrix4x4(rows: rows).simd
        let g = Gravity.inCameraFrame(cameraToWorld: m)
        XCTAssertEqual(g.x, 0.7498, accuracy: 1e-3)   // towards the image right = device bottom
        XCTAssertLessThan(g.z, -0.6)                  // along the viewing direction (looking down)
        let d = Gravity.deviceFrame(fromCamera: g)
        XCTAssertLessThan(d.y, -0.7)                  // portrait upright: towards the bottom edge
        XCTAssertLessThan(d.z, -0.6)                  // screen tilted up: into the back
        XCTAssertEqual(simd_length(d), 1, accuracy: 1e-9)
    }

    // MARK: - Focal length, options, scale check

    func testFocalLength35mm() {
        XCTAssertEqual(FocalLength.equivalent35mm(photo: photo(1, mask: .notGenerated)), 26)
    }

    func testOptionParsing() throws {
        let o = try CommandLineParser.parse(["844B", "--detail", "preview", "--masks=off", "--frames", "ref-2,none", "--gravity", "camera"])
        XCTAssertEqual(o.session, "844B")
        XCTAssertEqual(o.detail, .preview)
        XCTAssertEqual(o.masks, .off)
        XCTAssertEqual(o.frames, ["ref-2", "none"])
        XCTAssertEqual(o.gravity, .camera)
        XCTAssertEqual(o.include, .all)
        XCTAssertThrowsError(try CommandLineParser.parse(["a", "--detail", "huge"]))
        XCTAssertThrowsError(try CommandLineParser.parse(["a", "b"]))
        XCTAssertThrowsError(try CommandLineParser.parse(["a", "--bogus", "1"]))
    }

    func testScaleCheckRecoversSimilarity() {
        let arkit: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0.4, 0, 0), SIMD3(0, 0.3, 0.1), SIMD3(-0.2, 0.1, 0.5)]
        let rotation = simd_double3x3(simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3))))
        let estimated = arkit.map { rotation * $0 / 0.25 + SIMD3(5, -1, 2) }
        let checks = ScaleCheck.compute(zip(arkit, estimated).map { ("ref-1", $0, $1) })
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks[0].pairs, 6)
        XCTAssertEqual(checks[0].medianScale!, 0.25, accuracy: 1e-4)
        XCTAssertEqual(checks[0].relativeSpread!, 0, accuracy: 1e-3)
    }
}
