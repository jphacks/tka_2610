import Foundation
import CaptureCore

/// A received, complete session folder (`<data-dir>/sessions/<sessionId>/`).
public struct LocatedSession {
    public var folder: URL
    public var dataDir: URL
    public var session: CaptureSession
    public var receipt: Receipt?
}

/// `_receipt.json` written by the receiver (only the fields the report needs).
public struct Receipt: Decodable {
    public var complete: Bool?
    public var sessionId: String?
    public var manifestHash: String?
    public var receivedAt: String?
}

public enum SessionLocator {
    /// `--data-dir` as given (relative to the current directory), else the nearest `captures/` with a
    /// `sessions/` folder above the current directory, else `<repo>/captures` derived from this source file.
    public static func dataDir(option: String?, sourceFile: String = #filePath) -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let option {
            return URL(fileURLWithPath: option, isDirectory: true, relativeTo: cwd).standardizedFileURL
        }
        var dir = cwd.standardizedFileURL
        while true {
            let candidate = dir.appendingPathComponent("captures", isDirectory: true)
            if isDirectory(candidate.appendingPathComponent("sessions")) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // <repo>/tools/reconstruct/Sources/ReconstructKit/SessionLocator.swift → <repo>/captures
        var repo = URL(fileURLWithPath: sourceFile)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return repo.appendingPathComponent("captures", isDirectory: true).standardizedFileURL
    }

    public static func locate(_ argument: String, dataDir: URL) throws -> LocatedSession {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let sessionsDir = dataDir.appendingPathComponent("sessions", isDirectory: true)
        var folder: URL?

        let asPath = URL(fileURLWithPath: argument, isDirectory: true, relativeTo: cwd).standardizedFileURL
        if argument.contains("/") || isDirectory(asPath) && fm.fileExists(atPath: asPath.appendingPathComponent("session.json").path) {
            guard fm.fileExists(atPath: asPath.appendingPathComponent("session.json").path) else {
                throw UsageError("no session.json in \(asPath.path)")
            }
            folder = asPath
        } else {
            guard isDirectory(sessionsDir) else { throw UsageError("no sessions folder at \(sessionsDir.path) (use --data-dir)") }
            let names = (try? fm.contentsOfDirectory(atPath: sessionsDir.path)) ?? []
            let wanted = argument.uppercased()
            let matches = names.filter { $0.uppercased() == wanted } + names.filter { $0.uppercased().hasPrefix(wanted) && $0.uppercased() != wanted }
            if let exact = names.first(where: { $0.uppercased() == wanted }) {
                folder = sessionsDir.appendingPathComponent(exact, isDirectory: true)
            } else if matches.count == 1 {
                folder = sessionsDir.appendingPathComponent(matches[0], isDirectory: true)
            } else if matches.isEmpty {
                throw UsageError("no session matching \"\(argument)\" in \(sessionsDir.path)")
            } else {
                throw UsageError("\"\(argument)\" matches several sessions: \(matches.sorted().joined(separator: ", "))")
            }
        }
        guard let folder else { throw UsageError("session not found") }
        let resolved = folder.resolvingSymlinksInPath()
        if resolved.pathComponents.contains("incoming") {
            throw UsageError("refusing to read \(resolved.path): incoming/ holds incomplete transfers; use sessions/")
        }

        let data = try Data(contentsOf: folder.appendingPathComponent("session.json"))
        let session = try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data)
        guard session.schema == SessionSchema.name, session.schemaVersion == SessionSchema.version else {
            throw UsageError("unsupported session.json: \(session.schema) v\(session.schemaVersion)")
        }
        var receipt: Receipt?
        if let r = try? Data(contentsOf: folder.appendingPathComponent("_receipt.json")) {
            receipt = try? JSONDecoder().decode(Receipt.self, from: r)
        }
        return LocatedSession(folder: folder, dataDir: dataDir, session: session, receipt: receipt)
    }

    /// `<data-dir>/reconstructions/<sessionId>/<UTC>-<detail>/`, or `--out`. Never inside `sessions/` or the session folder.
    public static func outputDir(option: String?, located: LocatedSession, detail: DetailOption, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        var dir: URL
        if let option {
            dir = URL(fileURLWithPath: option, isDirectory: true, relativeTo: cwd).standardizedFileURL
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            let base = located.dataDir
                .appendingPathComponent("reconstructions", isDirectory: true)
                .appendingPathComponent(located.session.sessionId, isDirectory: true)
            let name = "\(formatter.string(from: now))-\(detail.rawValue)"
            dir = base.appendingPathComponent(name, isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: dir.path) {
                dir = base.appendingPathComponent("\(name)-\(n)", isDirectory: true)
                n += 1
            }
        }
        let forbidden = [
            located.dataDir.appendingPathComponent("sessions", isDirectory: true),
            located.dataDir.appendingPathComponent("incoming", isDirectory: true),
            located.folder,
        ].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let target = resolvedPrefix(dir).path
        for f in forbidden where target == f || target.hasPrefix(f + "/") {
            throw UsageError("refusing to write into \(f) (output must not go into sessions/ or incoming/)")
        }
        return dir
    }

    /// Resolves symlinks of the longest existing ancestor so the forbidden-folder check is reliable.
    private static func resolvedPrefix(_ url: URL) -> URL {
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            tail.insert(existing.lastPathComponent, at: 0)
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            existing = parent
        }
        var result = existing.resolvingSymlinksInPath()
        for t in tail { result.appendPathComponent(t) }
        return result.standardizedFileURL
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
