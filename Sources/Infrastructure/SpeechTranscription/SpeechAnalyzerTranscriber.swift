import AVFoundation
import EngramLogging
import Foundation
import Speech
import VideoUnderstanding

public struct SpeechAnalyzerTranscriber: Transcriber {
    private let locale: Locale
    private let audioExtractor: any VideoAudioExtracting
    private let runtime: any SpeechRecognitionRunning

    public init(locale: Locale = .current) {
        self.init(
            locale: locale,
            audioExtractor: AVFoundationVideoAudioExtractor(),
            runtime: SystemSpeechAnalyzerRuntime()
        )
    }

    init(
        locale: Locale = .current,
        audioExtractor: any VideoAudioExtracting,
        runtime: any SpeechRecognitionRunning
    ) {
        self.locale = locale
        self.audioExtractor = audioExtractor
        self.runtime = runtime
    }

    public func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment] {
        let audioFileURL: URL
        do {
            audioFileURL = try await audioExtractor.audioFileURL(for: source.localFileURL)
        } catch let error as VideoUnderstandingError {
            throw error
        } catch {
            Log.speech.error("Audio extraction failed for \(source.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw VideoUnderstandingError.unreadableAsset(error.localizedDescription)
        }

        defer {
            try? audioExtractor.removeTemporaryAudioFile(at: audioFileURL)
        }

        do {
            let candidates = try await runtime.recognizeSegments(inAudioFileAt: audioFileURL, locale: locale)
            return Self.normalizedSegments(from: candidates)
        } catch let error as VideoUnderstandingError {
            throw error
        } catch {
            Log.speech.error("SpeechAnalyzer failed for \(source.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw VideoUnderstandingError.transcriptionUnavailable(error.localizedDescription)
        }
    }

    static func normalizedSegments(from candidates: [RecognizedSpeechSegment]) -> [TranscriptSegment] {
        var previousEnd = 0.0

        return candidates
            .map { candidate in
                RecognizedSpeechSegment(
                    startSeconds: max(0, candidate.startSeconds),
                    endSeconds: max(0, candidate.endSeconds),
                    text: candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty && $0.endSeconds > $0.startSeconds }
            .sorted {
                if $0.startSeconds == $1.startSeconds {
                    return $0.endSeconds < $1.endSeconds
                }
                return $0.startSeconds < $1.startSeconds
            }
            .compactMap { candidate in
                let start = max(candidate.startSeconds, previousEnd)
                let end = max(candidate.endSeconds, start)
                guard end > start else {
                    return nil
                }

                previousEnd = end
                return TranscriptSegment(
                    startSeconds: start,
                    endSeconds: end,
                    text: candidate.text
                )
            }
    }
}

struct RecognizedSpeechSegment: Sendable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

protocol VideoAudioExtracting: Sendable {
    func audioFileURL(for videoURL: URL) async throws -> URL
    func removeTemporaryAudioFile(at audioFileURL: URL) throws
}

extension VideoAudioExtracting {
    func removeTemporaryAudioFile(at audioFileURL: URL) throws {}
}

protocol SpeechRecognitionRunning: Sendable {
    func recognizeSegments(inAudioFileAt audioFileURL: URL, locale: Locale) async throws -> [RecognizedSpeechSegment]
}

struct AVFoundationVideoAudioExtractor: VideoAudioExtracting {
    private let temporaryDirectory: URL

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    func audioFileURL(for videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw VideoUnderstandingError.unreadableAsset(
                "Unable to inspect audio tracks for \(videoURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        guard !audioTracks.isEmpty else {
            throw VideoUnderstandingError.noAudioTrack
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw VideoUnderstandingError.unreadableAsset(
                "Unable to create Apple M4A export session for \(videoURL.lastPathComponent)"
            )
        }

        let outputURL = temporaryDirectory
            .appendingPathComponent("engram-transcription-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            try await session.export(to: outputURL, as: .m4a)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoUnderstandingError.unreadableAsset(
                "Unable to export audio track for \(videoURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    func removeTemporaryAudioFile(at audioFileURL: URL) throws {
        try FileManager.default.removeItem(at: audioFileURL)
    }
}

struct SystemSpeechAnalyzerRuntime: SpeechRecognitionRunning {
    func recognizeSegments(inAudioFileAt audioFileURL: URL, locale: Locale) async throws -> [RecognizedSpeechSegment] {
        #if targetEnvironment(simulator)
        throw VideoUnderstandingError.transcriptionUnavailable(
            "SpeechAnalyzerTranscriber is disabled on iOS Simulator; use an iOS 26 device or macOS 26 runtime."
        )
        #else
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            throw VideoUnderstandingError.transcriptionUnavailable("SpeechAnalyzer requires iOS/macOS/tvOS/visionOS 26.0 or newer.")
        }

        return try await Self.recognizeWithSpeechAnalyzer(audioFileURL: audioFileURL, locale: locale)
        #endif
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func recognizeWithSpeechAnalyzer(audioFileURL: URL, locale: Locale) async throws -> [RecognizedSpeechSegment] {
        guard SpeechTranscriber.isAvailable else {
            throw VideoUnderstandingError.transcriptionUnavailable("SpeechTranscriber.isAvailable is false on this runtime.")
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber has no supported locale equivalent for \(locale.identifier)."
            )
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .timeIndexedTranscriptionWithAlternatives)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        guard assetStatus == .installed else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber asset status for \(supportedLocale.identifier) is \(describe(assetStatus)); installed assets are required before transcription."
            )
        }

        let compatibleFormats = await transcriber.availableCompatibleAudioFormats
        guard !compatibleFormats.isEmpty else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber reported no compatible audio formats for \(supportedLocale.identifier)."
            )
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioFileURL)
        } catch {
            throw VideoUnderstandingError.unreadableAsset(
                "Unable to open exported audio for SpeechAnalyzer: \(error.localizedDescription)"
            )
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        async let collectedResults = collectFinalResults(from: transcriber)

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collectedResults
        } catch let error as VideoUnderstandingError {
            await analyzer.cancelAndFinishNow()
            throw error
        } catch {
            await analyzer.cancelAndFinishNow()
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechAnalyzer failed for \(audioFileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func collectFinalResults(from transcriber: SpeechTranscriber) async throws -> [RecognizedSpeechSegment] {
        var segments: [RecognizedSpeechSegment] = []

        for try await result in transcriber.results {
            guard result.isFinal else {
                continue
            }

            segments.append(
                RecognizedSpeechSegment(
                    startSeconds: result.range.start.seconds,
                    endSeconds: result.range.end.seconds,
                    text: String(result.text.characters)
                )
            )
        }

        return segments
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func describe(_ status: AssetInventory.Status) -> String {
        switch status {
        case .unsupported:
            return "unsupported"
        case .supported:
            return "supported"
        case .downloading:
            return "downloading"
        case .installed:
            return "installed"
        @unknown default:
            return "unknown"
        }
    }
}
