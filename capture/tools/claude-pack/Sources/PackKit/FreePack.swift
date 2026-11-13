import Foundation
import CoreGraphics
import CaptureCore

/// Free capture (`guidance` "free", plan `free`): 3D work shot freely, any number of photos, no guidance, no reference
/// frame, no masks; only the camera's look-down angle is recorded. The pack holds the photos turned upright
/// (`views/photo-01.jpg`…, in shooting order, at most `maxFreeViews`), the declared height if any, and says that which photo
/// shows which side is for the reader to judge. No overview grid (its layout needs known directions), no hull.
extension PackBuilder {
    /// At most this many photos go into `views/`.
    public static let maxFreeViews = 16

    /// The photos the pack uses: all of them in shooting order, or, when there are more than `limit`, `limit` photos spread
    /// evenly over the shooting order (the first and the last always included).
    public static func chooseFreePhotos(session: CaptureSession, limit: Int = maxFreeViews) -> [Photo] {
        let sorted = session.photos.sorted { $0.sequence < $1.sequence }
        guard sorted.count > limit, limit > 1 else { return Array(sorted.prefix(max(limit, 0))) }
        let n = sorted.count
        return (0..<limit).map { i in sorted[Int((Double(i) * Double(n - 1) / Double(limit - 1)).rounded())] }
    }

    /// `views/photo-NN.jpg` name of the i-th chosen photo (0-based).
    static func freeViewName(_ index: Int) -> String { String(format: "photo-%02d", index + 1) }

    func writeFree(into dir: URL, started: Date) throws -> String {
        let photos = timed("selectViews") { Self.chooseFreePhotos(session: session) }
        var choices: [ViewChoice] = []
        try timed("views") {
            for (i, photo) in photos.enumerated() {
                var c = freeChoice(photo, name: Self.freeViewName(i))
                c.cropSource = "fullImage"
                try writeScaled(url(photo.image.file), rotation: photo.image.displayRotationDegClockwise, name: c.name, into: dir, choice: &c)
                choices.append(c)
            }
        }

        var m = Measurements(sessionId: session.sessionId, status: "unavailable")
        m.method = "freeCapture"
        m.unavailableReason = "free capture: the size is not derived from the photos (no reference frame, no masks)"
        m.frame = [
            "units": "metres",
            "frame": "none: free capture records no object position and no direction around the object (only each photo's look-down angle)",
        ]
        m.declaredHeight = session.declaredHeightM.map { Measurements.DeclaredHeight(heightM: $0) }
        m.caveats = m.declaredHeight == nil
            ? ["The size is unknown. Do not invent one; if a size is needed, say it is a guess."]
            : ["Only the height is known (typed in by the person, not measured). Choose width and depth so their ratio to this height matches the photos; say they are estimates."]
        m.seconds = 0

        let freeSource = PackIndex.FreeSource(photoCount: session.photos.count, viewCount: choices.count,
                                              selection: session.photos.count > Self.maxFreeViews ? "evenlySpaced" : "all")
        let els = session.photos.compactMap(\.direction.elevationDeg)
        let coverage = PackIndex.Coverage(
            referenceFrameId: nil, referenceFrameIds: session.referenceFrames.map(\.id),
            photoCount: session.photos.count, photosInReferenceFrame: session.photos.filter(\.direction.confirmed).count,
            minElevationDeg: els.min().map(round1), maxElevationDeg: els.max().map(round1),
            directionPlanId: session.directionPlan.id, bands: [],
            missingViews: [], weakViews: choices.filter { !$0.notes.isEmpty }.map(\.name))

        let now = Date()
        let provenance = makeProvenance(now: now)
        timings["total"] = (now.timeIntervalSince(started) * 100).rounded() / 100
        let files = ["brief.md", "measurements.json", "pack.json"] + choices.compactMap(\.file)

        let brief = Brief.freeMarkdown(session: session, provenance: provenance, choices: choices, measurements: m, source: freeSource)
        try Data(brief.utf8).write(to: dir.appendingPathComponent("brief.md"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(m).write(to: dir.appendingPathComponent("measurements.json"))
        var index = PackIndex(workKind: WorkKind.object.rawValue, provenance: provenance, title: session.title, views: choices,
                              coverage: coverage, maskIssues: [], files: files, timingsS: timings)
        index.guidance = CaptureGuidance.free.rawValue
        index.free = freeSource
        try encoder.encode(index).write(to: dir.appendingPathComponent("pack.json"))

        let height = m.declaredHeight.map { String(format: "declared height %.1f cm", $0.heightCm) } ?? "size unknown"
        return String(format: "[pack] %@: free capture, %d/%d photos, %@, %.1fs", session.sessionId, choices.count, session.photos.count,
                      height, timings["total"] ?? 0)
    }

    /// A view entry for a freely shot photo (only the look-down angle is known; nothing was requested, so
    /// `requestedElevationDeg` repeats the measured angle).
    func freeChoice(_ p: Photo, name: String) -> ViewChoice {
        var c = ViewChoice(name: name, label: "photo #\(p.sequence)", requestedAzimuthDeg: nil,
                           requestedElevationDeg: p.direction.elevationDeg ?? 0, notes: [])
        c.photoId = p.photoId
        c.sequence = p.sequence
        c.targetId = nil
        c.azimuthDeg = nil
        c.elevationDeg = p.direction.elevationDeg
        c.distanceM = nil
        if !p.direction.confirmed { c.notes.append("tracking was not available: the look-down angle is approximate") }
        if let q = SavedQualityRank.note(p) { c.notes.append(q) }
        return c
    }
}

extension Brief {
    /// `brief.md` for free capture (Japanese). Says how many photos, that no direction was guided, each photo's look-down
    /// angle, and the declared height (preferred) or that the size is unknown.
    public static func freeMarkdown(session: CaptureSession, provenance: PackIndex.Provenance, choices: [ViewChoice],
                                    measurements m: Measurements, source: PackIndex.FreeSource) -> String {
        var out: [String] = []
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append("# 3D モデルを作るための入力（\(title.isEmpty ? "作品名なし" : title)）")
        out.append("")
        out.append("子どもが作った立体の作品を、撮影アプリで **案内なしで自由に撮った写真 \(source.photoCount) 枚** です。"
                   + "受信した撮影セッション（`sessions/\(session.sessionId)/`）から `memoria-pack` が自動で作りました。元のセッションは変えていません。")
        out.append("")
        out.append("- 作品名（撮影アプリで入力した名前）：\(title.isEmpty ? "（空。何の作品かは書かれていません）" : "「\(title)」")")
        out.append("- **向き・位置の案内はしていません。** どの写真が正面・横・後ろ・真上かは記録していないので、**写真を見て判断してください。** 正面も決まっていません。")
        out.append("- 作品の位置・座標・切り抜き（マスク）はありません。分かっているのは、写真ごとの見下ろす角度（カメラが水平から下へ傾いた角度）だけです。")
        out.append("- 一覧の画像（`overview.jpg`）と粗い形（`hull.obj`）はありません（向きが分からないため）。")
        out.append("")

        if let d = m.declaredHeight {
            out.append("## 高さ（撮る人が入力した値）")
            out.append("")
            out.append("- **高さは \(f1(d.heightCm)) cm です。** 撮る人が撮影アプリで入力した値で、AR や写真で測った値ではありません（`measurements.json` の `declaredHeight`）。この高さに合わせてください。")
            out.append("- 幅・奥行きは分かりません。この高さとの比が写真と合うように決め、推測した値であることを結果に書いてください。")
        } else {
            out.append("## 大きさ（分かりません）")
            out.append("")
            out.append("**大きさは分かりません**（撮る人は高さを入力していません。写真から大きさは求めていません）。推測で決めるときは、推測したことを結果に書いてください。")
        }
        out.append("")

        out.append("## 写真（`views/`）")
        out.append("")
        out.append("撮った順に、上下をまっすぐに回したものです（切り抜きなし・背景は写ったまま。長い辺 \(CropMath.maxOutputSide) px 以下）。"
                   + (source.selection == "evenlySpaced"
                      ? "写真が \(source.photoCount) 枚と多いので、撮った順に均等に \(source.viewCount) 枚を選びました（最初と最後を含む）。"
                      : "撮った写真をすべて入れました。"))
        out.append("")
        out.append("| ファイル | 撮った順 | 見下ろす角度 | 写真 | メモ |")
        out.append("|---|---|---|---|---|")
        for c in choices {
            guard let id = c.photoId else { continue }
            let files = c.file.map { "`\($0)`" } ?? "—"
            out.append("| \(files) | #\(c.sequence ?? 0) | \(f0(c.elevationDeg))° | `\(id)` | \(freeNotesJa(c, session: session).joined(separator: "、")) |")
        }
        out.append("")
        out.append("- 見下ろす角度：0° はカメラが水平、90° は真下を向いていた（真上から撮った）ことを表します。60° 以上の写真は、真上に近い写真の候補です。")
        out.append("- **底面は写っていません**（作品を机に置いて撮ったため）。写っていない所は推測になります。推測した部分は結果に書いてください。")
        out.append("")

        out.append("## AI でモデルを作るときの使い方")
        out.append("")
        out.append("1. `views/` の写真をすべて見て、どれが正面・横・後ろ・真上に近いかを決める（作品の顔や模様などから正面を判断する）。")
        out.append("2. 形・色・模様・細部を写真から読み取る。写真には背景（机・まわりの物）も写っています。作品は真ん中あたりの物です。")
        out.append(m.declaredHeight == nil
                   ? "3. 大きさは分かりません。写真から推測し、推測した大きさは結果に書く。"
                   : "3. 高さは撮る人が入力した \(f1(m.declaredHeight?.heightCm)) cm に合わせる。幅・奥行きは写真の比から決め、推測と書く。")
        out.append("4. 単位はメートル、上は +Y を使うのがおすすめです（座標の決まりはこのセッションにはありません）。")
        out.append("")
        out.append("**これらの画像を Claude やほかのクラウドのツールに渡すことは外部への送信にあたります。** 子どもの作品とまわりが写った個人の写真です。送るかどうかはユーザーが決めます。")
        out.append("")

        out.append("## 出どころ")
        out.append("")
        out.append("- sessionId：`\(provenance.sessionId)`")
        out.append("- manifestHash（`_receipt.json`）：`\(provenance.manifestHash ?? "なし")`")
        out.append("- 受信：\(provenance.receivedAt ?? "記録なし")")
        out.append("- 作成：\(provenance.generatedAt)（\(provenance.tool) \(provenance.toolVersion)）")
        out.append("- 機械で読む一覧：`pack.json`（`guidance` は `free`、使った写真と見下ろす角度、`free` に枚数と選び方）、`measurements.json`（`method` は `freeCapture`、大きさは求めていない。撮る人が高さを入力したときは `declaredHeight`）")
        out.append("")
        return out.joined(separator: "\n")
    }

    /// Remarks about a freely shot photo, in Japanese.
    static func freeNotesJa(_ c: ViewChoice, session: CaptureSession) -> [String] {
        guard let id = c.photoId, let p = session.photo(id: id) else { return [] }
        var notes: [String] = []
        if !p.direction.confirmed { notes.append("追跡が無く、角度は参考値") }
        if let saved = p.quality.saved {
            if saved.blur != .ok { notes.append("ぶれ \(saved.blur.rawValue)") }
            if saved.brightness != .ok { notes.append("明るさ \(saved.brightness.rawValue)") }
        } else {
            notes.append("画質は未解析")
        }
        return notes
    }
}
