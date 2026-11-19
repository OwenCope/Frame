import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop target for screenshots. Accepts .png / .jpg / .heic via
/// drop or the Browse button, then hands URLs to the store, which runs
/// `frames info` automatically.
struct DropZone: View {
    @EnvironmentObject var store: ProjectStore
    @State private var hovering = false
    @State private var showImporter = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    hovering ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
            VStack(spacing: 6) {
                Image(systemName: store.sourceURL == nil ? "photo.badge.plus" : "photo.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                if let url = store.sourceURL {
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let info = store.detectedInfo, let device = info.device {
                        Text(device)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Drop a screenshot")
                        .font(.callout)
                    Text("PNG, JPG, HEIC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(store.sourceURL == nil ? "Browse…" : "Replace…") {
                    showImporter = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(12)
        }
        .frame(minHeight: 132)
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            var accepted = false
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        store.accept(urls: [url])
                    }
                }
            }
            return accepted
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result {
                store.accept(urls: urls)
            }
        }
    }
}
