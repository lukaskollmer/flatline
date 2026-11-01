import FlatlineCore
import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public var succeeded: Bool { status == 0 }
}

public enum Shell {
    /// Runs a program found on `PATH`.
    ///
    /// With `passthrough`, the program's output goes straight to standard
    /// error (so standard output stays reserved for results) and isn't captured.
    @discardableResult
    public static func run(
        _ program: String,
        _ arguments: [String],
        in directory: String? = nil,
        environment: [String: String] = [:],
        passthrough: Bool = false
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }

        let output = Pipe()
        let errorOutput = Pipe()
        if passthrough {
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
        } else {
            process.standardOutput = output
            process.standardError = errorOutput
        }

        // Drain both pipes while the process runs, so it can't block on a full pipe.
        let collected = Collected()
        let group = DispatchGroup()
        if !passthrough {
            for (pipe, keyPath) in [(output, \Collected.output), (errorOutput, \Collected.errorOutput)] {
                group.enter()
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    collected.set(keyPath, data)
                    group.leave()
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw FlatlineError("could not run \(program): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        group.wait()

        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: collected.output, as: UTF8.self),
            errorOutput: String(decoding: collected.errorOutput, as: UTF8.self)
        )
    }

    /// Like `run`, but throws with the tail of the output if the program fails.
    @discardableResult
    public static func runChecked(
        _ program: String,
        _ arguments: [String],
        in directory: String? = nil,
        environment: [String: String] = [:],
        passthrough: Bool = false
    ) throws -> ProcessResult {
        let result = try run(program, arguments, in: directory, environment: environment, passthrough: passthrough)
        guard result.succeeded else {
            let log = (result.output + "\n" + result.errorOutput)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(40)
                .joined(separator: "\n")
            let command = ([program] + arguments).joined(separator: " ")
            throw FlatlineError("\(command) failed with exit status \(result.status)" + (log.isEmpty ? "" : ":\n\(log)"))
        }
        return result
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    var output = Data()
    var errorOutput = Data()

    func set(_ keyPath: ReferenceWritableKeyPath<Collected, Data>, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        self[keyPath: keyPath] = data
    }
}
