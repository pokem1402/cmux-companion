import Foundation

public enum CommandApplyError: Error, Equatable, LocalizedError {
    case unsupportedCommandVersion(Int)
    case missingSetName(InboxCommandKind)
    case missingRole
    case missingMemberIdentity
    case missingValue(String)
    case setNotFound(String)
    case groupNotFound(UUID)
    case groupRoleMismatch(UUID, MemberRole)
    case duplicateSetName(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedCommandVersion(version):
            return "Unsupported inbox command version \(version)."
        case let .missingSetName(kind):
            return "The \(kind.rawValue) command requires a set name."
        case .missingRole:
            return "The join command requires a member role."
        case .missingMemberIdentity:
            return "The command requires a cmux surface/panel ID or an agent session ID."
        case let .missingValue(name):
            return "The command requires \(name)."
        case let .setNotFound(name):
            return "No logical set named \(name) exists."
        case let .groupNotFound(groupID):
            return "No target group with ID \(groupID.uuidString) exists."
        case let .groupRoleMismatch(groupID, role):
            return "Target group \(groupID.uuidString) does not accept the \(role.rawValue) role."
        case let .duplicateSetName(name):
            return "A logical set named \(name) already exists."
        }
    }
}

public struct CommandApplyResult: Equatable, Sendable {
    public var changedSetIDs: [UUID]
    public var joinedMemberID: UUID?

    public init(changedSetIDs: [UUID] = [], joinedMemberID: UUID? = nil) {
        self.changedSetIDs = changedSetIDs
        self.joinedMemberID = joinedMemberID
    }
}

/// Pure command reducer used by both the UI state engine and headless tests.
public enum CommandReducer {
    @discardableResult
    public static func apply(
        _ command: InboxCommand,
        to snapshot: inout CompanionSnapshot,
        now: Date = Date()
    ) throws -> CommandApplyResult {
        guard command.version == InboxCommand.currentVersion else {
            throw CommandApplyError.unsupportedCommandVersion(command.version)
        }

        switch command.kind {
        case .join:
            return try join(command, snapshot: &snapshot)
        case .leave:
            return try leave(command, snapshot: &snapshot)
        case .arm:
            let index = try requiredSetIndex(for: command, in: snapshot)
            snapshot.sets[index].arm()
            return CommandApplyResult(changedSetIDs: [snapshot.sets[index].id])
        case .complete:
            let index = try requiredSetIndex(for: command, in: snapshot)
            snapshot.sets[index].completeCurrentGeneration()
            return CommandApplyResult(changedSetIDs: [snapshot.sets[index].id])
        case .snooze:
            let index = try requiredSetIndex(for: command, in: snapshot)
            guard let minutes = command.minutes else {
                throw CommandApplyError.missingValue("minutes")
            }
            snapshot.sets[index].snoozedUntil = now.addingTimeInterval(
                TimeInterval(max(0, minutes)) * 60
            )
            return CommandApplyResult(changedSetIDs: [snapshot.sets[index].id])
        case .rename:
            let index = try requiredSetIndex(for: command, in: snapshot)
            guard let newLabel = normalized(command.label) else {
                throw CommandApplyError.missingValue("label")
            }
            if snapshot.sets.enumerated().contains(where: { otherIndex, set in
                otherIndex != index
                    && set.label.compare(
                        newLabel,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
            }) {
                throw CommandApplyError.duplicateSetName(newLabel)
            }
            snapshot.sets[index].label = newLabel
            return CommandApplyResult(changedSetIDs: [snapshot.sets[index].id])
        case .lastInput:
            guard let text = command.text else {
                throw CommandApplyError.missingValue("text")
            }
            return try updateMatchingMembers(command, snapshot: &snapshot) { member in
                member.lastSubmittedText = text
                member.lastSubmittedAt = command.createdAt
            }
        case .heartbeat:
            return try updateMatchingMembers(command, snapshot: &snapshot) { member in
                member.sessionID = normalized(command.session) ?? member.sessionID
                member.surfaceID = command.cmuxContext.effectiveSurfaceID ?? member.surfaceID
                member.workspaceID = command.cmuxContext.workspaceID ?? member.workspaceID
                member.windowID = command.cmuxContext.windowID ?? member.windowID
                member.agent = normalized(command.agent) ?? member.agent
                member.runtimeState = command.state.flatMap(runtimeState(from:))
                    ?? member.runtimeState
                member.isRemote = command.remote ?? true
                member.lastHeartbeatAt = command.createdAt
            }
        }
    }

    private static func join(
        _ command: InboxCommand,
        snapshot: inout CompanionSnapshot
    ) throws -> CommandApplyResult {
        guard let setName = normalized(command.setName) else {
            throw CommandApplyError.missingSetName(.join)
        }
        guard let role = command.role else {
            throw CommandApplyError.missingRole
        }
        let surfaceID = command.cmuxContext.effectiveSurfaceID
        let sessionID = normalized(command.session)
        guard surfaceID != nil || sessionID != nil else {
            throw CommandApplyError.missingMemberIdentity
        }
        // PR attachments are surface-bound and cannot be identified by an
        // agent session alone. Validate this before creating a target set or
        // displacing an existing member so a rejected command is atomic.
        guard role != .pr || surfaceID != nil else {
            throw CommandApplyError.missingMemberIdentity
        }

        let existingTargetIndex = setIndex(named: setName, in: snapshot)
        if let groupID = command.groupID {
            guard let existingTargetIndex,
                  let targetGroup = snapshot.sets[existingTargetIndex].groups.first(where: {
                      $0.id == groupID
                  }) else {
                throw CommandApplyError.groupNotFound(groupID)
            }
            guard targetGroup.role == role else {
                throw CommandApplyError.groupRoleMismatch(groupID, role)
            }
        }

        let targetIndex: Int
        if let existing = existingTargetIndex {
            targetIndex = existing
            if let color = normalized(command.color) {
                snapshot.sets[targetIndex].color = color
            }
        } else {
            snapshot.sets.append(WorkSet(label: setName, color: normalized(command.color) ?? "#0A84FF"))
            targetIndex = snapshot.sets.index(before: snapshot.sets.endIndex)
        }

        let displaced = displaceMatchingIdentity(
            surfaceID: surfaceID,
            sessionID: sessionID,
            excludingSetAt: targetIndex,
            snapshot: &snapshot
        )
        var workSet = snapshot.sets[targetIndex]
        let matchingMembers = workSet.members.filter { member in
            if let surfaceID, member.surfaceID == surfaceID { return true }
            if let sessionID, member.sessionID == sessionID { return true }
            return false
        }
        let matchingMemberIDs = Set(matchingMembers.map(\.id))
        // A command can bridge two stale rows: one already owns the surface and
        // another owns the session. The surface row is canonical because it is
        // the terminal the user invoked the command from; otherwise retain the
        // session row. Duplicate metadata is folded into that stable identity.
        let canonicalMemberID = surfaceID.flatMap { surfaceID in
            matchingMembers.first { $0.surfaceID == surfaceID }?.id
        } ?? sessionID.flatMap { sessionID in
            matchingMembers.first { $0.sessionID == sessionID }?.id
        }

        if role == .pr {
            // Proven non-nil by the pre-mutation validation above.
            let surfaceID = surfaceID!
            if !matchingMemberIDs.isEmpty {
                removeMembersAndGroupReferences(matchingMemberIDs, from: &workSet)
            }
            if let attachmentIndex = workSet.attachments.firstIndex(where: { $0.surfaceID == surfaceID }) {
                workSet.attachments[attachmentIndex].label = normalized(command.label)
                    ?? workSet.attachments[attachmentIndex].label
                workSet.attachments[attachmentIndex].workspaceID = command.cmuxContext.workspaceID
                    ?? workSet.attachments[attachmentIndex].workspaceID
                workSet.attachments[attachmentIndex].windowID = command.cmuxContext.windowID
                    ?? workSet.attachments[attachmentIndex].windowID
            } else {
                workSet.attachments.append(
                    WorkAttachment(
                        label: normalized(command.label) ?? "PR",
                        role: .pr,
                        surfaceID: surfaceID,
                        workspaceID: command.cmuxContext.workspaceID,
                        windowID: command.cmuxContext.windowID
                    )
                )
            }
            snapshot.sets[targetIndex] = workSet
            return CommandApplyResult(changedSetIDs: displaced.changedSetIDs + [workSet.id])
        }

        if let surfaceID {
            workSet.attachments.removeAll { $0.surfaceID == surfaceID }
        }

        if let canonicalMemberID {
            let duplicateIDs = matchingMemberIDs.subtracting([canonicalMemberID])
            if !duplicateIDs.isEmpty,
               let canonicalIndex = workSet.members.firstIndex(where: { $0.id == canonicalMemberID }) {
                var canonical = workSet.members[canonicalIndex]
                for duplicate in workSet.members where duplicateIDs.contains(duplicate.id) {
                    mergeMetadata(from: duplicate, into: &canonical)
                }
                workSet.members[canonicalIndex] = canonical
                preserveDestinationGroupMembership(
                    canonicalMemberID: canonicalMemberID,
                    duplicateMemberIDs: duplicateIDs,
                    role: role,
                    preferredGroupID: command.groupID,
                    in: &workSet
                )
                removeMembersAndGroupReferences(duplicateIDs, from: &workSet)
            }
        }
        let matchingMemberIndex = canonicalMemberID.flatMap { memberID in
            workSet.members.firstIndex { $0.id == memberID }
        }

        let memberID: UUID
        if let existingIndex = matchingMemberIndex {
            memberID = workSet.members[existingIndex].id
            let previousRole = workSet.members[existingIndex].role
            workSet.members[existingIndex].label = normalized(command.label)
                ?? workSet.members[existingIndex].label
            workSet.members[existingIndex].role = role
            workSet.members[existingIndex].agent = normalized(command.agent)
                ?? workSet.members[existingIndex].agent
            workSet.members[existingIndex].sessionID = sessionID
                ?? workSet.members[existingIndex].sessionID
            workSet.members[existingIndex].surfaceID = surfaceID
                ?? workSet.members[existingIndex].surfaceID
            workSet.members[existingIndex].workspaceID = command.cmuxContext.workspaceID
                ?? workSet.members[existingIndex].workspaceID
            workSet.members[existingIndex].windowID = command.cmuxContext.windowID
                ?? workSet.members[existingIndex].windowID
            workSet.members[existingIndex].isRemote = command.remote
                ?? workSet.members[existingIndex].isRemote

            if previousRole != role {
                for groupIndex in workSet.groups.indices {
                    if workSet.groups[groupIndex].role != role {
                        workSet.groups[groupIndex].memberIDs.removeAll { $0 == memberID }
                    }
                }
                workSet.groups.removeAll {
                    $0.memberIDs.isEmpty && $0.id != command.groupID
                }
            }
        } else if var member = displaced.member {
            member.label = normalized(command.label) ?? member.label
            member.role = role
            member.agent = normalized(command.agent) ?? member.agent
            member.sessionID = sessionID ?? member.sessionID
            member.surfaceID = surfaceID ?? member.surfaceID
            member.workspaceID = command.cmuxContext.workspaceID ?? member.workspaceID
            member.windowID = command.cmuxContext.windowID ?? member.windowID
            member.isRemote = command.remote ?? member.isRemote
            memberID = member.id
            workSet.members.append(member)
        } else {
            let fallbackLabel = normalized(command.label)
                ?? normalized(command.agent)
                ?? role.rawValue.capitalized
            let member = WorkMember(
                label: fallbackLabel,
                role: role,
                agent: normalized(command.agent),
                sessionID: sessionID,
                surfaceID: surfaceID,
                workspaceID: command.cmuxContext.workspaceID,
                windowID: command.cmuxContext.windowID,
                isRemote: command.remote
                    ?? command.source.executable.lowercased().contains("remote")
            )
            memberID = member.id
            workSet.members.append(member)
        }

        if let targetGroupID = command.groupID,
           let groupIndex = workSet.groups.firstIndex(where: { $0.id == targetGroupID }) {
            for candidateIndex in workSet.groups.indices {
                workSet.groups[candidateIndex].memberIDs.removeAll { $0 == memberID }
            }
            workSet.groups[groupIndex].memberIDs.append(memberID)
            workSet.groups.removeAll { $0.memberIDs.isEmpty }
            if let required = command.required,
               let updatedIndex = workSet.groups.firstIndex(where: { $0.id == targetGroupID }) {
                workSet.groups[updatedIndex].required = required
            }
        } else if let groupIndex = workSet.groups.firstIndex(where: {
            $0.role == role && $0.memberIDs.contains(memberID)
        }) ?? workSet.groups.firstIndex(where: { $0.role == role }) {
            if !workSet.groups[groupIndex].memberIDs.contains(memberID) {
                workSet.groups[groupIndex].memberIDs.append(memberID)
            }
            if let required = command.required {
                workSet.groups[groupIndex].required = required
            }
        } else {
            workSet.groups.append(
                WorkGroup(
                    label: defaultGroupLabel(for: role),
                    role: role,
                    required: command.required ?? true,
                    policy: role == .other ? .minActive(1) : .all,
                    memberIDs: [memberID]
                )
            )
        }

        snapshot.sets[targetIndex] = workSet
        return CommandApplyResult(
            changedSetIDs: displaced.changedSetIDs + [workSet.id],
            joinedMemberID: memberID
        )
    }

    /// A terminal/session belongs to at most one logical set. Keep a matching
    /// member already present in the target set (so a same-set rejoin preserves
    /// its group policy), but remove every matching identity from other sets.
    /// The first displaced member is returned so moving through `cmux-set join`
    /// retains prompt, lifecycle, and remote-order metadata.
    private static func displaceMatchingIdentity(
        surfaceID: String?,
        sessionID: String?,
        excludingSetAt targetIndex: Int,
        snapshot: inout CompanionSnapshot
    ) -> (changedSetIDs: [UUID], member: WorkMember?) {
        var changedSetIDs: [UUID] = []
        var displacedMember: WorkMember?

        for setIndex in snapshot.sets.indices where setIndex != targetIndex {
            let matchingMembers = snapshot.sets[setIndex].members.filter { member in
                let matchesSurface = surfaceID.map { member.surfaceID == $0 } ?? false
                let matchesSession = sessionID.map { member.sessionID == $0 } ?? false
                return matchesSurface || matchesSession
            }
            let removedMemberIDs = Set(matchingMembers.map(\.id))
            var didChange = !removedMemberIDs.isEmpty

            if displacedMember == nil {
                displacedMember = matchingMembers.first
            }
            if !removedMemberIDs.isEmpty {
                snapshot.sets[setIndex].members.removeAll { removedMemberIDs.contains($0.id) }
                for groupIndex in snapshot.sets[setIndex].groups.indices {
                    snapshot.sets[setIndex].groups[groupIndex].memberIDs.removeAll {
                        removedMemberIDs.contains($0)
                    }
                }
                snapshot.sets[setIndex].groups.removeAll { $0.memberIDs.isEmpty }
            }

            if let surfaceID {
                let attachmentCount = snapshot.sets[setIndex].attachments.count
                snapshot.sets[setIndex].attachments.removeAll { $0.surfaceID == surfaceID }
                didChange = didChange || snapshot.sets[setIndex].attachments.count != attachmentCount
            }

            if didChange {
                changedSetIDs.append(snapshot.sets[setIndex].id)
            }
        }

        return (changedSetIDs, displacedMember)
    }

    /// When the duplicate session row is the sole member of a custom group for
    /// the incoming role, transfer that one destination membership before the
    /// duplicate ID is removed. This preserves required/quorum policy while the
    /// surface-selected member changes role.
    private static func preserveDestinationGroupMembership(
        canonicalMemberID: UUID,
        duplicateMemberIDs: Set<UUID>,
        role: MemberRole,
        preferredGroupID: UUID? = nil,
        in workSet: inout WorkSet
    ) {
        let alreadyHasDestinationMembership = workSet.groups.contains { group in
            let isRequestedDestination = preferredGroupID.map { group.id == $0 }
                ?? (group.role == role)
            return isRequestedDestination && group.memberIDs.contains(canonicalMemberID)
        }
        guard !alreadyHasDestinationMembership else { return }
        let preferredIndex = preferredGroupID.flatMap { preferredGroupID in
            workSet.groups.firstIndex(where: { group in
                group.id == preferredGroupID
                    && group.role == role
                    && group.memberIDs.contains(where: duplicateMemberIDs.contains)
            })
        }
        guard let groupIndex = preferredIndex ?? workSet.groups.firstIndex(where: { group in
                  group.role == role
                      && group.memberIDs.contains(where: duplicateMemberIDs.contains)
              }),
              let replacementIndex = workSet.groups[groupIndex].memberIDs.firstIndex(
                  where: duplicateMemberIDs.contains
              ) else { return }

        workSet.groups[groupIndex].memberIDs[replacementIndex] = canonicalMemberID
    }

    private static func removeMembersAndGroupReferences(
        _ memberIDs: Set<UUID>,
        from workSet: inout WorkSet
    ) {
        guard !memberIDs.isEmpty else { return }
        workSet.members.removeAll { memberIDs.contains($0.id) }
        for groupIndex in workSet.groups.indices {
            workSet.groups[groupIndex].memberIDs.removeAll { memberIDs.contains($0) }
        }
        workSet.groups.removeAll { $0.memberIDs.isEmpty }
    }

    /// Preserves the surface-selected row while retaining useful state from a
    /// duplicate session row. Explicit command fields are applied afterward.
    private static func mergeMetadata(from candidate: WorkMember, into member: inout WorkMember) {
        if member.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            member.label = candidate.label
        }
        member.agent = member.agent ?? candidate.agent
        member.sessionID = member.sessionID ?? candidate.sessionID
        member.surfaceID = member.surfaceID ?? candidate.surfaceID
        member.workspaceID = member.workspaceID ?? candidate.workspaceID
        member.windowID = member.windowID ?? candidate.windowID

        let memberHeartbeat = member.lastHeartbeatAt ?? .distantPast
        let candidateHeartbeat = candidate.lastHeartbeatAt ?? .distantPast
        if candidateHeartbeat > memberHeartbeat
            || (member.runtimeState == .unknown && candidate.runtimeState != .unknown) {
            member.runtimeState = candidate.runtimeState
        }
        if candidateHeartbeat > memberHeartbeat {
            member.lastHeartbeatAt = candidate.lastHeartbeatAt
        }

        if let candidateText = candidate.lastSubmittedText {
            let shouldUseCandidate: Bool
            switch (member.lastSubmittedText, member.lastSubmittedAt, candidate.lastSubmittedAt) {
            case (nil, _, _):
                shouldUseCandidate = true
            case (_, nil, _?):
                shouldUseCandidate = true
            case (_, let current?, let incoming?):
                shouldUseCandidate = incoming > current
            default:
                shouldUseCandidate = false
            }
            if shouldUseCandidate {
                member.lastSubmittedText = candidateText
                member.lastSubmittedAt = candidate.lastSubmittedAt
            }
        }

        let shouldUseCandidateRemoteOrder: Bool
        switch (
            member.lastRemoteBootID,
            member.lastRemoteSequence,
            candidate.lastRemoteBootID,
            candidate.lastRemoteSequence
        ) {
        case (_, _, nil, _), (_, _, _, nil):
            shouldUseCandidateRemoteOrder = false
        case (nil, _, _?, _?), (_, nil, _?, _?):
            shouldUseCandidateRemoteOrder = true
        case let (currentBoot?, currentSequence?, incomingBoot?, incomingSequence?)
            where currentBoot == incomingBoot:
            shouldUseCandidateRemoteOrder = incomingSequence > currentSequence
        default:
            shouldUseCandidateRemoteOrder = candidateHeartbeat > memberHeartbeat
        }
        if shouldUseCandidateRemoteOrder {
            member.lastRemoteBootID = candidate.lastRemoteBootID
            member.lastRemoteSequence = candidate.lastRemoteSequence
        }

        switch (member.localOwnershipSince, candidate.localOwnershipSince) {
        case (nil, let candidateOwnership?):
            member.localOwnershipSince = candidateOwnership
        case (let current?, let candidateOwnership?) where candidateOwnership > current:
            member.localOwnershipSince = candidateOwnership
        default:
            break
        }
        member.isRemote = member.isRemote || candidate.isRemote
    }

    private static func leave(
        _ command: InboxCommand,
        snapshot: inout CompanionSnapshot
    ) throws -> CommandApplyResult {
        let surfaceID = command.cmuxContext.effectiveSurfaceID
        let sessionID = normalized(command.session)
        guard surfaceID != nil || sessionID != nil else {
            throw CommandApplyError.missingMemberIdentity
        }

        let candidateIndices: [Int]
        if let setName = normalized(command.setName) {
            guard let index = setIndex(named: setName, in: snapshot) else {
                throw CommandApplyError.setNotFound(setName)
            }
            candidateIndices = [index]
        } else {
            candidateIndices = Array(snapshot.sets.indices)
        }

        var changedSetIDs: [UUID] = []
        for index in candidateIndices {
            let removedIDs = snapshot.sets[index].members.compactMap { member -> UUID? in
                if let surfaceID, member.surfaceID == surfaceID { return member.id }
                if let sessionID, member.sessionID == sessionID { return member.id }
                return nil
            }
            let attachmentCount = snapshot.sets[index].attachments.count
            if let surfaceID {
                snapshot.sets[index].attachments.removeAll { $0.surfaceID == surfaceID }
            }
            let removedAttachment = snapshot.sets[index].attachments.count != attachmentCount
            guard !removedIDs.isEmpty || removedAttachment else { continue }

            let removed = Set(removedIDs)
            snapshot.sets[index].members.removeAll { removed.contains($0.id) }
            for groupIndex in snapshot.sets[index].groups.indices {
                snapshot.sets[index].groups[groupIndex].memberIDs.removeAll { removed.contains($0) }
            }
            snapshot.sets[index].groups.removeAll { $0.memberIDs.isEmpty }
            changedSetIDs.append(snapshot.sets[index].id)
        }

        return CommandApplyResult(changedSetIDs: changedSetIDs)
    }

    private static func updateMatchingMembers(
        _ command: InboxCommand,
        snapshot: inout CompanionSnapshot,
        update: (inout WorkMember) -> Void
    ) throws -> CommandApplyResult {
        let surfaceID = command.cmuxContext.effectiveSurfaceID
        let sessionID = normalized(command.session)
        guard surfaceID != nil || sessionID != nil else {
            throw CommandApplyError.missingMemberIdentity
        }

        let candidateIndices: [Int]
        if let setName = normalized(command.setName) {
            guard let index = setIndex(named: setName, in: snapshot) else {
                throw CommandApplyError.setNotFound(setName)
            }
            candidateIndices = [index]
        } else {
            candidateIndices = Array(snapshot.sets.indices)
        }

        var changedSetIDs: [UUID] = []
        for setIndex in candidateIndices {
            var didChange = false
            for memberIndex in snapshot.sets[setIndex].members.indices {
                let member = snapshot.sets[setIndex].members[memberIndex]
                let matchesSurface = surfaceID.map { member.surfaceID == $0 } ?? false
                let matchesSession = sessionID.map { member.sessionID == $0 } ?? false
                guard matchesSurface || matchesSession else { continue }

                update(&snapshot.sets[setIndex].members[memberIndex])
                didChange = true
            }
            if didChange {
                changedSetIDs.append(snapshot.sets[setIndex].id)
            }
        }
        return CommandApplyResult(changedSetIDs: changedSetIDs)
    }

    private static func requiredSetIndex(
        for command: InboxCommand,
        in snapshot: CompanionSnapshot
    ) throws -> Int {
        guard let name = normalized(command.setName) else {
            throw CommandApplyError.missingSetName(command.kind)
        }
        guard let index = setIndex(named: name, in: snapshot) else {
            throw CommandApplyError.setNotFound(name)
        }
        return index
    }

    private static func setIndex(named name: String, in snapshot: CompanionSnapshot) -> Int? {
        snapshot.sets.firstIndex {
            $0.label.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private static func defaultGroupLabel(for role: MemberRole) -> String {
        switch role {
        case .worker: return "Workers"
        case .reviewer: return "Reviewers"
        case .pr: return "PR"
        case .other: return "Other"
        }
    }

    private static func runtimeState(from rawValue: String) -> MemberRuntimeState? {
        if let exact = MemberRuntimeState(rawValue: rawValue.lowercased()) {
            return exact
        }
        let normalized = rawValue.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "working", "busy", "active": return .running
        case "needsinput", "permission", "blocked": return .waiting
        case "stopped", "stop", "done": return .idle
        case "closed", "exited": return .ended
        case "offline": return .disconnected
        case "failed": return .error
        default: return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
