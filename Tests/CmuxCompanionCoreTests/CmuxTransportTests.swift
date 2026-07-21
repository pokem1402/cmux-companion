import Foundation
import XCTest
@testable import CmuxCompanionCore

final class CmuxTransportTests: XCTestCase {
    func testJSONValuePreservesIntegersAndUnknownFields() throws {
        let value = try CmuxJSON.decode(#"{"seq":9223372036854775806,"new_field":{"enabled":true}}"#)

        XCTAssertEqual(value["seq"], .integer(9_223_372_036_854_775_806))
        XCTAssertEqual(value["new_field"]?["enabled"], .bool(true))
        XCTAssertEqual(try CmuxJSON.decode(CmuxJSON.encode(value)), value)
    }

    func testTreeNormalizationAcceptsRPCWrapperAndAlternateKeys() throws {
        let raw = try CmuxJSON.decode(#"""
        {
          "result": {
            "windows": [{
              "window_id": "window-1",
              "is_key_window": true,
              "workspaces": [{
                "workspaceId": "workspace-1",
                "name": "Review",
                "panes": [{
                  "pane_id": "pane-1",
                  "surfaces": [{
                    "surface_id": "surface-1",
                    "surface_type": "browser",
                    "browser": {"current_url": "https://github.com/example/repo/pull/1"},
                    "selected_in_pane": true
                  }]
                }]
              }]
            }]
          }
        }
        """#)

        let snapshot = CmuxTreeSnapshot(raw: raw)
        XCTAssertEqual(snapshot.windows.first?.id, "window-1")
        XCTAssertEqual(snapshot.windows.first?.isKey, true)
        XCTAssertEqual(snapshot.windows.first?.workspaces.first?.title, "Review")
        XCTAssertEqual(snapshot.windows.first?.workspaces.first?.surfaces.first?.id, "surface-1")
        XCTAssertEqual(
            snapshot.windows.first?.workspaces.first?.surfaces.first?.url,
            "https://github.com/example/repo/pull/1"
        )
    }

    func testSessionFeedAndNotificationNormalization() throws {
        let sessions = CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"""
        {"data":{"sessions":[{
          "sessionId":"session-1","agent":"codex","workspaceId":"workspace-1",
          "surfaceId":"surface-1","agentLifecycle":"running","pid":"42",
          "codex_transcript_path":"/tmp/rollout.jsonl","is_restorable":true,"transcript_backed":true
        }]}}
        """#))
        XCTAssertEqual(sessions.sessions.first?.id, "session-1")
        XCTAssertEqual(sessions.sessions.first?.effectiveLifecycle, "running")
        XCTAssertEqual(sessions.sessions.first?.pid, 42)
        XCTAssertEqual(sessions.sessions.first?.transcriptPath, "/tmp/rollout.jsonl")
        XCTAssertEqual(sessions.sessions.first?.isRestorable, true)
        XCTAssertEqual(sessions.sessions.first?.transcriptBacked, true)

        let feed = CmuxFeedSnapshot(raw: try CmuxJSON.decode(#"""
        {"items":[
          {"id":"feed-1","workstream_id":"session-1","kind":"userPrompt","text":"review this"},
          {"id":"feed-2","kind":"userPrompt","text":null,"text_length":11,"redacted_fields":["text"]}
        ]}
        """#))
        XCTAssertEqual(feed.items.first?.text, "review this")
        XCTAssertFalse(feed.items[0].isTextRedacted)
        XCTAssertTrue(feed.items[1].isTextRedacted)

        let notifications = CmuxNotificationsSnapshot(raw: try CmuxJSON.decode(#"""
        [{"notification_id":"notification-1","workspace_id":"workspace-1","body":"Done","read":true}]
        """#))
        XCTAssertEqual(notifications.notifications.first?.id, "notification-1")
        XCTAssertEqual(notifications.notifications.first?.body, "Done")
        XCTAssertEqual(notifications.notifications.first?.isRead, true)
    }

    func testSurfaceWorkloadClassificationIsExplicitAndShellSafe() {
        XCTAssertEqual(SurfaceWorkload(agent: "codex"), .codex)
        XCTAssertEqual(SurfaceWorkload(agent: "OpenAI Codex CLI"), .codex)
        XCTAssertEqual(SurfaceWorkload(agent: "Claude Code"), .claude)
        XCTAssertEqual(
            SurfaceWorkload(agent: nil, shellIsAuthoritative: true),
            .shell
        )
        XCTAssertEqual(SurfaceWorkload(agent: nil), .unknown)
        XCTAssertEqual(
            SurfaceWorkload(agent: "claude", isBrowser: true, shellIsAuthoritative: true),
            .browser
        )
        XCTAssertEqual(SurfaceWorkload(agent: "custom-agent"), .otherAgent("custom-agent"))
    }

    func testFreshProcessWorkloadSupplementsButNeverOverridesKnownSession() throws {
        let sessions = CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"""
        {"sessions":[
          {"session_id":"claude","surface_id":"surface-1","agent":"claude",
           "active_for_surface":true},
          {"session_id":"unnamed","surface_id":"surface-2",
           "active_for_surface":true}
        ]}
        """#)).sessions

        XCTAssertEqual(
            SurfaceWorkload.resolved(
                currentSession: sessions[0],
                processWorkload: .codex,
                hasFreshProcessSnapshot: true,
                occupancyIsAuthoritative: true
            ),
            .claude
        )
        XCTAssertEqual(
            SurfaceWorkload.resolved(
                currentSession: sessions[1],
                processWorkload: .codex,
                hasFreshProcessSnapshot: true,
                occupancyIsAuthoritative: true
            ),
            .codex
        )
        XCTAssertEqual(
            SurfaceWorkload.resolved(
                currentSession: sessions[1],
                processWorkload: .shell,
                hasFreshProcessSnapshot: true,
                occupancyIsAuthoritative: true
            ),
            .unknown
        )
        XCTAssertEqual(
            SurfaceWorkload.resolved(
                currentSession: nil,
                processWorkload: nil,
                hasFreshProcessSnapshot: true,
                occupancyIsAuthoritative: true
            ),
            .unknown
        )
        XCTAssertEqual(
            SurfaceWorkload.resolved(
                currentSession: nil,
                processWorkload: nil,
                hasFreshProcessSnapshot: false,
                occupancyIsAuthoritative: true
            ),
            .shell
        )
        XCTAssertEqual(
            SurfaceWorkload.resolved(
                currentSession: sessions[0],
                processWorkload: .codex,
                hasFreshProcessSnapshot: true,
                isBrowser: true,
                occupancyIsAuthoritative: true
            ),
            .browser
        )
    }

    func testTopSnapshotClassifiesProcessTreesTagsAndShells() throws {
        let tsv = [
            "0.0\t0\t0\ttotal\ttotal\t\t",
            "0.1\t100\t1\ttag\tworkspace-1:tag:claude_code\tworkspace-1\tNeeds input",
            "0.1\t100\t1\tprocess\t41\tworkspace-1:tag:claude_code\t2.1.114",
            "0.2\t200\t3\tsurface\tsurface-codex\tpane-1\tProject\twith tab",
            "0.0\t10\t1\tprocess\t10\tsurface-codex\tnode",
            "0.1\t100\t1\tprocess\t11\t10\t/opt/tools/codex",
            "0.0\t10\t1\tprocess\t12\tsurface-codex\tzsh",
            "0.1\t120\t2\tsurface\tsurface-claude\tpane-1\tClaude",
            "0.1\t100\t1\tprocess\t41\tsurface-claude\t2.1.114",
            "0.0\t20\t1\tprocess\t42\tsurface-claude\t-zsh",
            "0.0\t20\t1\tsurface\tsurface-shell\tpane-1\tShell",
            "0.0\t20\t1\tprocess\t43\tsurface-shell\t/bin/bash",
            "0.0\t20\t1\tsurface\tsurface-unknown\tpane-1\tUnknown",
            "0.0\t20\t1\tprocess\t50\tsurface-unknown\tpython3",
        ].joined(separator: "\n")

        let snapshot = try CmuxTopSnapshot(tsv: tsv)

        XCTAssertEqual(snapshot.workload(forSurfaceID: "surface-codex"), .codex)
        XCTAssertEqual(snapshot.workload(forSurfaceID: "surface-claude"), .claude)
        XCTAssertEqual(snapshot.workload(forSurfaceID: "surface-shell"), .shell)
        XCTAssertNil(snapshot.workload(forSurfaceID: "surface-unknown"))
        XCTAssertEqual(snapshot.processIDs(forSurfaceID: "surface-codex"), [10, 11, 12])
        XCTAssertEqual(snapshot.processIDs(forSurfaceID: "surface-claude"), [41, 42])
        XCTAssertEqual(snapshot.processIDs(forSurfaceID: "surface-unknown"), [50])
        XCTAssertTrue(snapshot.processIDs(forSurfaceID: "missing-surface").isEmpty)
        XCTAssertNil(snapshot.agentWorkload(forProcessID: 10, onSurfaceID: "surface-codex"))
        XCTAssertEqual(
            snapshot.agentWorkload(forProcessID: 11, onSurfaceID: "surface-codex"),
            .codex
        )
        XCTAssertEqual(
            snapshot.agentWorkload(forProcessID: 41, onSurfaceID: "surface-claude"),
            .claude
        )
        XCTAssertNil(snapshot.agentWorkload(forProcessID: 41, onSurfaceID: "surface-codex"))
    }

    func testTopSnapshotRejectsConflictingAgentEvidenceAndMalformedTSV() throws {
        let conflict = [
            "0.1\t50\t1\ttag\tworkspace-1:tag:claude_code\tworkspace-1\tRunning",
            "0.1\t50\t1\tprocess\t10\tworkspace-1:tag:claude_code\tcodex",
            "0.1\t100\t2\tsurface\tsurface-1\tpane-1\tAgent",
            "0.1\t50\t1\tprocess\t10\tsurface-1\tcodex",
            "0.1\t50\t1\tprocess\t11\tsurface-1\tclaude",
        ].joined(separator: "\n")
        let snapshot = try CmuxTopSnapshot(tsv: conflict)
        XCTAssertNil(snapshot.workload(forSurfaceID: "surface-1"))
        XCTAssertEqual(snapshot.processIDs(forSurfaceID: "surface-1"), [10, 11])
        XCTAssertNil(snapshot.agentWorkload(forProcessID: 10, onSurfaceID: "surface-1"))
        XCTAssertEqual(snapshot.agentWorkload(forProcessID: 11, onSurfaceID: "surface-1"), .claude)

        XCTAssertThrowsError(try CmuxTopSnapshot(tsv: "")) { error in
            XCTAssertEqual(error as? CmuxTopSnapshotError, .noRows)
        }
        XCTAssertThrowsError(try CmuxTopSnapshot(tsv: "not tsv")) { error in
            XCTAssertEqual(error as? CmuxTopSnapshotError, .invalidTSVLine(1))
        }
    }

    func testClaudeTagWinsOverNestedAgentHelper() throws {
        let tsv = [
            "0.1\t50\t1\ttag\tworkspace-1:tag:claude_code\tworkspace-1\tRunning",
            "0.1\t50\t1\tprocess\t41\tworkspace-1:tag:claude_code\t2.1.114",
            "0.1\t100\t3\tsurface\tsurface-1\tpane-1\tReview",
            "0.1\t50\t1\tprocess\t41\tsurface-1\t2.1.114",
            "0.1\t50\t1\tprocess\t42\t41\tcodex",
            "0.0\t10\t1\tprocess\t43\tsurface-1\tzsh",
        ].joined(separator: "\n")

        XCTAssertEqual(
            try CmuxTopSnapshot(tsv: tsv).workload(forSurfaceID: "surface-1"),
            .claude
        )
    }

    func testInactiveSessionCanSupplyPromptDisplayButNotCurrentOwnership() throws {
        let top = try CmuxTopSnapshot(tsv: [
            "0.1\t100\t2\tsurface\tsurface-1\tpane-1\tCodex",
            "0.1\t90\t1\tprocess\t42\tsurface-1\tcodex",
            "0.0\t10\t1\tprocess\t43\tsurface-1\tzsh",
        ].joined(separator: "\n"))
        let sessions = CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"""
        {"sessions":[
          {"session_id":"live-prompt","surface_id":"surface-1","pid":42,
           "agent":"codex","agent_lifecycle":"idle","active_for_surface":false,
           "transcript_path":"/tmp/live.jsonl"},
          {"session_id":"stale-prompt","surface_id":"surface-2","pid":99,
           "agent":"codex","agent_lifecycle":"idle","active_for_surface":false}
        ]}
        """#)).sessions

        XCTAssertTrue(CmuxAgentSessionResolver.currentBySurface(sessions).isEmpty)
        let displaySources = CmuxAgentSessionResolver.promptDisplaySourcesBySurface(
            sessions,
            corroboratedBy: top
        )
        XCTAssertEqual(displaySources["surface-1"]?.sessionID, "live-prompt")
        XCTAssertEqual(displaySources["surface-1"]?.transcriptPath, "/tmp/live.jsonl")
        XCTAssertNil(displaySources["surface-2"])
    }

    func testCurrentSessionResolverRejectsHistoricalSurfaceOwners() throws {
        let snapshot = CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"""
        {"sessions":[
          {"session_id":"historical","surface_id":"surface-1","agent":"codex",
           "agent_lifecycle":"running","active_for_surface":false,"updated_at_unix":30},
          {"session_id":"current","surface_id":"surface-1","agent":"claude",
           "agent_lifecycle":"needsInput","active_for_surface":true,"updated_at_unix":20},
          {"session_id":"legacy-current","surface_id":"surface-2","agent":"codex",
           "agent_lifecycle":"running","updated_at_unix":10},
          {"session_id":"legacy-ended","surface_id":"surface-3","agent":"claude",
           "agent_lifecycle":"ended","updated_at_unix":40},
          {"session_id":"current-unknown","surface_id":"surface-4",
           "agent_lifecycle":"running","active_for_surface":true,"updated_at_unix":50},
          {"session_id":"display-name-only","surface_id":"surface-5",
           "agent_display_name":"Claude Code","agent_lifecycle":"running",
           "active_for_surface":true,"updated_at_unix":60}
        ]}
        """#))

        let resolved = CmuxAgentSessionResolver.currentBySurface(snapshot.sessions)
        XCTAssertEqual(resolved["surface-1"]?.id, "current")
        XCTAssertEqual(resolved["surface-1"]?.activeForSurface, true)
        XCTAssertEqual(resolved["surface-2"]?.id, "legacy-current")
        XCTAssertNil(resolved["surface-2"]?.activeForSurface)
        XCTAssertNil(resolved["surface-3"])
        XCTAssertEqual(
            SurfaceWorkload(
                currentSession: resolved["surface-4"],
                occupancyIsAuthoritative: true
            ),
            .unknown
        )
        XCTAssertEqual(
            SurfaceWorkload(
                currentSession: resolved["surface-5"],
                occupancyIsAuthoritative: true
            ),
            .claude
        )
    }

    func testEventFramesExposeResumeGapAndNeverInventRedactedText() throws {
        let ack = try CmuxEventFrame.decode(line: #"""
        {"type":"ack","boot_id":"boot-1","resume":{"gap":true,"latest_seq":8}}
        """#)
        XCTAssertEqual(ack.kind, .acknowledgement)
        XCTAssertTrue(ack.resumeGap)

        let event = try CmuxEventFrame.decode(line: #"""
        {
          "type":"event","boot_id":"boot-1","seq":9,"name":"workspace.prompt.submitted",
          "workspace_id":"workspace-1",
          "payload":{"message":null,"message_length":24,"preview":"safe preview","redacted_fields":["message"]}
        }
        """#)
        XCTAssertEqual(event.id, "boot-1-9")
        XCTAssertTrue(event.isContentRedacted)
        XCTAssertEqual(event.payload?["message"], .null)
    }

    func testSnapshotFailuresDoNotSuppressOtherComponents() async throws {
        let topTSV = [
            "0.1\t100\t1\tsurface\tsurface-1\tpane-1\tCodex",
            "0.1\t100\t1\tprocess\t42\tsurface-1\tcodex",
        ].joined(separator: "\n")
        let runner = FakeCommandRunner(responses: [
            CmuxSnapshotLoader.treeArguments: .failure(FakeError.expected),
            CmuxSnapshotLoader.sessionsArguments: .success(#"{"sessions":[{"session_id":"s1"}]}"#),
            CmuxSnapshotLoader.topArguments: .success(topTSV),
            CmuxSnapshotLoader.feedArguments: .success("not-json"),
            CmuxSnapshotLoader.notificationsArguments: .success(#"[{"id":"n1"}]"#)
        ])
        let snapshot = await CmuxSnapshotLoader(runner: runner).load()

        XCTAssertNotNil(snapshot.tree.failure)
        XCTAssertEqual(snapshot.sessions.value?.sessions.first?.id, "s1")
        XCTAssertEqual(snapshot.top.value?.workload(forSurfaceID: "surface-1"), .codex)
        XCTAssertEqual(snapshot.top.value?.processIDs(forSurfaceID: "surface-1"), [42])
        XCTAssertNotNil(snapshot.feed.failure)
        XCTAssertEqual(snapshot.notifications.value?.notifications.first?.id, "n1")
        XCTAssertEqual(snapshot.failures.count, 2)
        XCTAssertEqual(Set(runner.recordedArguments), Set([
            CmuxSnapshotLoader.treeArguments,
            CmuxSnapshotLoader.sessionsArguments,
            CmuxSnapshotLoader.topArguments,
            CmuxSnapshotLoader.feedArguments,
            CmuxSnapshotLoader.notificationsArguments
        ]))
    }

    func testOptionalTopFailureDoesNotDegradeHealthyCmuxSnapshot() async throws {
        let runner = FakeCommandRunner(responses: [
            CmuxSnapshotLoader.treeArguments: .success(#"{"windows":[]}"#),
            CmuxSnapshotLoader.sessionsArguments: .success(#"{"sessions":[]}"#),
            CmuxSnapshotLoader.topArguments: .failure(FakeError.expected),
            CmuxSnapshotLoader.feedArguments: .success(#"{"items":[]}"#),
            CmuxSnapshotLoader.notificationsArguments: .success("[]"),
        ])

        let snapshot = await CmuxSnapshotLoader(runner: runner).load()

        XCTAssertNotNil(snapshot.top.failure)
        XCTAssertTrue(snapshot.failures.isEmpty)
    }

    func testOptionalTopTimeoutCannotBlockWholeRefresh() async throws {
        let runner = HangingTopRunner()
        let startedAt = ContinuousClock.now

        let snapshot = await CmuxSnapshotLoader(
            runner: runner,
            topTimeout: .milliseconds(20)
        ).load()

        XCTAssertNotNil(snapshot.top.failure)
        XCTAssertNotNil(snapshot.tree.value)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
    }

    func testTreeSnapshotRequestsDurableUUIDsUsingGlobalOption() {
        XCTAssertEqual(
            CmuxSnapshotLoader.treeArguments,
            ["--id-format", "uuids", "tree", "--all", "--json"]
        )
        XCTAssertEqual(
            CmuxSnapshotLoader.topArguments,
            [
                "--id-format", "uuids", "top", "--all", "--processes", "--flat",
                "--format", "tsv",
            ]
        )
    }

    func testFocusCommandsRunBroadestToNarrowest() async throws {
        let runner = FakeCommandRunner(responses: [:], defaultResponse: .success("{}"))
        let client = CmuxCommandClient(runner: runner)
        try await client.focus(CmuxFocusTarget(
            windowID: "window-1",
            workspaceID: "workspace-1",
            surfaceID: "surface-1"
        ))

        XCTAssertEqual(runner.recordedArguments, [
            ["focus-window", "--window", "window-1"],
            ["workspace", "select", "workspace-1", "--window", "window-1"],
            [
                "focus-panel", "--panel", "surface-1",
                "--workspace", "workspace-1", "--window", "window-1"
            ]
        ])
    }

    func testNavigationDeepLinkUsesRegisteredWorkspaceRoute() throws {
        let workspaceID = "84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A"
        let surfaceID = "4202F9A9-C905-41D4-B126-6F8179F51783"

        XCTAssertEqual(
            CmuxNavigationLink.workspace(workspaceID, surfaceID: surfaceID)?.absoluteString,
            "cmux://workspace/\(workspaceID)/surface/\(surfaceID)"
        )
        XCTAssertNil(CmuxNavigationLink.workspace("workspace:1"))
    }

    func testRemoteEventIdentityRejectsLocalSessionsAndDecodesCarrier() throws {
        let payload = try CmuxJSON.decode(#"{"tool_name":"cmux-companion-remote-event:PermissionRequest","_opencode_request_id":"cmux-companion-seq:boot-1:42:event"}"#)
        let identity = try XCTUnwrap(CmuxRemoteEventIdentity(
            sessionID: "cmux-remote:v2:surface%3A1:native-session",
            payload: payload
        ))
        XCTAssertEqual(identity.surfaceID, "surface:1")
        XCTAssertEqual(identity.originalHookName, "PermissionRequest")
        XCTAssertEqual(identity.order, CmuxRemoteEventOrder(bootID: "boot-1", sequence: 42))

        let legacyPayload = try CmuxJSON.decode(#"{"surface_id":"surface:1","_opencode_request_id":"cmux-companion-seq:boot-1:43:event"}"#)
        XCTAssertEqual(
            CmuxRemoteEventIdentity(
                sessionID: "cmux-remote:surface:1:native-session",
                payload: legacyPayload
            )?.surfaceID,
            "surface:1"
        )
        XCTAssertNil(CmuxRemoteEventIdentity(sessionID: "cmux-remote:v2:", payload: payload))
        XCTAssertNil(CmuxRemoteEventIdentity(
            sessionID: "cmux-remote:v2:surface%3A1",
            payload: payload
        ))
        XCTAssertNil(CmuxRemoteEventIdentity(sessionID: "local-session", payload: payload))
    }

    func testRemoteHeartbeatPreservesLifecycleInsteadOfInventingRunning() {
        XCTAssertEqual(CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .waiting), .waiting)
        XCTAssertEqual(CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .idle), .idle)
        XCTAssertEqual(CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .stale), .unknown)
        XCTAssertEqual(CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: .disconnected), .unknown)
        XCTAssertEqual(CmuxRemoteLifecycle.state(forHookName: "Heartbeat", previous: nil), .unknown)
        XCTAssertEqual(CmuxRemoteLifecycle.state(forHookName: "PermissionRequest", previous: .running), .waiting)

        let leaseSeenAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(CmuxRemoteLifecycle.stateApplyingLease(
            .running,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(10 * 60)
        ), .running)
        XCTAssertEqual(CmuxRemoteLifecycle.stateApplyingLease(
            .running,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(16 * 60)
        ), .stale)
        XCTAssertEqual(CmuxRemoteLifecycle.stateApplyingLease(
            .unknown,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(61 * 60)
        ), .disconnected)
        XCTAssertEqual(CmuxRemoteLifecycle.stateApplyingLease(
            .stale,
            lastSeenAt: leaseSeenAt,
            now: leaseSeenAt.addingTimeInterval(61 * 60)
        ), .disconnected)
        for explicitState in [
            MemberRuntimeState.waiting,
            .idle,
            .ended,
            .error,
        ] {
            XCTAssertEqual(CmuxRemoteLifecycle.stateApplyingLease(
                explicitState,
                lastSeenAt: leaseSeenAt,
                now: leaseSeenAt.addingTimeInterval(24 * 60 * 60)
            ), explicitState)
        }

        let remoteSeenAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(CmuxRemoteLifecycle.shouldYieldToLocalSession(
            isActiveForSurface: true,
            state: .idle,
            updatedAt: nil,
            remoteLastSeenAt: remoteSeenAt
        ))
        XCTAssertFalse(CmuxRemoteLifecycle.shouldYieldToLocalSession(
            isActiveForSurface: false,
            state: .running,
            updatedAt: Date(timeIntervalSince1970: 90),
            remoteLastSeenAt: remoteSeenAt
        ))
        XCTAssertTrue(CmuxRemoteLifecycle.shouldYieldToLocalSession(
            isActiveForSurface: false,
            state: .running,
            updatedAt: Date(timeIntervalSince1970: 110),
            remoteLastSeenAt: remoteSeenAt
        ))
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
        XCTAssertEqual(twentyMinuteReplaySeenAt, twentyMinuteOldFrame)
        XCTAssertEqual(sixtyOneMinuteReplaySeenAt, sixtyOneMinuteOldFrame)
        XCTAssertEqual(CmuxRemoteLifecycle.stateApplyingLease(
            .running,
            lastSeenAt: twentyMinuteReplaySeenAt,
            now: replayReceivedAt
        ), .stale)
        XCTAssertEqual(CmuxRemoteLifecycle.stateApplyingLease(
            .running,
            lastSeenAt: sixtyOneMinuteReplaySeenAt,
            now: replayReceivedAt
        ), .disconnected)
        let localReceivedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(
            CmuxRemoteLifecycle.canonicalPromptDate(
                frameOccurredAt: nil,
                localReceivedAt: localReceivedAt,
                remoteReportedAt: Date(timeIntervalSince1970: 9_999)
            ),
            localReceivedAt
        )
        XCTAssertFalse(CmuxRemoteLifecycle.shouldAcceptSessionEvent(
            currentSessionID: "session-b",
            incomingSessionID: "session-a",
            hookName: "Stop"
        ))
        XCTAssertTrue(CmuxRemoteLifecycle.shouldAcceptSessionEvent(
            currentSessionID: "session-a",
            incomingSessionID: "session-b",
            hookName: "SessionStart"
        ))
        XCTAssertEqual(CmuxRemoteLifecycle.isOrderNewer(
            CmuxRemoteEventOrder(bootID: "boot-1", sequence: 9),
            thanBootID: "boot-1",
            sequence: 10
        ), false)
        XCTAssertEqual(CmuxRemoteLifecycle.isOrderNewer(
            CmuxRemoteEventOrder(bootID: "boot-1", sequence: 11),
            thanBootID: "boot-1",
            sequence: 10
        ), true)
        XCTAssertFalse(CmuxRemoteLifecycle.isEventNewer(
            incomingOrder: CmuxRemoteEventOrder(bootID: "old-boot", sequence: 99),
            occurredAt: Date(timeIntervalSince1970: 90),
            previousBootID: "new-boot",
            previousSequence: 1,
            previousReceivedAt: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertFalse(CmuxRemoteLifecycle.isAfterLocalOwnership(
            occurredAt: Date(timeIntervalSince1970: 99),
            localOwnershipSince: Date(timeIntervalSince1970: 100)
        ))
    }

    func testEventStreamBuildsReconnectCommandAndDecodesNDJSON() async throws {
        let streamer = FakeLineStreamer(lines: [
            #"{"type":"ack","boot_id":"boot-1","resume":{"gap":false}}"#,
            #"{"type":"event","boot_id":"boot-1","seq":1,"name":"agent.hook.Stop","category":"agent"}"#
        ])
        let cursor = URL(fileURLWithPath: "/tmp/cmux-companion-test/events.seq")
        let configuration = CmuxEventStreamConfiguration(
            cursorFile: cursor,
            names: ["agent.hook.Stop"],
            categories: ["agent"]
        )

        var frames: [CmuxEventFrame] = []
        for try await frame in CmuxEventStream(runner: streamer).frames(configuration: configuration) {
            frames.append(frame)
        }

        XCTAssertEqual(frames.map(\.kind), [.acknowledgement, .event])
        XCTAssertEqual(streamer.recordedArguments, [
            "events", "--cursor-file", cursor.path, "--reconnect", "--no-heartbeat",
            "--name", "agent.hook.Stop", "--category", "agent"
        ])
    }

    func testExecutableLocatorFindsAppBundleThenPATH() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-locator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let appExecutable = applications
            .appendingPathComponent("cmux.app/Contents/Resources/bin/cmux", isDirectory: false)
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: appExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appExecutable.path)

        let locator = CmuxExecutableLocator(
            environment: ["PATH": "/does/not/exist"],
            applicationsDirectory: applications,
            homeDirectory: root
        )
        XCTAssertEqual(try locator.resolve(), appExecutable)
    }

    func testProcessRunnerCapturesStderrExitAndSupportsCancellation() async throws {
        let shell = CmuxProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        do {
            _ = try await shell.run(arguments: ["-c", "printf output; printf problem >&2; exit 7"])
            XCTFail("Expected non-zero exit")
        } catch let error as CmuxProcessError {
            XCTAssertEqual(error.exitCode, 7)
            XCTAssertEqual(error.stderr, "problem")
            guard case .nonZeroExit(_, _, let stdout, _) = error else {
                return XCTFail("Expected nonZeroExit")
            }
            XCTAssertEqual(stdout, "output")
        }

        let sleep = CmuxProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let task = Task { try await sleep.run(arguments: ["5"]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private enum FakeError: Error {
    case expected
}

private final class FakeCommandRunner: CmuxCommandRunning, @unchecked Sendable {
    typealias Response = Result<String, Error>

    private let lock = NSLock()
    private let responses: [[String]: Response]
    private let defaultResponse: Response?
    private var calls: [[String]] = []

    var recordedArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    init(responses: [[String]: Response], defaultResponse: Response? = nil) {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    func run(arguments: [String], environment: [String: String]) async throws -> CmuxProcessResult {
        let response = record(arguments: arguments)

        guard let response else { throw FakeError.expected }
        let output = try response.get()
        return CmuxProcessResult(
            arguments: arguments,
            exitCode: 0,
            standardOutput: Data(output.utf8),
            standardError: Data()
        )
    }

    private func record(arguments: [String]) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        calls.append(arguments)
        return responses[arguments] ?? defaultResponse
    }
}

private final class FakeLineStreamer: CmuxLineStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private let lines: [String]
    private var arguments: [String] = []

    var recordedArguments: [String] {
        lock.lock()
        defer { lock.unlock() }
        return arguments
    }

    init(lines: [String]) {
        self.lines = lines
    }

    func streamLines(
        arguments: [String],
        environment: [String: String]
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        self.arguments = arguments
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

private final class HangingTopRunner: CmuxCommandRunning, @unchecked Sendable {
    func run(arguments: [String], environment: [String: String]) async throws -> CmuxProcessResult {
        if arguments == CmuxSnapshotLoader.topArguments {
            try await Task.sleep(for: .seconds(60))
        }
        let output: String
        switch arguments {
        case CmuxSnapshotLoader.treeArguments: output = #"{"windows":[]}"#
        case CmuxSnapshotLoader.sessionsArguments: output = #"{"sessions":[]}"#
        case CmuxSnapshotLoader.feedArguments: output = #"{"items":[]}"#
        case CmuxSnapshotLoader.notificationsArguments: output = "[]"
        default: throw FakeError.expected
        }
        return CmuxProcessResult(
            arguments: arguments,
            exitCode: 0,
            standardOutput: Data(output.utf8),
            standardError: Data()
        )
    }
}
