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

        return videoURL
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
        try await ensureAssetsInstalled(for: supportedLocale, modules: [transcriber])
        try await reserveAssets(for: supportedLocale)

        let compatibleFormats = await transcriber.availableCompatibleAudioFormats
        guard !compatibleFormats.isEmpty else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber reported no compatible audio formats for \(supportedLocale.identifier)."
            )
        }
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) ?? compatibleFormats.first else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechAnalyzer could not select a compatible audio format for \(supportedLocale.identifier)."
            )
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        async let collectedResults = collectFinalResults(from: transcriber)

        do {
            try await analyzer.prepareToAnalyze(in: analysisFormat)
            let inputSequence = SpeechAnalyzerAssetAudioInputSequence(
                mediaURL: audioFileURL,
                analysisFormat: analysisFormat
            )
            _ = try await analyzer.analyzeSequence(inputSequence)
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
    private struct SpeechAnalyzerAssetAudioInputSequence: AsyncSequence, @unchecked Sendable {
        typealias Element = AnalyzerInput

        private let mediaURL: URL
        private let analysisFormat: AVAudioFormat

        init(
            mediaURL: URL,
            analysisFormat: AVAudioFormat
        ) {
            self.mediaURL = mediaURL
            self.analysisFormat = analysisFormat
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(
                mediaURL: mediaURL,
                analysisFormat: analysisFormat
            )
        }

        struct Iterator: AsyncIteratorProtocol {
            private let mediaURL: URL
            private let analysisFormat: AVAudioFormat
            private var reader: SpeechAnalyzerAssetAudioReader?

            init(
                mediaURL: URL,
                analysisFormat: AVAudioFormat
            ) {
                self.mediaURL = mediaURL
                self.analysisFormat = analysisFormat
            }

            mutating func next() async throws -> AnalyzerInput? {
                if reader == nil {
                    reader = try await SpeechAnalyzerAssetAudioReader(
                        mediaURL: mediaURL,
                        analysisFormat: analysisFormat
                    )
                }
                return try reader?.next()
            }
        }
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private final class SpeechAnalyzerAssetAudioReader {
        private let mediaURL: URL
        private let analysisFormat: AVAudioFormat
        private let reader: AVAssetReader
        private let readerOutput: AVAssetReaderAudioMixOutput
        private var outputStartFrame: AVAudioFramePosition = 0
        private var finished = false

        init(
            mediaURL: URL,
            analysisFormat: AVAudioFormat
        ) async throws {
            self.mediaURL = mediaURL
            self.analysisFormat = analysisFormat

            let asset = AVURLAsset(url: mediaURL)
            let audioTracks: [AVAssetTrack]
            do {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                throw VideoUnderstandingError.unreadableAsset(
                    "Unable to inspect audio tracks for SpeechAnalyzer input: \(error.localizedDescription)"
                )
            }
            guard !audioTracks.isEmpty else {
                throw VideoUnderstandingError.noAudioTrack
            }

            let audioSettings = try Self.linearPCMSettings(for: analysisFormat)
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: audioSettings
            )
            readerOutput.alwaysCopiesSampleData = true
            guard reader.canAdd(readerOutput) else {
                throw VideoUnderstandingError.unreadableAsset(
                    "Unable to add SpeechAnalyzer audio reader output for \(mediaURL.lastPathComponent)."
                )
            }
            reader.add(readerOutput)
            guard reader.startReading() else {
                throw VideoUnderstandingError.unreadableAsset(
                    "Unable to start SpeechAnalyzer audio reader for \(mediaURL.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")"
                )
            }
            self.reader = reader
            self.readerOutput = readerOutput
        }

        deinit {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        func next() throws -> AnalyzerInput? {
            guard !finished else {
                return nil
            }

            while true {
                switch reader.status {
                case .reading:
                    break
                case .completed:
                    finished = true
                    return nil
                case .failed:
                    finished = true
                    throw VideoUnderstandingError.unreadableAsset(
                        "SpeechAnalyzer audio reader failed for \(mediaURL.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")"
                    )
                case .cancelled:
                    finished = true
                    throw VideoUnderstandingError.unreadableAsset(
                        "SpeechAnalyzer audio reader was cancelled for \(mediaURL.lastPathComponent)."
                    )
                case .unknown:
                    break
                @unknown default:
                    finished = true
                    throw VideoUnderstandingError.unreadableAsset("SpeechAnalyzer audio reader returned an unknown status.")
                }

                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                    switch reader.status {
                    case .reading, .completed:
                        finished = true
                        return nil
                    case .failed:
                        finished = true
                        throw VideoUnderstandingError.unreadableAsset(
                            "SpeechAnalyzer audio reader failed for \(mediaURL.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")"
                        )
                    case .cancelled:
                        finished = true
                        throw VideoUnderstandingError.unreadableAsset(
                            "SpeechAnalyzer audio reader was cancelled for \(mediaURL.lastPathComponent)."
                        )
                    default:
                        finished = true
                        return nil
                    }
                }

                let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
                guard sampleCount > 0 else {
                    continue
                }
                guard sampleCount <= Int(Int32.max) else {
                    throw VideoUnderstandingError.unreadableAsset(
                        "SpeechAnalyzer audio sample buffer is too large: \(sampleCount) frames."
                    )
                }

                let frameCount = AVAudioFrameCount(sampleCount)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: frameCount) else {
                    throw VideoUnderstandingError.transcriptionUnavailable(
                        "Unable to allocate SpeechAnalyzer audio buffer for \(Self.describe(analysisFormat))."
                    )
                }
                buffer.frameLength = frameCount

                let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sampleBuffer,
                    at: 0,
                    frameCount: Int32(sampleCount),
                    into: buffer.mutableAudioBufferList
                )
                guard copyStatus == noErr else {
                    throw VideoUnderstandingError.unreadableAsset(
                        "Unable to copy PCM audio for SpeechAnalyzer: status \(copyStatus)."
                    )
                }

                return input(from: buffer)
            }
        }

        private func input(from buffer: AVAudioPCMBuffer) -> AnalyzerInput {
            let startTime = CMTime(
                value: CMTimeValue(outputStartFrame),
                timescale: CMTimeScale(max(1, Int32(analysisFormat.sampleRate.rounded())))
            )
            outputStartFrame += AVAudioFramePosition(buffer.frameLength)
            return AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
        }

        private static func describe(_ format: AVAudioFormat) -> String {
            "\(format.commonFormat), \(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved)"
        }

        private static func linearPCMSettings(for format: AVAudioFormat) throws -> [String: Any] {
            let bitDepth: Int
            let isFloat: Bool
            switch format.commonFormat {
            case .pcmFormatFloat32:
                bitDepth = 32
                isFloat = true
            case .pcmFormatFloat64:
                bitDepth = 64
                isFloat = true
            case .pcmFormatInt16:
                bitDepth = 16
                isFloat = false
            case .pcmFormatInt32:
                bitDepth = 32
                isFloat = false
            default:
                throw VideoUnderstandingError.transcriptionUnavailable(
                    "Unsupported SpeechAnalyzer audio format \(Self.describe(format))."
                )
            }

            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVLinearPCMBitDepthKey: bitDepth,
                AVLinearPCMIsFloatKey: isFloat,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: !format.isInterleaved
            ]
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
    private static func ensureAssetsInstalled(
        for locale: Locale,
        modules: [any SpeechModule]
    ) async throws {
        let initialStatus = await AssetInventory.status(forModules: modules)
        guard initialStatus != .installed else {
            return
        }
        guard initialStatus == .supported else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber asset status for \(locale.identifier) is \(describe(initialStatus)); installed assets are required before transcription."
            )
        }

        Log.speech.info("Installing SpeechTranscriber assets for \(locale.identifier, privacy: .public)")
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: modules)
        } catch {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber asset installation request failed for \(locale.identifier): \(error.localizedDescription)"
            )
        }

        guard let request else {
            let status = await AssetInventory.status(forModules: modules)
            if status == .installed {
                return
            }
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber asset installation request was unavailable for \(locale.identifier); status is \(describe(status))."
            )
        }

        do {
            try await request.downloadAndInstall()
        } catch {
            let status = await AssetInventory.status(forModules: modules)
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber asset installation failed for \(locale.identifier); status is \(describe(status)): \(error.localizedDescription)"
            )
        }

        let finalStatus = await AssetInventory.status(forModules: modules)
        guard finalStatus == .installed else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber asset status for \(locale.identifier) is \(describe(finalStatus)) after installation."
            )
        }
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func reserveAssets(for locale: Locale) async throws {
        let reservedLocales = await AssetInventory.reservedLocales
        if reservedLocales.contains(where: { $0.identifier == locale.identifier }) {
            return
        }

        Log.speech.info("Reserving SpeechTranscriber locale \(locale.identifier, privacy: .public)")
        do {
            let reserved = try await AssetInventory.reserve(locale: locale)
            if reserved {
                return
            }
        } catch {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber locale reservation failed for \(locale.identifier): \(error.localizedDescription)"
            )
        }

        let refreshedLocales = await AssetInventory.reservedLocales
        guard refreshedLocales.contains(where: { $0.identifier == locale.identifier }) else {
            throw VideoUnderstandingError.transcriptionUnavailable(
                "SpeechTranscriber locale reservation did not activate \(locale.identifier)."
            )
        }
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
