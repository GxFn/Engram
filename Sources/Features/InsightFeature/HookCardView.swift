import ScriptCore
import SwiftUI

/// One hook in the library: type + favorite, the hook line (large, copyable), retention-device
/// tags, a foldable "why it works", and the source clip (tap to open its breakdown).
struct HookCardView: View {
    let hook: HookEntry
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void

    @State private var showWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(hook.hookType.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)

                Spacer()

                Button(action: onToggleFavorite) {
                    Image(systemName: hook.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(hook.isFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hook.isFavorite ? "取消收藏" : "收藏")
            }

            Text(hook.text)
                .font(.body.weight(.medium))
                .textSelection(.enabled)

            if !hook.retentionDevices.isEmpty {
                FlowTags(tags: hook.retentionDevices)
            }

            if !hook.whyItWorks.isEmpty {
                DisclosureGroup(isExpanded: $showWhy) {
                    Text(hook.whyItWorks)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("为什么成立")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack")
                    Text(hook.clipTitle)
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
        .padding(.vertical, 6)
    }
}

/// Simple wrapping tag row for retention devices.
private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(tags.prefix(4).enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if tags.count > 4 {
                Text("+\(tags.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
