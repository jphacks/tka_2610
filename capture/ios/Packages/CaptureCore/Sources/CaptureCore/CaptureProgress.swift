import Foundation

// 撮影の進み具合：方向ごとに「そろった・確認中・撮り直し・未撮影」を決め、送る前の確認（そろっているか・気になる写真）をまとめる。
// session.json には書かない（いつでも session.json から計算し直せる）。

/// 写真のマスクの結果を、方向がそろったかの判定に使う形にしたもの。
public enum MaskOutcome: Equatable, Sendable {
    /// 使える（ユーザーが確認した、または自動で作って確かめた結果が ok）。
    case good
    /// まだ分からない（作っている・順番待ち・確かめていない）。
    case pending
    /// 使えない（作品らしくない・確かめられない・作れなかった・物が無い）。
    case bad
}

extension Photo {
    public var maskOutcome: MaskOutcome {
        switch mask.status {
        case .confirmed: return .good
        case .candidate:
            switch mask.check?.status {
            case .ok?: return .good
            case nil: return .pending
            case .suspicious?, .unknown?: return .bad
            }
        case .notGenerated, .processing: return .pending
        case .failed, .noObject: return .bad
        }
    }
}

/// 撮影方向 1 つの状態（1 つの基準の中で）。
public enum TargetState: String, Equatable, Sendable {
    /// まだ撮っていない。
    case notShot
    /// 撮ったが、切り抜きを作っている・確かめている（仮にそろった扱い：自動撮影ですぐ撮り直さない）。
    case checking
    /// そろった。
    case done
    /// 撮ったが切り抜きがうまくいかなかった。もう一度撮る。
    case retake

    /// 撮影中に「撮った」とみなす（次に撮る方向・自動撮影の対象から外す）。
    public var countsAsCovered: Bool { self == .done || self == .checking }
}

public struct TargetProgress: Equatable, Sendable {
    public var target: DirectionTarget
    public var state: TargetState
    /// この方向の代表の写真（新しく撮った写真が優先。使える写真があれば、その中で一番新しいもの）。
    public var photoId: String?
    /// この方向の、代表ではない写真（置き換え済み）。撮影順。
    public var supersededPhotoIds: [String]
}

/// 1 つの基準の、撮影方向ごとの状態。
public struct CoverageProgress: Equatable, Sendable {
    public var referenceFrameId: String?
    /// 撮影方向の一覧の順。
    public var targets: [TargetProgress]

    public init(referenceFrameId: String?, targets: [TargetProgress]) {
        self.referenceFrameId = referenceFrameId
        self.targets = targets
    }

    public func ids(_ state: TargetState) -> Set<String> {
        Set(targets.filter { $0.state == state }.map(\.target.id))
    }

    public var doneIds: Set<String> { ids(.done) }
    public var checkingIds: Set<String> { ids(.checking) }
    public var retakeIds: Set<String> { ids(.retake) }
    /// 撮影中に撮ったとみなす方向（そろった ＋ 確認中）。次に撮る方向・自動撮影はこれ以外から選ぶ。
    public var coveredForCapture: Set<String> { Set(targets.filter { $0.state.countsAsCovered }.map(\.target.id)) }
    public var supersededPhotoIds: Set<String> { Set(targets.flatMap(\.supersededPhotoIds)) }
    public var doneCount: Int { targets.filter { $0.state == .done }.count }
    public var totalCount: Int { targets.count }
    /// すべての方向がそろった（確認中を含まない）。
    public var isComplete: Bool { totalCount > 0 && doneCount == totalCount }

    public func state(of targetId: String) -> TargetState {
        targets.first { $0.target.id == targetId }?.state ?? .notShot
    }

    public static func empty(plan: DirectionPlan) -> CoverageProgress {
        CoverageProgress(referenceFrameId: nil, targets: plan.targets.map {
            TargetProgress(target: $0, state: .notShot, photoId: nil, supersededPhotoIds: [])
        })
    }
}

/// 仰角の段ごとの進み具合（撮影画面の「20°: 18/24 · 45°: 0/16 · 70°: 0/8」）。
public struct BandProgress: Equatable, Sendable, Identifiable {
    public var elevationDeg: Double
    /// そろった方向の数。
    public var doneCount: Int
    /// 撮影中に撮ったとみなす方向の数（そろった ＋ 確認中）。
    public var coveredCount: Int
    public var totalCount: Int

    public var id: String { DirectionTarget.formatDegrees(elevationDeg) }
    public var isComplete: Bool { doneCount >= totalCount }
    /// 「20°: 18/24」
    public var text: String { "\(DirectionTarget.formatDegrees(elevationDeg))°: \(doneCount)/\(totalCount)" }
}

extension CoverageProgress {
    /// 段ごとの進み具合（低い順）。
    public var bands: [BandProgress] {
        DirectionPlan(id: "", targets: targets.map(\.target)).bands.map { band in
            let states = band.targets.map { state(of: $0.id) }
            return BandProgress(
                elevationDeg: band.elevationDeg, doneCount: states.filter { $0 == .done }.count,
                coveredCount: states.filter(\.countsAsCovered).count, totalCount: band.targets.count
            )
        }
    }

    /// 段ごとの進み具合の 1 行（例：「20°: 18/24 · 45°: 0/16 · 70°: 0/8」）。段が 1 つなら nil。
    public var bandSummary: String? {
        let bands = self.bands
        guard bands.count > 1 else { return nil }
        return bands.map(\.text).joined(separator: " · ")
    }
}

extension Coverage {
    /// 基準 `referenceFrameId` の撮影方向ごとの状態。数えるのは、その基準で撮った、方向が確定した写真だけ。
    /// - そろった：代表の写真のマスクが使える（`confirmed`、または `candidate` で確かめた結果が ok）。
    /// - 確認中：代表の写真のマスクをまだ作っている・確かめていない。
    /// - 撮り直し：代表の写真のマスクが使えない（suspicious・unknown・failed・noObject）。
    /// 代表の写真は、使える写真のうち一番新しいもの。使える写真が無ければ一番新しい写真。
    /// 代表より新しくて確認中の写真は、置き換え済みにしない（結果しだいで代表になる）。
    public static func progress(photos: [Photo], referenceFrameId: String?, plan: DirectionPlan) -> CoverageProgress {
        guard let referenceFrameId else { return .empty(plan: plan) }
        let inFrame = photos
            .filter { $0.referenceFrameId == referenceFrameId && $0.direction.confirmed && $0.direction.targetId != nil }
            .sorted { $0.sequence < $1.sequence }
        let targets = plan.targets.map { target -> TargetProgress in
            let shots = inFrame.filter { $0.direction.targetId == target.id }
            guard let latest = shots.last else {
                return TargetProgress(target: target, state: .notShot, photoId: nil, supersededPhotoIds: [])
            }
            let winner = shots.last { $0.maskOutcome == .good } ?? latest
            let state: TargetState
            switch winner.maskOutcome {
            case .good: state = .done
            case .pending: state = .checking
            case .bad: state = .retake
            }
            let superseded = shots.filter { shot in
                shot.photoId != winner.photoId && !(shot.sequence > winner.sequence && shot.maskOutcome == .pending)
            }
            return TargetProgress(target: target, state: state, photoId: winner.photoId, supersededPhotoIds: superseded.map(\.photoId))
        }
        return CoverageProgress(referenceFrameId: referenceFrameId, targets: targets)
    }

    public static func progress(in session: CaptureSession, referenceFrameId: String?) -> CoverageProgress {
        progress(photos: session.photos, referenceFrameId: referenceFrameId, plan: session.directionPlan)
    }
}

/// 送る前に気にしてほしい点（写真ごと）。
public enum PhotoIssue: String, CaseIterable, Sendable {
    /// 切り抜きが作品らしくない（確かめた結果が suspicious）。
    case maskSuspicious
    /// 切り抜きを確かめられない（確かめた結果が unknown：基準が無い・写真の全体から作った）。
    case maskUnchecked
    /// 切り抜きが無い（failed・noObject）。
    case maskMissing
    /// 方向が参考値（基準なし・位置が不安定・基準が無効）。
    case directionUnconfirmed
    /// 同じ方向をあとで撮り直した（置き換え済み）。
    case superseded

    public var label: String {
        switch self {
        case .maskSuspicious: return "切り抜きが怪しい"
        case .maskUnchecked: return "切り抜きを確かめられない"
        case .maskMissing: return "切り抜きなし"
        case .directionUnconfirmed: return "方向が参考値"
        case .superseded: return "置き換え済み"
        }
    }
}

/// 送る前の確認（撮影画面・確認画面・送信画面に出す）。session.json から計算する。
public struct Readiness: Equatable, Sendable {
    /// 方向を数える基準（最後に設定した基準）。基準が 1 つも無ければ nil。
    public var referenceFrameId: String?
    public var progress: CoverageProgress
    /// 写真ごとの気になる点（無い写真は入らない）。
    public var issues: [String: [PhotoIssue]]
    /// 切り抜きを作っている・待っている写真の数。
    public var pendingMaskCount: Int

    public var doneCount: Int { progress.doneCount }
    public var totalCount: Int { progress.totalCount }
    public var isComplete: Bool { progress.isComplete }

    public func issues(for photoId: String) -> [PhotoIssue] { issues[photoId] ?? [] }

    /// 気になる点のある写真の数。
    public var attentionCount: Int { issues.count }

    public func count(_ issue: PhotoIssue) -> Int { issues.values.filter { $0.contains(issue) }.count }

    /// 置き換え済みの写真（どの基準でも）。
    public var supersededPhotoIds: [String] {
        issues.filter { $0.value.contains(.superseded) }.map(\.key).sorted()
    }

    /// セッションから作る。方向は最後に設定した基準で数える（撮影画面を閉じると基準は無効になるため、有効かどうかは問わない）。
    /// 置き換え済みは基準ごとに決める。`pendingPhotoIds` は順番待ちのマスク（まだ `processing` になっていない）。
    public static func make(session: CaptureSession, pendingPhotoIds: Set<String> = []) -> Readiness {
        let lastId = session.referenceFrames.last?.id
        let progress = Coverage.progress(in: session, referenceFrameId: lastId)
        var superseded = Set<String>()
        for frame in session.referenceFrames {
            superseded.formUnion(frame.id == lastId ? progress.supersededPhotoIds
                                 : Coverage.progress(in: session, referenceFrameId: frame.id).supersededPhotoIds)
        }
        var issues: [String: [PhotoIssue]] = [:]
        var pending = 0
        for photo in session.photos {
            var list: [PhotoIssue] = []
            switch photo.mask.status {
            case .candidate:
                if photo.mask.check?.status == .suspicious { list.append(.maskSuspicious) }
                if photo.mask.check?.status == .unknown { list.append(.maskUnchecked) }
            case .failed, .noObject:
                list.append(.maskMissing)
            case .confirmed, .notGenerated, .processing:
                break
            }
            if photo.mask.status == .notGenerated || photo.mask.status == .processing || pendingPhotoIds.contains(photo.photoId) {
                pending += 1
            }
            if !photo.direction.confirmed { list.append(.directionUnconfirmed) }
            if superseded.contains(photo.photoId) { list.append(.superseded) }
            if !list.isEmpty { issues[photo.photoId] = list }
        }
        return Readiness(referenceFrameId: lastId, progress: progress, issues: issues, pendingMaskCount: pending)
    }

    /// 1 行の要約（例：「方向 8/8 そろいました」「方向 6/8・撮り直し 2」）。
    public var directionSummary: String {
        if totalCount == 0 { return "撮る方向がありません" }
        if isComplete { return "方向 \(doneCount)/\(totalCount) そろいました" }
        var parts = ["方向 \(doneCount)/\(totalCount)"]
        let checking = progress.checkingIds.count, retake = progress.retakeIds.count
        if checking > 0 { parts.append("確認中 \(checking)") }
        if retake > 0 { parts.append("撮り直し \(retake)") }
        return parts.joined(separator: "・")
    }

    /// 気になる写真の要約（無ければ nil）。例：「気になる写真 3 枚（切り抜きが怪しい 2・方向が参考値 1）」
    public var attentionSummary: String? {
        guard attentionCount > 0 else { return nil }
        let parts = PhotoIssue.allCases.compactMap { issue -> String? in
            let n = count(issue)
            return n > 0 ? "\(issue.label) \(n)" : nil
        }
        return "気になる写真 \(attentionCount) 枚（\(parts.joined(separator: "・"))）"
    }
}
