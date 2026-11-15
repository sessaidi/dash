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

    private var sections: [(name: String, types: [WidgetType])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return host.extensions.compactMap { item in
            guard host.isEnabled(item), !item.widgets.isEmpty else { return nil }
            let types = item.widgets.filter { type in
                query.isEmpty || type.displayName.lowercased().contains(query) || type.summary.lowercased().contains(query)
                    || item.name.lowercased().contains(query)
            }
            return types.isEmpty ? nil : (item.name, types)
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
                                ForEach(section.types) { type in
                                    tile(type)
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

    private func tile(_ type: WidgetType) -> some View {
        let count = added[type.kind] ?? 0
        return Button {
            if (try? host.dashboard.add(kind: type.kind)) != nil {
                withAnimation(.snappy) { added[type.kind] = count + 1 }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                WidgetMiniature(type: type)
                    .frame(width: WidgetMiniature.maxSize.width, height: WidgetMiniature.maxSize.height)
                    .frame(maxWidth: .infinity)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(type.displayName).font(.headline)
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
