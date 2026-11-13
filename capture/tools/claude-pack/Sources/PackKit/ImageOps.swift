import Foundation
import CoreGraphics
import ImageIO
import CaptureCore

/// An 8-bit single-channel image (row-major, no padding).
public struct GrayImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Bounding box of pixels ≥ `threshold` (pixels; max edges exclusive), or nil when there are none.
    public func boundingBox(threshold: UInt8 = 128) -> PixelRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] >= threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return PixelRect(minX: Double(minX), minY: Double(minY), maxX: Double(maxX + 1), maxY: Double(maxY + 1))
    }

    /// 0/1 image of pixels ≥ threshold.
    public func binarized(threshold: UInt8 = 128) -> GrayImage {
        GrayImage(width: width, height: height, pixels: pixels.map { $0 >= threshold ? 1 : 0 })
    }

    /// Dilation of a 0/1 image with a (2r+1)² square.
    public func dilated(radius r: Int) -> GrayImage {
        guard r > 0 else { return self }
        var horizontal = GrayImage(width: width, height: height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] != 0 {
                for xx in max(0, x - r)...min(width - 1, x + r) { horizontal.pixels[row + xx] = 1 }
            }
        }
        var out = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width where horizontal.pixels[y * width + x] != 0 {
                for yy in max(0, y - r)...min(height - 1, y + r) { out.pixels[yy * width + x] = 1 }
            }
        }
        return out
    }

    /// 3 × 3 box blur (edges clamp). Used to feather cutout edges by about a pixel.
    public func boxBlurred() -> GrayImage {
        var out = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                for dy in -1...1 {
                    let yy = min(height - 1, max(0, y + dy))
                    for dx in -1...1 {
                        let xx = min(width - 1, max(0, x + dx))
                        sum += Int(pixels[yy * width + xx])
                    }
                }
                out.pixels[y * width + x] = UInt8((sum + 4) / 9)
            }
        }
        return out
    }
}

public enum ImageOps {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case unwritable(String)
        public var description: String {
            switch self {
            case .unreadable(let s): return "cannot read \(s)"
            case .unwritable(let s): return "cannot write \(s)"
            }
        }
    }

    public static func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure.unreadable(url.lastPathComponent) }
        return image
    }

    /// The mask PNG as gray bytes, at full size or downsampled so the long side is at most `maxSide`.
    public static func loadMask(_ url: URL, maxSide: Int? = nil) throws -> GrayImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let image: CGImage?
        if let maxSide {
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image else { throw Failure.unreadable(url.lastPathComponent) }
        return try gray(image)
    }

    /// Draws any image into an 8-bit gray buffer of the same size.
    public static func gray(_ image: CGImage) throws -> GrayImage {
        let w = image.width, h = image.height
        var out = GrayImage(width: w, height: h)
        let ok = out.pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure.unreadable("gray conversion") }
        return out
    }

    /// Crops `crop` (stored-photo pixels, origin top-left) out of `image`, turns it `rotation` degrees clockwise and
    /// scales it to `width × height` (the upright size). Works for RGB photos and gray masks alike.
    public static func uprightCrop(_ image: CGImage, crop: PixelBox, rotationDegClockwise: Int, width: Int, height: Int,
                                   gray: Bool = false) throws -> CGImage {
        guard crop.width > 0, crop.height > 0, crop.x >= 0, crop.y >= 0, crop.maxX <= image.width, crop.maxY <= image.height else {
            throw Failure.unreadable("crop outside the image")
        }
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { throw Failure.unwritable("context") }
        ctx.interpolationQuality = .high
        let rot = DisplayRotation.normalized(rotationDegClockwise)
        let dw = CGFloat(width), dh = CGFloat(height)
        // Size of the (scaled) crop before turning it.
        let sw = rot % 180 == 0 ? dw : dh
        let sh = rot % 180 == 0 ? dh : dw
        // CoreGraphics is y-up: a clockwise turn on screen is a negative angle.
        switch rot {
        case 90: ctx.translateBy(x: 0, y: dh); ctx.rotate(by: -.pi / 2)
        case 180: ctx.translateBy(x: dw, y: dh); ctx.rotate(by: .pi)
        case 270: ctx.translateBy(x: dw, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        // Draw the whole image so that the crop fills (0, 0, sw, sh); the context clips the rest.
        // (CGImage.cropping + a rotated draw mis-sampled rows of small gray images.)
        let sx = sw / CGFloat(crop.width), sy = sh / CGFloat(crop.height)
        let bottom = CGFloat(image.height - crop.maxY)  // y-up: distance of the crop's lower edge from the image bottom
        ctx.draw(image, in: CGRect(x: -CGFloat(crop.x) * sx, y: -bottom * sy, width: CGFloat(image.width) * sx, height: CGFloat(image.height) * sy))
        guard let out = ctx.makeImage() else { throw Failure.unwritable("image") }
        return out
    }

    /// The photo with `alpha` (same size, 255 = object) as its alpha channel: a transparent cutout (RGBA, straight alpha).
    public static func transparentCutout(photo: CGImage, alpha: GrayImage) throws -> CGImage {
        let w = photo.width, h = photo.height
        precondition(alpha.width == w && alpha.height == h)
        // Draw the photo opaque, then write the mask into the alpha byte.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { throw Failure.unwritable("context") }
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgba = [UInt8](UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: w * h * 4), count: w * h * 4))
        // CGContext memory is top row first, same as GrayImage.
        for i in 0..<(w * h) { rgba[i * 4 + 3] = alpha.pixels[i] }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw Failure.unwritable("image") }
        return out
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure.unwritable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unwritable(url.lastPathComponent) }
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw Failure.unwritable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unwritable(url.lastPathComponent) }
    }

    public static func makeGrayImage(_ g: GrayImage) -> CGImage? {
        let data = Data(g.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: g.width, height: g.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: g.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
