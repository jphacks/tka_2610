import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// ARKit の YCbCr のピクセルバッファを JPEG にする（回転・縮小なし、EXIF Orientation 1、sRGB）。
final class JPEGEncoder: @unchecked Sendable {
    static let shared = JPEGEncoder()

    /// 使い回す CIContext（作るのが重いため）。CIContext はスレッドをまたいで使ってよい。
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func jpeg(from pixelBuffer: CVPixelBuffer, quality: Double = 0.92) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}

enum PixelBufferLuma {
    /// Y 面（明るさ）を、ROI の中だけ飛ばし読みして小さく写す。ピクセルバッファは呼び出しの中でだけ触る。
    static func downsampledLuma(_ pixelBuffer: CVPixelBuffer, roi: PixelRect?, maxSamples: Int = ImageMetrics.defaultSampleSize) -> LumaBuffer? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        return ImageMetrics.downsample(base: UnsafeRawPointer(base), width: width, height: height, bytesPerRow: bytesPerRow, roi: roi, maxSamples: maxSamples)
    }
}

enum SavedPhotoAnalyzer {
    /// 保存した JPEG を縮小して読み、作品の範囲（あれば）の明るさとシャープさを測る。
    /// - Parameter roi: 保存した画像のピクセルでの作品の範囲。
    static func metrics(jpegURL: URL, imageSize: PixelSize, roi: PixelRect?) -> ImageMetricsResult? {
        guard let thumbnail = ImageLoading.thumbnail(url: jpegURL, maxPixel: 1024),
              let gray = ImageLoading.grayBuffer(from: thumbnail) else { return nil }
        let sx = Double(gray.width) / Double(max(1, imageSize.width))
        let sy = Double(gray.height) / Double(max(1, imageSize.height))
        let scaledROI = roi.map { $0.scaled(x: sx, y: sy) }
        return ImageMetrics.compute(gray, roi: scaledROI) ?? ImageMetrics.compute(gray)
    }

    /// 写真の姿勢で作品の円柱を投影した範囲（保存した画像のピクセル）。基準や大きさが無ければ nil。
    static func objectRegion(photo: Photo, session: CaptureSession, expandBy fraction: Double = 0.1) -> PixelRect? {
        // 向きで案内したセッション：作品の位置は撮るときには分からないので、十字のまわり（切り抜きと同じ正方形）。
        if session.usesHeadingGuidance {
            return MaskCropPlanner.crosshairPlan(imageWidth: photo.image.width, imageHeight: photo.image.height).region.rect
        }
        guard let reference = session.referenceFrame(id: photo.referenceFrameId), let base = reference.basePointWorld?.simd,
              let object = session.object else { return nil }
        let k = photo.camera.intrinsicsResolution
        let camera = CameraModel(
            cameraToWorld: photo.camera.cameraToWorld.simd, intrinsics: photo.camera.intrinsics.simd,
            imageWidth: Double(k.width), imageHeight: Double(k.height)
        )
        let cylinder = ObjectCylinder(basePoint: base, radiusM: object.radiusM, heightM: object.heightM)
        let result = Projection.evaluate(cylinder: cylinder, camera: camera)
        guard let box = result.boundingBox else { return nil }
        // K の画像と保存した画像の大きさが違うときは、保存した画像に合わせる。
        let sx = Double(photo.image.width) / Double(max(1, k.width))
        let sy = Double(photo.image.height) / Double(max(1, k.height))
        return box.expanded(by: fraction).scaled(x: sx, y: sy)
    }
}
