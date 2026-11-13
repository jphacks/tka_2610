import Foundation

/// 8 bit の明るさ（Y）の画像。`bytesPerRow` は幅より大きいことがある（行の詰め物）。
public struct LumaBuffer: Equatable, Sendable {
    public var pixels: [UInt8]
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int

    public init(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int? = nil) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow ?? width
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * bytesPerRow + x]
    }
}

public struct ImageMetricsResult: Equatable, Sendable {
    /// 平均の明るさ（0〜1）。
    public var meanLuma: Double
    /// 明るさを 0〜1 にした縮小画像の、4 近傍ラプラシアンの分散。大きいほどくっきり。
    public var laplacianVariance: Double
    public var sampleWidth: Int
    public var sampleHeight: Int
}

public enum ImageMetrics {
    /// 縮小したときの長い辺の点の数の目安。撮影前の映像と保存した写真で同じにして、値を比べられるようにする。
    public static let defaultSampleSize = 256

    /// 行ごとに飛ばして読んで縮小する（ROI があればその範囲だけ）。
    /// ARKit の Y 面のような生のメモリから読むために、ポインタを受け取る。
    public static func downsample(
        base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
        roi: PixelRect? = nil, maxSamples: Int = defaultSampleSize
    ) -> LumaBuffer? {
        let full = PixelRect(x: 0, y: 0, width: Double(width), height: Double(height))
        guard let area = (roi ?? full).clamped(width: Double(width), height: Double(height)) else { return nil }
        let x0 = Int(area.minX.rounded(.down)), y0 = Int(area.minY.rounded(.down))
        let x1 = min(width, Int(area.maxX.rounded(.up))), y1 = min(height, Int(area.maxY.rounded(.up)))
        let w = x1 - x0, h = y1 - y0
        guard w >= 3, h >= 3 else { return nil }
        let step = max(1, Int((Double(max(w, h)) / Double(max(1, maxSamples))).rounded(.up)))
        let sw = (w + step - 1) / step, sh = (h + step - 1) / step
        guard sw >= 3, sh >= 3 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: sw * sh)
        out.withUnsafeMutableBufferPointer { dst in
            for j in 0..<sh {
                let row = bytes + (y0 + j * step) * bytesPerRow + x0
                for i in 0..<sw {
                    dst[j * sw + i] = row[i * step]
                }
            }
        }
        return LumaBuffer(pixels: out, width: sw, height: sh)
    }

    /// `LumaBuffer` から縮小する。
    public static func downsample(_ buffer: LumaBuffer, roi: PixelRect? = nil, maxSamples: Int = defaultSampleSize) -> LumaBuffer? {
        buffer.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return downsample(base: base, width: buffer.width, height: buffer.height, bytesPerRow: buffer.bytesPerRow, roi: roi, maxSamples: maxSamples)
        }
    }

    /// 平均の明るさとラプラシアンの分散。ROI があれば先に切り出して縮小する。
    public static func compute(_ buffer: LumaBuffer, roi: PixelRect? = nil, maxSamples: Int = defaultSampleSize) -> ImageMetricsResult? {
        guard let small = downsample(buffer, roi: roi, maxSamples: maxSamples) else { return nil }
        return computeOnSamples(small)
    }

    /// 縮小済みの画像（行の詰め物なし、幅・高さ 3 以上）の値。
    public static func computeOnSamples(_ s: LumaBuffer) -> ImageMetricsResult? {
        let w = s.width, h = s.height
        guard w >= 3, h >= 3 else { return nil }
        var sum = 0.0
        for y in 0..<h {
            for x in 0..<w { sum += Double(s[x, y]) }
        }
        let mean = sum / Double(w * h) / 255

        var lapSum = 0.0, lapSq = 0.0
        var n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(s[x, y])
                let l = Double(s[x - 1, y]) + Double(s[x + 1, y]) + Double(s[x, y - 1]) + Double(s[x, y + 1]) - 4 * c
                let v = l / 255
                lapSum += v
                lapSq += v * v
                n += 1
            }
        }
        let lapMean = lapSum / n
        let variance = max(0, lapSq / n - lapMean * lapMean)
        return ImageMetricsResult(meanLuma: mean, laplacianVariance: variance, sampleWidth: w, sampleHeight: h)
    }
}
