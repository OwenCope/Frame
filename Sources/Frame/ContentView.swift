import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showMotion = false

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DropZone()
                    SettingsPane()
                    if store.sourceURL != nil && store.project.framedImagePath == nil {
                        Text(store.status)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
            .navigationTitle("Frame")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.frameNow() }
                    } label: {
                        Label("Reframe", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.sourceURL == nil || store.isWorking)
                }
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PreviewCanvas()
                        .frame(minHeight: 380)

                    statusCard

                    DisclosureGroup("Motion preview", isExpanded: $showMotion) {
                        AnimationPreview()
                            .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button("Open…") { store.open() }
                    Button("Save…") { store.save() }
                        .disabled(store.sourceURL == nil || store.isWorking)
                    Menu("Export") {
                        Button("PNG image…") { store.exportPNG() }
                            .keyboardShortcut("e", modifiers: .command)
                        Button("MP4 video…") { store.exportVideo() }
                    }
                        .disabled(store.project.framedImagePath == nil || store.isWorking)
                    if store.isWorking { ProgressView().controlSize(.small) }
                }
            }
        }
        .task { await store.loadDevices() }
        .alert("Frame", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        HStack(spacing: 8) {
            Image(systemName: store.lastError != nil ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(.secondary)
            Text(store.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let w = store.detectedInfo?.width, let h = store.detectedInfo?.height {
                Text("\(w)×\(h)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}
