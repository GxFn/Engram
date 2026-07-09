import ScriptCore
import SwiftUI

/// 洞察 tab (v6). P1 surfaces the personal hook library; P2 adds a deterministic dashboard
/// (type distribution / retention ranking / overview) — pure aggregates, no LLM. P3 adds
/// cross-video LLM insight reports.
public struct InsightView: View {
    private enum Mode: Hashable {
        case library
        case dashboard
        case reports
    }

    @State private var viewModel: HookLibraryViewModel
    @State private var mode: Mode = .library
    @State private var presentedReport: InsightReport?
    private let onHookSelected: @MainActor (String) -> Void

    public init(
        viewModel: HookLibraryViewModel,
        onHookSelected: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onHookSelected = onHookSelected
    }

    public var body: some View {
        Group {
            if viewModel.hooks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    Picker("视图", selection: $mode) {
                        Text("钩子库").tag(Mode.library)
                        Text("看板").tag(Mode.dashboard)
                        Text("报告").tag(Mode.reports)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    switch mode {
                    case .library: library
                    case .dashboard: dashboard
                    case .reports: reports
                    }
                }
            }
        }
        .navigationTitle("洞察")
        .task {
            await viewModel.load()
            await viewModel.loadReports()
        }
        .navigationDestination(item: $presentedReport) { report in
            InsightReportView(
                report: report,
                titleForClip: { viewModel.title(forClip: $0) },
                onEvidenceSelected: onHookSelected
            )
        }
    }

    // MARK: - Library

    private var library: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            List {
                Section {
                    ForEach(viewModel.filtered) { hook in
                        HookCardView(
                            hook: hook,
                            onOpen: { onHookSelected(hook.clipID) },
                            onToggleFavorite: { Task { await viewModel.toggleFavorite(hook) } }
                        )
                    }
                } header: {
                    Text("钩子库 · \(viewModel.filtered.count)")
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.load() }
        }
        .searchable(text: searchBinding, prompt: "搜钩子（关键词）")
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", isOn: viewModel.selectedType == nil && !viewModel.favoritesOnly) {
                    viewModel.selectedType = nil
                    viewModel.favoritesOnly = false
                }
                if viewModel.favoriteCount > 0 {
                    chip(title: "★ 收藏", isOn: viewModel.favoritesOnly) {
                        viewModel.favoritesOnly.toggle()
                    }
                }
                ForEach(viewModel.presentTypes) { type in
                    chip(title: type.displayName, isOn: viewModel.selectedType == type) {
                        viewModel.selectedType = viewModel.selectedType == type ? nil : type
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isOn ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dashboard (deterministic, no LLM)

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview

                if !viewModel.typeDistribution.isEmpty {
                    dashboardSection("钩子类型分布") {
                        ForEach(viewModel.typeDistribution) { item in
                            distributionRow(item)
                        }
                    }
                }

                let devices = viewModel.topRetentionDevices()
                if !devices.isEmpty {
                    dashboardSection("留人手法 Top") {
                        ForEach(devices) { device in
                            HStack {
                                Text(device.label).font(.subheadline)
                                Spacer()
                                Text("\(device.count)").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable { await viewModel.load() }
    }

    private var overview: some View {
        HStack(spacing: 12) {
            statTile(value: "\(viewModel.totalHooks)", label: "钩子")
            statTile(value: "\(viewModel.favoriteCount)", label: "收藏")
            if let span = viewModel.timeSpanText {
                statTile(value: span, label: "跨度", wide: true)
            }
        }
    }

    private func statTile(value: String, label: String, wide: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(wide ? .subheadline.weight(.semibold) : .title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func dashboardSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func distributionRow(_ item: HookLibraryViewModel.TypeCount) -> some View {
        let maxCount = viewModel.typeDistribution.first?.count ?? 1
        let fraction = maxCount > 0 ? Double(item.count) / Double(maxCount) : 0
        return Button {
            viewModel.selectedType = item.type
            viewModel.favoritesOnly = false
            mode = .library
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.type.displayName).font(.subheadline)
                    Spacer()
                    Text("\(item.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: max(6, geo.size.width * fraction), height: 6)
                }
                .frame(height: 6)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    // MARK: - Reports (LLM cross-video synthesis)

    private var reports: some View {
        List {
            Section {
                Button {
                    Task {
                        if let report = await viewModel.generateReport() {
                            presentedReport = report
                        }
                    }
                } label: {
                    if viewModel.isGeneratingReport {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("归纳中…")
                        }
                    } else {
                        Label("对当前 \(viewModel.filtered.count) 条生成洞察", systemImage: "wand.and.stars")
                    }
                }
                .disabled(viewModel.isGeneratingReport || viewModel.filtered.count < 2)

                if let error = viewModel.reportError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("先在『钩子库』按类型/收藏/搜索筛选，这里就只对筛选后的集合归纳；至少 2 条。")
            }

            if viewModel.reports.isEmpty {
                Section {
                    Text("还没有洞察报告。点上面生成第一份，会自动保存到这里，可随时回看。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("历史报告") {
                    ForEach(viewModel.reports) { report in
                        Button {
                            presentedReport = report
                        } label: {
                            reportRow(report)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        let toDelete = indexSet.map { viewModel.reports[$0] }
                        Task {
                            for report in toDelete {
                                await viewModel.deleteReport(report)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reportRow(_ report: InsightReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(report.title)
                .font(.body)
                .lineLimit(1)
            Text("\(report.scopeDescription) · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("钩子库还是空的")
                    .font(.title3.weight(.semibold))
                Text("去『拆解』导入视频，每条拆解的开场钩子会自动进这里，越拆越厚。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var searchBinding: Binding<String> {
        Binding(get: { viewModel.searchText }, set: { viewModel.searchText = $0 })
    }
}
