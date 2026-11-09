import CaptureCore
import SwiftUI

/// 撮った写真の一覧（撮影順・方向・確定か参考か・品質・マスク）。
struct ReviewView: View {
    let sessionId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transfer: TransferCoordinator
    @State private var session: CaptureSession?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var confirmRegenerate = false
    @State private var confirmDeleteSuperseded = false
    @State private var readiness: Readiness?
    /// 一覧に出す写真のまとまり（段ごと）。読み直したときにだけ作る。
    @State private var groups: [PhotoGroup] = []

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        ScrollView {
            if let session {
                VStack(alignment: .leading, spacing: 12) {
                    summary(session)
                    if model.isLocked(sessionId) {
                        Label("送信中のため、撮影・編集はできません", systemImage: "lock.fill")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.photos) { photo in
                                    Button {
                                        model.open(.photo(sessionId: sessionId, photoId: photo.photoId))
                                    } label: {
                                        PhotoCell(photo: photo, session: session, issues: readiness?.issues(for: photo.photoId) ?? [],
                                                  url: model.store.photoURL(sessionId, photoId: photo.photoId))
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                if let title = group.title {
                                    Text(title)
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 6)
                                }
                            }
                        }
                    }
                }
                .padding()
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle(session.map { $0.title.isEmpty ? "確認" : $0.title } ?? "確認")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("作品名を変える") {
                        titleDraft = session?.title ?? ""
                        editingTitle = true
                    }
                    .disabled(model.isLocked(sessionId))
                    Button("切り抜きを作り直す") { confirmRegenerate = true }
                        .disabled(model.isLocked(sessionId) || regenerateTargets.isEmpty)
                    Button("置き換え済みを削除", role: .destructive) { confirmDeleteSuperseded = true }
                        .disabled(model.isLocked(sessionId) || (readiness?.supersededPhotoIds.isEmpty ?? true))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    model.replaceTop(with: .capture(sessionId: sessionId, preferredTargetId: nil))
                } label: {
                    Label("追加撮影", systemImage: "camera")
                }
                .disabled(model.isLocked(sessionId))
                Spacer()
                Button {
                    model.open(.send(sessionId: sessionId))
                } label: {
                    Label("Mac へ送る", systemImage: "paperplane")
                }
                .disabled((session?.photos.isEmpty ?? true))
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .confirmationDialog("切り抜きを作り直しますか？", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("\(regenerateTargets.count) 枚を作り直す") {
                model.masks.regenerate(sessionId: sessionId, photoIds: regenerateTargets, includeConfirmed: false)
            }
        } message: {
            Text("確認済みの切り抜きはそのまま残します。選び直した切り抜きも、自動で作った切り抜きに置き換わります。元の写真は変わりません。")
        }
        .confirmationDialog("置き換え済みの写真を削除しますか？", isPresented: $confirmDeleteSuperseded, titleVisibility: .visible) {
            Button("\(readiness?.supersededPhotoIds.count ?? 0) 枚を削除", role: .destructive) { deleteSuperseded() }
        } message: {
            Text("同じ方向をあとで撮り直した、前の写真です。撮り直した写真は残ります。")
        }
        .alert("作品名", isPresented: $editingTitle) {
            TextField("作品名", text: $titleDraft)
            Button("保存") { model.renameSession(sessionId, title: titleDraft) }
            Button("やめる", role: .cancel) {}
        }
    }

    private func reload() {
        session = model.loadSession(sessionId)
        readiness = session.map { Readiness.make(session: $0, pendingPhotoIds: model.masks.pendingPhotoIds()) }
        groups = session.map { PhotoGroup.make(session: $0, progress: readiness?.progress) } ?? []
    }

    private func deleteSuperseded() {
        for id in readiness?.supersededPhotoIds ?? [] {
            do {
                try model.store.deletePhoto(sessionId: sessionId, photoId: id)
            } catch {
                model.alertMessage = error.localizedDescription
                break
            }
        }
        model.sessionChanged()
    }

    /// 切り抜きを作り直す写真（確認済み・作成中を除く）。
    private var regenerateTargets: [String] {
        let pending = model.masks.pendingPhotoIds()
        return (session?.photos ?? [])
            .filter { $0.mask.status != .confirmed && $0.mask.status != .processing && !pending.contains($0.photoId) }
            .sorted { $0.sequence < $1.sequence }
            .map(\.photoId)
    }

    private func summary(_ session: CaptureSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(session.photos.count) 枚・切り抜き \(session.photos.filter { $0.mask.status.hasFile }.count) 枚")
                .font(.headline)
            if let readiness {
                ReadinessView(readiness: readiness)
            }
            Text("✓ は方向が確定した写真、「参考」は方向が参考値の写真です。「前の基準」は基準を設定し直す前に撮った写真です。「置き換え済み」は同じ方向をあとで撮り直した写真です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 送る前の確認（方向がそろっているか・気になる写真）。送るのは止めない。
struct ReadinessView: View {
    let readiness: Readiness

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(readiness.referenceFrameId == nil ? "基準を設定して撮った写真がありません" : "最後の基準（\(readiness.referenceFrameId!)）：\(readiness.directionSummary)")
            } icon: {
                Image(systemName: readiness.isComplete ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(readiness.isComplete ? .green : .orange)
            }
            .font(.subheadline.bold())
            if let attention = readiness.attentionSummary {
                Label(attention, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            if readiness.pendingMaskCount > 0 {
                Label("切り抜きを作っています（\(readiness.pendingMaskCount) 枚）", systemImage: "hourglass")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !readiness.isComplete || readiness.attentionCount > 0 {
                Text("このままでも送れますが、3D にするには、すべての方向に切り抜きのよい写真があるのが理想です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 確認画面の写真のまとまり。撮る方向の段が 2 つ以上あるときは段ごと（段の中は方位の順）、
/// 方向の無い写真（追加撮影・基準なし）は最後にまとめる。段が 1 つなら撮影順に 1 つ（見出しなし）。
struct PhotoGroup: Identifiable {
    let id: String
    let title: String?
    let photos: [Photo]

    static func make(session: CaptureSession, progress: CoverageProgress?) -> [PhotoGroup] {
        let photos = session.photos.sorted { $0.sequence < $1.sequence }
        let plan = session.directionPlan
        let bands = plan.bands
        guard bands.count > 1 else { return [PhotoGroup(id: "all", title: nil, photos: photos)] }
        var byBand: [String: [(azimuth: Double, photo: Photo)]] = [:]
        var others: [Photo] = []
        for photo in photos {
            if let target = plan.target(id: photo.direction.targetId), let band = bands.first(where: { $0.contains(target) }) {
                byBand[band.id, default: []].append((target.azimuthDeg, photo))
            } else {
                others.append(photo)
            }
        }
        let bandProgress = progress?.bands ?? []
        var groups = bands.compactMap { band -> PhotoGroup? in
            guard let items = byBand[band.id], !items.isEmpty else { return nil }
            // 方位の順。同じ方位（撮り直し）は撮影順。
            let sorted = items.sorted { ($0.azimuth, $0.photo.sequence) < ($1.azimuth, $1.photo.sequence) }.map(\.photo)
            let done = bandProgress.first { $0.id == band.id }.map { "・そろった \($0.doneCount)/\($0.totalCount)" } ?? ""
            return PhotoGroup(id: "band-\(band.id)", title: "高さ \(band.id)°（\(sorted.count) 枚\(done)）", photos: sorted)
        }
        if !others.isEmpty {
            groups.append(PhotoGroup(id: "others", title: "そのほか（追加撮影・方向なし \(others.count) 枚）", photos: others))
        }
        return groups
    }
}

struct PhotoCell: View {
    let photo: Photo
    let session: CaptureSession
    var issues: [PhotoIssue] = []
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PhotoThumbnail(url: url, rotation: photo.image.displayRotationDegClockwise, maxPixel: 300)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Text("#\(photo.sequence)")
                        .font(.caption2.bold()).padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white).padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if hasQualityWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow).padding(5)
                            .background(.black.opacity(0.5), in: Circle()).padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    MaskBadge(status: photo.mask.status, check: photo.mask.check?.status).padding(4)
                }
                .overlay(alignment: .bottomLeading) {
                    if issues.contains(.superseded) {
                        Text("置き換え済み")
                            .font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 3)
                            .background(.gray.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white).padding(4)
                    }
                }
                .opacity(issues.contains(.superseded) ? 0.6 : 1)
            HStack(spacing: 4) {
                if photo.direction.confirmed && isLatestReference {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if photo.direction.confirmed {
                    Text("前の基準").foregroundStyle(.secondary)
                } else {
                    Text("参考").foregroundStyle(.orange)
                }
                Text(directionLabel).lineLimit(1)
            }
            .font(.caption2)
        }
    }

    /// 最後に設定した基準で撮った写真か（撮影画面を閉じると基準は無効になるので、最後の基準と比べる）。
    private var isLatestReference: Bool {
        photo.referenceFrameId != nil && photo.referenceFrameId == session.referenceFrames.last?.id
    }

    private var directionLabel: String {
        if let target = session.directionPlan.target(id: photo.direction.targetId) {
            return "\(DirectionTarget.formatDegrees(target.azimuthDeg))°・高さ \(DirectionTarget.formatDegrees(target.elevationDeg))°"
        }
        if let az = photo.direction.azimuthDeg {
            return "\(Int(az.rounded()))°（追加）"
        }
        return "方向なし"
    }

    private var hasQualityWarning: Bool {
        if let saved = photo.quality.saved, saved.brightness != .ok || saved.blur != .ok { return true }
        return photo.quality.live.warningsAcknowledged
    }
}

struct MaskBadge: View {
    let status: MaskStatus
    /// 作品の輪郭と比べた結果（candidate のときに使う）。
    var check: MaskCheckStatus?

    /// 自動で作った切り抜きが、作品らしくない・確かめられない。
    private var doubtful: Bool { status == .candidate && (check == .suspicious || check == .unknown) }

    var body: some View {
        Label(text, systemImage: icon)
            .labelStyle(.iconOnly)
            .font(.caption2.bold())
            .padding(5)
            .background(color, in: Circle())
            .foregroundStyle(.white)
            .accessibilityLabel(text)
    }

    var text: String { doubtful ? (check == .suspicious ? "切り抜きが怪しい" : "切り抜き（確かめられない）") : Self.label(status) }

    static func label(_ status: MaskStatus) -> String {
        switch status {
        case .notGenerated: return "切り抜き待ち"
        case .processing: return "切り抜き作成中"
        case .candidate: return "切り抜き（未確認）"
        case .confirmed: return "切り抜き（確認済み）"
        case .failed: return "切り抜きなし"
        case .noObject: return "作品が見つからない"
        }
    }

    private var icon: String {
        if doubtful { return "exclamationmark" }
        switch status {
        case .notGenerated: return "clock"
        case .processing: return "hourglass"
        case .candidate: return "scissors"
        case .confirmed: return "checkmark.seal.fill"
        case .failed: return "xmark"
        case .noObject: return "questionmark"
        }
    }

    private var color: Color {
        if doubtful { return .orange }
        switch status {
        case .notGenerated, .processing: return .gray
        case .candidate: return .blue
        case .confirmed: return .green
        case .failed: return .red
        case .noObject: return .orange
        }
    }
}
