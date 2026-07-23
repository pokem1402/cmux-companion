import Foundation

public enum PendingInteractionKind: String, CaseIterable, Sendable {
    case inputRequired
    case completion
    case attention

    fileprivate var priority: Int {
        switch self {
        case .inputRequired: return 3
        case .completion: return 2
        case .attention: return 1
        }
    }
}

public enum PendingInteractionReplyCapability: String, Sendable {
    /// The current cmux hook/event feeds expose state but do not own the
    /// provider's blocking request, so the safe action is to focus its terminal.
    case openTerminalOnly
    /// Reserved for a future request/reply transport that can prove ownership
    /// of the provider request and deliver exactly one correlated response.
    case directReply
}

public enum PendingInteractionSensitivity: String, Sendable {
    case normal
    case sensitive
}

public struct PendingInteractionOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct PendingInteraction: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: PendingInteractionKind
    public var setID: UUID
    public var memberID: UUID?
    public var setTitle: String
    public var memberTitle: String?
    public var agent: String?
    public var detail: String
    public var options: [PendingInteractionOption]
    public var replyCapability: PendingInteractionReplyCapability
    public var sensitivity: PendingInteractionSensitivity
    public var windowID: String?
    public var workspaceID: String?
    public var surfaceID: String?
    public var isRemote: Bool
    public var createdAt: Date

    public init(
        id: String,
        kind: PendingInteractionKind,
        setID: UUID,
        memberID: UUID? = nil,
        setTitle: String,
        memberTitle: String? = nil,
        agent: String? = nil,
        detail: String,
        options: [PendingInteractionOption] = [],
        replyCapability: PendingInteractionReplyCapability = .openTerminalOnly,
        sensitivity: PendingInteractionSensitivity = .normal,
        windowID: String? = nil,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        isRemote: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.setID = setID
        self.memberID = memberID
        self.setTitle = setTitle
        self.memberTitle = memberTitle
        self.agent = agent
        self.detail = detail
        self.options = options
        self.replyCapability = replyCapability
        self.sensitivity = sensitivity
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.isRemote = isRemote
        self.createdAt = createdAt
    }

    public static func attention(
        set: WorkSet,
        evaluation: SetEvaluation,
        createdAt: Date = Date()
    ) -> PendingInteraction {
        let memberID = SetEvaluator.preferredFocusMemberID(in: set, evaluation: evaluation)
        let member = memberID.flatMap { id in set.members.first(where: { $0.id == id }) }
        let detail: String
        if let member, member.runtimeState.needsAttention {
            switch member.runtimeState {
            case .stale:
                detail = "\(member.label)의 상태가 오래되어 확인이 필요합니다."
            case .disconnected:
                detail = "\(member.label)의 연결이 끊겼습니다."
            case .error:
                detail = "\(member.label)에서 오류가 발생했습니다."
            case .waiting:
                detail = "\(member.label)이 사용자 입력 또는 승인을 기다리고 있습니다."
            default:
                detail = "\(member.label)의 상태를 확인하세요."
            }
        } else {
            detail = "필수 Worker/Reviewer 그룹이 현재 작업 중이 아닙니다."
        }
        return PendingInteraction(
            id: "attention:\(set.id.uuidString):\(set.generation)",
            kind: .attention,
            setID: set.id,
            memberID: member?.id,
            setTitle: set.label,
            memberTitle: member?.label,
            agent: member?.agent,
            detail: detail,
            windowID: member?.windowID,
            workspaceID: member?.workspaceID,
            surfaceID: member?.surfaceID,
            isRemote: member?.isRemote ?? false,
            createdAt: createdAt
        )
    }
}

private struct InteractionMemberKey: Hashable, Sendable {
    var setID: UUID
    var memberID: UUID
}

/// Remembers the previous linked-member snapshot and emits only real runtime
/// transitions. A non-notifying update seeds or refreshes the baseline, which
/// prevents a launch-time `idle`/`waiting` snapshot from looking like a new event.
public struct InteractionTransitionTracker: Sendable {
    private var memberStates: [InteractionMemberKey: MemberRuntimeState] = [:]

    public init() {}

    public mutating func update(
        sets: [WorkSet],
        notifyTransitions: Bool,
        now: Date = Date()
    ) -> [PendingInteraction] {
        var current: [InteractionMemberKey: MemberRuntimeState] = [:]
        for set in sets {
            for member in set.members where member.role != .pr {
                current[InteractionMemberKey(setID: set.id, memberID: member.id)] = member.runtimeState
            }
        }
        defer { memberStates = current }
        guard notifyTransitions else { return [] }

        var interactions: [PendingInteraction] = []
        for set in sets where set.armed && !set.isCurrentGenerationCompleted {
            let requiredMemberIDs = Set(
                set.groups
                    .filter(\.required)
                    .flatMap(\.memberIDs)
            )
            for member in set.members where member.role != .pr {
                let key = InteractionMemberKey(setID: set.id, memberID: member.id)
                let previous = memberStates[key]
                if member.runtimeState == .waiting,
                   previous != .waiting,
                   requiredMemberIDs.contains(member.id) {
                    interactions.append(
                        PendingInteraction(
                            id: "input:\(set.id.uuidString):\(member.id.uuidString):\(set.generation)",
                            kind: .inputRequired,
                            setID: set.id,
                            memberID: member.id,
                            setTitle: set.label,
                            memberTitle: member.label,
                            agent: member.agent,
                            detail: "사용자 입력 또는 승인이 필요합니다.",
                            windowID: member.windowID,
                            workspaceID: member.workspaceID,
                            surfaceID: member.surfaceID,
                            isRemote: member.isRemote,
                            createdAt: now
                        )
                    )
                } else if previous == .running,
                          member.runtimeState == .idle || member.runtimeState == .ended {
                    if member.role == .reviewer,
                       set.requiredReviewerGroupStillRunning(after: member.id) {
                        continue
                    }
                    interactions.append(
                        PendingInteraction(
                            id: "completion:\(set.id.uuidString):\(member.id.uuidString):\(set.generation)",
                            kind: .completion,
                            setID: set.id,
                            memberID: member.id,
                            setTitle: set.label,
                            memberTitle: member.label,
                            agent: member.agent,
                            detail: "현재 작업이 완료되었습니다.",
                            windowID: member.windowID,
                            workspaceID: member.workspaceID,
                            surfaceID: member.surfaceID,
                            isRemote: member.isRemote,
                            createdAt: now
                        )
                    )
                }
            }
        }
        return interactions
    }
}

private extension WorkSet {
    func requiredReviewerGroupStillRunning(after completedMemberID: UUID) -> Bool {
        groups.contains { group in
            group.required
                && group.role == .reviewer
                && group.memberIDs.contains(completedMemberID)
                && group.memberIDs.contains { memberID in
                    memberID != completedMemberID
                        && members.first(where: { $0.id == memberID })?.runtimeState == .running
                }
        }
    }
}

public struct PendingInteractionQueue: Equatable, Sendable {
    public private(set) var items: [PendingInteraction]
    public var maximumCount: Int

    public init(items: [PendingInteraction] = [], maximumCount: Int = 32) {
        self.items = items
        self.maximumCount = max(1, maximumCount)
        trimIfNeeded()
    }

    public var orderedItems: [PendingInteraction] {
        items.sorted { lhs, rhs in
            if lhs.kind.priority != rhs.kind.priority {
                return lhs.kind.priority > rhs.kind.priority
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    public var current: PendingInteraction? { orderedItems.first }

    public mutating func enqueue(_ interaction: PendingInteraction) {
        if let index = items.firstIndex(where: { $0.id == interaction.id }) {
            items[index] = interaction
        } else {
            items.append(interaction)
        }
        trimIfNeeded()
    }

    @discardableResult
    public mutating func remove(id: String) -> PendingInteraction? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func removeAll(where shouldRemove: (PendingInteraction) -> Bool) {
        items.removeAll(where: shouldRemove)
    }

    private mutating func trimIfNeeded() {
        guard items.count > maximumCount else { return }
        items = Array(orderedItems.prefix(maximumCount))
    }
}
