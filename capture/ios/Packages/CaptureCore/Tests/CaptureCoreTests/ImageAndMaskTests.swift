@testable import CaptureCore
import XCTest

final class ImageMetricsTests: XCTestCase {
    func testMeanLumaOfFlatImage() throws {
        let buffer = LumaBuffer(pixels: [UInt8](repeating: 51, count: 100 * 80), width: 100, height: 80)
        let r = try XCTUnwrap(ImageMetrics.compute(buffer))
        XCTAssertEqual(r.meanLuma, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.laplacianVariance, 0, accuracy: 1e-12)
    }

    func testCheckerboardIsSharperThanGradient() throws {
        let w = 64, h = 64
        var checker = [UInt8](repeating: 0, count: w * h)
        var gradient = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                checker[y * w + x] = ((x / 2 + y / 2) % 2 == 0) ? 230 : 20
                gradient[y * w + x] = UInt8(x * 255 / (w - 1))
            }
        }
        let sharp = try XCTUnwrap(ImageMetrics.compute(LumaBuffer(pixels: checker, width: w, height: h)))
        let smooth = try XCTUnwrap(ImageMetrics.compute(LumaBuffer(pixels: gradient, width: w, height: h)))
        XCTAssertGreaterThan(sharp.laplacianVariance, 0.01)
        XCTAssertLessThan(smooth.laplacianVariance, 0.0001)
    }

    func testStrideAndROI() throws {
        // 1 行 12 バイト（幅 10 + 詰め物 2）。左半分 0、右半分 200。詰め物は 255（読まれてはいけない）。
        let w = 10, h = 6, stride = 12
        var pixels = [UInt8](repeating: 255, count: stride * h)
        for y in 0..<h { for x in 0..<w { pixels[y * stride + x] = x < 5 ? 0 : 200 } }
        let buffer = LumaBuffer(pixels: pixels, width: w, height: h, bytesPerRow: stride)
        let whole = try XCTUnwrap(ImageMetrics.compute(buffer))
        XCTAssertEqual(whole.meanLuma, 100.0 / 255, accuracy: 1e-9)
        let right = try XCTUnwrap(ImageMetrics.compute(buffer, roi: PixelRect(x: 5, y: 0, width: 5, height: 6)))
        XCTAssertEqual(right.meanLuma, 200.0 / 255, accuracy: 1e-9)
        // ROI が画像の外にはみ出していても切り詰める。
        let clipped = try XCTUnwrap(ImageMetrics.compute(buffer, roi: PixelRect(x: 5, y: -10, width: 50, height: 50)))
        XCTAssertEqual(clipped.meanLuma, 200.0 / 255, accuracy: 1e-9)
        // 画像の外だけの ROI は nil。
        XCTAssertNil(ImageMetrics.compute(buffer, roi: PixelRect(x: 20, y: 20, width: 5, height: 5)))
    }

    func testDownsampleLimitsSize() throws {
        let buffer = LumaBuffer(pixels: [UInt8](repeating: 128, count: 1000 * 800), width: 1000, height: 800)
        let small = try XCTUnwrap(ImageMetrics.downsample(buffer, maxSamples: 100))
        XCTAssertLessThanOrEqual(max(small.width, small.height), 100)
        XCTAssertGreaterThanOrEqual(max(small.width, small.height), 90)
    }
}

final class MaskSelectionTests: XCTestCase {
    /// 20 × 10。番号 1 は左（x 0..<6）、番号 2 は中央（x 8..<12）、番号 3 は右下の小さい物。
    private func map() -> InstanceLabelMap {
        let w = 20, h = 10
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                if x < 6 { labels[y * w + x] = 1 }
                if x >= 8 && x < 12 && y >= 2 && y < 8 { labels[y * w + x] = 2 }
                if x >= 17 && y >= 8 { labels[y * w + x] = 3 }
            }
        }
        return InstanceLabelMap(labels: labels, width: w, height: h)
    }

    func testChoosesInstanceOverlappingROI() {
        let selected = MaskInstanceSelector.autoSelect(map: map(), roi: PixelRect(x: 7, y: 1, width: 6, height: 8))
        XCTAssertEqual(selected, [2])
        XCTAssertEqual(MaskInstanceSelector.status(for: selected), .candidate)
    }

    func testNoOverlapChoosesNone() {
        let selected = MaskInstanceSelector.autoSelect(map: map(), roi: PixelRect(x: 13, y: 0, width: 3, height: 5))
        XCTAssertEqual(selected, [])
        XCTAssertEqual(MaskInstanceSelector.status(for: selected), .noObject)
    }

    func testSingleInstanceIsChosenEvenOutsideROI() {
        var labels = [UInt8](repeating: 0, count: 100)
        labels[0] = 4
        let m = InstanceLabelMap(labels: labels, width: 10, height: 10)
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: m, roi: PixelRect(x: 5, y: 5, width: 2, height: 2)), [4])
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: InstanceLabelMap(labels: [UInt8](repeating: 0, count: 100), width: 10, height: 10), roi: nil), [])
    }

    func testSecondaryInstanceMostlyInsideIsAdded() {
        // ROI が中央の物と右下の物を囲む：右下の物は全部が中にあり、重なりも十分なら加える。
        let w = 10, h = 10
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 2..<6 { for x in 2..<6 { labels[y * w + x] = 1 } }  // 16
        for y in 6..<9 { for x in 2..<5 { labels[y * w + x] = 2 } }  // 9
        let m = InstanceLabelMap(labels: labels, width: w, height: h)
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: m, roi: PixelRect(x: 1, y: 1, width: 7, height: 9)), [1, 2])
    }

    func testToggle() {
        XCTAssertEqual(MaskInstanceSelector.toggle(2, in: [1]), [1, 2])
        XCTAssertEqual(MaskInstanceSelector.toggle(1, in: [1, 2]), [2])
        XCTAssertEqual(MaskInstanceSelector.toggle(0, in: [1]), [1])
    }
}
