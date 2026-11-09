import Foundation
import CoreGraphics
import CoreMotion
import CoreVideo
import ImageIO
import RealityKit
import CaptureCore

/// What happened when one sample was built (filled while PhotogrammetrySession iterates the input).
public struct SampleLoadRecord: Codable, Equatable, Sendable {
    public var sampleId: Int
    public var photoId: String
    public var imageWidth: Int
    public var imageHeight: Int
    public var imagePixelFormat: String
    public var decodeSeconds: Double
    /// Fraction of mask pixels >= 128 (object). Null when no mask was attached.
    @NullCodable public var maskCoverage: Double?
    /// Mask pixels that are neither 0 nor 255.
    @NullCodable public var maskNonBinaryPixels: Int?
    @NullCodable public var maskPixelFormat: String?
    /// Set when a planned mask could not be attached (the sample is still used without it).
    @NullCodable public var maskError: String?
    /// Set when the sample could not be built at all (then it is not handed to the session).
    @NullCodable public var error: String?
}

public final class SampleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int: SampleLoadRecord] = [:]
    public init() {}
    func put(_ r: SampleLoadRecord) {
        lock.lock(); defer { lock.unlock() }
        records[r.sampleId] = r
    }
    public var all: [SampleLoadRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.sampleId < $1.sampleId }
    }
}

public enum SampleFactory {
    struct BuildError: Error, CustomStringConvertible {
        var description: String
    }

    /// A lazy sequence: each sample (≈ 48 MB image + 12 MB mask at 4032×3024) is created only when the
    /// session asks for it. Samples that cannot be built are skipped and recorded in `log`.
    public static func samples(for inputs: [PlannedInput], folder: URL, log: SampleLog) -> AnySequence<PhotogrammetrySample> {
        let included = inputs.filter(\.included)
        return AnySequence(included.lazy.compactMap { input -> PhotogrammetrySample? in
            autoreleasepool { make(input, folder: folder, log: log) }
        })
    }

    static func make(_ input: PlannedInput, folder: URL, log: SampleLog) -> PhotogrammetrySample? {
        let start = Date()
        var record = SampleLoadRecord(sampleId: input.sampleId, photoId: input.photoId, imageWidth: 0, imageHeight: 0,
                                      imagePixelFormat: "", decodeSeconds: 0)
        defer {
            record.decodeSeconds = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
            log.put(record)
        }
        let imageURL = folder.appendingPathComponent(input.imageFile)
        do {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw BuildError(description: "cannot decode \(input.imageFile)") }
            // No EXIF rotation is applied: CGImageSourceCreateImageAtIndex returns the stored (sensor) orientation,
            // which is also the orientation of the masks and the intrinsics.
            let buffer = try bgraBuffer(from: image)
            record.imageWidth = image.width
            record.imageHeight = image.height
            record.imagePixelFormat = fourCC(CVPixelBufferGetPixelFormatType(buffer))
            var sample = PhotogrammetrySample(id: input.sampleId, image: buffer)

            var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
            var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            if exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] == nil {
                exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = input.focalLength35mm
            }
            metadata[kCGImagePropertyExifDictionary as String] = exif
            if metadata[kCGImagePropertyOrientation as String] == nil {
                metadata[kCGImagePropertyOrientation as String] = 1   // session.json: exifOrientation 1
            }
            sample.metadata = metadata

            if let g = input.gravity {
                sample.gravity = CMAcceleration(x: g[0], y: g[1], z: g[2])
            }

            if input.maskUsed, let maskFile = input.maskFile {
                do {
                    let (mask, coverage, nonBinary) = try maskBuffer(url: folder.appendingPathComponent(maskFile),
                                                                    width: image.width, height: image.height)
                    sample.objectMask = mask
                    record.maskCoverage = (coverage * 1e5).rounded() / 1e5
                    record.maskNonBinaryPixels = nonBinary
                    record.maskPixelFormat = fourCC(CVPixelBufferGetPixelFormatType(mask))
                } catch {
                    record.maskError = "\(error)"
                }
            }
            return sample
        } catch {
            record.error = "\(error)"
            return nil
        }
    }

    static let bufferAttributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]

    /// kCVPixelFormatType_32BGRA (one of the two formats the PhotogrammetrySample.image doc accepts).
    static func bgraBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                         bufferAttributes as CFDictionary, &out)
        guard status == kCVReturnSuccess, let buffer = out else { throw BuildError(description: "CVPixelBufferCreate failed (\(status))") }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw BuildError(description: "cannot create BGRA context") }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        return buffer
    }

    /// kCVPixelFormatType_OneComponent8, same width/height as the image (PhotogrammetrySample.objectMask doc).
    /// The session ignores image pixels whose mask value is 0; the session's PNGs use 255 = object, 0 = background.
    static func maskBuffer(url: URL, width: Int, height: Int) throws -> (CVPixelBuffer, Double, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw BuildError(description: "cannot decode mask \(url.lastPathComponent)") }
        guard image.width == width, image.height == height else {
            throw BuildError(description: "mask is \(image.width)x\(image.height), image is \(width)x\(height)")
        }
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8,
                                         bufferAttributes as CFDictionary, &out)
        guard status == kCVReturnSuccess, let buffer = out else { throw BuildError(description: "CVPixelBufferCreate (mask) failed (\(status))") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw BuildError(description: "no mask base address") }
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)

        let isPlainGray8 = image.bitsPerPixel == 8 && image.bitsPerComponent == 8
            && image.colorSpace?.model == .monochrome && image.alphaInfo == .none
        if isPlainGray8, let data = image.dataProvider?.data, let src = CFDataGetBytePtr(data) {
            // Copy the stored values unchanged (no colour matching).
            let srcStride = image.bytesPerRow
            for y in 0..<height {
                memcpy(base + y * dstStride, src + y * srcStride, width)
            }
        } else {
            guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: dstStride,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw BuildError(description: "cannot create gray context") }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var object = 0, nonBinary = 0
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = p + y * dstStride
            for x in 0..<width {
                let v = row[x]
                if v >= 128 { object += 1 }
                if v != 0 && v != 255 { nonBinary += 1 }
            }
        }
        return (buffer, Double(object) / Double(width * height), nonBinary)
    }

    static func fourCC(_ code: OSType) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let s = String(chars)
        return s.allSatisfy { $0.isASCII && !$0.isWhitespace || $0 == " " } ? s : String(code)
    }
}
