import Foundation
import CaptureCore

public struct Report: Codable {
    public struct Tool: Codable {
        public var name = "memoria-reconstruct"
        public var version = "0.1.0"
        public var command: [String]
    }
    public struct SessionInfo: Codable {
        public var sessionId: String
        public var title: String
        public var folder: String
        @NullCodable public var manifestHash: String?
        @NullCodable public var receivedAt: String?
        public var photoCount: Int
        public var directionPlanId: String
        public var referenceFrameIds: [String]
    }
    public struct Environment: Codable {
        public var osVersion: String
        public var photogrammetryIsSupported: Bool
        public var maximumInputImageDimension: Int
        public var maximumNumberOfInputImages: Int
    }
    public struct Counts: Codable {
        public var photos = 0
        public var planned = 0
        public var excluded = 0
        public var plannedWithMask = 0
        /// Samples actually handed to PhotogrammetrySession (built without error).
        public var samplesProvided = 0
        public var samplesWithMask = 0
        public var invalidSamples = 0
        public var skippedSamples = 0
        @NullCodable public var posesEstimated: Int?
    }
    public struct Message: Codable {
        /// Seconds since the session was created.
        public var t: Double
        public var type: String
        @NullCodable public var request: String?
        @NullCodable public var sampleId: Int?
        @NullCodable public var detail: String?
    }
    public struct StageTiming: Codable {
        public var request: String
        public var stage: String
        public var startS: Double
        @NullCodable public var durationS: Double?
    }
    public struct Durations: Codable {
        public var sessionCreateS: Double = 0
        public var processingS: Double = 0
        public var totalS: Double = 0
        public var requests: [String: Double] = [:]
    }
    public struct ModelInfo: Codable, Equatable, Sendable {
        public var file: String
        public var bytes: Int
        @NullCodable public var mesh: MeshStats?
    }
    public struct PoseEntry: Codable, Equatable, Sendable {
        public var sampleId: Int
        public var photoId: String
        public var translation: [Double]
        public var rotationQuaternion: [Double]
        @NullCodable public var estimatedFx: Double?
        @NullCodable public var estimatedFy: Double?
        public var arkitFx: Double
        public var arkitFy: Double
    }
    public struct Poses: Codable, Equatable, Sendable {
        public var count: Int
        public var notPosedSampleIds: [Int]
        public var entries: [PoseEntry]
        public var scaleCheck: [ScaleCheck]
    }
    public struct PerInput: Codable {
        public var plan: PlannedInput
        @NullCodable public var load: SampleLoadRecord?
        /// "notProvided" (excluded / failed to build), "used", "invalid: …", "skipped", "unposed" or "unknown".
        public var sessionOutcome: String
    }

    public var tool: Tool
    public var startedAt: String
    @NullCodable public var finishedAt: String?
    /// "completed", "failed", "cancelled".
    public var status: String = "failed"
    public var errors: [String] = []
    public var session: SessionInfo
    public var options: Options
    /// The PhotogrammetrySession.Configuration actually used.
    public var configuration: [String: String] = [:]
    public var environment: Environment
    public var counts = Counts()
    public var inputs: [PerInput] = []
    public var messages: [Message] = []
    public var stages: [StageTiming] = []
    public var durations = Durations()
    @NullCodable public var model: ModelInfo?
    @NullCodable public var poses: Poses?
    public var notes: [String] = []
}

extension Report {
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
