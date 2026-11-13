@testable import CaptureCore
import simd
import XCTest

final class QualityEvaluatorTests: XCTestCase {
    let plan = DirectionPlanPreset.ring8.plan
    let inside = ProjectionResult(status: .inside, boundingBox: PixelRect(x: 500, y: 300, width: 900, height: 800), sizeFraction: 0.55, center: SIMD2(960, 720))

    private func direction(matched: String? = "a045-e20", covered: Bool = false) -> DirectionContext {
        DirectionContext(
            azimuthDeg: 45, elevationDeg: 20, distanceM: 0.4, matchedTarget: plan.target(id: matched),
            matchedTargetCovered: covered, nextTarget: plan.target(id: covered ? "a090-e20" : matched),
            coveredCount: 1, totalCount: 8
        )
    }

    /// すべて ok の入力。
    private func good(_ t: Double, _ change: (inout LiveFrameSample) -> Void = { _ in }) -> LiveFrameSample {
        var s = LiveFrameSample(
            timestamp: t, trackingState: .normal, reference: .ready, projection: inside, direction: direction(),
            angularSpeed: 0.05, linearSpeed: 0.02, meanLuma: 0.5, sharpness: 0.01, ambientIntensity: 1000, exposureDuration: 0.01
        )
        change(&s)
        return s
    }

    /// 0.1 秒ごとに n 回判定して最後の結果を返す。
    private func run(_ e: inout QualityEvaluator, from t0: Double = 0, count: Int, _ change: (inout LiveFrameSample) -> Void = { _ in }) -> QualityAssessment {
        var last = QualityAssessment.initial
        for i in 0..<count { last = e.evaluate(good(t0 + Double(i) * 0.1, change)) }
        return last
    }

    func testAutoCaptureNeedsStabilityWindow() {
        var e = QualityEvaluator()
        XCTAssertFalse(run(&e, count: 3).canAutoCapture)  // 0.2 秒しか経っていない
        var e2 = QualityEvaluator()
        let r = run(&e2, count: 6)  // 0.5 秒
        XCTAssertTrue(r.canAutoCapture)
        XCTAssertEqual(r.autoTargetId, "a045-e20")
        XCTAssertTrue(r.canManualCapture)
        XCTAssertFalse(r.hasWarnings)
    }

    func testInstabilityResetsWindow() {
        var e = QualityEvaluator()
        _ = run(&e, count: 5)
        _ = e.evaluate(good(0.5) { $0.angularSpeed = 2 })  // 速く動いた
        let r = run(&e, from: 0.6, count: 3)
        XCTAssertFalse(r.canAutoCapture)
    }

    func testCooldownAfterCapture() {
        var e = QualityEvaluator()
        XCTAssertTrue(run(&e, count: 6).canAutoCapture)
        e.noteCapture(at: 0.5)
        XCTAssertFalse(run(&e, from: 0.6, count: 7).canAutoCapture)  // 1.2 秒の待ちの中（最後は 1.2 秒）
        XCTAssertTrue(run(&e, from: 1.3, count: 6).canAutoCapture)   // 1.8 秒、待ちの外
    }

    func testLimitedTrackingBlocksAutoNotManual() {
        var e = QualityEvaluator()
        let r = run(&e, count: 10) { $0.trackingState = .limited; $0.trackingReason = .insufficientFeatures }
        XCTAssertFalse(r.canAutoCapture)
        XCTAssertTrue(r.canManualCapture)
        XCTAssertEqual(r.status(.tracking), .warning)
        XCTAssertTrue(r.hasWarnings)
    }

    func testNotAvailableBlocksBoth() {
        var e = QualityEvaluator()
        let r = run(&e, count: 10) { $0.trackingState = .notAvailable }
        XCTAssertFalse(r.canAutoCapture)
        XCTAssertFalse(r.canManualCapture)
        XCTAssertEqual(r.status(.tracking), .blocked)
    }

    func testCaptureInFlightBlocksBoth() {
        var e = QualityEvaluator()
        let r = run(&e, count: 10) { $0.captureInFlight = true }
        XCTAssertFalse(r.canAutoCapture)
        XCTAssertFalse(r.canManualCapture)
    }

    func testDarkAndBlurAreWarningsOnly() {
        var e = QualityEvaluator()
        let dark = run(&e, count: 10) { $0.meanLuma = 0.05 }
        XCTAssertEqual(dark.status(.brightness), .warning)
        XCTAssertTrue(dark.canManualCapture)
        XCTAssertFalse(dark.canAutoCapture)
        XCTAssertFalse(dark.checks.contains { $0.status == .blocked })

        var e2 = QualityEvaluator()
        let blurry = run(&e2, count: 10) { $0.sharpness = 0.00001 }
        XCTAssertEqual(blurry.status(.sharpness), .warning)
        XCTAssertTrue(blurry.canManualCapture)
        XCTAssertFalse(blurry.checks.contains { $0.status == .blocked })

        var e3 = QualityEvaluator()
        let longExposure = run(&e3, count: 3) { $0.exposureDuration = 0.1 }
        XCTAssertEqual(longExposure.status(.brightness), .warning)
    }

    func testCoveredTargetDoesNotAutoCapture() {
        var e = QualityEvaluator()
        let r = run(&e, count: 10) { $0.direction = self.direction(matched: "a045-e20", covered: true) }
        XCTAssertFalse(r.canAutoCapture)
        XCTAssertEqual(r.status(.direction), .warning)
        XCTAssertTrue(r.canManualCapture)
    }

    func testOffTargetDoesNotAutoCapture() {
        var e = QualityEvaluator()
        let r = run(&e, count: 10) { $0.direction = self.direction(matched: nil) }
        XCTAssertFalse(r.canAutoCapture)
    }

    func testNoReferenceAllowsManualOnly() {
        var e = QualityEvaluator()
        let r = run(&e, count: 10) { $0.reference = .none; $0.projection = nil; $0.direction = nil }
        XCTAssertFalse(r.canAutoCapture)
        XCTAssertTrue(r.canManualCapture)
        XCTAssertEqual(r.status(.inFrame), .unknown)
        XCTAssertEqual(r.status(.direction), .unknown)
    }

    func testFrontPhotoIsManual() {
        var e = QualityEvaluator()
        let r = run(&e, count: 10) {
            $0.reference = .awaitingFront
            $0.direction = DirectionContext(azimuthDeg: nil, elevationDeg: 20, distanceM: 0.4, matchedTarget: nil, matchedTargetCovered: false, nextTarget: nil, coveredCount: 0, totalCount: 8)
        }
        XCTAssertEqual(r.status(.direction), .ok)
        XCTAssertFalse(r.canAutoCapture)
        XCTAssertTrue(r.canManualCapture)
        XCTAssertTrue(r.primaryMessage.contains("正面"), r.primaryMessage)
    }

    func testTargetChangeRestartsWindow() {
        var e = QualityEvaluator()
        _ = run(&e, count: 5)
        let r = run(&e, from: 0.5, count: 3) { $0.direction = DirectionContext(azimuthDeg: 90, elevationDeg: 20, distanceM: 0.4, matchedTarget: self.plan.target(id: "a090-e20"), matchedTargetCovered: false, nextTarget: nil, coveredCount: 1, totalCount: 8) }
        XCTAssertFalse(r.canAutoCapture)
    }

    func testLiveRecordAndSavedQuality() {
        var e = QualityEvaluator()
        let r = run(&e, count: 2) { $0.meanLuma = 0.05 }
        let record = r.liveRecord(warningsAcknowledged: true)
        XCTAssertEqual(record.brightness, .warning)
        XCTAssertEqual(record.tracking, .ok)
        XCTAssertTrue(record.warningsAcknowledged)
        let saved = e.savedQuality(meanLuma: 0.05, sharpness: 0.0001)
        XCTAssertEqual(saved.brightness, .warning)
        XCTAssertEqual(saved.blur, .warning)
        XCTAssertEqual(e.savedQuality(meanLuma: 0.5, sharpness: 0.01).blur, .ok)
    }
}
