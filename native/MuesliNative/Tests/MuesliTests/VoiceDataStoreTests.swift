import Foundation
import Testing
@testable import MuesliCore

@Suite("VoiceDataStore", .serialized)
struct VoiceDataStoreTests {
    @Test("OpenAI capture preserves WAV bytes and appends its transcript mapping")
    func capturePreservesAudioAndManifest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let id = UUID()
        let store = VoiceDataStore(rootDirectory: fixture.root)

        let staged = try await store.stageAudio(id: id, from: fixture.sourceWAV)
        let entry = try await store.commitOpenAIEntry(
            stagedAudio: staged,
            transcript: "Muesli keeps the exact OpenAI transcript.",
            durationSeconds: 4.2,
            model: "gpt-live-transcribe",
            timestamp: "2026-09-05T10:30:00Z",
            device: "test-microphone"
        )

        #expect(entry.id == id)
        #expect(entry.audioPath == "recordings/\(id.uuidString.lowercased()).wav")
        #expect(entry.sttEngine == "openai-realtime")
        #expect(entry.sttModel == "gpt-live-transcribe")
        #expect(entry.transcriptRaw == "Muesli keeps the exact OpenAI transcript.")
        #expect(entry.transcriptCorrected == nil)
        #expect(!entry.reviewed)
        #expect(entry.device == "test-microphone")

        let preserved = fixture.root.appendingPathComponent(entry.audioPath)
        #expect(try Data(contentsOf: preserved) == fixture.audioBytes)
        #expect(try await store.entries() == [entry])

        let manifest = try String(
            contentsOf: fixture.root.appendingPathComponent("manifest.jsonl"),
            encoding: .utf8
        )
        #expect(manifest.split(separator: "\n").count == 1)
        #expect(manifest.contains(#""stt_engine":"openai-realtime""#))
        #expect(manifest.contains(#""transcript_raw":"Muesli keeps the exact OpenAI transcript.""#))
        #expect(manifest.contains(#""transcript_corrected":null"#))
    }

    @Test("Stats and export use the latest corrected snapshot for each recording")
    func statsAndExportUseLatestSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let id = UUID()
        let store = VoiceDataStore(rootDirectory: fixture.root)
        let staged = try await store.stageAudio(id: id, from: fixture.sourceWAV)
        let original = try await store.commitOpenAIEntry(
            stagedAudio: staged,
            transcript: "silver label",
            durationSeconds: 90,
            model: "gpt-live-transcribe",
            timestamp: "2026-09-05T10:30:00Z",
            device: nil
        )
        let corrected = VoiceDataEntry(
            id: original.id,
            audioPath: original.audioPath,
            durationSeconds: original.durationSeconds,
            sttEngine: original.sttEngine,
            sttModel: original.sttModel,
            transcriptRaw: original.transcriptRaw,
            transcriptCorrected: "gold label",
            reviewed: true,
            timestamp: original.timestamp,
            device: original.device
        )
        try appendFixtureEntry(corrected, to: fixture.root)
        try Data("{interrupted".utf8).appendLine(
            to: fixture.root.appendingPathComponent("manifest.jsonl")
        )

        let effective = try await store.entries()
        #expect(effective == [corrected])
        let stats = try await store.stats()
        #expect(stats.sampleCount == 1)
        #expect(stats.totalDurationSeconds == 90)
        #expect(stats.reviewedDurationSeconds == 90)
        #expect(stats.unreviewedDurationSeconds == 0)

        let output = fixture.container.appendingPathComponent("export")
        let result = try await store.export(to: output)
        #expect(result.sampleCount == 1)
        #expect(result.totalDurationSeconds == 90)
        #expect(try Data(contentsOf: output.appendingPathComponent("audio/\(id.uuidString.lowercased()).wav")) == fixture.audioBytes)
        let exportedManifest = try String(
            contentsOf: output.appendingPathComponent("manifest.jsonl"),
            encoding: .utf8
        )
        #expect(exportedManifest.contains(#""transcript":"gold label""#))
        #expect(!exportedManifest.contains(#""transcript":"silver label""#))
    }

    @Test("Export refuses to overwrite an existing directory")
    func exportRefusesExistingDirectory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let output = fixture.container.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = VoiceDataStore(rootDirectory: fixture.root)

        await #expect(throws: CocoaError.self) {
            try await store.export(to: output)
        }
    }

    private func makeFixture() throws -> (
        container: URL,
        root: URL,
        sourceWAV: URL,
        audioBytes: Data
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-voice-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let audioBytes = Data("RIFF-test-WAVE-audio".utf8)
        let sourceWAV = container.appendingPathComponent("source.wav")
        try audioBytes.write(to: sourceWAV)
        return (
            container: container,
            root: container.appendingPathComponent("voice-data", isDirectory: true),
            sourceWAV: sourceWAV,
            audioBytes: audioBytes
        )
    }

    private func appendFixtureEntry(_ entry: VoiceDataEntry, to root: URL) throws {
        let encoder = JSONEncoder()
        var data = try encoder.encode(entry)
        data.append(UInt8(ascii: "\n"))
        try data.appendLine(to: root.appendingPathComponent("manifest.jsonl"))
    }
}

private extension Data {
    func appendLine(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
        if last != UInt8(ascii: "\n") {
            try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
        }
    }
}
