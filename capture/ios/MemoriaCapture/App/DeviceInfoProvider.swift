import CaptureCore
import UIKit

enum DeviceInfoProvider {
    /// `iPhone15,4` のような機種の識別子。シミュレーターでは実機の識別子を環境変数から取る。
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    @MainActor
    static func current() -> DeviceInfo {
        DeviceInfo(
            model: modelIdentifier, systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion, appVersion: appVersion, appBuild: appBuild
        )
    }

    /// UIDeviceOrientation の名前（session.json の `deviceOrientation`）。
    static func name(of orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown"
        }
    }
}
