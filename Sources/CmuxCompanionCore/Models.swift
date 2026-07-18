import Foundation

/// Stable filesystem locations shared by the menu-bar app and `cmux-set`.
public enum CompanionPaths {
    public static var defaultRootDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport.appendingPathComponent("CmuxCompanion", isDirectory: true)
    }

    public static var defaultSetsURL: URL {
        defaultRootDirectory.appendingPathComponent("sets.json", isDirectory: false)
    }

    public static var defaultCommandsDirectory: URL {
        defaultRootDirectory.appendingPathComponent("commands", isDirectory: true)
    }
}

public enum MemberRole: String, Codable, CaseIterable, Sendable {
    case worker
    case reviewer
    case pr
    case other
}

public enum MemberRuntimeState: String, Codable, CaseIterable, Sendable {
    case running
    case waiting
    case idle
    case ended
    case stale
    case disconnected
    case unknown
    case error

    public var isActivelyWorking: Bool {
        self == .running
    }

    public var needsAttention: Bool {
        switch self {
        case .waiting, .stale, .disconnected, .error:
            return true
        case .running, .idle, .ended, .unknown:
            return false
        }
    }
}

public enum GroupPolicy: Equatable, Sendable {
    case all
    case minActive(Int)

    public var minimumActive: Int? {
        switch self {
        case .all:
            return nil
        case let .minActive(value):
            return max(0, value)
        }
    }
}

extension GroupPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case minimum
    }

    private enum Kind: String, Codable {
        case all
        case minActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .all:
            self = .all
        case .minActive:
            self = .minActive(try container.decode(Int.self, forKey: .minimum))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(Kind.all, forKey: .kind)
        case let .minActive(minimum):
            try container.encode(Kind.minActive, forKey: .kind)
            try container.encode(max(0, minimum), forKey: .minimum)
        }
    }
}

public struct WorkMember: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var role: MemberRole
    public var agent: String?
    public var sessionID: String?
    public var surfaceID: String?
    public var workspaceID: String?
    public var windowID: String?
    public var runtimeState: MemberRuntimeState
    public var lastSubmittedText: String?
    public var lastSubmittedAt: Date?
    public var lastHeartbeatAt: Date?
    public var lastRemoteBootID: String?
    public var lastRemoteSequence: UInt64?
    public var localOwnershipSince: Date?
    public var isRemote: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        role: MemberRole,
        agent: String? = nil,
        sessionID: String? = nil,
        surfaceID: String? = nil,
        workspaceID: String? = nil,
        windowID: String? = nil,
        runtimeState: MemberRuntimeState = .unknown,
        lastSubmittedText: String? = nil,
        lastSubmittedAt: Date? = nil,
        lastHeartbeatAt: Date? = nil,
        lastRemoteBootID: String? = nil,
        lastRemoteSequence: UInt64? = nil,
        localOwnershipSince: Date? = nil,
        isRemote: Bool = false
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.agent = agent
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.runtimeState = runtimeState
        self.lastSubmittedText = lastSubmittedText
        self.lastSubmittedAt = lastSubmittedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastRemoteBootID = lastRemoteBootID
        self.lastRemoteSequence = lastRemoteSequence
        self.localOwnershipSince = localOwnershipSince
        self.isRemote = isRemote
    }
}

public struct WorkGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var role: MemberRole?
    /// Whether this entire role group participates in armed-set completeness
    /// and attention alerts. Requiredness is intentionally not per-member.
    public var required: Bool
    public var policy: GroupPolicy
    public var memberIDs: [UUID]

    public init(
        id: UUID = UUID(),
        label: String,
        role: MemberRole? = nil,
        required: Bool = true,
        policy: GroupPolicy = .all,
        memberIDs: [UUID] = []
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.required = required
        self.policy = policy
        self.memberIDs = memberIDs
    }
}

public struct WorkAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var role: MemberRole
    public var url: URL?
    public var surfaceID: String?
    public var workspaceID: String?
    public var windowID: String?

    public init(
        id: UUID = UUID(),
        label: String,
        role: MemberRole = .pr,
        url: URL? = nil,
        surfaceID: String? = nil,
        workspaceID: String? = nil,
        windowID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.url = url
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.windowID = windowID
    }
}

public struct WorkSet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var color: String
    public var armed: Bool
    public var generation: Int
    public var completedGeneration: Int?
    public var groups: [WorkGroup]
    public var members: [WorkMember]
    public var attachments: [WorkAttachment]
    public var snoozedUntil: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        color: String = "#0A84FF",
        armed: Bool = false,
        generation: Int = 1,
        completedGeneration: Int? = nil,
        groups: [WorkGroup] = [],
        members: [WorkMember] = [],
        attachments: [WorkAttachment] = [],
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.color = color
        self.armed = armed
        self.generation = max(1, generation)
        self.completedGeneration = completedGeneration
        self.groups = groups
        self.members = members
        self.attachments = attachments
        self.snoozedUntil = snoozedUntil
    }

    public var isCurrentGenerationCompleted: Bool {
        completedGeneration == generation
    }

    /// Starts monitoring. Re-arming a completed generation creates a new round.
    public mutating func arm() {
        if isCurrentGenerationCompleted {
            generation += 1
        }
        completedGeneration = nil
        armed = true
        snoozedUntil = nil
    }

    /// Completion is deliberately explicit; agent Stop/idle events never call this.
    public mutating func completeCurrentGeneration() {
        completedGeneration = generation
        armed = false
        snoozedUntil = nil
    }
}

public struct CompanionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sets: [WorkSet]

    public init(
        schemaVersion: Int = CompanionSnapshot.currentSchemaVersion,
        sets: [WorkSet] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sets = sets
    }
}
