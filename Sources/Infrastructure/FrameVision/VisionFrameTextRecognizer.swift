import CoreGraphics
import EngramLogging
import Foundation
import ImageIO
import VideoUnderstanding
#if canImport(Vision)
import Vision
#endif

/// Deterministic on-screen text (烧录字幕 / 关键文字) extraction via Apple Vision OCR. Samples the
/// video at a fixed cadence — dense enough that caption changes aren't missed — OCRs each frame in
/// Chinese + English, and drops consecutive duplicate captions. Runs on-device (Neural Engine),
/// independent of the VLM, so the text is captured in both 云端 and 本地 modes and never depends on
/// the model choosing to read it. Never throws: returns [] on any failure so 拆解 still proceeds.
public struct VisionFrameTextRecognizer: FrameTextRecognizing {
    private let assetService: any FrameAssetServicing
    private let sampleEverySeconds: Double
    private let maxSamples: Int

    public init() {
        self.init(assetService: AVFoundationFrameAssetService())
    }

    init(
        assetService: any FrameAssetServicing,
        sampleEverySeconds: Double = 1.5,
        maxSamples: Int = 40
    ) {
        self.assetService = assetService
        self.sampleEverySeconds = max(0.3, sampleEverySeconds)
        self.maxSamples = max(1, maxSamples)
    }

    public func recognizeText(in source: VideoSource) async -> [FrameText] {
        #if canImport(Vision)
        do {
            let duration = try await assetService.durationSeconds(for: source.localFileURL)
            guard duration.isFinite, duration > 0 else { return [] }

            let count = min(maxSamples, max(1, Int((duration / sampleEverySeconds).rounded(.up))))
            let timestamps = (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
            let frames = try await assetService.sampleFrames(at: timestamps, from: source.localFileURL)

            var texts: [FrameText] = []
            for frame in frames {
                guard let cgImage = Self.decode(frame.jpegData) else { continue }
                let lines = Self.recognize(cgImage)
                guard !lines.isEmpty else { continue }
                texts.append(FrameText(timestampSeconds: frame.timestampSeconds, lines: lines))
            }
            return Self.deduped(texts)
        } catch {
            Log.frameVision.warning(
                "On-screen text OCR failed for \(source.id, privacy: .public); continuing without captions: \(String(describing: error), privacy: .public)"
            )
            return []
        }
        #else
        return []
        #endif
    }

    private static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    #if canImport(Vision)
    private static func recognize(_ cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }
    #endif

    /// Drops frames whose text equals (normalized) the previously kept frame's — a caption held
    /// across several frames appears once, at its first occurrence. Non-consecutive re-appearances
    /// are kept, so genuinely distinct captions are never lost.
    static func deduped(_ texts: [FrameText]) -> [FrameText] {
        var result: [FrameText] = []
        var previousKey: String?
        for text in texts.sorted(by: { $0.timestampSeconds < $1.timestampSeconds }) {
            let key = normalizedKey(text.lines)
            if key == previousKey { continue }
            previousKey = key
            result.append(text)
        }
        return result
    }

    static func normalizedKey(_ lines: [String]) -> String {
        lines.joined(separator: "|")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
