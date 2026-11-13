import ARKit
@preconcurrency import AVFoundation

/// ピントと露出の基準の位置を、作品の中心へ合わせる（1 秒に 1 回まで、失敗しても無視）。
/// ARKit が使うカメラ（configurableCaptureDeviceForPrimaryCamera、iOS 16+）を設定するだけで、
/// 別の AVCaptureSession は作らない。
@MainActor
final class FocusController {
    private var lastUpdate = Date.distantPast
    private var lastPoint: CGPoint?
    private let queue = DispatchQueue(label: "memoria.focus", qos: .utility)
    var isEnabled = true

    /// - Parameter point: 0〜1（センサーの向きの画像の左上が原点。AVCaptureDevice の point of interest と同じ座標）。
    func focus(at point: CGPoint) {
        guard isEnabled, Date().timeIntervalSince(lastUpdate) >= 1 else { return }
        if let last = lastPoint, hypot(last.x - point.x, last.y - point.y) < 0.05 { return }
        let clamped = CGPoint(x: min(0.95, max(0.05, point.x)), y: min(0.95, max(0.05, point.y)))
        lastUpdate = Date()
        lastPoint = clamped
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
            } catch {
                return
            }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = clamped
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = clamped
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    func reset() {
        lastPoint = nil
        lastUpdate = .distantPast
    }
}
