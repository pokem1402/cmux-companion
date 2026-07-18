import Foundation

/// Builds the subprocess environment used by the menu-bar app. GUI apps
/// commonly inherit only the system PATH, which hides user-installed agent
/// CLIs even though they are available in an interactive shell.
public enum CmuxProcessEnvironment {
    /// Returns the trusted, shell-free PATH additions used for cmux child
    /// processes. NVM versions are discovered by enumerating direct children;
    /// no shell expansion or user-controlled command evaluation is involved.
    public static func supplementalPathDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".volta/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".cargo/bin", isDirectory: true),
        ]

        let nvmRoot = homeDirectory
            .appendingPathComponent(".nvm", isDirectory: true)
        let nvmCurrentBin = nvmRoot
            .appendingPathComponent("current/bin", isDirectory: true)
        if isDirectory(nvmCurrentBin, fileManager: fileManager) {
            directories.append(nvmCurrentBin)
        }

        let nvmVersionsRoot = nvmRoot
            .appendingPathComponent("versions/node", isDirectory: true)
        let versionDirectories = (try? fileManager.contentsOfDirectory(
            at: nvmVersionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let installedVersionBins = versionDirectories
            .filter { isDirectory($0, fileManager: fileManager) }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.compare(
                    rhs.lastPathComponent,
                    options: [.numeric, .caseInsensitive]
                ) == .orderedDescending
            }
            .map { $0.appendingPathComponent("bin", isDirectory: true) }
            .filter { isDirectory($0, fileManager: fileManager) }
        directories.append(contentsOf: installedVersionBins)

        directories.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))

        var seen = Set<String>()
        return directories.compactMap { url in
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, !path.contains(":"), seen.insert(path).inserted else {
                return nil
            }
            return path
        }
    }

    /// Preserves the inherited PATH order, then appends missing trusted GUI
    /// candidates. Empty PATH components are dropped so they cannot mean the
    /// current working directory.
    public static func augmented(
        _ environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var result = environment
        let inherited = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let candidates = supplementalPathDirectories(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )

        var seen = Set<String>()
        let path = (inherited + candidates).filter { entry in
            !entry.isEmpty && !entry.contains(":") && seen.insert(entry).inserted
        }
        result["PATH"] = path.joined(separator: ":")
        return result
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

public struct CmuxExecutableLocator: Sendable {
    public var explicitURL: URL?
    public var environment: [String: String]
    public var applicationsDirectory: URL
    public var homeDirectory: URL

    public init(
        explicitURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.explicitURL = explicitURL
        self.environment = environment
        self.applicationsDirectory = applicationsDirectory
        self.homeDirectory = homeDirectory
    }

    public var candidateURLs: [URL] {
        var candidates: [URL] = []
        if let explicitURL { candidates.append(explicitURL) }

        for key in ["CMUX_BIN", "CMUX_EXECUTABLE"] {
            if let value = environment[key], !value.isEmpty {
                candidates.append(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
            }
        }

        candidates.append(
            applicationsDirectory
                .appendingPathComponent("cmux.app", isDirectory: true)
                .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
        )
        candidates.append(
            homeDirectory
                .appendingPathComponent("Applications/cmux.app", isDirectory: true)
                .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
        )

        let path = CmuxProcessEnvironment.augmented(
            environment,
            homeDirectory: homeDirectory
        )["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            candidates.append(
                URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("cmux", isDirectory: false)
            )
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public func resolve(fileManager: FileManager = .default) throws -> URL {
        for candidate in candidateURLs where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw CmuxProcessError.executableNotFound(searchedPaths: candidateURLs.map(\.path))
    }
}

public struct CmuxProcessResult: Sendable, Equatable {
    public let arguments: [String]
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public var stdout: String { String(decoding: standardOutput, as: UTF8.self) }
    public var stderr: String { String(decoding: standardError, as: UTF8.self) }

    public init(
        arguments: [String],
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data
    ) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// A display-ready interpretation of `cmux hooks setup` output. cmux exits
/// successfully even when every supported agent is skipped, so the final
/// summary line must be inspected to avoid reporting a false success.
public struct CmuxHooksSetupSummary: Sendable, Equatable {
    public let installedCount: Int?
    public let skippedCount: Int?
    public let output: String

    public var installedAny: Bool? {
        installedCount.map { $0 > 0 }
    }

    public init(stdout: String, stderr: String, maximumCharacters: Int = 2_000) {
        let stdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if stdout.isEmpty {
            combined = stderr
        } else if stderr.isEmpty {
            combined = stdout
        } else {
            combined = "\(stdout)\n\nstderr:\n\(stderr)"
        }
        output = Self.truncated(combined, maximumCharacters: maximumCharacters)

        let pattern = #"Done:\s+(\d+)\s+installed,\s+(\d+)\s+skipped"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(
                  in: combined,
                  range: NSRange(combined.startIndex..., in: combined)
              ).last,
              let installedRange = Range(match.range(at: 1), in: combined),
              let skippedRange = Range(match.range(at: 2), in: combined) else {
            installedCount = nil
            skippedCount = nil
            return
        }
        installedCount = Int(combined[installedRange])
        skippedCount = Int(combined[skippedRange])
    }

    private static func truncated(_ value: String, maximumCharacters: Int) -> String {
        guard maximumCharacters > 0, value.count > maximumCharacters else { return value }
        let end = value.index(value.startIndex, offsetBy: maximumCharacters)
        return String(value[..<end]) + "\n…"
    }
}

public enum CmuxProcessError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound(searchedPaths: [String])
    case launchFailed(command: [String], message: String)
    case nonZeroExit(command: [String], exitCode: Int32, stdout: String, stderr: String)

    public var command: [String]? {
        switch self {
        case .executableNotFound: return nil
        case .launchFailed(let command, _), .nonZeroExit(let command, _, _, _): return command
        }
    }

    public var exitCode: Int32? {
        guard case .nonZeroExit(_, let code, _, _) = self else { return nil }
        return code
    }

    public var stderr: String? {
        guard case .nonZeroExit(_, _, _, let stderr) = self else { return nil }
        return stderr
    }

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let paths):
            return "Could not find the cmux executable. Searched: \(paths.joined(separator: ", "))"
        case .launchFailed(let command, let message):
            return "Could not launch \(command.joined(separator: " ")): \(message)"
        case .nonZeroExit(let command, let exitCode, _, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command.joined(separator: " ")) exited with status \(exitCode)"
                + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}

public protocol CmuxCommandRunning: Sendable {
    func run(arguments: [String], environment: [String: String]) async throws -> CmuxProcessResult
}

public extension CmuxCommandRunning {
    func run(arguments: [String]) async throws -> CmuxProcessResult {
        try await run(arguments: arguments, environment: [:])
    }
}

public protocol CmuxLineStreaming: Sendable {
    func streamLines(
        arguments: [String],
        environment: [String: String]
    ) -> AsyncThrowingStream<String, Error>
}

public extension CmuxLineStreaming {
    func streamLines(arguments: [String]) -> AsyncThrowingStream<String, Error> {
        streamLines(arguments: arguments, environment: [:])
    }
}

/// Runs cmux without a shell, so labels, UUIDs, and RPC JSON are passed as
/// literal argv values. Every invocation owns its Process and is safe to retry.
public final class CmuxProcessRunner: CmuxCommandRunning, CmuxLineStreaming, @unchecked Sendable {
    public let executableURL: URL
    public let baseEnvironment: [String: String]

    public init(
        executableURL: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.baseEnvironment = baseEnvironment
    }

    public convenience init(
        locator: CmuxExecutableLocator = CmuxExecutableLocator(),
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            executableURL: locator.resolve(fileManager: fileManager),
            baseEnvironment: CmuxProcessEnvironment.augmented(
                locator.environment,
                homeDirectory: locator.homeDirectory,
                fileManager: fileManager
            )
        )
    }

    public func run(
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> CmuxProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let processBox = CancellableProcessBox(process: process)
        let termination = ProcessTerminationLatch()
        let command = [executableURL.path] + arguments

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = baseEnvironment.merging(environment) { _, override in override }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { terminatedProcess in
            termination.complete(status: terminatedProcess.terminationStatus)
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                throw CmuxProcessError.launchFailed(command: command, message: error.localizedDescription)
            }

            processBox.terminateIfCancellationWasRequested()

            let stdoutTask = Task.detached { () throws -> Data in
                try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
            }
            let stderrTask = Task.detached { () throws -> Data in
                try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
            }

            let status = await termination.wait()
            let standardOutput = try await stdoutTask.value
            let standardError = try await stderrTask.value
            try Task.checkCancellation()

            let result = CmuxProcessResult(
                arguments: arguments,
                exitCode: status,
                standardOutput: standardOutput,
                standardError: standardError
            )
            guard status == 0 else {
                throw CmuxProcessError.nonZeroExit(
                    command: command,
                    exitCode: status,
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            }
            return result
        } onCancel: {
            processBox.cancel()
        }
    }

    public func streamLines(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let execution = CmuxStreamingProcess(
                executableURL: executableURL,
                arguments: arguments,
                environment: baseEnvironment.merging(environment) { _, override in override },
                continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in execution.cancel() }
            execution.start()
        }
    }
}

private final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancellationRequested = false

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let shouldTerminate = process.isRunning
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    func terminateIfCancellationWasRequested() {
        lock.lock()
        let shouldTerminate = cancellationRequested && process.isRunning
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }
}

private final class ProcessTerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func complete(status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            self.status = status
            lock.unlock()
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class CmuxStreamingProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private var stdoutTail = Data()
    private var stderrData = Data()
    private var processStatus: Int32?
    private var stdoutEnded = false
    private var stderrEnded = false
    private var finished = false
    private static let diagnosticLimit = 256 * 1_024

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.continuation = continuation
    }

    func start() {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.receiveTermination(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            finishImmediately(
                throwing: CmuxProcessError.launchFailed(
                    command: [executableURL.path] + arguments,
                    message: error.localizedDescription
                )
            )
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = nil
        lock.unlock()
        clearHandlers()
        if process.isRunning { process.terminate() }
    }

    private func receiveStdout(_ data: Data) {
        var lines: [String] = []
        var shouldAttemptFinish = false

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if data.isEmpty {
            stdoutEnded = true
            if !stdoutBuffer.isEmpty {
                lines.append(String(decoding: stdoutBuffer, as: UTF8.self))
                stdoutBuffer.removeAll(keepingCapacity: false)
            }
            shouldAttemptFinish = true
        } else {
            appendDiagnosticTail(data, to: &stdoutTail)
            stdoutBuffer.append(data)
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                var lineData = stdoutBuffer[..<newline]
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                lines.append(String(decoding: lineData, as: UTF8.self))
                stdoutBuffer.removeSubrange(...newline)
            }
        }
        let continuation = self.continuation
        lock.unlock()

        for line in lines { continuation?.yield(line) }
        if shouldAttemptFinish { finishIfReady() }
    }

    private func receiveStderr(_ data: Data) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if data.isEmpty {
            stderrEnded = true
        } else {
            appendDiagnosticTail(data, to: &stderrData)
        }
        let shouldAttemptFinish = data.isEmpty
        lock.unlock()
        if shouldAttemptFinish { finishIfReady() }
    }

    private func receiveTermination(status: Int32) {
        lock.lock()
        processStatus = status
        lock.unlock()
        finishIfReady()
    }

    private func finishIfReady() {
        let action: (AsyncThrowingStream<String, Error>.Continuation, Error?)?

        lock.lock()
        guard !finished, let processStatus, stdoutEnded, stderrEnded, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        if processStatus == 0 {
            action = (continuation, nil)
        } else {
            action = (
                continuation,
                CmuxProcessError.nonZeroExit(
                    command: [executableURL.path] + arguments,
                    exitCode: processStatus,
                    stdout: String(decoding: stdoutTail, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                )
            )
        }
        lock.unlock()

        clearHandlers()
        if let error = action?.1 {
            action?.0.finish(throwing: error)
        } else {
            action?.0.finish()
        }
    }

    private func finishImmediately(throwing error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        clearHandlers()
        continuation?.finish(throwing: error)
    }

    private func clearHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }

    private func appendDiagnosticTail(_ data: Data, to target: inout Data) {
        target.append(data)
        if target.count > Self.diagnosticLimit {
            target.removeFirst(target.count - Self.diagnosticLimit)
        }
    }
}
