import SwiftUI

@main
struct FrameApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Frame Now") { Task { await store.frameNow() } }
                    .keyboardShortcut("f", modifiers: [.command])
            }
        }

        Settings {
            ScrollView {
                SettingsPane()
                    .padding(24)
            }
            .environmentObject(store)
            .frame(width: 420, height: 620)
        }
    }
}
