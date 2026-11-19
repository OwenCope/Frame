import Foundation

// MARK: - Errors

enum FramesError: LocalizedError, Sendable {
    case binaryNotFound
    case failed(status: Int32, stderr: String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Could not find the `frames` binary. Install it and ensure it is on PATH or at ~/.local/bin/frames."
        case let .failed(status, stderr):
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`frames` exited with status \(status).\(tail.isEmpty ? "" : " \(tail)")"
        case let .decode(detail):
            return "Could not read `frames --json` output. \(detail)"
        }
    }
}

// MARK: - JSON models (match `frames --json info` / `frames --json frame`)

struct FrameInfo: Codable, Sendable {
    var file: String?
    var name: String?
    var width: Int?
    var height: Int?
    var device: String?
    var primaryMatch: String?
    var colors: [String]?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case file, name, width, height, device, colors, error
        case primaryMatch = "primary_match"
    }
}

struct FrameResult: Codable, Sendable {
    var source: String?
    var device: String?
    var color: String?
    var output: String?
    /// Absolute path resolved by the bridge (CLI may emit a bare filename).
    var resolvedOutputPath: String = ""

    enum CodingKeys: String, CodingKey {
        case source, device, color, output
    }
}

struct FramedDevice: Identifiable, Hashable, Sendable {
    var id: String { name }
    var family: String
    var name: String
    var width: Int?
    var detail: String?
}

struct FramedColor: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var isDefault: Bool
}

// MARK: - Bridge

/// Runs the `frames` CLI via Process and parses its output.
/// Device and color tables are NEVER hardcoded: they are parsed live from
/// `frames list` and `frames list-colors`. JSON is used for info/frame
/// (the only subcommands that support --json); list output is human text
/// and is parsed as such.
struct FramesBridge: Sendable {
    /// Ordered candidates; FRAMES_BIN wins when set.
    static func binaryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["FRAMES_BIN"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/frames",
            "\(home)/bin/frames",
            "/opt/homebrew/bin/frames",
            "/usr/local/bin/frames",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to PATH lookup through /usr/bin/env.
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    static func arguments(prepending binary: URL, args: [String]) -> [String] {
        binary.lastPathComponent == "env" ? ["frames"] + args : args
    }

    @discardableResult
    func run(_ args: [String], cwd: URL? = nil) async throws -> String {
        let binary = try Self.binaryURL()
        let finalArgs = Self.arguments(prepending: binary, args: args)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = finalArgs
                if let cwd { process.currentDirectoryURL = cwd }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                process.waitUntilExit()
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: outData, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: FramesError.failed(
                        status: process.terminationStatus,
                        stderr: errText.isEmpty ? text : errText
                    ))
                    return
                }
                cont.resume(returning: text)
            }
        }
    }

    // MARK: Devices

    func listDevices() async throws -> [FramedDevice] {
        let text = try await run(["list"])
        return Self.parseDevices(text)
    }

    /// Parses `frames list` human output:
    /// family headers are bare lines; entries look like
    /// `   1179px → iPhone 16 Portrait (5 colors)`.
    static func parseDevices(_ text: String) -> [FramedDevice] {
        var devices: [FramedDevice] = []
        var seen = Set<String>()
        var family = "Other"
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "Supported Devices" { continue }
            if line.hasPrefix("Manual frames") { family = "Manual frames"; continue }
            if line.hasPrefix("Default Variants") { family = "Default Variants"; continue }
            if family == "Manual frames", !line.contains("→") {
                if seen.insert(line).inserted {
                    devices.append(FramedDevice(family: family, name: line))
                }
                continue
            }
            if family == "Default Variants" {
                if let arrow = line.range(of: "→") {
                    let name = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if seen.insert(name).inserted {
                        devices.append(FramedDevice(family: family, name: name))
                    }
                }
                continue
            }
            guard rawLine.first == " " || rawLine.first == "\t" else {
                if !line.contains("→") && !line.lowercased().contains("supported") {
                    family = line
                }
                continue
            }
            // Entry line.
            guard let arrow = line.range(of: "→") ?? line.range(of: "->") else { continue }
            let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            var right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !right.isEmpty else { continue }
            let width = Int(left.replacingOccurrences(of: "px", with: "")
                .trimmingCharacters(in: .whitespaces))
            var detail: String?
            if let open = right.lastIndex(of: "("), let close = right.lastIndex(of: ")"),
               open < close, close == right.index(before: right.endIndex)
            {
                detail = String(right[right.index(after: open) ..< close])
                right = right[..<open].trimmingCharacters(in: .whitespaces)
            }
            guard seen.insert(String(right)).inserted else { continue }
            devices.append(FramedDevice(
                family: family,
                name: String(right),
                width: width,
                detail: detail
            ))
        }
        return devices
    }

    // MARK: Colors

    func listColors(device: String) async throws -> [FramedColor] {
        let text = try await run(["list-colors", device])
        return Self.parseColors(text)
    }

    /// Parses `frames list-colors` human output: `    1. Silver (default)`.
    static func parseColors(_ text: String) -> [FramedColor] {
        var colors: [FramedColor] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.first?.isNumber == true else { continue }
            guard let dot = line.firstIndex(of: ".") else { continue }
            var name = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var isDefault = false
            if name.hasSuffix("(default)") {
                isDefault = true
                name = name.replacingOccurrences(of: "(default)", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            colors.append(FramedColor(name: name, isDefault: isDefault))
        }
        return colors
    }

    // MARK: Info / frame (JSON)

    func info(file: URL) async throws -> FrameInfo {
        let text = try await run(["--json", "info", file.path])
        guard let data = text.data(using: .utf8) else {
            throw FramesError.decode("info output was not UTF-8.")
        }
        do {
            return try JSONDecoder().decode(FrameInfo.self, from: data)
        } catch {
            // `info` on multiple files emits an array; surface the first entry.
            if let array = try? JSONDecoder().decode([FrameInfo].self, from: data),
               let first = array.first
            {
                return first
            }
            throw FramesError.decode(error.localizedDescription)
        }
    }

    @discardableResult
    func frame(input: URL, device: String?, color: String?, outputDir: URL? = nil) async throws -> FrameResult {
        var args = ["--json", "frame"]
        if let device, !device.isEmpty { args += ["--device", device] }
        if let color, !color.isEmpty { args += ["--color", color] }
        if let outputDir { args += ["--output", outputDir.path] }
        args.append(input.path)
        let text = try await run(args, cwd: input.deletingLastPathComponent())
        guard let data = text.data(using: .utf8) else {
            throw FramesError.decode("frame output was not UTF-8.")
        }
        var result: FrameResult
        do {
            result = try JSONDecoder().decode(FrameResult.self, from: data)
        } catch {
            if let array = try? JSONDecoder().decode([FrameResult].self, from: data),
               let first = array.first
            {
                result = first
            } else {
                throw FramesError.decode(error.localizedDescription)
            }
        }
        result.resolvedOutputPath = Self.resolve(output: result.output, relativeTo: outputDir ?? input.deletingLastPathComponent())
        guard !result.resolvedOutputPath.isEmpty,
              FileManager.default.fileExists(atPath: result.resolvedOutputPath) else {
            throw FramesError.decode("Framing did not produce an image file.")
        }
        return result
    }

    static func resolve(output: String?, relativeTo dir: URL) -> String {
        guard let output, !output.isEmpty else { return "" }
        if output.hasPrefix("/") { return output }
        return dir.appendingPathComponent(output).path
    }
}
