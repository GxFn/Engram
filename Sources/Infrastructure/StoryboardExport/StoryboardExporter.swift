import Foundation
import CoreGraphics
import CoreText
import ImageIO
import StoryboardCore
import VideoUnderstanding

public enum StoryboardExportFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case markdown
    case json
    case csv
    case pdf
    case referenceFramePackage
}

public struct StoryboardExportArtifact: Codable, Hashable, Sendable {
    public let format: StoryboardExportFormat
    public let url: URL
}

public struct StoryboardExportBundle: Codable, Hashable, Sendable {
    public let rootURL: URL
    public let artifacts: [StoryboardExportArtifact]
}

public struct StoryboardExportValidation: Hashable, Sendable {
    public let issues: [String]
    public var isValid: Bool { issues.isEmpty }
}

public struct StoryboardExporter: Sendable {
    public init() {}

    public func export(
        _ document: StoryboardDocumentV2,
        keyframes: [ShotKeyframe],
        to rootURL: URL
    ) throws -> StoryboardExportBundle {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let jsonURL = rootURL.appendingPathComponent("storyboard.json")
        try encoder.encode(document).write(to: jsonURL, options: .atomic)
        let markdownURL = rootURL.appendingPathComponent("storyboard.md")
        try markdown(document).data(using: .utf8)!.write(to: markdownURL, options: .atomic)
        let csvURL = rootURL.appendingPathComponent("storyboard.csv")
        try csv(document).data(using: .utf8)!.write(to: csvURL, options: .atomic)
        let pdfURL = rootURL.appendingPathComponent("storyboard.pdf")
        try pdf(document, keyframes: keyframes).write(to: pdfURL, options: .atomic)

        let referenceURL = rootURL.appendingPathComponent("reference-frames", isDirectory: true)
        try fileManager.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        var manifest: [ReferenceFrameManifestItem] = []
        for keyframe in keyframes {
            let name = "\(safe(keyframe.shotID.rawValue)).jpg"
            try keyframe.frame.jpegData.write(to: referenceURL.appendingPathComponent(name), options: .atomic)
            guard let segment = document.shotGraph.shots.first(where: { $0.id == keyframe.shotID }) else { continue }
            manifest.append(ReferenceFrameManifestItem(
                shotID: keyframe.shotID.rawValue,
                fileName: name,
                timestampSeconds: keyframe.frame.timestampSeconds,
                startSeconds: segment.timeRange.startSeconds,
                endSeconds: segment.timeRange.endSeconds
            ))
        }
        try encoder.encode(ReferenceFrameManifest(items: manifest.sorted { $0.shotID < $1.shotID }))
            .write(to: referenceURL.appendingPathComponent("manifest.json"), options: .atomic)
        return StoryboardExportBundle(rootURL: rootURL, artifacts: [
            StoryboardExportArtifact(format: .markdown, url: markdownURL),
            StoryboardExportArtifact(format: .json, url: jsonURL),
            StoryboardExportArtifact(format: .csv, url: csvURL),
            StoryboardExportArtifact(format: .pdf, url: pdfURL),
            StoryboardExportArtifact(format: .referenceFramePackage, url: referenceURL),
        ])
    }

    private func markdown(_ document: StoryboardDocumentV2) -> String {
        var lines = ["# \(document.contentAnalysis.title ?? "视频分镜")", "", document.contentAnalysis.summary, ""]
        for (index, segment) in document.shotGraph.shots.enumerated() {
            let plan = document.shots.first { $0.id == segment.id }?.productionPlan
            lines.append("## \(index + 1). \(segment.id.rawValue) [\(segment.timeRange.startSeconds)s–\(segment.timeRange.endSeconds)s]")
            lines.append("")
            lines.append("- 目的：\(plan?.purpose ?? "待确认")")
            lines.append("- 画面：\(plan?.subjectAction ?? "待确认")")
            lines.append("- 台词：\(plan?.dialogueOrVO ?? "无")")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func csv(_ document: StoryboardDocumentV2) -> String {
        var rows = ["shot_id,start_seconds,end_seconds,purpose,subject_action,dialogue_or_vo"]
        for segment in document.shotGraph.shots {
            let plan = document.shots.first { $0.id == segment.id }?.productionPlan
            rows.append([
                segment.id.rawValue,
                String(segment.timeRange.startSeconds),
                String(segment.timeRange.endSeconds),
                plan?.purpose ?? "", plan?.subjectAction ?? "", plan?.dialogueOrVO ?? "",
            ].map(csvCell).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func pdf(_ document: StoryboardDocumentV2, keyframes: [ShotKeyframe]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(
                  consumer: consumer,
                  mediaBox: nil,
                  [
                      kCGPDFContextTitle as String: document.contentAnalysis.title ?? "视频分镜",
                      kCGPDFContextSubject as String: document.shotGraph.shots.map(\.id.rawValue).joined(separator: ","),
                  ] as CFDictionary
              )
        else { throw StoryboardExportError.pdfCreationFailed }
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let frames = Dictionary(uniqueKeysWithValues: keyframes.map { ($0.shotID, $0.frame.jpegData) })

        for chunkStart in stride(from: 0, to: document.shotGraph.shots.count, by: 3) {
            context.beginPDFPage([kCGPDFContextMediaBox as String: page] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(page)
            drawText(document.contentAnalysis.title ?? "视频分镜", in: CGRect(x: 36, y: 742, width: 540, height: 28), size: 20, context: context)
            drawText(document.contentAnalysis.summary, in: CGRect(x: 36, y: 704, width: 540, height: 34), size: 10, context: context)

            for offset in 0..<3 {
                let index = chunkStart + offset
                guard document.shotGraph.shots.indices.contains(index) else { continue }
                let segment = document.shotGraph.shots[index]
                let shot = document.shots.first { $0.id == segment.id }
                let bottom = 474 - CGFloat(offset) * 214
                context.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
                context.stroke(CGRect(x: 36, y: bottom, width: 540, height: 198))
                if let bytes = frames[segment.id],
                   let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    context.draw(image, in: aspectFit(image, in: CGRect(x: 46, y: bottom + 12, width: 190, height: 142)))
                }
                let timecode = String(format: "%.2fs – %.2fs", segment.timeRange.startSeconds, segment.timeRange.endSeconds)
                drawText("\(index + 1). \(segment.id.rawValue)  \(timecode)", in: CGRect(x: 250, y: bottom + 164, width: 314, height: 22), size: 13, context: context)
                drawText("目的：\(shot?.productionPlan?.purpose ?? "待确认")", in: CGRect(x: 250, y: bottom + 132, width: 314, height: 28), size: 10, context: context)
                drawText("画面：\(shot?.productionPlan?.subjectAction ?? "待确认")", in: CGRect(x: 250, y: bottom + 90, width: 314, height: 38), size: 10, context: context)
                drawText("台词：\(shot?.productionPlan?.dialogueOrVO ?? "无")", in: CGRect(x: 250, y: bottom + 48, width: 314, height: 38), size: 10, context: context)
                let facts = shot?.observedFacts.facts.prefix(2).map { "\($0.field.rawValue): \($0.value)" }.joined(separator: "；") ?? ""
                drawText("证据事实：\(facts)", in: CGRect(x: 250, y: bottom + 12, width: 314, height: 32), size: 9, context: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func drawText(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.08, alpha: 1),
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, context)
    }

    private func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func csvCell(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    private func safe(_ value: String) -> String { value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.reduce("") { $0 + String($1) } }
}

public enum StoryboardExportError: Error, Hashable, Sendable {
    case pdfCreationFailed
}

private struct ReferenceFrameManifest: Codable {
    let items: [ReferenceFrameManifestItem]
}

private struct ReferenceFrameManifestItem: Codable {
    let shotID: String
    let fileName: String
    let timestampSeconds: Double
    let startSeconds: Double
    let endSeconds: Double
}

public enum StoryboardExportValidator {
    public static func validate(
        _ bundle: StoryboardExportBundle,
        document: StoryboardDocumentV2
    ) -> StoryboardExportValidation {
        var issues: [String] = []
        let formats = Set(bundle.artifacts.map(\.format))
        for format in StoryboardExportFormat.allCases where !formats.contains(format) {
            issues.append("missing-format:\(format.rawValue)")
        }
        for artifact in bundle.artifacts {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: artifact.url.path, isDirectory: &isDirectory) else {
                issues.append("missing-artifact:\(artifact.format.rawValue)")
                continue
            }
            switch artifact.format {
            case .json:
                guard let data = try? Data(contentsOf: artifact.url),
                      let decoded = try? JSONDecoder().decode(StoryboardDocumentV2.self, from: data),
                      decoded.id == document.id
                else { issues.append("invalid-json"); continue }
            case .pdf:
                guard let provider = CGDataProvider(url: artifact.url as CFURL),
                      let pdf = CGPDFDocument(provider),
                      pdf.numberOfPages == max(1, Int(ceil(Double(document.shots.count) / 3))),
                      ((try? Data(contentsOf: artifact.url).count) ?? 0) > 1_000
                else { issues.append("invalid-pdf"); continue }
            case .csv:
                let text = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
                if !text.hasPrefix("shot_id,start_seconds,end_seconds") || text.split(separator: "\n").count != document.shots.count + 1 {
                    issues.append("invalid-csv")
                }
            case .markdown:
                let text = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
                if !text.contains(document.contentAnalysis.summary)
                    || !document.shotGraph.shots.allSatisfy({ text.contains($0.id.rawValue) }) {
                    issues.append("invalid-markdown")
                }
            case .referenceFramePackage:
                let manifestURL = artifact.url.appendingPathComponent("manifest.json")
                guard isDirectory.boolValue,
                      let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(ReferenceFrameManifest.self, from: data),
                      Set(manifest.items.map(\.shotID)) == Set(document.shots.map(\.id.rawValue)),
                      manifest.items.allSatisfy({ item in
                          !item.fileName.contains("/")
                              && item.timestampSeconds >= item.startSeconds
                              && item.timestampSeconds <= item.endSeconds
                              && ((try? Data(contentsOf: artifact.url.appendingPathComponent(item.fileName)))?.starts(with: [0xff, 0xd8]) ?? false)
                      })
                else { issues.append("invalid-reference-package"); continue }
            }
        }
        return StoryboardExportValidation(issues: issues)
    }
}
