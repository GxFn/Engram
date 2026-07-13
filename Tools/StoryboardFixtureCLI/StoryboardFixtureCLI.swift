import AVFoundation
import CryptoKit
import Foundation
import StoryboardCore
import VideoUnderstanding

@main
enum StoryboardFixtureCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(sanitized(error))\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { throw CLIError.usage }
        switch command {
        case "probe":
            let video = try requiredPath(arguments, at: 1)
            try printJSON(await probe(video))
        case "label-template":
            let video = try requiredPath(arguments, at: 1)
            let asset = try await probe(video)
            let label = StoryboardFixtureLabel(
                fixtureID: asset.fixtureID,
                sha256: asset.sha256,
                durationSeconds: asset.durationSeconds,
                frameRate: asset.frameRate,
                frameCount: asset.frameCount,
                shots: [BoundaryLabel(startFrame: 0, endFrameExclusive: 0, transitionOut: .end)]
            )
            try printJSON(label)
        case "validate-label":
            let path = try requiredPath(arguments, at: 1)
            let label: StoryboardFixtureLabel = try decode(path)
            try label.validate()
            try printJSON(ValidationResult(kind: "fixture-label", valid: true, filesChecked: 1))
        case "evaluate":
            let goldPath = try option("--gold", in: arguments)
            let predictionPath = try option("--prediction", in: arguments)
            let tolerance = Int(optionValue("--tolerance", in: arguments) ?? "2") ?? 2
            let gold: StoryboardFixtureLabel = try decode(goldPath)
            try gold.validate()
            let predictions: [BoundaryPrediction] = try decode(predictionPath)
            try printJSON(BoundaryEvaluator.evaluate(
                labels: gold.shots,
                predictions: predictions,
                toleranceFrames: tolerance
            ))
        case "compare":
            let baselinePath = try option("--baseline", in: arguments)
            let candidatePath = try option("--candidate", in: arguments)
            let baseline: BoundaryEvaluationReport = try decode(baselinePath)
            let candidate: BoundaryEvaluationReport = try decode(candidatePath)
            try printJSON(BoundaryComparison(baseline: baseline, candidate: candidate))
        case "validate-artifacts":
            let directory = try requiredPath(arguments, at: 1)
            try printJSON(validateArtifacts(directory))
        case "validate-export":
            let directory = try requiredPath(arguments, at: 1)
            try printJSON(validateExport(directory))
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func probe(_ path: String) async throws -> AssetProbeReport {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.fileMissing }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CLIError.unreadableVideo }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CLIError.unreadableVideo
        }
        let frameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let size = try await videoTrack.load(.naturalSize)
        let frameCount = max(1, Int((duration * frameRate).rounded()))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return AssetProbeReport(
            fixtureID: url.deletingPathExtension().lastPathComponent,
            sha256: try sha256(url),
            durationSeconds: duration,
            frameRate: frameRate,
            frameCount: frameCount,
            width: Int(abs(size.width).rounded()),
            height: Int(abs(size.height).rounded()),
            hasAudio: !audio.isEmpty,
            fileSizeBytes: bytes
        )
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateArtifacts(_ path: String) throws -> ValidationResult {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let required = ["manifest.json"] + AnalysisStage.allCases.map { "\($0.rawValue).json" }
        for name in required {
            let file = root.appendingPathComponent(name)
            let data = try Data(contentsOf: file)
            _ = try JSONSerialization.jsonObject(with: data)
            try rejectSensitiveContent(data)
        }
        return ValidationResult(kind: "analysis-artifacts", valid: true, filesChecked: required.count)
    }

    private static func validateExport(_ path: String) throws -> ValidationResult {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let required = ["storyboard.json", "storyboard.csv", "storyboard.md", "storyboard.pdf", "reference-frames/manifest.json"]
        var files: [String: Data] = [:]
        for name in required {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            try rejectSensitiveContent(data)
            files[name] = data
        }
        guard let documentData = files["storyboard.json"],
              let document = try? JSONDecoder().decode(StoryboardDocumentV2.self, from: documentData),
              let csvData = files["storyboard.csv"],
              let csv = String(data: csvData, encoding: .utf8),
              csv.split(separator: "\n").count == document.shots.count + 1,
              let markdownData = files["storyboard.md"],
              let markdown = String(data: markdownData, encoding: .utf8),
              document.shots.allSatisfy({ markdown.contains($0.id.rawValue) }),
              let pdf = files["storyboard.pdf"], pdf.starts(with: Data("%PDF-".utf8)), pdf.count > 1_000,
              let manifestData = files["reference-frames/manifest.json"],
              let manifest = try? JSONDecoder().decode(CLIReferenceManifest.self, from: manifestData),
              Set(manifest.items.map(\.shotID)) == Set(document.shots.map(\.id.rawValue)),
              manifest.items.allSatisfy({ item in
                  !item.fileName.contains("/")
                      && ((try? Data(contentsOf: root.appendingPathComponent("reference-frames/\(item.fileName)")))?.starts(with: [0xff, 0xd8]) ?? false)
              })
        else { throw CLIError.invalidArtifact }
        return ValidationResult(kind: "storyboard-export", valid: true, filesChecked: required.count)
    }

    private static func rejectSensitiveContent(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lowered = text.lowercased()
        if lowered.contains("authorization:")
            || lowered.contains("signedurl")
            || lowered.contains("api_key")
            || text.contains("/Users/")
        {
            throw CLIError.sensitiveArtifact
        }
    }

    private static func requiredPath(_ arguments: [String], at index: Int) throws -> String {
        guard arguments.indices.contains(index) else { throw CLIError.usage }
        return arguments[index]
    }

    private static func option(_ name: String, in arguments: [String]) throws -> String {
        guard let value = optionValue(name, in: arguments) else { throw CLIError.missingOption(name) }
        return value
    }

    private static func optionValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func decode<Value: Decodable>(_ path: String) throws -> Value {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func printJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func sanitized(_ error: Error) -> String {
        switch error {
        case let error as CLIError:
            return error.description
        case is FixtureLabelValidationError:
            return "fixture label validation failed"
        default:
            return String(describing: type(of: error))
        }
    }
}

private struct AssetProbeReport: Codable {
    let fixtureID: String
    let sha256: String
    let durationSeconds: Double
    let frameRate: Double
    let frameCount: Int
    let width: Int
    let height: Int
    let hasAudio: Bool
    let fileSizeBytes: Int64
}

private struct ValidationResult: Codable {
    let kind: String
    let valid: Bool
    let filesChecked: Int
}

private struct BoundaryComparison: Codable {
    let hardF1Delta: Double
    let gradualF1Delta: Double
    let overallF1Delta: Double

    init(baseline: BoundaryEvaluationReport, candidate: BoundaryEvaluationReport) {
        hardF1Delta = candidate.hard.f1 - baseline.hard.f1
        gradualF1Delta = candidate.gradual.f1 - baseline.gradual.f1
        overallF1Delta = candidate.overall.f1 - baseline.overall.f1
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case unknownCommand(String)
    case missingOption(String)
    case fileMissing
    case unreadableVideo
    case sensitiveArtifact
    case invalidArtifact

    var description: String {
        switch self {
        case .usage:
            return "usage: StoryboardFixtureCLI <probe|label-template|validate-label|evaluate|compare|validate-artifacts|validate-export> ..."
        case let .unknownCommand(command):
            return "unknown command: \(command)"
        case let .missingOption(option):
            return "missing option: \(option)"
        case .fileMissing:
            return "input file is missing"
        case .unreadableVideo:
            return "input has no readable video track"
        case .sensitiveArtifact:
            return "artifact contains a secret marker or absolute user path"
        case .invalidArtifact:
            return "artifact structure or round-trip validation failed"
        }
    }
}

private struct CLIReferenceManifest: Decodable {
    let items: [CLIReferenceManifestItem]
}

private struct CLIReferenceManifestItem: Decodable {
    let shotID: String
    let fileName: String
}
