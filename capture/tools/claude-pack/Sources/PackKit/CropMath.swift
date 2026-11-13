import Foundation
import CaptureCore

/// Where to cut a view out of the stored (sensor-orientation) photo, and how it looks once turned upright.
public enum CropMath {
    /// Margin added on every side, as a fraction of the box's longer side.
    public static let margin = 0.2
    /// The crop is widened along its short side until it is at most this elongated ("square-ish").
    public static let maxAspect = 4.0 / 3.0
    /// Long side of a view image (Claude's vision input works best up to about 1568 px).
    public static let maxOutputSide = 1568

    /// Crop rectangle (stored-photo pixels) around `box`: `margin` on every side, widened to `maxAspect`,
    /// shifted inside the photo keeping its size, then clipped to the photo. nil for an empty box or photo.
    public static func crop(around box: PixelRect, imageWidth: Int, imageHeight: Int,
                            margin: Double = margin, maxAspect: Double = maxAspect) -> PixelBox? {
        let W = Double(imageWidth), H = Double(imageHeight)
        guard imageWidth > 0, imageHeight > 0, !box.isEmpty, box.clamped(width: W, height: H) != nil else { return nil }
        let m = margin * max(box.width, box.height)
        var w = box.width + 2 * m
        var h = box.height + 2 * m
        if w / h > maxAspect { h = w / maxAspect } else if h / w > maxAspect { w = h / maxAspect }
        w = min(w, W)
        h = min(h, H)
        let x0 = min(max(box.midX - w / 2, 0), W - w)
        let y0 = min(max(box.midY - h / 2, 0), H - h)
        let ix0 = max(0, Int(x0.rounded(.down))), iy0 = max(0, Int(y0.rounded(.down)))
        let ix1 = min(imageWidth, Int((x0 + w).rounded(.up))), iy1 = min(imageHeight, Int((y0 + h).rounded(.up)))
        guard ix1 > ix0, iy1 > iy0 else { return nil }
        return PixelBox(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0)
    }

    /// The same rectangle in the upright image (the stored photo turned `rotation` degrees clockwise,
    /// the receiver's `upright/` copy). Matches `DisplayRotation.displayPoint` in pixels.
    public static func upright(_ r: PixelBox, imageWidth W: Int, imageHeight H: Int, rotationDegClockwise: Int) -> PixelBox {
        switch DisplayRotation.normalized(rotationDegClockwise) {
        case 90: return PixelBox(x: H - r.maxY, y: r.x, width: r.height, height: r.width)
        case 180: return PixelBox(x: W - r.maxX, y: H - r.maxY, width: r.width, height: r.height)
        case 270: return PixelBox(x: r.y, y: W - r.maxX, width: r.height, height: r.width)
        default: return r
        }
    }

    /// Output size (upright) of a crop: long side at most `maxSide`, never larger than the crop itself.
    public static func outputSize(crop: PixelBox, rotationDegClockwise: Int, maxSide: Int = maxOutputSide) -> (width: Int, height: Int) {
        let size = DisplayRotation.displaySize(width: crop.width, height: crop.height, rotationDegClockwise: rotationDegClockwise)
        let scale = min(1, Double(maxSide) / Double(max(size.width, size.height)))
        return (max(1, Int((Double(size.width) * scale).rounded())), max(1, Int((Double(size.height) * scale).rounded())))
    }
}
