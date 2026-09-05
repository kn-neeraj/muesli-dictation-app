import ArgumentParser
import Foundation
import MuesliCore

struct VoiceDataOptions: ParsableArguments {
    @Option(name: .long, help: "Override the voice-data directory containing manifest.jsonl and recordings/.")
    var voiceDataDir: String?

    func rootDirectory(context: CLIContext) -> URL {
        if let voiceDataDir, !voiceDataDir.isEmpty {
            return URL(fileURLWithPath: NSString(string: voiceDataDir).expandingTildeInPath)
                .standardizedFileURL
        }
        return context.supportDirectory.appendingPathComponent("voice-data", isDirectory: true)
    }
}

struct VoiceDataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice-data",
        abstract: "Inspect and export locally collected OpenAI dictation audio.",
        subcommands: [VoiceDataStatsCommand.self, VoiceDataExportCommand.self]
    )
}

struct VoiceDataStatsPayload: Encodable, Equatable {
    let directory: String
    let sampleCount: Int
    let totalMinutes: Double
    let reviewedMinutes: Double
    let unreviewedMinutes: Double

    init(directory: URL, stats: VoiceDataStats) {
        self.directory = directory.path
        sampleCount = stats.sampleCount
        totalMinutes = stats.totalDurationSeconds / 60
        reviewedMinutes = stats.reviewedDurationSeconds / 60
        unreviewedMinutes = stats.unreviewedDurationSeconds / 60
    }
}

struct VoiceDataStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Report collected duration and sample count."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var voiceData: VoiceDataOptions

    func run() async throws {
        let context = CLIContext(options: global)
        let root = voiceData.rootDirectory(context: context)
        let stats = try await VoiceDataStore(rootDirectory: root).stats()
        emitSuccess(
            command: "muesli-cli voice-data stats",
            data: VoiceDataStatsPayload(directory: root, stats: stats),
            dbPath: context.databaseURL
        )
    }
}

struct VoiceDataExportPayload: Encodable, Equatable {
    let outputDirectory: String
    let sampleCount: Int
    let totalMinutes: Double

    init(_ result: VoiceDataExportResult) {
        outputDirectory = result.outputDirectory
        sampleCount = result.sampleCount
        totalMinutes = result.totalDurationSeconds / 60
    }
}

struct VoiceDataExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Copy collected WAVs and effective transcripts into a portable dataset."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var voiceData: VoiceDataOptions
    @Argument(help: "A new directory to create for the exported dataset.")
    var outputDirectory: String

    func run() async throws {
        let context = CLIContext(options: global)
        let root = voiceData.rootDirectory(context: context)
        let output = URL(
            fileURLWithPath: NSString(string: outputDirectory).expandingTildeInPath
        ).standardizedFileURL
        do {
            let result = try await VoiceDataStore(rootDirectory: root).export(to: output)
            emitSuccess(
                command: "muesli-cli voice-data export",
                data: VoiceDataExportPayload(result),
                dbPath: context.databaseURL
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw CLIError.invalidInput(
                "Export directory already exists: \(output.path)",
                fix: "Choose a new output directory so existing files are not overwritten."
            )
        }
    }
}
