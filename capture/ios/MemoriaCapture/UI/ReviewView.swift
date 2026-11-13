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
                                                  url: thumbnailURL(photo, session: session),
                                                  rotation: session.isFlat && photo.flat?.rectified != nil ? 0 : nil)
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
                    if session?.isFlat != true && session?.usesFreeCapture != true {
                        Button("切り抜きを作り直す") { confirmRegenerate = true }
                            .disabled(model.isLocked(sessionId) || regenerateTargets.isEmpty)
                    }
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
                    Label(session?.isFlat == true ? "撮り直す" : "追加撮影", systemImage: "camera")
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

    /// 一覧の縮小画像：平面の作品は遠近を直した画像（あれば）、ほかは元の写真。
    private func thumbnailURL(_ photo: Photo, session: CaptureSession) -> URL {
        if session.isFlat, photo.flat?.rectified != nil { return model.store.rectifiedURL(sessionId, photoId: photo.photoId) }
        return model.store.photoURL(sessionId, photoId: photo.photoId)
    }

    /// 撮る人が選んだ・入力した大きさ（新しいセッションを作るときに決めたもの）。
    private func declaredSizeText(_ session: CaptureSession) -> String {
        if session.isFlat {
            guard let sheet = session.declaredSheet else { return "紙の大きさ：選んでいません（机の平面で測れたときはその大きさを使います）" }
            return "紙：\(sheet.labelWithSize)（選んだ大きさ）"
        }
        guard let height = session.declaredHeightM else { return "高さ：入力していません" }
        return String(format: "高さ：%.1f cm（入力した値。写真から求めた大きさより優先します）", height * 100)
    }

    private func summary(_ session: CaptureSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.isFlat {
                Text("平面の作品・\(session.photos.count) 枚").font(.headline)
            } else if session.usesFreeCapture {
                Text("立体の作品（自由に撮影）・\(session.photos.count) 枚").font(.headline)
            } else {
                Text("\(session.photos.count) 枚・切り抜き \(session.photos.filter { $0.mask.status.hasFile }.count) 枚")
                    .font(.headline)
            }
            if let readiness {
                ReadinessView(readiness: readiness)
            }
            Label(declaredSizeText(session), systemImage: "ruler")
                .font(.caption).foregroundStyle(.secondary)
            if session.usesHeadingGuidance {
                HeadingDerivationSummary(session: session)
            }
            Text(session.usesFreeCapture
                 ? "自由に撮った写真です（向きの案内はしていません）。どの写真がどの向きかは、Mac で AI が写真を見て決めます。正面・横・後ろ・真上があると作りやすくなります。"
                 : session.isFlat
                 ? "✓ は真上から撮った写真です。紙が見つかった写真は、遠近を直した画像を出しています。「置き換え済み」は撮り直す前の写真です（送ると Mac では一番新しい真上の写真を使います）。"
                 : session.usesHeadingGuidance
                 ? "✓ は方向が確定した写真、「参考」は方向が参考値の写真です。「前の基準」は正面からやり直す前（撮影画面を開き直す前）に撮った写真です。「向きの外」は狙った向きの外か、その場で回して撮った写真です。"
                 : "✓ は方向が確定した写真、「参考」は方向が参考値の写真です。「前の基準」は基準を設定し直す前に撮った写真です。「置き換え済み」は同じ方向をあとで撮り直した写真です。")
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
                if readiness.isFlat || readiness.isFree {
                    Text(readiness.directionSummary)
                } else {
                    Text(readiness.referenceFrameId == nil ? "基準を設定して撮った写真がありません" : "最後の基準（\(readiness.referenceFrameId!)）：\(readiness.directionSummary)")
                }
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
                Text(readiness.isFree
                     ? "1 枚以上あれば送れます。作品の全体が写っている写真を撮ってください。"
                     : readiness.isFlat
                     ? "このままでも送れますが、紙の全体が真上から写っていて、紙が見つかった写真が理想です。"
                     : "このままでも送れますが、3D にするには、すべての方向に切り抜きのよい写真があるのが理想です。")
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
        if plan.usesStepNames {
            // 正面・右・後ろ・左・真上の順（撮り直しは撮影順）。一覧の外の写真は最後。
            let order = Dictionary(uniqueKeysWithValues: plan.targets.enumerated().map { ($1.id, $0) })
            let sorted = photos.sorted {
                (order[$0.direction.targetId ?? ""] ?? Int.max, $0.sequence) < (order[$1.direction.targetId ?? ""] ?? Int.max, $1.sequence)
            }
            return [PhotoGroup(id: "all", title: nil, photos: sorted)]
        }
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
    /// 縮小画像を回す角度（nil なら写真の `displayRotationDegClockwise`。遠近を直した画像はすでにまっすぐなので 0）。
    var rotation: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PhotoThumbnail(url: url, rotation: rotation ?? photo.image.displayRotationDegClockwise, maxPixel: 300)
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
                    if session.usesFreeCapture {
                        EmptyView()  // マスクを作らない
                    } else if session.isFlat {
                        FlatBadge(flat: photo.flat).padding(4)
                    } else {
                        MaskBadge(status: photo.mask.status, check: photo.mask.check?.status).padding(4)
                    }
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
                if session.usesFreeCapture {
                    // 方向の案内は無い。見下ろす角度だけ。
                    Text(photo.direction.elevationDeg.map { "見下ろし \(Int($0.rounded()))°" } ?? "傾きなし").foregroundStyle(.secondary)
                } else if session.isFlat {
                    if photo.direction.targetId != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("真上ではない").foregroundStyle(.orange)
                    }
                } else if photo.direction.confirmed && isLatestReference {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if photo.direction.confirmed {
                    Text("前の基準").foregroundStyle(.secondary)
                } else {
                    Text("参考").foregroundStyle(.orange)
                }
                if !session.usesFreeCapture {
                    Text(directionLabel).lineLimit(1)
                }
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
            return session.directionPlan.displayName(of: target)
        }
        if let az = photo.heading?.relativeHeadingDeg ?? photo.direction.azimuthDeg {
            return photo.heading != nil ? "向きの外 \(Int(az.rounded()))°" : "\(Int(az.rounded()))°（追加）"
        }
        return "方向なし"
    }

    private var hasQualityWarning: Bool {
        if let saved = photo.quality.saved, saved.brightness != .ok || saved.blur != .ok { return true }
        return photo.quality.live.warningsAcknowledged
    }
}

/// 平面の作品の写真の印：遠近を直した（緑）・紙は見つかったが直していない（青）・紙が見つからない（橙）。端にかかっていれば橙。
struct FlatBadge: View {
    let flat: FlatPhotoInfo?

    var body: some View {
        Label(text, systemImage: icon)
            .labelStyle(.iconOnly)
            .font(.caption2.bold())
            .padding(5)
            .background(color, in: Circle())
            .foregroundStyle(.white)
            .accessibilityLabel(text)
    }

    private var text: String {
        guard flat?.corners != nil else { return "紙が見つからない" }
        if flat?.sheetAtFrameEdge == true { return "紙が端で切れているかも" }
        return flat?.rectified != nil ? "遠近を直した画像" : "紙は見つかった（直した画像なし）"
    }

    private var icon: String {
        guard flat?.corners != nil else { return "questionmark" }
        if flat?.sheetAtFrameEdge == true { return "exclamationmark" }
        return flat?.rectified != nil ? "crop" : "rectangle"
    }

    private var color: Color {
        guard flat?.corners != nil, flat?.sheetAtFrameEdge != true else { return .orange }
        return flat?.rectified != nil ? .green : .blue
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

/// 向きで案内したセッションの、撮ったあとに求めた中心と大きさ（最後の基準）。
struct HeadingDerivationSummary: View {
    let session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(centerText, systemImage: "scope")
            Label(sizeText, systemImage: "ruler")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var derivation: HeadingDerivation? {
        session.referenceFrames.last { $0.heading?.frontHeadingDeg != nil }?.heading?.derivation
    }

    private var centerText: String {
        guard let d = derivation else { return "作品の位置：横の写真を撮ると求めます" }
        guard d.centerWorld != nil else { return "作品の位置：分かりません（写真が足りない・線がほぼ平行）" }
        let miss = d.residualRmsM.map { String(format: "線の外れ %.1f cm", $0 * 100) } ?? ""
        let base = d.origin == .base ? "・机の面あり" : "・机の高さは分からない"
        return "作品の位置：写真 \(d.photoIds.count) 枚から求めました（\(miss)\(d.status == .ok ? "" : "・当てにしにくい")\(base)）"
    }

    private var sizeText: String {
        guard let d = derivation, d.centerWorld != nil else { return "大きさ：位置が分かると求めます" }
        guard let size = d.size else { return "大きさ：切り抜きができたら求めます" }
        guard size.isKnown, let w = size.widthM, let dep = size.depthM, let h = size.heightM else { return "大きさ：分かりません（切り抜きが足りない）" }
        let confidence = size.confidence == "low" ? "・信頼度 低" : ""
        return String(format: "大きさ（おおよそ）：幅 %.1f × 奥行き %.1f × 高さ %.1f cm", w * 100, dep * 100, h * 100) + confidence
    }
}
