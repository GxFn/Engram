import ScriptCore
import SwiftUI

/// A saved cross-video insight report: sections with an evidence trail back to the source clips.
struct InsightReportView: View {
    let report: InsightReport
    let titleForClip: (String) -> String?
    let onEvidenceSelected: (String) -> Void

    var body: some View {
        List {
            Section {
                Text(report.scopeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(report.sourceCount) 条 · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(report.sections) { section in
                Section(section.heading) {
                    Text(section.body)
                        .textSelection(.enabled)
                    if !section.evidenceClipIDs.isEmpty {
                        evidence(section.evidenceClipIDs)
                    }
                }
            }
        }
        .navigationTitle(report.title)
    }

    private func evidence(_ clipIDs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("证据")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(clipIDs.enumerated()), id: \.offset) { _, clipID in
                Button {
                    onEvidenceSelected(clipID)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "film.stack")
                        Text(titleForClip(clipID) ?? "来源")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}
