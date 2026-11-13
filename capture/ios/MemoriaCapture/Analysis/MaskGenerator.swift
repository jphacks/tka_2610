import CaptureCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

enum MaskGeneratorError: LocalizedError {
    case simulatorUnsupported
    case visionFailed(String)
    case pixelFormat(OSType)
    case encodeFailed
    case imageUnreadable
    case imageSizeMismatch(Int, Int)
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .imageUnreadable: return "photoUnreadable"
        case .imageSizeMismatch(let w, let h): return "photoSizeMismatch \(w)x\(h)"
        case .cropFailed: return "cropFailed"
        case .simulatorUnsupported: return "simulatorUnsupported"
        case .visionFailed(let message): return "vision: \(message)"
        case .pixelFormat(let format): return "unexpectedPixelFormat \(format)"
        case .encodeFailed: return "pngEncodeFailed"
        }
    }
}

/// 写真 1 枚の Vision の結果（物の番号の画像を持つ）。マスクを作り直すときに使い回す。
/// Vision には写真の全体ではなく `plan.region` を切り抜いた画像を渡す（物の番号の画像は切り抜きに対する座標）。
final class InstanceAnalysis: @unchecked Sendable {
    let plan: MaskCropPlan
    let handler: VNImageRequestHandler
    let observation: VNInstanceMaskObservation?
    let labelMap: InstanceLabelMap?

    init(plan: MaskCropPlan, handler: VNImageRequestHandler, observation: VNInstanceMaskObservation?, labelMap: InstanceLabelMap?) {
        self.plan = plan
        self.handler = handler
        self.observation = observation
        self.labelMap = labelMap
    }

    var instanceCount: Int { observation?.allInstances.count ?? 0 }

    /// 写真の 0〜1 に正規化した点（センサーの向き）にある物の番号（切り抜きの外・背景は 0）。
    func label(atNormalizedImagePoint n: SIMD2<Double>) -> Int {
        guard let map = labelMap, let p = plan.labelMapPixel(fromNormalizedImage: n, mapWidth: map.width, mapHeight: map.height) else { return 0 }
        return map.label(x: p.x, y: p.y)
    }

    /// 自動で選ぶ（作品の範囲と重なる物。選んだ物が切り抜きのほとんどを占めるなら、作品の輪郭とよく重なる物）。
    func autoSelect() -> [Int] {
        guard let map = labelMap, instanceCount > 0 else { return [] }
        return MaskInstanceSelector.autoSelect(
            map: map, roi: plan.selectionROI(mapWidth: map.width, mapHeight: map.height),
            silhouette: plan.silhouette(mapWidth: map.width, mapHeight: map.height)
        )
    }
}

/// VNGenerateForegroundInstanceMaskRequest（iOS 17）で作品のマスクを作る。
/// 保存した写真（センサーの向き、EXIF 1）を切り抜いて `.up` で渡し、できたマスクを写真と同じ大きさの画像に貼るので、
/// マスクは写真と同じ向き・大きさになる（切り抜きの外は 0）。
enum MaskGenerator {
    /// 保存した写真を読む（回さない。EXIF Orientation は 1）。
    static func loadImage(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw MaskGeneratorError.imageUnreadable
        }
        return image
    }

    static func analyze(imageURL: URL, plan: MaskCropPlan) throws -> InstanceAnalysis {
        try analyze(image: try loadImage(url: imageURL), plan: plan)
    }

    static func analyze(image: CGImage, plan: MaskCropPlan) throws -> InstanceAnalysis {
        #if targetEnvironment(simulator)
        throw MaskGeneratorError.simulatorUnsupported
        #else
        guard image.width == plan.imageWidth, image.height == plan.imageHeight else {
            throw MaskGeneratorError.imageSizeMismatch(image.width, image.height)
        }
        let input = try crop(image, to: plan.region)
        let handler = VNImageRequestHandler(cgImage: input, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw MaskGeneratorError.visionFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first else {
            return InstanceAnalysis(plan: plan, handler: handler, observation: nil, labelMap: nil)
        }
        return InstanceAnalysis(plan: plan, handler: handler, observation: observation, labelMap: try labelMap(observation.instanceMask))
        #endif
    }

    /// 切り抜いた画像（自分のメモリに写す。写真全体のデコード結果を持ち続けないため）。全体ならそのまま。
    private static func crop(_ image: CGImage, to region: PixelBox) throws -> CGImage {
        if region.x == 0, region.y == 0, region.width == image.width, region.height == image.height { return image }
        guard let cropped = image.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)),
              let context = CGContext(
                data: nil, width: region.width, height: region.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw MaskGeneratorError.cropFailed }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        guard let copy = context.makeImage() else { throw MaskGeneratorError.cropFailed }
        return copy
    }

    /// 物の番号の画像（OneComponent8）を写す。
    private static func labelMap(_ buffer: CVPixelBuffer) throws -> InstanceLabelMap {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent8 else { throw MaskGeneratorError.pixelFormat(format) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MaskGeneratorError.pixelFormat(format) }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var labels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { labels[y * width + x] = pointer[y * bytesPerRow + x] }
        }
        return InstanceLabelMap(labels: labels, width: width, height: height)
    }

    /// 選んだ物だけのマスク（写真と同じ大きさ、8 bit グレー、255 = 作品、切り抜きの外は 0）の PNG と、
    /// 作品の輪郭と比べた確かめの結果（`mask.check`）。
    static func maskPNG(analysis: InstanceAnalysis, instances: [Int]) throws -> (png: Data, width: Int, height: Int, check: MaskCheck) {
        guard let observation = analysis.observation else { throw MaskGeneratorError.visionFailed("noObservation") }
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(instances), from: analysis.handler)
        } catch {
            throw MaskGeneratorError.visionFailed(error.localizedDescription)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let region = analysis.plan.region
        guard width == region.width, height == region.height else {
            throw MaskGeneratorError.visionFailed("scaledMaskSize \(width)x\(height) != crop \(region.width)x\(region.height)")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MaskGeneratorError.pixelFormat(format) }
        var pixels = [UInt8](repeating: 0, count: width * height)
        switch format {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<width where row[x] >= 0.5 { pixels[y * width + x] = 255 }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width where row[x] >= 128 { pixels[y * width + x] = 255 }
            }
        default:
            throw MaskGeneratorError.pixelFormat(format)
        }
        let plan = analysis.plan
        let check = MaskPlausibility.evaluate(cropMask: pixels, width: width, height: height, plan: plan)
        let full = MaskCanvas.paste(pixels, region: region, fullWidth: plan.imageWidth, fullHeight: plan.imageHeight)
        guard let png = ImageLoading.grayPNG(pixels: full, width: plan.imageWidth, height: plan.imageHeight) else { throw MaskGeneratorError.encodeFailed }
        return (png, plan.imageWidth, plan.imageHeight, check)
    }

    /// 保存したマスク（写真と同じ大きさの PNG）を、作品の輪郭と比べて確かめる（`mask.check` の無い前の版のマスクのため）。
    /// 確かめるだけなので縮小して読む。
    static func checkSavedMask(url: URL, plan: MaskCropPlan?) -> MaskCheck? {
        guard let plan else { return .unknown }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: false,
              ] as CFDictionary),
              let gray = ImageLoading.grayBuffer(from: image) else { return nil }
        return MaskPlausibility.evaluate(fullMask: gray.pixels, width: gray.width, height: gray.height, plan: plan)
    }
}
