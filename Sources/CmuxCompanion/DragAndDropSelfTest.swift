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
        try verifyColorPalette()
        guard SurfaceDragTransport.selfTest() else {
            throw DragAndDropSelfTestError.assertion("drag transport token round-trip failed")
        }
        try await verifyItemProviderRoundTrip()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-companion-dnd-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

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
        let failingModel = CompanionAppModel(
            store: failingStore,
            inbox: CommandInbox(directoryURL: root.appendingPathComponent("failing-commands"))
        )
        try FileManager.default.removeItem(at: failingStoreURL)
        try FileManager.default.createDirectory(
            at: failingStoreURL,
            withIntermediateDirectories: false
        )
        let unchangedSets = failingModel.sets

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

        let received = await withTaskGroup(of: SurfaceDragPayload?.self) { group in
            group.addTask {
                for await payload in stream { return payload }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        continuation.finish()
        guard received == expected else {
            throw DragAndDropSelfTestError.assertion("item provider did not deliver its drag token")
        }
    }
}
