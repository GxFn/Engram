import ScriptCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A saved 剧本范式: the structural skeleton + key elements + sources (看), and applying it to a new
/// topic to get a fresh script scaffold (用). Applying is judgment assistance — a text scaffold you
/// can copy into 豆包/即梦 — not video generation.
struct ParadigmDetailView: View {
    let paradigm: ScriptParadigm
    let titleForClip: (String) -> String?
    let onOpenSource: (String) -> Void
    let apply: (String) async -> String?

    @State private var topic = ""
    @State private var scaffold: String?
    @State private var isApplying = false

    var body: some View {
        List {
            Section {
                if !paradigm.applicableScene.isEmpty {
                    Text(paradigm.applicableScene)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                Text("\(paradigm.sourceClipIDs.count) 条剧本 · \(paradigm.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("结构骨架") {
                ForEach(paradigm.beats) { beat in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(beat.stage).font(.subheadline.weight(.semibold))
                        Text(beat.pattern).font(.subheadline).textSelection(.enabled)
                        if !beat.note.isEmpty {
                            Text(beat.note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !paradigm.keyElements.isEmpty {
                Section("关键要素") {
                    Text(paradigm.keyElements.joined(separator: "、"))
                        .textSelection(.enabled)
                }
            }

            if !paradigm.sourceClipIDs.isEmpty {
                Section("来源") {
                    ForEach(Array(paradigm.sourceClipIDs.enumerated()), id: \.offset) { _, clipID in
                        Button {
                            onOpenSource(clipID)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "film.stack")
                                Text(titleForClip(clipID) ?? "来源").lineLimit(1).truncationMode(.middle)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                TextField("输入你的新主题，如：大学生租房避坑", text: $topic, axis: .vertical)
                    .lineLimit(1 ... 3)

                Button {
                    Task {
                        isApplying = true
                        scaffold = await apply(topic)
                        isApplying = false
                    }
                } label: {
                    if isApplying {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("套用中…")
                        }
                    } else {
                        Label("按范式生成剧本骨架", systemImage: "wand.and.stars")
                    }
                }
                .disabled(isApplying || topic.trimmingCharacters(in: .whitespaces).isEmpty)

                if let scaffold {
                    Text(scaffold)
                        .font(.callout)
                        .textSelection(.enabled)
                    #if os(iOS)
                    Button {
                        UIPasteboard.general.string = scaffold
                    } label: {
                        Label("复制骨架", systemImage: "doc.on.doc")
                    }
                    #endif
                }
            } header: {
                Text("套用到新主题")
            } footer: {
                Text("判断力辅助：套用范式给你一版可拍的剧本骨架，不生成视频。可复制去豆包/即梦生成。")
            }
        }
        .navigationTitle(paradigm.name)
    }
}
