import CaptureCore
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 写真・マスクの縮小画像（ImageIO で縮小して読む。12MP の画像をまるごと UIImage にしない）。
enum ImageLoading {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// 長い辺が `maxPixel` 以下の画像（向きはファイルのまま＝センサーの向き）。
    static func thumbnail(url: URL, maxPixel: Int) -> CGImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(maxPixel)#\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// まっすぐに回した JPEG（memoria の Web に渡す写真）。回転は画素に焼き込み（EXIF の向きに頼らない）、
    /// 長い辺を `maxPixel` 以下に縮める。重いので main スレッドの外で呼ぶ。読めない・作れなければ nil。
    /// 縮小の控え（`cache`）は使わない（大きな画像で一覧の縮小画像を追い出さないため）。
    static func uprightJPEG(url: URL, rotation: Int, maxPixel: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let upright = rotated(image, clockwise: rotation) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, upright, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 画像を時計回りに 0・90・180・270° 回した画像（画素を並べ替える）。
    static func rotated(_ image: CGImage, clockwise degrees: Int) -> CGImage? {
        let turn = DisplayRotation.normalized(degrees)
        if turn == 0 { return image }
        let w = image.width, h = image.height
        let (outW, outH) = turn % 180 == 0 ? (w, h) : (h, w)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // CGContext は y が上向き。見た目で時計回りに回すのは、数学の角度では −θ。
        switch turn {
        case 90:
            context.translateBy(x: 0, y: CGFloat(outH))
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: CGFloat(outW), y: CGFloat(outH))
            context.rotate(by: .pi)
        default:  // 270
            context.translateBy(x: CGFloat(outW), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// 時計回りの角度 → UIImage の向き（表示のためだけに回す）。
    static func orientation(clockwise degrees: Int) -> UIImage.Orientation {
        switch DisplayRotation.normalized(degrees) {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    static func uiImage(_ image: CGImage, rotation: Int) -> UIImage {
        UIImage(cgImage: image, scale: 1, orientation: orientation(clockwise: rotation))
    }

    /// 8 bit グレーの PNG を作る。
    static func grayPNG(pixels: [UInt8], width: Int, height: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 画像を 8 bit グレーにする（保存した写真の明るさ・シャープさを測るため）。
    static func grayBuffer(from image: CGImage) -> LumaBuffer? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? LumaBuffer(pixels: pixels, width: width, height: height) : nil
    }
}

/// 写真の縮小画像を、まっすぐに回して表示する。
struct PhotoThumbnail: View {
    let url: URL
    let rotation: Int
    var maxPixel: Int = 360
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
                ProgressView()
            }
        }
        .task(id: "\(url.path)#\(rotation)#\(maxPixel)") {
            let url = self.url, maxPixel = self.maxPixel, rotation = self.rotation
            let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                ImageLoading.thumbnail(url: url, maxPixel: maxPixel).map { ImageLoading.uiImage($0, rotation: rotation) }
            }.value
            image = loaded
        }
    }
}
