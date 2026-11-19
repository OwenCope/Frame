import SwiftUI

struct SettingsPane: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showBackdropImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                heading("Output format")
                Picker("Output format", selection: Binding(
                    get: { store.project.useCase },
                    set: { value in
                        OutputUseCase(rawValue: value)?.apply(to: &store.project)
                        if store.sourceURL != nil { store.recomposite() }
                    }
                )) {
                    ForEach(OutputUseCase.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                if let width = store.project.canvasWidth, let height = store.project.canvasHeight {
                    Text("\(width) × \(height) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                heading("Device")
                Picker("Device", selection: deviceBinding) {
                    Text("Detect automatically").tag("")
                    ForEach(store.devices) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .disabled(store.isWorking)
                Picker("Device color", selection: colorBinding) {
                    Text("Default color").tag(Optional<String>.none)
                    ForEach(store.colors) { Text($0.name).tag(Optional($0.name)) }
                }
                .labelsHidden()
                .disabled(store.colors.isEmpty || store.isWorking)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                heading("Backdrop")
                Picker("Backdrop type", selection: $store.project.backdropKind) {
                    Text("Color").tag("color")
                    Text("Image").tag("image")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: store.project.backdropKind) {
                    store.project.backdropValue = store.project.backdropKind == "color" ? store.project.backgroundHex : ""
                    if store.sourceURL != nil && store.project.backdropKind == "color" { store.recomposite() }
                }
                if store.project.backdropKind == "color" {
                    ColorPicker("Background color", selection: bgBinding, supportsOpacity: false)
                } else {
                    Button("Choose backdrop image…") { showBackdropImporter = true }
                    if !store.project.backdropValue.isEmpty {
                        Text(URL(fileURLWithPath: store.project.backdropValue).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }

            DisclosureGroup("Advanced adjustments") {
                VStack(alignment: .leading, spacing: 16) {
                    adjustment("Scale", value: $store.project.scale, range: 0.1...1, step: 0.01, percent: true)
                    adjustment("Horizontal", value: $store.project.offsetX, range: -0.5...0.5, step: 0.01, percent: true)
                    adjustment("Vertical", value: $store.project.offsetY, range: -0.5...0.5, step: 0.01, percent: true)
                    adjustment("Blur", value: $store.project.blur, range: 0...20, step: 1)
                    adjustment("Grain", value: $store.project.grain, range: 0...15, step: 1)
                }
                .padding(.top, 12)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $showBackdropImporter, allowedContentTypes: [.png, .jpeg, .heic]) { result in
            do {
                store.project.backdropValue = try ProjectStore.importImage(result.get()).path
                if store.sourceURL != nil { store.recomposite() }
            } catch { store.lastError = error.localizedDescription }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold))
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, percent: Bool = false) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step) { Text(title) }
                .labelsHidden()
                .onChange(of: value.wrappedValue) {
                    if store.sourceURL != nil { store.recomposite() }
                }
        }
    }

    private var deviceBinding: Binding<String> {
        Binding(get: { store.project.deviceName ?? "" }, set: { value in
            store.project.deviceName = value.isEmpty ? nil : value
            store.project.colorName = nil
            Task {
                await store.refreshColors()
                if store.sourceURL != nil { await store.runInfoAndFrame() }
            }
        })
    }

    private var colorBinding: Binding<String?> {
        Binding(get: { store.project.colorName }, set: { value in
            store.project.colorName = value
            if store.sourceURL != nil { Task { await store.frameNow() } }
        })
    }

    private var bgBinding: Binding<Color> {
        Binding(get: { Color(hex: store.project.backgroundHex) }, set: { color in
            let hex = color.toHex()
            store.project.backgroundHex = hex
            store.project.backdropValue = hex
            if store.sourceURL != nil { store.recomposite() }
        })
    }
}
