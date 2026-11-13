import ARKit
import CaptureCore
import SwiftUI

/// 撮影画面の共通の入れ物（4 つの撮影画面のどれもこれを使う）。
/// カメラの映像（ARSCNView）を写真と同じ縦横比（縦に持つので今は 3:4）の枠にして画面の幅に合わせ、余った上下を黒い帯にする。
/// 画面に見える範囲＝保存する写真に写る範囲（標準のカメラと同じ）。置き方の計算は CaptureCore の `CameraPreview.layout`。
///
/// - `overlay`：映像の上に描く印（十字・紙の輪郭など）。映像の枠と同じ大きさ・同じ座標（＝ ARSCNView の bounds）で、触れない。
/// - `panels`：映像の上に浮かべる案内（知らせ・方向の地図など）。上下の帯の中身が映像に重なる所は除いた範囲に置く。
/// - `top`：上の帯（案内の文など）。帯より高いときは、映像の上の端に重なる。
/// - `bottom`：下の帯（シャッターの列など）。帯より高いときは、映像の下の端に重なる。
/// ナビゲーションバー（「やめる」「これで登録」「確認」）の下・ホームインジケーターの上に置くので、バーが映像を隠さない。
struct CameraPreviewContainer<Overlay: View, Panels: View, Top: View, Bottom: View>: View {
    /// 下の操作（シャッターの列）の高さ（シャッター 78 pt と上下の余白）。小さい画面でも、これだけは下の帯に取る。
    static var controlsHeight: CGFloat { 100 }

    let arView: ARSCNView
    /// 縦に持って見た映像の幅 / 高さ。分からなければ nil（3:4 にする）。
    let imageAspect: Double?
    @ViewBuilder let overlay: () -> Overlay
    @ViewBuilder let panels: () -> Panels
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    @State private var topContentHeight: CGFloat = 0
    @State private var bottomContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let layout = CameraPreview.layout(
                in: PreviewRect(x: 0, y: 0, width: Double(geo.size.width), height: Double(geo.size.height)),
                imageAspect: imageAspect, bottomControlsHeight: Double(Self.controlsHeight)
            )
            let image = CGRect(layout.image)
            let panelArea = CGRect(CameraPreview.panelArea(layout, topContentHeight: Double(topContentHeight),
                                                           bottomContentHeight: Double(bottomContentHeight)))
            ZStack(alignment: .topLeading) {
                ARCameraView(arView: arView)
                    .frame(width: image.width, height: image.height)
                    .placed(at: image.origin)
                overlay()
                    .frame(width: image.width, height: image.height)
                    .allowsHitTesting(false)
                    .placed(at: image.origin)
                panels()
                    .frame(width: panelArea.width, height: panelArea.height, alignment: .top)
                    .placed(at: panelArea.origin)
                top()
                    .frame(width: geo.size.width)
                    .frame(minHeight: CGFloat(layout.topBar.height))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topContentHeight = $0 }
                bottom()
                    .frame(width: geo.size.width)
                    .frame(minHeight: CGFloat(layout.bottomBar.height))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomContentHeight = $0 }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private extension View {
    /// 親（左上が原点の ZStack）の中で、左上を `origin` に置く。
    func placed(at origin: CGPoint) -> some View {
        padding(.leading, origin.x).padding(.top, origin.y)
    }
}

private extension CGRect {
    init(_ rect: PreviewRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

/// 上の帯の案内の文（撮影画面で共通）。帯が薄くて映像に重なっても読めるよう、暗い下地を付ける。
struct CaptureGuidanceText: View {
    let text: String
    var tip: String?
    var tipSystemImage = "lightbulb.fill"

    var body: some View {
        VStack(spacing: 4) {
            Text(text)
                .font(.subheadline.bold())
            if let tip {
                Label(tip, systemImage: tipSystemImage)
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

/// 上の帯の小さな情報（選んだ紙・入力した高さ・傾きなど）。
struct CaptureInfoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.15), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// ARSCNView を SwiftUI に置く（4 つの撮影画面で共通）。
struct ARCameraView: UIViewRepresentable {
    let arView: ARSCNView

    func makeUIView(context: Context) -> ARSCNView { arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

extension ARConfiguration.VideoFormat {
    /// この形式の映像を縦に持って見たときの幅 / 高さ（撮影画面の映像の枠の縦横比。高解像度の写真も同じ比）。
    var portraitAspect: Double {
        CameraPreview.portraitAspect(imageWidth: Double(imageResolution.width), imageHeight: Double(imageResolution.height))
    }
}
