import DashKit
import DashKitUI
import SwiftUI

/// The widget gallery, like the iOS and Android home-screen pickers: every widget the enabled
/// features offer, with a live miniature, grouped by feature and searchable. Adding keeps the
/// gallery open so several widgets can go in at once; the page stays in edit mode behind it.
struct WidgetGallery: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// Widgets added this session, for the brief "Added" confirmation.
    @State private var added: [String: Int] = [:]
    /// The preview size picked per widget kind (it is added at that size).
    @State private var sizes: [String: WidgetSize] = [:]

    /// Grouped by what they're about (not by plugin, which mostly gives one widget each), each
    /// tile naming the plugin it comes from.
    private var sections: [(name: String, items: [(type: WidgetType, owner: String)])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var groups: [ExtensionCategory: [(type: WidgetType, owner: String)]] = [:]
        for item in host.extensions where host.isEnabled(item) {
            for type in item.widgets where query.isEmpty || type.displayName.lowercased().contains(query)
                || type.summary.lowercased().contains(query) || item.name.lowercased().contains(query) {
                groups[item.metadata.category, default: []].append((type, item.name))
            }
        }
        let order: [ExtensionCategory] = [.productivity, .projectManagement, .sourceControl, .cloud, .monitoring, .ai, .communication, .other]
        return order.compactMap { category in
            guard let items = groups[category], !items.isEmpty else { return nil }
            return (Self.title(category), items.sorted { $0.type.displayName < $1.type.displayName })
        }
    }

    static func title(_ category: ExtensionCategory) -> String {
        switch category {
        case .productivity: "Basics & productivity"
        case .ai: "AI & agents"
        case .cloud: "Cloud & clusters"
        case .communication: "Meetings & communication"
        default: category.title
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Widgets").font(.title2.bold())
                Spacer()
                TextField("Search widgets", text: $search, prompt: Text("Search widgets"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding(20)
            Divider()
            ScrollView {
                // Not lazy: a lazy list of lazy grids drops tiles that scroll back into view (and
                // the gallery holds a few dozen widgets at most).
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(sections, id: \.name) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.name).font(.headline).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], alignment: .leading, spacing: 16) {
                                ForEach(section.items, id: \.type.kind) { item in
                                    tile(item.type, owner: item.owner)
                                }
                            }
                        }
                    }
                    if sections.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "No widgets available" : "No widgets match “\(search)”",
                                               systemImage: "square.grid.2x2",
                                               description: Text("Turn on features in Settings › Features to get their widgets."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Widgets go to the end of the page; drag them into place.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 900, height: 640)
    }

    private func tile(_ type: WidgetType, owner: String) -> some View {
        let count = added[type.kind] ?? 0
        let size = sizes[type.kind] ?? type.defaultSize
        let choices = WidgetMiniature.sizes(of: type)
        return Button {
            if (try? host.dashboard.add(kind: type.kind, size: size)) != nil {
                withAnimation(.snappy) { added[type.kind] = count + 1 }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                WidgetMiniature(type: type, size: size)
                    .frame(width: WidgetMiniature.maxSize.width, height: WidgetMiniature.maxSize.height)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy(duration: 0.2), value: size)
                if choices.count > 1 {
                    // Each preset size's layout; the widget is added at the one shown.
                    Picker("Size", selection: Binding(get: { size }, set: { sizes[type.kind] = $0 })) {
                        ForEach(choices, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(type.displayName).font(.headline)
                            if owner != type.displayName {
                                Text(owner).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: .capsule)
                            }
                        }
                        Text(type.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if count > 0 {
                        Label(count > 1 ? "Added ×\(count)" : "Added", systemImage: "checkmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.tint)
                    }
                }
            }
            .padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6)))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .help("Add \(type.displayName) to this page")
    }
}
