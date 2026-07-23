import Foundation

public struct CmuxSnapshotFailure: Error, LocalizedError, Sendable, Equatable {
    public let command: [String]
    public let message: String
    public let exitCode: Int32?
    public let stderr: String?

    public init(command: [String], error: Error) {
        self.command = command
        self.message = error.localizedDescription
        if let processError = error as? CmuxProcessError {
            self.exitCode = processError.exitCode
            self.stderr = processError.stderr
        } else {
            self.exitCode = nil
            self.stderr = nil
        }
    }

    public var errorDescription: String? { message }
}

public enum CmuxSnapshotPart<Value: Sendable>: Sendable {
    case success(Value)
    case failure(CmuxSnapshotFailure)

    public var value: Value? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    public var failure: CmuxSnapshotFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

extension CmuxSnapshotPart: Equatable where Value: Equatable {}

public struct CmuxTransportSnapshot: Sendable, Equatable {
    public let tree: CmuxSnapshotPart<CmuxTreeSnapshot>
    public let sessions: CmuxSnapshotPart<CmuxSessionsSnapshot>
    public let top: CmuxSnapshotPart<CmuxTopSnapshot>
    public let feed: CmuxSnapshotPart<CmuxFeedSnapshot>
    public let notifications: CmuxSnapshotPart<CmuxNotificationsSnapshot>
    public let loadedAt: Date

    public var failures: [CmuxSnapshotFailure] {
        // Live process inspection is an optional badge enhancement. A cmux
        // build that cannot provide it must not make an otherwise healthy
        // tree/session connection look broken in the UI.
        [tree.failure, sessions.failure, feed.failure, notifications.failure].compactMap { $0 }
    }

    public init(
        tree: CmuxSnapshotPart<CmuxTreeSnapshot>,
        sessions: CmuxSnapshotPart<CmuxSessionsSnapshot>,
        top: CmuxSnapshotPart<CmuxTopSnapshot>,
        feed: CmuxSnapshotPart<CmuxFeedSnapshot>,
        notifications: CmuxSnapshotPart<CmuxNotificationsSnapshot>,
        loadedAt: Date = Date()
    ) {
        self.tree = tree
        self.sessions = sessions
        self.top = top
        self.feed = feed
        self.notifications = notifications
        self.loadedAt = loadedAt
    }

    /// Source-compatible initializer for clients that construct transport
    /// snapshots without the optional live-process enhancement.
    public init(
        tree: CmuxSnapshotPart<CmuxTreeSnapshot>,
        sessions: CmuxSnapshotPart<CmuxSessionsSnapshot>,
        feed: CmuxSnapshotPart<CmuxFeedSnapshot>,
        notifications: CmuxSnapshotPart<CmuxNotificationsSnapshot>,
        loadedAt: Date = Date()
    ) {
        self.init(
            tree: tree,
            sessions: sessions,
            top: .failure(CmuxSnapshotFailure(
                command: CmuxSnapshotLoader.topArguments,
                error: CmuxTopUnavailableError()
            )),
            feed: feed,
            notifications: notifications,
            loadedAt: loadedAt
        )
    }
}

/// Collects independent cmux snapshots concurrently. A stopped socket can make
/// tree/top/feed/notifications unavailable while `sessions` remains readable
/// from disk, so each result is intentionally represented separately.
public final class CmuxSnapshotLoader: Sendable {
    // cmux defaults to short refs (`workspace:1`, `surface:2`) in output.
    // Persistent linking and the first-party cmux:// deep links require UUIDs.
    public static let treeArguments = ["--id-format", "uuids", "tree", "--all", "--json"]
    public static let sessionsArguments = ["sessions", "--all", "--json"]
    public static let topArguments = [
        "--id-format", "uuids", "top", "--all", "--processes", "--flat", "--format", "tsv",
    ]
    public static let feedArguments = ["rpc", "feed.list", "{}"]
    public static let notificationsArguments = ["--json", "list-notifications"]

    private let runner: any CmuxCommandRunning
    private let topTimeout: Duration
    private let remoteScreenTimeout: Duration

    public init(
        runner: any CmuxCommandRunning,
        topTimeout: Duration = .seconds(2),
        remoteScreenTimeout: Duration = .seconds(1)
    ) {
        self.runner = runner
        self.topTimeout = topTimeout
        self.remoteScreenTimeout = remoteScreenTimeout
    }

    public static func remoteScreenArguments(surfaceID: String) -> [String] {
        ["read-screen", "--surface", surfaceID, "--lines", "16"]
    }

    public convenience init(locator: CmuxExecutableLocator = CmuxExecutableLocator()) throws {
        try self.init(runner: CmuxProcessRunner(locator: locator))
    }

    public func load() async -> CmuxTransportSnapshot {
        async let tree = loadPart(
            arguments: Self.treeArguments,
            normalize: { CmuxTreeSnapshot(raw: $0) }
        )
        async let sessions = loadPart(
            arguments: Self.sessionsArguments,
            normalize: { CmuxSessionsSnapshot(raw: $0) }
        )
        async let top = loadTextPart(
            arguments: Self.topArguments,
            timeout: topTimeout,
            normalize: { [self] text in
                await addRemoteScreenEvidence(to: try CmuxTopSnapshot(tsv: text))
            }
        )
        async let feed = loadPart(
            arguments: Self.feedArguments,
            normalize: { CmuxFeedSnapshot(raw: $0) }
        )
        async let notifications = loadPart(
            arguments: Self.notificationsArguments,
            normalize: { CmuxNotificationsSnapshot(raw: $0) }
        )

        return await CmuxTransportSnapshot(
            tree: tree,
            sessions: sessions,
            top: top,
            feed: feed,
            notifications: notifications
        )
    }

    public func loadTree() async throws -> CmuxTreeSnapshot {
        CmuxTreeSnapshot(raw: try await loadJSON(arguments: Self.treeArguments))
    }

    public func loadSessions() async throws -> CmuxSessionsSnapshot {
        CmuxSessionsSnapshot(raw: try await loadJSON(arguments: Self.sessionsArguments))
    }

    public func loadTop() async throws -> CmuxTopSnapshot {
        await addRemoteScreenEvidence(
            to: try CmuxTopSnapshot(tsv: await loadText(arguments: Self.topArguments))
        )
    }

    public func loadFeed() async throws -> CmuxFeedSnapshot {
        CmuxFeedSnapshot(raw: try await loadJSON(arguments: Self.feedArguments))
    }

    public func loadNotifications() async throws -> CmuxNotificationsSnapshot {
        CmuxNotificationsSnapshot(raw: try await loadJSON(arguments: Self.notificationsArguments))
    }

    private func loadPart<Value: Sendable>(
        arguments: [String],
        normalize: @Sendable (JSONValue) -> Value
    ) async -> CmuxSnapshotPart<Value> {
        do {
            return .success(normalize(try await loadJSON(arguments: arguments)))
        } catch {
            return .failure(CmuxSnapshotFailure(command: arguments, error: error))
        }
    }

    private func loadTextPart<Value: Sendable>(
        arguments: [String],
        timeout: Duration,
        normalize: @escaping @Sendable (String) async throws -> Value
    ) async -> CmuxSnapshotPart<Value> {
        do {
            let text = try await loadText(arguments: arguments, timeout: timeout)
            return .success(try await normalize(text))
        } catch {
            return .failure(CmuxSnapshotFailure(command: arguments, error: error))
        }
    }

    private func addRemoteScreenEvidence(to snapshot: CmuxTopSnapshot) async -> CmuxTopSnapshot {
        guard !snapshot.remoteProbeSurfaceIDs.isEmpty else { return snapshot }

        let screenTextBySurfaceID = await withTaskGroup(
            of: (String, String?).self,
            returning: [String: String].self
        ) { group in
            for surfaceID in snapshot.remoteProbeSurfaceIDs.sorted() {
                group.addTask { [self] in
                    let arguments = Self.remoteScreenArguments(surfaceID: surfaceID)
                    let text = try? await loadText(
                        arguments: arguments,
                        timeout: remoteScreenTimeout
                    )
                    return (surfaceID, text)
                }
            }

            var result: [String: String] = [:]
            for await (surfaceID, text) in group {
                if let text { result[surfaceID] = text }
            }
            return result
        }
        return snapshot.addingRemoteScreenEvidence(screenTextBySurfaceID)
    }

    private func loadJSON(arguments: [String]) async throws -> JSONValue {
        try CmuxJSON.decode(await loadData(arguments: arguments))
    }

    private func loadText(arguments: [String]) async throws -> String {
        let data = try await loadData(arguments: arguments)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CmuxTransportError.invalidUTF8
        }
        return value
    }

    private func loadText(arguments: [String], timeout: Duration) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [self] in
                try await loadText(arguments: arguments)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                try Task.checkCancellation()
                throw CmuxSnapshotTimeoutError(command: arguments)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    private func loadData(arguments: [String]) async throws -> Data {
        let result = try await runner.run(arguments: arguments)
        guard !result.standardOutput.isEmpty else {
            throw CmuxTransportError.emptyOutput(command: arguments)
        }
        return result.standardOutput
    }
}

private struct CmuxSnapshotTimeoutError: Error, LocalizedError, Sendable {
    let command: [String]

    var errorDescription: String? {
        "Timed out while loading optional cmux process data: \(command.joined(separator: " "))"
    }
}

private struct CmuxTopUnavailableError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "Optional cmux process data was not supplied"
    }
}

public struct CmuxFocusTarget: Sendable, Equatable {
    public var windowID: String?
    public var workspaceID: String?
    public var surfaceID: String?

    public init(windowID: String? = nil, workspaceID: String? = nil, surfaceID: String? = nil) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }
}

/// Command-side operations are kept separate from snapshots so the event
/// stream always has its own cmux process/socket connection.
public final class CmuxCommandClient: Sendable {
    private let runner: any CmuxCommandRunning

    public init(runner: any CmuxCommandRunning) {
        self.runner = runner
    }

    public convenience init(locator: CmuxExecutableLocator = CmuxExecutableLocator()) throws {
        try self.init(runner: CmuxProcessRunner(locator: locator))
    }

    @discardableResult
    public func focusWindow(_ windowID: String) async throws -> CmuxProcessResult {
        try await runner.run(arguments: ["focus-window", "--window", windowID])
    }

    @discardableResult
    public func selectWorkspace(_ workspaceID: String, windowID: String? = nil) async throws -> CmuxProcessResult {
        var arguments = ["workspace", "select", workspaceID]
        if let windowID { arguments += ["--window", windowID] }
        return try await runner.run(arguments: arguments)
    }

    @discardableResult
    public func focusSurface(
        _ surfaceID: String,
        workspaceID: String? = nil,
        windowID: String? = nil
    ) async throws -> CmuxProcessResult {
        var arguments = ["focus-panel", "--panel", surfaceID]
        if let workspaceID { arguments += ["--workspace", workspaceID] }
        if let windowID { arguments += ["--window", windowID] }
        return try await runner.run(arguments: arguments)
    }

    @discardableResult
    public func renameSurface(
        _ surfaceID: String,
        title: String,
        workspaceID: String? = nil,
        windowID: String? = nil
    ) async throws -> CmuxProcessResult {
        var arguments = ["rename-tab", "--surface", surfaceID]
        if let workspaceID { arguments += ["--workspace", workspaceID] }
        if let windowID { arguments += ["--window", windowID] }
        arguments.append(title)
        return try await runner.run(arguments: arguments)
    }

    /// Focuses from broadest to narrowest. UUIDs are passed literally and cmux
    /// resolves the corresponding window/workspace/surface.
    public func focus(_ target: CmuxFocusTarget) async throws {
        if let windowID = target.windowID {
            try await focusWindow(windowID)
        }
        if let workspaceID = target.workspaceID {
            try await selectWorkspace(workspaceID, windowID: target.windowID)
        }
        if let surfaceID = target.surfaceID {
            try await focusSurface(
                surfaceID,
                workspaceID: target.workspaceID,
                windowID: target.windowID
            )
        }
    }
}
