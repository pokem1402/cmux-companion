import Foundation
import XCTest
@testable import CmuxCompanionCore

final class PendingInteractionTests: XCTestCase {
    func testTrackerSeedsBaselineAndEmitsCompletionOnlyOnce() {
        var member = WorkMember(label: "Codex", role: .worker, runtimeState: .running)
        let group = WorkGroup(label: "Worker", role: .worker, memberIDs: [member.id])
        var set = WorkSet(label: "Feature", armed: true, groups: [group], members: [member])
        var tracker = InteractionTransitionTracker()

        XCTAssertTrue(tracker.update(sets: [set], notifyTransitions: false).isEmpty)

        member.runtimeState = .idle
        set.members = [member]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interactions = tracker.update(sets: [set], notifyTransitions: true, now: now)

        XCTAssertEqual(interactions.count, 1)
        XCTAssertEqual(interactions.first?.kind, .completion)
        XCTAssertEqual(interactions.first?.memberID, member.id)
        XCTAssertEqual(interactions.first?.surfaceID, member.surfaceID)
        XCTAssertEqual(interactions.first?.createdAt, now)
        XCTAssertTrue(tracker.update(sets: [set], notifyTransitions: true).isEmpty)
    }

    func testTrackerWaitsForAllRequiredReviewersBeforeCompletion() {
        var first = WorkMember(label: "Claude", role: .reviewer, runtimeState: .running)
        var second = WorkMember(label: "Codex", role: .reviewer, runtimeState: .running)
        let group = WorkGroup(
            label: "Reviewers",
            role: .reviewer,
            memberIDs: [first.id, second.id]
        )
        var set = WorkSet(label: "PR-42", armed: true, groups: [group], members: [first, second])
        var tracker = InteractionTransitionTracker()

        XCTAssertTrue(tracker.update(sets: [set], notifyTransitions: true).isEmpty)

        first.runtimeState = .idle
        set.members = [first, second]
        XCTAssertTrue(tracker.update(sets: [set], notifyTransitions: true).isEmpty)

        second.runtimeState = .idle
        set.members = [first, second]
        let interactions = tracker.update(sets: [set], notifyTransitions: true)
        XCTAssertEqual(interactions.map(\.kind), [.completion])
        XCTAssertEqual(interactions.first?.memberID, second.id)
    }

    func testTrackerEmitsPersistentInputForRequiredWaitingMember() {
        var member = WorkMember(
            label: "Remote Claude",
            role: .reviewer,
            agent: "claude",
            surfaceID: "surface-1",
            runtimeState: .running,
            isRemote: true
        )
        let group = WorkGroup(label: "Reviewer", role: .reviewer, memberIDs: [member.id])
        var set = WorkSet(label: "PR-42", armed: true, groups: [group], members: [member])
        var tracker = InteractionTransitionTracker()
        _ = tracker.update(sets: [set], notifyTransitions: false)

        member.runtimeState = .waiting
        set.members = [member]
        let interactions = tracker.update(sets: [set], notifyTransitions: true)

        XCTAssertEqual(interactions.map(\.kind), [.inputRequired])
        XCTAssertEqual(interactions.first?.replyCapability, .openTerminalOnly)
        XCTAssertEqual(interactions.first?.surfaceID, "surface-1")
        XCTAssertEqual(interactions.first?.isRemote, true)
    }

    func testTrackerSuppressesUnarmedAndOptionalWaitingMembers() {
        var required = WorkMember(label: "Required", role: .worker, runtimeState: .running)
        var optional = WorkMember(label: "Optional", role: .reviewer, runtimeState: .running)
        let setID = UUID()
        let groups = [
            WorkGroup(label: "Worker", role: .worker, required: true, memberIDs: [required.id]),
            WorkGroup(label: "Reviewer", role: .reviewer, required: false, memberIDs: [optional.id])
        ]
        var set = WorkSet(id: setID, label: "Quiet", armed: false, groups: groups, members: [required, optional])
        var tracker = InteractionTransitionTracker()
        _ = tracker.update(sets: [set], notifyTransitions: false)

        required.runtimeState = .waiting
        optional.runtimeState = .waiting
        set.members = [required, optional]
        XCTAssertTrue(tracker.update(sets: [set], notifyTransitions: true).isEmpty)

        required.runtimeState = .running
        optional.runtimeState = .running
        set.armed = true
        set.members = [required, optional]
        _ = tracker.update(sets: [set], notifyTransitions: false)
        optional.runtimeState = .waiting
        set.members = [required, optional]
        XCTAssertTrue(tracker.update(sets: [set], notifyTransitions: true).isEmpty)
    }

    func testQueuePrioritizesInputThenCompletionThenGeneralAttention() {
        let setID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let attention = makeInteraction(
            id: "attention",
            kind: .attention,
            setID: setID,
            createdAt: base
        )
        let completion = makeInteraction(
            id: "completion",
            kind: .completion,
            setID: setID,
            createdAt: base.addingTimeInterval(1)
        )
        var input = makeInteraction(
            id: "input",
            kind: .inputRequired,
            setID: setID,
            createdAt: base.addingTimeInterval(2)
        )
        var queue = PendingInteractionQueue()

        queue.enqueue(attention)
        queue.enqueue(completion)
        queue.enqueue(input)
        XCTAssertEqual(queue.orderedItems.map(\.id), ["input", "completion", "attention"])

        input.detail = "updated"
        queue.enqueue(input)
        XCTAssertEqual(queue.items.count, 3)
        XCTAssertEqual(queue.current?.detail, "updated")

        XCTAssertEqual(queue.remove(id: "input")?.id, "input")
        XCTAssertEqual(queue.current?.id, "completion")
    }

    func testQueueKeepsHighestPriorityItemsWhenBounded() {
        let setID = UUID()
        var queue = PendingInteractionQueue(maximumCount: 2)
        queue.enqueue(makeInteraction(id: "attention", kind: .attention, setID: setID))
        queue.enqueue(makeInteraction(id: "completion", kind: .completion, setID: setID))
        queue.enqueue(makeInteraction(id: "input", kind: .inputRequired, setID: setID))

        XCTAssertEqual(queue.orderedItems.map(\.id), ["input", "completion"])
    }

    private func makeInteraction(
        id: String,
        kind: PendingInteractionKind,
        setID: UUID,
        createdAt: Date = Date()
    ) -> PendingInteraction {
        PendingInteraction(
            id: id,
            kind: kind,
            setID: setID,
            setTitle: "Set",
            detail: "detail",
            createdAt: createdAt
        )
    }
}
