import Foundation
import RealityKit
import CaptureCore
import simd

public enum Runner {
    public static func run(arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try CommandLineParser.parse(arguments)
        } catch let error as UsageError {
            if error.description.isEmpty { print(CommandLineParser.usage); return 0 }
            eprint("error: \(error.description)\n\n\(CommandLineParser.usage)")
            return 2
        } catch {
            eprint("error: \(error)")
            return 2
        }

        let located: LocatedSession
        let outDir: URL
        do {
            let dataDir = SessionLocator.dataDir(option: options.dataDir)
            located = try SessionLocator.locate(options.session, dataDir: dataDir)
            outDir = try SessionLocator.outputDir(option: options.out, located: located, detail: options.detail)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch let error as UsageError {
            eprint("error: \(error.description)")
            return 2
        } catch {
            eprint("error: \(error)")
            return 1
        }
        let job = Job(options: options, located: located, outDir: outDir, arguments: arguments)
        return await job.run()
    }
}

func eprint(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

private final class Job {
    let options: Options
    let located: LocatedSession
    let outDir: URL
    let modelURL: URL
    var report: Report
    let plan: [PlannedInput]
    let log = SampleLog()
    let progress = ProgressLine()
    let started = Date()
    var sessionCreated = Date()
    var invalid: [Int: String] = [:]
    var skipped: Set<Int> = []
    var requestStarted: [String: Date] = [:]
    var lastStage: [String: (stage: String, index: Int)] = [:]
    var modelDone = false
    var cancelled = false
    var signalSources: [DispatchSourceSignal] = []

    init(options: Options, located: LocatedSession, outDir: URL, arguments: [String]) {
        self.options = options
        self.located = located
        self.outDir = outDir
        modelURL = outDir.appendingPathComponent("model.usdz")
        plan = InputPlanner.plan(session: located.session, folder: located.folder, options: options)
        let s = located.session
        report = Report(
            tool: .init(command: ["memoria-reconstruct"] + arguments),
            startedAt: ISODate.string(started, timeZone: TimeZone(identifier: "UTC")!),
            session: .init(sessionId: s.sessionId, title: s.title, folder: located.folder.path,
                           manifestHash: located.receipt?.manifestHash, receivedAt: located.receipt?.receivedAt,
                           photoCount: s.photos.count, directionPlanId: s.directionPlan.id,
                           referenceFrameIds: s.referenceFrames.map(\.id)),
            options: options,
            environment: .init(osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                               photogrammetryIsSupported: PhotogrammetrySession.isSupported,
                               maximumInputImageDimension: PhotogrammetrySession.limits.maximumInputImageDimension,
                               maximumNumberOfInputImages: PhotogrammetrySession.limits.maximumNumberOfInputImages)
        )
        report.notes = [
            "Camera poses and intrinsics from session.json are NOT passed: PhotogrammetrySample.camera (intrinsics, transform) is get-only and only filled by init(contentsOf:) for ObjectCaptureSession HEIC files; PhotogrammetrySession estimates poses itself.",
            "Images are the stored sensor-orientation JPEGs (32BGRA), masks are the session PNGs (OneComponent8, 255 = object, same size).",
            "metadata = the JPEG's own ImageIO properties plus {Exif}.FocalLenIn35mmFilm derived from the intrinsics.",
            options.gravity == .off
                ? "Gravity not passed (--gravity off): the RealityKit doc for PhotogrammetrySample.gravity does not state its frame or sign."
                : "Gravity passed in the '\(options.gravity.rawValue)' convention (experimental; see README).",
            "Photos from different referenceFrames are pooled; PhotogrammetrySession does not use ARKit world coordinates.",
        ]
    }

    func run() async -> Int32 {
        let s = located.session
        print("session  \(s.sessionId)  \"\(s.title)\"  (\(s.photos.count) photos, plan \(s.directionPlan.id), reference frames \(s.referenceFrames.map(\.id).joined(separator: ", ")))")
        print("folder   \(located.folder.path)")
        print("output   \(outDir.path)")
        print("options  frames=\(options.frames?.joined(separator: ",") ?? "all") detail=\(options.detail.rawValue) masks=\(options.masks.rawValue) include=\(options.include.rawValue) ordering=\(options.ordering.rawValue) sensitivity=\(options.sensitivity.rawValue) gravity=\(options.gravity.rawValue) session-masking=\(options.sessionMasking.rawValue)")
        print("")
        for p in plan {
            let head = String(format: "#%-3d %@  %@  %@", p.sequence, String(p.photoId.prefix(8)),
                              (p.referenceFrameId ?? "no-ref").padding(toLength: 6, withPad: " ", startingAt: 0),
                              (p.targetId ?? (p.directionConfirmed ? "no-target" : "unconfirmed")).padding(toLength: 11, withPad: " ", startingAt: 0))
            if p.included {
                print("\(head)  use   mask \(p.maskUsed ? "yes" : "no ") (\(p.maskReason))")
            } else {
                print("\(head)  EXCLUDED: \(p.exclusionReason ?? "?")")
            }
        }
        let included = plan.filter(\.included)
        report.counts.photos = s.photos.count
        report.counts.planned = included.count
        report.counts.excluded = plan.count - included.count
        report.counts.plannedWithMask = included.filter(\.maskUsed).count
        print("\n\(included.count) of \(plan.count) photos planned, \(report.counts.plannedWithMask) with a mask, \(report.counts.excluded) excluded")
        let frames = Set(included.map { $0.referenceFrameId ?? "none" })
        if frames.count > 1 {
            let warning = "photos come from \(frames.count) reference frames (\(frames.sorted().joined(separator: ", "))). If the object or its surroundings were moved between them, reconstruct one frame at a time with --frames."
            print("warning: \(warning)")
            report.notes.append(warning)
        }

        guard PhotogrammetrySession.isSupported else {
            return finish(error: "PhotogrammetrySession is not supported on this Mac")
        }
        guard !included.isEmpty else { return finish(error: "no photos left to reconstruct") }

        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering = options.ordering == .sequential ? .sequential : .unordered
        config.featureSensitivity = options.sensitivity == .high ? .high : .normal
        config.isObjectMaskingEnabled = options.sessionMasking.isOn
        report.configuration = [
            "sampleOrdering": options.ordering.rawValue,
            "featureSensitivity": options.sensitivity.rawValue,
            "isObjectMaskingEnabled": "\(config.isObjectMaskingEnabled)",
            "requests": (options.poses.isOn ? "poses, " : "") + "modelFile(detail: \(options.detail.rawValue))",
        ]

        let session: PhotogrammetrySession
        do {
            let t0 = Date()
            session = try PhotogrammetrySession(
                input: SampleFactory.samples(for: plan, folder: located.folder, log: log), configuration: config)
            sessionCreated = Date()
            report.durations.sessionCreateS = round3(sessionCreated.timeIntervalSince(t0))
        } catch {
            return finish(error: "PhotogrammetrySession init failed: \(describe(error))")
        }
        installSignalHandlers(session)

        var requests: [PhotogrammetrySession.Request] = []
        if options.poses.isOn { requests.append(.poses) }
        requests.append(.modelFile(url: modelURL, detail: detail(options.detail)))
        do {
            try session.process(requests: requests)
        } catch {
            return finish(error: "process(requests:) failed: \(describe(error))")
        }
        let processStart = Date()

        do {
            outputLoop: for try await output in session.outputs {
                switch output {
                case .inputComplete:
                    progress.clear()
                    let loaded = log.all
                    let failed = loaded.filter { $0.error != nil }
                    let maskErrors = loaded.filter { $0.maskError != nil }
                    print("input complete: \(loaded.count - failed.count) samples built (\(loaded.filter { $0.maskCoverage != nil }.count) with mask), \(failed.count) failed to build")
                    for f in failed { print("  sample \(f.sampleId) not provided: \(f.error!)") }
                    for f in maskErrors { print("  sample \(f.sampleId) mask dropped: \(f.maskError!)") }
                    message("inputComplete")
                case let .requestProgress(request, fraction):
                    let name = requestName(request)
                    if requestStarted[name] == nil { requestStarted[name] = Date() }
                    progress.update(request: name, fraction: fraction)
                case let .requestProgressInfo(request, info):
                    let name = requestName(request)
                    if requestStarted[name] == nil { requestStarted[name] = Date() }
                    // processingStage is sometimes nil; keep showing the previous stage then.
                    let stage = info.processingStage.map(stageName)
                    if let stage { stageChanged(request: name, stage: stage) }
                    progress.update(request: name, stage: stage, eta: info.estimatedRemainingTime)
                case let .requestComplete(request, result):
                    let name = requestName(request)
                    if let start = requestStarted[name] { report.durations.requests[name] = round3(Date().timeIntervalSince(start)) }
                    closeStage(request: name)
                    progress.complete(request: name)
                    switch result {
                    case let .modelFile(url):
                        modelDone = true
                        progress.clear()
                        print("model written: \(url.path)")
                        message("requestComplete", request: name, detail: url.path)
                    case let .poses(poses):
                        recordPoses(poses)
                        progress.clear()
                        print("poses: \(poses.posesBySample.count) of \(log.all.filter { $0.error == nil }.count) samples posed")
                        message("requestComplete", request: name, detail: "\(poses.posesBySample.count) poses")
                    default:
                        message("requestComplete", request: name, detail: "\(result)")
                    }
                case let .requestError(request, error):
                    let name = requestName(request)
                    closeStage(request: name)
                    progress.clear()
                    let text = describe(error)
                    print("request error [\(name)]: \(text)")
                    report.errors.append("\(name): \(text)")
                    message("requestError", request: name, detail: text)
                case let .invalidSample(id, reason):
                    invalid[id] = reason
                    progress.clear()
                    print("invalid sample \(id) (\(photoLabel(id))): \(reason)")
                    message("invalidSample", sampleId: id, detail: reason)
                case let .skippedSample(id):
                    skipped.insert(id)
                    progress.clear()
                    print("skipped sample \(id) (\(photoLabel(id)))")
                    message("skippedSample", sampleId: id)
                case .automaticDownsampling:
                    progress.clear()
                    print("automatic downsampling: the session reduced image size because of memory constraints")
                    message("automaticDownsampling")
                case .stitchingIncomplete:
                    progress.clear()
                    print("stitching incomplete: not all images could be stitched; parts of the model may be missing")
                    message("stitchingIncomplete")
                case .processingComplete:
                    progress.clear()
                    print("processing complete")
                    message("processingComplete")
                    break outputLoop
                case .processingCancelled:
                    progress.clear()
                    print("processing cancelled")
                    cancelled = true
                    message("processingCancelled")
                    break outputLoop
                @unknown default:
                    message("unknown", detail: "\(output)")
                }
            }
        } catch {
            progress.clear()
            report.errors.append("outputs: \(describe(error))")
        }
        report.durations.processingS = round3(Date().timeIntervalSince(processStart))
        for src in signalSources { src.cancel() }

        if cancelled { return finish(status: "cancelled", code: 130) }
        if !modelDone {
            if report.stages.last?.stage == "imageAlignment" || report.stages.isEmpty {
                let hint = "image alignment failed: the photos could not be registered to each other. Try one reference frame at a time (--frames), --masks off (masks remove the background features a plain object needs), --sensitivity high, and capture more overlapping photos."
                print("hint: \(hint)")
                report.notes.append(hint)
            }
            return finish(error: report.errors.isEmpty ? "no model was produced" : nil)
        }
        return finish(status: "completed", code: 0)
    }

    // MARK: - Outputs

    func message(_ type: String, request: String? = nil, sampleId: Int? = nil, detail: String? = nil) {
        report.messages.append(.init(t: round3(Date().timeIntervalSince(sessionCreated)), type: type,
                                     request: request, sampleId: sampleId, detail: detail))
    }

    func stageChanged(request: String, stage: String) {
        if let last = lastStage[request], last.stage == stage { return }
        closeStage(request: request)
        report.stages.append(.init(request: request, stage: stage, startS: round3(Date().timeIntervalSince(sessionCreated)), durationS: nil))
        lastStage[request] = (stage, report.stages.count - 1)
    }

    func closeStage(request: String) {
        guard let last = lastStage[request] else { return }
        let now = round3(Date().timeIntervalSince(sessionCreated))
        report.stages[last.index].durationS = round3(now - report.stages[last.index].startS)
        lastStage[request] = nil
    }

    func recordPoses(_ poses: PhotogrammetrySession.Poses) {
        var entries: [Report.PoseEntry] = []
        var centres: [(String, SIMD3<Double>, SIMD3<Double>)] = []
        for (id, pose) in poses.posesBySample.sorted(by: { $0.key < $1.key }) {
            guard let input = plan.first(where: { $0.sampleId == id }),
                  let photo = located.session.photo(id: input.photoId) else { continue }
            let k = photo.camera.intrinsics.simd
            var fx: Double?, fy: Double?
            if #available(macOS 26.0, *), let m = pose.intrinsics {
                fx = Double(m[0][0]); fy = Double(m[1][1])
            }
            let t = pose.translation, q = pose.rotation.vector
            entries.append(.init(sampleId: id, photoId: input.photoId,
                                 translation: [t.x, t.y, t.z].map { round5(Double($0)) },
                                 rotationQuaternion: [q.x, q.y, q.z, q.w].map { round5(Double($0)) },
                                 estimatedFx: fx.map(round3), estimatedFy: fy.map(round3),
                                 arkitFx: round3(k[0][0]), arkitFy: round3(k[1][1])))
            if let frame = photo.referenceFrameId {
                centres.append((frame, photo.camera.cameraToWorld.simd.translation, SIMD3<Double>(t)))
            }
        }
        let provided = Set(log.all.filter { $0.error == nil }.map(\.sampleId))
        report.poses = .init(count: poses.posesBySample.count,
                             notPosedSampleIds: provided.subtracting(poses.posesBySample.keys).sorted(),
                             entries: entries, scaleCheck: ScaleCheck.compute(centres))
        report.counts.posesEstimated = poses.posesBySample.count
    }

    // MARK: - Finish

    @discardableResult
    func finish(status: String = "failed", code: Int32 = 1, error: String? = nil) -> Int32 {
        progress.clear()
        if let error {
            report.errors.append(error)
            eprint("error: \(error)")
        }
        report.status = status
        let finished = Date()
        report.finishedAt = ISODate.string(finished, timeZone: TimeZone(identifier: "UTC")!)
        report.durations.totalS = round3(finished.timeIntervalSince(started))

        let loads = Dictionary(uniqueKeysWithValues: log.all.map { ($0.sampleId, $0) })
        let posed = report.poses.map { Set($0.entries.map(\.sampleId)) }
        report.inputs = plan.map { p in
            let load = loads[p.sampleId]
            var outcome = "notProvided"
            if let load, load.error == nil {
                if let reason = invalid[p.sampleId] { outcome = "invalid: \(reason)" }
                else if skipped.contains(p.sampleId) { outcome = "skipped" }
                else if let posed { outcome = posed.contains(p.sampleId) ? "used" : "unposed" }
                else { outcome = modelDone ? "used" : "unknown" }
            }
            return .init(plan: p, load: load, sessionOutcome: outcome)
        }
        report.counts.samplesProvided = loads.values.filter { $0.error == nil }.count
        report.counts.samplesWithMask = loads.values.filter { $0.error == nil && $0.maskCoverage != nil }.count
        report.counts.invalidSamples = invalid.count
        report.counts.skippedSamples = skipped.count

        if FileManager.default.fileExists(atPath: modelURL.path) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int) ?? 0
            report.model = .init(file: "model.usdz", bytes: bytes, mesh: MeshStats.read(modelURL))
        }

        do {
            try report.write(to: outDir.appendingPathComponent("report.json"))
            try readme().write(to: outDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        } catch {
            eprint("error: cannot write report: \(error)")
        }

        print("")
        print("status   \(status) in \(formatDuration(report.durations.totalS)) (processing \(formatDuration(report.durations.processingS)))")
        print("samples  \(report.counts.samplesProvided) provided (\(report.counts.samplesWithMask) with mask), \(invalid.count) invalid, \(skipped.count) skipped" + (report.counts.posesEstimated.map { ", \($0) posed" } ?? ""))
        if let checks = report.poses?.scaleCheck {
            for c in checks where c.medianScale != nil {
                print("poses    \(c.referenceFrameId): \(c.posedSamples) posed, ARKit metres per model unit \(c.medianScale!), spread \(c.relativeSpread!)")
            }
        }
        if let model = report.model {
            var line = "model    \(modelURL.path) (\(ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .file)))"
            if let m = model.mesh {
                line += ", \(m.vertexCount) vertices, \(m.triangleCount) triangles, extent \(m.extent.map { String(format: "%.4f", $0) }.joined(separator: " × "))"
            }
            print(line)
            print("         open with: qlmanage -p \"\(modelURL.path)\"")
        }
        print("report   \(outDir.appendingPathComponent("report.json").path)")
        for e in report.errors { print("error    \(e)") }
        return code
    }

    func readme() -> String {
        let s = located.session
        var lines = [
            "# 3D モデルの作成結果",
            "",
            "`memoria-reconstruct`（tools/reconstruct）が、Apple の RealityKit `PhotogrammetrySession` で Mac の中だけで作ったモデルです（クラウドは使いません）。",
            "",
            "- セッション: `\(s.sessionId)`「\(s.title)」（manifestHash `\(located.receipt?.manifestHash ?? "なし")`）",
            "- 結果: **\(report.status)**、写真 \(report.counts.photos) 枚のうち \(report.counts.samplesProvided) 枚を使用（マスクあり \(report.counts.samplesWithMask) 枚）",
            "- 設定: detail \(options.detail.rawValue)、masks \(options.masks.rawValue)、include \(options.include.rawValue)、ordering \(options.ordering.rawValue)、sensitivity \(options.sensitivity.rawValue)、gravity \(options.gravity.rawValue)",
            "- 時間: \(formatDuration(report.durations.totalS))",
            "",
            "| ファイル | 中身 |",
            "|---|---|",
        ]
        if report.model != nil {
            lines.append("| `model.usdz` | 3D モデル。Finder のクイックルック、または `qlmanage -p model.usdz` で見られます |")
        }
        lines.append("| `report.json` | 写真ごとの使い方（除いた理由・マスクの有無）、設定、時間、PhotogrammetrySession のメッセージとエラー、推定したカメラ位置と ARKit の比較 |")
        lines.append("")
        lines.append("元のセッション（`sessions/`）には何も書き込んでいません。")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    func installSignalHandlers(_ session: PhotogrammetrySession) {
        var count = 0
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                count += 1
                if count == 1 {
                    self?.progress.clear()
                    print("\ncancelling… (press Ctrl-C again to quit immediately)")
                    session.cancel()
                } else {
                    exit(130)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func photoLabel(_ sampleId: Int) -> String {
        guard let p = plan.first(where: { $0.sampleId == sampleId }) else { return "?" }
        return "#\(p.sequence) \(p.photoId.prefix(8))"
    }

    func requestName(_ request: PhotogrammetrySession.Request) -> String {
        switch request {
        case .modelFile: return "modelFile"
        case .modelEntity: return "modelEntity"
        case .bounds: return "bounds"
        case .pointCloud: return "pointCloud"
        case .poses: return "poses"
        @unknown default: return "\(request)"
        }
    }

    func stageName(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch stage {
        case .preProcessing: return "preProcessing"
        case .imageAlignment: return "imageAlignment"
        case .pointCloudGeneration: return "pointCloudGeneration"
        case .meshGeneration: return "meshGeneration"
        case .textureMapping: return "textureMapping"
        case .optimization: return "optimization"
        @unknown default: return "\(stage)"
        }
    }

    func detail(_ d: DetailOption) -> PhotogrammetrySession.Request.Detail {
        switch d {
        case .preview: return .preview
        case .reduced: return .reduced
        case .medium: return .medium
        case .full: return .full
        case .raw: return .raw
        }
    }

    func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(error)"
        if !text.contains(ns.localizedDescription) { text += " — \(ns.localizedDescription)" }
        if ns.domain != "" && !text.contains(ns.domain) { text += " [\(ns.domain) \(ns.code)]" }
        return text
    }
}

/// One status line, redrawn in place on a terminal (plain lines otherwise).
final class ProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private let tty = isatty(1) != 0
    private var state: [String: (fraction: Double, stage: String?, eta: Double?)] = [:]
    private var order: [String] = []
    private var shown = false
    private var lastPlain: [String: Int] = [:]

    func update(request: String, fraction: Double? = nil, stage: String? = nil, eta: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if state[request] == nil { order.append(request); state[request] = (0, nil, nil) }
        var s = state[request]!
        let stageChanged = stage != nil && stage != s.stage
        if let fraction { s.fraction = fraction }
        if let stage { s.stage = stage }
        if let eta { s.eta = eta }
        state[request] = s
        if tty {
            draw()
        } else {
            let bucket = Int(s.fraction * 10)
            if stageChanged || bucket != lastPlain[request] {
                lastPlain[request] = bucket
                print(line(request, s))
            }
        }
    }

    func complete(request: String) {
        update(request: request, fraction: 1.0)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        if tty && shown {
            FileHandle.standardOutput.write("\r\u{1B}[2K".data(using: .utf8)!)
            shown = false
        }
    }

    private func line(_ name: String, _ s: (fraction: Double, stage: String?, eta: Double?)) -> String {
        var text = String(format: "%@ %5.1f%%", name, s.fraction * 100)
        if let stage = s.stage { text += " [\(stage)]" }
        if let eta = s.eta, eta.isFinite, eta > 0, s.fraction < 1 { text += " eta \(formatDuration(eta))" }
        return text
    }

    private func draw() {
        let text = order.map { line($0, state[$0]!) }.joined(separator: "  |  ")
        fflush(stdout)
        FileHandle.standardOutput.write(("\r\u{1B}[2K" + text).data(using: .utf8)!)
        shown = true
    }
}

func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
func round5(_ v: Double) -> Double { (v * 1e5).rounded() / 1e5 }

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : String(format: "%.1fs", seconds)
}
