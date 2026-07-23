import AppKit
import Foundation
import SwiftUI
import CmuxCompanionCore

private enum DragAndDropSelfTestError: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

enum DragAndDropSelfTest {
    @MainActor
    static func run() async throws {
        try verifyDashboardWindow()
        try verifyMenuBarLayout()
        try verifyRemoteLiveSurfaceOverlay()
        try verifyLocalTopRuntimeFallback()
        try verifyRemoteEventPipeline()
        try verifySearch()
        try verifyColorPalette()
        guard SurfaceDragTransport.selfTest() else {
            throw DragAndDropSelfTestError.assertion("drag transport token round-trip failed")
        }
        guard SetOrderDragTransport.selfTest(),
              SetOrderDragTransport.contentType.identifier
                != SurfaceDragTransport.contentType.identifier else {
            throw DragAndDropSelfTestError.assertion(
                "set-order drag transport round-trip or private type separation failed"
            )
        }
        try await verifyItemProviderRoundTrip()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-companion-dnd-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try verifySetPreferencesAndOrdering(root: root)

        let member = WorkMember(
            label: "main",
            role: .worker,
            sessionID: "dnd-session",
            surfaceID: "dnd-surface",
            runtimeState: .running,
            lastSubmittedText: "keep this prompt",
            lastHeartbeatAt: Date(timeIntervalSince1970: 100),
            lastRemoteBootID: "boot",
            lastRemoteSequence: 9,
            localOwnershipSince: Date(timeIntervalSince1970: 90),
            isRemote: true
        )
        let memberGroup = WorkGroup(
            label: "Workers",
            role: .worker,
            memberIDs: [member.id]
        )
        let attachment = WorkAttachment(
            label: "PR-1",
            role: .pr,
            url: URL(string: "https://github.com/example/repo/pull/1"),
            surfaceID: "browser-surface",
            workspaceID: "workspace",
            windowID: "window"
        )
        let sourceSet = WorkSet(
            label: "Source",
            groups: [memberGroup],
            members: [member],
            attachments: [attachment]
        )
        let targetGroup = WorkGroup(
            label: "Review team",
            role: .reviewer,
            required: false,
            policy: .minActive(1)
        )
        let destinationSet = WorkSet(label: "Destination", groups: [targetGroup])
        let store = CompanionStore(url: root.appendingPathComponent("sets.json"))
        try store.save(CompanionSnapshot(sets: [sourceSet, destinationSet]))
        let model = CompanionAppModel(
            store: store,
            inbox: CommandInbox(directoryURL: root.appendingPathComponent("commands", isDirectory: true))
        )

        let initialSets = model.sets
        for duplicateName in ["Source", "source", "Söurce", "  Source  "] {
            model.newSetName = duplicateName
            guard !model.createSet(),
                  model.sets == initialSets,
                  model.newSetName == duplicateName,
                  model.conflictingSetName == "Source" else {
                throw DragAndDropSelfTestError.assertion("duplicate set creation did not warn atomically")
            }
            model.dismissSetNameConflict()
        }
        guard model.renameSet(sourceSet.id, to: "SOURCE"),
              model.sets.first(where: { $0.id == sourceSet.id })?.label == "SOURCE",
              model.renameSet(sourceSet.id, to: "Source") else {
            throw DragAndDropSelfTestError.assertion("a set could not be renamed to its own name")
        }
        guard !model.renameSet(destinationSet.id, to: " source "),
              model.sets.first(where: { $0.id == destinationSet.id })?.label == "Destination",
              model.conflictingSetName == "Source" else {
            throw DragAndDropSelfTestError.assertion("duplicate set rename did not warn atomically")
        }
        model.dismissSetNameConflict()
        model.newSetName = "unfinished popover draft"
        guard model.createSet(named: "Dashboard local draft"),
              model.newSetName == "unfinished popover draft",
              let dashboardCreatedSet = model.sets.last,
              dashboardCreatedSet.label == "Dashboard local draft" else {
            throw DragAndDropSelfTestError.assertion(
                "Dashboard set creation overwrote the compact popover draft"
            )
        }
        model.deleteSet(dashboardCreatedSet.id)
        model.newSetName = ""

        let connectionFailure = CmuxSnapshotFailure(
            command: ["cmux", "tree"],
            error: NSError(
                domain: "CmuxCompanionSelfTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic cmux connection failure"]
            )
        )
        model.applySnapshotForSelfTest(CmuxTransportSnapshot(
            tree: .failure(connectionFailure),
            sessions: .success(CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"{"sessions":[]}"#))),
            top: .success(CmuxTopSnapshot()),
            feed: .success(CmuxFeedSnapshot(raw: try CmuxJSON.decode(#"{"items":[]}"#))),
            notifications: .success(
                CmuxNotificationsSnapshot(raw: try CmuxJSON.decode(#"{"notifications":[]}"#))
            )
        ))
        let connectionError = model.lastError
        guard connectionError != nil,
              model.createSet(named: "Created while cmux is unavailable"),
              model.lastError == connectionError,
              let offlineCreatedSet = model.sets.last,
              offlineCreatedSet.label == "Created while cmux is unavailable" else {
            throw DragAndDropSelfTestError.assertion(
                "successful set creation cleared an unrelated cmux error"
            )
        }
        model.deleteSet(offlineCreatedSet.id)

        let movedMember = SurfaceDragPayload(
            origin: .member,
            surfaceID: member.surfaceID,
            sourceSetID: sourceSet.id,
            itemID: member.id
        )
        guard model.acceptSurfaceDrop(
            movedMember,
            onto: destinationSet.id,
            role: .reviewer,
            targetGroupID: targetGroup.id
        ),
              model.sets[0].members.isEmpty,
              model.sets[1].members.count == 1,
              model.sets[1].members[0].id == member.id,
              model.sets[1].members[0].role == .reviewer,
              model.sets[1].members[0].lastSubmittedText == member.lastSubmittedText,
              model.sets[1].members[0].lastRemoteSequence == member.lastRemoteSequence,
              model.sets[1].groups.count == 1,
              model.sets[1].groups[0].id == targetGroup.id,
              model.sets[1].groups[0].required == targetGroup.required,
              model.sets[1].groups[0].policy == targetGroup.policy,
              model.sets[1].groups[0].memberIDs == [member.id] else {
            throw DragAndDropSelfTestError.assertion("member move did not preserve identity and metadata")
        }

        let movedMemberPayload = SurfaceDragPayload(
            origin: .member,
            surfaceID: member.surfaceID,
            sourceSetID: destinationSet.id,
            itemID: member.id
        )

        guard model.acceptSurfaceDrop(
            movedMemberPayload,
            onto: destinationSet.id,
            role: .reviewer,
            targetGroupID: targetGroup.id
        ),
              model.sets[1].members.count == 1,
              model.sets[1].groups.count == 1,
              model.sets[1].groups[0].memberIDs == [member.id] else {
            throw DragAndDropSelfTestError.assertion("same-group drop created a duplicate")
        }

        let beforeRejectedMemberDrop = model.sets
        guard !model.acceptSurfaceDrop(movedMemberPayload, onto: destinationSet.id, role: .pr),
              model.sets == beforeRejectedMemberDrop else {
            throw DragAndDropSelfTestError.assertion("invalid member-to-PR drop was not atomic")
        }

        guard model.acceptUnlinkDrop(movedMemberPayload),
              model.sets[1].members.isEmpty,
              model.sets[1].groups.isEmpty else {
            throw DragAndDropSelfTestError.assertion("member unlink did not clean the destination group")
        }

        let attachmentPayload = SurfaceDragPayload(
            origin: .attachment,
            surfaceID: attachment.surfaceID,
            sourceSetID: sourceSet.id,
            itemID: attachment.id
        )
        let beforeRejectedAttachmentDrop = model.sets
        guard !model.acceptSurfaceDrop(attachmentPayload, onto: destinationSet.id, role: .worker),
              model.sets == beforeRejectedAttachmentDrop else {
            throw DragAndDropSelfTestError.assertion("invalid PR-to-worker drop was not atomic")
        }

        guard model.acceptSurfaceDrop(attachmentPayload, onto: destinationSet.id, role: .pr),
              model.sets[0].attachments.isEmpty,
              model.sets[1].attachments == [attachment] else {
            throw DragAndDropSelfTestError.assertion("PR move did not preserve attachment identity and metadata")
        }

        let movedAttachmentPayload = SurfaceDragPayload(
            origin: .attachment,
            surfaceID: attachment.surfaceID,
            sourceSetID: destinationSet.id,
            itemID: attachment.id
        )
        let beforeSameSetAttachmentDrop = model.sets
        guard model.acceptSurfaceDrop(movedAttachmentPayload, onto: destinationSet.id, role: .pr),
              model.sets == beforeSameSetAttachmentDrop else {
            throw DragAndDropSelfTestError.assertion("same-set PR drop unexpectedly mutated data")
        }

        guard model.acceptUnlinkDrop(movedAttachmentPayload),
              model.sets[1].attachments.isEmpty else {
            throw DragAndDropSelfTestError.assertion("PR unlink failed")
        }

        let beforeRejectedUnlink = model.sets
        let unlinkedSurfacePayload = SurfaceDragPayload(
            origin: .liveSurface,
            surfaceID: "already-unlinked",
            sourceSetID: nil,
            itemID: nil
        )
        guard !model.acceptUnlinkDrop(unlinkedSurfacePayload),
              !model.acceptUnlinkDrop(movedMemberPayload),
              model.sets == beforeRejectedUnlink else {
            throw DragAndDropSelfTestError.assertion("invalid unlink changed persisted associations")
        }

        let restored = try store.load()
        guard restored.sets[0].members.isEmpty,
              restored.sets[0].attachments.isEmpty,
              restored.sets[1].members.isEmpty,
              restored.sets[1].attachments.isEmpty else {
            throw DragAndDropSelfTestError.assertion("drag mutations were not persisted")
        }

        let failingStoreURL = root.appendingPathComponent("failing-sets.json")
        let failingStore = CompanionStore(url: failingStoreURL)
        try failingStore.save(CompanionSnapshot(sets: [sourceSet, destinationSet]))
        let failingPreferencesName = "dev.cmuxcompanion.selftest.failing-store.\(UUID().uuidString)"
        guard let failingPreferences = UserDefaults(suiteName: failingPreferencesName) else {
            throw DragAndDropSelfTestError.assertion(
                "could not create isolated failing-store preferences"
            )
        }
        failingPreferences.removePersistentDomain(forName: failingPreferencesName)
        defer { failingPreferences.removePersistentDomain(forName: failingPreferencesName) }
        let failingModel = CompanionAppModel(
            store: failingStore,
            inbox: CommandInbox(directoryURL: root.appendingPathComponent("failing-commands")),
            preferences: failingPreferences
        )
        guard failingModel.setSetCollapsed(sourceSet.id, collapsed: true),
              failingModel.isSetCollapsed(sourceSet.id) else {
            throw DragAndDropSelfTestError.assertion(
                "could not prepare a collapsed set for failing-store deletion"
            )
        }
        let unchangedCollapsedPreferences = failingPreferences.stringArray(
            forKey: "collapsedWorkSetIDs"
        )
        try FileManager.default.removeItem(at: failingStoreURL)
        try FileManager.default.createDirectory(
            at: failingStoreURL,
            withIntermediateDirectories: false
        )
        let unchangedSets = failingModel.sets

        failingModel.deleteSet(sourceSet.id)
        guard failingModel.sets == unchangedSets,
              failingModel.isSetCollapsed(sourceSet.id),
              failingPreferences.stringArray(forKey: "collapsedWorkSetIDs")
                == unchangedCollapsedPreferences,
              failingModel.lastError?.contains("세트를 삭제하지 못했습니다") == true else {
            throw DragAndDropSelfTestError.assertion(
                "failed set deletion changed sets or collapsed preferences"
            )
        }

        guard !failingModel.createSet(named: "Must not appear"),
              failingModel.sets == unchangedSets,
              failingModel.lastError?.contains("세트를 생성하지 못했습니다") == true else {
            throw DragAndDropSelfTestError.assertion(
                "failed Dashboard set creation was not rolled back atomically"
            )
        }

        guard !failingModel.acceptSurfaceDrop(
            movedMember,
            onto: destinationSet.id,
            role: .reviewer,
            targetGroupID: targetGroup.id
        ), failingModel.sets == unchangedSets else {
            throw DragAndDropSelfTestError.assertion("failed member-move save was not rolled back")
        }
        guard !failingModel.acceptSurfaceDrop(
            attachmentPayload,
            onto: destinationSet.id,
            role: .pr
        ), failingModel.sets == unchangedSets else {
            throw DragAndDropSelfTestError.assertion("failed PR-move save was not rolled back")
        }
        let sourceMemberPayload = SurfaceDragPayload(
            origin: .member,
            surfaceID: member.surfaceID,
            sourceSetID: sourceSet.id,
            itemID: member.id
        )
        guard !failingModel.acceptUnlinkDrop(sourceMemberPayload),
              failingModel.sets == unchangedSets,
              failingModel.lastError?.contains("저장하지 못했습니다") == true else {
            throw DragAndDropSelfTestError.assertion("failed unlink save was not rolled back")
        }

        guard !failingModel.moveSet(sourceSet.id, relativeTo: destinationSet.id),
              failingModel.sets == unchangedSets,
              failingModel.lastError?.contains("세트 순서를 변경하지 못했습니다") == true else {
            throw DragAndDropSelfTestError.assertion(
                "failed relative set reorder was not rolled back atomically"
            )
        }
        guard !failingModel.moveSet(sourceSet.id, by: 1),
              failingModel.sets == unchangedSets,
              failingModel.lastError?.contains("세트 순서를 변경하지 못했습니다") == true else {
            throw DragAndDropSelfTestError.assertion(
                "failed adjacent set reorder was not rolled back atomically"
            )
        }
    }

    @MainActor
    private static func verifySetPreferencesAndOrdering(root: URL) throws {
        let suiteName = "dev.cmuxcompanion.selftest.set-presentation.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            throw DragAndDropSelfTestError.assertion(
                "could not create isolated set-presentation preferences"
            )
        }
        preferences.removePersistentDomain(forName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let first = WorkSet(label: "A", color: "#FF3B30")
        let second = WorkSet(label: "B", color: "#34C759")
        let third = WorkSet(label: "C", color: "#0A84FF")
        let canonicalSets = [first, second, third]
        let storeURL = root.appendingPathComponent("set-presentation-sets.json")
        let store = CompanionStore(url: storeURL)
        try store.save(CompanionSnapshot(sets: canonicalSets))
        let workSetDataBeforeCollapse = try Data(contentsOf: storeURL)

        let model = CompanionAppModel(
            store: store,
            inbox: CommandInbox(
                directoryURL: root.appendingPathComponent(
                    "set-presentation-commands",
                    isDirectory: true
                )
            ),
            preferences: preferences
        )
        guard !model.isSetCollapsed(first.id),
              !model.isSetCollapsed(second.id),
              model.setSetCollapsed(first.id, collapsed: true),
              model.setSetCollapsed(second.id, collapsed: true),
              model.isSetCollapsed(first.id),
              model.isSetCollapsed(second.id),
              !model.setSetCollapsed(UUID(), collapsed: true),
              try Data(contentsOf: storeURL) == workSetDataBeforeCollapse else {
            throw DragAndDropSelfTestError.assertion(
                "set collapse preferences were not shared or changed sets.json"
            )
        }

        let collapsedPreferencesBeforeReadOnlyLaunch = preferences.stringArray(
            forKey: "collapsedWorkSetIDs"
        )
        let unreadableStoreURL = root.appendingPathComponent("unreadable-presentation-sets.json")
        try Data(#"{"schemaVersion":99,"sets":[]}"#.utf8).write(to: unreadableStoreURL)
        let readOnlyModel = CompanionAppModel(
            store: CompanionStore(url: unreadableStoreURL),
            inbox: CommandInbox(
                directoryURL: root.appendingPathComponent(
                    "read-only-set-presentation-commands",
                    isDirectory: true
                )
            ),
            preferences: preferences
        )
        guard readOnlyModel.sets.isEmpty,
              readOnlyModel.lastError?.contains("읽지 못해") == true,
              readOnlyModel.isSetCollapsed(first.id),
              readOnlyModel.isSetCollapsed(second.id),
              preferences.stringArray(forKey: "collapsedWorkSetIDs")
                == collapsedPreferencesBeforeReadOnlyLaunch else {
            throw DragAndDropSelfTestError.assertion(
                "read-only store recovery erased collapsed set preferences"
            )
        }

        guard let restoredPreferences = UserDefaults(suiteName: suiteName) else {
            throw DragAndDropSelfTestError.assertion(
                "could not reopen isolated set-presentation preferences"
            )
        }
        let restoredModel = CompanionAppModel(
            store: store,
            inbox: CommandInbox(
                directoryURL: root.appendingPathComponent(
                    "restored-set-presentation-commands",
                    isDirectory: true
                )
            ),
            preferences: restoredPreferences
        )
        guard restoredModel.isSetCollapsed(first.id),
              restoredModel.isSetCollapsed(second.id),
              !restoredModel.isSetCollapsed(third.id) else {
            throw DragAndDropSelfTestError.assertion(
                "set collapse preferences did not survive model recreation"
            )
        }

        restoredModel.deleteSet(first.id)
        guard !restoredModel.isSetCollapsed(first.id),
              restoredModel.isSetCollapsed(second.id) else {
            throw DragAndDropSelfTestError.assertion(
                "deleting a set did not remove only its collapsed preference"
            )
        }

        // Reintroducing the exact UUID exposes a stale preference that a
        // simple `sets.contains` guard could otherwise hide after deletion.
        try store.save(CompanionSnapshot(sets: canonicalSets))
        guard let cleanedPreferences = UserDefaults(suiteName: suiteName) else {
            throw DragAndDropSelfTestError.assertion(
                "could not verify cleaned set-presentation preferences"
            )
        }
        let orderingModel = CompanionAppModel(
            store: store,
            inbox: CommandInbox(
                directoryURL: root.appendingPathComponent(
                    "set-ordering-commands",
                    isDirectory: true
                )
            ),
            preferences: cleanedPreferences
        )
        guard !orderingModel.isSetCollapsed(first.id),
              orderingModel.isSetCollapsed(second.id) else {
            throw DragAndDropSelfTestError.assertion(
                "a deleted set ID left a stale collapsed preference"
            )
        }

        func IDs(_ sets: [WorkSet]) -> [UUID] { sets.map(\.id) }
        func requireOrder(
            _ expected: [WorkSet],
            _ message: String
        ) throws {
            let expectedIDs = IDs(expected)
            guard IDs(orderingModel.sets) == expectedIDs,
                  IDs(try store.load().sets) == expectedIDs else {
                throw DragAndDropSelfTestError.assertion(message)
            }
        }

        guard orderingModel.moveSet(first.id, relativeTo: third.id) else {
            throw DragAndDropSelfTestError.assertion(
                "a forward relative set reorder was rejected"
            )
        }
        try requireOrder(
            [second, third, first],
            "a forward relative set reorder used the wrong insertion side or was not persisted"
        )

        guard orderingModel.moveSet(first.id, relativeTo: second.id) else {
            throw DragAndDropSelfTestError.assertion(
                "a backward relative set reorder was rejected"
            )
        }
        try requireOrder(
            canonicalSets,
            "a backward relative set reorder used the wrong insertion side or was not persisted"
        )

        guard orderingModel.moveSet(second.id, by: 1) else {
            throw DragAndDropSelfTestError.assertion(
                "a downward adjacent set reorder was rejected"
            )
        }
        try requireOrder(
            [first, third, second],
            "a downward adjacent set reorder was not persisted"
        )
        guard orderingModel.moveSet(second.id, by: -1) else {
            throw DragAndDropSelfTestError.assertion(
                "an upward adjacent set reorder was rejected"
            )
        }
        try requireOrder(
            canonicalSets,
            "an upward adjacent set reorder was not persisted"
        )

        let stableSets = orderingModel.sets
        let stableData = try Data(contentsOf: storeURL)
        let unknownID = UUID()
        guard orderingModel.moveSet(second.id, relativeTo: second.id),
              !orderingModel.moveSet(unknownID, relativeTo: first.id),
              !orderingModel.moveSet(first.id, relativeTo: unknownID),
              !orderingModel.moveSet(first.id, by: -1),
              !orderingModel.moveSet(third.id, by: 1),
              orderingModel.sets == stableSets,
              try Data(contentsOf: storeURL) == stableData else {
            throw DragAndDropSelfTestError.assertion(
                "self, invalid, or boundary set reorder changed canonical order"
            )
        }
        guard orderingModel.lastError?.hasPrefix(
            "세트 순서를 변경하지 못했습니다:"
        ) == true,
              orderingModel.moveSet(first.id, relativeTo: third.id),
              orderingModel.lastError == nil,
              orderingModel.moveSet(first.id, relativeTo: second.id),
              orderingModel.lastError == nil else {
            throw DragAndDropSelfTestError.assertion(
                "a successful set reorder did not clear its previous validation error"
            )
        }
        try requireOrder(
            canonicalSets,
            "clearing a set-order validation error changed the restored order"
        )

        let unrelatedConnectionFailure = CmuxSnapshotFailure(
            command: ["cmux", "tree"],
            error: NSError(
                domain: "CmuxCompanionSelfTest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unrelated synthetic connection failure"]
            )
        )
        orderingModel.applySnapshotForSelfTest(CmuxTransportSnapshot(
            tree: .failure(unrelatedConnectionFailure),
            sessions: .success(CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"{"sessions":[]}"#))),
            top: .success(CmuxTopSnapshot()),
            feed: .success(CmuxFeedSnapshot(raw: try CmuxJSON.decode(#"{"items":[]}"#))),
            notifications: .success(
                CmuxNotificationsSnapshot(raw: try CmuxJSON.decode(#"{"notifications":[]}"#))
            )
        ))
        let unrelatedConnectionError = orderingModel.lastError
        guard unrelatedConnectionError != nil,
              orderingModel.moveSet(first.id, relativeTo: third.id),
              orderingModel.lastError == unrelatedConnectionError,
              orderingModel.moveSet(first.id, relativeTo: second.id),
              orderingModel.lastError == unrelatedConnectionError else {
            throw DragAndDropSelfTestError.assertion(
                "a successful set reorder cleared an unrelated cmux error"
            )
        }
        try requireOrder(
            canonicalSets,
            "preserving an unrelated cmux error changed the restored set order"
        )

        guard let relaunchedPreferences = UserDefaults(suiteName: suiteName) else {
            throw DragAndDropSelfTestError.assertion(
                "could not reopen preferences for the reordered model"
            )
        }
        let relaunchedModel = CompanionAppModel(
            store: store,
            inbox: CommandInbox(
                directoryURL: root.appendingPathComponent(
                    "relaunched-set-ordering-commands",
                    isDirectory: true
                )
            ),
            preferences: relaunchedPreferences
        )
        guard IDs(relaunchedModel.sets) == IDs(canonicalSets),
              relaunchedModel.isSetCollapsed(second.id),
              !relaunchedModel.isSetCollapsed(first.id) else {
            throw DragAndDropSelfTestError.assertion(
                "set order or collapse preferences did not survive model recreation"
            )
        }
    }

    @MainActor
    private static func verifyDashboardWindow() throws {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_000, height: 700)
        let oversizedOffscreenFrame = NSRect(x: 2_000, y: -500, width: 1_400, height: 900)
        guard DashboardWindowMetrics.clampedFrame(
            oversizedOffscreenFrame,
            to: visibleFrame
        ) == visibleFrame,
              DashboardWindowMetrics.clampedFrame(
                NSRect(x: 1_000, y: 600, width: 400, height: 300),
                to: visibleFrame
              ) == NSRect(x: 700, y: 450, width: 400, height: 300),
              DashboardWindowMetrics.clampedFrame(
                oversizedOffscreenFrame,
                to: .zero
              ) == oversizedOffscreenFrame else {
            throw DragAndDropSelfTestError.assertion(
                "Dashboard restored frame was not clamped to the visible screen"
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-companion-dashboard-window-selftest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CompanionStore(url: root.appendingPathComponent("sets.json"))
        try store.save(CompanionSnapshot(sets: [WorkSet(label: "Dashboard")]))
        let model = CompanionAppModel(
            store: store,
            inbox: CommandInbox(
                directoryURL: root.appendingPathComponent("commands", isDirectory: true)
            )
        )
        let updater = AppUpdateController()
        let autosaveName = "CmuxCompanionDashboardWindow.selftest.\(UUID().uuidString)"
        let controller = DashboardWindowController(
            model: model,
            updater: updater,
            frameAutosaveName: autosaveName
        )
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)") }

        let requiredStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        guard controller.modelForTesting === model,
              controller.updaterForTesting === updater,
              controller.frameAutosaveNameForTesting == autosaveName,
              controller.minimumWindowSizeForTesting == DashboardWindowMetrics.minimumWindowSize,
              controller.supportsFullScreenForTesting,
              !controller.isReleasedWhenClosedForTesting,
              controller.window?.styleMask.contains(requiredStyle) == true,
              controller.window?.contentViewController is NSHostingController<DashboardRootView> else {
            throw DragAndDropSelfTestError.assertion(
                "Dashboard window did not preserve its shared model or standard window behavior"
            )
        }
    }

    @MainActor
    private static func verifyMenuBarLayout() throws {
        guard MenuBarStatusLayout.itemLength == 48,
              MenuBarStatusLayout.title(attentionCount: 0, updateAvailable: false).isEmpty,
              MenuBarStatusLayout.title(attentionCount: 1, updateAvailable: false) == " 1",
              MenuBarStatusLayout.title(attentionCount: 100, updateAvailable: false) == " 99",
              MenuBarStatusLayout.title(attentionCount: 0, updateAvailable: true) == " ↑" else {
            throw DragAndDropSelfTestError.assertion("menu bar popover anchor sizing is not stable")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-companion-menu-layout-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let monitoredSet = WorkSet(
            label: "Layout",
            groups: [WorkGroup(label: "Workers", role: .worker, required: true)]
        )
        let store = CompanionStore(url: root.appendingPathComponent("sets.json"))
        try store.save(CompanionSnapshot(sets: [monitoredSet]))
        let model = CompanionAppModel(
            store: store,
            inbox: CommandInbox(directoryURL: root.appendingPathComponent("commands", isDirectory: true))
        )
        let defaultsName = "cmux-companion-menu-layout-selftest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw DragAndDropSelfTestError.assertion("could not create isolated layout defaults")
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let layout = PopoverLayoutSettings(defaults: defaults)
        guard layout.size == PopoverLayoutMetrics.defaultSize,
              model.attentionCount == 0 else {
            throw DragAndDropSelfTestError.assertion("menu bar did not start with a fixed popover anchor")
        }

        layout.apply(.large)
        let restoredLayout = PopoverLayoutSettings(defaults: defaults)
        guard layout.size == PopoverSizePreset.large.size,
              restoredLayout.size == PopoverSizePreset.large.size,
              PopoverLayoutMetrics.clamped(width: -1, height: .infinity)
                == NSSize(
                    width: PopoverLayoutMetrics.minimumSize.width,
                    height: PopoverLayoutMetrics.defaultSize.height
                ) else {
            throw DragAndDropSelfTestError.assertion("popover size settings were not applied or restored safely")
        }

        let smallScreenSize = NSSize(width: 500, height: 600)
        layout.updateScreenMaximum(
            maximumWidth: smallScreenSize.width,
            maximumHeight: smallScreenSize.height
        )
        guard layout.size == smallScreenSize,
              layout.preferredSizeForTesting == PopoverSizePreset.large.size,
              PopoverLayoutSettings(defaults: defaults).size == PopoverSizePreset.large.size else {
            throw DragAndDropSelfTestError.assertion("screen clamping overwrote the preferred popover size")
        }
        layout.updateScreenMaximum(
            maximumWidth: PopoverLayoutMetrics.maximumSize.width,
            maximumHeight: PopoverLayoutMetrics.maximumSize.height
        )
        guard layout.size == PopoverSizePreset.large.size else {
            throw DragAndDropSelfTestError.assertion("popover preference did not restore on a larger screen")
        }

        model.arm(monitoredSet.id)
        guard model.attentionCount == 1 else {
            throw DragAndDropSelfTestError.assertion("arming monitoring changed the popover anchor width")
        }

        model.disarm(monitoredSet.id)
        guard model.attentionCount == 0 else {
            throw DragAndDropSelfTestError.assertion("disarming monitoring changed the popover anchor width")
        }
    }

    private static func verifyColorPalette() throws {
        let presets = CompanionColorPalette.presets
        let uniqueColors = Set(presets.map { $0.hex.uppercased() })
        let legacyColors: Set<String> = [
            "#0A84FF", "#BF5AF2", "#30D158", "#FF9F0A", "#FF375F", "#64D2FF", "#FFD60A"
        ]
        let roundTripSet = WorkSet(label: "Color", color: "#12ABEF")
        let roundTripData = try JSONEncoder().encode(roundTripSet)
        let decodedSet = try JSONDecoder().decode(WorkSet.self, from: roundTripData)
        guard presets.count >= 16,
              uniqueColors.count == presets.count,
              legacyColors.isSubset(of: uniqueColors),
              presets.allSatisfy({ $0.hex.range(of: #"^#[0-9A-F]{6}$"#, options: .regularExpression) != nil }),
              CompanionHexColor.canonicalize("#12abef") == "#12ABEF",
              CompanionHexColor.canonicalize("0af") == "#00AAFF",
              CompanionHexColor.canonicalize("blue") == "#0A84FF",
              CompanionHexColor.canonicalize("red") == "#FF453A",
              CompanionHexColor.canonicalize("GGGGGG") == nil,
              CompanionHexColor.canonicalize("red!") == nil,
              Color(companionHex: "#000000").companionHexString == "#000000",
              Color(companionHex: "#FFFFFF").companionHexString == "#FFFFFF",
              Color(companionHex: "#808080").companionHexString == "#808080",
              Color(companionHex: "#12ABEF").companionHexString == "#12ABEF",
              decodedSet.color == "#12ABEF" else {
            throw DragAndDropSelfTestError.assertion("color palette or hex conversion is invalid")
        }
    }

    private static func verifySearch() throws {
        let linkedSurface = LiveSurface(
            id: "linked-surface",
            windowID: "window",
            workspaceID: "workspace",
            workspaceTitle: "Büild Workspace",
            title: "ＡＰＩ shell",
            kind: "terminal",
            url: nil,
            agent: "codex",
            sessionID: "linked-session",
            runtimeState: .running,
            lastSubmittedText: nil,
            lastSubmittedAt: nil,
            displayOnlyPromptText: nil,
            displayOnlyPromptAt: nil,
            isRemote: false,
            workload: .codex
        )
        let unlinkedSurface = LiveSurface(
            id: "unlinked-surface",
            windowID: "window",
            workspaceID: "production",
            workspaceTitle: "Production",
            title: "review-shell",
            kind: "terminal",
            url: nil,
            agent: "claude",
            sessionID: "unlinked-session",
            runtimeState: .running,
            lastSubmittedText: nil,
            lastSubmittedAt: nil,
            displayOnlyPromptText: nil,
            displayOnlyPromptAt: nil,
            isRemote: true,
            workload: .claude
        )
        let otherUnlinkedSurface = LiveSurface(
            id: "other-unlinked-surface",
            windowID: "window",
            workspaceID: "staging",
            workspaceTitle: "Staging",
            title: "misc-shell",
            kind: "terminal",
            url: nil,
            agent: nil,
            sessionID: nil,
            runtimeState: .idle,
            lastSubmittedText: nil,
            lastSubmittedAt: nil,
            displayOnlyPromptText: nil,
            displayOnlyPromptAt: nil,
            isRemote: false,
            workload: .shell
        )
        let member = WorkMember(
            label: "main worker",
            role: .worker,
            sessionID: linkedSurface.sessionID,
            surfaceID: linkedSurface.id,
            runtimeState: .running
        )
        let group = WorkGroup(
            label: "Réview Team",
            role: .worker,
            memberIDs: [member.id]
        )
        let set = WorkSet(label: "PR-142", groups: [group], members: [member])
        let destinationSet = WorkSet(label: "Destination")
        let sets = [set, destinationSet]
        let unlinkedSurfaces = [unlinkedSurface, otherUnlinkedSurface]
        let allSurfaces = [linkedSurface] + unlinkedSurfaces

        let shellResults = CompanionSearch.results(
            sets: sets,
            unlinkedSurfaces: unlinkedSurfaces,
            allLiveSurfaces: allSurfaces,
            query: "production CLAUDE"
        )
        let setResults = CompanionSearch.results(
            sets: sets,
            unlinkedSurfaces: unlinkedSurfaces,
            allLiveSurfaces: allSurfaces,
            query: "review build api"
        )
        let destinationResults = CompanionSearch.results(
            sets: sets,
            unlinkedSurfaces: unlinkedSurfaces,
            allLiveSurfaces: allSurfaces,
            query: "destination"
        )
        let dualResults = CompanionSearch.results(
            sets: sets,
            unlinkedSurfaces: unlinkedSurfaces,
            allLiveSurfaces: allSurfaces,
            query: "review"
        )
        let emptyResults = CompanionSearch.results(
            sets: sets,
            unlinkedSurfaces: unlinkedSurfaces,
            allLiveSurfaces: allSurfaces,
            query: "missing-value"
        )
        let unfilteredResults = CompanionSearch.results(
            sets: sets,
            unlinkedSurfaces: unlinkedSurfaces,
            allLiveSurfaces: allSurfaces,
            query: "   "
        )

        guard shellResults.sets == sets,
              shellResults.unlinkedSurfaces == [unlinkedSurface],
              shellResults.matchingSetIDs.isEmpty,
              setResults.sets == sets,
              setResults.unlinkedSurfaces == unlinkedSurfaces,
              setResults.matchingSetIDs == [set.id],
              destinationResults.sets == [destinationSet, set],
              Set(destinationResults.sets.map(\.id)) == Set(sets.map(\.id)),
              destinationResults.unlinkedSurfaces == unlinkedSurfaces,
              dualResults.sets == sets,
              dualResults.unlinkedSurfaces == [unlinkedSurface],
              emptyResults.sets.isEmpty,
              emptyResults.unlinkedSurfaces.isEmpty,
              !emptyResults.hasAnyMatch,
              unfilteredResults.sets == sets,
              unfilteredResults.unlinkedSurfaces == unlinkedSurfaces,
              !unfilteredResults.isActive else {
            throw DragAndDropSelfTestError.assertion(
                "workspace, group, and shell search did not preserve drag targets"
            )
        }
    }

    private static func verifyRemoteLiveSurfaceOverlay() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let base = LiveSurface(
            id: "remote-surface",
            windowID: "window",
            workspaceID: "workspace",
            workspaceTitle: "Remote workspace",
            title: "remote shell",
            kind: "terminal",
            url: nil,
            agent: nil,
            sessionID: nil,
            runtimeState: .unknown,
            lastSubmittedText: nil,
            lastSubmittedAt: nil,
            displayOnlyPromptText: nil,
            displayOnlyPromptAt: nil,
            isRemote: false,
            workload: .shell
        )
        let promptDate = now.addingTimeInterval(-2)
        let runningCodex = RemoteEventState(
            sessionID: "cmux-remote:remote-surface:codex-session",
            source: "codex",
            surfaceID: base.id,
            workspaceID: base.workspaceID,
            runtimeState: .running,
            lastSubmittedText: "review PR 142",
            lastSubmittedAt: promptDate,
            order: CmuxRemoteEventOrder(bootID: "boot", sequence: 1),
            receivedAt: now,
            lastSeenAt: now
        )

        let overlaid = RemoteLiveSurfaceOverlay.apply(
            runningCodex,
            to: base,
            hasAuthoritativeCurrentSession: false,
            now: now
        )
        guard overlaid.agent == "codex",
              overlaid.sessionID == runningCodex.sessionID,
              overlaid.runtimeState == .running,
              overlaid.lastSubmittedText == "review PR 142",
              overlaid.lastSubmittedAt == promptDate,
              overlaid.isRemote,
              overlaid.workload == .codex else {
            throw DragAndDropSelfTestError.assertion(
                "remote event did not enrich an unlinked live surface"
            )
        }

        var localClaude = base
        localClaude.agent = "claude"
        localClaude.sessionID = "local-claude-session"
        localClaude.runtimeState = .waiting
        localClaude.workload = .claude
        let localWinner = RemoteLiveSurfaceOverlay.apply(
            runningCodex,
            to: localClaude,
            hasAuthoritativeCurrentSession: true,
            now: now
        )
        guard localWinner == localClaude else {
            throw DragAndDropSelfTestError.assertion(
                "remote event replaced a current local agent session"
            )
        }

        let newerRemoteWinner = RemoteLiveSurfaceOverlay.apply(
            runningCodex,
            to: localClaude,
            hasAuthoritativeCurrentSession: false,
            hasCachedCurrentSession: true,
            cachedCurrentSessionUpdatedAt: now.addingTimeInterval(-1),
            now: now
        )
        guard newerRemoteWinner.workload == .codex,
              newerRemoteWinner.sessionID == runningCodex.sessionID,
              newerRemoteWinner.isRemote else {
            throw DragAndDropSelfTestError.assertion(
                "newer remote telemetry did not replace an older cached local session"
            )
        }

        let newerCachedLocalWinner = RemoteLiveSurfaceOverlay.apply(
            runningCodex,
            to: localClaude,
            hasAuthoritativeCurrentSession: false,
            hasCachedCurrentSession: true,
            cachedCurrentSessionUpdatedAt: now.addingTimeInterval(1),
            now: now
        )
        let undatedCachedLocalWinner = RemoteLiveSurfaceOverlay.apply(
            runningCodex,
            to: localClaude,
            hasAuthoritativeCurrentSession: false,
            hasCachedCurrentSession: true,
            cachedCurrentSessionUpdatedAt: nil,
            now: now
        )
        guard newerCachedLocalWinner == localClaude,
              undatedCachedLocalWinner == localClaude else {
            throw DragAndDropSelfTestError.assertion(
                "stale or undated remote telemetry replaced a cached local session"
            )
        }

        let freshProcessWinner = RemoteLiveSurfaceOverlay.apply(
            runningCodex,
            to: localClaude,
            hasAuthoritativeCurrentSession: false,
            hasFreshLocalAgentProcess: true,
            now: now
        )
        guard freshProcessWinner == localClaude else {
            throw DragAndDropSelfTestError.assertion(
                "stale remote telemetry replaced fresh local process evidence"
            )
        }

        var expiredIdle = runningCodex
        expiredIdle.runtimeState = .idle
        expiredIdle.lastSeenAt = now.addingTimeInterval(
            -CmuxRemoteLifecycle.defaultDisconnectedAfter - 1
        )
        let expiredIdentity = RemoteLiveSurfaceOverlay.apply(
            expiredIdle,
            to: base,
            hasAuthoritativeCurrentSession: false,
            now: now
        )
        guard expiredIdentity == base else {
            throw DragAndDropSelfTestError.assertion(
                "expired remote identity remained stuck on an unlinked shell"
            )
        }

        var endedCodex = runningCodex
        endedCodex.runtimeState = .ended
        endedCodex.lastSubmittedText = "final remote prompt"
        let returnedToShell = RemoteLiveSurfaceOverlay.apply(
            endedCodex,
            to: base,
            hasAuthoritativeCurrentSession: false,
            now: now
        )
        guard returnedToShell.workload == .shell,
              returnedToShell.runtimeState == .ended,
              returnedToShell.agent == "codex",
              returnedToShell.sessionID == endedCodex.sessionID,
              returnedToShell.lastSubmittedText == "final remote prompt",
              returnedToShell.isRemote else {
            throw DragAndDropSelfTestError.assertion(
                "remote SessionEnd did not return the live terminal to Shell"
            )
        }

        var refObservation = runningCodex
        refObservation.surfaceID = "surface:1"
        refObservation.workspaceID = "workspace:1"
        var canonicalLive = base
        canonicalLive.ref = "surface:1"
        canonicalLive.workspaceID = "workspace-uuid"
        let refMember = WorkMember(
            label: "remote",
            role: .worker,
            sessionID: "old-session",
            surfaceID: "surface:1"
        )
        let canonicalMember = RemoteMemberTopology.apply(
            refObservation,
            to: refMember,
            liveSurface: canonicalLive
        )
        let fallbackMember = RemoteMemberTopology.apply(
            refObservation,
            to: refMember,
            liveSurface: nil
        )
        guard canonicalMember.surfaceID == canonicalLive.id,
              canonicalMember.workspaceID == canonicalLive.workspaceID,
              fallbackMember.surfaceID == "surface:1",
              fallbackMember.workspaceID == "workspace:1" else {
            throw DragAndDropSelfTestError.assertion(
                "remote short refs displaced canonical live surface identity"
            )
        }

        let admissionPayload = try CmuxJSON.decode(
            #"{"_opencode_request_id":"cmux-companion-seq:boot:1:event"}"#
        )
        guard let admissionIdentity = CmuxRemoteEventIdentity(
            sessionID: "cmux-remote:v2:surface%3A1:session",
            payload: admissionPayload
        ),
              RemoteEventAdmission.source(" Codex ") == "codex",
              RemoteEventAdmission.source("shell") == nil,
              RemoteEventAdmission.surfaceID(
                identity: admissionIdentity,
                frameSurfaceID: "surface:1",
                payloadSurfaceID: "surface:1"
              ) == "surface:1",
              RemoteEventAdmission.surfaceID(
                identity: admissionIdentity,
                frameSurfaceID: "surface:1",
                payloadSurfaceID: "surface:2"
              ) == nil,
              RemoteEventAdmission.surfaceID(
                identity: admissionIdentity,
                frameSurfaceID: "canonical-surface-uuid",
                payloadSurfaceID: "surface:1",
                knownSurfaceAliases: [["canonical-surface-uuid", "surface:1"]]
              ) == "canonical-surface-uuid",
              RemoteEventAdmission.surfaceID(
                identity: admissionIdentity,
                frameSurfaceID: "unknown-canonical-uuid",
                payloadSurfaceID: "surface:1",
                knownSurfaceAliases: []
              ) == nil else {
            throw DragAndDropSelfTestError.assertion(
                "unmanaged or surface-mismatched remote telemetry was admitted"
            )
        }

        let cache = Dictionary(uniqueKeysWithValues: (0..<300).map { index in
            let key = "session-\(index)"
            var state = runningCodex
            state.sessionID = key
            state.surfaceID = "surface:1"
            state.receivedAt = now.addingTimeInterval(-Double(index))
            return (key, state)
        })
        let boundedCache = RemoteEventCachePolicy.retained(cache, now: now)
        var expiredCache = cache
        var oldState = runningCodex
        oldState.sessionID = "expired"
        oldState.receivedAt = now.addingTimeInterval(-RemoteEventCachePolicy.maximumAge - 1)
        expiredCache[oldState.sessionID] = oldState
        var offSurfaceState = runningCodex
        offSurfaceState.sessionID = "off-surface"
        offSurfaceState.surfaceID = "surface:2"
        expiredCache[offSurfaceState.sessionID] = offSurfaceState
        let liveOnlyCache = RemoteEventCachePolicy.retained(
            expiredCache,
            now: now,
            liveSurfaceIDs: ["surface:1"]
        )
        let noLiveSurfaceCache = RemoteEventCachePolicy.retained(
            expiredCache,
            now: now,
            liveSurfaceIDs: []
        )
        guard boundedCache.count == RemoteEventCachePolicy.maximumEntries,
              boundedCache["session-0"] != nil,
              boundedCache["session-299"] == nil,
              liveOnlyCache["expired"] == nil,
              liveOnlyCache["off-surface"] == nil,
              liveOnlyCache.count == RemoteEventCachePolicy.maximumEntries,
              noLiveSurfaceCache.isEmpty else {
            throw DragAndDropSelfTestError.assertion(
                "remote event cache was not bounded, expired, and surface-scoped"
            )
        }

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-companion-remote-cache-selftest-\(UUID().uuidString)",
                isDirectory: true
            )
        let cacheURL = cacheRoot.appendingPathComponent("remote-events.json")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        var canonicalPersistedState = runningCodex
        canonicalPersistedState.surfaceID = "4202F9A9-C905-41D4-B126-6F8179F51783"
        var unsafeShortRefState = runningCodex
        unsafeShortRefState.sessionID = "short-ref-only"
        unsafeShortRefState.surfaceID = "surface:1"
        try RemoteEventCacheStore.save([
            canonicalPersistedState.sessionID: canonicalPersistedState,
            unsafeShortRefState.sessionID: unsafeShortRefState,
        ], to: cacheURL)
        let restoredCache = RemoteEventCacheStore.load(from: cacheURL, now: now)
        guard restoredCache[canonicalPersistedState.sessionID]?.source == "codex",
              restoredCache[canonicalPersistedState.sessionID]?.surfaceID
                == canonicalPersistedState.surfaceID,
              restoredCache[canonicalPersistedState.sessionID]?.lastSubmittedText == nil,
              restoredCache[unsafeShortRefState.sessionID] == nil else {
            throw DragAndDropSelfTestError.assertion(
                "remote identity cache was not restored without private prompt text"
            )
        }
    }

    @MainActor
    private static func verifyLocalTopRuntimeFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-companion-local-top-state-selftest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceID = "00000000-0000-0000-0000-000000000101"
        let surfaceID = "00000000-0000-0000-0000-000000000102"
        let tree = CmuxTreeSnapshot(raw: try CmuxJSON.decode(#"""
        {"windows":[{"id":"00000000-0000-0000-0000-000000000103","workspaces":[{"id":"\#(workspaceID)","title":"Local","panes":[{"id":"00000000-0000-0000-0000-000000000104","surfaces":[{"id":"\#(surfaceID)","type":"terminal","title":"Codex"}]}]}]}]}
        """#))
        let store = CompanionStore(url: root.appendingPathComponent("sets.json"))
        let trackedMember = WorkMember(
            label: "Codex",
            role: .worker,
            surfaceID: surfaceID
        )
        let trackedGroup = WorkGroup(
            label: "Worker",
            role: .worker,
            memberIDs: [trackedMember.id]
        )
        try store.save(CompanionSnapshot(sets: [
            WorkSet(
                label: "Local interaction",
                armed: true,
                groups: [trackedGroup],
                members: [trackedMember]
            )
        ]))
        let model = CompanionAppModel(
            store: store,
            inbox: CommandInbox(directoryURL: root.appendingPathComponent("commands", isDirectory: true))
        )
        var interactions: [PendingInteraction] = []
        model.onInteractionTransition = { interactions.append($0) }

        func snapshot(status: String) throws -> CmuxTransportSnapshot {
            let top = try CmuxTopSnapshot(tsv: [
                "0.1\t100\t1\ttag\t\(workspaceID):tag:codex\t\(workspaceID)\t\(status)",
                "0.1\t100\t2\ttag\t\(workspaceID):tag:codex.session-1\t\(workspaceID)\t",
                "0.1\t50\t1\tprocess\t41\t\(workspaceID):tag:codex.session-1\tnode",
                "0.1\t100\t3\tsurface\t\(surfaceID)\tpane-1\tCodex",
                "0.1\t50\t1\tprocess\t41\t\(surfaceID)\tnode",
                "0.1\t50\t1\tprocess\t42\t41\tcodex",
            ].joined(separator: "\n"))
            return CmuxTransportSnapshot(
                tree: .success(tree),
                sessions: .success(CmuxSessionsSnapshot(raw: try CmuxJSON.decode(#"{"sessions":[]}"#))),
                top: .success(top),
                feed: .success(CmuxFeedSnapshot(raw: try CmuxJSON.decode(#"{"items":[]}"#))),
                notifications: .success(
                    CmuxNotificationsSnapshot(raw: try CmuxJSON.decode(#"{"notifications":[]}"#))
                )
            )
        }

        model.applySnapshotForSelfTest(try snapshot(status: "Running"))
        guard model.liveSurfaces.count == 1,
              model.liveSurfaces[0].workload == .codex,
              model.liveSurfaces[0].runtimeState == .running else {
            throw DragAndDropSelfTestError.assertion(
                "local Codex top tag did not supply a running live-surface state"
            )
        }

        model.applySnapshotForSelfTest(try snapshot(status: "Idle"))
        guard model.liveSurfaces[0].runtimeState == .idle,
              interactions.map(\.kind) == [.completion] else {
            throw DragAndDropSelfTestError.assertion(
                "local Codex running-to-idle did not emit one completion interaction"
            )
        }

        model.applySnapshotForSelfTest(try snapshot(status: "Running"))
        model.applySnapshotForSelfTest(try snapshot(status: "Needs Input"))
        guard model.liveSurfaces[0].runtimeState == .waiting,
              interactions.map(\.kind) == [.completion, .inputRequired],
              interactions.last?.surfaceID == surfaceID else {
            throw DragAndDropSelfTestError.assertion(
                "local Codex waiting state did not emit one surface-correlated input interaction"
            )
        }
    }

    @MainActor
    private static func verifyRemoteEventPipeline() throws {
        let canonicalWorkspaceID = "84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A"
        let canonicalSurfaceID = "4202F9A9-C905-41D4-B126-6F8179F51783"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-companion-remote-pipeline-selftest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tree = CmuxTreeSnapshot(raw: try CmuxJSON.decode(#"""
        {"windows":[{"id":"00000000-0000-0000-0000-000000000001","ref":"window:1","workspaces":[{"id":"84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A","ref":"workspace:1","title":"Remote","panes":[{"id":"00000000-0000-0000-0000-000000000002","ref":"pane:1","surfaces":[{"id":"4202F9A9-C905-41D4-B126-6F8179F51783","ref":"surface:1","type":"terminal","title":"SSH shell"}]}]}]}]}
        """#))
        let top = try CmuxTopSnapshot(tsv: [
            "0.1\t100\t2\tsurface\t\(canonicalSurfaceID)\tpane:1\tSSH shell",
            "0.1\t100\t1\tprocess\t42\t\(canonicalSurfaceID)\tzsh",
        ].joined(separator: "\n"))

        func snapshot(sessionsJSON: String = #"{"sessions":[]}"#) throws -> CmuxTransportSnapshot {
            CmuxTransportSnapshot(
                tree: .success(tree),
                sessions: .success(CmuxSessionsSnapshot(raw: try CmuxJSON.decode(sessionsJSON))),
                top: .success(top),
                feed: .success(CmuxFeedSnapshot(raw: try CmuxJSON.decode(#"{"items":[]}"#))),
                notifications: .success(
                    CmuxNotificationsSnapshot(raw: try CmuxJSON.decode(#"{"notifications":[]}"#))
                ),
                loadedAt: Date()
            )
        }

        func event(
            hookName: String,
            source: String,
            sequence: Int64,
            nativeSession: String,
            prompt: String? = nil,
            frameUsesCanonicalSurface: Bool = true
        ) throws -> CmuxEventFrame {
            let wireHookName = hookName == "Heartbeat" ? "SessionStart" : hookName
            var payloadFields: [String: JSONValue] = [
                "session_id": .string(
                    "cmux-remote:v2:surface%3A1:\(nativeSession)"
                ),
                "hook_event_name": .string(wireHookName),
                "tool_name": .string("cmux-companion-remote-event:\(hookName)"),
                "_source": .string(source),
                "surface_id": .string("surface:1"),
                "workspace_id": .string("workspace:1"),
                "_opencode_request_id": .string(
                    "cmux-companion-seq:boot:\(sequence):event-\(sequence)"
                ),
            ]
            if let prompt {
                payloadFields["tool_input"] = .object(["prompt": .string(prompt)])
                payloadFields["context"] = .object(["lastUserMessage": .string(prompt)])
            }
            let payload: JSONValue = .object(payloadFields)
            var frameFields: [String: JSONValue] = [
                "type": .string("event"),
                "name": .string("agent.hook.\(wireHookName)"),
                "category": .string("agent"),
                "workspace_id": .string(canonicalWorkspaceID),
                "payload": payload,
            ]
            if frameUsesCanonicalSurface {
                frameFields["surface_id"] = .string(canonicalSurfaceID)
            }
            return try CmuxEventFrame(raw: .object(frameFields))
        }

        func model(member: WorkMember, name: String) throws -> CompanionAppModel {
            let store = CompanionStore(url: root.appendingPathComponent("\(name)-sets.json"))
            let group = WorkGroup(
                label: "Workers",
                role: member.role,
                memberIDs: [member.id]
            )
            try store.save(CompanionSnapshot(sets: [
                WorkSet(label: name, armed: true, groups: [group], members: [member]),
            ]))
            return CompanionAppModel(
                store: store,
                inbox: CommandInbox(
                    directoryURL: root.appendingPathComponent("\(name)-commands", isDirectory: true)
                )
            )
        }

        let linkedMember = WorkMember(
            label: "remote worker",
            role: .worker,
            surfaceID: canonicalSurfaceID,
            runtimeState: .unknown
        )
        let remoteModel = try model(member: linkedMember, name: "remote-alias")
        var remoteInteractions: [PendingInteraction] = []
        remoteModel.onInteractionTransition = { remoteInteractions.append($0) }
        // Match cold-start ordering: the event can be replayed from the cursor
        // before the first tree snapshot establishes UUID/ref aliases.
        remoteModel.captureRemoteEventForSelfTest(try event(
            hookName: "SessionStart",
            source: "codex",
            sequence: 1,
            nativeSession: "codex-session"
        ))
        remoteModel.applySnapshotForSelfTest(try snapshot())

        guard remoteModel.liveSurfaces.first?.isRemote == true,
              remoteModel.liveSurfaces.first?.workload == .codex,
              remoteModel.sets[0].members[0].isRemote,
              remoteModel.sets[0].members[0].agent == "codex",
              remoteModel.workload(for: remoteModel.sets[0].members[0]) == .codex else {
            throw DragAndDropSelfTestError.assertion(
                "canonical/ref remote event was not reconciled in one refresh"
            )
        }

        remoteModel.captureRemoteEventForSelfTest(try event(
            hookName: "UserPromptSubmit",
            source: "codex",
            sequence: 2,
            nativeSession: "codex-session",
            prompt: "review remote PR 142"
        ))
        remoteModel.applySnapshotForSelfTest(try snapshot())
        guard remoteModel.sets[0].members[0].lastSubmittedText == "review remote PR 142",
              remoteModel.promptPreview(for: remoteModel.sets[0].members[0])?.text
                == "review remote PR 142" else {
            throw DragAndDropSelfTestError.assertion(
                "nested remote prompt telemetry did not reach the member preview"
            )
        }

        remoteModel.captureRemoteEventForSelfTest(try event(
            hookName: "Heartbeat",
            source: "claude",
            sequence: 3,
            nativeSession: "unrelated-heartbeat"
        ))
        remoteModel.applySnapshotForSelfTest(try snapshot())
        guard remoteModel.sets[0].members[0].agent == "codex" else {
            throw DragAndDropSelfTestError.assertion(
                "a cross-agent heartbeat replaced the active remote agent"
            )
        }

        remoteModel.captureRemoteEventForSelfTest(try event(
            hookName: "PermissionRequest",
            source: "codex",
            sequence: 4,
            nativeSession: "codex-session"
        ))
        remoteModel.applySnapshotForSelfTest(try snapshot())
        guard remoteModel.sets[0].members[0].runtimeState == .waiting,
              remoteInteractions.map(\.kind) == [.inputRequired],
              remoteInteractions[0].isRemote else {
            throw DragAndDropSelfTestError.assertion(
                "remote permission telemetry did not emit one input interaction"
            )
        }

        remoteModel.captureRemoteEventForSelfTest(try event(
            hookName: "UserPromptSubmit",
            source: "codex",
            sequence: 5,
            nativeSession: "codex-session"
        ))
        remoteModel.applySnapshotForSelfTest(try snapshot())
        remoteModel.captureRemoteEventForSelfTest(try event(
            hookName: "Stop",
            source: "codex",
            sequence: 6,
            nativeSession: "codex-session"
        ))
        remoteModel.applySnapshotForSelfTest(try snapshot())
        guard remoteModel.sets[0].members[0].runtimeState == .idle,
              remoteInteractions.map(\.kind) == [.inputRequired, .completion] else {
            throw DragAndDropSelfTestError.assertion(
                "remote running-to-stop telemetry did not emit one completion interaction"
            )
        }

        remoteModel.captureRemoteEventForSelfTest(try event(
            hookName: "SessionEnd",
            source: "codex",
            sequence: 7,
            nativeSession: "codex-session"
        ))
        remoteModel.applySnapshotForSelfTest(try snapshot())
        guard remoteModel.sets[0].members[0].runtimeState == .ended,
              remoteModel.workload(for: remoteModel.sets[0].members[0]) == .shell,
              remoteModel.liveSurfaces.first?.workload == .shell else {
            throw DragAndDropSelfTestError.assertion(
                "remote SessionEnd did not return the linked surface to Shell"
            )
        }

        let heartbeatOnlyModel = try model(member: linkedMember, name: "heartbeat-only")
        heartbeatOnlyModel.applySnapshotForSelfTest(try snapshot())
        heartbeatOnlyModel.captureRemoteEventForSelfTest(try event(
            hookName: "Heartbeat",
            source: "codex",
            sequence: 1,
            nativeSession: "diagnostic-heartbeat"
        ))
        heartbeatOnlyModel.applySnapshotForSelfTest(try snapshot())
        guard heartbeatOnlyModel.liveSurfaces.first?.workload == .shell,
              !heartbeatOnlyModel.sets[0].members[0].isRemote else {
            throw DragAndDropSelfTestError.assertion(
                "a first diagnostic heartbeat mislabeled an SSH shell as Codex"
            )
        }

        var persistedCodexMember = linkedMember
        persistedCodexMember.sessionID = "cmux-remote:v2:surface%3A1:persisted-codex"
        persistedCodexMember.agent = "codex"
        persistedCodexMember.runtimeState = .running
        persistedCodexMember.lastHeartbeatAt = Date().addingTimeInterval(-30)
        persistedCodexMember.isRemote = true
        let persistedHeartbeatModel = try model(
            member: persistedCodexMember,
            name: "persisted-heartbeat"
        )
        persistedHeartbeatModel.captureRemoteEventForSelfTest(try event(
            hookName: "Heartbeat",
            source: "claude",
            sequence: 1,
            nativeSession: "unrelated-after-restart"
        ))
        persistedHeartbeatModel.applySnapshotForSelfTest(try snapshot())
        guard persistedHeartbeatModel.sets[0].members[0].isRemote,
              persistedHeartbeatModel.sets[0].members[0].agent == "codex" else {
            throw DragAndDropSelfTestError.assertion(
                "a post-restart heartbeat changed the persisted remote agent"
            )
        }

        let remoteSwitchModel = try model(
            member: persistedCodexMember,
            name: "remote-agent-switch"
        )
        remoteSwitchModel.captureRemoteEventForSelfTest(try event(
            hookName: "SessionStart",
            source: "codex",
            sequence: 1,
            nativeSession: "old-codex-session"
        ))
        let remoteClaudeUpdatedAt = Int(Date().addingTimeInterval(10).timeIntervalSince1970)
        let remoteClaudeSessions = #"""
        {"sessions":[{"session_id":"cmux-remote:v2:surface%3A1:claude-session","surface_id":"4202F9A9-C905-41D4-B126-6F8179F51783","workspace_id":"84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A","agent":"claude","agent_lifecycle":"waiting","active_for_surface":true,"updated_at_unix":\#(remoteClaudeUpdatedAt)}]}
        """#
        remoteSwitchModel.applySnapshotForSelfTest(try snapshot(
            sessionsJSON: remoteClaudeSessions
        ))
        guard remoteSwitchModel.liveSurfaces.first?.workload == .claude,
              remoteSwitchModel.liveSurfaces.first?.runtimeState == .waiting,
              remoteSwitchModel.sets[0].members[0].isRemote,
              remoteSwitchModel.sets[0].members[0].agent == "claude",
              remoteSwitchModel.sets[0].members[0].runtimeState == .waiting else {
            throw DragAndDropSelfTestError.assertion(
                "a newer remote Claude session did not replace stale Codex telemetry"
            )
        }
        remoteSwitchModel.captureRemoteEventForSelfTest(try event(
            hookName: "Heartbeat",
            source: "claude",
            sequence: 2,
            nativeSession: "claude-session"
        ))
        remoteSwitchModel.applySnapshotForSelfTest(try snapshot(
            sessionsJSON: remoteClaudeSessions
        ))
        guard remoteSwitchModel.sets[0].members[0].agent == "claude" else {
            throw DragAndDropSelfTestError.assertion(
                "the current remote agent changed after its heartbeat"
            )
        }

        let unlinkedStore = CompanionStore(
            url: root.appendingPathComponent("unlinked-agent-switch-sets.json")
        )
        try unlinkedStore.save(CompanionSnapshot(sets: []))
        let unlinkedSwitchModel = CompanionAppModel(
            store: unlinkedStore,
            inbox: CommandInbox(
                directoryURL: root.appendingPathComponent(
                    "unlinked-agent-switch-commands",
                    isDirectory: true
                )
            )
        )
        unlinkedSwitchModel.applySnapshotForSelfTest(try snapshot())
        unlinkedSwitchModel.captureRemoteEventForSelfTest(try event(
            hookName: "SessionStart",
            source: "codex",
            sequence: 1,
            nativeSession: "unlinked-old-codex"
        ))
        unlinkedSwitchModel.applySnapshotForSelfTest(try snapshot())
        guard unlinkedSwitchModel.liveSurfaces.first?.workload == .codex else {
            throw DragAndDropSelfTestError.assertion(
                "unlinked remote Codex telemetry did not reach the live surface"
            )
        }
        unlinkedSwitchModel.applySnapshotForSelfTest(try snapshot(
            sessionsJSON: remoteClaudeSessions
        ))
        guard unlinkedSwitchModel.liveSurfaces.first?.workload == .claude else {
            throw DragAndDropSelfTestError.assertion(
                "a newer remote Claude session did not replace unlinked Codex telemetry"
            )
        }
        unlinkedSwitchModel.applySnapshotForSelfTest(try snapshot())
        guard unlinkedSwitchModel.liveSurfaces.first?.workload == .shell else {
            throw DragAndDropSelfTestError.assertion(
                "stale unlinked Codex telemetry reappeared after the newer session ended"
            )
        }

        var sessionOnlyMember = linkedMember
        sessionOnlyMember.surfaceID = nil
        sessionOnlyMember.sessionID = "session-only-link"
        sessionOnlyMember.agent = "claude"
        let sessionOnlyModel = try model(
            member: sessionOnlyMember,
            name: "session-only-link"
        )
        let sessionOnlyUpdatedAt = Int(Date().timeIntervalSince1970)
        sessionOnlyModel.applySnapshotForSelfTest(try snapshot(sessionsJSON: #"""
        {"sessions":[{"session_id":"session-only-link","surface_id":"4202F9A9-C905-41D4-B126-6F8179F51783","workspace_id":"84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A","agent":"claude","agent_lifecycle":"running","active_for_surface":true,"updated_at_unix":\#(sessionOnlyUpdatedAt)}]}
        """#))
        guard let sessionOnlySurface = sessionOnlyModel.liveSurfaces.first,
              sessionOnlyModel.linkedSet(for: sessionOnlySurface)?.id
                == sessionOnlyModel.sets[0].id,
              sessionOnlyModel.unlinkedSurfaces.isEmpty else {
            throw DragAndDropSelfTestError.assertion(
                "a session-only linked terminal was also exposed as unlinked"
            )
        }

        let localWinnerModel = try model(member: linkedMember, name: "local-winner")
        localWinnerModel.applySnapshotForSelfTest(try snapshot())
        localWinnerModel.captureRemoteEventForSelfTest(try event(
            hookName: "SessionStart",
            source: "codex",
            sequence: 1,
            nativeSession: "remote-before-local",
            frameUsesCanonicalSurface: false
        ))
        let localUpdatedAt = Int(Date().addingTimeInterval(10).timeIntervalSince1970)
        localWinnerModel.applySnapshotForSelfTest(try snapshot(sessionsJSON: #"""
        {"sessions":[{"session_id":"local-claude","surface_id":"4202F9A9-C905-41D4-B126-6F8179F51783","workspace_id":"84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A","agent":"claude","agent_lifecycle":"running","active_for_surface":true,"updated_at_unix":\#(localUpdatedAt)}]}
        """#))
        guard localWinnerModel.liveSurfaces.first?.workload == .claude,
              !localWinnerModel.sets[0].members[0].isRemote,
              localWinnerModel.sets[0].members[0].agent == "claude" else {
            throw DragAndDropSelfTestError.assertion(
                "an authoritative local session did not beat remote telemetry"
            )
        }
        localWinnerModel.applySnapshotForSelfTest(try snapshot())
        guard localWinnerModel.liveSurfaces.first?.workload == .shell,
              localWinnerModel.workload(for: localWinnerModel.sets[0].members[0]) == .shell else {
            throw DragAndDropSelfTestError.assertion(
                "short-ref remote cache reappeared after local ownership ended"
            )
        }

        var expiredMember = linkedMember
        expiredMember.sessionID = "cmux-remote:v2:surface%3A1:expired"
        expiredMember.agent = "codex"
        expiredMember.runtimeState = .idle
        expiredMember.lastHeartbeatAt = Date().addingTimeInterval(
            -CmuxRemoteLifecycle.defaultDisconnectedAfter - 30
        )
        expiredMember.isRemote = true
        let expiredModel = try model(member: expiredMember, name: "expired-linked")
        expiredModel.captureRemoteEventForSelfTest(try event(
            hookName: "Heartbeat",
            source: "claude",
            sequence: 1,
            nativeSession: "expired-heartbeat"
        ))
        let expiredUpdatedAt = Int(
            Date().addingTimeInterval(
                -CmuxRemoteLifecycle.defaultDisconnectedAfter - 30
            ).timeIntervalSince1970
        )
        expiredModel.applySnapshotForSelfTest(try snapshot(sessionsJSON: #"""
        {"sessions":[{"session_id":"cmux-remote:v2:surface%3A1:expired","surface_id":"4202F9A9-C905-41D4-B126-6F8179F51783","workspace_id":"84EDB51C-13F9-490D-8B2B-2AE7DB1DBE0A","agent":"codex","agent_lifecycle":"idle","active_for_surface":true,"updated_at_unix":\#(expiredUpdatedAt)}]}
        """#))
        guard !expiredModel.sets[0].members[0].isRemote,
              expiredModel.sets[0].members[0].agent == nil,
              expiredModel.workload(for: expiredModel.sets[0].members[0]) == .shell,
              expiredModel.liveSurfaces.first?.workload == .shell else {
            throw DragAndDropSelfTestError.assertion(
                "an expired linked/session identity or heartbeat remained stuck on Codex"
            )
        }
    }

    @MainActor
    private static func verifyItemProviderRoundTrip() async throws {
        let expected = SurfaceDragPayload(
            origin: .liveSurface,
            surfaceID: "provider-selftest-surface",
            sourceSetID: nil,
            itemID: nil
        )
        let (stream, continuation) = AsyncStream.makeStream(of: SurfaceDragPayload.self)
        let accepted = SurfaceDragTransport.receiveOne(
            from: [SurfaceDragTransport.provider(for: expected)]
        ) { payload in
            continuation.yield(payload)
            continuation.finish()
        }
        guard accepted else {
            continuation.finish()
            throw DragAndDropSelfTestError.assertion("item provider did not advertise the drag type")
        }

        // Finishing the stream makes the timeout truly bounded. A cancelled
        // task-group consumer can remain suspended in `for await` when an
        // unbundled AppKit process never receives the item-provider callback.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            continuation.finish()
        }
        var received: SurfaceDragPayload?
        for await payload in stream {
            received = payload
            break
        }
        guard received == expected else {
            throw DragAndDropSelfTestError.assertion("item provider did not deliver its drag token")
        }
    }
}
