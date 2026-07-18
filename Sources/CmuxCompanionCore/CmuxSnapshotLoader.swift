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
    public let feed: CmuxSnapshotPart<CmuxFeedSnapshot>
    public let notifications: CmuxSnapshotPart<CmuxNotificationsSnapshot>
    public let loadedAt: Date

    public var failures: [CmuxSnapshotFailure] {
        [tree.failure, sessions.failure, feed.failure, notifications.failure].compactMap { $0 }
    }

    public init(
        tree: CmuxSnapshotPart<CmuxTreeSnapshot>,
        sessions: CmuxSnapshotPart<CmuxSessionsSnapshot>,
        feed: CmuxSnapshotPart<CmuxFeedSnapshot>,
        notifications: CmuxSnapshotPart<CmuxNotificationsSnapshot>,
        loadedAt: Date = Date()
    ) {
        self.tree = tree
        self.sessions = sessions
        self.feed = feed
        self.notifications = notifications
        self.loadedAt = loadedAt
    }
}

/// Collects independent cmux snapshots concurrently. A stopped socket can make
/// tree/feed/notifications unavailable while `sessions` remains readable from
/// disk, so each result is intentionally represented separately.
public final class CmuxSnapshotLoader: Sendable {
    // cmux defaults to short refs (`workspace:1`, `surface:2`) in output.
    // Persistent linking and the first-party cmux:// deep links require UUIDs.
    public static let treeArguments = ["--id-format", "uuids", "tree", "--all", "--json"]
    public static let sessionsArguments = ["sessions", "--all", "--json"]
    public static let feedArguments = ["rpc", "feed.list", "{}"]
    public static let notificationsArguments = ["--json", "list-notifications"]

    private let runner: any CmuxCommandRunning

    public init(runner: any CmuxCommandRunning) {
        self.runner = runner
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

    private func loadJSON(arguments: [String]) async throws -> JSONValue {
        let result = try await runner.run(arguments: arguments)
        guard !result.standardOutput.isEmpty else {
            throw CmuxTransportError.emptyOutput(command: arguments)
        }
        return try CmuxJSON.decode(result.standardOutput)
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
