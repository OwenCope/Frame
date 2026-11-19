import SwiftUI

struct PreviewCanvas: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image = store.composited {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            } else {
                if store.sourceURL != nil {
                    ContentUnavailableView("Choose a device", systemImage: "laptopcomputer",
                        description: Text("Select a device in the sidebar to frame this screenshot."))
                } else {
                    ContentUnavailableView("Add a screenshot", systemImage: "photo.badge.plus",
                        description: Text("Drop a screenshot or choose Browse to preview your export."))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
