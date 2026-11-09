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
