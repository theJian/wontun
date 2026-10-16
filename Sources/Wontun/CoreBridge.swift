import Foundation
import Darwin

struct CoreFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// A serial worker keeps blocking pipe I/O off the main actor and preserves request order.
final class CoreBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.wontun.core", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private let executableOverride: URL?
    private let directoryOverride: URL?

    init(executable: URL? = nil, directory: URL? = nil) {
        executableOverride = executable
        directoryOverride = directory
    }

    func request(_ payload: JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.exchange(payload)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func launch() throws {
        if let process {
            guard process.isRunning else { throw CoreFailure(message: "The Rust backend stopped. Quit and reopen Wontun.") }
            return
        }
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wontun-core")
        let environment = ProcessInfo.processInfo.environment
        let executable = executableOverride ?? environment["WONTUN_CORE_PATH"].map { URL(fileURLWithPath: $0) } ?? bundle
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CoreFailure(message: "Rust backend not found. Build Wontun.app with scripts/build-app.sh, or set WONTUN_CORE_PATH when using swift run.")
        }
        let support = try directoryOverride ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = directoryOverride?.path ?? environment["WONTUN_DATA_DIR"] ?? support.appendingPathComponent("Wontun").path
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["--data-dir", directory]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }
    private func exchange(_ payload: JSONValue) throws -> JSONValue {
        try launch()
        var data = try JSONEncoder().encode(payload)
        data.append(10)
        guard data.count <= 8 * 1024 * 1024 else { throw CoreFailure(message: "Import is too large (8 MiB maximum).") }
        try input?.write(contentsOf: data)
        while !pending.contains(10) {
            guard let output else { throw CoreFailure(message: "Backend output is unavailable.") }
            var buffer = [UInt8](repeating: 0, count: 65536)
            // FileHandle.read(upToCount:) can wait for the requested count on a pipe.
            // A single POSIX read returns the available response without waiting for EOF.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw CoreFailure(message: "The Rust backend closed the connection. Check that another Wontun instance is not already running.")
            }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count < 32 * 1024 * 1024 else { throw CoreFailure(message: "Backend response is too large.") }
        }
        let end = pending.firstIndex(of: 10)!
        let line = pending[..<end]
        pending.removeSubrange(...end)
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(line))
        if response["ok"] == .bool(true), let result = response["result"] { return result }
        throw CoreFailure(message: response["error"]?.string ?? "Unknown backend error")
    }
    func shutdown() async {
        _ = try? await request(.object(["command": .string("shutdown")]))
        await withCheckedContinuation { continuation in
            queue.async {
                try? self.input?.close()
                self.process?.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
