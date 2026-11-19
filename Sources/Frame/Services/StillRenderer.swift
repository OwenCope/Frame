import Foundation

enum StillRenderer {
    static func render(_ project: Project, videoOutput: URL? = nil) async throws -> Data {
        let document = try project.documentData()
        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: directory) }
            let input = directory.appendingPathComponent("preview.frameproj")
            let output = videoOutput ?? directory.appendingPathComponent("preview.png")
            try document.write(to: input)
            let relativeScript = videoOutput == nil ? "FrameCore/Renderer.py" : "FrameMotion/render_video.py"
            let bundled = Bundle.main.resourceURL?.appendingPathComponent(relativeScript)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(relativeScript)
            let script = bundled.flatMap { manager.fileExists(atPath: $0.path) ? $0 : nil } ?? source
            let process = Process()
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(manager.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let python = ProcessInfo.processInfo.environment["FRAME_PYTHON"] ?? "/usr/bin/python3"
            process.arguments = [python, script.path, input.path, "-o", output.path]
            if videoOutput == nil { process.arguments?.append("--json") }
            let log = directory.appendingPathComponent("render.log")
            manager.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "Rendering failed."
                throw FramesError.decode(detail)
            }
            return videoOutput == nil ? try Data(contentsOf: output) : Data()
        }.value
    }
}
