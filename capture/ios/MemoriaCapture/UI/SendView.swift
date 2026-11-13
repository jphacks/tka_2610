import CaptureCore
import SwiftUI

/// Mac（受信側）へ送る。設定した受信側にだけ送る。
struct SendView: View {
    let sessionId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var transfer: TransferCoordinator
    @State private var snapshotInfo: (files: Int, bytes: Int64)?
    @State private var status: TransferDisplayStatus = .notSent
    @State private var masksPending = false
    @State private var prepareError: String?
    @State private var readiness: Readiness?

    var body: some View {
        Form {
            Section("送り先") {
                if settings.isReceiverConfigured {
                    LabeledContent("Mac", value: settings.receiverDisplayName)
                    LabeledContent("URL", value: settings.receiverURLString)
                    if settings.receiverIsPublicAddress {
                        Label(TransferError.notLocalNetworkMessage, systemImage: "exclamationmark.shield")
                            .font(.subheadline).foregroundStyle(.red)
                    }
                } else {
                    Text("送り先の Mac とペアリングコードを設定してください。Mac で受信側（memoria_receiver.py）を起動すると、名前と 6 桁のコードが表示されます。")
                        .font(.subheadline)
                    Button("設定を開く") { model.open(.settings) }
                }
            }

            if let readiness {
                Section("そろっているか") {
                    ReadinessView(readiness: readiness)
                }
            }

            Section("送るもの") {
                if let info = snapshotInfo {
                    LabeledContent("ファイル", value: "\(info.files) 個")
                    LabeledContent("大きさ", value: ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file))
                } else if let prepareError {
                    Text(prepareError).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                LabeledContent("状態") { TransferBadge(status: status) }
                if case let .failed(message) = status {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if masksPending {
                    Label("切り抜きを作っています。終わってから送ってください。", systemImage: "hourglass")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }

            if transfer.isSending(sessionId) {
                Section("送信中") {
                    if let progress = transfer.progress {
                        ProgressView(value: progress.fraction) {
                            Text(phaseText(progress.phase))
                        } currentValueLabel: {
                            Text("\(progress.sentFiles) / \(progress.totalFiles) 個・\(ByteCountFormatter.string(fromByteCount: progress.sentBytes, countStyle: .file))")
                        }
                    } else {
                        ProgressView("接続しています")
                    }
                    Button("中止", role: .destructive) { transfer.cancel() }
                }
            }

            if let outcome = transfer.lastOutcome[sessionId], !transfer.isSending(sessionId) {
                Section("結果") {
                    outcomeView(outcome)
                }
            }

            Section {
                Button {
                    transfer.send(sessionId: sessionId)
                } label: {
                    Label(sendButtonTitle, systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            } footer: {
                Text("同じネットワーク（自宅の Wi-Fi・USB ケーブル・インターネット共有）の Mac に、写真・切り抜き（平面の作品は遠近を直した画像）・session.json を送ります。途中で止まっても、もう一度送ると続きから送ります。公開 IP アドレス（インターネットの向こう）には送りません。")
            }
        }
        .navigationTitle("Mac へ送る")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: model.revision) { _, _ in refresh() }
        .onChange(of: transfer.sendingSessionId) { _, _ in refresh() }
    }

    private var canSend: Bool {
        settings.isReceiverConfigured && !settings.receiverIsPublicAddress && transfer.sendingSessionId == nil && !masksPending && snapshotInfo != nil
    }

    private var sendButtonTitle: String {
        switch status {
        case .failed, .inProgress: return "再送"
        case .sent: return "もう一度送る"
        case .modifiedSinceSent: return "変更を送る"
        case .notSent: return "送る"
        }
    }

    private func refresh() {
        let store = model.store, masks = model.masks, id = sessionId
        Task.detached(priority: .userInitiated) {
            let pending = masks.hasPending(sessionId: id)
            let readiness = (try? store.loadSession(id)).map { Readiness.make(session: $0, pendingPhotoIds: masks.pendingPhotoIds()) }
            let result = Result { try store.makeTransferSnapshot(id) }
            let status = store.transferDisplayStatus(id)
            await MainActor.run {
                masksPending = pending
                self.readiness = readiness
                self.status = status
                switch result {
                case .success(let snapshot):
                    snapshotInfo = (snapshot.manifest.entries.count, snapshot.manifest.totalBytes)
                    prepareError = nil
                case .failure(let error):
                    snapshotInfo = nil
                    prepareError = "送るファイルを準備できません（\(error.localizedDescription)）"
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeView(_ outcome: TransferOutcome) -> some View {
        switch outcome {
        case let .complete(_, _, alreadyComplete, path):
            Label(alreadyComplete ? "この内容はすでに Mac にあります" : "送信しました", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let path { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        case let .failed(error):
            Label(error.userMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            if error.mayBeLocalNetworkProblem {
                Text("""
                つながらないときは次を確かめてください。
                ・「設定」アプリ > プライバシーとセキュリティ > ローカルネットワーク で「Memoria」をオンにする
                ・Mac で受信側（memoria_receiver.py）が動いている
                ・iPhone と Mac が同じネットワーク（自宅の Wi-Fi・USB ケーブル・インターネット共有）につながっている
                """)
                .font(.caption)
                Button("「設定」アプリを開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
    }

    private func phaseText(_ phase: TransferProgress.Phase) -> String {
        switch phase {
        case .connecting: return "接続しています"
        case .uploading: return "送っています"
        case .committing: return "Mac で確かめています"
        case .done: return "完了"
        }
    }
}
