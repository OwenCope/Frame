// FramesCLI.swift
// Thin Process wrapper around the `frames` CLI. Array args only (never string
// interpolation into a shell); timeout + stderr capture; setup_required handling.

import Foundation

/// Errors raised by FramesCLI.
public enum FramesError: Error, Equatable {
    /// The asset pack is missing or outdated; the user must run `frames setup`.
    case setupRequired(String)
    /// The CLI reported a regular failure (message, exit code, stderr).
    case cliFailed(message: String, code: Int32, stderr: String)
    /// The CLI timed out (message). The process was terminated.
    case timedOut(String)
    /// CLI output was not the expected JSON.
    case badOutput(String)
}

extension FramesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .setupRequired(let m): return "frames setup required: \(m)"
        case .cliFailed(let m, let c, _): return "frames failed (exit \(c)): \(m)"
        case .timedOut(let m): return "frames timed out: \(m)"
        case .badOutput(let m): return "frames bad output: \(m)"
        }
    }
}

/// Framed-image result parsed from `frames --json frame` output.
public struct FramedResult: Codable, Equatable {
    public var source: String
    public var device: String
    public var color: String?
    public var output: String
    public var frameSize: String?

    private enum CodingKeys: String, CodingKey {
        case source, device, color, output
        case frameSize = "frame_size"
    }
}

/// Device detection result parsed from `frames --json info` output.
public struct InfoResult: Codable, Equatable {
    public var file: String?
    public var device: String?
    public var color: String?
    public var error: String?
}

/// Doctor result parsed from `frames --json doctor` output.
public struct DoctorResult: Codable, Equatable {
    public var ok: Bool
    public var assetsPath: String?
    public var issues: [String]?

    private enum CodingKeys: String, CodingKey {
        case ok, issues
        case assetsPath = "assets_path"
    }
}

/// Thin wrapper around the `frames` binary. All invocations use an argument
/// array (no shell), with a timeout and captured stderr.
public struct FramesCLI {
    public var executableURL: URL
    public var assetsPath: String?
    public var timeout: TimeInterval

    public init(executableURL: URL = URL(fileURLWithPath: "/Users/owencope/.local/bin/frames"),
                assetsPath: String? = nil,
                timeout: TimeInterval = 120) {
        self.executableURL = executableURL
        self.assetsPath = assetsPath
        self.timeout = timeout
    }

    // MARK: - public API

    /// Detect the device for screenshots: `frames --json info <files>`.
    @discardableResult
    public func info(_ files: [String]) throws -> [InfoResult] {
        let data = try run(["--json", "info"] + files)
        // `info` prints one JSON array for many files, or one object per file.
        if let arr = try? JSONDecoder().decode([InfoResult].self, from: data) {
            return arr
        }
        if let one = try? JSONDecoder().decode(InfoResult.self, from: data) {
            return [one]
        }
        throw FramesError.badOutput("info output is not a JSON object or array")
    }

    /// Frame screenshots: `frames --json frame -d device -c color ...`.
    @discardableResult
    public func frame(files: [String], device: String, color: String? = nil,
                      outputDir: String? = nil) throws -> [FramedResult] {
        var args = ["--json", "frame", "-d", device]
        if let color { args += ["-c", color] }
        if let outputDir { args += ["-o", outputDir] }
        args += files
        let data = try run(args)
        // Single file -> one JSON object; several files -> array.
        if let arr = try? JSONDecoder().decode([FramedResult].self, from: data) {
            return arr
        }
        if let one = try? JSONDecoder().decode(FramedResult.self, from: data) {
            return [one]
        }
        throw FramesError.badOutput("frame output is not a JSON object or array")
    }

    /// Diagnose assets/config: `frames --json doctor`.
    public func doctor() throws -> DoctorResult {
        let data = try run(["--json", "doctor"])
        do {
            return try JSONDecoder().decode(DoctorResult.self, from: data)
        } catch {
            throw FramesError.badOutput("doctor output is not a JSON object")
        }
    }

    // MARK: - process plumbing

    private struct ErrorPayload: Codable {
        var error: String
        var setupRequired: Bool?

        private enum CodingKeys: String, CodingKey {
            case error
            case setupRequired = "setup_required"
        }
    }

    /// Run the CLI with array args, enforcing timeout and mapping
    /// `{"error": ..., "setup_required": true}` to `.setupRequired`.
    @discardableResult
    func run(_ args: [String]) throws -> Data {
        var fullArgs = args
        if let assetsPath {
            fullArgs += ["--assets", assetsPath]
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = fullArgs
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw FramesError.cliFailed(message: error.localizedDescription,
                                        code: -1, stderr: "")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while !finished {
            if !process.isRunning { finished = true; break }
            if Date() > deadline {
                process.terminate()
                // Give it a grace period, then kill.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { process.interrupt() }
                }
                throw FramesError.timedOut(
                    "frames \(fullArgs.joined(separator: " ")) exceeded \(Int(timeout))s")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            // Prefer a structured JSON error when the CLI emits one.
            if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: outData) {
                if payload.setupRequired == true {
                    throw FramesError.setupRequired(payload.error)
                }
                throw FramesError.cliFailed(message: payload.error,
                                            code: process.terminationStatus,
                                            stderr: stderr)
            }
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FramesError.cliFailed(message: msg.isEmpty ? "unknown error" : msg,
                                        code: process.terminationStatus,
                                        stderr: stderr)
        }
        // Even on exit 0, a setup_required payload means assets are unusable.
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: outData),
           payload.setupRequired == true {
            throw FramesError.setupRequired(payload.error)
        }
        return outData
    }
}
