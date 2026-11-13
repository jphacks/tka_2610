@testable import CaptureCore
import simd
import XCTest

/// 撮影画面のカメラの映像の置き方（写真と同じ縦横比で画面の幅に合わせ、上下を黒い帯にする）と、写真の点 ↔ 画面の点。
final class CameraPreviewTests: XCTestCase {
    /// 縦に持った画面の大きさと、撮影画面で使える範囲（ナビゲーションバー 44 pt の下・ホームインジケーターの上）。
    struct Screen {
        let name: String
        let width: Double
        let height: Double
        let topInset: Double
        let bottomInset: Double
        static let navigationBar = 44.0

        var safeArea: PreviewRect {
            let top = topInset + Self.navigationBar
            return PreviewRect(x: 0, y: top, width: width, height: height - top - bottomInset)
        }
    }

    static let screens = [
        Screen(name: "iPhone 15", width: 393, height: 852, topInset: 59, bottomInset: 34),
        Screen(name: "iPhone SE", width: 375, height: 667, topInset: 20, bottomInset: 0),
        Screen(name: "iPhone 15 Pro Max", width: 430, height: 932, topInset: 59, bottomInset: 34),
    ]
    /// 撮影画面の下の操作（シャッターの列）の高さ（アプリの `CameraPreviewContainer.controlsHeight` と同じ）。
    static let controls = 100.0
    /// 今の形式（`recommendedVideoFormatForHighResolutionFrameCapturing`）の映像と、高解像度の写真。
    static let video = (width: 1920.0, height: 1440.0)
    static let photo = (width: 4032.0, height: 3024.0)

    func testPortraitAspectFromImageResolution() {
        XCTAssertEqual(CameraPreview.portraitAspect(imageWidth: 1920, imageHeight: 1440), 0.75, accuracy: 1e-12)
        XCTAssertEqual(CameraPreview.portraitAspect(imageWidth: 4032, imageHeight: 3024), 0.75, accuracy: 1e-12)
        // 縦長で渡されても同じ（縦に持った幅 / 高さは短い辺 / 長い辺）。
        XCTAssertEqual(CameraPreview.portraitAspect(imageWidth: 1440, imageHeight: 1920), 0.75, accuracy: 1e-12)
        // 16:9 の形式なら 9:16。
        XCTAssertEqual(CameraPreview.portraitAspect(imageWidth: 1920, imageHeight: 1080), 0.5625, accuracy: 1e-12)
        // 分からないときは 3:4。
        XCTAssertEqual(CameraPreview.portraitAspect(imageWidth: 0, imageHeight: 0), CameraPreview.fallbackPortraitAspect)
        XCTAssertEqual(CameraPreview.portraitAspect(imageWidth: .nan, imageHeight: 1440), CameraPreview.fallbackPortraitAspect)
        XCTAssertEqual(CameraPreview.portraitAspect(imageWidth: .infinity, imageHeight: 1440), CameraPreview.fallbackPortraitAspect)
    }

    func testLayoutOnPhonesKeepsPhotoAspectInsideSafeArea() {
        let aspect = CameraPreview.portraitAspect(imageWidth: Self.video.width, imageHeight: Self.video.height)
        for screen in Self.screens {
            let safe = screen.safeArea
            let layout = CameraPreview.layout(in: safe, imageAspect: aspect, bottomControlsHeight: Self.controls)
            let image = layout.image
            XCTAssertTrue(safe.contains(image), screen.name)
            XCTAssertEqual(image.width / image.height, 0.75, accuracy: 1e-9, screen.name)
            // 画面の幅いっぱい（左右に帯は無い）。
            XCTAssertEqual(image.width, screen.width, accuracy: 1e-9, screen.name)
            XCTAssertEqual(image.minX, 0, accuracy: 1e-9, screen.name)
            for (label, rect) in [("top", layout.topBar), ("bottom", layout.bottomBar), ("controls", layout.bottomControls)] {
                XCTAssertGreaterThanOrEqual(rect.height, 0, "\(screen.name) \(label)")
                XCTAssertTrue(safe.contains(rect), "\(screen.name) \(label)")
            }
            // 上の帯・映像・下の帯で、使える範囲の高さをちょうど分ける。
            XCTAssertEqual(layout.topBar.height + image.height + layout.bottomBar.height, safe.height, accuracy: 1e-9, screen.name)
            XCTAssertEqual(layout.topBar.maxY, image.minY, accuracy: 1e-9, screen.name)
            XCTAssertEqual(layout.bottomBar.minY, image.maxY, accuracy: 1e-9, screen.name)
            XCTAssertEqual(layout.bottomBar.maxY, safe.maxY, accuracy: 1e-9, screen.name)
            // シャッターの列は入る（どの端末でも映像に重ならない）。
            XCTAssertGreaterThanOrEqual(layout.bottomControls.height, Self.controls, screen.name)
            XCTAssertEqual(layout.bottomControls.maxY, safe.maxY, accuracy: 1e-9, screen.name)
            XCTAssertEqual(layout.bottomOverlap, 0, accuracy: 1e-9, screen.name)
            // 薄すぎる上の帯は作らない。
            XCTAssertTrue(layout.topBar.height == 0 || layout.topBar.height >= CameraPreview.minimumBarHeight, screen.name)
            // 画面に見える範囲＝写真の全体。
            let visible = CameraPreview.visiblePhotoFraction(imageWidth: Self.photo.width, imageHeight: Self.photo.height,
                                                             viewWidth: image.width, viewHeight: image.height)
            XCTAssertEqual(visible.width, 1, accuracy: 1e-9, screen.name)
            XCTAssertEqual(visible.height, 1, accuracy: 1e-9, screen.name)
        }
    }

    func testLayoutNumbersPerPhone() {
        // iPhone 15：使える範囲 393 × 715。映像 393 × 524、余り 191 → 下 100（シャッター）、上 91。
        let l15 = CameraPreview.layout(in: Self.screens[0].safeArea, imageAspect: 0.75, bottomControlsHeight: Self.controls)
        XCTAssertEqual(l15.image.height, 524, accuracy: 1e-9)
        XCTAssertEqual(l15.bottomBar.height, 100, accuracy: 1e-9)
        XCTAssertEqual(l15.topBar.height, 91, accuracy: 1e-9)
        // iPhone SE：使える範囲 375 × 603。映像 375 × 500、余り 103 → 上の帯は 3 pt なので作らず、下に 103。
        let se = CameraPreview.layout(in: Self.screens[1].safeArea, imageAspect: 0.75, bottomControlsHeight: Self.controls)
        XCTAssertEqual(se.image.height, 500, accuracy: 1e-9)
        XCTAssertEqual(se.topBar.height, 0, accuracy: 1e-9)
        XCTAssertEqual(se.image.minY, 64, accuracy: 1e-9)
        XCTAssertEqual(se.bottomBar.height, 103, accuracy: 1e-9)
        // iPhone 15 Pro Max：使える範囲 430 × 795。映像の高さ 573.3、余り 221.7 は操作より十分大きいので上下で半分ずつ。
        let max = CameraPreview.layout(in: Self.screens[2].safeArea, imageAspect: 0.75, bottomControlsHeight: Self.controls)
        XCTAssertEqual(max.topBar.height, max.bottomBar.height, accuracy: 1e-9)
        XCTAssertEqual(max.image.midY, Self.screens[2].safeArea.midY, accuracy: 1e-9)
    }

    func testThinBarsLetControlsOverlapImageBottomOnly() {
        // 9:16 の画面で操作が帯より高いとき：映像は上に寄せ、操作は映像の下の端にだけ重なる（映像の中央には届かない）。
        let safe = PreviewRect(x: 0, y: 64, width: 375, height: 560)
        let layout = CameraPreview.layout(in: safe, imageAspect: 0.75, bottomControlsHeight: 110)
        XCTAssertEqual(layout.topBar.height, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.image.minY, safe.minY, accuracy: 1e-9)
        XCTAssertEqual(layout.bottomBar.height, 60, accuracy: 1e-9)
        XCTAssertEqual(layout.bottomControls.height, 110, accuracy: 1e-9)
        XCTAssertEqual(layout.bottomOverlap, 50, accuracy: 1e-9)
        XCTAssertLessThan(layout.bottomControls.minY, layout.image.maxY)
        XCTAssertGreaterThan(layout.bottomControls.minY, layout.image.midY)
        XCTAssertTrue(safe.contains(layout.image))
    }

    func testLayoutFallbacksAndWideContainers() {
        // 縦横比が分からない（最初のフレームの前）ときは 3:4。
        let safe = Self.screens[0].safeArea
        for unknown in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            let layout = CameraPreview.layout(in: safe, imageAspect: unknown, bottomControlsHeight: Self.controls)
            XCTAssertEqual(layout.image.width / layout.image.height, CameraPreview.fallbackPortraitAspect, accuracy: 1e-9)
        }
        // 横に広い場所では高さに合わせて左右の中央。
        let wide = CameraPreview.layout(in: PreviewRect(x: 10, y: 20, width: 800, height: 400), imageAspect: 0.75, bottomControlsHeight: 50)
        XCTAssertEqual(wide.image.height, 400, accuracy: 1e-9)
        XCTAssertEqual(wide.image.width, 300, accuracy: 1e-9)
        XCTAssertEqual(wide.image.midX, 410, accuracy: 1e-9)
        XCTAssertEqual(wide.topBar.height, 0)
        XCTAssertEqual(wide.bottomBar.height, 0)
        XCTAssertEqual(wide.bottomControls.height, 50, accuracy: 1e-9)
        // 空の範囲・おかしな操作の高さでも、負の高さは出ない。
        let empty = CameraPreview.layout(in: PreviewRect(x: 0, y: 0, width: 0, height: -5), imageAspect: 0.75, bottomControlsHeight: .nan)
        for rect in [empty.image, empty.topBar, empty.bottomBar, empty.bottomControls] {
            XCTAssertGreaterThanOrEqual(rect.width, 0)
            XCTAssertGreaterThanOrEqual(rect.height, 0)
        }
    }

    func testPanelAreaExcludesBarContentsOverImage() {
        let layout = CameraPreview.layout(in: Self.screens[0].safeArea, imageAspect: 0.75, bottomControlsHeight: Self.controls)
        // 中身が帯に収まっていれば、映像の枠そのまま。
        XCTAssertEqual(CameraPreview.panelArea(layout, topContentHeight: layout.topBar.height, bottomContentHeight: layout.bottomBar.height), layout.image)
        // 上の案内が帯より 30 pt 高い・下の操作が 20 pt 高い → その分を除く。
        let area = CameraPreview.panelArea(layout, topContentHeight: layout.topBar.height + 30, bottomContentHeight: layout.bottomBar.height + 20)
        XCTAssertEqual(area.minY, layout.image.minY + 30, accuracy: 1e-9)
        XCTAssertEqual(area.maxY, layout.image.maxY - 20, accuracy: 1e-9)
        XCTAssertEqual(area.width, layout.image.width)
        // 中身が映像の全体を覆うほど高くても、負の高さにはならない。
        let covered = CameraPreview.panelArea(layout, topContentHeight: 10_000, bottomContentHeight: 10_000)
        XCTAssertEqual(covered.height, 0)
        XCTAssertGreaterThanOrEqual(covered.minY, layout.image.minY)
        XCTAssertLessThanOrEqual(covered.maxY, layout.image.maxY)
    }

    func testSensorCornersLandOnViewCornersWhenAspectMatches() {
        // 縦向き＝センサーの画像を時計回りに 90° 回す。写真と同じ縦横比の view なら、写真の四隅が view の四隅。
        let w = 393.0, h = 524.0
        func view(_ x: Double, _ y: Double) -> SIMD2<Double> {
            CameraPreview.viewPoint(fromSensor: SIMD2(x, y), imageWidth: Self.photo.width, imageHeight: Self.photo.height, viewWidth: w, viewHeight: h)
        }
        assertClose(view(0, 0), SIMD2(w, 0))   // センサーの左上 → 画面の右上
        assertClose(view(1, 0), SIMD2(w, h))   // 右上 → 右下
        assertClose(view(1, 1), SIMD2(0, h))   // 右下 → 左下
        assertClose(view(0, 1), SIMD2(0, 0))   // 左下 → 左上
        // 写真の中心（向きで案内する撮影の十字・中心の線）＝ view の中心。
        assertClose(view(0.5, 0.5), SIMD2(w / 2, h / 2))
        // ARKit の displayTransform(for: .portrait) と同じ形：(x, y) → (1 − y, x)。
        let p = SIMD2(0.3, 0.8)
        assertClose(view(p.x, p.y), SIMD2((1 - p.y) * w, p.x * h))
        // 逆も合う。
        let back = CameraPreview.sensorPoint(fromView: view(p.x, p.y), imageWidth: Self.photo.width, imageHeight: Self.photo.height, viewWidth: w, viewHeight: h)
        assertClose(back, p)
        let shown = CameraPreview.shownImageRect(imageWidth: Self.photo.width, imageHeight: Self.photo.height, viewWidth: w, viewHeight: h)
        assertClose(SIMD2(shown.minX, shown.minY), SIMD2(0, 0))
        assertClose(SIMD2(shown.maxX, shown.maxY), SIMD2(w, h))
    }

    func testOldFullScreenPreviewCroppedThePhoto() {
        // 前の置き方（画面の全体 393 × 852 に aspect-fill）：写真の幅の約 6 割しか見えず、左右が切れていた。
        let visible = CameraPreview.visiblePhotoFraction(imageWidth: Self.video.width, imageHeight: Self.video.height, viewWidth: 393, viewHeight: 852)
        XCTAssertEqual(visible.height, 1, accuracy: 1e-9)
        XCTAssertEqual(visible.width, 393.0 / (1440.0 * 852.0 / 1920.0), accuracy: 1e-9)
        XCTAssertLessThan(visible.width, 0.62)
        // そのときも中心は合っていた（十字は画面の中心でよかった）が、写真の左の端は画面の外。
        let shown = CameraPreview.shownImageRect(imageWidth: Self.video.width, imageHeight: Self.video.height, viewWidth: 393, viewHeight: 852)
        XCTAssertLessThan(shown.minX, 0)
        let center = CameraPreview.viewPoint(fromSensor: SIMD2(0.5, 0.5), imageWidth: Self.video.width, imageHeight: Self.video.height, viewWidth: 393, viewHeight: 852)
        assertClose(center, SIMD2(196.5, 426))
        // 逆の変換も aspect-fill のずれを戻す。
        let p = SIMD2(0.25, 0.6)
        let v = CameraPreview.viewPoint(fromSensor: p, imageWidth: Self.video.width, imageHeight: Self.video.height, viewWidth: 393, viewHeight: 852)
        assertClose(CameraPreview.sensorPoint(fromView: v, imageWidth: Self.video.width, imageHeight: Self.video.height, viewWidth: 393, viewHeight: 852), p)
    }

    func testUnknownImageSizeTreatsViewAsPhoto() {
        let rect = CameraPreview.shownImageRect(imageWidth: 0, imageHeight: 0, viewWidth: 300, viewHeight: 400)
        XCTAssertEqual(rect, PreviewRect(x: 0, y: 0, width: 300, height: 400))
        assertClose(CameraPreview.viewPoint(fromSensor: SIMD2(0, 0), imageWidth: 0, imageHeight: 0, viewWidth: 300, viewHeight: 400), SIMD2(300, 0))
        assertClose(CameraPreview.sensorPoint(fromView: SIMD2(10, 10), imageWidth: 1920, imageHeight: 1440, viewWidth: 0, viewHeight: 0), SIMD2(0.5, 0.5))
    }

    func testSheetEdgeCheckMeansTheEdgeTheUserSees() {
        // 平面の作品：「紙が端にかかっている」の判定は写真の 0〜1 の座標で見る。撮影画面は写真の全体を出すので、
        // 判定にかかる紙は、画面でも映像の枠の端にかかって見える（前は画面の外で見えない所にあった）。
        let layout = CameraPreview.layout(in: Self.screens[0].safeArea, imageAspect: 0.75, bottomControlsHeight: Self.controls)
        let w = layout.image.width, h = layout.image.height
        // 写真の左右の端（センサーの y = 0.005 と 0.995）にかかる紙。
        let atEdge: [SIMD2<Double>] = [SIMD2(0.2, 0.005), SIMD2(0.8, 0.005), SIMD2(0.8, 0.6), SIMD2(0.2, 0.6)]
        XCTAssertEqual(FlatGuidance.evaluate(corners: atEdge, lookDownDeg: 85), .sheetAtEdge)
        let points = atEdge.map {
            CameraPreview.viewPoint(fromSensor: $0, imageWidth: Self.photo.width, imageHeight: Self.photo.height, viewWidth: w, viewHeight: h)
        }
        // view の中（見える）で、右の端から 1% 以内。
        for p in points {
            XCTAssertGreaterThanOrEqual(p.x, -1e-9)
            XCTAssertLessThanOrEqual(p.x, w + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, -1e-9)
            XCTAssertLessThanOrEqual(p.y, h + 1e-9)
        }
        XCTAssertTrue(points.contains { $0.x >= w * 0.99 })
        // 端から離れた紙は撮れる。
        let inside: [SIMD2<Double>] = [SIMD2(0.2, 0.15), SIMD2(0.8, 0.15), SIMD2(0.8, 0.85), SIMD2(0.2, 0.85)]
        XCTAssertEqual(FlatGuidance.evaluate(corners: inside, lookDownDeg: 85), .ready)
    }

    private func assertClose(_ a: SIMD2<Double>, _ b: SIMD2<Double>, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }
}
