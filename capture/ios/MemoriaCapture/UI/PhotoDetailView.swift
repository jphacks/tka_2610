import CaptureCore
import SwiftUI

/// 写真 1 枚の確認（元写真・切り抜き・重ね表示、対象の選び直し、撮り直し・削除）。
/// 表示のためだけに回して見せる。保存した写真とマスクはセンサーの向きのまま。
struct PhotoDetailView: View {
    let sessionId: String
    let photoId: String

    enum Mode: String, CaseIterable, Identifiable {
        case original = "元写真", cutout = "切り抜き", overlay = "重ね表示"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @State private var session: CaptureSession?
    @State private var photoImage: UIImage?
    @State private var maskImage: UIImage?
    @State private var mode: Mode = .overlay
    @State private var editing = false
    @State private var analysis: InstanceAnalysis?
    @State private var selected: [Int] = []
    @State private var working = false
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var confirmRetake = false
    @State private var confirmRegenerate = false

    private var photo: Photo? { session?.photo(id: photoId) }
    private var locked: Bool { model.isLocked(sessionId) }
    /// マスクを作っている・作る順番を待っている。
    private var maskBusy: Bool { photo?.mask.status == .processing || model.masks.pendingPhotoIds().contains(photoId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("表示", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                imageArea
                    .frame(maxWidth: .infinity)
                    .frame(height: 440)
                    .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))

                if let message {
                    Text(message).font(.subheadline).foregroundStyle(.orange)
                }
                if editing {
                    editingPanel
                } else if let photo {
                    info(photo)
                    actions(photo)
                }
            }
            .padding()
        }
        .navigationTitle(photo.map { "#\($0.sequence)" } ?? "写真")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .confirmationDialog("この写真を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { deletePhoto(retake: false) }
        }
        .confirmationDialog("この写真を消して撮り直しますか？", isPresented: $confirmRetake, titleVisibility: .visible) {
            Button("撮り直す", role: .destructive) { deletePhoto(retake: true) }
        } message: {
            Text("撮影画面で基準を設定し直してから、同じ方向を撮ります。")
        }
        .confirmationDialog("切り抜きを作り直しますか？", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("作り直す") { regenerate() }
        } message: {
            Text("選び直した切り抜き・確認済みの切り抜きも、自動で作った切り抜きに置き換わります。元の写真は変わりません。")
        }
    }

    // MARK: 画像

    @ViewBuilder
    private var imageArea: some View {
        if let photoImage {
            GeometryReader { geo in
                let rect = fittedRect(imageSize: photoImage.size, in: geo.size)
                ZStack {
                    switch mode {
                    case .original:
                        Image(uiImage: photoImage).resizable().scaledToFit()
                    case .cutout:
                        if let maskImage {
                            Image(uiImage: photoImage).resizable().scaledToFit()
                                .mask(Image(uiImage: maskImage).resizable().scaledToFit().luminanceToAlpha())
                        } else {
                            Text("切り抜きがありません").foregroundStyle(.white)
                        }
                    case .overlay:
                        Image(uiImage: photoImage).resizable().scaledToFit()
                        if let maskImage {
                            Color.green.opacity(0.45)
                                .frame(width: rect.width, height: rect.height)
                                .mask(Image(uiImage: maskImage).resizable().scaledToFit().luminanceToAlpha())
                        }
                    }
                    if working { ProgressView().tint(.white) }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard editing else { return }
                    tapped(at: location, imageRect: rect)
                }
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    // MARK: 情報

    private func info(_ photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if photo.direction.confirmed {
                    Label("方向は確定", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("方向は参考値（\(unconfirmedText(photo.direction.unconfirmedReason))）", systemImage: "info.circle").foregroundStyle(.orange)
                }
            }
            .font(.subheadline.bold())
            Text(directionText(photo)).font(.subheadline)
            Text("切り抜き：\(MaskBadge.label(photo.mask.status))\(photo.mask.selection == .user ? "（選び直し）" : "")\(photo.mask.error.map { "・\($0)" } ?? "")")
                .font(.subheadline)
            if photo.mask.status.hasFile, let check = photo.mask.check {
                switch check.status {
                case .ok:
                    Text("切り抜きの確認：作品の位置と合っています").font(.caption).foregroundStyle(.secondary)
                case .suspicious:
                    Text("切り抜きの確認：作品ではない物を選んでいるかもしれません（\(check.reasons.map(\.label).joined(separator: "・"))）")
                        .font(.caption).foregroundStyle(.orange)
                case .unknown:
                    Text("切り抜きの確認：作品の位置が分からないため確かめていません").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let source = photo.mask.inputRegionSource {
                Text(source == .projectedCylinder ? "作品のまわりを切り抜いて作りました" : "写真の全体から作りました（作品の位置が分からないため）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let saved = photo.quality.saved {
                Text("明るさ \(String(format: "%.2f", saved.meanLuma))（\(statusText(saved.brightness))）・シャープさ \(String(format: "%.4f", saved.sharpness))（\(statusText(saved.blur))）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if photo.quality.live.warningsAcknowledged {
                Text("警告を確認して撮った写真です").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(photo.image.width) × \(photo.image.height)・\(photo.trigger == .auto ? "自動" : "手動")撮影・基準 \(photo.referenceFrameId ?? "なし")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func actions(_ photo: Photo) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button("対象を選び直す") { startEditing(photo) }
                    .disabled(locked || working || maskBusy || photo.mask.status == .notGenerated)
                Button("この切り抜きでOK") { setMaskStatus(.confirmed) }
                    .disabled(locked || photo.mask.status != .candidate)
            }
            .buttonStyle(.bordered)
            Button("切り抜きを作り直す") {
                if photo.mask.status == .confirmed || photo.mask.selection == .user {
                    confirmRegenerate = true
                } else {
                    regenerate()
                }
            }
            .buttonStyle(.bordered)
            .disabled(locked || working || maskBusy)
            HStack {
                Button("マスクなしにする") { rejectMask() }
                    .disabled(locked || !photo.mask.status.hasFile)
                Button("撮り直す") { confirmRetake = true }
                    .disabled(locked)
                Button("削除", role: .destructive) { confirmDelete = true }
                    .disabled(locked)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    private var editingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("写真の中の物をタップすると、切り抜きに入れる・外すを切り替えます。")
                .font(.subheadline)
            if let analysis {
                Text("見つかった物：\(analysis.instanceCount) 個・選んでいる物：\(selected.isEmpty ? "なし" : selected.map(String.init).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("選び直しを終える") {
                editing = false
                analysis = nil
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: 操作

    private func reload() {
        session = model.loadSession(sessionId)
        guard let photo else { return }
        let photoURL = model.store.photoURL(sessionId, photoId: photoId)
        let maskURL = model.store.maskURL(sessionId, photoId: photoId)
        let rotation = photo.image.displayRotationDegClockwise
        let hasMask = photo.mask.status.hasFile
        Task.detached(priority: .userInitiated) {
            let image = ImageLoading.thumbnail(url: photoURL, maxPixel: 2048).map { ImageLoading.uiImage($0, rotation: rotation) }
            let mask = hasMask ? ImageLoading.thumbnail(url: maskURL, maxPixel: 2048).map { ImageLoading.uiImage($0, rotation: rotation) } : nil
            await MainActor.run {
                photoImage = image
                maskImage = mask
            }
        }
    }

    private func startEditing(_ photo: Photo) {
        working = true
        message = nil
        model.masks.analyzeForEditing(sessionId: sessionId, photoId: photoId) { result in
            working = false
            switch result {
            case .success(let result):
                guard result.labelMap != nil, result.instanceCount > 0 else {
                    message = "写真の中に物が見つかりませんでした"
                    return
                }
                analysis = result
                // マスクを作ったときと同じ切り抜きなら、記録した物の番号がそのまま使える。違えば選び直し。
                let sameRegion = photo.mask.inputRegionSource == result.plan.source && photo.mask.inputRegion == result.plan.recordedRegion
                selected = sameRegion ? photo.mask.selectedInstances : []
                editing = true
            case .failure(let error):
                message = "切り抜きを作り直せません（\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)）"
            }
        }
    }

    private func tapped(at location: CGPoint, imageRect: CGRect) {
        guard let analysis, analysis.labelMap != nil, let photo, !working, imageRect.contains(location) else { return }
        // タップ → 表示した画像の 0〜1 → センサーの向きの写真の 0〜1 → 切り抜き → 物の番号の画像。
        let display = SIMD2((location.x - imageRect.minX) / imageRect.width, (location.y - imageRect.minY) / imageRect.height)
        let sensor = DisplayRotation.sensorPoint(fromDisplay: SIMD2(Double(display.x), Double(display.y)), rotationDegClockwise: photo.image.displayRotationDegClockwise)
        let label = analysis.label(atNormalizedImagePoint: sensor)
        guard label > 0 else {
            message = "そこには物が見つかっていません"
            return
        }
        let next = MaskInstanceSelector.toggle(label, in: selected)
        working = true
        message = nil
        model.masks.applyUserSelection(sessionId: sessionId, photoId: photoId, analysis: analysis, selected: next) { error in
            working = false
            if let error {
                message = "保存できませんでした（\(error.localizedDescription)）"
            } else {
                selected = next
                reload()
            }
        }
    }

    /// 切り抜きを作り直す（元写真は変えない。順番待ちに入れ、1 枚ずつ処理する）。
    private func regenerate() {
        message = nil
        model.masks.regenerate(sessionId: sessionId, photoIds: [photoId], includeConfirmed: true)
    }

    private func setMaskStatus(_ status: MaskStatus) {
        do {
            try model.store.updateSession(sessionId) { s in
                if let i = s.photos.firstIndex(where: { $0.photoId == photoId }) { s.photos[i].mask.status = status }
            }
        } catch {
            message = error.localizedDescription
        }
        model.sessionChanged()
    }

    private func rejectMask() {
        do {
            try model.store.updateSession(sessionId) { s in
                if let i = s.photos.firstIndex(where: { $0.photoId == photoId }) {
                    s.photos[i].mask = .failed("userRejected", instanceCount: s.photos[i].mask.instanceCount)
                }
            }
            try? FileManager.default.removeItem(at: model.store.maskURL(sessionId, photoId: photoId))
        } catch {
            message = error.localizedDescription
        }
        model.sessionChanged()
    }

    private func deletePhoto(retake: Bool) {
        let target = photo?.direction.targetId
        do {
            try model.store.deletePhoto(sessionId: sessionId, photoId: photoId)
        } catch {
            message = error.localizedDescription
            return
        }
        model.sessionChanged()
        if retake {
            model.path = [.capture(sessionId: sessionId, preferredTargetId: target)]
        } else if !model.path.isEmpty {
            model.path.removeLast()
        }
    }

    // MARK: 文

    private func directionText(_ photo: Photo) -> String {
        var parts: [String] = []
        if let target = session?.directionPlan.target(id: photo.direction.targetId) {
            parts.append("方向 \(DirectionTarget.formatDegrees(target.azimuthDeg))°・高さ \(DirectionTarget.formatDegrees(target.elevationDeg))°")
        } else {
            parts.append("撮る方向の一覧の外（追加撮影）")
        }
        if let az = photo.direction.azimuthDeg { parts.append("方位 \(String(format: "%.1f", az))°") }
        if let el = photo.direction.elevationDeg { parts.append("仰角 \(String(format: "%.1f", el))°") }
        if let d = photo.direction.distanceM { parts.append("距離 \(String(format: "%.2f", d)) m") }
        return parts.joined(separator: "・")
    }

    private func unconfirmedText(_ reason: UnconfirmedReason?) -> String {
        switch reason {
        case .trackingNotNormal: return "位置が不安定"
        case .noReference: return "基準なし"
        case .referenceInvalidated: return "基準が無効"
        case nil: return "不明"
        }
    }

    private func statusText(_ status: CheckStatus) -> String {
        switch status {
        case .ok: return "OK"
        case .warning: return "注意"
        case .blocked: return "不可"
        case .unknown: return "不明"
        }
    }
}
