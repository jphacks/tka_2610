import CaptureCore
import SwiftUI

/// 撮影セッションの一覧（作品名・枚数・マスク・転送の状態）。
struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showingNew = false
    @State private var newTitle = ""
    @State private var pendingDelete: SessionSummary?

    var body: some View {
        List {
            if !settings.isReceiverConfigured {
                Section {
                    Button {
                        model.open(.settings)
                    } label: {
                        Label("送り先の Mac をまだ設定していません。設定を開く", systemImage: "desktopcomputer")
                    }
                }
            }
            if model.sessions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("まだ撮影がありません").font(.headline)
                        Text("「新しく撮る」から作品名を入れて、作品のまわりを撮影します。作品は動かないように置いてください。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            Section {
                ForEach(model.sessions) { summary in
                    Button {
                        model.open(summary.photoCount == 0 ? .capture(sessionId: summary.id, preferredTargetId: nil) : .review(sessionId: summary.id))
                    } label: {
                        SessionRow(summary: summary, store: model.store)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = summary
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .disabled(model.isLocked(summary.id))
                    }
                }
            }
        }
        .navigationTitle("Memoria Capture")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.open(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newTitle = ""
                    showingNew = true
                } label: {
                    Label("新しく撮る", systemImage: "plus")
                }
            }
        }
        .refreshable { model.reloadSessions() }
        .onAppear { model.reloadSessions() }
        .alert("新しく撮る", isPresented: $showingNew) {
            TextField("作品名（例：ねこの貯金箱）", text: $newTitle)
            Button("撮影を始める") {
                if let session = model.createSession(title: newTitle) {
                    model.open(.capture(sessionId: session.sessionId, preferredTargetId: nil))
                }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("作品名は空でもかまいません。")
        }
        .confirmationDialog("このセッションを削除しますか？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let id = pendingDelete?.id { model.deleteSession(id) }
                pendingDelete = nil
            }
        } message: {
            Text("写真とマスクがこの iPhone から消えます。Mac へ送ったものは残ります。")
        }
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    let store: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let photo = summary.firstPhoto {
                    PhotoThumbnail(url: store.photoURL(summary.id, photoId: photo.photoId), rotation: photo.image.displayRotationDegClockwise, maxPixel: 160)
                } else {
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                        Image(systemName: "camera").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title.isEmpty ? "（名前なし）" : summary.title).font(.headline)
                HStack(spacing: 10) {
                    Label("\(summary.photoCount) 枚", systemImage: "photo")
                    Label("方向 \(summary.confirmedDirections)/\(summary.totalDirections)", systemImage: "circle.dashed")
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(maskText).font(.caption).foregroundStyle(.secondary)
                    TransferBadge(status: summary.transferStatus)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var maskText: String {
        if summary.photoCount == 0 { return "切り抜き —" }
        var text = "切り抜き \(summary.maskReady)/\(summary.photoCount)"
        if summary.maskProcessing > 0 { text += "（作成中 \(summary.maskProcessing)）" }
        return text
    }
}

struct TransferBadge: View {
    let status: TransferDisplayStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .sent: return .green
        case .modifiedSinceSent: return .orange
        case .failed: return .red
        case .inProgress: return .blue
        case .notSent: return .secondary
        }
    }
}
