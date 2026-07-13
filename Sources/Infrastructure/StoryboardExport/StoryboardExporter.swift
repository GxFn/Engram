import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
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
        let references = try validatedReferences(document: document, keyframes: keyframes)

        let jsonURL = rootURL.appendingPathComponent("storyboard.json")
        try encoder.encode(document).write(to: jsonURL, options: .atomic)
        let markdownURL = rootURL.appendingPathComponent("storyboard.md")
        try markdown(document).data(using: .utf8)!.write(to: markdownURL, options: .atomic)
        let csvURL = rootURL.appendingPathComponent("storyboard.csv")
        try csv(document).data(using: .utf8)!.write(to: csvURL, options: .atomic)
        let pdfURL = rootURL.appendingPathComponent("storyboard.pdf")
        try pdf(document, references: references).write(to: pdfURL, options: .atomic)

        let referenceURL = rootURL.appendingPathComponent("reference-frames", isDirectory: true)
        try fileManager.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        for reference in references {
            try reference.data.write(
                to: referenceURL.appendingPathComponent(reference.manifest.fileName),
                options: .atomic
            )
        }
        try encoder.encode(ReferenceFrameManifest(items: references.map(\.manifest)))
            .write(to: referenceURL.appendingPathComponent("manifest.json"), options: .atomic)
        return StoryboardExportBundle(rootURL: rootURL, artifacts: [
            StoryboardExportArtifact(format: .markdown, url: markdownURL),
            StoryboardExportArtifact(format: .json, url: jsonURL),
            StoryboardExportArtifact(format: .csv, url: csvURL),
            StoryboardExportArtifact(format: .pdf, url: pdfURL),
            StoryboardExportArtifact(format: .referenceFramePackage, url: referenceURL),
        ])
    }

    fileprivate func markdown(_ document: StoryboardDocumentV2) -> String {
        var lines = ["# \(document.contentAnalysis.title ?? "视频分镜")", "", document.contentAnalysis.summary, ""]
        for row in Self.rows(document) {
            lines.append("## \(row.displayNumber). \(row.segment.id.rawValue) [\(Self.seconds(row.segment.timeRange.startSeconds))s–\(Self.seconds(row.segment.timeRange.endSeconds))s]")
            lines.append("")
            lines.append(contentsOf: row.professionalLines.map { "- \($0)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    fileprivate func csv(_ document: StoryboardDocumentV2) -> String {
        let header = StoryboardExportRow.csvHeader.joined(separator: ",")
        let rows = Self.rows(document).map { row in
            row.csvValues.map(csvCell).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func pdf(_ document: StoryboardDocumentV2, references: [ValidatedReference]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(
                  consumer: consumer,
                  mediaBox: nil,
                  [kCGPDFContextTitle as String: document.contentAnalysis.title ?? "视频分镜"] as CFDictionary
              )
        else { throw StoryboardExportError.pdfCreationFailed }
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let firstReference = Dictionary(
            grouping: references,
            by: { $0.manifest.shotID }
        ).compactMapValues { $0.first }

        for row in Self.rows(document) {
            context.beginPDFPage([kCGPDFContextMediaBox as String: page] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(page)
            drawText(document.contentAnalysis.title ?? "视频分镜", in: CGRect(x: 36, y: 742, width: 540, height: 28), size: 20, context: context)
            drawText(document.contentAnalysis.summary, in: CGRect(x: 36, y: 704, width: 540, height: 34), size: 10, context: context)
            let timecode = "\(Self.seconds(row.segment.timeRange.startSeconds))s – \(Self.seconds(row.segment.timeRange.endSeconds))s"
            drawText("\(row.displayNumber). \(row.segment.id.rawValue)  \(timecode)", in: CGRect(x: 36, y: 666, width: 540, height: 24), size: 14, context: context)

            if let reference = firstReference[row.segment.id.rawValue] {
                context.draw(reference.image, in: aspectFit(reference.image, in: CGRect(x: 36, y: 510, width: 190, height: 142)))
                drawText("参考帧：\(reference.manifest.fileName)", in: CGRect(x: 250, y: 610, width: 326, height: 28), size: 9, context: context)
                drawText("参考时间：\(Self.seconds(reference.manifest.timestampSeconds))s", in: CGRect(x: 250, y: 574, width: 326, height: 28), size: 9, context: context)
            }
            drawText(
                row.professionalLines.joined(separator: "\n"),
                in: CGRect(x: 36, y: 42, width: 540, height: 455),
                size: 8,
                context: context
            )
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func validatedReferences(
        document: StoryboardDocumentV2,
        keyframes: [ShotKeyframe]
    ) throws -> [ValidatedReference] {
        let segments = Dictionary(uniqueKeysWithValues: document.shotGraph.shots.map { ($0.id, $0) })
        let order = Dictionary(uniqueKeysWithValues: document.shotGraph.shots.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = keyframes.sorted {
            let left = order[$0.shotID] ?? .max
            let right = order[$1.shotID] ?? .max
            return left == right ? $0.frame.timestampSeconds < $1.frame.timestampSeconds : left < right
        }
        var perShotCount: [ShotID: Int] = [:]
        var signatures = Set<String>()
        var references: [ValidatedReference] = []
        for keyframe in ordered {
            guard let segment = segments[keyframe.shotID],
                  keyframe.frame.timestampSeconds >= segment.timeRange.startSeconds,
                  keyframe.frame.timestampSeconds <= segment.timeRange.endSeconds,
                  let source = CGImageSourceCreateWithData(keyframe.frame.jpegData as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw StoryboardExportError.invalidReferenceFrame(keyframe.shotID.rawValue) }
            let signature = "\(keyframe.shotID.rawValue)|\(Self.seconds(keyframe.frame.timestampSeconds))"
            guard signatures.insert(signature).inserted else {
                throw StoryboardExportError.invalidReferenceFrame(keyframe.shotID.rawValue)
            }
            let index = perShotCount[keyframe.shotID, default: 0] + 1
            perShotCount[keyframe.shotID] = index
            let name = "\(safe(keyframe.shotID.rawValue))_\(Self.timecodeFileName(keyframe.frame.timestampSeconds))_\(index).jpg"
            references.append(ValidatedReference(
                manifest: ReferenceFrameManifestItem(
                    shotID: keyframe.shotID.rawValue,
                    fileName: name,
                    timestampSeconds: keyframe.frame.timestampSeconds,
                    startSeconds: segment.timeRange.startSeconds,
                    endSeconds: segment.timeRange.endSeconds
                ),
                data: keyframe.frame.jpegData,
                image: image
            ))
        }
        let missing = Set(document.shotGraph.shots.map(\.id)).subtracting(perShotCount.keys)
        guard missing.isEmpty else {
            throw StoryboardExportError.missingReferenceFrame(missing.sorted().map(\.rawValue).joined(separator: ","))
        }
        return references
    }

    private static func rows(_ document: StoryboardDocumentV2) -> [StoryboardExportRow] {
        let shots = Dictionary(uniqueKeysWithValues: document.shots.map { ($0.id, $0) })
        return document.shotGraph.shots.enumerated().map { index, segment in
            StoryboardExportRow(segment: segment, shot: shots[segment.id], fallbackDisplayNumber: index + 1)
        }
    }

    private func drawText(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.08, alpha: 1),
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func csvCell(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    private func safe(_ value: String) -> String { value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.reduce("") { $0 + String($1) } }
    fileprivate static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func timecodeFileName(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secs = (milliseconds / 1_000) % 60
        let millis = milliseconds % 1_000
        return String(format: "%02d-%02d-%02d-%03d", hours, minutes, secs, millis)
    }
}

public enum StoryboardExportError: Error, Hashable, Sendable {
    case pdfCreationFailed
    case missingReferenceFrame(String)
    case invalidReferenceFrame(String)
}

private struct ValidatedReference {
    let manifest: ReferenceFrameManifestItem
    let data: Data
    let image: CGImage
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

private struct StoryboardExportRow {
    static let csvHeader = [
        "shot_id", "start_seconds", "end_seconds", "sequence_id", "display_number", "purpose",
        "narrative_beat", "hook_role", "target_duration", "shot_size", "angle", "movement", "lens_intent",
        "subject_action", "composition", "background", "lighting_color", "props_wardrobe", "dialogue_or_vo",
        "on_screen_copy", "music_sfx", "transition", "continuity", "generation_prompt", "production_notes",
        "source_shot_refs", "confidence", "user_locked_fields", "observed_facts", "unknown_fields", "review_flags",
    ]

    let segment: ShotSegment
    let shot: StoryboardShotV2?
    let fallbackDisplayNumber: Int
    var plan: ShotProductionPlan? { shot?.productionPlan }
    var displayNumber: Int { plan?.displayNumber ?? fallbackDisplayNumber }
    var facts: String {
        shot?.observedFacts.facts.map {
            "\($0.field.rawValue): \($0.value) [\($0.evidenceIDs.map(\.rawValue).joined(separator: ";"))]"
        }.joined(separator: " | ") ?? ""
    }
    var unknownFields: String { shot?.observedFacts.unknownFields.map(\.rawValue).sorted().joined(separator: ";") ?? "" }
    var reviewFlags: String { shot?.observedFacts.reviewFlags.sorted().joined(separator: ";") ?? "" }
    var sourceRefs: String { plan?.sourceShotRefs.map(\.rawValue).joined(separator: ";") ?? "" }
    var lockedFields: String { plan?.userLockedFields.sorted().joined(separator: ";") ?? "" }

    var professionalLines: [String] {
        [
            "序列：\(value(plan?.sequenceID))",
            "目的：\(value(plan?.purpose))",
            "叙事节拍：\(value(plan?.narrativeBeat))",
            "钩子作用：\(value(plan?.hookRole))",
            "目标时长：\(number(plan?.targetDuration))",
            "景别：\(value(plan?.shotSize))",
            "角度：\(value(plan?.angle))",
            "运镜：\(value(plan?.movement))",
            "镜头意图：\(value(plan?.lensIntent))",
            "主体动作：\(value(plan?.subjectAction))",
            "构图：\(value(plan?.composition))",
            "背景：\(value(plan?.background))",
            "光色：\(value(plan?.lightingColor))",
            "道具服装：\(value(plan?.propsWardrobe))",
            "台词旁白：\(value(plan?.dialogueOrVO))",
            "屏幕文案：\(value(plan?.onScreenCopy))",
            "音乐音效：\(value(plan?.musicSFX))",
            "转场：\(value(plan?.transition))",
            "连续性：\(value(plan?.continuity))",
            "生成提示：\(value(plan?.generationPrompt))",
            "制作备注：\(value(plan?.productionNotes))",
            "来源镜头：\(sourceRefs)",
            "置信度：\(number(plan?.confidence))",
            "人工锁定：\(lockedFields)",
            "证据事实：\(facts)",
            "未知字段：\(unknownFields)",
            "复核标记：\(reviewFlags)",
        ]
    }

    var csvValues: [String] {
        [
            segment.id.rawValue,
            StoryboardExporter.seconds(segment.timeRange.startSeconds),
            StoryboardExporter.seconds(segment.timeRange.endSeconds),
            value(plan?.sequenceID),
            String(displayNumber),
            value(plan?.purpose),
            value(plan?.narrativeBeat),
            value(plan?.hookRole),
            number(plan?.targetDuration),
            value(plan?.shotSize),
            value(plan?.angle),
            value(plan?.movement),
            value(plan?.lensIntent),
            value(plan?.subjectAction),
            value(plan?.composition),
            value(plan?.background),
            value(plan?.lightingColor),
            value(plan?.propsWardrobe),
            value(plan?.dialogueOrVO),
            value(plan?.onScreenCopy),
            value(plan?.musicSFX),
            value(plan?.transition),
            value(plan?.continuity),
            value(plan?.generationPrompt),
            value(plan?.productionNotes),
            sourceRefs,
            number(plan?.confidence),
            lockedFields,
            facts,
            unknownFields,
            reviewFlags,
        ]
    }

    private func value(_ value: String?) -> String { value ?? "" }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
}

public enum StoryboardExportValidator {
    public static func validate(
        _ bundle: StoryboardExportBundle,
        document: StoryboardDocumentV2
    ) -> StoryboardExportValidation {
        var issues: [String] = []
        let formats = Set(bundle.artifacts.map(\.format))
        if bundle.artifacts.count != formats.count { issues.append("duplicate-format") }
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
                      !ExportSafetyScanner.containsSensitive(data),
                      let decoded = try? JSONDecoder().decode(StoryboardDocumentV2.self, from: data),
                      decoded == document
                else { issues.append("invalid-json"); continue }
            case .csv:
                let text = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
                let expected = StoryboardExporter().csv(document)
                guard !ExportSafetyScanner.containsSensitive(text),
                      let actualTable = CSVTable.parse(text),
                      let expectedTable = CSVTable.parse(expected),
                      actualTable == expectedTable
                else { issues.append("invalid-csv"); continue }
            case .markdown:
                let text = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
                let expected = StoryboardExporter().markdown(document)
                guard !ExportSafetyScanner.containsSensitive(text),
                      MarkdownStoryboard.parse(text) == MarkdownStoryboard.parse(expected)
                else { issues.append("invalid-markdown"); continue }
            case .pdf:
                guard let pdf = PDFDocument(url: artifact.url),
                      pdf.pageCount == document.shots.count,
                      ((try? Data(contentsOf: artifact.url).count) ?? 0) > 1_000,
                      validatePDF(pdf, document: document)
                else { issues.append("invalid-pdf"); continue }
            case .referenceFramePackage:
                if !validateReferences(at: artifact.url, isDirectory: isDirectory.boolValue, document: document) {
                    issues.append("invalid-reference-package")
                }
            }
        }
        return StoryboardExportValidation(issues: issues)
    }

    private static func validatePDF(_ pdf: PDFDocument, document: StoryboardDocumentV2) -> Bool {
        let rows = document.shotGraph.shots.enumerated().map { index, segment in
            let shot = document.shots.first { $0.id == segment.id }
            return StoryboardExportRow(segment: segment, shot: shot, fallbackDisplayNumber: index + 1)
        }
        guard rows.count == pdf.pageCount else { return false }
        for (index, row) in rows.enumerated() {
            guard let text = pdf.page(at: index)?.string else { return false }
            let searchableText = normalizedPDFText(text)
            let structuredLines = row.professionalLines.filter({ !$0.hasPrefix("证据事实：") })
            guard
                  !ExportSafetyScanner.containsSensitive(text),
                  searchableText.contains(row.segment.id.rawValue),
                  searchableText.contains(StoryboardExporter.seconds(row.segment.timeRange.startSeconds)),
                  searchableText.contains(StoryboardExporter.seconds(row.segment.timeRange.endSeconds)),
                  structuredLines.allSatisfy({ line in
                      let value = line.split(separator: "：", maxSplits: 1).last.map(String.init) ?? ""
                      return value.isEmpty || searchableText.contains(normalizedPDFText(value))
                  }),
                  row.shot?.observedFacts.facts.allSatisfy({
                      searchableText.contains(normalizedPDFText($0.value))
                  }) != false
            else { return false }
        }
        return true
    }

    private static func normalizedPDFText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func validateReferences(
        at root: URL,
        isDirectory: Bool,
        document: StoryboardDocumentV2
    ) -> Bool {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard isDirectory,
              let data = try? Data(contentsOf: manifestURL),
              !ExportSafetyScanner.containsSensitive(data),
              let manifest = try? JSONDecoder().decode(ReferenceFrameManifest.self, from: data)
        else { return false }
        let segments = Dictionary(uniqueKeysWithValues: document.shotGraph.shots.map { ($0.id.rawValue, $0) })
        let fileNames = manifest.items.map(\.fileName)
        let signatures = manifest.items.map { "\($0.shotID)|\(StoryboardExporter.seconds($0.timestampSeconds))" }
        guard Set(fileNames).count == fileNames.count,
              Set(signatures).count == signatures.count,
              Set(manifest.items.map(\.shotID)) == Set(segments.keys),
              manifest.items.allSatisfy({ item in
                  guard let segment = segments[item.shotID],
                        item.fileName == URL(fileURLWithPath: item.fileName).lastPathComponent,
                        !item.fileName.contains(".."),
                        abs(item.startSeconds - segment.timeRange.startSeconds) < 0.000_001,
                        abs(item.endSeconds - segment.timeRange.endSeconds) < 0.000_001,
                        item.timestampSeconds >= segment.timeRange.startSeconds,
                        item.timestampSeconds <= segment.timeRange.endSeconds,
                        let bytes = try? Data(contentsOf: root.appendingPathComponent(item.fileName)),
                        let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                        CGImageSourceGetCount(source) > 0,
                        CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
                  else { return false }
                  return true
              })
        else { return false }
        let actualFiles = ((try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.lastPathComponent != "manifest.json" }
            .map(\.lastPathComponent)
        return Set(actualFiles) == Set(fileNames) && actualFiles.count == fileNames.count
    }
}

private enum ExportSafetyScanner {
    static func containsSensitive(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return containsSensitive(text)
    }

    static func containsSensitive(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "authorization:", "bearer ", "api_key", "api-key", "signedurl", "signed_url",
            "x-amz-signature", "x-tos-signature", "sk-", "/users/", "/private/var/",
            "/var/mobile/containers/", ":\\users\\",
        ]
        return markers.contains { lowered.contains($0) }
    }
}

private enum CSVTable {
    static func parse(_ text: String) -> [[String]]? {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if inQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    inQuotes.toggle()
                }
            } else if character == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if character == "\n", !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" || inQuotes {
                field.append(character)
            }
            index = text.index(after: index)
        }
        guard !inQuotes else { return nil }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private struct MarkdownStoryboard: Equatable {
    let preamble: [String]
    let sections: [String: [String]]

    static func parse(_ text: String) -> MarkdownStoryboard? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var preamble: [String] = []
        var sections: [String: [String]] = [:]
        var currentID: String?
        for line in lines {
            if line.hasPrefix("## ") {
                let components = line.dropFirst(3).split(separator: " ", maxSplits: 2)
                guard components.count >= 2 else { return nil }
                let id = String(components[1])
                guard sections[id] == nil else { return nil }
                currentID = id
                sections[id] = [line]
            } else if let currentID {
                sections[currentID, default: []].append(line)
            } else {
                preamble.append(line)
            }
        }
        guard !sections.isEmpty else { return nil }
        return MarkdownStoryboard(preamble: preamble, sections: sections)
    }
}
