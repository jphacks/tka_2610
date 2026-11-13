import Foundation
import simd

// 撮影画面のカメラの映像の置き方（アプリは縦向きだけ）。
// 写真（captureHighResolutionFrame）は映像と同じ縦横比（今の形式は 4:3）で、どこも切れていない。
// 映像を画面の全体に広げると（aspect-fill）、縦長の画面に合わせて映像の左右が切れ、画面に見える範囲より写真の方が広くなる。
// そこで撮影画面では、標準のカメラと同じく、映像を写真と同じ縦横比の枠（縦に持つので 3:4）にして画面の幅に合わせ、
// 余った上下を黒い帯にする。画面に見える範囲＝写真に写る範囲になる。

/// 画面の上の長方形（pt。原点は左上）。
public struct PreviewRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = PreviewRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// `other` が丸ごと入っているか（`tolerance` pt までのはみ出しは許す）。
    public func contains(_ other: PreviewRect, tolerance: Double = 1e-6) -> Bool {
        other.minX >= minX - tolerance && other.minY >= minY - tolerance
            && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }
}

public enum CameraPreview {
    /// 縦に持って見た映像の幅 / 高さが分からない（形式を決める前など）ときに使う値（背面カメラのセンサーの 4:3 を縦にした 3:4）。
    public static let fallbackPortraitAspect = 3.0 / 4.0
    /// 縦向きの表示は、センサーの向きの画像を時計回りに 90° 回したもの（ARSCNView の `.portrait` と同じ）。
    public static let portraitRotationDegClockwise = 90
    /// これより薄い上の帯は作らず、下の帯に回す（映像を上に寄せる）。
    public static let minimumBarHeight = 16.0

    /// センサーの向きの画像の大きさ（ARKit の `imageResolution`。横長）から、縦に持って見たときの幅 / 高さ。
    /// 大きさが分からない（0・無限・NaN）ときは `fallbackPortraitAspect`。
    public static func portraitAspect(imageWidth: Double, imageHeight: Double) -> Double {
        guard imageWidth.isFinite, imageHeight.isFinite, imageWidth > 0, imageHeight > 0 else { return fallbackPortraitAspect }
        return min(imageWidth, imageHeight) / max(imageWidth, imageHeight)
    }

    /// 縦横比（幅 / 高さ）が使える値か。
    static func isUsable(_ aspect: Double?) -> Bool {
        guard let aspect else { return false }
        return aspect.isFinite && aspect > 0
    }

    /// 縦横比 `aspect`（幅 / 高さ）の長方形を、`container` に収まる一番大きい大きさで中央に置く（aspect-fit）。
    /// 縦横比が使えない・`container` が空のときは、`container` の中央の大きさ 0 の長方形。
    public static func aspectFit(aspect: Double, in container: PreviewRect) -> PreviewRect {
        let w = max(0, container.width), h = max(0, container.height)
        guard isUsable(aspect), w > 0, h > 0 else { return PreviewRect(x: container.midX, y: container.midY, width: 0, height: 0) }
        var fitW = w, fitH = w / aspect
        if fitH > h {
            fitH = h
            fitW = h * aspect
        }
        return PreviewRect(x: container.x + (w - fitW) / 2, y: container.y + (h - fitH) / 2, width: fitW, height: fitH)
    }

    // MARK: - 撮影画面の置き方

    /// 撮影画面の置き方。どれも同じ座標（撮影画面の安全領域の左上が原点のことが多い）。
    public struct Layout: Equatable, Sendable {
        /// 置いてよい範囲（ナビゲーションバー・ホームインジケーターを除いた安全領域）。
        public var safeArea: PreviewRect
        /// 映像（＝写真の全体）を出す枠。縦横比は映像と同じ。
        public var image: PreviewRect
        /// 映像の上の黒い帯（高さ 0 のこともある）。
        public var topBar: PreviewRect
        /// 映像の下の黒い帯（高さ 0 のこともある）。
        public var bottomBar: PreviewRect
        /// 下の操作（シャッターの列）を置く場所。下の帯が操作より低いときは、映像の下の端に重なる。
        public var bottomControls: PreviewRect

        /// 下の操作が映像に重なる高さ（0 なら重ならない）。
        public var bottomOverlap: Double { max(0, image.maxY - bottomControls.minY) }
    }

    /// 映像を写真と同じ縦横比で画面の幅に合わせ、余った高さを上下の帯に分ける。
    /// - 下の帯は、シャッターの列（`bottomControlsHeight`）が入る高さを先に取り、余りが多いときは上下で半分ずつ。
    /// - 上の帯が `minimumBarHeight` より薄くなるとき（9:16 に近い画面）は、上の帯を作らず映像を一番上に寄せる。
    ///   余りが操作より少ないときは、下の操作が映像の下の端に重なる（`bottomOverlap`）。
    /// - 画面の幅に合わせると高さが足りないとき（横に広い場所）は、高さに合わせて左右の中央に置く。
    /// - Parameters:
    ///   - safeArea: 置いてよい範囲（ナビゲーションバー・ホームインジケーターを除いた安全領域）。
    ///   - imageAspect: 縦に持って見た映像の幅 / 高さ（`portraitAspect`）。分からなければ nil（3:4 にする）。
    ///   - bottomControlsHeight: 下の操作（シャッターの列）の高さ。
    public static func layout(in safeArea: PreviewRect, imageAspect: Double?, bottomControlsHeight: Double) -> Layout {
        let aspect = isUsable(imageAspect) ? imageAspect! : fallbackPortraitAspect
        let area = PreviewRect(x: safeArea.x, y: safeArea.y, width: max(0, safeArea.width), height: max(0, safeArea.height))
        let fitted = aspectFit(aspect: aspect, in: area)
        let leftover = max(0, area.height - fitted.height)
        let controls = bottomControlsHeight.isFinite ? max(0, bottomControlsHeight) : 0
        var bottom = min(leftover, max(controls, leftover / 2))
        var top = leftover - bottom
        if top < minimumBarHeight {
            bottom += top
            top = 0
        }
        let image = PreviewRect(x: fitted.x, y: area.y + top, width: fitted.width, height: fitted.height)
        let controlsH = min(area.height, max(controls, bottom))
        return Layout(
            safeArea: area,
            image: image,
            topBar: PreviewRect(x: area.x, y: area.y, width: area.width, height: top),
            bottomBar: PreviewRect(x: area.x, y: image.maxY, width: area.width, height: bottom),
            bottomControls: PreviewRect(x: area.x, y: area.maxY - controlsH, width: area.width, height: controlsH)
        )
    }

    /// 映像の上に浮かべる案内（知らせ・方向の地図など）を置ける範囲：映像の枠から、上の帯の中身と下の帯の中身が
    /// 映像に重なっている所を除いたもの。中身の高さは、帯の上端・下端から測った実際の高さ（帯より低ければ帯の高さ）。
    public static func panelArea(_ layout: Layout, topContentHeight: Double, bottomContentHeight: Double) -> PreviewRect {
        let topH = topContentHeight.isFinite ? max(0, topContentHeight) : 0
        let bottomH = bottomContentHeight.isFinite ? max(0, bottomContentHeight) : 0
        let image = layout.image
        let top = min(image.maxY, max(image.minY, layout.safeArea.minY + topH))
        let bottom = min(image.maxY, max(top, layout.safeArea.maxY - bottomH))
        return PreviewRect(x: image.x, y: top, width: image.width, height: bottom - top)
    }

    // MARK: - 写真の点 ↔ 画面の点

    /// ARSCNView と同じ置き方（縦向き＝センサーの画像を時計回りに 90° 回し、view を埋めるように拡大して中央に置く aspect-fill）で、
    /// センサーの向きの画像の 0〜1 の点（原点は左上）→ view の点（pt）。`ARFrame.displayTransform(for: .portrait, viewportSize:)` と同じ。
    /// 撮影画面は view を映像と同じ縦横比にするので、何も切れず、写真の四隅が view の四隅になる。
    public static func viewPoint(fromSensor p: SIMD2<Double>, imageWidth: Double, imageHeight: Double,
                                 viewWidth: Double, viewHeight: Double) -> SIMD2<Double> {
        let shown = shownImageRect(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
        let d = DisplayRotation.displayPoint(fromSensor: p, rotationDegClockwise: portraitRotationDegClockwise)
        return SIMD2(shown.x + d.x * shown.width, shown.y + d.y * shown.height)
    }

    /// view の点（pt）→ センサーの向きの画像の 0〜1 の点（`viewPoint` の逆）。
    public static func sensorPoint(fromView v: SIMD2<Double>, imageWidth: Double, imageHeight: Double,
                                   viewWidth: Double, viewHeight: Double) -> SIMD2<Double> {
        let shown = shownImageRect(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
        guard shown.width > 0, shown.height > 0 else { return SIMD2(0.5, 0.5) }
        let d = SIMD2((v.x - shown.x) / shown.width, (v.y - shown.y) / shown.height)
        return DisplayRotation.sensorPoint(fromDisplay: d, rotationDegClockwise: portraitRotationDegClockwise)
    }

    /// 縦向きに回した画像を view に aspect-fill で置いた範囲（view の座標。view より大きいと、はみ出た所は切れて見えない）。
    /// 画像の大きさが分からないときは、view と同じ範囲（縦横比が合っているとみなす）。
    public static func shownImageRect(imageWidth: Double, imageHeight: Double, viewWidth: Double, viewHeight: Double) -> PreviewRect {
        let vw = max(0, viewWidth), vh = max(0, viewHeight)
        // 縦向きでは、センサーの高さが表示の幅、センサーの幅が表示の高さ。
        let rotatedW = imageHeight, rotatedH = imageWidth
        guard rotatedW.isFinite, rotatedH.isFinite, rotatedW > 0, rotatedH > 0, vw > 0, vh > 0 else {
            return PreviewRect(x: 0, y: 0, width: vw, height: vh)
        }
        let scale = max(vw / rotatedW, vh / rotatedH)
        let w = rotatedW * scale, h = rotatedH * scale
        return PreviewRect(x: (vw - w) / 2, y: (vh - h) / 2, width: w, height: h)
    }

    /// view に見えている写真の割合（表示の幅・高さの向きで 0〜1）。1 と 1 なら写真の全体が見えている。
    public static func visiblePhotoFraction(imageWidth: Double, imageHeight: Double, viewWidth: Double, viewHeight: Double) -> (width: Double, height: Double) {
        let shown = shownImageRect(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight)
        guard shown.width > 0, shown.height > 0 else { return (0, 0) }
        return (min(1, max(0, viewWidth) / shown.width), min(1, max(0, viewHeight) / shown.height))
    }
}
