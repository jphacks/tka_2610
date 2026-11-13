import Foundation
import CoreGraphics
import simd
import CaptureCore

public struct PackOptions: Equatable, Sendable {
    public var session: String
    public var dataDir: String?
    public var force = false
    /// Also write `views/<name>_cutout.png` (transparent, alpha = the iPhone mask). Off by default: the reader is an AI
    /// that looks at photos, and the photo with its background is what it should see.
    public var cutouts = false

    public static let usage = """
    usage: memoria-pack <session folder | sessionId | sessionId prefix> [--data-dir DIR] [--force] [--cutouts]

    Writes <data-dir>/for_claude/<sessionId>/ (views, overview.jpg, measurements.json, hull.obj, brief.md, pack.json)
    from a received session. The session folder itself is never modified.
      --data-dir DIR  receiver data folder (default: nearest captures/ above the current folder, else the repo's captures/)
      --force         rebuild even when the package is up to date (same manifestHash, tool version and options)
      --cutouts       also write views/<name>_cutout.png: transparent PNGs cut out with the iPhone mask
    """

    public static func parse(_ args: [String]) throws -> PackOptions {
        var session: String?
        var dataDir: String?
        var force = false
        var cutouts = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help": throw UsageError("")
            case "--force": force = true
            case "--cutouts": cutouts = true
            case "--data-dir":
                guard i + 1 < args.count else { throw UsageError("--data-dir needs a value") }
                dataDir = args[i + 1]
                i += 1
            default:
                if a.hasPrefix("--data-dir=") { dataDir = String(a.dropFirst("--data-dir=".count)) }
                else if a.hasPrefix("-") { throw UsageError("unknown option \(a)") }
                else if session == nil { session = a }
                else { throw UsageError("unexpected argument \(a)") }
            }
            i += 1
        }
        guard let session else { throw UsageError("missing session") }
        return PackOptions(session: session, dataDir: dataDir, force: force, cutouts: cutouts)
    }
}

func eprint(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

public enum Runner {
    public static func run(arguments: [String]) -> Int32 {
        let options: PackOptions
        do {
            options = try PackOptions.parse(arguments)
        } catch let e as UsageError {
            if e.description.isEmpty { print(PackOptions.usage); return 0 }
            eprint("error: \(e.description)\n\n\(PackOptions.usage)")
            return 2
        } catch {
            eprint("error: \(error)")
            return 2
        }
        do {
            let located = try SessionLocator.locate(options.session, dataDir: SessionLocator.dataDir(option: options.dataDir))
            let outDir = try SessionLocator.outputDir(located: located)
            if !options.force, let hash = located.receipt?.manifestHash, isUpToDate(outDir, manifestHash: hash, cutouts: options.cutouts) {
                print("[pack] \(located.session.sessionId): up to date (\(outDir.path)); use --force to rebuild")
                return 0
            }
            let builder = PackBuilder(located: located)
            builder.writeCutouts = options.cutouts
            let result = try builder.build(into: outDir)
            print(result)
            return 0
        } catch let e as UsageError {
            eprint("error: \(e.description)")
            return 2
        } catch {
            eprint("error: \(error)")
            return 1
        }
    }

    static func isUpToDate(_ outDir: URL, manifestHash: String, cutouts: Bool) -> Bool {
        guard let data = try? Data(contentsOf: outDir.appendingPathComponent("pack.json")),
              let index = try? JSONDecoder().decode(PackIndex.self, from: data) else { return false }
        return index.provenance.manifestHash == manifestHash && index.provenance.toolVersion == PackInfo.toolVersion
            && (index.provenance.cutouts ?? false) == cutouts
    }
}

/// Builds the package in a temporary folder next to the destination and swaps it in.
public final class PackBuilder {
    let located: LocatedSession
    /// The session as received, except that for a heading-guided session (`guidance: "heading"`) the centre, object frame
    /// and approximate size are derived here when the iPhone has not (yet) written them (`HeadingSizer.refresh`, the same
    /// CaptureCore code the app runs). Only this in-memory copy is changed; the session folder is never written.
    let session: CaptureSession
    /// For heading-guided sessions: whether this tool (not the iPhone) derived the centre or the size.
    var headingComputedHere = false
    var timings: [String: Double] = [:]
    public var hullSettings = HullSettings()
    /// Write `views/<name>_cutout.png` (`--cutouts`).
    public var writeCutouts = false
    /// Long side of the masks used for carving (the stored masks are 4032 px; a quarter is plenty for 2 mm voxels).
    public var hullMaskMaxSide = 1008
    /// Fewer silhouettes than this: no visual hull (a hull from a handful of views, e.g. the 5 of an `ai5` session,
    /// is a loose box whose sizes look more precise than they are). The user-fitted cylinder is reported instead.
    public static let minimumHullViews = 8

    public init(located: LocatedSession) {
        self.located = located
        var session = located.session
        if session.usesHeadingGuidance {
            let folder = located.folder
            headingComputedHere = HeadingSizer.refresh(session: &session) { photo in
                guard let f = photo.mask.file, let m = try? ImageOps.loadMask(folder.appendingPathComponent(f), maxSide: 1008) else { return nil }
                return MaskBounds.of(pixels: m.pixels, width: m.width, height: m.height)
            }
        }
        self.session = session
    }

    func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let t0 = Date()
        defer { timings[name] = ((Date().timeIntervalSince(t0)) * 100).rounded() / 100 }
        return try body()
    }

    func url(_ relative: String) -> URL { located.folder.appendingPathComponent(relative) }

    func maskExists(_ p: Photo) -> Bool {
        guard let f = p.mask.file else { return false }
        return FileManager.default.fileExists(atPath: url(f).path)
    }

    /// Returns a one-line summary.
    public func build(into outDir: URL) throws -> String {
        let started = Date()
        let fm = FileManager.default
        let parent = outDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let sid = session.sessionId
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(".tmp-\(sid)-") || name.hasPrefix(".old-\(sid)-") {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
        let tmp = parent.appendingPathComponent(".tmp-\(sid)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("views"), withIntermediateDirectories: true)
        do {
            let summary = try write(into: tmp, started: started)
            try swap(tmp, into: outDir)
            return summary + " → \(outDir.path)"
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Replaces `outDir` with `tmp` (rename, so readers never see a half-written package).
    func swap(_ tmp: URL, into outDir: URL) throws {
        let fm = FileManager.default
        let old = outDir.deletingLastPathComponent().appendingPathComponent(".old-\(session.sessionId)-\(UUID().uuidString)")
        if fm.fileExists(atPath: outDir.path) { try fm.moveItem(at: outDir, to: old) }
        do {
            try fm.moveItem(at: tmp, to: outDir)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: outDir) }
            throw error
        }
        try? fm.removeItem(at: old)
    }

    func write(into dir: URL, started: Date) throws -> String {
        if session.isFlat { return try writeFlat(into: dir, started: started) }
        if session.usesFreeCapture { return try writeFree(into: dir, started: started) }
        let selection = timed("selectViews") { ViewSelector.select(session: session, maskFileExists: maskExists) }
        var choices = selection.choices
        var tiles: [Overview.Tile] = []
        try timed("views") {
            for i in choices.indices {
                let image = try writeView(&choices[i], dir: dir)
                tiles.append(Overview.Tile(name: choices[i].name, label: tileLabel(choices[i]), image: image))
            }
        }

        var measurements = timed("visualHull") { measure(referenceFrameId: selection.referenceFrameId, dir: dir) }
        measurements.seconds = timings["visualHull"] ?? 0
        // The height the person typed in (preferred over the derived / measured height; the numbers above are not rescaled).
        measurements.declaredHeight = session.declaredHeightM.map { Measurements.DeclaredHeight(heightM: $0) }
        try timed("overview") {
            let sheet = try Overview.render(tiles: tiles, footer: footerLines(measurements))
            try ImageOps.writeJPEG(sheet, to: dir.appendingPathComponent("overview.jpg"), quality: 0.88)
        }

        let coverage = coverageInfo(referenceFrameId: selection.referenceFrameId, choices: choices)
        let maskIssues = maskIssueList()
        let now = Date()
        let provenance = makeProvenance(now: now)
        var files = ["brief.md", "overview.jpg", "measurements.json", "pack.json"]
        if measurements.mesh != nil { files.append("hull.obj") }
        files += choices.flatMap { [$0.file, $0.cutoutFile].compactMap { $0 } }
        timings["total"] = (now.timeIntervalSince(started) * 100).rounded() / 100

        let brief = Brief.markdown(session: session, provenance: provenance, choices: choices, measurements: measurements,
                                   coverage: coverage, maskIssues: maskIssues, cutouts: writeCutouts)
        try Data(brief.utf8).write(to: dir.appendingPathComponent("brief.md"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(measurements).write(to: dir.appendingPathComponent("measurements.json"))
        var index = PackIndex(workKind: session.workKind.rawValue, provenance: provenance, title: session.title, views: choices,
                              coverage: coverage, maskIssues: maskIssues, files: files, timingsS: timings)
        index.guidance = session.captureGuidance?.rawValue
        try encoder.encode(index).write(to: dir.appendingPathComponent("pack.json"))

        let shown = choices.filter { !$0.isMissing }.count
        let size = measurements.method == "headingDerived"
            ? measurements.sizeCm.map { String(format: "approx. W %.1f × D %.1f × H %.1f cm (derived after capture, %@ confidence)", $0.width, $0.depth, $0.height, measurements.confidence ?? "?") }
                ?? "size unavailable (\(measurements.unavailableReason ?? "?"))"
            : measurements.method == "userCylinder"
            ? measurements.sizeCm.map { String(format: "approx. ⌀ %.1f × H %.1f cm (user cylinder, not measured)", $0.width, $0.height) } ?? "size unavailable"
            : measurements.sizeCm.map { String(format: "W %.1f × D %.1f × H %.1f cm ±%.1f", $0.width, $0.depth, $0.height, measurements.uncertainty?.plusMinusCm ?? 0) }
            ?? "size unavailable (\(measurements.unavailableReason ?? "?"))"
        if measurements.method == "headingDerived" {
            return String(format: "[pack] %@: %d/%d views, %@, %d masks, %.1fs", session.sessionId, shown, choices.count, size,
                          measurements.usableSilhouettes, timings["total"] ?? 0)
        }
        return String(format: "[pack] %@: %d/%d views, %@, %d hull views, %.1fs", session.sessionId, shown, choices.count, size,
                      measurements.viewsUsed, timings["total"] ?? 0)
    }

    func makeProvenance(now: Date) -> PackIndex.Provenance {
        PackIndex.Provenance(
            sessionId: session.sessionId, manifestHash: located.receipt?.manifestHash, receivedAt: located.receipt?.receivedAt,
            generatedAt: ISODate.string(now, timeZone: TimeZone(identifier: "UTC")!),
            tool: PackInfo.toolName, toolVersion: PackInfo.toolVersion, sourceFolder: located.folder.path, cutouts: writeCutouts)
    }

    // MARK: Views

    func tileLabel(_ c: ViewChoice) -> String {
        guard let az = c.azimuthDeg, let el = c.elevationDeg else { return "\(c.label) · (no photo)" }
        return String(format: "%@ · %.0f° / %.0f°", c.label, az, el) + (c.maskUse == .good ? "" : " · mask?")
    }

    /// Writes views/<name>.jpg (the upright crop with its background) and, with `writeCutouts`, views/<name>_cutout.png
    /// (the same crop, transparent outside the iPhone mask, edges feathered by about a pixel). Returns the view image for the overview.
    func writeView(_ choice: inout ViewChoice, dir: URL) throws -> CGImage? {
        guard let id = choice.photoId, let photo = session.photo(id: id) else { return nil }
        let image = try ImageOps.loadImage(url(photo.image.file))
        let W = image.width, H = image.height
        var mask: GrayImage?
        if choice.maskUse != .unusable, let f = photo.mask.file {
            mask = try? ImageOps.loadMask(url(f))
            if let m = mask, m.width != W || m.height != H {
                choice.notes.append("mask size \(m.width)×\(m.height) differs from the photo; not used")
                mask = nil
            }
        }
        var box: PixelRect?
        let heading = session.usesHeadingGuidance
        if let m = mask, let b = m.boundingBox() {
            box = b
            choice.cropSource = "maskBoundingBox"
        } else if let projected = MaskCropPlanner.projectObject(photo: photo, session: session) {
            // Heading-guided sessions: the box derived after capture (centre + approximate size); otherwise the user's cylinder.
            box = projected.boundingBox
            choice.cropSource = heading ? "projectedDerivedBox" : "projectedCylinder"
            mask = nil
        }
        let rotation = photo.image.displayRotationDegClockwise
        var crop = box.flatMap { CropMath.crop(around: $0, imageWidth: W, imageHeight: H) }
        if crop == nil && heading {
            // Size unknown: the square around the crosshair (the photo's centre), the same region the iPhone gave Vision.
            crop = MaskCropPlanner.crosshairPlan(imageWidth: W, imageHeight: H).region
            choice.cropSource = "crosshairCenter"
        } else if crop == nil {
            choice.cropSource = "fullImage"
        }
        let finalCrop = crop ?? PixelBox(x: 0, y: 0, width: W, height: H)
        let out = CropMath.outputSize(crop: finalCrop, rotationDegClockwise: rotation)
        let view = try ImageOps.uprightCrop(image, crop: finalCrop, rotationDegClockwise: rotation, width: out.width, height: out.height)
        let name = "views/\(choice.name).jpg"
        try ImageOps.writeJPEG(view, to: dir.appendingPathComponent(name))
        choice.file = name
        choice.cropInPhoto = finalCrop
        choice.outputWidth = out.width
        choice.outputHeight = out.height
        if writeCutouts, let m = mask, let maskImage = ImageOps.makeGrayImage(m) {
            let alphaImage = try ImageOps.uprightCrop(maskImage, crop: finalCrop, rotationDegClockwise: rotation,
                                                      width: out.width, height: out.height, gray: true)
            let alpha = try ImageOps.gray(alphaImage).boxBlurred()
            let cut = try ImageOps.transparentCutout(photo: view, alpha: alpha)
            let cutName = "views/\(choice.name)_cutout.png"
            try ImageOps.writePNG(cut, to: dir.appendingPathComponent(cutName))
            choice.cutoutFile = cutName
        }
        return view
    }

    // MARK: Size

    func measure(referenceFrameId: String?, dir: URL) -> Measurements {
        if session.usesHeadingGuidance { return measureHeading(referenceFrameId: referenceFrameId) }
        var m = Measurements(sessionId: session.sessionId, status: "unavailable")
        m.referenceFrameId = referenceFrameId
        guard let frameId = referenceFrameId, let frame = session.referenceFrame(id: frameId) else {
            m.unavailableReason = "no reference frame with confirmed photos"
            return m
        }
        m.baseSource = frame.base?.source.rawValue
        guard let objectToWorld = frame.objectToWorld?.simd else {
            m.unavailableReason = "reference frame \(frameId) has no front direction (objectToWorld is null)"
            return m
        }
        guard let size = session.objectSize(referenceFrameId: frameId) else {
            m.unavailableReason = "no object size for reference frame \(frameId)"
            return m
        }
        m.userCylinder = size

        // Silhouettes: every photo of the frame with a normal-tracking pose and a usable mask.
        var candidates: [Photo] = []
        for p in session.photos.sorted(by: { $0.sequence < $1.sequence }) where p.referenceFrameId == frameId {
            var reason: String?
            if p.camera.trackingState != .normal { reason = "tracking \(p.camera.trackingState.rawValue)" }
            else {
                switch MaskUse.of(p, fileExists: maskExists(p)) {
                case .good, .unchecked: break
                case .unusable:
                    reason = "mask not usable (\(p.mask.status.rawValue)\(p.mask.check.map { " " + $0.status.rawValue } ?? ""))"
                }
            }
            if let reason { m.viewsSkipped.append(.init(photoId: p.photoId, sequence: p.sequence, reason: reason)) }
            else { candidates.append(p) }
        }
        var loaded = [HullView?](repeating: nil, count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let p = candidates[i]
            guard let f = p.mask.file, let mask = try? ImageOps.loadMask(url(f), maxSide: hullMaskMaxSide) else { return }
            let k = p.camera.intrinsicsResolution
            // K is for intrinsicsResolution; the mask has the photo's aspect, so scale K to the mask.
            let view = HullView(id: p.photoId, cameraToWorld: p.camera.cameraToWorld.simd, intrinsics: p.camera.intrinsics.simd,
                                intrinsicsWidth: Double(k.width), intrinsicsHeight: Double(k.height), mask: mask.binarized())
            lock.lock(); loaded[i] = view; lock.unlock()
        }
        var views: [HullView] = []
        for (i, v) in loaded.enumerated() {
            if let v { views.append(v) } else {
                m.viewsSkipped.append(.init(photoId: candidates[i].photoId, sequence: candidates[i].sequence, reason: "mask unreadable"))
            }
        }
        m.viewsSkipped.sort { $0.sequence < $1.sequence }
        m.usableSilhouettes = views.count
        guard views.count >= Self.minimumHullViews else {
            Self.useCylinder(&m, size: size, silhouettes: views.count)
            return m
        }

        let empty = VisualHull.grid(radiusM: size.radiusM, heightM: size.heightM, settings: hullSettings)
        var carved = VisualHull.carve(grid: empty, views: views, objectToWorld: objectToWorld, settings: hullSettings)
        var removed = carved.keepLargestComponent()
        let s = carved.voxelSize
        m.viewsUsed = views.count
        m.viewsUsedPhotoIds = views.map(\.id)

        // The table plane: the reference point can be off by a centimetre or more (it is measured during capture),
        // so the plane is estimated from the hull's hidden wedge under the object, and sizes are measured from it.
        let worldToObject = objectToWorld.inverse
        let cameras = views.map { v -> SIMD3<Double> in
            let p = worldToObject * SIMD4(v.cameraToWorld.translation, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        let table = VisualHull.estimateTable(grid: carved, cameraPositions: cameras)
        if let table {
            m.tablePlaneAboveReferenceM = round6(table)
            carved = VisualHull.clip(carved, belowY: table)
            removed += carved.keepLargestComponent()
        } else {
            carved = VisualHull.clip(carved, belowY: 0)
            removed += carved.keepLargestComponent()
            m.caveats.append("The table plane could not be estimated (the hull reaches the bottom of the search box); heights are measured from the reference point.")
        }
        m.removedFragmentVoxels = removed
        // From here on y = 0 is the table plane (the object frame moved up by `table`).
        let tableY = table ?? 0
        var grid = carved
        grid.origin.y -= tableY
        let modelToWorld = objectToWorld * simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, tableY, 0, 1)))
        let boxMin = empty.origin - SIMD3(0, tableY, 0)
        let boxMax = boxMin + SIMD3(Double(empty.nx), Double(empty.ny), Double(empty.nz)) * s
        m.grid = .init(nx: grid.nx, ny: grid.ny, nz: grid.nz, voxelSizeM: round6(s), searchBoxMinM: boxMin.rounded6, searchBoxMaxM: boxMax.rounded6)
        guard var b = grid.bounds(), let ib = grid.indexBounds() else {
            m.unavailableReason = "the silhouettes do not agree on any common volume (poses or masks are inconsistent)"
            return m
        }
        if abs(b.min.y) < s { b.min.y = 0 }
        m.status = "ok"
        let ext = b.max - b.min
        m.sizeM = Size3(width: round6(ext.x), depth: round6(ext.z), height: round6(ext.y))
        m.sizeCm = Size3(width: round1(ext.x * 100), depth: round1(ext.z * 100), height: round1(ext.y * 100))
        m.bboxMinM = b.min.rounded6
        m.bboxMaxM = b.max.rounded6
        let count = grid.count
        m.voxelCount = count
        m.volumeCm3 = round1(Double(count) * s * s * s * 1e6)
        if ib.min.x == 0 { m.touchesSearchBox.append("x-") }
        if ib.max.x == grid.nx - 1 { m.touchesSearchBox.append("x+") }
        if ib.min.z == 0 { m.touchesSearchBox.append("z-") }
        if ib.max.z == grid.nz - 1 { m.touchesSearchBox.append("z+") }
        if ib.max.y == grid.ny - 1 { m.touchesSearchBox.append("y+") }
        if let fp = VisualHull.footprint(grid: grid) {
            m.footprint = .init(lengthCm: round1(fp.lengthM * 100), widthCm: round1(fp.widthM * 100), longAxisAzimuthDeg: fp.longAxisAzimuthDeg)
        }
        let slack = VisualHull.slack(grid: grid, views: views, objectToWorld: modelToWorld)
        m.perViewSlack = slack.map { .init(id: $0.id, slackPx: round1($0.slackPx), slackM: round6($0.slackM)) }
        let median = slack.map(\.slackM).sorted().middle
        m.uncertainty = .init(
            plusMinusCm: round1((s + (median ?? 0)) * 100), voxelCm: round1(s * 100),
            reprojectionSlackCm: median.map { round1($0 * 100) },
            heightOverestimateUpToCm: VisualHull.flatTopBias(grid: grid, cameraPositions: cameras.map { $0 - SIMD3(0, tableY, 0) }).map { round1($0 * 100) },
            note: "± per dimension = voxel edge + median gap between each mask's bounding box and the hull's projection. "
                + "A visual hull is never smaller than the object along a silhouette: concave parts and the hidden underside are filled. "
                + "The top can additionally be too high by up to heightOverestimateUpToCm (flat-top worst case), since no photo looks at the top from the side.")

        var low: [String] = []
        if views.count < 12 { low.append("only \(views.count) silhouettes (12 or more recommended)") }
        if let med = median, med > 0.005 { low.append(String(format: "silhouettes disagree by %.1f cm (median), pose drift or wrong masks", med * 100)) }
        let unchecked = views.filter { v in session.photo(id: v.id).map { MaskUse.of($0) == .unchecked } ?? false }.count
        if unchecked > 0 { low.append("\(unchecked) of \(views.count) masks never checked") }
        m.uncheckedMaskViews = unchecked
        m.confidence = low.isEmpty ? "normal" : "low"
        m.confidenceReasons = low
        if !low.isEmpty {
            let worst = slack.map(\.slackM).max() ?? 0
            m.caveats.append(String(format: "Low confidence: inconsistent silhouettes carve real parts away, so a size can be too small by up to about %.1f cm (twice the largest per-view gap), beyond the ±.", 2 * worst * 100))
        }

        // Mesh: exposed voxel faces, coarsened when the face count would be large.
        var meshGrid = grid
        var factor = 1
        while true {
            let faces = VisualHull.obj(grid: meshGrid, header: []).faces
            if faces <= 60_000 || factor >= 4 { break }
            factor *= 2
            meshGrid = grid.coarsened(by: factor)
        }
        let obj = VisualHull.obj(grid: meshGrid, header: [
            "memoria-pack \(PackInfo.toolVersion): visual hull of session \(session.sessionId) (reference frame \(frameId))",
            "units: metres; object frame: origin = base centre on the table, +Y up, +Z towards the front view, +X right seen from the front",
            String(format: "voxel %.1f mm; exposed voxel faces only (blocky proxy, over-estimates concave parts and the underside)", meshGrid.voxelSize * 1000),
        ])
        if (try? Data(obj.text.utf8).write(to: dir.appendingPathComponent("hull.obj"))) != nil {
            m.mesh = .init(file: "hull.obj", vertices: obj.vertices, faces: obj.faces, voxelSizeM: round6(meshGrid.voxelSize))
        }

        m.caveats += [
            "Visual hull: concave regions (dents, holes, the gap under an overhang) are filled; sizes are upper bounds along every silhouette.",
            "The underside was never photographed (the object stood on the table); the hull's bottom is the table plane y = 0 (flat).",
            table.map { String(format: "Height is measured from the table plane estimated from the hull (the hidden wedge under the object), %.1f cm %@ the capture's reference point (method: %@).", abs($0) * 100, $0 >= 0 ? "above" : "below", frame.base?.source.rawValue ?? "unknown") }
                ?? "Height is measured from the capture's reference point (method: \(frame.base?.source.rawValue ?? "unknown")).",
            "Camera poses come from ARKit tracking; drift between photos shrinks or blurs the hull by a few millimetres.",
        ]
        if views.contains(where: { v in session.photo(id: v.id).map { MaskUse.of($0) == .unchecked } ?? false }) {
            m.caveats.append("Some masks were never checked (older session); a wrong mask removes real parts of the object.")
        }
        if !m.touchesSearchBox.isEmpty {
            m.caveats.append("The hull reaches the search box (\(m.touchesSearchBox.joined(separator: ", "))): the object may extend beyond the user-fitted cylinder × \(hullSettings.boundsScale); that size is a lower bound there.")
        }
        return m
    }

    /// Heading-guided session: no cylinder and no reference point were set during capture. The centre (closest point to the
    /// photos' centre lines), the object frame and an approximate size were derived after capture (on the iPhone, or here
    /// when the session has none yet). No visual hull: an `ai5` session has 5 photos.
    func measureHeading(referenceFrameId: String?) -> Measurements {
        var m = Measurements(sessionId: session.sessionId, status: "unavailable")
        m.method = "headingDerived"
        m.referenceFrameId = referenceFrameId
        guard let frameId = referenceFrameId, let frame = session.referenceFrame(id: frameId), let heading = frame.heading else {
            m.unavailableReason = "no reference frame with confirmed photos"
            return m
        }
        m.baseSource = frame.base?.source.rawValue
        guard let derivation = heading.derivation else {
            m.unavailableReason = "the object centre was not derived (no front photo)"
            return m
        }
        m.heading = Measurements.HeadingInfo(derivation: derivation, computedBy: headingComputedHere ? PackInfo.toolName : "iPhone")
        guard let center = derivation.centerWorld?.simd else {
            m.unavailableReason = "the object centre could not be derived (\(derivation.reasons.map(\.rawValue).joined(separator: ", ")))"
            return m
        }
        let baseKnown = derivation.origin == .base
        let originY = frame.basePointWorld?.simd.y ?? center.y
        m.frame["origin"] = baseKnown
            ? "x, z: the object centre derived after capture (closest point to the photos' centre lines); y = 0: the supporting surface (table) measured by ARKit (\(frame.base?.source.rawValue ?? "?"))"
            : "x, z: the object centre derived after capture (closest point to the photos' centre lines); y = 0: the height of that centre (the table height is unknown; it is NOT the bottom of the object)"
        m.frame["z"] = "towards the front camera: opposite the front photo's horizontal viewing direction (views/front.jpg looks along -Z)"
        guard let size = derivation.size else {
            m.unavailableReason = "the approximate size was not computed (masks still pending when the session was sent)"
            return m
        }
        // No hull: viewsUsed stays 0; the masks used for the size are heading.size.photoIds.
        m.usableSilhouettes = size.photoIds.count
        guard size.isKnown, let w = size.widthM, let d = size.depthM, let h = size.heightM else {
            m.unavailableReason = "the approximate size is unknown (\(size.reasons.map(\.rawValue).joined(separator: ", ")))"
            return m
        }
        m.status = "approximate"
        m.sizeM = Size3(width: round6(w), depth: round6(d), height: round6(h))
        m.sizeCm = Size3(width: round1(w * 100), depth: round1(d * 100), height: round1(h * 100))
        if let lo = size.boxMinM?.simd, let hi = size.boxMaxM?.simd {
            let dy = center.y - originY
            m.bboxMinM = [round6(lo.x), round6(lo.y + dy), round6(lo.z)]
            m.bboxMaxM = [round6(hi.x), round6(hi.y + dy), round6(hi.z)]
        }
        m.confidence = size.confidence
        m.confidenceReasons = size.reasons.map(Self.headingSizeReasonText)
        if derivation.status != .ok {
            m.confidenceReasons.append("object centre: \(derivation.status.rawValue) (\(derivation.reasons.map(\.rawValue).joined(separator: ", ")))")
        }
        m.caveats = [
            "Approximate size derived after capture from the iPhone masks' bounding boxes and the camera poses. Nothing was fitted or measured during capture (no cylinder, no reference point).",
            "Two readings bracket the size: lowerM (an axis-aligned box fitted to every mask's bounding box: right for box-like objects, too small for rounded ones) "
                + "and upperM (each mask's extent on the plane through the centre: close for rounded objects, too large for box-like ones). sizeM is their geometric mean.",
            "Where lowerM and upperM differ a lot (reason shapeDependent), the dimension depends on the object's shape: look at the photos. Height is the most affected (the photos look down at about 15°).",
            String(format: "Object centre: closest point to %d photos' centre lines; the lines miss it by %.1f cm (RMS), %.1f cm at most. Larger misses mean the object was not on the crosshair or the poses drifted.",
                   derivation.photoIds.count, (derivation.residualRmsM ?? 0) * 100, (derivation.residualMaxM ?? 0) * 100),
            baseKnown ? "y = 0 is the table under the object (ARKit \(frame.base?.source.rawValue ?? "?")); the size box (bboxMinM/bboxMaxM) is placed from the masks and need not touch it exactly."
                : "The table height is unknown: y = 0 is the derived centre's height, not the bottom. The size box (bboxMinM/bboxMaxM) gives the approximate bottom (its y minimum).",
            "No visual hull and no hull.obj (5 photos are too few for a carve).",
        ]
        return m
    }

    static func headingSizeReasonText(_ r: HeadingSizeReason) -> String {
        switch r {
        case .noCenter: return "the object centre is unknown"
        case .notEnoughMasks: return "not enough usable masks"
        case .maskTouchesImageEdge: return "a mask touches the photo's edge (the object may extend beyond the photo)"
        case .poorFit: return "the box does not fit the masks well (wrong mask, object not on the crosshair, or pose drift)"
        case .oppositeViewsDisagree: return "opposite views (front/back or right/left) disagree on the size"
        case .centerLowConfidence: return "the object centre was derived with low confidence"
        case .shapeDependent: return "lower and upper readings differ a lot: the size depends on the object's shape"
        case .fitFailed: return "the box fit failed"
        }
    }

    /// Too few silhouettes for a hull: report the cylinder the user fitted during capture, clearly labelled as such.
    static func useCylinder(_ m: inout Measurements, size: ObjectSize, silhouettes: Int) {
        let d = 2 * size.radiusM, h = size.heightM
        m.status = "approximate"
        m.method = "userCylinder"
        m.sizeM = Size3(width: round6(d), depth: round6(d), height: round6(h))
        m.sizeCm = Size3(width: round1(d * 100), depth: round1(d * 100), height: round1(h * 100))
        m.confidence = "low"
        m.confidenceReasons = ["only \(silhouettes) silhouettes with a usable mask (a visual hull needs \(minimumHullViews) or more); "
            + "the size is the user-adjusted capture cylinder, not a measurement"]
        m.frame["origin"] = "x, z: the capture's reference point (base centre); y = 0: the capture's reference point (no table estimate without a hull)"
        m.caveats = [
            "Size = the cylinder the user fitted around the object with the AR guide during capture (diameter × diameter × height). "
                + "It is an eyeballed enclosing guide, not a measurement: the object is usually somewhat smaller, its footprint need not be round, "
                + "and width/depth are both the diameter.",
            "No visual hull and no hull.obj: \(silhouettes) silhouettes are too few for a reliable carve (\(minimumHullViews) or more needed).",
            "Height is from the capture's reference point (the measured base), not from an estimated table plane.",
        ]
    }

    func footerLines(_ m: Measurements) -> [String] {
        let title = session.title.isEmpty ? "(untitled)" : session.title
        var lines = ["\(title) · session \(session.sessionId.prefix(8)) · tiles placed where the camera stood, seen from above (front at the bottom)"]
        if m.method == "headingDerived" {
            if let s = m.sizeCm {
                lines.append(String(format: "Approximate size (derived after capture from masks, %@ confidence): W %.1f × D %.1f × H %.1f cm · X right, Y up, Z front", m.confidence ?? "?", s.width, s.depth, s.height))
            } else {
                lines.append("Size unavailable: \(m.unavailableReason ?? "unknown")")
            }
            if let h = m.heading {
                lines.append(String(format: "Heading-guided capture: object centre from %d photos' centre lines (miss %.1f cm RMS) · table height %@", h.photoIds.count, (h.residualRmsM ?? 0) * 100, h.origin == "base" ? "measured" : "unknown"))
            }
            return lines
        }
        if m.method == "userCylinder", let s = m.sizeCm {
            lines.append(String(format: "Approximate size (user-fitted capture cylinder, NOT measured): diameter %.1f cm × height %.1f cm", s.width, s.height))
            lines.append("Only \(m.usableSilhouettes) silhouettes (a hull needs \(Self.minimumHullViews)+): no visual hull; the object is usually smaller than this cylinder")
        } else if let s = m.sizeCm {
            lines.append(String(format: "Measured (visual hull, %d views): W %.1f × D %.1f × H %.1f cm (±%.1f cm) · X right, Y up, Z front", m.viewsUsed,
                                s.width, s.depth, s.height, m.uncertainty?.plusMinusCm ?? 0))
            if let f = m.footprint {
                lines.append(String(format: "Footprint from above: %.1f × %.1f cm, long side at azimuth %.0f° · underside not captured · upper bound (hull fills concavities)",
                                    f.lengthCm, f.widthCm, f.longAxisAzimuthDeg))
            }
        } else {
            lines.append("Size unavailable: \(m.unavailableReason ?? "unknown")")
        }
        return lines
    }

    // MARK: Coverage and masks

    func coverageInfo(referenceFrameId: String?, choices: [ViewChoice]) -> PackIndex.Coverage {
        let inFrame = session.photos.filter { $0.referenceFrameId == referenceFrameId && $0.direction.confirmed && referenceFrameId != nil }
        let els = inFrame.compactMap(\.direction.elevationDeg)
        let progress = Coverage.progress(in: session, referenceFrameId: referenceFrameId)
        let bands = session.directionPlan.bands.map { band -> PackIndex.Band in
            let states = band.targets.map { progress.state(of: $0.id) }
            return PackIndex.Band(elevationDeg: band.elevationDeg, targets: states.count,
                                  shot: states.filter { $0 != .notShot }.count, done: states.filter { $0 == .done }.count)
        }
        return PackIndex.Coverage(
            referenceFrameId: referenceFrameId, referenceFrameIds: session.referenceFrames.map(\.id),
            photoCount: session.photos.count, photosInReferenceFrame: inFrame.count,
            minElevationDeg: els.min().map(round1), maxElevationDeg: els.max().map(round1),
            directionPlanId: session.directionPlan.id, bands: bands,
            missingViews: choices.filter(\.isMissing).map(\.name),
            weakViews: choices.filter { !$0.isMissing && !$0.notes.isEmpty }.map(\.name))
    }

    func maskIssueList() -> [PackIndex.MaskIssue] {
        session.photos.sorted { $0.sequence < $1.sequence }.compactMap { p in
            guard MaskUse.of(p, fileExists: maskExists(p)) != .good else { return nil }
            return PackIndex.MaskIssue(sequence: p.sequence, photoId: p.photoId, targetId: p.direction.targetId,
                                       referenceFrameId: p.referenceFrameId, status: p.mask.status.rawValue,
                                       check: p.mask.check?.status.rawValue,
                                       reasons: (p.mask.check?.reasons.map(\.rawValue) ?? []) + (p.mask.error.map { [$0] } ?? []))
        }
    }
}

func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
func round6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

extension SIMD3 where Scalar == Double {
    var rounded6: [Double] { [round6(x), round6(y), round6(z)] }
}

extension Array where Element == Double {
    var middle: Double? {
        guard !isEmpty else { return nil }
        let s = sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
