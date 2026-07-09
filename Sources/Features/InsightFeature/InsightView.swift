import ScriptCore
import SwiftUI

/// 洞察 tab (v6). P1 surfaces the personal hook library (sedimented methodology); P2/P3 add the
/// deterministic dashboard and cross-video insight reports.
public struct InsightView: View {
    @State private var viewModel: HookLibraryViewModel
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
                library
            }
        }
        .navigationTitle("洞察")
        .searchable(text: searchBinding, prompt: "搜钩子（关键词）")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

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
        }
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
