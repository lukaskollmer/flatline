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
        // The readers get threads of their own: callers (e.g. tests on Swift
        // concurrency's thread pool) block while waiting for them, and once as
        // many callers as there are cores block, GCD starts no threads for its
        // global queues, so readers queued there would never run.
        let collected = Collected()
        let group = DispatchGroup()
        if !passthrough {
            for (pipe, keyPath) in [(output, \Collected.output), (errorOutput, \Collected.errorOutput)] {
                group.enter()
                Thread {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    collected.set(keyPath, data)
                    group.leave()
                }.start()
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
            let command = ([program] + arguments).joined(separator: " ")
            let log = summarize(result.output + "\n" + result.errorOutput)
            throw FlatlineError("\(command) failed with exit status \(result.status)" + (log.isEmpty ? "" : ":\n\(log)"))
        }
        return result
    }

    /// The error lines of a (build) log, or its last lines if there are none.
    /// Compiler command lines can be many kilobytes long, so lines are shortened.
    static func summarize(_ log: String) -> String {
        let lines = log
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var errors: [String] = []
        for line in lines where line.contains("error:") && !errors.contains(line) {
            errors.append(line)
        }
        let selected = errors.isEmpty ? Array(lines.suffix(20)) : Array(errors.prefix(20))
        return selected
            .map { $0.count > 300 ? $0.prefix(300) + "…" : $0 }
            .joined(separator: "\n")
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
