import CaptureCore
import SwiftUI

/// 設定（memoria の家の引き継ぎ・再読み込み、送り先の Mac・ペアリングコード・接続の確認・撮る方向・自動撮影）。
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var transfer: TransferCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var web: MemoriaWebController
    /// 「家を引き継ぐ」に貼った `/house` のリンクか家の番号。
    @State private var houseInput = ""
    @StateObject private var browser = ReceiverBrowser()
    @State private var pingResult: String?
    @State private var pingFailed = false
    @State private var pinging = false
    @State private var showLocalNetworkHelp = false

    var body: some View {
        Form {
            memoriaSection

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

            Section {
                TextField("http://192.168.0.10:8765", text: $settings.receiverURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: settings.receiverURLString) { _, _ in pingResult = nil }
                if settings.receiverIsPublicAddress {
                    Label(TransferError.notLocalNetworkMessage, systemImage: "exclamationmark.shield")
                        .font(.subheadline).foregroundStyle(.red)
                }
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
                .disabled(!settings.isReceiverConfigured || settings.receiverIsPublicAddress || pinging)
                if let pingResult {
                    Text(pingResult).font(.subheadline).foregroundStyle(pingFailed ? .red : .green)
                    if pingFailed && showLocalNetworkHelp { localNetworkHelp }
                }
            } header: {
                Text("送り先")
            } footer: {
                Text("送れるのは同じネットワーク（自宅の Wi-Fi・USB ケーブル・インターネット共有）の Mac だけです。公開 IP アドレスには送りません。")
            }

            Section {
                Picker("案内のしかた", selection: $settings.guidance) {
                    ForEach(CaptureGuidance.allCases.reversed()) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.displayName)
                            Text(option.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("立体の撮り方")
            } footer: {
                Text("「自由に撮る」は案内も自動撮影もなく、シャッターを押すだけです。向きで案内する方法は新しく、まだ試しているところで、AI 用 5 方向のときだけ使えます（ほかの方向はいつも底の中心と円柱）。今あるセッションは、作ったときの方法のままです。")
            }

            Section {
                Picker("撮る方向", selection: $settings.planPreset) {
                    ForEach(DirectionPlanPreset.objectPresets) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.displayName)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(preset)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(settings.guidance == .free)
            } header: {
                Text("撮る方向（案内つきの撮り方のとき）")
            } footer: {
                Text(settings.guidance == .free
                     ? "「自由に撮る」では撮る方向を使いません（何枚でも、どの向きでも撮れます）。案内つきの撮り方を選んだときに使います。"
                     : "立体の作品の新しいセッションから使われます。今あるセッションは、作ったときの方向のままです。平面の作品は、いつも真上から 1 枚です。")
            }

            Section {
                Toggle("自動撮影", isOn: $settings.autoCaptureEnabled)
            } header: {
                Text("撮影")
            } footer: {
                Text("自動撮影は、まだ撮っていない方向で、作品が画面に収まり、止まっているときに撮ります（1 枚目の正面は手で撮ります）。「自由に撮る」では自動撮影はしません。")
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

    /// memoria（アプリの中の Web）：接続先・家を引き継ぐ・再読み込み。
    private var memoriaSection: some View {
        Section {
            LabeledContent("接続先", value: web.origin?.serialized ?? "未設定")
            TextField("/house のリンクか家の番号", text: $houseInput)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !houseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && HouseLink.houseId(fromUserInput: houseInput) == nil {
                Text("家の番号（32 桁）が読み取れません。memoria の「この家のリンク」（/house）の画面のリンクを、そのまま貼ってください。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("この家を開く") {
                guard let id = HouseLink.houseId(fromUserInput: houseInput) else { return }
                web.switchHouse(id: id)
                houseInput = ""
                model.showsDeveloperScreens = false
            }
            .disabled(HouseLink.houseId(fromUserInput: houseInput) == nil || web.origin == nil)
            Button("memoria を読み込み直す") {
                web.reload()
                model.showsDeveloperScreens = false
            }
            .disabled(web.origin == nil)
        } header: {
            Text("memoria")
        } footer: {
            Text("アプリの中の memoria は、Safari とは別の家になります。Safari で使っている家を引き継ぐときは、Safari の memoria で「この家のリンク」（/house）を開いてリンクをコピーし、ここに貼って「この家を開く」を押してください。")
        }
    }

    private var localNetworkHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("「設定」アプリ > プライバシーとセキュリティ > ローカルネットワーク で「Memoria」をオンにしてください。Mac の受信側が動いていて、同じネットワーク（自宅の Wi-Fi・USB ケーブル・インターネット共有）につながっている必要があります。")
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
