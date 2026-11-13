import Foundation

public enum DetailOption: String, CaseIterable, Codable, Sendable {
    case preview, reduced, medium, full, raw
}

/// Which of the session's mask PNGs are handed to PhotogrammetrySession.
public enum MaskMode: String, CaseIterable, Codable, Sendable {
    /// confirmed, or candidate whose check is ok or missing.
    case auto
    /// every mask file that exists (candidate / confirmed), whatever the check says.
    case on
    /// no masks from the session.
    case off
}

public enum IncludeMode: String, CaseIterable, Codable, Sendable {
    /// every photo whose image can be read.
    case all
    /// direction confirmed, usable mask (auto rule), not superseded.
    case good
}

public enum OrderingOption: String, CaseIterable, Codable, Sendable {
    case unordered, sequential
}

public enum SensitivityOption: String, CaseIterable, Codable, Sendable {
    case normal, high
}

/// How (and whether) the gravity vector derived from `cameraToWorld` is passed.
/// The RealityKit doc comment for `PhotogrammetrySample.gravity` does not state a frame or sign,
/// so this is opt-in.
public enum GravityMode: String, CaseIterable, Codable, Sendable {
    case off
    /// CMDeviceMotion.gravity convention: device frame of the portrait iPhone
    /// (+X right edge, +Y top edge, +Z out of the screen), unit = g, pointing towards the earth.
    case on
    /// Same vector expressed in the ARKit camera / stored-image axes (+X image right, +Y image up, +Z backwards).
    case camera
}

public enum OnOff: String, CaseIterable, Codable, Sendable {
    case on, off
    public var isOn: Bool { self == .on }
}

public struct Options: Codable, Sendable {
    public var session: String
    public var dataDir: String?
    public var detail: DetailOption = .medium
    public var masks: MaskMode = .auto
    public var include: IncludeMode = .all
    public var ordering: OrderingOption = .unordered
    public var sensitivity: SensitivityOption = .normal
    public var gravity: GravityMode = .off
    /// PhotogrammetrySession.Configuration.isObjectMaskingEnabled.
    public var sessionMasking: OnOff = .on
    /// Also request `.poses` (estimated camera poses; used for the report's scale check).
    public var poses: OnOff = .on
    public var out: String?
    /// Only photos whose referenceFrameId is in this list ("none" = photos without a reference frame). nil = all.
    public var frames: [String]?

    public init(session: String) {
        self.session = session
    }
}

public struct UsageError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum CommandLineParser {
    public static let usage = """
    usage: memoria-reconstruct <session folder | sessionId | sessionId prefix> [options]

      --data-dir <dir>        captures folder (default: the nearest ./captures with sessions/ above
                              the current directory, else <repo>/captures)
      --detail <d>            preview | reduced | medium | full | raw   (default medium)
      --masks <m>             auto | on | off   (default auto)
                                auto: mask.status confirmed, or candidate with check ok / no check
                                on:   every mask file that exists
                                off:  no masks from the session
      --include <i>           all | good   (default all)
                                good: direction.confirmed, usable mask, not superseded
      --ordering <o>          unordered | sequential   (default unordered)
      --sensitivity <s>       normal | high   (default normal)
      --gravity <g>           off | on | camera   (default off; experimental, see README)
      --session-masking <b>   on | off  PhotogrammetrySession isObjectMaskingEnabled (default on)
      --poses <b>             on | off  also request estimated camera poses (default on)
      --frames <ids>          only photos of these reference frames, comma separated (e.g. ref-2,none;
                              "none" = photos without a reference frame). Default: all
      --out <dir>             output folder (default <data-dir>/reconstructions/<sessionId>/<UTC>-<detail>/)
      -h, --help              show this help
    """

    public static func parse(_ arguments: [String]) throws -> Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var i = 0
        let known: Set<String> = ["--data-dir", "--detail", "--masks", "--include", "--ordering", "--sensitivity",
                                  "--gravity", "--session-masking", "--poses", "--out", "--frames"]
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "-h" || arg == "--help" { throw UsageError("") }
            if arg.hasPrefix("--") {
                var key = arg
                var value: String?
                if let eq = arg.firstIndex(of: "=") {
                    key = String(arg[..<eq])
                    value = String(arg[arg.index(after: eq)...])
                }
                guard known.contains(key) else { throw UsageError("unknown option \(key)") }
                if value == nil {
                    i += 1
                    guard i < arguments.count else { throw UsageError("\(key) needs a value") }
                    value = arguments[i]
                }
                guard values[key] == nil else { throw UsageError("\(key) given twice") }
                values[key] = value
            } else {
                positional.append(arg)
            }
            i += 1
        }
        guard positional.count == 1 else {
            throw UsageError(positional.isEmpty ? "missing session" : "only one session can be given")
        }
        var options = Options(session: positional[0])
        options.dataDir = values["--data-dir"]
        options.out = values["--out"]
        if let v = values["--frames"] {
            let ids = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !ids.isEmpty else { throw UsageError("--frames needs at least one id") }
            options.frames = ids
        }
        if let v = values["--detail"] { options.detail = try choice(v, "--detail") }
        if let v = values["--masks"] { options.masks = try choice(v, "--masks") }
        if let v = values["--include"] { options.include = try choice(v, "--include") }
        if let v = values["--ordering"] { options.ordering = try choice(v, "--ordering") }
        if let v = values["--sensitivity"] { options.sensitivity = try choice(v, "--sensitivity") }
        if let v = values["--gravity"] { options.gravity = try choice(v, "--gravity") }
        if let v = values["--session-masking"] { options.sessionMasking = try choice(v, "--session-masking") }
        if let v = values["--poses"] { options.poses = try choice(v, "--poses") }
        return options
    }

    private static func choice<T: RawRepresentable & CaseIterable>(_ value: String, _ key: String) throws -> T
    where T.RawValue == String {
        guard let v = T(rawValue: value.lowercased()) else {
            throw UsageError("\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: " | ")), got \(value)")
        }
        return v
    }
}
