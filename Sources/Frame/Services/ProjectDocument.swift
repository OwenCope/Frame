import Foundation

extension Project {
    func documentData() throws -> Data {
        var doc = try canonicalData.map {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:]
        } ?? [:]
        func merging(_ key: String, _ values: [String: Any]) {
            var layer = doc[key] as? [String: Any] ?? [:]
            for (key, value) in values { layer[key] = value }
            doc[key] = layer
        }
        doc["frameproj"] = 1
        merging("screenshot", ["path": sourceImagePath ?? ""])
        merging("frame", ["device": deviceName ?? "Auto", "color": colorName ?? "Default"])
        var frame = doc["frame"] as? [String: Any] ?? [:]
        frame["output"] = framedImagePath
        doc["frame"] = frame
        merging("backdrop", ["blur": blur, "grain": grain, "scale": scale, "position": [offsetX, offsetY]])
        var backdrop = doc["backdrop"] as? [String: Any] ?? [:]
        backdrop["path"] = backdropKind == "image" ? backdropValue : nil
        backdrop["color"] = backdropKind == "color" ? backdropValue : nil
        doc["backdrop"] = backdrop
        if doc["adjust"] == nil { doc["adjust"] = [:] as [String: Any] }
        merging("animation", ["preset": animationPreset])
        if useCase == OutputUseCase.backdrop.rawValue && backdropKind == "image" {
            doc["canvas"] = ["fit": "backdrop"]
        } else if let width = canvasWidth, let height = canvasHeight {
            doc["canvas"] = ["width": width, "height": height]
        } else {
            doc.removeValue(forKey: "canvas")
        }
        merging("editor", ["useCase": useCase])
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    static func load(_ data: Data, relativeTo base: URL) throws -> Project {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let version = doc["frameproj"] as? Int else {
            var legacy = doc
            legacy["useCase"] = legacy["useCase"] ?? "Original"
            legacy["animationPreset"] = legacy["animationPreset"] ?? "hero-zoom"
            return try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
        guard version == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        var result = Project()
        var resolved = doc
        for (layer, key) in [("screenshot", "path"), ("frame", "output"), ("backdrop", "path")] {
            var fields = resolved[layer] as? [String: Any] ?? [:]
            if let path = fields[key] as? String, !path.hasPrefix("/") {
                fields[key] = base.appendingPathComponent(path).standardizedFileURL.path
            }
            resolved[layer] = fields
        }
        let shot = resolved["screenshot"] as? [String: Any] ?? [:]
        let frame = resolved["frame"] as? [String: Any] ?? [:]
        let backdrop = resolved["backdrop"] as? [String: Any] ?? [:]
        guard let path = shot["path"] as? String, !path.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        result.sourceImagePath = path
        result.framedImagePath = frame["output"] as? String
        result.deviceName = frame["device"] as? String
        result.colorName = frame["color"] as? String
        result.backdropKind = backdrop["path"] == nil ? "color" : "image"
        result.backdropValue = backdrop["path"] as? String ?? backdrop["color"] as? String ?? "#1C1C1E"
        result.backgroundHex = backdrop["color"] as? String ?? "#1C1C1E"
        result.scale = backdrop["scale"] as? Double ?? 0.7
        let position = backdrop["position"] as? [Double] ?? [0, 0]
        result.offsetX = position.first ?? 0
        result.offsetY = position.count > 1 ? position[1] : 0
        result.blur = backdrop["blur"] as? Double ?? 8
        result.grain = backdrop["grain"] as? Double ?? 6
        let canvas = doc["canvas"] as? [String: Any] ?? [:]
        result.canvasWidth = canvas["width"] as? Int
        result.canvasHeight = canvas["height"] as? Int
        result.animationPreset = (doc["animation"] as? [String: Any])?["preset"] as? String ?? "hero-zoom"
        result.useCase = (doc["editor"] as? [String: Any])?["useCase"] as? String ?? "Original"
        result.canonicalData = try JSONSerialization.data(withJSONObject: resolved)
        return result
    }
}

enum OutputUseCase: String, CaseIterable, Identifiable {
    case original = "Original"
    case backdrop = "Match backdrop"
    case appStore = "App Store screenshot"
    case release = "Release announcement"
    case social = "Social demo"
    var id: String { rawValue }

    func apply(to project: inout Project) {
        project.useCase = rawValue
        switch self {
        case .original, .backdrop: project.canvasWidth = nil; project.canvasHeight = nil
        case .appStore: project.canvasWidth = 1290; project.canvasHeight = 2796
        case .release: project.canvasWidth = 2400; project.canvasHeight = 1350
        case .social: project.canvasWidth = 1080; project.canvasHeight = 1080
        }
        project.scale = self == .appStore ? 0.9 : 0.7
        project.blur = 8
        project.grain = 6
        project.animationPreset = self == .social ? "float" : "hero-zoom"
    }
}
