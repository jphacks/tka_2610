import CaptureCore
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import Vision

/// 平面の作品の用紙（四角）を Vision で見つける。結果は写真の 0〜1 の座標（原点は左上、センサーの向き）。
enum SheetDetector {
    struct Result: Sendable {
        /// 四隅（順は Vision のまま。並べ直しは `FlatGeometry.orderCorners`）。
        let corners: [SIMD2<Double>]
        let confidence: Double
    }

    /// - Parameter minimumSize: 用紙の短い辺の下限（画像の短い辺に対する割合）。
    static func detect(pixelBuffer: CVPixelBuffer, minimumSize: Float = 0.2) -> Result? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        // 細長い紙から正方形まで。真上から少しずれても見つかるように、直角からのずれを広めに許す。
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = minimumSize
        request.quadratureTolerance = 25
        request.minimumConfidence = 0.6
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        // Vision の座標は原点が左下なので、上下を反転する。
        let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            .map { SIMD2(Double($0.x), 1 - Double($0.y)) }
        return Result(corners: corners, confidence: Double(observation.confidence))
    }
}

/// 用紙の四隅から、遠近を直してまっすぐにした画像を作る（Core Image の CIPerspectiveCorrection）。
final class SheetRectifier: @unchecked Sendable {
    static let shared = SheetRectifier()

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 四隅（保存した写真のピクセル。左上…は、まっすぐに回して見たときの位置）の中を、`width × height` の画像にする。
    /// 左上の角が補正した画像の左上になるので、まっすぐに回した向きになる。
    func rectifiedJPEG(pixelBuffer: CVPixelBuffer, corners: FlatQuad, width: Int, height: Int, quality: Double = 0.92) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let h = image.extent.height
        // Core Image は原点が左下。
        func point(_ p: PixelPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = point(corners.topLeft)
        filter.topRight = point(corners.topRight)
        filter.bottomRight = point(corners.bottomRight)
        filter.bottomLeft = point(corners.bottomLeft)
        filter.crop = true
        guard var output = filter.outputImage, output.extent.width >= 1, output.extent.height >= 1 else { return nil }
        output = output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
        // 縦横比を、測った実寸（無ければ辺の長さ）に合わせる。
        let sx = CGFloat(width) / output.extent.width, sy = CGFloat(height) / output.extent.height
        output = output.samplingLinear().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        return context.jpegRepresentation(of: output, colorSpace: colorSpace, options: options)
    }
}
