import CaptureCore
import SwiftUI

/// 設定（送り先の Mac・ペアリングコード・接続の確認・撮る方向・自動撮影）。
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var transfer: TransferCoordinator
    @StateObject private var browser = ReceiverBrowser()
    @State private var pingResult: String?
    @State private var pingFailed = false
    @State private var pinging = false
    @State private var showLocalNetworkHelp = false

    var body: some View {
        Form {
            Section {
                switch browser.state {
                case .localNetworkDenied:
                    Label("ローカルネットワークが許可されていません", systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                    localNetworkHelp
                case .failed(let message):
                    Label("探せませんでした（\(message)）", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                default:
                    if browser.receivers.isEmpty {
                        HStack {
                            ProgressView()
                            Text("同じ Wi-Fi の Mac を探しています…").foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(browser.receivers) { receiver in
                    Button {
                        if let url = receiver.url {
                            settings.receiverURLString = url.absoluteString
                            settings.receiverName = receiver.name
                            pingResult = nil
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(receiver.name)
                                Text(receiver.url?.absoluteString ?? "（host・port がありません）")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if receiver.url?.absoluteString == settings.receiverURL?.absoluteString {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(receiver.url == nil)
                }
            } header: {
                Text("見つかった Mac")
            } footer: {
                Text("Mac で memoria_receiver.py を起動すると、ここに出ます。出ないときは、受信側に表示される http://IP:ポート を下に入れてください。")
            }

            Section("送り先") {
                TextField("http://192.168.0.10:8765", text: $settings.receiverURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: settings.receiverURLString) { _, _ in pingResult = nil }
                TextField("ペアリングコード（6 桁）", text: $settings.pairingCode)
                    .keyboardType(.numberPad)
                Button {
                    Task { await ping() }
                } label: {
                    HStack {
                        Text("接続を確認")
                        if pinging { Spacer(); ProgressView() }
                    }
                }
                .disabled(!settings.isReceiverConfigured || pinging)
                if let pingResult {
                    Text(pingResult).font(.subheadline).foregroundStyle(pingFailed ? .red : .green)
                    if pingFailed && showLocalNetworkHelp { localNetworkHelp }
                }
            }

            Section {
                Picker("撮る方向", selection: $settings.planPreset) {
                    ForEach(DirectionPlanPreset.allCases) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.displayName)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(preset)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("撮る方向")
            } footer: {
                Text("新しく作るセッションから使われます。今あるセッションは、作ったときの方向のままです。")
            }

            Section {
                Toggle("自動撮影", isOn: $settings.autoCaptureEnabled)
            } header: {
                Text("撮影")
            } footer: {
                Text("自動撮影は、まだ撮っていない方向で、作品が画面に収まり、止まっているときに撮ります（1 枚目の正面は手で撮ります）。")
            }

            Section("この iPhone") {
                LabeledContent("機種", value: DeviceInfoProvider.modelIdentifier)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("アプリ", value: "\(DeviceInfoProvider.appVersion) (\(DeviceInfoProvider.appBuild))")
            }
        }
        .navigationTitle("設定")
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var localNetworkHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("「設定」アプリ > プライバシーとセキュリティ > ローカルネットワーク で「Memoria Capture」をオンにしてください。Mac の受信側が動いていて、同じ Wi-Fi につながっている必要があります。")
                .font(.caption)
            Button("「設定」アプリを開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.caption)
        }
    }

    private func ping() async {
        guard let client = transfer.makeClient() else { return }
        pinging = true
        defer { pinging = false }
        do {
            let info = try await client.ping()
            pingFailed = false
            showLocalNetworkHelp = false
            pingResult = "つながりました：\(info.name ?? "Mac")"
            if let name = info.name, !name.isEmpty { settings.receiverName = name }
        } catch {
            let transferError = TransferClient.classify(error)
            pingFailed = true
            showLocalNetworkHelp = transferError.mayBeLocalNetworkProblem
            pingResult = transferError.userMessage
        }
    }
}
