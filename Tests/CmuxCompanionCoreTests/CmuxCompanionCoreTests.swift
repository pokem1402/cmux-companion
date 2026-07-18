import Foundation
import XCTest
@testable import CmuxCompanionCore

final class SetEvaluatorTests: XCTestCase {
    func testPriorityIsAttentionThenIncompleteThenActive() {
        let worker = WorkMember(label: "Main", role: .worker, runtimeState: .running)
        var reviewer = WorkMember(label: "Claude", role: .reviewer, runtimeState: .waiting)
        let groups = [
            WorkGroup(label: "Worker", role: .worker, policy: .all, memberIDs: [worker.id]),
            WorkGroup(label: "Reviewers", role: .reviewer, policy: .all, memberIDs: [reviewer.id])
        ]
        var set = WorkSet(label: "PR-42", armed: true, groups: groups, members: [worker, reviewer])

        var result = SetEvaluator.evaluate(set)
        XCTAssertEqual(result.status, .attention)
        XCTAssertEqual(result.attentionMemberIDs, [reviewer.id])
        XCTAssertTrue(result.shouldNotify)

        reviewer.runtimeState = .idle
        set.members[1] = reviewer
        result = SetEvaluator.evaluate(set)
        XCTAssertEqual(result.status, .incomplete, "A required group deficit outranks another running member")
        XCTAssertEqual(result.deficientGroupIDs, [groups[1].id])

        reviewer.runtimeState = .running
        set.members[1] = reviewer
        result = SetEvaluator.evaluate(set)
        XCTAssertEqual(result.status, .active)
        XCTAssertFalse(result.shouldNotify)
    }

    func testPreferredFocusMemberComesFromDeficientGroup() {
        let worker = WorkMember(label: "Worker", role: .worker, runtimeState: .running)
        let reviewer = WorkMember(label: "Reviewer", role: .reviewer, runtimeState: .idle)
        let set = WorkSet(
            label: "Focus",
            armed: true,
            groups: [
                WorkGroup(label: "Workers", role: .worker, memberIDs: [worker.id]),
                WorkGroup(label: "Reviewers", role: .reviewer, memberIDs: [reviewer.id])
            ],
            members: [worker, reviewer]
        )
        let evaluation = SetEvaluator.evaluate(set)

        XCTAssertEqual(evaluation.status, .incomplete)
        XCTAssertEqual(
            SetEvaluator.preferredFocusMemberID(in: set, evaluation: evaluation),
            reviewer.id
        )

        var optionalReviewerSet = set
        optionalReviewerSet.groups[1].required = false
        let optionalEvaluation = SetEvaluator.evaluate(optionalReviewerSet)
        XCTAssertEqual(optionalEvaluation.status, .active)
        XCTAssertEqual(
            SetEvaluator.preferredFocusMemberID(
                in: optionalReviewerSet,
                evaluation: optionalEvaluation
            ),
            worker.id
        )
    }

    func testMinActivePolicyAndSnooze() {
        let first = WorkMember(label: "Claude", role: .reviewer, runtimeState: .running)
        let second = WorkMember(label: "Codex", role: .reviewer, runtimeState: .idle)
        let group = WorkGroup(
            label: "Reviewers",
            role: .reviewer,
            policy: .minActive(2),
            memberIDs: [first.id, second.id]
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let set = WorkSet(
            label: "Review",
            armed: true,
            groups: [group],
            members: [first, second],
            snoozedUntil: now.addingTimeInterval(60)
        )

        let result = SetEvaluator.evaluate(set, now: now)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.groups.first?.requiredActiveCount, 2)
        XCTAssertTrue(result.isSnoozed)
        XCTAssertFalse(result.shouldNotify)
    }

    func testStopDoesNotCompleteGenerationButManualCompletionDoes() {
        let member = WorkMember(label: "Main", role: .worker, runtimeState: .ended)
        let group = WorkGroup(label: "Worker", role: .worker, policy: .all, memberIDs: [member.id])
        var set = WorkSet(label: "Feature", armed: true, groups: [group], members: [member])

        var result = SetEvaluator.evaluate(set)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertFalse(result.isGenerationCompleted)

        set.completeCurrentGeneration()
        result = SetEvaluator.evaluate(set)
        XCTAssertEqual(result.status, .idle)
        XCTAssertTrue(result.isGenerationCompleted)
        XCTAssertFalse(result.shouldNotify)

        set.arm()
        XCTAssertEqual(set.generation, 2)
        XCTAssertNil(set.completedGeneration)
        XCTAssertEqual(SetEvaluator.evaluate(set).status, .incomplete)
    }

    func testOptionalGroupAttentionDoesNotEscalateSet() {
        let worker = WorkMember(label: "Main", role: .worker, runtimeState: .running)
        let optionalReviewer = WorkMember(label: "Optional", role: .reviewer, runtimeState: .waiting)
        let set = WorkSet(
            label: "Feature",
            armed: true,
            groups: [
                WorkGroup(
                    label: "Workers",
                    role: .worker,
                    required: true,
                    policy: .all,
                    memberIDs: [worker.id]
                ),
                WorkGroup(
                    label: "Optional reviewers",
                    role: .reviewer,
                    required: false,
                    policy: .all,
                    memberIDs: [optionalReviewer.id]
                )
            ],
            members: [worker, optionalReviewer]
        )

        let result = SetEvaluator.evaluate(set)
        XCTAssertEqual(result.status, .active)
        XCTAssertTrue(result.attentionMemberIDs.isEmpty)
        XCTAssertTrue(result.deficientGroupIDs.isEmpty)
        XCTAssertFalse(result.shouldNotify)
        XCTAssertEqual(set.members[1].runtimeState, .waiting, "UI runtime detail remains available")
    }
}

final class CompanionStoreTests: XCTestCase {
    func testAtomicStoreRoundTripAndSchemaVersion() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/sets.json")
        let store = CompanionStore(url: url)
        let submittedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let member = WorkMember(
            label: "Remote Codex",
            role: .reviewer,
            agent: "codex",
            sessionID: "session-1",
            surfaceID: "surface-1",
            workspaceID: "workspace-1",
            windowID: "window-1",
            runtimeState: .waiting,
            lastSubmittedText: "Review the race condition",
            lastSubmittedAt: submittedAt,
            lastHeartbeatAt: submittedAt,
            lastRemoteBootID: "boot-1",
            lastRemoteSequence: 42,
            localOwnershipSince: submittedAt,
            isRemote: true
        )
        let group = WorkGroup(
            label: "Reviewers",
            role: .reviewer,
            policy: .minActive(1),
            memberIDs: [member.id]
        )
        let attachment = WorkAttachment(
            label: "PR page",
            url: URL(string: "https://github.com/example/project/pull/42"),
            surfaceID: "browser-surface",
            workspaceID: "workspace-1",
            windowID: "window-1"
        )
        let set = WorkSet(
            label: "PR-42",
            color: "#FF9500",
            armed: true,
            generation: 3,
            groups: [group],
            members: [member],
            attachments: [attachment],
            snoozedUntil: submittedAt.addingTimeInterval(60)
        )
        let snapshot = CompanionSnapshot(sets: [set])

        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertEqual(loaded, snapshot)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(root?["schemaVersion"] as? Int, CompanionSnapshot.currentSchemaVersion)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingStoreLoadsEmptySnapshot() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStore(url: directory.appendingPathComponent("missing.json"))
        XCTAssertEqual(try store.load(), CompanionSnapshot())
    }

    func testUnsupportedSchemaIsRejected() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sets.json")
        let unsupported = CompanionSnapshot(schemaVersion: 99)
        try JSONEncoder().encode(unsupported).write(to: url)

        XCTAssertThrowsError(try CompanionStore(url: url).load()) { error in
            XCTAssertEqual(
                error as? CompanionStoreError,
                .unsupportedSchemaVersion(found: 99, supported: CompanionSnapshot.currentSchemaVersion)
            )
        }
    }
}

final class CommandInboxTests: XCTestCase {
    func testEnqueuePeekAndDrainUseUniqueOrderedFiles() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CommandInbox(directoryURL: directory)
        let first = InboxCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .arm,
            createdAt: Date(timeIntervalSince1970: 100),
            setName: "Feature"
        )
        let second = InboxCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            kind: .complete,
            createdAt: Date(timeIntervalSince1970: 101),
            setName: "Feature"
        )

        let firstURL = try inbox.enqueue(first)
        let secondURL = try inbox.enqueue(second)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try inbox.peek().map(\.id), [first.id, second.id])
        XCTAssertEqual(try inbox.drain().map(\.id), [first.id, second.id])
        XCTAssertTrue(try inbox.peek().isEmpty)
    }

    func testDecodesCmuxSetCLISnakeCaseWireFormat() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = """
        {
          "version": 1,
          "id": "11111111-1111-1111-1111-111111111111",
          "kind": "join",
          "created_at": "2026-07-18T12:34:56Z",
          "set_name": "PR-99",
          "role": "reviewer",
          "label": "Claude",
          "agent": "claude",
          "session": "remote-session",
          "required": true,
          "cmux_context": {
            "window_id": "window",
            "workspace_id": "workspace",
            "panel_id": "legacy-panel"
          },
          "source": {
            "executable": "cmux-set",
            "pid": 42,
            "host": "mac"
          }
        }
        """
        try Data(fixture.utf8).write(to: directory.appendingPathComponent("001.json"))

        let command = try XCTUnwrap(CommandInbox(directoryURL: directory).peek().first)
        XCTAssertEqual(command.setName, "PR-99")
        XCTAssertEqual(command.role, .reviewer)
        XCTAssertEqual(command.cmuxContext.effectiveSurfaceID, "legacy-panel")
        XCTAssertNil(command.text, "New optional fields must remain backward compatible")
    }

    func testDecodeFailureLeavesWholeBatchInPlace() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CommandInbox(directoryURL: directory)
        _ = try inbox.enqueue(InboxCommand(kind: .arm, setName: "Feature"))
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("zzz.json"))

        XCTAssertThrowsError(try inbox.drain())
        let jsonFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(jsonFiles.count, 2)
    }
}

final class CommandReducerTests: XCTestCase {
    func testJoinHeartbeatAndLastInputUpdateSameMember() throws {
        let context = CmuxContext(windowID: "window", workspaceID: "workspace", surfaceID: "surface")
        var snapshot = CompanionSnapshot()
        let join = InboxCommand(
            kind: .join,
            setName: "PR-12",
            role: .worker,
            label: "Main Codex",
            agent: "codex",
            session: "session",
            required: true,
            cmuxContext: context
        )

        let joinResult = try CommandReducer.apply(join, to: &snapshot)
        XCTAssertEqual(snapshot.sets.count, 1)
        XCTAssertEqual(snapshot.sets[0].groups[0].memberIDs, [joinResult.joinedMemberID!])

        let heartbeatAt = Date(timeIntervalSince1970: 2_000)
        let heartbeat = InboxCommand(
            kind: .heartbeat,
            createdAt: heartbeatAt,
            session: "session",
            state: MemberRuntimeState.running.rawValue,
            remote: true,
            cmuxContext: CmuxContext(workspaceID: "new-workspace", surfaceID: "surface")
        )
        _ = try CommandReducer.apply(heartbeat, to: &snapshot)
        XCTAssertEqual(snapshot.sets[0].members[0].runtimeState, .running)
        XCTAssertEqual(snapshot.sets[0].members[0].workspaceID, "new-workspace")
        XCTAssertEqual(snapshot.sets[0].members[0].lastHeartbeatAt, heartbeatAt)
        XCTAssertTrue(snapshot.sets[0].members[0].isRemote)

        let inputAt = heartbeatAt.addingTimeInterval(1)
        let lastInput = InboxCommand(
            kind: .lastInput,
            createdAt: inputAt,
            session: "session",
            text: "Please review the synchronization logic"
        )
        _ = try CommandReducer.apply(lastInput, to: &snapshot)
        XCTAssertEqual(snapshot.sets[0].members[0].lastSubmittedText, lastInput.text)
        XCTAssertEqual(snapshot.sets[0].members[0].lastSubmittedAt, inputAt)
    }

    func testArmCompleteRenameAndLeaveLifecycle() throws {
        let context = CmuxContext(surfaceID: "surface")
        var snapshot = CompanionSnapshot()
        _ = try CommandReducer.apply(
            InboxCommand(kind: .join, setName: "Old", role: .worker, cmuxContext: context),
            to: &snapshot
        )
        _ = try CommandReducer.apply(InboxCommand(kind: .arm, setName: "Old"), to: &snapshot)
        XCTAssertTrue(snapshot.sets[0].armed)

        _ = try CommandReducer.apply(
            InboxCommand(kind: .rename, setName: "old", label: "New"),
            to: &snapshot
        )
        _ = try CommandReducer.apply(InboxCommand(kind: .complete, setName: "New"), to: &snapshot)
        XCTAssertEqual(snapshot.sets[0].completedGeneration, snapshot.sets[0].generation)

        _ = try CommandReducer.apply(
            InboxCommand(kind: .leave, setName: "New", cmuxContext: context),
            to: &snapshot
        )
        XCTAssertTrue(snapshot.sets[0].members.isEmpty)
        XCTAssertTrue(snapshot.sets[0].groups.isEmpty)
    }

    func testRenameRejectsCaseAndDiacriticEquivalentDuplicate() throws {
        var snapshot = CompanionSnapshot(sets: [
            WorkSet(label: "Main"),
            WorkSet(label: "Café")
        ])

        XCTAssertThrowsError(try CommandReducer.apply(
            InboxCommand(kind: .rename, setName: "Main", label: "CAFE"),
            to: &snapshot
        )) { error in
            XCTAssertEqual(error as? CommandApplyError, .duplicateSetName("CAFE"))
        }
        XCTAssertEqual(snapshot.sets.map(\.label), ["Main", "Café"])
    }

    func testSameRoleRejoinPreservesGroupAndExplicitRequiredUpdatesIt() throws {
        let context = CmuxContext(surfaceID: "review-surface")
        let member = WorkMember(
            label: "Claude",
            role: .reviewer,
            agent: "claude",
            sessionID: "review-session",
            surfaceID: "review-surface"
        )
        let group = WorkGroup(
            label: "Reviewers",
            role: .reviewer,
            required: false,
            policy: .minActive(1),
            memberIDs: [member.id]
        )
        let unrelatedMember = WorkMember(
            label: "Other worker",
            role: .worker,
            sessionID: "other-session",
            surfaceID: "other-surface"
        )
        let unrelatedSet = WorkSet(label: "Unrelated", members: [unrelatedMember])
        var snapshot = CompanionSnapshot(
            sets: [
                WorkSet(label: "PR-24", groups: [group], members: [member]),
                unrelatedSet
            ]
        )

        let rejoin = InboxCommand(
            kind: .join,
            setName: "PR-24",
            role: .reviewer,
            label: "Claude review",
            session: "review-session",
            cmuxContext: context
        )
        let rejoinResult = try CommandReducer.apply(rejoin, to: &snapshot)

        XCTAssertEqual(snapshot.sets[0].members.count, 1)
        XCTAssertEqual(snapshot.sets[0].members[0].id, member.id)
        XCTAssertEqual(snapshot.sets[0].members[0].label, "Claude review")
        XCTAssertEqual(snapshot.sets[0].groups, [group])
        XCTAssertEqual(snapshot.sets[1], unrelatedSet)
        XCTAssertEqual(rejoinResult.changedSetIDs, [snapshot.sets[0].id])
        XCTAssertEqual(rejoinResult.joinedMemberID, member.id)

        _ = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "PR-24",
                role: .reviewer,
                session: "review-session",
                required: true,
                cmuxContext: context
            ),
            to: &snapshot
        )
        XCTAssertTrue(snapshot.sets[0].groups[0].required)
        XCTAssertEqual(snapshot.sets[0].groups[0].policy, .minActive(1))

        _ = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "PR-24",
                role: .reviewer,
                session: "review-session",
                required: false,
                cmuxContext: context
            ),
            to: &snapshot
        )
        XCTAssertFalse(snapshot.sets[0].groups[0].required)
        XCTAssertEqual(snapshot.sets[0].groups[0].id, group.id)
        XCTAssertEqual(snapshot.sets[0].groups[0].policy, .minActive(1))
    }

    func testCrossSetJoinMovesSurfaceAndCleansSourceGroups() throws {
        let submittedAt = Date(timeIntervalSince1970: 2_100)
        let movingMember = WorkMember(
            label: "Remote reviewer",
            role: .worker,
            agent: "codex",
            sessionID: "moving-session",
            surfaceID: "moving-surface",
            workspaceID: "source-workspace",
            runtimeState: .waiting,
            lastSubmittedText: "Review the ownership change",
            lastSubmittedAt: submittedAt,
            lastHeartbeatAt: submittedAt,
            lastRemoteBootID: "boot-1",
            lastRemoteSequence: 17,
            isRemote: true
        )
        let sourceReviewer = WorkMember(
            label: "Source reviewer",
            role: .reviewer,
            surfaceID: "source-reviewer"
        )
        let sourceWorkerGroup = WorkGroup(
            label: "Workers",
            role: .worker,
            memberIDs: [movingMember.id]
        )
        let sourceReviewerGroup = WorkGroup(
            label: "Reviewers",
            role: .reviewer,
            required: false,
            policy: .minActive(1),
            memberIDs: [sourceReviewer.id]
        )
        let sourceSet = WorkSet(
            label: "Source",
            groups: [sourceWorkerGroup, sourceReviewerGroup],
            members: [movingMember, sourceReviewer],
            attachments: [WorkAttachment(label: "stale duplicate", surfaceID: "moving-surface")]
        )

        let destinationReviewer = WorkMember(
            label: "Destination reviewer",
            role: .reviewer,
            surfaceID: "destination-reviewer"
        )
        let destinationGroup = WorkGroup(
            label: "Review quorum",
            role: .reviewer,
            required: false,
            policy: .minActive(1),
            memberIDs: [destinationReviewer.id]
        )
        let destinationSet = WorkSet(
            label: "Destination",
            groups: [destinationGroup],
            members: [destinationReviewer]
        )
        var snapshot = CompanionSnapshot(sets: [sourceSet, destinationSet])

        let result = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "Destination",
                role: .reviewer,
                session: "moving-session",
                cmuxContext: CmuxContext(
                    windowID: "destination-window",
                    workspaceID: "destination-workspace",
                    surfaceID: "moving-surface"
                )
            ),
            to: &snapshot
        )

        XCTAssertEqual(snapshot.sets[0].members, [sourceReviewer])
        XCTAssertEqual(snapshot.sets[0].groups, [sourceReviewerGroup])
        XCTAssertTrue(snapshot.sets[0].attachments.isEmpty)

        let moved = try XCTUnwrap(snapshot.sets[1].members.first { $0.id == movingMember.id })
        XCTAssertEqual(moved.role, .reviewer)
        XCTAssertEqual(moved.workspaceID, "destination-workspace")
        XCTAssertEqual(moved.windowID, "destination-window")
        XCTAssertEqual(moved.runtimeState, .waiting)
        XCTAssertEqual(moved.lastSubmittedText, movingMember.lastSubmittedText)
        XCTAssertEqual(moved.lastRemoteBootID, "boot-1")
        XCTAssertEqual(moved.lastRemoteSequence, 17)
        XCTAssertTrue(moved.isRemote)

        let preservedDestinationGroup = try XCTUnwrap(
            snapshot.sets[1].groups.first { $0.id == destinationGroup.id }
        )
        XCTAssertEqual(preservedDestinationGroup.label, "Review quorum")
        XCTAssertEqual(preservedDestinationGroup.policy, .minActive(1))
        XCTAssertFalse(preservedDestinationGroup.required)
        XCTAssertEqual(
            Set(preservedDestinationGroup.memberIDs),
            Set([destinationReviewer.id, movingMember.id])
        )
        XCTAssertEqual(result.changedSetIDs, [sourceSet.id, destinationSet.id])
        XCTAssertEqual(result.joinedMemberID, movingMember.id)
    }

    func testCrossSetJoinMovesBySessionWhenSurfaceChanges() throws {
        let movingMember = WorkMember(
            label: "SSH Codex",
            role: .worker,
            sessionID: "stable-session",
            surfaceID: "old-surface"
        )
        let sourceGroup = WorkGroup(
            label: "Workers",
            role: .worker,
            memberIDs: [movingMember.id]
        )
        let sourceSet = WorkSet(
            label: "Old set",
            groups: [sourceGroup],
            members: [movingMember]
        )
        let destinationSet = WorkSet(label: "New set")
        var snapshot = CompanionSnapshot(sets: [sourceSet, destinationSet])

        let result = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "New set",
                role: .worker,
                session: "stable-session",
                cmuxContext: CmuxContext(
                    workspaceID: "new-workspace",
                    surfaceID: "new-surface"
                )
            ),
            to: &snapshot
        )

        XCTAssertTrue(snapshot.sets[0].members.isEmpty)
        XCTAssertTrue(snapshot.sets[0].groups.isEmpty)
        XCTAssertEqual(snapshot.sets[1].members.count, 1)
        XCTAssertEqual(snapshot.sets[1].members[0].id, movingMember.id)
        XCTAssertEqual(snapshot.sets[1].members[0].surfaceID, "new-surface")
        XCTAssertEqual(snapshot.sets[1].members[0].workspaceID, "new-workspace")
        XCTAssertEqual(snapshot.sets[1].groups.first?.memberIDs, [movingMember.id])
        XCTAssertEqual(result.changedSetIDs, [sourceSet.id, destinationSet.id])
    }

    func testTargetSplitIdentityMergesToSurfaceMemberAndSubsequentCommandsMatchOnce() throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let surfaceMember = WorkMember(
            label: "Surface owner",
            role: .worker,
            agent: "codex",
            sessionID: "old-session",
            surfaceID: "shared-surface",
            runtimeState: .unknown,
            lastSubmittedText: "older prompt",
            lastSubmittedAt: oldDate,
            lastHeartbeatAt: oldDate,
            lastRemoteBootID: "old-boot",
            lastRemoteSequence: 2
        )
        let sessionMember = WorkMember(
            label: "Session duplicate",
            role: .reviewer,
            agent: "claude",
            sessionID: "shared-session",
            surfaceID: "old-surface",
            runtimeState: .waiting,
            lastSubmittedText: "newer prompt",
            lastSubmittedAt: newDate,
            lastHeartbeatAt: newDate,
            lastRemoteBootID: "new-boot",
            lastRemoteSequence: 9,
            localOwnershipSince: newDate,
            isRemote: true
        )
        let canonicalGroup = WorkGroup(
            label: "Original workers",
            role: .worker,
            memberIDs: [surfaceMember.id]
        )
        let duplicateGroup = WorkGroup(
            label: "Custom review quorum",
            role: .reviewer,
            required: false,
            policy: .minActive(1),
            memberIDs: [sessionMember.id]
        )
        let workSet = WorkSet(
            label: "Split",
            groups: [canonicalGroup, duplicateGroup],
            members: [surfaceMember, sessionMember]
        )
        var snapshot = CompanionSnapshot(sets: [workSet])

        let joinResult = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "Split",
                role: .reviewer,
                session: "shared-session",
                cmuxContext: CmuxContext(surfaceID: "shared-surface")
            ),
            to: &snapshot
        )

        XCTAssertEqual(snapshot.sets[0].members.count, 1)
        let merged = try XCTUnwrap(snapshot.sets[0].members.first)
        XCTAssertEqual(merged.id, surfaceMember.id)
        XCTAssertEqual(merged.sessionID, "shared-session")
        XCTAssertEqual(merged.surfaceID, "shared-surface")
        XCTAssertEqual(merged.runtimeState, .waiting)
        XCTAssertEqual(merged.lastSubmittedText, "newer prompt")
        XCTAssertEqual(merged.lastSubmittedAt, newDate)
        XCTAssertEqual(merged.lastHeartbeatAt, newDate)
        XCTAssertEqual(merged.lastRemoteBootID, "new-boot")
        XCTAssertEqual(merged.lastRemoteSequence, 9)
        XCTAssertEqual(merged.localOwnershipSince, newDate)
        XCTAssertTrue(merged.isRemote)
        XCTAssertEqual(snapshot.sets[0].groups.count, 1)
        let preservedReviewerGroup = snapshot.sets[0].groups[0]
        XCTAssertEqual(preservedReviewerGroup.id, duplicateGroup.id)
        XCTAssertEqual(preservedReviewerGroup.label, "Custom review quorum")
        XCTAssertEqual(preservedReviewerGroup.role, .reviewer)
        XCTAssertFalse(preservedReviewerGroup.required)
        XCTAssertEqual(preservedReviewerGroup.policy, .minActive(1))
        XCTAssertEqual(preservedReviewerGroup.memberIDs, [surfaceMember.id])
        XCTAssertFalse(snapshot.sets[0].groups.contains { $0.id == canonicalGroup.id })
        XCTAssertEqual(joinResult.joinedMemberID, surfaceMember.id)

        let heartbeatDate = Date(timeIntervalSince1970: 300)
        let heartbeatResult = try CommandReducer.apply(
            InboxCommand(
                kind: .heartbeat,
                createdAt: heartbeatDate,
                setName: "Split",
                session: "shared-session",
                state: "running",
                remote: true,
                cmuxContext: CmuxContext(surfaceID: "shared-surface")
            ),
            to: &snapshot
        )
        XCTAssertEqual(snapshot.sets[0].members.count, 1)
        XCTAssertEqual(snapshot.sets[0].members[0].runtimeState, .running)
        XCTAssertEqual(snapshot.sets[0].members[0].lastHeartbeatAt, heartbeatDate)
        XCTAssertEqual(heartbeatResult.changedSetIDs, [workSet.id])

        let inputDate = Date(timeIntervalSince1970: 400)
        let inputResult = try CommandReducer.apply(
            InboxCommand(
                kind: .lastInput,
                createdAt: inputDate,
                session: "shared-session",
                text: "single update"
            ),
            to: &snapshot
        )
        XCTAssertEqual(snapshot.sets[0].members.count, 1)
        XCTAssertEqual(snapshot.sets[0].members[0].lastSubmittedText, "single update")
        XCTAssertEqual(inputResult.changedSetIDs, [workSet.id])

        let leaveResult = try CommandReducer.apply(
            InboxCommand(
                kind: .leave,
                setName: "Split",
                session: "shared-session",
                cmuxContext: CmuxContext(surfaceID: "shared-surface")
            ),
            to: &snapshot
        )
        XCTAssertTrue(snapshot.sets[0].members.isEmpty)
        XCTAssertTrue(snapshot.sets[0].groups.isEmpty)
        XCTAssertEqual(leaveResult.changedSetIDs, [workSet.id])
    }

    func testPRJoinRemovesEveryTargetSurfaceOrSessionMatch() throws {
        let surfaceMember = WorkMember(
            label: "Surface worker",
            role: .worker,
            sessionID: "surface-session",
            surfaceID: "pr-surface"
        )
        let sessionMember = WorkMember(
            label: "Session reviewer",
            role: .reviewer,
            sessionID: "shared-session",
            surfaceID: "other-surface"
        )
        let retained = WorkMember(
            label: "Retained reviewer",
            role: .reviewer,
            sessionID: "retained-session",
            surfaceID: "retained-surface"
        )
        let mixedGroup = WorkGroup(
            label: "Mixed",
            memberIDs: [surfaceMember.id, retained.id]
        )
        let removedOnlyGroup = WorkGroup(
            label: "Removed only",
            role: .reviewer,
            memberIDs: [sessionMember.id]
        )
        let workSet = WorkSet(
            label: "PR target",
            groups: [mixedGroup, removedOnlyGroup],
            members: [surfaceMember, sessionMember, retained]
        )
        var snapshot = CompanionSnapshot(sets: [workSet])

        _ = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "PR target",
                role: .pr,
                session: "shared-session",
                cmuxContext: CmuxContext(surfaceID: "pr-surface")
            ),
            to: &snapshot
        )

        XCTAssertEqual(snapshot.sets[0].members, [retained])
        XCTAssertEqual(snapshot.sets[0].groups.count, 1)
        XCTAssertEqual(snapshot.sets[0].groups[0].id, mixedGroup.id)
        XCTAssertEqual(snapshot.sets[0].groups[0].memberIDs, [retained.id])
        XCTAssertEqual(snapshot.sets[0].attachments.count, 1)
        XCTAssertEqual(snapshot.sets[0].attachments[0].surfaceID, "pr-surface")
    }

    func testSessionOnlyPRJoinIsRejectedWithoutMutatingSnapshot() throws {
        let member = WorkMember(
            label: "Existing worker",
            role: .worker,
            sessionID: "session-only",
            surfaceID: "existing-surface"
        )
        let group = WorkGroup(
            label: "Workers",
            role: .worker,
            memberIDs: [member.id]
        )
        var snapshot = CompanionSnapshot(
            sets: [WorkSet(label: "Existing", groups: [group], members: [member])]
        )
        let original = snapshot

        XCTAssertThrowsError(try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "New PR set",
                role: .pr,
                session: "session-only"
            ),
            to: &snapshot
        )) { error in
            XCTAssertEqual(error as? CommandApplyError, .missingMemberIdentity)
        }
        XCTAssertEqual(snapshot, original)
    }

    func testRoleChangeMovesMemberAndPreservesDestinationPolicy() throws {
        let reviewer = WorkMember(
            label: "Claude",
            role: .reviewer,
            sessionID: "moving-session",
            surfaceID: "moving-surface"
        )
        let worker = WorkMember(label: "Codex", role: .worker, surfaceID: "worker-surface")
        let reviewerGroup = WorkGroup(
            label: "Reviewers",
            role: .reviewer,
            policy: .all,
            memberIDs: [reviewer.id]
        )
        let workerGroup = WorkGroup(
            label: "Workers",
            role: .worker,
            required: false,
            policy: .minActive(1),
            memberIDs: [worker.id]
        )
        var snapshot = CompanionSnapshot(
            sets: [
                WorkSet(
                    label: "PR-25",
                    groups: [reviewerGroup, workerGroup],
                    members: [reviewer, worker]
                )
            ]
        )

        _ = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "PR-25",
                role: .worker,
                session: "moving-session",
                cmuxContext: CmuxContext(surfaceID: "moving-surface")
            ),
            to: &snapshot
        )

        XCTAssertEqual(snapshot.sets[0].members.first { $0.id == reviewer.id }?.role, .worker)
        XCTAssertNil(snapshot.sets[0].groups.first { $0.id == reviewerGroup.id })
        let preservedWorkerGroup = try XCTUnwrap(snapshot.sets[0].groups.first { $0.id == workerGroup.id })
        XCTAssertEqual(preservedWorkerGroup.policy, .minActive(1))
        XCTAssertFalse(preservedWorkerGroup.required)
        XCTAssertEqual(Set(preservedWorkerGroup.memberIDs), Set([worker.id, reviewer.id]))
    }

    func testJoinCanTargetExactSameRoleGroupAtomically() throws {
        let moving = WorkMember(
            label: "Claude",
            role: .reviewer,
            sessionID: "exact-session",
            surfaceID: "exact-surface"
        )
        let anchor = WorkMember(label: "Codex", role: .reviewer, surfaceID: "anchor-surface")
        let source = WorkGroup(label: "Primary", role: .reviewer, memberIDs: [moving.id])
        let target = WorkGroup(
            label: "Optional",
            role: .reviewer,
            required: false,
            policy: .minActive(1),
            memberIDs: [anchor.id]
        )
        var snapshot = CompanionSnapshot(sets: [
            WorkSet(label: "Review", groups: [source, target], members: [moving, anchor])
        ])
        let command = InboxCommand(
            kind: .join,
            setName: "Review",
            role: .reviewer,
            groupID: target.id,
            session: moving.sessionID,
            cmuxContext: CmuxContext(surfaceID: moving.surfaceID)
        )

        _ = try CommandReducer.apply(command, to: &snapshot)
        XCTAssertNil(snapshot.sets[0].groups.first { $0.id == source.id })
        let preserved = try XCTUnwrap(snapshot.sets[0].groups.first { $0.id == target.id })
        XCTAssertFalse(preserved.required)
        XCTAssertEqual(preserved.policy, .minActive(1))
        XCTAssertEqual(Set(preserved.memberIDs), Set([moving.id, anchor.id]))

        _ = try CommandReducer.apply(command, to: &snapshot)
        XCTAssertEqual(
            snapshot.sets[0].groups.first { $0.id == target.id }?.memberIDs.filter {
                $0 == moving.id
            }.count,
            1
        )

        let original = snapshot
        XCTAssertThrowsError(try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "Review",
                role: .worker,
                groupID: target.id,
                session: moving.sessionID,
                cmuxContext: CmuxContext(surfaceID: moving.surfaceID)
            ),
            to: &snapshot
        )) { error in
            XCTAssertEqual(error as? CommandApplyError, .groupRoleMismatch(target.id, .worker))
        }
        XCTAssertEqual(snapshot, original)

        let canonical = WorkMember(
            label: "surface row",
            role: .reviewer,
            sessionID: "old-session",
            surfaceID: "shared-surface"
        )
        let duplicate = WorkMember(
            label: "session row",
            role: .reviewer,
            sessionID: "shared-session",
            surfaceID: "other-surface"
        )
        let canonicalGroup = WorkGroup(
            label: "Reviewer lane A",
            role: .reviewer,
            memberIDs: [canonical.id]
        )
        let exactTarget = WorkGroup(
            label: "Reviewer lane B",
            role: .reviewer,
            required: false,
            policy: .minActive(1),
            memberIDs: [duplicate.id]
        )
        var splitSnapshot = CompanionSnapshot(sets: [
            WorkSet(
                label: "Exact split",
                groups: [canonicalGroup, exactTarget],
                members: [canonical, duplicate]
            )
        ])

        let splitResult = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "Exact split",
                role: .reviewer,
                groupID: exactTarget.id,
                session: "shared-session",
                cmuxContext: CmuxContext(surfaceID: "shared-surface")
            ),
            to: &splitSnapshot
        )
        XCTAssertEqual(splitResult.joinedMemberID, canonical.id)
        XCTAssertEqual(splitSnapshot.sets[0].members.map(\.id), [canonical.id])
        XCTAssertEqual(splitSnapshot.sets[0].groups.count, 1)
        XCTAssertEqual(splitSnapshot.sets[0].groups[0].id, exactTarget.id)
        XCTAssertEqual(splitSnapshot.sets[0].groups[0].memberIDs, [canonical.id])
        XCTAssertFalse(splitSnapshot.sets[0].groups[0].required)
        XCTAssertEqual(splitSnapshot.sets[0].groups[0].policy, .minActive(1))
    }
}

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CmuxCompanionCoreTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
