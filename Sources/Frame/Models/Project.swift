import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - Layers

/// The four compositing layers. The canonical .frameproj schema is owned by
/// a sibling worker; this struct is the app's working model of it and stays
/// compatible via `schemaVersion` + fixed layer kinds.
enum LayerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case screenshot
    case frame
    case backdrop
    case adjust

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .screenshot: "photo"
        case .frame: "macbook"
        case .backdrop: "photo.on.rectangle"
        case .adjust: "slider.horizontal.3"
        }
    }
}

struct FrameLayer: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: LayerKind
    var visible: Bool = true
}

// MARK: - Project

struct Project: Codable, Sendable {
    var canonicalData: Data? = nil
    var canvasWidth: Int? = nil
    var canvasHeight: Int? = nil
    var useCase: String = "Original"
    var animationPreset: String = "hero-zoom"
    var schemaVersion: Int = 1
    var sourceImagePath: String?
    var framedImagePath: String?
    var deviceName: String?
    var colorName: String?
    /// Framed-device scale within the backdrop, 0.1...1.0.
    var scale: Double = 0.70
    /// Device position as a fraction of the canvas from center, -0.5...0.5.
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Backdrop blur radius, 0...20.
    var blur: Double = 8
    /// Film grain amount, 0...15.
    var grain: Double = 6
    /// "color" or "image".
    var backdropKind: String = "color"
    /// Hex color when backdropKind == "color", file path when "image".
    var backdropValue: String = "#1C1C1E"
    var backgroundHex: String = "#1C1C1E"
    /// Export preset name. UI only: actual video rendering is owned by the
    /// video pipeline worker; this records the choice.
    var exportPreset: String = ExportPreset.preview.rawValue
    var layers: [FrameLayer] = LayerKind.allCases.map { FrameLayer(kind: $0) }

    func isVisible(_ kind: LayerKind) -> Bool {
        layers.first { $0.kind == kind }?.visible ?? true
    }
}

enum ExportPreset: String, Codable, CaseIterable, Identifiable {
    case preview
    case prores4444
    case hevcAlpha

    var id: String { rawValue }
    var title: String {
        switch self {
        case .preview: "Preview (still)"
        case .prores4444: "ProRes 4444"
        case .hevcAlpha: "HEVC with alpha"
        }
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        } else {
            r = 0.11; g = 0.11; b = 0.12
        }
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        guard let cg = NSColor(self).usingColorSpace(.sRGB) else { return "#1C1C1E" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        cg.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Store

/// Observable app state. Persists per-project as a Codable .frameproj file;
/// the last-opened path is remembered in UserDefaults (never keychain).
@MainActor
final class ProjectStore: ObservableObject {
    @Published var project = Project()
    @Published var devices: [FramedDevice] = []
    @Published var colors: [FramedColor] = []
    @Published var detectedInfo: FrameInfo?
    @Published var status: String = "Drop a screenshot to begin."
    @Published var lastError: String?
    @Published var isWorking = false
    @Published var composited: NSImage?
    private var renderTask: Task<Void, Never>?
    private var renderedPNG: Data?

    private let bridge = FramesBridge()
    private let lastPathKey = "Frame.lastProjectPath"

    var sourceURL: URL? {
        project.sourceImagePath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: Devices / colors (always live from the CLI, never hardcoded)

    func loadDevices() async {
        do {
            devices = try await bridge.listDevices()
            if devices.isEmpty { status = "No devices reported by `frames list`." }
        } catch {
            lastError = error.localizedDescription
            status = "Could not list devices."
        }
    }

    func refreshColors() async {
        guard let device = project.deviceName, !device.isEmpty else {
            colors = []
            return
        }
        do {
            colors = try await bridge.listColors(device: device)
            if let first = colors.first(where: { $0.isDefault }) ?? colors.first,
               project.colorName == nil
            {
                project.colorName = first.name
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Drop / info / frame

    static let acceptedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]

    func accept(urls: [URL]) {
        guard !isWorking else { return }
        renderTask?.cancel()
        let images = urls.filter { Self.acceptedExtensions.contains($0.pathExtension.lowercased()) }
        guard let url = images.first else {
            lastError = "Only .png, .jpg, and .heic files are supported."
            return
        }
        do {
            project.sourceImagePath = try Self.importImage(url).path
        } catch {
            lastError = "Cannot read \(url.lastPathComponent). Export it as PNG and try again."
            return
        }
        project.framedImagePath = nil
        project.colorName = nil
        project.canonicalData = nil
        detectedInfo = nil
        composited = nil
        Task { await runInfoAndFrame() }
    }

    static func importImage(_ url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Frame/Imports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output
    }

    func runInfoAndFrame() async {
        guard let source = sourceURL else { return }
        isWorking = true
        lastError = nil
        status = "Detecting device…"
        do {
            let info = try await bridge.info(file: source)
            detectedInfo = info
            if project.deviceName == nil, let device = info.device {
                project.deviceName = device
                status = "Detected \(device)."
            }
            guard project.deviceName != nil else {
                status = "Choose a device to frame this \(info.width ?? 0) × \(info.height ?? 0) screenshot."
                isWorking = false
                return
            }
            await refreshColors()
            await frameNow()
        } catch {
            lastError = error.localizedDescription
            status = "Detection failed."
        }
        isWorking = false
    }

    func frameNow() async {
        guard let source = sourceURL else {
            lastError = "Drop a screenshot first."
            return
        }
        renderTask?.cancel()
        guard project.deviceName != nil else {
            status = "Choose a device before framing this screenshot."
            return
        }
        isWorking = true
        lastError = nil
        status = "Framing…"
        do {
            let result = try await bridge.frame(
                input: source,
                device: project.deviceName,
                color: project.colorName
            )
            project.framedImagePath = result.resolvedOutputPath
            project.deviceName = result.device ?? project.deviceName
            project.colorName = result.color ?? project.colorName
            status = "Framed with \(result.device ?? "auto") · \(result.color ?? "") → \(URL(fileURLWithPath: result.resolvedOutputPath).lastPathComponent)"
            recomposite()
        } catch {
            lastError = error.localizedDescription
            status = "Framing failed."
        }
        isWorking = false
    }

    // MARK: Layers

    func setVisible(_ kind: LayerKind, _ visible: Bool) {
        if let i = project.layers.firstIndex(where: { $0.kind == kind }) {
            project.layers[i].visible = visible
        }
        recomposite()
    }

    // MARK: Composite

    func recomposite() {
        renderTask?.cancel()
        renderedPNG = nil
        guard let path = project.framedImagePath,
              FileManager.default.fileExists(atPath: path) else { return }
        let snapshot = project
        renderTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let data = try await StillRenderer.render(snapshot)
                guard !Task.isCancelled else { return }
                renderedPNG = data
                composited = NSImage(data: data)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
            }
        }
    }

    func exportPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Frame.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let data = try await StillRenderer.render(project)
                try data.write(to: url, options: .atomic)
                status = "Exported \(url.lastPathComponent)."
            } catch { lastError = error.localizedDescription }
        }
    }

    func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Frame.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isWorking = true
            status = "Exporting video…"
            defer { isWorking = false }
            do {
                _ = try await StillRenderer.render(project, videoOutput: url)
                status = "Exported \(url.lastPathComponent)."
            } catch { lastError = error.localizedDescription }
        }
    }

    // MARK: Persistence (Codable file + UserDefaults, no keychain)

    static var frameprojType: UTType {
        UTType(filenameExtension: "frameproj") ?? .data
    }

    func save() {
        guard let panelURL = savePanelURL() else { return }
        do {
            let data = try project.documentData()
            try data.write(to: panelURL)
            UserDefaults.standard.set(panelURL.path, forKey: lastPathKey)
            status = "Saved \(panelURL.lastPathComponent)."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.frameprojType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            project = try Project.load(data, relativeTo: url.deletingLastPathComponent())
            UserDefaults.standard.set(url.path, forKey: lastPathKey)
            status = "Opened \(url.lastPathComponent)."
            Task {
                await refreshColors()
                if project.framedImagePath.map({ FileManager.default.fileExists(atPath: $0) }) != true {
                    await frameNow()
                } else { recomposite() }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func savePanelURL() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.frameprojType]
        panel.nameFieldStringValue = "Untitled.frameproj"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
