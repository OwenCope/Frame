// FrameProject.swift
// GENERATED from project_schema.json (frameproj v1) — do not hand-edit.
// Regenerate: python3 Sources/FrameCore/Renderer.py --generate-swift Sources/FrameCore/FrameProject.swift
// Unknown fields are preserved on load (forward-compat); every layer is
// independently replaceable: open -> edit one layer -> re-render.

import Foundation



/// Minimal JSON value box so unknown fields survive a decode/encode round-trip.
public enum AnyJSON: Codable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([AnyJSON]), object([String: AnyJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
        self = .object(try c.decode([String: AnyJSON].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String; var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
}


public struct ScreenshotLayer: Codable, Equatable {
    private static let _knownKeys = ["path", "sha256"]
    public var path: String
    public var sha256: String? = nil

    public init(path: String, sha256: String? = nil) {
        self.path = path
        self.sha256 = sha256
    }

    /// Unknown fields within this layer, preserved verbatim.
    public var unknown: [String: AnyJSON] = [:]

    private enum KnownKeys: String, CodingKey {
        case path; case sha256
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: KnownKeys.self)
        path = try known.decode(String.self, forKey: .path)
        sha256 = try known.decodeIfPresent(String.self, forKey: .sha256) ?? nil
        let bag = try decoder.container(keyedBy: AnyKey.self)
        for key in bag.allKeys where !Self._knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: KnownKeys.self)
        try known.encode(path, forKey: .path)
        try known.encodeIfPresent(sha256, forKey: .sha256)
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }
}

public struct FrameLayer: Codable, Equatable {
    private static let _knownKeys = ["device", "color", "output"]
    public var device: String
    public var color: String
    public var output: String? = nil

    public init(device: String, color: String, output: String? = nil) {
        self.device = device
        self.color = color
        self.output = output
    }

    /// Unknown fields within this layer, preserved verbatim.
    public var unknown: [String: AnyJSON] = [:]

    private enum KnownKeys: String, CodingKey {
        case device; case color; case output
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: KnownKeys.self)
        device = try known.decode(String.self, forKey: .device)
        color = try known.decode(String.self, forKey: .color)
        output = try known.decodeIfPresent(String.self, forKey: .output) ?? nil
        let bag = try decoder.container(keyedBy: AnyKey.self)
        for key in bag.allKeys where !Self._knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: KnownKeys.self)
        try known.encode(device, forKey: .device)
        try known.encode(color, forKey: .color)
        try known.encodeIfPresent(output, forKey: .output)
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }
}

public struct BackdropLayer: Codable, Equatable {
    private static let _knownKeys = ["path", "color", "blur", "grain", "scale", "offset"]
    public var path: String? = nil
    public var color: String? = nil
    public var blur: Double = 8
    public var grain: Double = 6
    public var scale: Double = 0.7
    public var offset: [Double] = [0, 0]

    public init(path: String? = nil, color: String? = nil, blur: Double = 8, grain: Double = 6, scale: Double = 0.7, offset: [Double] = [0, 0]) {
        self.path = path
        self.color = color
        self.blur = blur
        self.grain = grain
        self.scale = scale
        self.offset = offset
    }

    /// Unknown fields within this layer, preserved verbatim.
    public var unknown: [String: AnyJSON] = [:]

    private enum KnownKeys: String, CodingKey {
        case path; case color; case blur; case grain; case scale; case offset
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: KnownKeys.self)
        path = try known.decodeIfPresent(String.self, forKey: .path) ?? nil
        color = try known.decodeIfPresent(String.self, forKey: .color) ?? nil
        blur = try known.decodeIfPresent(Double.self, forKey: .blur) ?? 8
        grain = try known.decodeIfPresent(Double.self, forKey: .grain) ?? 6
        scale = try known.decodeIfPresent(Double.self, forKey: .scale) ?? 0.7
        offset = try known.decodeIfPresent([Double].self, forKey: .offset) ?? [0, 0]
        let bag = try decoder.container(keyedBy: AnyKey.self)
        for key in bag.allKeys where !Self._knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: KnownKeys.self)
        try known.encodeIfPresent(path, forKey: .path)
        try known.encodeIfPresent(color, forKey: .color)
        try known.encodeIfPresent(blur, forKey: .blur)
        try known.encodeIfPresent(grain, forKey: .grain)
        try known.encodeIfPresent(scale, forKey: .scale)
        try known.encodeIfPresent(offset, forKey: .offset)
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }
}

public struct AdjustLayer: Codable, Equatable {
    private static let _knownKeys = ["brightness", "contrast", "saturation"]
    public var brightness: Double = 1.0
    public var contrast: Double = 1.0
    public var saturation: Double = 1.0

    public init(brightness: Double = 1.0, contrast: Double = 1.0, saturation: Double = 1.0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
    }

    /// Unknown fields within this layer, preserved verbatim.
    public var unknown: [String: AnyJSON] = [:]

    private enum KnownKeys: String, CodingKey {
        case brightness; case contrast; case saturation
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: KnownKeys.self)
        brightness = try known.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
        contrast = try known.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0
        saturation = try known.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        let bag = try decoder.container(keyedBy: AnyKey.self)
        for key in bag.allKeys where !Self._knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: KnownKeys.self)
        try known.encodeIfPresent(brightness, forKey: .brightness)
        try known.encodeIfPresent(contrast, forKey: .contrast)
        try known.encodeIfPresent(saturation, forKey: .saturation)
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }
}

public struct AnimationLayer: Codable, Equatable {
    private static let _knownKeys = ["preset", "duration", "export"]
    public var preset: String? = nil
    public var duration: Double? = nil
    public var export: String? = nil

    public init(preset: String? = nil, duration: Double? = nil, export: String? = nil) {
        self.preset = preset
        self.duration = duration
        self.export = export
    }

    /// Unknown fields within this layer, preserved verbatim.
    public var unknown: [String: AnyJSON] = [:]

    private enum KnownKeys: String, CodingKey {
        case preset; case duration; case export
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: KnownKeys.self)
        preset = try known.decodeIfPresent(String.self, forKey: .preset) ?? nil
        duration = try known.decodeIfPresent(Double.self, forKey: .duration) ?? nil
        export = try known.decodeIfPresent(String.self, forKey: .export) ?? nil
        let bag = try decoder.container(keyedBy: AnyKey.self)
        for key in bag.allKeys where !Self._knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: KnownKeys.self)
        try known.encodeIfPresent(preset, forKey: .preset)
        try known.encodeIfPresent(duration, forKey: .duration)
        try known.encodeIfPresent(export, forKey: .export)
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }
}

public struct FrameProject: Codable, Equatable {
    public var frameproj: Int = 1
    public var screenshot: ScreenshotLayer
    public var frame: FrameLayer
    public var backdrop: BackdropLayer
    public var adjust: AdjustLayer = AdjustLayer()
    public var animation: AnimationLayer = AnimationLayer()

    /// Unknown top-level fields, preserved verbatim for forward compatibility.
    public var unknown: [String: AnyJSON] = [:]

    private enum TopKeys: String, CodingKey {
        case frameproj, screenshot, frame, backdrop, adjust, animation
    }

    public init(frameproj: Int = 1, screenshot: ScreenshotLayer, frame: FrameLayer,
                backdrop: BackdropLayer, adjust: AdjustLayer = AdjustLayer(),
                animation: AnimationLayer = AnimationLayer()) {
        self.frameproj = frameproj; self.screenshot = screenshot; self.frame = frame
        self.backdrop = backdrop; self.adjust = adjust; self.animation = animation
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: TopKeys.self)
        frameproj = try known.decode(Int.self, forKey: .frameproj)
        screenshot = try known.decode(ScreenshotLayer.self, forKey: .screenshot)
        frame = try known.decode(FrameLayer.self, forKey: .frame)
        backdrop = try known.decode(BackdropLayer.self, forKey: .backdrop)
        adjust = try known.decodeIfPresent(AdjustLayer.self, forKey: .adjust) ?? AdjustLayer()
        animation = try known.decodeIfPresent(AnimationLayer.self, forKey: .animation) ?? AnimationLayer()
        let bag = try decoder.container(keyedBy: AnyKey.self)
        let knownNames: Set<String> = ["frameproj", "screenshot", "frame", "backdrop", "adjust", "animation"]
        for key in bag.allKeys where !knownNames.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: TopKeys.self)
        try known.encode(frameproj, forKey: .frameproj)
        try known.encode(screenshot, forKey: .screenshot)
        try known.encode(frame, forKey: .frame)
        try known.encode(backdrop, forKey: .backdrop)
        try known.encode(adjust, forKey: .adjust)
        try known.encode(animation, forKey: .animation)
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }

}

