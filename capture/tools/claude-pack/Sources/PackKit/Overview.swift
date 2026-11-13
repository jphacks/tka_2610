import Foundation
import CoreGraphics
import CoreImage

/// The contact sheet (`overview.jpg`): the chosen views placed where the camera stood, seen from above
/// (front at the bottom, right on the right, `top` in the middle), plus `front_high`, and the measured size.
public enum Overview {
    public static let tile = 420
    public static let labelHeight = 34
    public static let gap = 8
    public static let footerHeight = 104

    /// Grid cell (column, row) of each view.
    public static let layout: [String: (col: Int, row: Int)] = [
        "back_left": (0, 0), "back": (1, 0), "back_right": (2, 0),
        "left": (0, 1), "top": (1, 1), "right": (2, 1),
        "front_left": (0, 2), "front": (1, 2), "front_right": (2, 2),
        "front_high": (1, 3),
    ]

    public struct Tile {
        public var name: String
        public var label: String
        public var image: CGImage?
        public init(name: String, label: String, image: CGImage?) {
            self.name = name
            self.label = label
            self.image = image
        }
    }

    public static func render(tiles: [Tile], footer: [String]) throws -> CGImage {
        let cols = 3, rows = tiles.contains { $0.name == "front_high" } ? 4 : 3
        let cellH = tile + labelHeight
        let width = cols * tile + (cols + 1) * gap
        let height = rows * cellH + (rows + 1) * gap + footerHeight
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageOps.Failure.unwritable("overview")
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = TextRenderer()

        for t in tiles {
            guard let cell = layout[t.name] else { continue }
            let x = gap + cell.col * (tile + gap)
            // CoreGraphics is y-up: row 0 at the top.
            let yTop = height - (gap + cell.row * (cellH + gap))
            let imageRect = CGRect(x: x, y: yTop - tile, width: tile, height: tile)
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(imageRect)
            if let img = t.image {
                let s = min(Double(tile) / Double(img.width), Double(tile) / Double(img.height))
                let w = Double(img.width) * s, h = Double(img.height) * s
                ctx.draw(img, in: CGRect(x: imageRect.midX - w / 2, y: imageRect.midY - h / 2, width: w, height: h))
            }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            let labelRect = CGRect(x: x, y: yTop - tile - labelHeight, width: tile, height: labelHeight)
            ctx.fill(labelRect)
            if let label = text.image(t.label, size: 21) {
                let lw = min(Double(label.width), Double(tile - 8))
                let lh = Double(label.height) * lw / Double(label.width)
                ctx.draw(label, in: CGRect(x: labelRect.minX + 6, y: labelRect.midY - lh / 2, width: lw, height: lh))
            }
        }

        var y = Double(footerHeight) - 10
        for line in footer {
            guard let img = text.image(line, size: 20) else { continue }
            let lw = min(Double(img.width), Double(width - 2 * gap))
            let lh = Double(img.height) * lw / Double(img.width)
            y -= lh + 2
            ctx.draw(img, in: CGRect(x: Double(gap), y: y, width: lw, height: lh))
        }
        guard let out = ctx.makeImage() else { throw ImageOps.Failure.unwritable("overview") }
        return out
    }
}

/// Black text on a transparent background (CoreImage `CITextImageGenerator`).
final class TextRenderer {
    let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    func image(_ string: String, size: Double, font: String = "Helvetica") -> CGImage? {
        guard !string.isEmpty, let f = CIFilter(name: "CITextImageGenerator") else { return nil }
        f.setValue(string, forKey: "inputText")
        f.setValue(font, forKey: "inputFontName")
        f.setValue(size, forKey: "inputFontSize")
        f.setValue(1.0, forKey: "inputScaleFactor")
        guard let out = f.outputImage, !out.extent.isEmpty, !out.extent.isInfinite else { return nil }
        return context.createCGImage(out, from: out.extent)
    }
}
