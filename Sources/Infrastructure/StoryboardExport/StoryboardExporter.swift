import Foundation
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
        try pdf(document).write(to: pdfURL, options: .atomic)

        let referenceURL = rootURL.appendingPathComponent("reference-frames", isDirectory: true)
        try fileManager.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for keyframe in keyframes {
            let name = "\(safe(keyframe.shotID.rawValue)).jpg"
            try keyframe.frame.jpegData.write(to: referenceURL.appendingPathComponent(name), options: .atomic)
            manifest[keyframe.shotID.rawValue] = name
        }
        try encoder.encode(manifest).write(to: referenceURL.appendingPathComponent("manifest.json"), options: .atomic)
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

    private func pdf(_ document: StoryboardDocumentV2) -> Data {
        let title = ascii(document.contentAnalysis.title ?? "Storyboard")
        let summary = ascii(document.contentAnalysis.summary)
        let stream = "BT /F1 18 Tf 50 760 Td (\(pdfEscape(title))) Tj 0 -28 Td /F1 11 Tf (\(pdfEscape(summary))) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func csvCell(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    private func safe(_ value: String) -> String { value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.reduce("") { $0 + String($1) } }
    private func ascii(_ value: String) -> String { value.unicodeScalars.map { $0.isASCII ? Character(String($0)) : "?" }.reduce("") { $0 + String($1) } }
    private func pdfEscape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)") }
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
                let header = (try? Data(contentsOf: artifact.url).prefix(8)) ?? Data()
                if String(decoding: header, as: UTF8.self).hasPrefix("%PDF-") == false { issues.append("invalid-pdf") }
            case .csv:
                let text = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
                if !text.hasPrefix("shot_id,start_seconds,end_seconds") { issues.append("invalid-csv") }
            case .markdown:
                let text = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
                if !text.contains(document.contentAnalysis.summary) { issues.append("invalid-markdown") }
            case .referenceFramePackage:
                if !isDirectory.boolValue || !FileManager.default.fileExists(atPath: artifact.url.appendingPathComponent("manifest.json").path) {
                    issues.append("invalid-reference-package")
                }
            }
        }
        return StoryboardExportValidation(issues: issues)
    }
}
