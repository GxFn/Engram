import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import StoryboardCore
import StoryboardExport
import Testing
import UniformTypeIdentifiers
import VideoUnderstanding

@Test func exporterWritesAndValidatesFiveRealFormats() throws {
    let retainedPath = ProcessInfo.processInfo.environment["ENGRAM_EXPORT_EVIDENCE_DIR"]
    let output = retainedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("EngramStoryboardExportTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        if retainedPath == nil { try? FileManager.default.removeItem(at: output) }
    }
    try? FileManager.default.removeItem(at: output)
    let document = try exportDocument()
    let keyframe = ShotKeyframe(
        shotID: document.shots[0].id,
        frame: SampledFrame(timestampSeconds: 0.5, jpegData: try makeJPEG()),
        artifactRef: "shots/S001/representative.jpg"
    )

    let bundle = try StoryboardExporter().export(document, keyframes: [keyframe], to: output)
    let report = StoryboardExportValidator.validate(bundle, document: document)

    #expect(bundle.artifacts.count == 5)
    #expect(Set(bundle.artifacts.map(\.format)) == Set(StoryboardExportFormat.allCases))
    #expect(report.isValid)
    #expect(report.issues.isEmpty)
}

@Test func exporterIncludesEveryProfessionalFieldInHumanReadableFormats() throws {
    let root = exportRoot("professional-fields")
    defer { try? FileManager.default.removeItem(at: root) }
    let document = try exportDocument(shotCount: 1, marker: "primary")
    let bundle = try StoryboardExporter().export(
        document,
        keyframes: try exportKeyframes(for: document),
        to: root
    )

    let markdown = try String(contentsOf: artifactURL(.markdown, in: bundle), encoding: .utf8)
    let csv = try String(contentsOf: artifactURL(.csv, in: bundle), encoding: .utf8)
    let pdf = try #require(PDFDocument(url: artifactURL(.pdf, in: bundle))?.string)

    let markers = professionalFieldMarkers(prefix: "primary", index: 1)
    let missingMarkdown = markers.filter { !markdown.contains($0) }
    let missingCSV = markers.filter { !csv.contains($0) }
    let missingPDF = markers.filter { !pdf.contains($0) }
    #expect(missingMarkdown.isEmpty, "Markdown omitted: \(missingMarkdown)")
    #expect(missingCSV.isEmpty, "CSV omitted: \(missingCSV)")
    #expect(missingPDF.isEmpty, "PDF omitted: \(missingPDF)")
}

@Test func validatorRejectsPerShotMappingRemovedFromMarkdownCSVAndPDF() throws {
    let root = exportRoot("tampered-mappings")
    let foreignRoot = exportRoot("foreign-pdf")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: foreignRoot)
    }
    let document = try exportDocument(shotCount: 2, marker: "primary")
    let bundle = try StoryboardExporter().export(
        document,
        keyframes: try exportKeyframes(for: document),
        to: root
    )
    let foreign = try exportDocument(shotCount: 2, marker: "foreign", idPrefix: "X")
    let foreignBundle = try StoryboardExporter().export(
        foreign,
        keyframes: try exportKeyframes(for: foreign),
        to: foreignRoot
    )

    let ids = document.shots.map(\.id.rawValue)
    let summary = document.contentAnalysis.summary
    let markdown = "# Kept title\n\n\(summary)\n\n## 1. \(ids[0]) [99s–100s]\n\n## 2. \(ids[1]) [101s–102s]\n"
    try markdown.write(to: artifactURL(.markdown, in: bundle), atomically: true, encoding: .utf8)
    let csv = "shot_id,start_seconds,end_seconds,purpose,subject_action,dialogue_or_vo\n"
        + "\(ids[1]),99,100,wrong,wrong,wrong\n"
        + "\(ids[0]),101,102,wrong,wrong,wrong\n"
    try csv.write(to: artifactURL(.csv, in: bundle), atomically: true, encoding: .utf8)
    let pdfURL = try artifactURL(.pdf, in: bundle)
    try FileManager.default.removeItem(at: pdfURL)
    try FileManager.default.copyItem(at: artifactURL(.pdf, in: foreignBundle), to: pdfURL)

    let report = StoryboardExportValidator.validate(bundle, document: document)

    #expect(!report.isValid)
    #expect(report.issues.contains("invalid-markdown"))
    #expect(report.issues.contains("invalid-csv"))
    #expect(report.issues.contains("invalid-pdf"))
}

@Test func validatorRejectsSecretsAndAbsolutePathsInExportArtifacts() throws {
    let root = exportRoot("sensitive-content")
    defer { try? FileManager.default.removeItem(at: root) }
    let document = try exportDocument(shotCount: 1, marker: "sensitive")
    let bundle = try StoryboardExporter().export(
        document,
        keyframes: try exportKeyframes(for: document),
        to: root
    )
    let markdownURL = try artifactURL(.markdown, in: bundle)
    let original = try String(contentsOf: markdownURL, encoding: .utf8)
    try (original + "\nAuthorization: Bearer sk-live-secret\n/Users/alice/private/source.mov\n")
        .write(to: markdownURL, atomically: true, encoding: .utf8)

    let report = StoryboardExportValidator.validate(bundle, document: document)

    #expect(!report.isValid)
}

@Test func validatorRejectsDuplicateReferenceManifestEntries() throws {
    let root = exportRoot("duplicate-manifest")
    defer { try? FileManager.default.removeItem(at: root) }
    let document = try exportDocument(shotCount: 2, marker: "duplicate")
    let bundle = try StoryboardExporter().export(
        document,
        keyframes: try exportKeyframes(for: document),
        to: root
    )
    let manifestURL = try artifactURL(.referenceFramePackage, in: bundle)
        .appendingPathComponent("manifest.json")
    let manifestData = try Data(contentsOf: manifestURL)
    var object = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    var items = try #require(object["items"] as? [[String: Any]])
    items.append(try #require(items.first))
    object["items"] = items
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL)

    let report = StoryboardExportValidator.validate(bundle, document: document)

    #expect(!report.isValid)
    #expect(report.issues.contains("invalid-reference-package"))
}

@Test func validatorRejectsJPEGHeaderWithoutDecodableReferenceImage() throws {
    let root = exportRoot("corrupt-reference")
    defer { try? FileManager.default.removeItem(at: root) }
    let document = try exportDocument(shotCount: 1, marker: "corrupt")
    let bundle = try StoryboardExporter().export(
        document,
        keyframes: try exportKeyframes(for: document),
        to: root
    )
    let referenceRoot = try artifactURL(.referenceFramePackage, in: bundle)
    let manifestData = try Data(contentsOf: referenceRoot.appendingPathComponent("manifest.json"))
    let object = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    let items = try #require(object["items"] as? [[String: Any]])
    let first = try #require(items.first)
    let fileName = try #require(first["fileName"] as? String)
    try Data([0xff, 0xd8, 0x00, 0x00]).write(to: referenceRoot.appendingPathComponent(fileName))

    let report = StoryboardExportValidator.validate(bundle, document: document)

    #expect(!report.isValid)
    #expect(report.issues.contains("invalid-reference-package"))
}

private func exportDocument(
    shotCount: Int = 1,
    marker: String = "baseline",
    idPrefix: String = "S"
) throws -> StoryboardDocumentV2 {
    let asset = VideoAssetDescriptor(
        sourceID: "export-\(marker)", durationSeconds: Double(shotCount), nominalFrameRate: 30, frameCount: shotCount * 30,
        width: 720, height: 1280, timescale: 600, codec: "h264", hasAudio: false,
        fileSizeBytes: 4, fingerprint: SourceFingerprint(value: "export-\(marker)")
    )
    let ids = (0..<shotCount).map { ShotID(rawValue: String(format: "%@%03d", idPrefix, $0 + 1)) }
    let graph = try ShotGraph(asset: asset, shots: ids.enumerated().map { index, id in
        ShotSegment(
            id: id,
            timeRange: MediaTimeRange(startSeconds: Double(index), endSeconds: Double(index + 1)),
            frameRange: FrameRange(startFrame: index * 30, endFrameExclusive: (index + 1) * 30),
            transitionIn: index == 0 ? .start : .cut,
            transitionOut: index == shotCount - 1 ? .end : .cut,
            boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:\(id.rawValue)"]
        )
    })
    return StoryboardDocumentV2(
        id: "export-document-\(marker)",
        source: StoryboardSource(
            sourceID: "export-\(marker)", runID: "run-export-\(marker)", schemaVersion: 2,
            pipelineVersion: "v2", mode: .faithful, actualCloudMode: .local,
            mediaUploaded: false
        ),
        shotGraph: graph,
        shots: ids.enumerated().map { index, id in
            let number = index + 1
            let prefix = "\(marker)-\(number)"
            return StoryboardShotV2(
                id: id,
                observedFacts: ObservedShotFacts(facts: [GroundedFact(
                    field: .action,
                    value: "\(prefix)-observed-fact",
                    evidenceIDs: [EvidenceID(rawValue: "\(prefix)-evidence")],
                    source: .user,
                    confidence: 1
                )]),
                productionPlan: ShotProductionPlan(
                    shotID: id,
                    sequenceID: "\(prefix)-sequence",
                    displayNumber: number,
                    purpose: "\(prefix)-purpose",
                    narrativeBeat: "\(prefix)-narrative-beat",
                    hookRole: "\(prefix)-hook-role",
                    targetDuration: 3.25,
                    shotSize: "\(prefix)-shot-size",
                    angle: "\(prefix)-angle",
                    movement: "\(prefix)-movement",
                    lensIntent: "\(prefix)-lens-intent",
                    subjectAction: "\(prefix)-subject-action",
                    composition: "\(prefix)-composition",
                    background: "\(prefix)-background",
                    lightingColor: "\(prefix)-lighting-color",
                    propsWardrobe: "\(prefix)-props-wardrobe",
                    dialogueOrVO: "\(prefix)-dialogue",
                    onScreenCopy: "\(prefix)-on-screen-copy",
                    musicSFX: "\(prefix)-music-sfx",
                    transition: "\(prefix)-transition",
                    continuity: "\(prefix)-continuity",
                    generationPrompt: "\(prefix)-generation-prompt",
                    productionNotes: "\(prefix)-production-notes",
                    sourceShotRefs: [id],
                    confidence: 0.87,
                    userLockedFields: ["dialogueOrVO"],
                    isDerivedCreativePlan: true
                )
            )
        },
        contentAnalysis: ContentAnalysis(
            title: "导出测试 \(marker)",
            summary: "五类导出 \(marker)",
            referencedShotIDs: ids
        )
    )
}

private func professionalFieldMarkers(prefix: String, index: Int) -> [String] {
    let value = "\(prefix)-\(index)"
    return [
        "\(value)-sequence",
        "\(value)-purpose",
        "\(value)-narrative-beat",
        "\(value)-hook-role",
        "\(value)-shot-size",
        "\(value)-angle",
        "\(value)-movement",
        "\(value)-lens-intent",
        "\(value)-subject-action",
        "\(value)-composition",
        "\(value)-background",
        "\(value)-lighting-color",
        "\(value)-props-wardrobe",
        "\(value)-dialogue",
        "\(value)-on-screen-copy",
        "\(value)-music-sfx",
        "\(value)-transition",
        "\(value)-continuity",
        "\(value)-generation-prompt",
        "\(value)-production-notes",
        "\(value)-observed-fact",
    ]
}

private func exportKeyframes(for document: StoryboardDocumentV2) throws -> [ShotKeyframe] {
    let jpeg = try makeJPEG()
    return document.shotGraph.shots.map { shot in
        ShotKeyframe(
            shotID: shot.id,
            frame: SampledFrame(
                timestampSeconds: (shot.timeRange.startSeconds + shot.timeRange.endSeconds) / 2,
                jpegData: jpeg
            ),
            artifactRef: "shots/\(shot.id.rawValue)/representative.jpg"
        )
    }
}

private func makeJPEG() throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: 4,
        height: 4,
        bitsPerComponent: 8,
        bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw StoryboardExportTestError.imageEncoding }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    guard let image = context.makeImage() else { throw StoryboardExportTestError.imageEncoding }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else { throw StoryboardExportTestError.imageEncoding }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw StoryboardExportTestError.imageEncoding }
    return data as Data
}

private func artifactURL(
    _ format: StoryboardExportFormat,
    in bundle: StoryboardExportBundle
) throws -> URL {
    guard let artifact = bundle.artifacts.first(where: { $0.format == format }) else {
        throw StoryboardExportTestError.missingArtifact(format)
    }
    return artifact.url
}

private func exportRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramStoryboardExportTests-\(label)-\(UUID().uuidString)", isDirectory: true)
}

private enum StoryboardExportTestError: Error {
    case imageEncoding
    case missingArtifact(StoryboardExportFormat)
}
