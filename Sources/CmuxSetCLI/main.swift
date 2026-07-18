import Darwin
import Foundation

private enum CLIError: LocalizedError {
    case usage(String)
    case invalidValue(option: String, value: String)
    case missingCmuxSurface
    case storeUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .invalidValue(let option, let value):
            return "Invalid value '\(value)' for \(option)."
        case .missingCmuxSurface:
            return "No cmux surface context found. Run this command inside the terminal you want to link."
        case .storeUnreadable(let message):
            return message
        }
    }
}

private enum MemberRole: String, Codable, CaseIterable {
    case worker
    case reviewer
    case pr
    case other
}

private enum CommandKind: String, Codable {
    case join
    case leave
    case arm
    case complete
    case snooze
    case rename
    case lastInput
    case heartbeat
}

private enum MemberRuntimeState: String, Codable, CaseIterable {
    case running
    case waiting
    case idle
    case ended
    case stale
    case disconnected
    case unknown
    case error
}

/// A private wire mirror of the companion's command-inbox schema.
///
/// Keeping this target independent of the app runtime means `cmux-set` can
/// enqueue a command even while the menu-bar UI is starting or reconnecting.
private struct InboxCommand: Codable {
    static let schemaVersion = 1

    let version: Int
    let id: UUID
    let kind: CommandKind
    let createdAt: Date
    let setName: String?
    let role: MemberRole?
    let label: String?
    let agent: String?
    let session: String?
    let color: String?
    let required: Bool?
    let minutes: Int?
    let text: String?
    let state: MemberRuntimeState?
    let remote: Bool?
    let cmuxContext: CmuxContext
    let source: CommandSource

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case kind
        case createdAt = "created_at"
        case setName = "set_name"
        case role
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

private struct CmuxContext: Codable {
    let windowID: String?
    let workspaceID: String?
    let surfaceID: String?
    let panelID: String?

    var effectiveSurfaceID: String? { surfaceID ?? panelID }

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case panelID = "panel_id"
    }

    static func current(environment: [String: String]) -> CmuxContext {
        CmuxContext(
            windowID: environment.nonEmptyValue(for: "CMUX_WINDOW_ID"),
            workspaceID: environment.nonEmptyValue(for: "CMUX_WORKSPACE_ID"),
            surfaceID: environment.nonEmptyValue(for: "CMUX_SURFACE_ID"),
            panelID: environment.nonEmptyValue(for: "CMUX_PANEL_ID")
        )
    }
}

private struct CommandSource: Codable {
    let executable: String
    let pid: Int32
    let host: String
}

private struct JoinOptions {
    var role: MemberRole?
    var label: String?
    var agent: String?
    var session: String?
    var color: String?
    var required: Bool?
}

private struct ArgumentCursor {
    private(set) var values: [String]
    private(set) var index = 0

    var isAtEnd: Bool { index >= values.count }

    mutating func next() -> String? {
        guard !isAtEnd else { return nil }
        defer { index += 1 }
        return values[index]
    }

    mutating func requiredValue(after option: String) throws -> String {
        guard let value = next(), !value.hasPrefix("--"), !value.isEmpty else {
            throw CLIError.usage("\(option) requires a value.\n\n\(usage)")
        }
        return value
    }
}

private enum CompanionPaths {
    static func root(environment: [String: String]) throws -> URL {
        if let override = environment.nonEmptyValue(for: "CMUX_COMPANION_HOME") {
            return URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            )
        }

        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CLIError.storeUnreadable("Unable to resolve the user Application Support directory.")
        }
        return applicationSupport.appendingPathComponent("CmuxCompanion", isDirectory: true)
    }

    static func inbox(environment: [String: String]) throws -> URL {
        try root(environment: environment).appendingPathComponent("commands", isDirectory: true)
    }

    static func store(environment: [String: String]) throws -> URL {
        if let override = environment.nonEmptyValue(for: "CMUX_COMPANION_STORE") {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return try root(environment: environment).appendingPathComponent("sets.json")
    }
}

private extension Dictionary where Key == String, Value == String {
    func nonEmptyValue(for key: String) -> String? {
        guard let raw = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }
}

private let usage = """
Usage:
  cmux-set join <set> --role worker|reviewer|pr|other [options]
  cmux-set leave [set]
  cmux-set arm <set>
  cmux-set complete <set>
  cmux-set snooze <set> <minutes>
  cmux-set rename <set> <new-name>
  cmux-set input [--] <text>
  cmux-set heartbeat <set> [--state running|waiting|idle|ended|stale|disconnected|unknown|error] [--remote true|false]
  cmux-set list

Join options:
  --label <text>          Display label for this terminal
  --agent <name>          Agent kind, for example codex or claude
  --session <id>          Agent session identifier
  --color <value>         Set color name or #RRGGBB value
  --required true|false   Whether this role group is required
                          (new groups default true; existing groups stay unchanged)

The command uses CMUX_WINDOW_ID, CMUX_WORKSPACE_ID, CMUX_SURFACE_ID, and
CMUX_PANEL_ID from the current terminal. Commands are queued atomically under
~/Library/Application Support/CmuxCompanion/commands.
"""

private func nonEmptyName(_ raw: String?, command: String) throws -> String {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          !value.hasPrefix("--") else {
        throw CLIError.usage("\(command) requires a set name.\n\n\(usage)")
    }
    return value
}

private func parseBoolean(_ raw: String, option: String) throws -> Bool {
    switch raw.lowercased() {
    case "true", "yes", "1": return true
    case "false", "no", "0": return false
    default: throw CLIError.invalidValue(option: option, value: raw)
    }
}

private func parseJoinOptions(_ arguments: [String]) throws -> JoinOptions {
    var cursor = ArgumentCursor(values: arguments)
    var options = JoinOptions()

    while let option = cursor.next() {
        switch option {
        case "--role":
            let raw = try cursor.requiredValue(after: option)
            guard let role = MemberRole(rawValue: raw.lowercased()) else {
                throw CLIError.invalidValue(option: option, value: raw)
            }
            options.role = role
        case "--label":
            options.label = try cursor.requiredValue(after: option)
        case "--agent":
            options.agent = try cursor.requiredValue(after: option)
        case "--session":
            options.session = try cursor.requiredValue(after: option)
        case "--color":
            options.color = try cursor.requiredValue(after: option)
        case "--required":
            let raw = try cursor.requiredValue(after: option)
            options.required = try parseBoolean(raw, option: option)
        default:
            throw CLIError.usage("Unknown join option: \(option)\n\n\(usage)")
        }
    }

    guard options.role != nil else {
        throw CLIError.usage("join requires --role worker|reviewer|pr|other.\n\n\(usage)")
    }
    return options
}

private func inferredRemote(environment: [String: String]) -> Bool {
    if let explicit = environment.nonEmptyValue(for: "CMUX_COMPANION_REMOTE"),
       let parsed = try? parseBoolean(explicit, option: "CMUX_COMPANION_REMOTE") {
        return parsed
    }

    guard let socket = environment.nonEmptyValue(for: "CMUX_SOCKET_PATH") else {
        return false
    }
    return socket.hasPrefix("127.0.0.1:")
        || socket.hasPrefix("localhost:")
        || socket.hasPrefix("[::1]:")
}

@discardableResult
private func enqueue(_ command: InboxCommand, environment: [String: String]) throws -> URL {
    let fileManager = FileManager.default
    let inbox = try CompanionPaths.inbox(environment: environment)
    try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: date))
    }
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(command)

    let timestamp = Int64(command.createdAt.timeIntervalSince1970 * 1_000)
    let filename = String(format: "%013lld-%@.json", timestamp, command.id.uuidString.lowercased())
    let destination = inbox.appendingPathComponent(filename, isDirectory: false)
    let staging = inbox.appendingPathComponent(".\(filename).tmp", isDirectory: false)

    defer { try? fileManager.removeItem(at: staging) }
    try data.write(to: staging, options: .atomic)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
    try fileManager.moveItem(at: staging, to: destination)
    return destination
}

private func makeCommand(
    kind: CommandKind,
    setName: String?,
    role: MemberRole? = nil,
    label: String? = nil,
    agent: String? = nil,
    session: String? = nil,
    color: String? = nil,
    required: Bool? = nil,
    minutes: Int? = nil,
    text: String? = nil,
    state: MemberRuntimeState? = nil,
    remote: Bool? = nil,
    context: CmuxContext
) -> InboxCommand {
    InboxCommand(
        version: InboxCommand.schemaVersion,
        id: UUID(),
        kind: kind,
        createdAt: Date(),
        setName: setName,
        role: role,
        label: label,
        agent: agent,
        session: session,
        color: color,
        required: required,
        minutes: minutes,
        text: text,
        state: state,
        remote: remote,
        cmuxContext: context,
        source: CommandSource(
            executable: "cmux-set",
            pid: ProcessInfo.processInfo.processIdentifier,
            host: ProcessInfo.processInfo.hostName
        )
    )
}

private func printStore(environment: [String: String]) throws {
    let store = try CompanionPaths.store(environment: environment)
    guard FileManager.default.fileExists(atPath: store.path) else {
        print("{\n  \"sets\" : []\n}")
        return
    }

    let data: Data
    do {
        data = try Data(contentsOf: store)
    } catch {
        throw CLIError.storeUnreadable("Unable to read \(store.path): \(error.localizedDescription)")
    }

    do {
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let output = String(data: pretty, encoding: .utf8) else {
            throw CLIError.storeUnreadable("The companion store is not valid UTF-8 JSON.")
        }
        print(output)
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError.storeUnreadable("Unable to decode \(store.path): \(error.localizedDescription)")
    }
}

private func run(arguments: [String], environment: [String: String]) throws {
    guard let subcommand = arguments.first else {
        throw CLIError.usage(usage)
    }
    if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
        print(usage)
        return
    }

    let remainder = Array(arguments.dropFirst())
    let context = CmuxContext.current(environment: environment)

    if subcommand == "list" {
        guard remainder.isEmpty else {
            throw CLIError.usage("list does not accept arguments.\n\n\(usage)")
        }
        try printStore(environment: environment)
        return
    }

    let command: InboxCommand
    switch subcommand {
    case "join":
        guard let rawSet = remainder.first else {
            throw CLIError.usage("join requires a set name.\n\n\(usage)")
        }
        let setName = try nonEmptyName(rawSet, command: "join")
        guard context.effectiveSurfaceID != nil else { throw CLIError.missingCmuxSurface }
        let options = try parseJoinOptions(Array(remainder.dropFirst()))
        command = makeCommand(
            kind: .join,
            setName: setName,
            role: options.role,
            label: options.label,
            agent: options.agent,
            session: options.session,
            color: options.color,
            required: options.required,
            context: context
        )
    case "leave":
        guard remainder.count <= 1 else {
            throw CLIError.usage("leave accepts at most one set name.\n\n\(usage)")
        }
        guard context.effectiveSurfaceID != nil else { throw CLIError.missingCmuxSurface }
        let setName = try remainder.first.map { try nonEmptyName($0, command: "leave") }
        command = makeCommand(kind: .leave, setName: setName, context: context)
    case "arm", "complete":
        guard remainder.count == 1 else {
            throw CLIError.usage("\(subcommand) requires exactly one set name.\n\n\(usage)")
        }
        let setName = try nonEmptyName(remainder[0], command: subcommand)
        command = makeCommand(
            kind: subcommand == "arm" ? .arm : .complete,
            setName: setName,
            context: context
        )
    case "snooze":
        guard remainder.count == 2 else {
            throw CLIError.usage("snooze requires a set name and duration in minutes.\n\n\(usage)")
        }
        let setName = try nonEmptyName(remainder[0], command: "snooze")
        guard let minutes = Int(remainder[1]), (1 ... 10_080).contains(minutes) else {
            throw CLIError.invalidValue(option: "minutes", value: remainder[1])
        }
        command = makeCommand(
            kind: .snooze,
            setName: setName,
            minutes: minutes,
            context: context
        )
    case "rename":
        guard remainder.count == 2 else {
            throw CLIError.usage("rename requires the current and new set names.\n\n\(usage)")
        }
        let setName = try nonEmptyName(remainder[0], command: "rename")
        let newName = try nonEmptyName(remainder[1], command: "rename")
        command = makeCommand(
            kind: .rename,
            setName: setName,
            label: newName,
            context: context
        )
    case "input":
        guard context.effectiveSurfaceID != nil else { throw CLIError.missingCmuxSurface }
        let textArguments = remainder.first == "--" ? Array(remainder.dropFirst()) : remainder
        guard !textArguments.isEmpty else {
            throw CLIError.usage("input requires submitted text.\n\n\(usage)")
        }
        let submittedText = textArguments.joined(separator: " ")
        guard !submittedText.isEmpty else {
            throw CLIError.usage("input requires non-empty submitted text.\n\n\(usage)")
        }
        command = makeCommand(
            kind: .lastInput,
            setName: nil,
            text: submittedText,
            context: context
        )
    case "heartbeat":
        guard let rawSet = remainder.first else {
            throw CLIError.usage("heartbeat requires a set name.\n\n\(usage)")
        }
        guard context.effectiveSurfaceID != nil else { throw CLIError.missingCmuxSurface }
        let setName = try nonEmptyName(rawSet, command: "heartbeat")
        var state: MemberRuntimeState = .running
        var remote = inferredRemote(environment: environment)
        var cursor = ArgumentCursor(values: Array(remainder.dropFirst()))
        while let option = cursor.next() {
            switch option {
            case "--state":
                let raw = try cursor.requiredValue(after: option)
                guard let parsed = MemberRuntimeState(rawValue: raw.lowercased()) else {
                    throw CLIError.invalidValue(option: option, value: raw)
                }
                state = parsed
            case "--remote":
                remote = try parseBoolean(
                    cursor.requiredValue(after: option),
                    option: option
                )
            default:
                throw CLIError.usage("Unknown heartbeat option: \(option)\n\n\(usage)")
            }
        }
        command = makeCommand(
            kind: .heartbeat,
            setName: setName,
            state: state,
            remote: remote,
            context: context
        )
    default:
        throw CLIError.usage("Unknown command: \(subcommand)\n\n\(usage)")
    }

    let queuedAt = try enqueue(command, environment: environment)
    print("Queued \(command.kind.rawValue) command: \(queuedAt.lastPathComponent)")
}

do {
    try run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment
    )
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data("cmux-set: \(message)\n".utf8))
    exit(2)
}
