import CaptureCore
import Foundation
import SwiftUI

/// 端末に保存する設定（受信側・ペアリングコード・撮影方向・自動撮影）。
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// 受信側の URL（`http://host:port`）。
    @Published var receiverURLString: String { didSet { defaults.set(receiverURLString, forKey: Keys.receiverURL) } }
    /// 受信側の名前（Bonjour のサービス名、または ping の name）。
    @Published var receiverName: String { didSet { defaults.set(receiverName, forKey: Keys.receiverName) } }
    /// 6 桁のペアリングコード。
    @Published var pairingCode: String { didSet { defaults.set(pairingCode, forKey: Keys.pairingCode) } }
    /// 新しいセッションで使う撮影方向。
    @Published var planPreset: DirectionPlanPreset { didSet { defaults.set(planPreset.rawValue, forKey: Keys.planPreset) } }
    /// 条件がそろったら自動で撮る。
    @Published var autoCaptureEnabled: Bool { didSet { defaults.set(autoCaptureEnabled, forKey: Keys.autoCapture) } }

    /// 判定のしきい値（既定値のまま。変えるときは CaptureCore の QualityThresholds）。
    let thresholds = QualityThresholds.default

    private enum Keys {
        static let receiverURL = "receiverURL"
        static let receiverName = "receiverName"
        static let pairingCode = "pairingCode"
        static let planPreset = "planPreset"
        static let autoCapture = "autoCapture"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        receiverURLString = defaults.string(forKey: Keys.receiverURL) ?? ""
        receiverName = defaults.string(forKey: Keys.receiverName) ?? ""
        pairingCode = defaults.string(forKey: Keys.pairingCode) ?? ""
        planPreset = defaults.string(forKey: Keys.planPreset).flatMap(DirectionPlanPreset.init(rawValue:)) ?? .default
        autoCaptureEnabled = defaults.object(forKey: Keys.autoCapture) as? Bool ?? true
    }

    var receiverURL: URL? { TransferClient.receiverURL(fromUserInput: receiverURLString) }

    var trimmedPairingCode: String { pairingCode.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isReceiverConfigured: Bool { receiverURL != nil && !trimmedPairingCode.isEmpty }

    var receiverDisplayName: String {
        if !receiverName.isEmpty { return receiverName }
        return receiverURLString.isEmpty ? "未設定" : receiverURLString
    }
}
