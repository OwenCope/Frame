import AVKit
import SwiftUI

struct AnimationPreview: View {
    @EnvironmentObject var store: ProjectStore
    @State private var player: AVPlayer?
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Animation", selection: $store.project.animationPreset) {
                Text("Spring in").tag("spring-in")
                Text("Float").tag("float")
                Text("Parallax").tag("parallax")
                Text("Hero zoom").tag("hero-zoom")
                Text("Rise").tag("rise")
            }
            Button("Render motion preview") {
                Task {
                    store.isWorking = true
                    defer { store.isWorking = false }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                    do {
                        _ = try await StillRenderer.render(store.project, videoOutput: url)
                        clearPreview()
                        previewURL = url
                        player = AVPlayer(url: url)
                    } catch { store.lastError = error.localizedDescription }
                }
            }
            .disabled(store.project.framedImagePath == nil || store.isWorking)
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 240)
            }
            Text("Preview and export use the same video renderer. Press play to view motion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: store.project.animationPreset) { clearPreview() }
        .onDisappear { clearPreview() }
    }

    private func clearPreview() {
        player?.pause()
        player = nil
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
    }
}
