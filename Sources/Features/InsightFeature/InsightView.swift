import ScriptCore
import SwiftUI

/// 洞察 tab (v6). P1 surfaces the personal hook library; P2 adds a deterministic dashboard
/// (type distribution / retention ranking / overview) — pure aggregates, no LLM. P3 adds
/// cross-video LLM insight reports.
public struct InsightView: View {
    private enum Mode: Hashable {
        case library
        case dashboard
    }

    @State private var viewModel: HookLibraryViewModel
    @State private var mode: Mode = .library
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
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    switch mode {
                    case .library: library
                    case .dashboard: dashboard
                    }
                }
            }
        }
        .navigationTitle("洞察")
        .task { await viewModel.load() }
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
