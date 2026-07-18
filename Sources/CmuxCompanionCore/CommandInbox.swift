import Foundation

public enum InboxCommandKind: String, Codable, CaseIterable, Sendable {
    case join
    case leave
    case arm
    case complete
    case snooze
    case rename
    case lastInput
    case heartbeat
}

public struct CmuxContext: Codable, Equatable, Sendable {
    public var windowID: String?
    public var workspaceID: String?
    public var surfaceID: String?
    public var panelID: String?

    public init(
        windowID: String? = nil,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        panelID: String? = nil
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.panelID = panelID
    }

    public var effectiveSurfaceID: String? {
        surfaceID ?? panelID
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case panelID = "panel_id"
    }
}

public struct CommandSource: Codable, Equatable, Sendable {
    public var executable: String
    public var pid: Int32
    public var host: String

    public init(
        executable: String = "CmuxCompanionCore",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        host: String = ProcessInfo.processInfo.hostName
    ) {
        self.executable = executable
        self.pid = pid
        self.host = host
    }
}

/// Flat, versioned wire command written by `cmux-set` and remote helpers.
public struct InboxCommand: Codable, Identifiable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var kind: InboxCommandKind
    public var createdAt: Date
    public var setName: String?
    public var role: MemberRole?
    public var groupID: UUID?
    public var label: String?
    public var agent: String?
    public var session: String?
    public var color: String?
    public var required: Bool?
    public var minutes: Int?
    public var text: String?
    public var state: String?
    public var remote: Bool?
    public var cmuxContext: CmuxContext
    public var source: CommandSource

    public init(
        version: Int = InboxCommand.currentVersion,
        id: UUID = UUID(),
        kind: InboxCommandKind,
        createdAt: Date = Date(),
        setName: String? = nil,
        role: MemberRole? = nil,
        groupID: UUID? = nil,
        label: String? = nil,
        agent: String? = nil,
        session: String? = nil,
        color: String? = nil,
        required: Bool? = nil,
        minutes: Int? = nil,
        text: String? = nil,
        state: String? = nil,
        remote: Bool? = nil,
        cmuxContext: CmuxContext = CmuxContext(),
        source: CommandSource = CommandSource()
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.setName = setName
        self.role = role
        self.groupID = groupID
        self.label = label
        self.agent = agent
        self.session = session
        self.color = color
        self.required = required
        self.minutes = minutes
        self.text = text
        self.state = state
        self.remote = remote
        self.cmuxContext = cmuxContext
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case kind
        case createdAt = "created_at"
        case setName = "set_name"
        case role
        case groupID = "group_id"
        case label
        case agent
        case session
        case color
        case required
        case minutes
        case text
        case state
        case remote
        case cmuxContext = "cmux_context"
        case source
    }
}

public enum CommandInboxError: Error, Equatable, LocalizedError {
    case unsupportedCommandVersion(found: Int, supported: Int, file: URL?)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedCommandVersion(found, supported, file):
            let location = file.map { " in \($0.lastPathComponent)" } ?? ""
            return "Unsupported command version \(found)\(location); this build supports \(supported)."
        }
    }
}

/// A small file queue. Producers publish unique JSON files atomically;
/// consumers decode the complete batch before removing any file.
public final class CommandInbox: @unchecked Sendable {
    public let directoryURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        directoryURL: URL = CompanionPaths.defaultCommandsDirectory,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func enqueue(_ command: InboxCommand) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        guard command.version == InboxCommand.currentVersion else {
            throw CommandInboxError.unsupportedCommandVersion(
                found: command.version,
                supported: InboxCommand.currentVersion,
                file: nil
            )
        }

        try prepareDirectory()
        let data = try CompanionJSON.encoder().encode(command)
        let milliseconds = Int64(command.createdAt.timeIntervalSince1970 * 1_000)
        let filename = String(
            format: "%013lld-%@.json",
            milliseconds,
            command.id.uuidString.lowercased()
        )
        let destination = directoryURL.appendingPathComponent(filename, isDirectory: false)
        let staging = directoryURL.appendingPathComponent(".\(filename).tmp", isDirectory: false)

        defer { try? fileManager.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    public func peek() throws -> [InboxCommand] {
        lock.lock()
        defer { lock.unlock() }
        return try decodePendingCommands().commands
    }

    public func drain() throws -> [InboxCommand] {
        lock.lock()
        defer { lock.unlock() }

        let pending = try decodePendingCommands()
        for url in pending.urls {
            try fileManager.removeItem(at: url)
        }
        return pending.commands
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func decodePendingCommands() throws -> (urls: [URL], commands: [InboxCommand]) {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return ([], [])
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var commands: [InboxCommand] = []
        commands.reserveCapacity(urls.count)
        let decoder = CompanionJSON.decoder()

        for url in urls {
            let command = try decoder.decode(InboxCommand.self, from: Data(contentsOf: url))
            guard command.version == InboxCommand.currentVersion else {
                throw CommandInboxError.unsupportedCommandVersion(
                    found: command.version,
                    supported: InboxCommand.currentVersion,
                    file: url
                )
            }
            commands.append(command)
        }

        return (urls, commands)
    }
}
