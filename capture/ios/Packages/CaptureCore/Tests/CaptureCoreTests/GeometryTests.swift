@testable import CaptureCore
import simd
import XCTest

final class GeometryTests: XCTestCase {
    let base = SIMD3<Double>(0.1, -0.7, -0.4)

    func testObjectFrameFromFrontCamera() throws {
        // 正面のカメラは基準点の +X 方向、少し上にいる → 作品の +Z は世界の +X、+X = Y × Z は世界の −Z。
        let camera = base + SIMD3(0.5, 0.3, 0)
        let m = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: camera))
        XCTAssertEqual(m.columns.2.x, 1, accuracy: 1e-12)  // +Z
        XCTAssertEqual(m.columns.2.y, 0, accuracy: 1e-12)  // 水平
        XCTAssertEqual(m.columns.1.y, 1, accuracy: 1e-12)  // +Y は上
        XCTAssertEqual(m.columns.0.z, -1, accuracy: 1e-12) // +X = Y × Z
        XCTAssertEqual(m.translation, base)
        // 正面のカメラの方位は 0。
        XCTAssertEqual(Geometry.azimuth(cameraPosition: camera, objectToWorld: m), 0, accuracy: 1e-9)
    }

    func testObjectFrameUndefinedFromDirectlyAbove() {
        XCTAssertNil(Geometry.objectToWorld(basePoint: base, frontCameraPosition: base + SIMD3(0.01, 0.5, 0.01)))
    }

    func testAzimuthQuadrants() throws {
        let m = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: base + SIMD3(0, 0, 1)))
        // 作品座標 = 世界の向きそのまま（+Z が正面、+X が右）。
        XCTAssertEqual(Geometry.azimuth(cameraPosition: base + SIMD3(0, 0.2, 0.5), objectToWorld: m), 0, accuracy: 1e-9)
        XCTAssertEqual(Geometry.azimuth(cameraPosition: base + SIMD3(0.5, 0.2, 0), objectToWorld: m), 90, accuracy: 1e-9)
        XCTAssertEqual(Geometry.azimuth(cameraPosition: base + SIMD3(0, 0.2, -0.5), objectToWorld: m), 180, accuracy: 1e-9)
        XCTAssertEqual(Geometry.azimuth(cameraPosition: base + SIMD3(-0.5, 0.2, 0), objectToWorld: m), 270, accuracy: 1e-9)
        // 少しだけ左（負の側）は 360 に近い値（0〜360）。
        let slightlyLeft = Geometry.azimuth(cameraPosition: base + SIMD3(-0.01, 0, 0.5), objectToWorld: m)
        XCTAssertGreaterThan(slightlyLeft, 358)
        XCTAssertLessThan(slightlyLeft, 360)
    }

    func testAzimuthFollowsFrontNotWorldAxes() throws {
        // 正面が世界の +X 側なら、世界の +Z 側（正面から見て左）にいるカメラは 270。
        let m = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: base + SIMD3(1, 0, 0)))
        XCTAssertEqual(Geometry.azimuth(cameraPosition: base + SIMD3(0, 0, 1), objectToWorld: m), 270, accuracy: 1e-9)
        XCTAssertEqual(Geometry.azimuth(cameraPosition: base + SIMD3(0, 0, -1), objectToWorld: m), 90, accuracy: 1e-9)
    }

    func testElevationSignAndUsesObjectCenter() {
        let h = 0.2
        // 作品の中心と同じ高さ → 0°（基準点からだと正になる高さ）。
        let level = Geometry.elevationAndDistance(cameraPosition: base + SIMD3(0, h / 2, 0.5), basePoint: base, heightM: h)
        XCTAssertEqual(level.elevationDeg, 0, accuracy: 1e-9)
        XCTAssertEqual(level.distanceM, 0.5, accuracy: 1e-9)
        // 見下ろす → 正。
        let above = Geometry.elevationAndDistance(cameraPosition: base + SIMD3(0, h / 2 + 0.5, 0.5), basePoint: base, heightM: h)
        XCTAssertEqual(above.elevationDeg, 45, accuracy: 1e-9)
        // 下から → 負。
        let below = Geometry.elevationAndDistance(cameraPosition: base + SIMD3(0, h / 2 - 0.5, 0.5), basePoint: base, heightM: h)
        XCTAssertEqual(below.elevationDeg, -45, accuracy: 1e-9)
        // 基準点（底）の高さのカメラは、中心から見ると見上げている（負）。
        let atBase = Geometry.elevationAndDistance(cameraPosition: base + SIMD3(0, 0, 0.5), basePoint: base, heightM: h)
        XCTAssertLessThan(atBase.elevationDeg, 0)
    }

    func testAngleDifferenceWrapsAround() {
        XCTAssertEqual(Geometry.angleDistance(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(Geometry.angleDistance(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(Geometry.signedAngleDifference(from: 350, to: 10), 20, accuracy: 1e-9)
        XCTAssertEqual(Geometry.signedAngleDifference(from: 10, to: 350), -20, accuracy: 1e-9)
        XCTAssertEqual(Geometry.normalizeDegrees(-90), 270, accuracy: 1e-9)
        XCTAssertEqual(Geometry.normalizeDegrees(720), 0, accuracy: 1e-9)
    }

    func testSpeeds() throws {
        let a = Fixtures.lookAt(from: SIMD3(0, 0, 1), to: .zero)
        var b = a
        b.columns.3 = SIMD4(0.1, 0, 1, 1)
        let s = try XCTUnwrap(Geometry.speeds(from: a, at: 0, to: b, at: 0.5))
        XCTAssertEqual(s.linear, 0.2, accuracy: 1e-9)
        XCTAssertEqual(s.angular, 0, accuracy: 1e-6)
        let rotated = simd_mul(a, simd_double4x4(simd_quatd(angle: 0.5, axis: SIMD3(0, 1, 0))))
        let r = try XCTUnwrap(Geometry.speeds(from: a, at: 0, to: rotated, at: 1))
        XCTAssertEqual(r.angular, 0.5, accuracy: 1e-6)
    }

    func testDisplayRotationRoundTripAndMapping() {
        for rotation in [0, 90, 180, 270] {
            let p = SIMD2<Double>(0.2, 0.7)
            let d = DisplayRotation.displayPoint(fromSensor: p, rotationDegClockwise: rotation)
            let back = DisplayRotation.sensorPoint(fromDisplay: d, rotationDegClockwise: rotation)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-12)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-12)
        }
        // 時計回り 90°：センサーの左上は表示の右上へ。
        XCTAssertEqual(DisplayRotation.displayPoint(fromSensor: SIMD2(0, 0), rotationDegClockwise: 90), SIMD2(1, 0))
        XCTAssertEqual(DisplayRotation.rotation(deviceOrientation: "portrait"), 90)
        XCTAssertEqual(DisplayRotation.rotation(deviceOrientation: "portraitUpsideDown"), 270)
        XCTAssertNil(DisplayRotation.rotation(deviceOrientation: "faceUp"))
        // 世界の上が画像の左（縦持ち）→ 90。
        XCTAssertEqual(DisplayRotation.rotationFromGravity(upInCameraX: -0.9, upInCameraY: 0.1), 90)
        XCTAssertEqual(DisplayRotation.rotationFromGravity(upInCameraX: 0.1, upInCameraY: 0.9), 0)
    }

    func testMotionEstimatorSmooths() {
        var m = MotionEstimator(smoothing: 0.5)
        let a = Fixtures.lookAt(from: SIMD3(0, 0, 1), to: .zero)
        m.update(transform: a, timestamp: 0)
        var b = a
        b.columns.3 = SIMD4(0.1, 0, 1, 1)
        m.update(transform: b, timestamp: 0.1)  // 1 m/s
        XCTAssertEqual(m.linearSpeed, 0.5, accuracy: 1e-9)
    }
}

final class ProjectionTests: XCTestCase {
    let cylinder = ObjectCylinder(basePoint: SIMD3(0, 0, 0), radiusM: 0.08, heightM: 0.15)

    func testInsideWhenLookingAtObject() {
        let camera = Fixtures.camera(from: SIMD3(0, 0.2, 0.45), to: cylinder.center)
        let r = Projection.evaluate(cylinder: cylinder, camera: camera)
        XCTAssertEqual(r.status, .inside)
        let center = try! XCTUnwrap(r.center)
        XCTAssertEqual(center.x, 960, accuracy: 1e-6)
        XCTAssertEqual(center.y, 720, accuracy: 1e-6)
    }

    func testImageYFlipsUpward() {
        // 作品の上の点は、画像では中心より上（y が小さい）。
        let camera = Fixtures.camera(from: SIMD3(0, 0.075, 0.5), to: cylinder.center)
        let top = camera.project(SIMD3(0, 0.15, 0))!
        XCTAssertLessThan(top.y, 720)
        // 右（カメラの +X）の点は x が大きい。
        let right = camera.project(SIMD3(0.08, 0.075, 0))!
        XCTAssertGreaterThan(right.x, 960)
    }

    func testPartiallyOutside() {
        // 作品の横を見ている。
        let camera = Fixtures.camera(from: SIMD3(0, 0.2, 0.45), to: SIMD3(0.18, 0.075, 0))
        let r = Projection.evaluate(cylinder: cylinder, camera: camera)
        XCTAssertEqual(r.status, .partiallyOutside)
    }

    func testBehindCamera() {
        let camera = Fixtures.camera(from: SIMD3(0, 0.2, 0.45), to: SIMD3(0, 0.2, 1.5))
        let r = Projection.evaluate(cylinder: cylinder, camera: camera)
        XCTAssertEqual(r.status, .behindCamera)
        XCTAssertNil(r.boundingBox)
    }

    func testTooSmallAndTooLarge() {
        let far = Fixtures.camera(from: SIMD3(0, 0.5, 3), to: cylinder.center)
        XCTAssertEqual(Projection.evaluate(cylinder: cylinder, camera: far).status, .tooSmall)
        let near = Fixtures.camera(from: SIMD3(0, 0.1, 0.2), to: cylinder.center)
        XCTAssertEqual(Projection.evaluate(cylinder: cylinder, camera: near).status, .tooLarge)
    }

    func testPartlyBehindCameraIsNotInFrame() {
        // カメラが円柱の中（一部の点は後ろ）。
        let camera = Fixtures.camera(from: SIMD3(0, 0.075, 0.05), to: SIMD3(0, 0.075, -1))
        let r = Projection.evaluate(cylinder: cylinder, camera: camera)
        XCTAssertNotEqual(r.status, .inside)
    }
}
