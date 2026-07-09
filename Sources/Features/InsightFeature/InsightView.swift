import ScriptCore
import SwiftUI

/// 洞察 tab (v6, reworked): two focused pages — 洞察 (pick 分镜剧本 → distill a 剧本范式) and 范式
/// (the saved paradigms, viewed and applied to a new topic). The insight object is the breakdown
/// script; the product is a reusable, applicable paradigm.
public struct InsightView: View {
    private enum Mode: Hashable {
        case distill
        case paradigms
    }

    @State private var viewModel: InsightViewModel
    @State private var mode: Mode = .distill
    @State private var presentedParadigm: ScriptParadigm?
    private let onOpenBreakdown: @MainActor (String) -> Void

    public init(
        viewModel: InsightViewModel,
        onOpenBreakdown: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onOpenBreakdown = onOpenBreakdown
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("视图", selection: $mode) {
                Text("洞察").tag(Mode.distill)
                Text("范式").tag(Mode.paradigms)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            switch mode {
            case .distill: distill
            case .paradigms: paradigmLibrary
            }
        }
        .navigationTitle("洞察")
        .task { await viewModel.load() }
        .navigationDestination(item: $presentedParadigm) { paradigm in
            ParadigmDetailView(
                paradigm: paradigm,
                titleForClip: { viewModel.title(forClip: $0) },
                onOpenSource: onOpenBreakdown,
                apply: { await viewModel.apply(paradigm, topic: $0) }
            )
        }
    }

    // MARK: - 洞察: pick breakdowns → distill

    private var distill: some View {
        Group {
            if viewModel.breakdowns.isEmpty {
                emptyBreakdowns
            } else {
                List {
                    Section {
                        ForEach(viewModel.breakdowns) { item in
                            Button {
                                viewModel.toggleSelection(item.id)
                            } label: {
                                breakdownRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("选择要洞察的剧本")
                    } footer: {
                        Text("选 2 条以上爆款拆解，提炼它们共同的可复用剧本范式。")
                    }
                }
                .safeAreaInset(edge: .bottom) { generateBar }
            }
        }
    }

    private func breakdownRow(_ item: BreakdownItem) -> some View {
        let selected = viewModel.selectedIDs.contains(item.id)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body).lineLimit(1)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var generateBar: some View {
        VStack(spacing: 6) {
            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button {
                Task {
                    if let paradigm = await viewModel.generateParadigm() {
                        presentedParadigm = paradigm
                        mode = .paradigms
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isGenerating {
                        ProgressView().tint(.white)
                        Text("提炼中…")
                    } else {
                        Image(systemName: "wand.and.stars")
                        Text("提炼范式（已选 \(viewModel.selectedIDs.count) 条）")
                    }
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    viewModel.canGenerate ? Color.accentColor : Color.secondary.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGenerate)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - 范式: saved paradigms

    private var paradigmLibrary: some View {
        Group {
            if viewModel.paradigms.isEmpty {
                emptyParadigms
            } else {
                List {
                    ForEach(viewModel.paradigms) { paradigm in
                        Button {
                            presentedParadigm = paradigm
                        } label: {
                            paradigmRow(paradigm)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        let toDelete = indexSet.map { viewModel.paradigms[$0] }
                        Task {
                            for paradigm in toDelete {
                                await viewModel.deleteParadigm(paradigm)
                            }
                        }
                    }
                }
            }
        }
    }

    private func paradigmRow(_ paradigm: ScriptParadigm) -> some View {
        let subtitle = paradigm.applicableScene.isEmpty ? "\(paradigm.sourceClipIDs.count) 条剧本" : paradigm.applicableScene
        return VStack(alignment: .leading, spacing: 3) {
            Text(paradigm.name).font(.body).lineLimit(1)
            Text("\(subtitle) · \(paradigm.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Empty states

    private var emptyBreakdowns: some View {
        emptyState(
            icon: "film.stack",
            title: "还没有可洞察的剧本",
            message: "去『拆解』导入视频，拆出的分镜剧本会出现在这里，选几条就能提炼范式。"
        )
    }

    private var emptyParadigms: some View {
        emptyState(
            icon: "sparkles.rectangle.stack",
            title: "还没有剧本范式",
            message: "切到『洞察』选 2 条以上剧本，提炼出一套可复用的范式，会保存到这里。"
        )
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
