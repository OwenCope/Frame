import AppKit
import XCTest
@testable import Frame

final class FramingTests: XCTestCase {
    func testLiveDevicePickerHasUniqueEntriesAndManualFrames() async throws {
        let devices = try await FramesBridge().listDevices()
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        XCTAssertTrue(devices.contains { $0.name == "MacBook Pro 2021 14" })
    }

    @MainActor
    func testUnknownScreenshotWaitsForDeviceThenFramesAndRenders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1422, pixelsHigh: 1000,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 5688, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 180, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let input = directory.appendingPathComponent("screenshot.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: input)
        let store = ProjectStore()
        store.project.sourceImagePath = input.path
        await store.runInfoAndFrame()
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.project.framedImagePath)
        XCTAssertTrue(store.status.contains("Choose a device"), store.status)
        store.project.deviceName = "MacBook Pro PROLED 16"
        await store.refreshColors()
        await store.frameNow()
        XCTAssertNil(store.lastError)
        let output = try XCTUnwrap(store.project.framedImagePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        XCTAssertNotEqual(output, input.path)
        let png = try await StillRenderer.render(store.project)
        XCTAssertNotNil(NSImage(data: png))
    }
}
