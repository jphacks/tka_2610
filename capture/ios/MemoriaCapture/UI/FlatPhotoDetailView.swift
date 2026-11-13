import CaptureCore
import SwiftUI

/// 平面の作品の写真 1 枚の確認（遠近を直した画像・元の写真に紙の輪郭、測った大きさ、撮り直し・削除）。
/// 自由に撮った立体の写真（`guidance` が `free`）もこの画面（紙の表示は無く、傾きと入力した高さだけ）。
struct FlatPhotoDetailView: View {
    let sessionId: String
    let photoId: String

    enum Mode: String, CaseIterable, Identifiable {
        case rectified = "直した画像", original = "元の写真"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @State private var session: CaptureSession?
    @State private var photoImage: UIImage?
    @State private var rectifiedImage: UIImage?
    @State private var mode: Mode = .rectified
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var confirmRetake = false

    private var photo: Photo? { session?.photo(id: photoId) }
    private var locked: Bool { model.isLocked(sessionId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if photo?.flat?.rectified != nil {
                    Picker("表示", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                imageArea
                    .frame(maxWidth: .infinity)
                    .frame(height: 440)
                    .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(.orange)
                }
                if let photo {
                    info(photo)
                    actions
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
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        let showRectified = mode == .rectified && photo?.flat?.rectified != nil
        if let image = showRectified ? rectifiedImage : photoImage {
            GeometryReader { geo in
                let rect = fittedRect(imageSize: image.size, in: geo.size)
                ZStack {
                    Image(uiImage: image).resizable().scaledToFit()
                    if !showRectified, let outline = outlinePoints(in: rect) {
                        Path { path in
                            path.addLines(outline)
                            path.closeSubpath()
                        }
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    /// 紙の四隅（センサーの向きのピクセル）を、まっすぐに回して表示した画像の上の点にする。
    private func outlinePoints(in rect: CGRect) -> [CGPoint]? {
        guard let photo, let corners = photo.flat?.corners else { return nil }
        let w = Double(photo.image.width), h = Double(photo.image.height)
        return corners.points.map { p in
            let d = DisplayRotation.displayPoint(fromSensor: SIMD2(p.x / w, p.y / h), rotationDegClockwise: photo.image.displayRotationDegClockwise)
            return CGPoint(x: rect.minX + d.x * rect.width, y: rect.minY + d.y * rect.height)
        }
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func info(_ photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if session?.usesFreeCapture == true {
                freeInfo(photo)
            } else {
                flatInfo(photo)
            }
            if let saved = photo.quality.saved {
                Text("明るさ \(String(format: "%.2f", saved.meanLuma))・シャープさ \(String(format: "%.4f", saved.sharpness))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(photo.image.width) × \(photo.image.height)・\(photo.trigger == .auto ? "自動" : "手動")撮影")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 自由に撮った写真（立体）：傾きと入力した高さだけ（方向・紙・マスクは無い）。
    @ViewBuilder
    private func freeInfo(_ photo: Photo) -> some View {
        Label("自由に撮った写真", systemImage: "hand.tap").font(.subheadline.bold())
        if let el = photo.direction.elevationDeg {
            Text("見下ろす角度 \(String(format: "%.1f", el))°（0° が水平、90° が真下）").font(.subheadline)
        }
        if let height = session?.declaredHeightM {
            Text(String(format: "高さ：%.1f cm（入力した値）", height * 100)).font(.subheadline)
        }
    }

    /// 平面の作品の写真：真上か・紙・大きさ・直した画像。
    @ViewBuilder
    private func flatInfo(_ photo: Photo) -> some View {
        Group {
            if photo.direction.targetId != nil {
                Label("真上から撮りました", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("真上から撮れていません", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.subheadline.bold())
        if let el = photo.direction.elevationDeg {
            Text("傾き \(String(format: "%.1f", el))°（90° が真下）").font(.subheadline)
        }
        if let sheet = session?.declaredSheet {
            Text("紙：\(sheet.displayName)（選んだ大きさ。\(String(format: "%.1f × %.1f cm", sheet.shortSideM * 100, sheet.longSideM * 100))）")
                .font(.subheadline)
        }
        if let flat = photo.flat, flat.corners != nil {
            Text("紙：見つかりました" + (flat.cornersConfidence.map { "（確からしさ \(String(format: "%.2f", $0))）" } ?? "")).font(.subheadline)
            if flat.sheetAtFrameEdge == true {
                Text("紙の角が写真の端に近く、紙の一部が切れているかもしれません").font(.subheadline).foregroundStyle(.orange)
            }
            if let size = flat.size, session?.declaredSheet != nil {
                // 紙を選んだときは、測った大きさは参考（選んだ大きさを使う）。
                Text("参考：測った大きさ \(String(format: "%.1f × %.1f cm", size.widthM * 100, size.heightM * 100))（\(size.planeSource == "existingPlaneGeometry" ? "見つかった机の平面" : "ARKit が推定した平面")で測定）")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let size = flat.size {
                Text("大きさ：\(String(format: "%.1f × %.1f cm", size.widthM * 100, size.heightM * 100))（\(size.planeSource == "existingPlaneGeometry" ? "見つかった机の平面" : "ARKit が推定した平面")で測定）")
                    .font(.subheadline)
            } else if session?.declaredSheet == nil {
                Text("大きさ：測れませんでした（机の平面が見つからなかった）").font(.subheadline).foregroundStyle(.secondary)
            }
            if let r = flat.rectified {
                Text("直した画像：\(r.width) × \(r.height)").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("紙が見つからなかったので、写真の全体をそのまま使います（遠近は直していません\(session?.declaredSheet == nil ? "・大きさは不明" : "")）")
                .font(.subheadline).foregroundStyle(.orange)
        }
    }

    private var actions: some View {
        HStack {
            Button("撮り直す") { confirmRetake = true }.disabled(locked)
            Button("削除", role: .destructive) { confirmDelete = true }.disabled(locked)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        session = model.loadSession(sessionId)
        guard let photo else { return }
        let photoURL = model.store.photoURL(sessionId, photoId: photoId)
        let rectifiedURL = model.store.rectifiedURL(sessionId, photoId: photoId)
        let rotation = photo.image.displayRotationDegClockwise
        let hasRectified = photo.flat?.rectified != nil
        Task.detached(priority: .userInitiated) {
            let image = ImageLoading.thumbnail(url: photoURL, maxPixel: 2048).map { ImageLoading.uiImage($0, rotation: rotation) }
            let rectified = hasRectified ? ImageLoading.thumbnail(url: rectifiedURL, maxPixel: 2048).map { ImageLoading.uiImage($0, rotation: 0) } : nil
            await MainActor.run {
                photoImage = image
                rectifiedImage = rectified
                if rectified == nil { mode = .original }
            }
        }
    }

    private func deletePhoto(retake: Bool) {
        do {
            try model.store.deletePhoto(sessionId: sessionId, photoId: photoId)
        } catch {
            message = error.localizedDescription
            return
        }
        model.sessionChanged()
        if retake {
            model.path = [.capture(sessionId: sessionId, preferredTargetId: nil)]
        } else if !model.path.isEmpty {
            model.path.removeLast()
        }
    }
}
