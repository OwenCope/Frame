import Foundation
import XCTest
import AppKit
@testable import Frame

final class ProjectDocumentTests: XCTestCase {
    func testAppRendererMatchesCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 48, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 160, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let shot = directory.appendingPathComponent("shot.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: shot)
        var project = Project()
        project.sourceImagePath = shot.path
        project.framedImagePath = shot.path
        project.deviceName = "Test"
        project.colorName = "Black"
        let input = directory.appendingPathComponent("saved.frameproj")
        try project.documentData().write(to: input)
        let reopened = try Project.load(Data(contentsOf: input), relativeTo: directory)
        let appPNG = try await StillRenderer.render(reopened)
        let output = directory.appendingPathComponent("cli.png")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("Sources/FrameCore/Renderer.py").path, input.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(appPNG, try Data(contentsOf: output))
    }

    func testCanonicalRoundTripPreservesLayersAndUnknownFields() throws {
        let data = Data(##"{"frameproj":1,"screenshot":{"path":"shot.png"},"frame":{"device":"Phone","color":"Black"},"backdrop":{"color":"#203040","offset":[3,7]},"adjust":{"brightness":1.2},"animation":{"preset":"rise"},"future":{"keep":true}}"##.utf8)
        var project = try Project.load(data, relativeTo: URL(fileURLWithPath: "/tmp/example"))
        project.blur = 12
        let encoded = try project.documentData()
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((doc["screenshot"] as? [String: Any])?["path"] as? String, "/tmp/example/shot.png")
        XCTAssertEqual((doc["adjust"] as? [String: Any])?["brightness"] as? Double, 1.2)
        XCTAssertEqual((doc["animation"] as? [String: Any])?["preset"] as? String, "rise")
        XCTAssertEqual((doc["future"] as? [String: Any])?["keep"] as? Bool, true)
        XCTAssertEqual((doc["backdrop"] as? [String: Any])?["offset"] as? [Int], [3, 7])
        XCTAssertEqual(try Project.load(encoded, relativeTo: URL(fileURLWithPath: "/tmp")).blur, 12)
    }

    func testResetPresetRemovesCanvas() throws {
        var project = Project()
        OutputUseCase.social.apply(to: &project)
        project.canonicalData = try project.documentData()
        OutputUseCase.original.apply(to: &project)
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: project.documentData()) as? [String: Any])
        XCTAssertNil(doc["canvas"])
    }

    func testLegacyMigration() throws {
        var legacy = Project()
        legacy.sourceImagePath = "/tmp/shot.png"
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        old.removeValue(forKey: "useCase")
        old.removeValue(forKey: "animationPreset")
        let loaded = try Project.load(JSONSerialization.data(withJSONObject: old), relativeTo: URL(fileURLWithPath: "/tmp"))
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: loaded.documentData()) as? [String: Any])
        XCTAssertEqual(doc["frameproj"] as? Int, 1)
        XCTAssertNotNil(doc["screenshot"])
    }
}
