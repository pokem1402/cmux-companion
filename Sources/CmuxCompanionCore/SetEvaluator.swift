import Foundation

public enum SetActivityStatus: String, Codable, CaseIterable, Sendable {
    case attention
    case incomplete
    case active
    case idle
}

public struct GroupEvaluation: Equatable, Sendable {
    public var groupID: UUID
    public var memberCount: Int
    public var activeCount: Int
    public var requiredActiveCount: Int
    public var isSatisfied: Bool

    public init(
        groupID: UUID,
        memberCount: Int,
        activeCount: Int,
        requiredActiveCount: Int,
        isSatisfied: Bool
    ) {
        self.groupID = groupID
        self.memberCount = memberCount
        self.activeCount = activeCount
        self.requiredActiveCount = requiredActiveCount
        self.isSatisfied = isSatisfied
    }
}

public struct SetEvaluation: Equatable, Sendable {
    public var status: SetActivityStatus
    public var isGenerationCompleted: Bool
    public var isSnoozed: Bool
    public var shouldNotify: Bool
    public var activeMemberIDs: [UUID]
    public var attentionMemberIDs: [UUID]
    public var deficientGroupIDs: [UUID]
    public var groups: [GroupEvaluation]

    public init(
        status: SetActivityStatus,
        isGenerationCompleted: Bool,
        isSnoozed: Bool,
        shouldNotify: Bool,
        activeMemberIDs: [UUID],
        attentionMemberIDs: [UUID],
        deficientGroupIDs: [UUID],
        groups: [GroupEvaluation]
    ) {
        self.status = status
        self.isGenerationCompleted = isGenerationCompleted
        self.isSnoozed = isSnoozed
        self.shouldNotify = shouldNotify
        self.activeMemberIDs = activeMemberIDs
        self.attentionMemberIDs = attentionMemberIDs
        self.deficientGroupIDs = deficientGroupIDs
        self.groups = groups
    }
}

public enum SetEvaluator {
    /// Evaluates a set using this priority: attention, armed-group deficit,
    /// active, idle. A manually completed generation is acknowledged as idle
    /// and does not notify until it is armed again as a new generation.
    public static func evaluate(_ set: WorkSet, now: Date = Date()) -> SetEvaluation {
        let trackedMembers = set.members.filter { $0.role != .pr }
        let memberByID = Dictionary(uniqueKeysWithValues: set.members.map { ($0.id, $0) })
        let requiredMemberIDs = Set(
            set.groups
                .filter(\.required)
                .flatMap(\.memberIDs)
        )

        let activeMemberIDs = trackedMembers
            .filter { $0.runtimeState.isActivelyWorking }
            .map(\.id)
        let attentionMemberIDs = trackedMembers
            .filter { requiredMemberIDs.contains($0.id) && $0.runtimeState.needsAttention }
            .map(\.id)

        let groupEvaluations = set.groups.map { group -> GroupEvaluation in
            let activeCount = group.memberIDs.reduce(into: 0) { count, memberID in
                if memberByID[memberID]?.runtimeState.isActivelyWorking == true {
                    count += 1
                }
            }

            let requiredActiveCount: Int
            switch group.policy {
            case .all:
                // A required but not-yet-populated group must not appear healthy.
                let populatedCount = group.memberIDs.count
                if group.role == .reviewer, populatedCount > 1 {
                    requiredActiveCount = group.required ? 1 : min(1, populatedCount)
                } else {
                    requiredActiveCount = group.required
                        ? max(1, populatedCount)
                        : populatedCount
                }
            case let .minActive(minimum):
                requiredActiveCount = max(0, minimum)
            }

            return GroupEvaluation(
                groupID: group.id,
                memberCount: group.memberIDs.count,
                activeCount: activeCount,
                requiredActiveCount: requiredActiveCount,
                isSatisfied: activeCount >= requiredActiveCount
            )
        }

        let deficientGroupIDs = zip(set.groups, groupEvaluations).compactMap { group, evaluation in
            group.required && !evaluation.isSatisfied ? group.id : nil
        }
        let completed = set.isCurrentGenerationCompleted
        let snoozed = set.snoozedUntil.map { $0 > now } ?? false

        let status: SetActivityStatus
        if completed {
            status = .idle
        } else if !attentionMemberIDs.isEmpty {
            status = .attention
        } else if set.armed && !deficientGroupIDs.isEmpty {
            status = .incomplete
        } else if !activeMemberIDs.isEmpty {
            status = .active
        } else {
            status = .idle
        }

        let shouldNotify = set.armed
            && !completed
            && !snoozed
            && (status == .attention || status == .incomplete)

        return SetEvaluation(
            status: status,
            isGenerationCompleted: completed,
            isSnoozed: snoozed,
            shouldNotify: shouldNotify,
            activeMemberIDs: activeMemberIDs,
            attentionMemberIDs: attentionMemberIDs,
            deficientGroupIDs: deficientGroupIDs,
            groups: groupEvaluations
        )
    }

    /// Picks the member that best explains the set's current status. Jump
    /// actions should open a deficient reviewer instead of an unrelated
    /// worker that happens to still be running.
    public static func preferredFocusMemberID(
        in set: WorkSet,
        evaluation: SetEvaluation? = nil
    ) -> UUID? {
        let evaluation = evaluation ?? evaluate(set)
        let attentionIDs = Set(evaluation.attentionMemberIDs)
        if let member = set.members.first(where: { attentionIDs.contains($0.id) }) {
            return member.id
        }

        let deficientGroupIDs = Set(evaluation.deficientGroupIDs)
        let deficientMemberIDs = Set(
            set.groups
                .filter { deficientGroupIDs.contains($0.id) }
                .flatMap(\.memberIDs)
        )
        if let member = set.members.first(where: {
            deficientMemberIDs.contains($0.id) && !$0.runtimeState.isActivelyWorking
        }) {
            return member.id
        }

        return set.members.first(where: { $0.runtimeState.isActivelyWorking })?.id
            ?? set.members.first(where: { $0.runtimeState.needsAttention })?.id
            ?? set.members.first?.id
    }
}
