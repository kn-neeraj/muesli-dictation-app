import Foundation

public struct VoiceDataEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let audioPath: String
    public let durationSeconds: Double
    public let sttEngine: String
    public let sttModel: String
    public let transcriptRaw: String
    public let transcriptCorrected: String?
    public let reviewed: Bool
    public let timestamp: String
    public let device: String?

    public init(
        id: UUID,
        audioPath: String,
        durationSeconds: Double,
        sttEngine: String,
        sttModel: String,
        transcriptRaw: String,
        transcriptCorrected: String? = nil,
        reviewed: Bool = false,
        timestamp: String,
        device: String? = nil
    ) {
        self.id = id
        self.audioPath = audioPath
        self.durationSeconds = durationSeconds
        self.sttEngine = sttEngine
        self.sttModel = sttModel
        self.transcriptRaw = transcriptRaw
        self.transcriptCorrected = transcriptCorrected
        self.reviewed = reviewed
        self.timestamp = timestamp
        self.device = device
    }

    public var finalTranscript: String {
        transcriptCorrected ?? transcriptRaw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(audioPath, forKey: .audioPath)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(sttEngine, forKey: .sttEngine)
        try container.encode(sttModel, forKey: .sttModel)
        try container.encode(transcriptRaw, forKey: .transcriptRaw)
        if let transcriptCorrected {
            try container.encode(transcriptCorrected, forKey: .transcriptCorrected)
        } else {
            try container.encodeNil(forKey: .transcriptCorrected)
        }
        try container.encode(reviewed, forKey: .reviewed)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(device, forKey: .device)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case audioPath = "audio_path"
        case durationSeconds = "duration_sec"
        case sttEngine = "stt_engine"
        case sttModel = "stt_model"
        case transcriptRaw = "transcript_raw"
        case transcriptCorrected = "transcript_corrected"
        case reviewed
        case timestamp
        case device
    }
}

public struct VoiceDataStats: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let totalDurationSeconds: Double
    public let reviewedDurationSeconds: Double
    public let unreviewedDurationSeconds: Double

    public init(entries: [VoiceDataEntry]) {
        sampleCount = entries.count
        totalDurationSeconds = entries.reduce(0) { $0 + $1.durationSeconds }
        reviewedDurationSeconds = entries.lazy.filter(\.reviewed).reduce(0) { $0 + $1.durationSeconds }
        unreviewedDurationSeconds = totalDurationSeconds - reviewedDurationSeconds
    }
}

public struct StagedVoiceDataAudio: Sendable {
    public let id: UUID
    public let url: URL

    public init(id: UUID, url: URL) {
        self.id = id
        self.url = url
    }
}

public struct VoiceDataExportResult: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let totalDurationSeconds: Double
    public let outputDirectory: String
}

public actor VoiceDataStore {
    public static let manifestFilename = "manifest.jsonl"

    public let rootDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func stageAudio(id: UUID, from sourceURL: URL) throws -> StagedVoiceDataAudio {
        try ensureDirectories()
        let destination = stagingDirectory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("wav")
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try setOwnerOnlyFilePermissions(destination)
        return StagedVoiceDataAudio(id: id, url: destination)
    }

    @discardableResult
    public func commitOpenAIEntry(
        stagedAudio: StagedVoiceDataAudio,
        transcript: String,
        durationSeconds: Double,
        model: String,
        timestamp: String,
        device: String?
    ) throws -> VoiceDataEntry {
        try ensureDirectories()
        let filename = stagedAudio.id.uuidString.lowercased() + ".wav"
        let destination = recordingsDirectory.appendingPathComponent(filename)
        guard isDirectChild(stagedAudio.url, of: stagingDirectory),
              fileManager.fileExists(atPath: stagedAudio.url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedAudio.url, to: destination)
        try setOwnerOnlyFilePermissions(destination)

        let entry = VoiceDataEntry(
            id: stagedAudio.id,
            audioPath: "recordings/\(filename)",
            durationSeconds: max(durationSeconds, 0),
            sttEngine: "openai-realtime",
            sttModel: model,
            transcriptRaw: transcript,
            timestamp: timestamp,
            device: device
        )
        do {
            try append(entry)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return entry
    }

    public func discard(_ stagedAudio: StagedVoiceDataAudio) {
        guard isDirectChild(stagedAudio.url, of: stagingDirectory) else { return }
        try? fileManager.removeItem(at: stagedAudio.url)
    }

    public func entries() throws -> [VoiceDataEntry] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        var effective: [UUID: VoiceDataEntry] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let entry = try? decoder.decode(VoiceDataEntry.self, from: Data(line)) else { continue }
            effective[entry.id] = entry
        }
        return effective.values.sorted { $0.timestamp < $1.timestamp }
    }

    public func stats() throws -> VoiceDataStats {
        VoiceDataStats(entries: try entries())
    }

    public func export(to outputDirectory: URL) throws -> VoiceDataExportResult {
        let output = outputDirectory.standardizedFileURL
        guard !fileManager.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let audioOutput = output.appendingPathComponent("audio", isDirectory: true)
        try fileManager.createDirectory(at: audioOutput, withIntermediateDirectories: true)

        do {
            var exportedLines = Data()
            var exportedCount = 0
            var exportedDuration = 0.0
            for entry in try entries() {
                guard let sourceAudio = resolvedAudioURL(for: entry) else { continue }
                let filename = entry.id.uuidString.lowercased() + ".wav"
                let destination = audioOutput.appendingPathComponent(filename)
                try fileManager.copyItem(at: sourceAudio, to: destination)
                let row = VoiceDataExportRow(
                    id: entry.id,
                    audioPath: "audio/\(filename)",
                    durationSeconds: entry.durationSeconds,
                    sttEngine: entry.sttEngine,
                    sttModel: entry.sttModel,
                    transcript: entry.finalTranscript,
                    reviewed: entry.reviewed
                )
                exportedLines.append(try encoder.encode(row))
                exportedLines.append(UInt8(ascii: "\n"))
                exportedCount += 1
                exportedDuration += entry.durationSeconds
            }
            let exportedManifest = output.appendingPathComponent(Self.manifestFilename)
            try exportedLines.write(to: exportedManifest, options: .atomic)
            return VoiceDataExportResult(
                sampleCount: exportedCount,
                totalDurationSeconds: exportedDuration,
                outputDirectory: output.path
            )
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
        }
    }

    private var manifestURL: URL {
        rootDirectory.appendingPathComponent(Self.manifestFilename)
    }

    private var recordingsDirectory: URL {
        rootDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    private var stagingDirectory: URL {
        rootDirectory.appendingPathComponent(".staging", isDirectory: true)
    }

    private func ensureDirectories() throws {
        for directory in [rootDirectory, recordingsDirectory, stagingDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private func append(_ entry: VoiceDataEntry) throws {
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        if !fileManager.fileExists(atPath: manifestURL.path) {
            guard fileManager.createFile(atPath: manifestURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: manifestURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        try setOwnerOnlyFilePermissions(manifestURL)
    }

    private func resolvedAudioURL(for entry: VoiceDataEntry) -> URL? {
        guard !entry.audioPath.hasPrefix("/"), !entry.audioPath.contains("..") else { return nil }
        let resolved = rootDirectory.appendingPathComponent(entry.audioPath).standardizedFileURL
        guard resolved.path.hasPrefix(rootDirectory.path + "/"),
              fileManager.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    private func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL
    }

    private func setOwnerOnlyFilePermissions(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct VoiceDataExportRow: Encodable {
    let id: UUID
    let audioPath: String
    let durationSeconds: Double
    let sttEngine: String
    let sttModel: String
    let transcript: String
    let reviewed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case audioPath = "audio_path"
        case durationSeconds = "duration_sec"
        case sttEngine = "stt_engine"
        case sttModel = "stt_model"
        case transcript
        case reviewed
    }
}
