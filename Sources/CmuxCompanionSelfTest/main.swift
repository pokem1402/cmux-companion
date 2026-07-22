import Foundation
import CmuxCompanionCore

private enum SelfTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SelfTestFailure.assertion(message) }
}

private func testEvaluator() throws {
    let worker = WorkMember(label: "main", role: .worker, runtimeState: .running)
    let reviewer = WorkMember(label: "review", role: .reviewer, runtimeState: .idle)
    var set = WorkSet(
        label: "PR-142",
        armed: true,
        groups: [
            WorkGroup(label: "Workers", role: .worker, policy: .all, memberIDs: [worker.id]),
            WorkGroup(label: "Reviewers", role: .reviewer, policy: .all, memberIDs: [reviewer.id])
        ],
        members: [worker, reviewer]
    )

    var evaluation = SetEvaluator.evaluate(set)
    try require(evaluation.status == .incomplete, "idle required reviewer must make an armed set incomplete")
    try require(evaluation.shouldNotify, "incomplete armed set must notify")

    set.members[1].runtimeState = .waiting
    evaluation = SetEvaluator.evaluate(set)
    try require(evaluation.status == .attention, "waiting must outrank an incomplete group")

    set.snoozedUntil = Date().addingTimeInterval(120)
    try require(!SetEvaluator.evaluate(set).shouldNotify, "snooze must suppress notifications")

    let optionalReviewer = WorkMember(label: "optional", role: .reviewer, runtimeState: .waiting)
    let optionalSet = WorkSet(
        label: "Optional review",
        armed: true,
        groups: [
            WorkGroup(label: "Workers", role: .worker, memberIDs: [worker.id]),
            WorkGroup(
                label: "Optional reviewers",
                role: .reviewer,
                required: false,
                memberIDs: [optionalReviewer.id]
            )
        ],
        members: [worker, optionalReviewer]
    )
    let optionalEvaluation = SetEvaluator.evaluate(optionalSet)
    try require(optionalEvaluation.status == .active, "optional waiting group must not escalate the set")
    try require(optionalEvaluation.attentionMemberIDs.isEmpty, "optional members must not enter alert attention")
    try require(!optionalEvaluation.shouldNotify, "optional waiting group must not notify")

    set.completeCurrentGeneration()
    evaluation = SetEvaluator.evaluate(set)
    try require(evaluation.isGenerationCompleted, "explicit completion must complete the generation")
    try require(!evaluation.shouldNotify, "completed generation must not notify")
}

private func testStoreInboxAndReducer(root: URL) throws {
    let storeURL = root.appendingPathComponent("sets.json")
    let inboxURL = root.appendingPathComponent("commands", isDirectory: true)
    let store = CompanionStore(url: storeURL)
    let inbox = CommandInbox(directoryURL: inboxURL)
    let context = CmuxContext(windowID: "window-1", workspaceID: "workspace-1", surfaceID: "surface-1")

    let join = InboxCommand(
        kind: .join,
        setName: "PR-142",
        role: .worker,
        label: "main",
        agent: "codex",
        session: "session-1",
        cmuxContext: context,
        source: CommandSource(executable: "selftest")
    )
    _ = try inbox.enqueue(join)
    let drained = try inbox.drain()
    try require(drained.count == 1, "inbox must drain one command")
    try require(drained[0].id == join.id, "inbox must preserve command identity")
    try require(drained[0].setName == join.setName && drained[0].role == join.role, "inbox must preserve command fields")
    let remaining = try inbox.peek()
    try require(remaining.isEmpty, "drain must remove processed files")

    var snapshot = CompanionSnapshot()
    let result = try CommandReducer.apply(join, to: &snapshot)
    try require(result.joinedMemberID != nil, "join reducer must create a member")
    try require(snapshot.sets.first?.members.first?.surfaceID == "surface-1", "join must retain surface identity")

    let originalGroupID = snapshot.sets[0].groups[0].id
    snapshot.sets[0].groups[0].policy = .minActive(1)
    snapshot.sets[0].groups[0].required = false
    let rejoin = InboxCommand(
        kind: .join,
        setName: "PR-142",
        role: .worker,
        label: "main renamed",
        agent: "codex",
        session: "session-1",
        cmuxContext: context,
        source: CommandSource(executable: "selftest")
    )
    _ = try CommandReducer.apply(rejoin, to: &snapshot)
    try require(snapshot.sets[0].groups[0].id == originalGroupID, "same-role rejoin must preserve the group")
    try require(snapshot.sets[0].groups[0].policy == .minActive(1), "same-role rejoin must preserve policy")
    try require(!snapshot.sets[0].groups[0].required, "unspecified required must preserve the group setting")

    let requireGroup = InboxCommand(
        kind: .join,
        setName: "PR-142",
        role: .worker,
        session: "session-1",
        required: true,
        cmuxContext: context,
        source: CommandSource(executable: "selftest")
    )
    _ = try CommandReducer.apply(requireGroup, to: &snapshot)
    try require(snapshot.sets[0].groups[0].required, "explicit required true must update an existing group")

    let makeOptional = InboxCommand(
        kind: .join,
        setName: "PR-142",
        role: .worker,
        session: "session-1",
        required: false,
        cmuxContext: context,
        source: CommandSource(executable: "selftest")
    )
    _ = try CommandReducer.apply(makeOptional, to: &snapshot)
    try require(!snapshot.sets[0].groups[0].required, "explicit required false must update an existing group")
    try require(snapshot.sets[0].groups[0].policy == .minActive(1), "required updates must not reset policy")

    let movingReviewer = WorkMember(
        label: "moving",
        role: .reviewer,
        sessionID: "moving-session",
        surfaceID: "moving-surface"
    )
    let anchorWorker = WorkMember(label: "anchor", role: .worker, surfaceID: "anchor-surface")
    let sourceGroup = WorkGroup(
        label: "Reviewers",
        role: .reviewer,
        memberIDs: [movingReviewer.id]
    )
    let destinationGroup = WorkGroup(
        label: "Workers",
        role: .worker,
        required: false,
        policy: .minActive(1),
        memberIDs: [anchorWorker.id]
    )
    var movingSnapshot = CompanionSnapshot(
        sets: [
            WorkSet(
                label: "Role move",
                groups: [sourceGroup, destinationGroup],
                members: [movingReviewer, anchorWorker]
            )
        ]
    )
    _ = try CommandReducer.apply(
        InboxCommand(
            kind: .join,
            setName: "Role move",
            role: .worker,
            session: "moving-session",
            cmuxContext: CmuxContext(surfaceID: "moving-surface"),
            source: CommandSource(executable: "selftest")
        ),
        to: &movingSnapshot
    )
    try require(
        movingSnapshot.sets[0].groups.contains(where: { $0.id == sourceGroup.id }) == false,
        "role change must remove the member from its previous empty group"
    )
    guard let preservedDestination = movingSnapshot.sets[0].groups.first(where: { $0.id == destinationGroup.id }) else {
        throw SelfTestFailure.assertion("role change must retain the destination group")
    }
    try require(preservedDestination.policy == .minActive(1), "role change must preserve destination policy")
    try require(!preservedDestination.required, "unspecified required must preserve destination setting")
    try require(
        Set(preservedDestination.memberIDs) == Set([anchorWorker.id, movingReviewer.id]),
        "role change must add the member to the destination group"
    )

    let input = InboxCommand(
        kind: .lastInput,
        text: "git status",
        cmuxContext: context,
        source: CommandSource(executable: "selftest")
    )
    _ = try CommandReducer.apply(input, to: &snapshot)
    try require(snapshot.sets[0].members[0].lastSubmittedText == "git status", "lastInput must update the member")

    let heartbeat = InboxCommand(
        kind: .heartbeat,
        setName: "PR-142",
        agent: "codex",
        session: "cmux-remote:surface-1:session-1",
        state: "running",
        remote: true,
        cmuxContext: context,
        source: CommandSource(executable: "remote-selftest")
    )
    _ = try CommandReducer.apply(heartbeat, to: &snapshot)
    try require(snapshot.sets[0].members[0].runtimeState == .running, "heartbeat must update lifecycle")
    try require(snapshot.sets[0].members[0].isRemote, "heartbeat must mark a remote member")
    try require(snapshot.sets[0].members[0].lastHeartbeatAt != nil, "heartbeat timestamp must be retained")

    try store.save(snapshot)
    let restored = try store.load()
    try require(restored.sets.count == 1, "store must restore the set")
    try require(restored.sets[0].members[0].lastSubmittedText == "git status", "store must retain prompt text")
    try require(restored.sets[0].members[0].runtimeState == .running, "store must retain lifecycle")
    try require(restored.sets[0].members[0].isRemote, "store must retain remote identity")
    let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    try require(permissions == 0o600, "sets.json must use owner-only permissions")

    let legacyURL = root.appendingPathComponent("legacy-sets.json")
    let legacyJSON = """
    {"schemaVersion":1,"sets":[{"id":"00000000-0000-0000-0000-000000000010","label":"Legacy","color":"#0A84FF","armed":false,"generation":1,"groups":[],"members":[{"id":"00000000-0000-0000-0000-000000000011","label":"Remote","role":"worker","runtimeState":"idle","isRemote":true}],"attachments":[]}]}
    """
    try Data(legacyJSON.utf8).write(to: legacyURL)
    let legacy = try CompanionStore(url: legacyURL).load()
    try require(legacy.sets[0].members[0].lastRemoteBootID == nil, "legacy stores must decode without remote boot metadata")
    try require(legacy.sets[0].members[0].lastRemoteSequence == nil, "legacy stores must decode without remote sequence metadata")
    try require(legacy.sets[0].members[0].localOwnershipSince == nil, "legacy stores must decode without local ownership metadata")
}

private func testCrossSetOwnership() throws {
    let submittedAt = Date(timeIntervalSince1970: 2_100)
    let moving = WorkMember(
        label: "remote worker",
        role: .worker,
        sessionID: "stable-session",
        surfaceID: "old-surface",
        runtimeState: .waiting,
        lastSubmittedText: "review the patch",
        lastSubmittedAt: submittedAt,
        lastRemoteBootID: "boot-1",
        lastRemoteSequence: 7,
        isRemote: true
    )
    let sourceGroup = WorkGroup(label: "Workers", role: .worker, memberIDs: [moving.id])
    let source = WorkSet(label: "Source", groups: [sourceGroup], members: [moving])
    let destination = WorkSet(label: "Destination")
    var snapshot = CompanionSnapshot(sets: [source, destination])

    let result = try CommandReducer.apply(
        InboxCommand(
            kind: .join,
            setName: "Destination",
            role: .reviewer,
            session: "stable-session",
            cmuxContext: CmuxContext(workspaceID: "new-workspace", surfaceID: "new-surface"),
            source: CommandSource(executable: "selftest")
        ),
        to: &snapshot
    )

    try require(snapshot.sets[0].members.isEmpty, "cross-set join must remove the source member")
    try require(snapshot.sets[0].groups.isEmpty, "cross-set join must remove an empty source group")
    try require(snapshot.sets[1].members.count == 1, "cross-set join must create one destination member")
    let moved = snapshot.sets[1].members[0]
    try require(moved.id == moving.id, "cross-set join must preserve member identity")
    try require(moved.role == .reviewer, "cross-set join must apply the destination role")
    try require(moved.surfaceID == "new-surface", "cross-set join must update the surface")
    try require(moved.lastSubmittedText == moving.lastSubmittedText, "cross-set join must preserve the prompt")
    try require(moved.lastRemoteSequence == 7 && moved.isRemote, "cross-set join must preserve remote metadata")
    try require(result.changedSetIDs == [source.id, destination.id], "cross-set join must report source and destination")

    let beforeRejectedPR = snapshot
    do {
        _ = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "Invalid PR",
                role: .pr,
                session: "stable-session",
                source: CommandSource(executable: "selftest")
            ),
            to: &snapshot
        )
        throw SelfTestFailure.assertion("a session-only PR join must be rejected")
    } catch CommandApplyError.missingMemberIdentity {
        // Expected. In particular, no member may be displaced before rejection.
    }
    try require(snapshot == beforeRejectedPR, "a rejected PR join must not mutate any set")
}

private func testTargetSplitIdentity() throws {
    let oldDate = Date(timeIntervalSince1970: 100)
    let newDate = Date(timeIntervalSince1970: 200)
    let surfaceMember = WorkMember(
        label: "surface owner",
        role: .worker,
        sessionID: "old-session",
        surfaceID: "shared-surface",
        runtimeState: .unknown,
        lastSubmittedText: "old prompt",
        lastSubmittedAt: oldDate,
        lastHeartbeatAt: oldDate,
        lastRemoteBootID: "old-boot",
        lastRemoteSequence: 1
    )
    let sessionMember = WorkMember(
        label: "session duplicate",
        role: .reviewer,
        sessionID: "shared-session",
        surfaceID: "old-surface",
        runtimeState: .waiting,
        lastSubmittedText: "new prompt",
        lastSubmittedAt: newDate,
        lastHeartbeatAt: newDate,
        lastRemoteBootID: "new-boot",
        lastRemoteSequence: 7,
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
            cmuxContext: CmuxContext(surfaceID: "shared-surface"),
            source: CommandSource(executable: "selftest")
        ),
        to: &snapshot
    )
    try require(snapshot.sets[0].members.count == 1, "split identity join must retain one member")
    let merged = snapshot.sets[0].members[0]
    try require(merged.id == surfaceMember.id, "surface match must be canonical")
    try require(merged.sessionID == "shared-session", "canonical member must receive the joined session")
    try require(merged.runtimeState == .waiting, "newer duplicate lifecycle must be retained")
    try require(merged.lastSubmittedText == "new prompt", "newer duplicate prompt must be retained")
    try require(
        merged.lastRemoteBootID == "new-boot" && merged.lastRemoteSequence == 7 && merged.isRemote,
        "newer duplicate remote metadata must be retained"
    )
    guard snapshot.sets[0].groups.count == 1,
          let preservedReviewerGroup = snapshot.sets[0].groups.first else {
        throw SelfTestFailure.assertion("split role change must retain one destination group")
    }
    try require(
        preservedReviewerGroup.id == duplicateGroup.id
            && preservedReviewerGroup.label == "Custom review quorum"
            && preservedReviewerGroup.role == .reviewer
            && !preservedReviewerGroup.required
            && preservedReviewerGroup.policy == .minActive(1)
            && preservedReviewerGroup.memberIDs == [surfaceMember.id],
        "split role change must transfer canonical identity into the custom destination policy"
    )
    try require(
        !snapshot.sets[0].groups.contains { $0.id == canonicalGroup.id },
        "split role change must remove the canonical member's old empty group"
    )
    try require(joinResult.joinedMemberID == surfaceMember.id, "join result must report the canonical member")

    let heartbeatDate = Date(timeIntervalSince1970: 300)
    let heartbeatResult = try CommandReducer.apply(
        InboxCommand(
            kind: .heartbeat,
            createdAt: heartbeatDate,
            setName: "Split",
            session: "shared-session",
            state: "running",
            remote: true,
            cmuxContext: CmuxContext(surfaceID: "shared-surface"),
            source: CommandSource(executable: "selftest")
        ),
        to: &snapshot
    )
    try require(
        snapshot.sets[0].members.count == 1
            && snapshot.sets[0].members[0].lastHeartbeatAt == heartbeatDate
            && heartbeatResult.changedSetIDs == [workSet.id],
        "heartbeat must update only the merged member"
    )

    let inputResult = try CommandReducer.apply(
        InboxCommand(
            kind: .lastInput,
            session: "shared-session",
            text: "single input",
            source: CommandSource(executable: "selftest")
        ),
        to: &snapshot
    )
    try require(
        snapshot.sets[0].members.count == 1
            && snapshot.sets[0].members[0].lastSubmittedText == "single input"
            && inputResult.changedSetIDs == [workSet.id],
        "last input must update only the merged member"
    )

    let leaveResult = try CommandReducer.apply(
        InboxCommand(
            kind: .leave,
            setName: "Split",
            session: "shared-session",
            cmuxContext: CmuxContext(surfaceID: "shared-surface"),
            source: CommandSource(executable: "selftest")
        ),
        to: &snapshot
    )
    try require(
        snapshot.sets[0].members.isEmpty
            && snapshot.sets[0].groups.isEmpty
            && leaveResult.changedSetIDs == [workSet.id],
        "leave must remove the one merged member and its group"
    )

    let prSurfaceMember = WorkMember(
        label: "surface worker",
        role: .worker,
        sessionID: "surface-session",
        surfaceID: "pr-surface"
    )
    let prSessionMember = WorkMember(
        label: "session reviewer",
        role: .reviewer,
        sessionID: "pr-session",
        surfaceID: "other-surface"
    )
    var prSnapshot = CompanionSnapshot(sets: [
        WorkSet(
            label: "PR split",
            groups: [
                WorkGroup(label: "Workers", memberIDs: [prSurfaceMember.id]),
                WorkGroup(label: "Reviewers", memberIDs: [prSessionMember.id])
            ],
            members: [prSurfaceMember, prSessionMember]
        )
    ])
    _ = try CommandReducer.apply(
        InboxCommand(
            kind: .join,
            setName: "PR split",
            role: .pr,
            session: "pr-session",
            cmuxContext: CmuxContext(surfaceID: "pr-surface"),
            source: CommandSource(executable: "selftest")
        ),
        to: &prSnapshot
    )
    try require(
        prSnapshot.sets[0].members.isEmpty
            && prSnapshot.sets[0].groups.isEmpty
            && prSnapshot.sets[0].attachments.count == 1,
        "PR join must remove every surface/session match and group reference"
    )
}

private func testTransportNormalization() throws {
    let workspaceID = "84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A"
    let surfaceID = "4202F9A9-C905-41D4-B126-6F8179F51783"
    let treeJSON = #"{"windows":[{"id":"00000000-0000-0000-0000-000000000001","ref":"window:1","workspaces":[{"id":"84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A","ref":"workspace:1","title":"Build","panes":[{"id":"00000000-0000-0000-0000-000000000002","ref":"pane:1","surfaces":[{"id":"4202F9A9-C905-41D4-B126-6F8179F51783","ref":"surface:1","type":"terminal","title":"Codex"},{"id":"00000000-0000-0000-0000-000000000003","ref":"surface:2","type":"browser","url":"https://github.com/acme/repo/pull/1"}]}]}]}]}"#
    let tree = CmuxTreeSnapshot(raw: try CmuxJSON.decode(treeJSON))
    try require(tree.windows.count == 1, "tree decoder must retain windows")
    try require(tree.windows[0].workspaces[0].surfaces.count == 2, "tree decoder must flatten pane surfaces")
    try require(tree.windows[0].workspaces[0].surfaces[1].url?.contains("pull/1") == true, "browser URL must survive normalization")
    try require(tree.windows[0].workspaces[0].id == workspaceID, "tree must prefer the durable workspace UUID")
    try require(tree.windows[0].workspaces[0].surfaces[0].id == surfaceID, "tree must prefer the durable surface UUID")
    try require(
        CmuxSnapshotLoader.treeArguments == ["--id-format", "uuids", "tree", "--all", "--json"],
        "tree command must request UUID output before the subcommand"
    )
    try require(
        CmuxSnapshotLoader.topArguments == [
            "--id-format", "uuids", "top", "--all", "--processes", "--flat", "--format", "tsv",
        ],
        "top command must request UUID process output"
    )

    let topTSV = [
        "0.0\t20\t2\tsurface\tsurface-codex\tpane-1\tCodex",
        "0.0\t10\t1\tprocess\t41\tsurface-codex\tzsh",
        "0.1\t100\t1\tprocess\t42\tsurface-codex\tcodex",
        "0.0\t20\t1\tsurface\tsurface-shell\tpane-1\tShell",
        "0.0\t20\t1\tprocess\t43\tsurface-shell\t/bin/bash",
    ].joined(separator: "\n")
    let top = try CmuxTopSnapshot(tsv: topTSV)
    try require(
        top.workload(forSurfaceID: "surface-codex") == .codex,
        "live Codex processes must classify their surface"
    )
    try require(
        top.agentWorkload(forProcessID: 42, onSurfaceID: "surface-codex") == .codex,
        "exact Codex PID evidence must remain surface-scoped"
    )
    try require(
        top.workload(forSurfaceID: "surface-shell") == .shell,
        "shell-only process surfaces must classify as Shell"
    )

    let sshTSV = [
        "0.0\t20\t2\tsurface\tremote-claude\tpane-1\tRemote",
        "0.0\t10\t1\tprocess\t51\tremote-claude\tzsh",
        "0.0\t10\t1\tprocess\t52\t51\tssh",
        "0.0\t20\t2\tsurface\tremote-codex\tpane-1\tRemote",
        "0.0\t10\t1\tprocess\t61\tremote-codex\tzsh",
        "0.0\t10\t1\tprocess\t62\t61\tssh",
    ].joined(separator: "\n")
    let sshTop = try CmuxTopSnapshot(tsv: sshTSV).addingRemoteScreenEvidence([
        "remote-claude": "Do you want to proceed?\nPress enter to confirm or esc to cancel\nshift+tab to cycle",
        "remote-codex": "◦ Working (12s • esc to interrupt)\ngpt-5.6-sol xhigh · ~/remote/project",
    ])
    try require(
        sshTop.workload(forSurfaceID: "remote-claude") == .claude
            && sshTop.workload(forSurfaceID: "remote-codex") == .codex,
        "SSH surfaces must classify from conservative remote terminal UI evidence"
    )
    try require(
        sshTop.runtimeState(forSurfaceID: "remote-claude") == .waiting
            && sshTop.runtimeState(forSurfaceID: "remote-codex") == .running,
        "SSH terminal controls must provide conservative remote runtime evidence"
    )
    try require(
        CmuxSnapshotLoader.remoteScreenArguments(surfaceID: "remote-codex") == [
            "read-screen", "--surface", "remote-codex", "--lines", "16",
        ],
        "remote screen probes must stay surface-scoped and bounded"
    )

    let inactivePromptSessions = CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"""
    {"sessions":[
      {"session_id":"prompt-session","surface_id":"surface-codex","pid":42,
       "agent":"codex","agent_lifecycle":"idle","active_for_surface":false}
    ]}
    """#)).sessions
    let displaySources = CmuxAgentSessionResolver.promptDisplaySourcesBySurface(
        inactivePromptSessions,
        corroboratedBy: top
    )
    try require(
        displaySources["surface-codex"]?.sessionID == "prompt-session"
            && CmuxAgentSessionResolver.currentBySurface(inactivePromptSessions).isEmpty,
        "exact live PID evidence may restore prompt display but not session ownership"
    )

    let sessionsJSON = #"{"sessions":[{"agent":"codex","session_id":"session-1","workspace_id":"ws1","surface_id":"s1","agent_lifecycle":"running","updated_at_unix":100}]}"#
    let sessions = CmuxSessionsSnapshot(raw: try CmuxJSON.decode(sessionsJSON))
    try require(sessions.sessions.first?.effectiveLifecycle == "running", "session lifecycle must normalize")

    let feedJSON = #"{"items":[{"id":"i1","workstream_id":"codex-session-1","source":"codex","kind":"userPrompt","text":"review this","created_at":"2026-07-18T00:00:00Z"}]}"#
    let feed = CmuxFeedSnapshot(raw: try CmuxJSON.decode(feedJSON))
    try require(feed.items.first?.text == "review this", "feed prompt text must normalize")

    let eventLine = #"{"type":"event","boot_id":"boot","seq":42,"name":"agent.hook.Stop","category":"agent","payload":{"session_id":"session-1","text":null,"text_length":9,"redacted_fields":["text"]}}"#
    let event = try CmuxEventFrame.decode(line: eventLine)
    try require(event.sequence == 42, "event sequence must decode")
    try require(event.isContentRedacted, "redacted event payload must be detected")
}

private func testSurfaceWorkloadAndSessionResolution() throws {
    try require(SurfaceWorkload(agent: "codex") == .codex, "Codex agent must classify")
    try require(SurfaceWorkload(agent: "Claude Code") == .claude, "Claude agent must classify")
    try require(
        SurfaceWorkload(agent: nil, shellIsAuthoritative: true) == .shell,
        "an authoritative agent-free terminal must classify as Shell"
    )
    try require(
        SurfaceWorkload(agent: nil, shellIsAuthoritative: false) == .unknown,
        "a failed sessions lookup must not guess Shell"
    )
    try require(
        SurfaceWorkload(agent: "custom-agent") == .otherAgent("custom-agent"),
        "unknown agent names must remain visible"
    )

    try require(
        SurfaceWorkload.resolved(
            currentSession: nil,
            processWorkload: .codex,
            hasFreshProcessSnapshot: true,
            occupancyIsAuthoritative: true
        ) == .codex,
        "a fresh live process must classify a hookless Codex surface"
    )
    try require(
        SurfaceWorkload.resolved(
            currentSession: nil,
            processWorkload: nil,
            hasFreshProcessSnapshot: true,
            occupancyIsAuthoritative: true
        ) == .unknown,
        "a fresh but inconclusive process scan must not guess Shell"
    )

    let raw = try CmuxJSON.decode(#"""
    {"sessions":[
      {"session_id":"old-codex","surface_id":"surface-1","agent":"codex",
       "agent_lifecycle":"running","active_for_surface":false,"updated_at_unix":30},
      {"session_id":"current-claude","surface_id":"surface-1","agent":"claude",
       "agent_lifecycle":"needsInput","active_for_surface":true,"updated_at_unix":20},
      {"session_id":"legacy-codex","surface_id":"surface-2","agent":"codex",
       "agent_lifecycle":"running","updated_at_unix":10},
      {"session_id":"legacy-ended","surface_id":"surface-3","agent":"claude",
       "agent_lifecycle":"ended","updated_at_unix":40},
      {"session_id":"current-unknown","surface_id":"surface-4",
       "agent_lifecycle":"running","active_for_surface":true,"updated_at_unix":50},
      {"session_id":"display-name-only","surface_id":"surface-5",
       "agent_display_name":"Claude Code","agent_lifecycle":"running",
       "active_for_surface":true,"updated_at_unix":60}
    ]}
    """#)
    let sessions = CmuxSessionsSnapshot(raw: raw).sessions
    let current = CmuxAgentSessionResolver.currentBySurface(sessions)
    try require(
        sessions.first { $0.id == "old-codex" }?.isCurrentForSurface == false,
        "explicit inactive sessions must be historical even when lifecycle says running"
    )
    try require(
        current["surface-1"]?.id == "current-claude",
        "explicit inactive history must not override the current agent"
    )
    try require(
        current["surface-2"]?.id == "legacy-codex",
        "legacy active sessions must remain compatible"
    )
    try require(
        current["surface-3"] == nil,
        "legacy ended sessions must return the surface to Shell"
    )
    try require(
        SurfaceWorkload(
            currentSession: current["surface-4"],
            occupancyIsAuthoritative: true
        ) == .unknown,
        "a current unnamed session must remain Unknown rather than becoming Shell"
    )
    try require(
        SurfaceWorkload(
            currentSession: current["surface-5"],
            occupancyIsAuthoritative: true
        ) == .claude,
        "an agent display name must classify when the machine name is absent"
    )
}

private func testNavigationLinks() throws {
    let workspaceID = "84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A"
    let surfaceID = "4202F9A9-C905-41D4-B126-6F8179F51783"

    try require(
        CmuxNavigationLink.workspace(workspaceID)?.absoluteString
            == "cmux://workspace/\(workspaceID)",
        "workspace deep link must match cmux's registered route"
    )
    try require(
        CmuxNavigationLink.workspace(workspaceID, surfaceID: surfaceID)?.absoluteString
            == "cmux://workspace/\(workspaceID)/surface/\(surfaceID)",
        "surface deep link must retain workspace ownership"
    )
    try require(
        CmuxNavigationLink.workspace("workspace:1") == nil,
        "non-durable refs must not be emitted as navigation URLs"
    )
}

private func testGUIProcessEnvironment(root: URL) throws {
    let home = root.appendingPathComponent("gui-home", isDirectory: true)
    let nvmV20 = home.appendingPathComponent(
        ".nvm/versions/node/v20.19.0/bin",
        isDirectory: true
    )
    let nvmV24 = home.appendingPathComponent(
        ".nvm/versions/node/v24.15.0/bin",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: nvmV20, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nvmV24, withIntermediateDirectories: true)

    let candidates = CmuxProcessEnvironment.supplementalPathDirectories(
        homeDirectory: home
    )
    try require(
        candidates.contains(home.appendingPathComponent(".local/bin").path),
        "GUI PATH must include ~/.local/bin"
    )
    try require(candidates.contains(nvmV20.path), "GUI PATH must discover installed NVM bins")
    try require(candidates.contains(nvmV24.path), "GUI PATH must include every installed NVM bin")
    try require(
        candidates.firstIndex(of: nvmV24.path)! < candidates.firstIndex(of: nvmV20.path)!,
        "newer NVM versions must be searched before older fallback versions"
    )
    try require(
        candidates.contains(home.appendingPathComponent(".volta/bin").path),
        "GUI PATH must include ~/.volta/bin"
    )
    try require(
        candidates.contains(home.appendingPathComponent(".cargo/bin").path),
        "GUI PATH must include ~/.cargo/bin"
    )
    try require(candidates.contains("/opt/homebrew/bin"), "GUI PATH must include Homebrew")
    try require(candidates.contains("/usr/local/bin"), "GUI PATH must include /usr/local/bin")

    let inherited = "/custom/bin:/usr/local/bin::/usr/bin"
    let environment = CmuxProcessEnvironment.augmented(
        ["PATH": inherited, "UNCHANGED": "yes"],
        homeDirectory: home
    )
    let entries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    try require(entries.first == "/custom/bin", "GUI PATH must preserve inherited precedence")
    try require(
        entries.filter { $0 == "/usr/local/bin" }.count == 1,
        "GUI PATH must deduplicate inherited and supplemental entries"
    )
    try require(!entries.contains(""), "GUI PATH must drop empty current-directory entries")
    try require(environment["UNCHANGED"] == "yes", "environment augmentation must preserve other keys")

    let installed = CmuxHooksSetupSummary(
        stdout: "Done: 2 installed, 3 skipped\n",
        stderr: ""
    )
    try require(installed.installedAny == true, "hook summary must recognize installed agents")
    let skipped = CmuxHooksSetupSummary(
        stdout: "Done: 0 installed, 5 skipped\n",
        stderr: ""
    )
    try require(skipped.installedAny == false, "hook summary must reject all-skipped false success")
    let unrecognized = CmuxHooksSetupSummary(
        stdout: "hooks command completed without a count",
        stderr: ""
    )
    try require(
        unrecognized.installedAny == nil,
        "unrecognized hook output must never be treated as confirmed success"
    )
}

private func testRemoteEventIdentity() throws {
    let payload = try CmuxJSON.decode(#"{"tool_name":"cmux-companion-remote-event:PermissionRequest","_opencode_request_id":"cmux-companion-seq:boot-1:42:event"}"#)
    let identity = CmuxRemoteEventIdentity(
        sessionID: "cmux-remote:v2:surface%3A1:native-session",
        payload: payload
    )
    try require(identity?.surfaceID == "surface:1", "remote session must expose its cmux surface")
    try require(identity?.originalHookName == "PermissionRequest", "remote carrier must restore original hook")
    try require(identity?.order == CmuxRemoteEventOrder(bootID: "boot-1", sequence: 42), "remote sequence must decode")
    try require(
        CmuxRemoteEventIdentity(sessionID: "local-session", payload: payload) == nil,
        "local agent events must never be treated as remote"
    )
    try require(
        CmuxRemoteEventIdentity(sessionID: "cmux-remote:v2:", payload: payload) == nil
            && CmuxRemoteEventIdentity(
                sessionID: "cmux-remote:v2:surface%3A1",
                payload: payload
            ) == nil,
        "malformed v2 remote sessions must never fall back to legacy parsing"
    )
}

private func testRemoteHeartbeatPreservesLifecycle() throws {
    try require(
        CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .waiting) == .waiting,
        "heartbeat must preserve a waiting state"
    )
    try require(
        CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .idle) == .idle,
        "heartbeat must preserve an idle state"
    )
    try require(
        CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .stale) == .unknown,
        "fresh heartbeat must clear a persisted stale overlay"
    )
    try require(
        CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .disconnected) == .unknown,
        "fresh heartbeat must clear a persisted disconnected overlay"
    )
    try require(
        CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: nil) == .unknown,
        "a first heartbeat must not invent a running state"
    )
    try require(
        CmuxRemoteLifecycle.state(forHookName: "PermissionRequest", previous: .running) == .waiting,
        "real lifecycle hooks must still update state"
    )
    let leaseSeenAt = Date(timeIntervalSince1970: 1_000)
    try require(
        CmuxRemoteLifecycle.stateApplyingLease(
            .running,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(10 * 60)
        ) == .running,
        "a normal quiet ten-minute remote operation must stay running"
    )
    try require(
        CmuxRemoteLifecycle.stateApplyingLease(
            .running,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(16 * 60)
        ) == .stale,
        "a running remote operation must become stale after the default lease"
    )
    try require(
        CmuxRemoteLifecycle.stateApplyingLease(
            .unknown,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(61 * 60)
        ) == .disconnected,
        "an unknown remote operation must become disconnected after the long lease"
    )
    try require(
        CmuxRemoteLifecycle.stateApplyingLease(
            .stale,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(61 * 60)
        ) == .disconnected,
        "a persisted stale overlay must progress to disconnected after the long lease"
    )
    for explicitState in [
        MemberRuntimeState.waiting,
        .idle,
        .ended,
        .error,
    ] {
        try require(
            CmuxRemoteLifecycle.stateApplyingLease(
                explicitState,
                lastSeenAt: leaseSeenAt,
                now: leaseSeenAt.addingTimeInterval(24 * 60 * 60)
            ) == explicitState,
            "explicit remote lifecycle states must survive transport age"
        )
    }
    let remoteSeenAt = Date(timeIntervalSince1970: 100)
    try require(
        CmuxRemoteLifecycle.shouldYieldToLocalSession(
            isActiveForSurface: true,
            state: .idle,
            updatedAt: nil,
            remoteLastSeenAt: remoteSeenAt
        ),
        "an authoritative active local session must replace a remote binding"
    )
    try require(
        !CmuxRemoteLifecycle.shouldYieldToLocalSession(
            isActiveForSurface: false,
            state: .running,
            updatedAt: Date(timeIntervalSince1970: 90),
            remoteLastSeenAt: remoteSeenAt
        ),
        "an older local record must not displace a newer remote event"
    )
    try require(
        CmuxRemoteLifecycle.shouldYieldToLocalSession(
            isActiveForSurface: false,
            state: .running,
            updatedAt: Date(timeIntervalSince1970: 110),
            remoteLastSeenAt: remoteSeenAt
        ),
        "a newer running local session must replace a stale remote binding"
    )
    let replayReceivedAt = Date(timeIntervalSince1970: 10_000)
    let twentyMinuteOldFrame = replayReceivedAt.addingTimeInterval(-20 * 60)
    let sixtyOneMinuteOldFrame = replayReceivedAt.addingTimeInterval(-61 * 60)
    let futureRemoteClock = replayReceivedAt.addingTimeInterval(24 * 60 * 60)
    let twentyMinuteReplaySeenAt = CmuxRemoteLifecycle.canonicalEventDate(
        frameOccurredAt: twentyMinuteOldFrame,
        localReceivedAt: replayReceivedAt,
        remoteReportedAt: futureRemoteClock
    )
    let sixtyOneMinuteReplaySeenAt = CmuxRemoteLifecycle.canonicalEventDate(
        frameOccurredAt: sixtyOneMinuteOldFrame,
        localReceivedAt: replayReceivedAt,
        remoteReportedAt: futureRemoteClock
    )
    try require(
        twentyMinuteReplaySeenAt == twentyMinuteOldFrame
            && CmuxRemoteLifecycle.stateApplyingLease(
                .running,
                lastSeenAt: twentyMinuteReplaySeenAt,
                now: replayReceivedAt
            ) == .stale,
        "a twenty-minute-old replay must be stale immediately"
    )
    try require(
        sixtyOneMinuteReplaySeenAt == sixtyOneMinuteOldFrame
            && CmuxRemoteLifecycle.stateApplyingLease(
                .running,
                lastSeenAt: sixtyOneMinuteReplaySeenAt,
                now: replayReceivedAt
            ) == .disconnected,
        "a sixty-one-minute-old replay must be disconnected immediately"
    )
    let localReceivedAt = Date(timeIntervalSince1970: 200)
    try require(
        CmuxRemoteLifecycle.canonicalPromptDate(
            frameOccurredAt: nil,
            localReceivedAt: localReceivedAt,
            remoteReportedAt: Date(timeIntervalSince1970: 9_999)
        ) == localReceivedAt,
        "future-skewed remote time must not pin the last prompt timestamp"
    )
    try require(
        !CmuxRemoteLifecycle.shouldAcceptSessionEvent(
            currentSessionID: "session-b",
            incomingSessionID: "session-a",
            hookName: "Stop"
        ),
        "a delayed old-session Stop must not reclaim the surface"
    )
    try require(
        CmuxRemoteLifecycle.shouldAcceptSessionEvent(
            currentSessionID: "session-a",
            incomingSessionID: "session-b",
            hookName: "SessionStart"
        ),
        "a new SessionStart must be allowed to replace the surface binding"
    )
    try require(
        CmuxRemoteLifecycle.isOrderNewer(
            CmuxRemoteEventOrder(bootID: "boot-1", sequence: 9),
            thanBootID: "boot-1",
            sequence: 10
        ) == false,
        "a persisted newer surface sequence must reject a delayed event after restart"
    )
    try require(
        CmuxRemoteLifecycle.isOrderNewer(
            CmuxRemoteEventOrder(bootID: "boot-1", sequence: 11),
            thanBootID: "boot-1",
            sequence: 10
        ) == true,
        "a genuinely newer event must allow a remote session to resume"
    )
    try require(
        !CmuxRemoteLifecycle.isEventNewer(
            incomingOrder: CmuxRemoteEventOrder(bootID: "old-boot", sequence: 99),
            occurredAt: Date(timeIntervalSince1970: 90),
            previousBootID: "new-boot",
            previousSequence: 1,
            previousReceivedAt: Date(timeIntervalSince1970: 100)
        ),
        "a delayed activation from another boot must lose to the Mac event watermark"
    )
    try require(
        !CmuxRemoteLifecycle.isAfterLocalOwnership(
            occurredAt: Date(timeIntervalSince1970: 99),
            localOwnershipSince: Date(timeIntervalSince1970: 100)
        ),
        "a remote activation created before local takeover must not reclaim the surface"
    )
}

private func testFocusSelectionUsesDeficientGroup() throws {
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
    try require(evaluation.status == .incomplete, "idle reviewer must make the set incomplete")
    try require(
        SetEvaluator.preferredFocusMemberID(in: set, evaluation: evaluation) == reviewer.id,
        "focus must jump to the deficient reviewer rather than the running worker"
    )

    var optionalReviewerSet = set
    optionalReviewerSet.groups[1].required = false
    let optionalEvaluation = SetEvaluator.evaluate(optionalReviewerSet)
    try require(optionalEvaluation.status == .active, "optional reviewer must not make the set incomplete")
    try require(
        SetEvaluator.preferredFocusMemberID(
            in: optionalReviewerSet,
            evaluation: optionalEvaluation
        ) == worker.id,
        "optional reviewer attention must not outrank the active worker"
    )
}

private func testExactGroupJoin() throws {
    let moving = WorkMember(
        label: "Claude",
        role: .reviewer,
        sessionID: "exact-group-session",
        surfaceID: "exact-group-surface"
    )
    let anchor = WorkMember(
        label: "Codex",
        role: .reviewer,
        surfaceID: "exact-group-anchor"
    )
    let sourceGroup = WorkGroup(
        label: "Primary reviewers",
        role: .reviewer,
        memberIDs: [moving.id]
    )
    let targetGroup = WorkGroup(
        label: "Optional reviewers",
        role: .reviewer,
        required: false,
        policy: .minActive(1),
        memberIDs: [anchor.id]
    )
    var snapshot = CompanionSnapshot(sets: [
        WorkSet(
            label: "Exact group",
            groups: [sourceGroup, targetGroup],
            members: [moving, anchor]
        )
    ])
    let command = InboxCommand(
        kind: .join,
        setName: "Exact group",
        role: .reviewer,
        groupID: targetGroup.id,
        session: moving.sessionID,
        cmuxContext: CmuxContext(surfaceID: moving.surfaceID),
        source: CommandSource(executable: "drag-selftest")
    )

    let encoded = try JSONEncoder().encode(command)
    let decoded = try JSONDecoder().decode(InboxCommand.self, from: encoded)
    try require(
        decoded.groupID == targetGroup.id,
        "drag target group ID must survive inbox encoding"
    )
    let firstResult = try CommandReducer.apply(command, to: &snapshot)
    try require(firstResult.joinedMemberID == moving.id, "exact-group move must preserve member identity")
    try require(
        snapshot.sets[0].groups.contains(where: { $0.id == sourceGroup.id }) == false,
        "exact-group move must clean an empty source group"
    )
    guard let preservedTarget = snapshot.sets[0].groups.first(where: { $0.id == targetGroup.id }) else {
        throw SelfTestFailure.assertion("exact-group move must retain the requested target group")
    }
    try require(!preservedTarget.required, "exact-group move must preserve target requiredness")
    try require(preservedTarget.policy == .minActive(1), "exact-group move must preserve target policy")
    try require(
        Set(preservedTarget.memberIDs) == Set([moving.id, anchor.id]),
        "exact-group move must place the member only in the requested group"
    )

    _ = try CommandReducer.apply(command, to: &snapshot)
    let repeatedTarget = snapshot.sets[0].groups.first { $0.id == targetGroup.id }
    try require(
        repeatedTarget?.memberIDs.filter { $0 == moving.id }.count == 1,
        "repeating the same drop must be idempotent"
    )

    let beforeInvalidDrop = snapshot
    do {
        _ = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "Exact group",
                role: .reviewer,
                groupID: UUID(),
                session: moving.sessionID,
                cmuxContext: CmuxContext(surfaceID: moving.surfaceID)
            ),
            to: &snapshot
        )
        throw SelfTestFailure.assertion("unknown exact group must be rejected")
    } catch CommandApplyError.groupNotFound {
        // Expected.
    }
    try require(snapshot == beforeInvalidDrop, "rejected exact-group drop must be atomic")

    do {
        _ = try CommandReducer.apply(
            InboxCommand(
                kind: .join,
                setName: "Exact group",
                role: .worker,
                groupID: targetGroup.id,
                session: moving.sessionID,
                cmuxContext: CmuxContext(surfaceID: moving.surfaceID)
            ),
            to: &snapshot
        )
        throw SelfTestFailure.assertion("role-mismatched exact group must be rejected")
    } catch CommandApplyError.groupRoleMismatch {
        // Expected.
    }
    try require(snapshot == beforeInvalidDrop, "role-mismatched drop must be atomic")

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
            cmuxContext: CmuxContext(surfaceID: "shared-surface"),
            source: CommandSource(executable: "drag-selftest")
        ),
        to: &splitSnapshot
    )
    try require(splitResult.joinedMemberID == canonical.id, "exact split drop must keep surface identity")
    try require(splitSnapshot.sets[0].members.map(\.id) == [canonical.id], "exact split drop must merge duplicates")
    try require(
        splitSnapshot.sets[0].groups.count == 1
            && splitSnapshot.sets[0].groups[0].id == exactTarget.id
            && splitSnapshot.sets[0].groups[0].memberIDs == [canonical.id]
            && !splitSnapshot.sets[0].groups[0].required
            && splitSnapshot.sets[0].groups[0].policy == .minActive(1),
        "exact split drop must preserve the explicitly targeted lane and its policy"
    )
}

private func testRenameRejectsDuplicateSetName() throws {
    var snapshot = CompanionSnapshot(sets: [
        WorkSet(label: "Main"),
        WorkSet(label: "Café")
    ])
    do {
        _ = try CommandReducer.apply(
            InboxCommand(kind: .rename, setName: "Main", label: "CAFE"),
            to: &snapshot
        )
        throw SelfTestFailure.assertion("rename must reject an equivalent duplicate set name")
    } catch CommandApplyError.duplicateSetName {
        // Expected.
    }
    try require(snapshot.sets.map(\.label) == ["Main", "Café"], "failed rename must be atomic")
}

private func testTranscriptExtraction(root: URL) throws {
    let codexURL = root.appendingPathComponent("codex.jsonl")
    let codex = [
        #"{"timestamp":"2026-07-18T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"first prompt"}}"#,
        #"{"timestamp":"2026-07-18T00:01:00Z","type":"event_msg","payload":{"type":"user_message","message":"<codex_internal_context>hidden</codex_internal_context>"}}"#,
        #"{"timestamp":"2026-07-18T00:02:00Z","type":"event_msg","payload":{"type":"user_message","message":"latest real prompt"}}"#,
    ].joined(separator: "\n")
    try Data(codex.utf8).write(to: codexURL)
    let codexPrompt = try TranscriptPromptExtractor.latestUserPrompt(at: codexURL)
    try require(codexPrompt?.text == "latest real prompt", "Codex transcript prompt must extract")

    let claudeURL = root.appendingPathComponent("claude.jsonl")
    let claude = #"{"timestamp":"2026-07-18T01:00:00Z","type":"user","message":{"role":"user","content":[{"type":"text","text":"review the patch"}]}}"#
    try Data(claude.utf8).write(to: claudeURL)
    let claudePrompt = try TranscriptPromptExtractor.latestUserPrompt(at: claudeURL)
    try require(claudePrompt?.text == "review the patch", "Claude transcript prompt must extract")
}

private func testAppReleaseSelectionAndArchivePolicy() throws {
    guard let current = AppSemanticVersion("0.1.0"),
          let patchNine = AppSemanticVersion("0.1.9"),
          let patchTen = AppSemanticVersion("0.1.10"),
          let alpha = AppSemanticVersion("1.0.0-alpha"),
          let alphaOne = AppSemanticVersion("1.0.0-alpha.1"),
          let release = AppSemanticVersion("1.0.0") else {
        throw SelfTestFailure.assertion("valid semantic versions must parse")
    }
    try require(patchNine < patchTen, "semantic comparison must compare numeric components")
    try require(alpha < alphaOne && alphaOne < release, "prereleases must sort before releases")
    try require(AppSemanticVersion("01.0.0") == nil, "core versions must reject leading zeroes")
    try require(AppSemanticVersion("1.0.0-01") == nil, "numeric prereleases must reject leading zeroes")

    func makeRelease(
        _ version: String,
        architecture: String = "arm64",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> GitHubAppRelease {
        let archiveName = "CmuxCompanion-v\(version)-macos-\(architecture).zip"
        let base = "https://github.com/pokem1402/cmux-companion/releases/download/v\(version)/"
        return GitHubAppRelease(
            tagName: "v\(version)",
            draft: draft,
            prerelease: prerelease,
            assets: [
                GitHubAppReleaseAsset(
                    name: archiveName,
                    browserDownloadURL: URL(string: base + archiveName)!
                ),
                GitHubAppReleaseAsset(
                    name: archiveName + ".sha256",
                    browserDownloadURL: URL(string: base + archiveName + ".sha256")!
                )
            ]
        )
    }

    let older = makeRelease("0.0.9")
    let equal = makeRelease("0.1.0")
    let stable = makeRelease("0.1.1")
    let preview = makeRelease("0.2.0-beta.1", prerelease: true)
    let draft = makeRelease("9.0.0", draft: true)
    let wrongArchitecture = makeRelease("8.0.0", architecture: "x86_64")

    try require(
        AppReleaseSelector.latest(
            from: [older, equal],
            newerThan: current,
            channel: .preview
        ) == nil,
        "older and equal releases must not be offered"
    )
    try require(
        AppReleaseSelector.latest(
            from: [draft, wrongArchitecture],
            newerThan: current,
            channel: .preview
        ) == nil,
        "drafts and wrong-architecture assets must not be offered"
    )
    try require(
        AppReleaseSelector.latest(
            from: [preview, stable, draft, wrongArchitecture],
            newerThan: current,
            channel: .stable
        )?.version == AppSemanticVersion("0.1.1"),
        "stable channel must ignore prereleases"
    )
    try require(
        AppReleaseSelector.latest(
            from: [stable, preview],
            newerThan: current,
            channel: .preview
        )?.version == AppSemanticVersion("0.2.0-beta.1"),
        "preview channel must select the newest eligible prerelease"
    )

    let digest = String(repeating: "A", count: 64)
    guard let githubChecksum = AppUpdateChecksum(githubDigest: "sha256:\(digest)"),
          let sidecarChecksum = AppUpdateChecksum.parseSidecar(
              "\(digest)  CmuxCompanion-v0.1.1-macos-arm64.zip\n",
              expectedFilename: "CmuxCompanion-v0.1.1-macos-arm64.zip"
          ) else {
        throw SelfTestFailure.assertion("valid GitHub and sidecar checksums must parse")
    }
    try require(githubChecksum == sidecarChecksum, "checksum formats must normalize to one digest")
    try require(
        AppUpdateChecksum.parseSidecar(
            "\(digest)  another.zip\n",
            expectedFilename: "CmuxCompanion-v0.1.1-macos-arm64.zip"
        ) == nil,
        "sidecar filename must match the selected archive"
    )

    let releaseJSON = #"""
    [{
      "tag_name":"v0.1.1","name":"Preview","draft":false,"prerelease":false,
      "published_at":"2026-07-19T01:02:03Z",
      "html_url":"https://github.com/pokem1402/cmux-companion/releases/tag/v0.1.1",
      "assets":[{
        "name":"CmuxCompanion-v0.1.1-macos-arm64.zip",
        "browser_download_url":"https://github.com/pokem1402/cmux-companion/releases/download/v0.1.1/CmuxCompanion-v0.1.1-macos-arm64.zip",
        "content_type":"application/zip","size":1234,"digest":"sha256:\#(digest)"
      }]
    }]
    """#
    let decoded = try JSONDecoder().decode([GitHubAppRelease].self, from: Data(releaseJSON.utf8))
    try require(decoded.first?.semanticVersion == AppSemanticVersion("0.1.1"), "GitHub tag must decode")
    try require(decoded.first?.publishedAt != nil, "GitHub ISO-8601 publication date must decode")
    try require(decoded.first?.assets.first?.size == 1234, "GitHub asset metadata must decode")

    try require(
        AppUpdateArchivePolicy.isSafeEntryPath("CmuxCompanion.app/Contents/MacOS/CmuxCompanion"),
        "normal app bundle entry must be safe"
    )
    try require(
        AppUpdateArchivePolicy.isSafeEntryPath("CmuxCompanion.app/Contents/Resources/"),
        "normal directory entry must be safe"
    )
    for unsafePath in [
        "../escape",
        "CmuxCompanion.app/../../escape",
        "/tmp/escape",
        "C:\\escape",
        "CmuxCompanion.app//Contents",
        "CmuxCompanion.app/Contents\nEscape"
    ] {
        try require(
            !AppUpdateArchivePolicy.isSafeEntryPath(unsafePath),
            "unsafe archive path must be rejected: \(unsafePath)"
        )
    }
    try require(
        !AppUpdateArchivePolicy.allEntriesAreSafe([
            "CmuxCompanion.app/Contents/Info.plist",
            "../escape"
        ]),
        "one traversal entry must reject the whole archive listing"
    )
}

let temporaryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("cmux-companion-selftest-\(UUID().uuidString)", isDirectory: true)

do {
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try testEvaluator()
    try testStoreInboxAndReducer(root: temporaryRoot)
    try testCrossSetOwnership()
    try testTargetSplitIdentity()
    try testTransportNormalization()
    try testSurfaceWorkloadAndSessionResolution()
    try testNavigationLinks()
    try testGUIProcessEnvironment(root: temporaryRoot)
    try testRemoteEventIdentity()
    try testRemoteHeartbeatPreservesLifecycle()
    try testFocusSelectionUsesDeficientGroup()
    try testExactGroupJoin()
    try testRenameRejectsDuplicateSetName()
    try testTranscriptExtraction(root: temporaryRoot)
    try testAppReleaseSelectionAndArchivePolicy()
    print("Cmux Companion self-test: PASS")
} catch {
    fputs("Cmux Companion self-test: FAIL: \(error)\n", stderr)
    exit(1)
}
