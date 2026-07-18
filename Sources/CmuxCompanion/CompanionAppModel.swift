import AppKit
import Combine
import Foundation
import CmuxCompanionCore

struct LiveSurface: Identifiable, Equatable {
    let id: String
    var windowID: String?
    var workspaceID: String?
    var workspaceTitle: String
    var title: String
    var kind: String
    var url: URL?
    var agent: String?
    var sessionID: String?
    var runtimeState: MemberRuntimeState
    var lastSubmittedText: String?
    var lastSubmittedAt: Date?
    var displayOnlyPromptText: String?
    var displayOnlyPromptAt: Date?
    var isRemote: Bool
    var workload: SurfaceWorkload

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let agent, !agent.isEmpty { return agent }
        return kind.capitalized
    }

    var isBrowser: Bool { kind.lowercased() == "browser" }
}

enum HookSetupFeedbackKind: Equatable {
    case success
    case failure
}

struct HookSetupFeedback: Equatable {
    let kind: HookSetupFeedbackKind
    let title: String
    let detail: String
}

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published private(set) var sets: [WorkSet] = []
    @Published private(set) var evaluations: [UUID: SetEvaluation] = [:]
    @Published private(set) var liveSurfaces: [LiveSurface] = []
    @Published private(set) var isCmuxConnected = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var conflictingSetName: String?
    @Published private(set) var hookSetupFeedback: HookSetupFeedback?
    @Published private(set) var isInstallingHooks = false
    @Published var newSetName = ""
    @Published var showPet: Bool {
        didSet { UserDefaults.standard.set(showPet, forKey: Self.showPetKey) }
    }
    @Published var showPromptPreview: Bool {
        didSet { UserDefaults.standard.set(showPromptPreview, forKey: Self.showPromptPreviewKey) }
    }

    var onEvaluationsChanged: (([WorkSet], [UUID: SetEvaluation]) -> Void)?
    var onAttentionTransition: ((WorkSet, SetEvaluation, SetEvaluation?) -> Void)?
    var onPetVisibilityChanged: ((Bool) -> Void)?

    private static let showPetKey = "showFloatingPet"
    private static let showPromptPreviewKey = "showPromptPreview"
    private let store: CompanionStore
    private let inbox: CommandInbox
    private var loader: CmuxSnapshotLoader?
    private var commandClient: CmuxCommandClient?
    private var eventStream: CmuxEventStream?
    private var refreshTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var refreshRequested = false
    private var started = false
    private var previousEvaluations: [UUID: SetEvaluation] = [:]
    private var lastNotificationFingerprints: [UUID: NotificationFingerprint] = [:]
    private var lastEventByRemoteSession: [String: RemoteEventState] = [:]
    private var transcriptCache: [String: TranscriptCacheEntry] = [:]
    private var lastGoodTree: CmuxTreeSnapshot?
    private var lastGoodSessions: [CmuxTransportSession] = []
    private var lastGoodFeedItems: [CmuxTransportFeedItem] = []
    private var hasGoodSessionsSnapshot = false
    private var hasGoodFeedSnapshot = false
    private var degradedSnapshotSince: Date?
    private var hasAuthoritativeRefresh = false
    private var storeLoadFailureMessage: String?
    private let dateParser = FlexibleDateParser()
    private let degradedSnapshotGrace: TimeInterval = 30

    init(
        store: CompanionStore = CompanionStore(),
        inbox: CommandInbox = CommandInbox()
    ) {
        self.store = store
        self.inbox = inbox
        self.showPet = UserDefaults.standard.object(forKey: Self.showPetKey) as? Bool ?? true
        self.showPromptPreview = UserDefaults.standard.object(forKey: Self.showPromptPreviewKey) as? Bool ?? true

        do {
            sets = try store.load().sets
        } catch {
            let message = "저장된 세트를 읽지 못해 원본 보호를 위한 읽기 전용 모드로 시작했습니다. \(store.url.path)을 복구한 뒤 앱을 재시작하세요: \(error.localizedDescription)"
            storeLoadFailureMessage = message
            lastError = message
        }

        do {
            let runner = try CmuxProcessRunner()
            loader = CmuxSnapshotLoader(runner: runner)
            commandClient = CmuxCommandClient(runner: runner)
            eventStream = CmuxEventStream(runner: runner)
        } catch {
            lastError = storeLoadFailureMessage ?? error.localizedDescription
        }
        recalculateEvaluations(notifyTransitions: false)
    }

    deinit {
        refreshTask?.cancel()
        eventTask?.cancel()
        commandTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        startEventStream()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        commandTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drainInbox()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    func stop() {
        started = false
        refreshTask?.cancel()
        eventTask?.cancel()
        commandTask?.cancel()
        refreshTask = nil
        eventTask = nil
        commandTask = nil
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        guard let loader else {
            isCmuxConnected = false
            return
        }

        isRefreshing = true
        refreshRequested = false
        let snapshot = await loader.load()
        apply(snapshot)
        isRefreshing = false

        if refreshRequested {
            refreshRequested = false
            await refresh()
        }
    }

    @discardableResult
    func createSet() -> Bool {
        guard ensureStoreWritable() else { return false }
        let label = newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        if let existingName = existingSetName(matching: label) {
            conflictingSetName = existingName
            return false
        }
        sets.append(WorkSet(label: label, color: paletteColor(for: sets.count)))
        newSetName = ""
        conflictingSetName = nil
        persistAndEvaluate()
        return true
    }

    func deleteSet(_ setID: UUID) {
        guard ensureStoreWritable() else { return }
        sets.removeAll { $0.id == setID }
        persistAndEvaluate()
    }

    @discardableResult
    func renameSet(_ setID: UUID, to label: String) -> Bool {
        guard ensureStoreWritable() else { return false }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sets.firstIndex(where: { $0.id == setID }) else { return false }
        if let existingName = existingSetName(matching: trimmed, excluding: setID) {
            conflictingSetName = existingName
            return false
        }
        sets[index].label = trimmed
        conflictingSetName = nil
        persistAndEvaluate()
        return true
    }

    func existingSetName(matching label: String, excluding setID: UUID? = nil) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return sets.first(where: {
            $0.id != setID
                && $0.label.compare(
                    trimmed,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        })?.label
    }

    func setColor(_ setID: UUID, color: String) {
        guard ensureStoreWritable() else { return }
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].color = color
        persistAndEvaluate()
    }

    func add(surface: LiveSurface, to setID: UUID, role: MemberRole, required: Bool? = nil) {
        _ = acceptSurfaceDrop(
            SurfaceDragPayload(
                origin: .liveSurface,
                surfaceID: surface.id,
                sourceSetID: nil,
                itemID: nil
            ),
            onto: setID,
            role: role,
            required: required
        )
    }

    /// Applies an in-app drag without putting member metadata on the system
    /// pasteboard. The same pure join reducer used by `cmux-set` owns identity
    /// displacement and role changes, so moving a card preserves lifecycle,
    /// prompt, remote-order, and custom destination-group policy state.
    @discardableResult
    func acceptSurfaceDrop(
        _ payload: SurfaceDragPayload,
        onto setID: UUID,
        role: MemberRole,
        targetGroupID: UUID? = nil,
        required: Bool? = nil
    ) -> Bool {
        guard ensureStoreWritable() else { return false }
        guard let destination = sets.first(where: { $0.id == setID }) else {
            lastError = storeLoadFailureMessage ?? "드롭할 작업 세트를 찾지 못했습니다."
            return false
        }
        if let targetGroupID,
           !destination.groups.contains(where: { $0.id == targetGroupID && $0.role == role }) {
            lastError = storeLoadFailureMessage ?? "드롭할 그룹이 변경되었습니다. 다시 시도하세요."
            return false
        }

        var sourceMember: WorkMember?
        var sourceAttachment: WorkAttachment?
        switch payload.origin {
        case .liveSurface:
            guard payload.sourceSetID == nil, payload.itemID == nil,
                  let surfaceID = payload.surfaceID,
                  unlinkedSurfaces.contains(where: { $0.id == surfaceID }) else {
                lastError = storeLoadFailureMessage
                    ?? "드래그한 터미널이 이미 연결되었거나 사라졌습니다. 다시 드래그하세요."
                return false
            }
        case .member:
            guard let sourceSetID = payload.sourceSetID,
                  let memberID = payload.itemID,
                  let member = sets.first(where: { $0.id == sourceSetID })?.members.first(where: {
                      $0.id == memberID
                  }),
                  payload.surfaceID == nil || payload.surfaceID == member.surfaceID else {
                lastError = storeLoadFailureMessage
                    ?? "드래그한 멤버가 이동되었거나 제거되었습니다. 다시 드래그하세요."
                return false
            }
            sourceMember = member
        case .attachment:
            guard role == .pr,
                  let sourceSetID = payload.sourceSetID,
                  let attachmentID = payload.itemID,
                  let attachment = sets.first(where: { $0.id == sourceSetID })?.attachments.first(where: {
                      $0.id == attachmentID
                  }),
                  payload.surfaceID == nil || payload.surfaceID == attachment.surfaceID else {
                lastError = storeLoadFailureMessage
                    ?? "드래그한 PR 연결이 이동되었거나 제거되었습니다. 다시 드래그하세요."
                return false
            }
            sourceAttachment = attachment
        }

        if let sourceAttachment,
           let sourceSetID = payload.sourceSetID {
            if sourceSetID == setID {
                lastError = storeLoadFailureMessage
                return true
            }
            var proposedSets = sets
            guard let sourceIndex = proposedSets.firstIndex(where: { $0.id == sourceSetID }),
                  let destinationIndex = proposedSets.firstIndex(where: { $0.id == setID }) else {
                lastError = storeLoadFailureMessage ?? "PR 연결을 옮길 세트를 찾지 못했습니다."
                return false
            }
            proposedSets[sourceIndex].attachments.removeAll { $0.id == sourceAttachment.id }
            proposedSets[destinationIndex].attachments.removeAll { candidate in
                candidate.id == sourceAttachment.id
                    || (sourceAttachment.surfaceID != nil
                        && candidate.surfaceID == sourceAttachment.surfaceID)
            }
            proposedSets[destinationIndex].attachments.append(sourceAttachment)
            return commitDragMutation(proposedSets)
        }

        let resolvedSurfaceID = sourceMember?.surfaceID ?? payload.surfaceID
        let liveSurface = resolvedSurfaceID.flatMap { surfaceID in
            liveSurfaces.first(where: { $0.id == surfaceID })
        }
        let isBrowser = payload.origin == .liveSurface && liveSurface?.isBrowser == true

        if isBrowser && role != .pr {
            lastError = storeLoadFailureMessage ?? "브라우저 창은 PR 영역에 놓으세요."
            return false
        }
        if !isBrowser && role == .pr {
            lastError = storeLoadFailureMessage ?? "PR 영역에는 cmux 브라우저 창을 놓으세요."
            return false
        }

        let surfaceID = sourceMember?.surfaceID ?? liveSurface?.id ?? payload.surfaceID
        let sessionID = sourceMember?.sessionID ?? liveSurface?.sessionID

        guard surfaceID != nil || (role != .pr && sessionID != nil) else {
            lastError = storeLoadFailureMessage
                ?? "드래그한 터미널을 더 이상 찾을 수 없습니다. 새로고침 후 다시 시도하세요."
            return false
        }

        var snapshot = CompanionSnapshot(sets: sets)
        let command = InboxCommand(
            kind: .join,
            setName: destination.label,
            role: role,
            groupID: targetGroupID,
            label: sourceMember?.label ?? liveSurface?.displayTitle,
            agent: sourceMember?.agent ?? liveSurface?.agent,
            session: sessionID,
            required: required,
            remote: (sourceMember?.isRemote == true) || (liveSurface?.isRemote == true),
            cmuxContext: CmuxContext(
                windowID: liveSurface?.windowID ?? sourceMember?.windowID,
                workspaceID: liveSurface?.workspaceID ?? sourceMember?.workspaceID,
                surfaceID: surfaceID
            ),
            source: CommandSource(executable: "CmuxCompanion.drag-and-drop")
        )

        do {
            let result = try CommandReducer.apply(command, to: &snapshot)
            if role == .pr, let surfaceID,
               let setIndex = snapshot.sets.firstIndex(where: { $0.id == setID }),
               let attachmentIndex = snapshot.sets[setIndex].attachments.firstIndex(where: {
                   $0.surfaceID == surfaceID
               }) {
                snapshot.sets[setIndex].attachments[attachmentIndex].url = liveSurface?.url
                    ?? snapshot.sets[setIndex].attachments[attachmentIndex].url
            } else if let memberID = result.joinedMemberID,
                      let setIndex = snapshot.sets.firstIndex(where: { $0.id == setID }),
                      let memberIndex = snapshot.sets[setIndex].members.firstIndex(where: {
                          $0.id == memberID
                      }),
                      let liveSurface {
                var member = snapshot.sets[setIndex].members[memberIndex]
                member.agent = liveSurface.agent ?? member.agent
                member.sessionID = liveSurface.sessionID ?? member.sessionID
                member.surfaceID = liveSurface.id
                member.workspaceID = liveSurface.workspaceID ?? member.workspaceID
                member.windowID = liveSurface.windowID ?? member.windowID
                if sourceMember == nil || liveSurface.runtimeState != .unknown {
                    member.runtimeState = liveSurface.runtimeState
                }
                if let prompt = liveSurface.lastSubmittedText {
                    member.lastSubmittedText = prompt
                    member.lastSubmittedAt = liveSurface.lastSubmittedAt
                }
                member.isRemote = member.isRemote || liveSurface.isRemote
                snapshot.sets[setIndex].members[memberIndex] = member
            }

            return commitDragMutation(snapshot.sets)
        } catch {
            lastError = storeLoadFailureMessage
                ?? "드롭한 터미널을 연결하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    /// Removes only the logical association. A still-live local surface
    /// immediately returns to the fixed unlinked tray and can be assigned
    /// again; the cmux terminal/browser itself is never closed.
    @discardableResult
    func acceptUnlinkDrop(_ payload: SurfaceDragPayload) -> Bool {
        guard ensureStoreWritable() else { return false }
        guard let sourceSetID = payload.sourceSetID,
              let itemID = payload.itemID,
              let setIndex = sets.firstIndex(where: { $0.id == sourceSetID }) else {
            lastError = storeLoadFailureMessage ?? "연결된 멤버 또는 PR만 그룹에서 내릴 수 있습니다."
            return false
        }

        var proposedSets = sets
        switch payload.origin {
        case .member:
            guard let member = proposedSets[setIndex].members.first(where: { $0.id == itemID }),
                  payload.surfaceID == nil || payload.surfaceID == member.surfaceID else {
                lastError = storeLoadFailureMessage ?? "내릴 멤버가 더 이상 존재하지 않습니다."
                return false
            }
            proposedSets[setIndex].members.removeAll { $0.id == itemID }
            for groupIndex in proposedSets[setIndex].groups.indices {
                proposedSets[setIndex].groups[groupIndex].memberIDs.removeAll { $0 == itemID }
            }
            proposedSets[setIndex].groups.removeAll { $0.memberIDs.isEmpty }
        case .attachment:
            guard let attachment = proposedSets[setIndex].attachments.first(where: { $0.id == itemID }),
                  payload.surfaceID == nil || payload.surfaceID == attachment.surfaceID else {
                lastError = storeLoadFailureMessage ?? "내릴 PR 연결이 더 이상 존재하지 않습니다."
                return false
            }
            proposedSets[setIndex].attachments.removeAll { $0.id == itemID }
        case .liveSurface:
            lastError = storeLoadFailureMessage ?? "이미 그룹 밖에 있는 창입니다."
            return false
        }

        return commitDragMutation(proposedSets)
    }

    func removeMember(_ memberID: UUID, from setID: UUID) {
        guard ensureStoreWritable() else { return }
        guard let setIndex = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[setIndex].members.removeAll { $0.id == memberID }
        removeMemberID(memberID, fromGroupsIn: setIndex)
        persistAndEvaluate()
    }

    func renameMember(_ memberID: UUID, in setID: UUID, to label: String) {
        guard ensureStoreWritable() else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let setIndex = sets.firstIndex(where: { $0.id == setID }),
              let memberIndex = sets[setIndex].members.firstIndex(where: { $0.id == memberID }) else { return }
        sets[setIndex].members[memberIndex].label = trimmed
        persistAndEvaluate()
    }

    func setGroupPolicy(_ groupID: UUID, in setID: UUID, policy: GroupPolicy) {
        guard ensureStoreWritable() else { return }
        guard let setIndex = sets.firstIndex(where: { $0.id == setID }),
              let groupIndex = sets[setIndex].groups.firstIndex(where: { $0.id == groupID }) else { return }
        sets[setIndex].groups[groupIndex].policy = policy
        persistAndEvaluate()
    }

    func setGroupRequired(_ groupID: UUID, in setID: UUID, required: Bool) {
        guard ensureStoreWritable() else { return }
        guard let setIndex = sets.firstIndex(where: { $0.id == setID }),
              let groupIndex = sets[setIndex].groups.firstIndex(where: { $0.id == groupID }) else { return }
        sets[setIndex].groups[groupIndex].required = required
        persistAndEvaluate()
    }

    func removeAttachment(_ attachmentID: UUID, from setID: UUID) {
        guard ensureStoreWritable() else { return }
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].attachments.removeAll { $0.id == attachmentID }
        persistAndEvaluate()
    }

    func addLinkAttachment(to setID: UUID, label: String, urlString: String) {
        guard ensureStoreWritable() else { return }
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            lastError = storeLoadFailureMessage ?? "PR 링크는 유효한 http 또는 https URL이어야 합니다."
            return
        }
        guard let setIndex = sets.firstIndex(where: { $0.id == setID }) else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let attachmentIndex = sets[setIndex].attachments.firstIndex(where: { $0.url == url }) {
            if !trimmedLabel.isEmpty {
                sets[setIndex].attachments[attachmentIndex].label = trimmedLabel
            }
        } else {
            sets[setIndex].attachments.append(
                WorkAttachment(
                    label: trimmedLabel.isEmpty ? "PR 페이지" : trimmedLabel,
                    url: url
                )
            )
        }
        persistAndEvaluate()
    }

    func copyJoinCommand(for setID: UUID, role: MemberRole) {
        guard let set = sets.first(where: { $0.id == setID }) else { return }
        let bundledHelper = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-set")
        let helper = bundledHelper.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0.path : nil }
            ?? "cmux-set"
        let command = "\(shellQuote(helper)) join \(shellQuote(set.label)) --role \(role.rawValue)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func arm(_ setID: UUID) {
        guard ensureStoreWritable() else { return }
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].arm()
        persistAndEvaluate()
    }

    func disarm(_ setID: UUID) {
        guard ensureStoreWritable() else { return }
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].armed = false
        persistAndEvaluate()
    }

    func complete(_ setID: UUID) {
        guard ensureStoreWritable() else { return }
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].completeCurrentGeneration()
        persistAndEvaluate()
    }

    func snooze(_ setID: UUID, minutes: Int = 15) {
        guard ensureStoreWritable() else { return }
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].snoozedUntil = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        persistAndEvaluate()
    }

    func focus(_ member: WorkMember) {
        focus(windowID: member.windowID, workspaceID: member.workspaceID, surfaceID: member.surfaceID)
    }

    func focus(_ attachment: WorkAttachment) {
        let hasLiveSurface = isCmuxConnected && attachment.surfaceID.map { surfaceID in
            liveSurfaces.contains { $0.id == surfaceID }
        } == true
        if hasLiveSurface {
            focus(
                windowID: attachment.windowID,
                workspaceID: attachment.workspaceID,
                surfaceID: attachment.surfaceID
            )
        } else if let url = attachment.url {
            NSWorkspace.shared.open(url)
        }
    }

    func focus(_ surface: LiveSurface) {
        focus(windowID: surface.windowID, workspaceID: surface.workspaceID, surfaceID: surface.id)
    }

    func focusSet(_ setID: UUID) {
        guard let set = sets.first(where: { $0.id == setID }) else { return }
        let preferredMemberID = SetEvaluator.preferredFocusMemberID(
            in: set,
            evaluation: evaluations[set.id]
        )
        if let member = preferredMemberID.flatMap({ memberID in
            set.members.first { $0.id == memberID }
        }) {
            focus(member)
        } else if let attachment = set.attachments.first {
            focus(attachment)
        }
    }

    func installHooks() {
        guard !isInstallingHooks else { return }
        let runner: CmuxProcessRunner
        do {
            runner = try CmuxProcessRunner()
        } catch {
            hookSetupFeedback = HookSetupFeedback(
                kind: .failure,
                title: "Hooks 설치를 시작하지 못했습니다",
                detail: error.localizedDescription
            )
            return
        }

        isInstallingHooks = true
        hookSetupFeedback = nil
        Task {
            do {
                let result = try await runner.run(arguments: ["hooks", "setup", "--yes"])
                let summary = CmuxHooksSetupSummary(
                    stdout: result.stdout,
                    stderr: result.stderr
                )
                await MainActor.run {
                    self.isInstallingHooks = false
                    if summary.installedAny == false {
                        self.hookSetupFeedback = HookSetupFeedback(
                            kind: .failure,
                            title: "설치할 Agent hooks를 찾지 못했습니다",
                            detail: summary.output.isEmpty
                                ? "Codex 또는 지원 Agent CLI의 설치 위치를 확인하세요."
                                : summary.output
                        )
                    } else if summary.installedAny == true {
                        self.hookSetupFeedback = HookSetupFeedback(
                            kind: .success,
                            title: "Hooks 설치 완료",
                            detail: summary.output.isEmpty
                                ? "cmux hooks setup이 완료되었습니다."
                                : summary.output
                        )
                    } else {
                        self.hookSetupFeedback = HookSetupFeedback(
                            kind: .failure,
                            title: "Hooks 설치 결과를 확인해야 합니다",
                            detail: summary.output.isEmpty
                                ? "cmux가 성공 상태로 종료됐지만 설치 수를 확인할 summary를 출력하지 않았습니다."
                                : summary.output
                        )
                    }
                    self.lastError = self.storeLoadFailureMessage
                    Task { await self.refresh() }
                }
            } catch {
                await MainActor.run {
                    self.isInstallingHooks = false
                    let detail: String
                    if case let CmuxProcessError.nonZeroExit(_, exitCode, stdout, stderr) = error {
                        let summary = CmuxHooksSetupSummary(stdout: stdout, stderr: stderr)
                        let output = summary.output
                        detail = output.isEmpty
                            ? "cmux hooks setup이 상태 \(exitCode)로 종료되었습니다."
                            : "종료 상태 \(exitCode)\n\(output)"
                    } else {
                        detail = error.localizedDescription
                    }
                    self.hookSetupFeedback = HookSetupFeedback(
                        kind: .failure,
                        title: "Hooks 설치 실패",
                        detail: detail
                    )
                    self.lastError = self.storeLoadFailureMessage
                }
            }
        }
    }

    func dismissHookSetupFeedback() {
        hookSetupFeedback = nil
    }

    func dismissError() {
        lastError = storeLoadFailureMessage
    }

    func dismissSetNameConflict() {
        conflictingSetName = nil
    }

    private func ensureStoreWritable() -> Bool {
        guard let storeLoadFailureMessage else { return true }
        lastError = storeLoadFailureMessage
        return false
    }

    func petVisibilityDidChange() {
        onPetVisibilityChanged?(showPet)
    }

    var linkedSurfaceIDs: Set<String> {
        Set(sets.flatMap { set in
            set.members.compactMap(\.surfaceID) + set.attachments.compactMap(\.surfaceID)
        })
    }

    var unlinkedSurfaces: [LiveSurface] {
        liveSurfaces.filter { !linkedSurfaceIDs.contains($0.id) }
    }

    func workload(for member: WorkMember) -> SurfaceWorkload {
        let live = member.surfaceID.flatMap { surfaceID in
            liveSurfaces.first { $0.id == surfaceID }
        } ?? member.sessionID.flatMap { sessionID in
            liveSurfaces.first { $0.sessionID == sessionID }
        }

        if member.isRemote {
            // A remote SessionEnd with a still-live SSH surface means control
            // has returned to that remote shell. For stale/disconnected agents
            // keep the last known type instead of guessing.
            if member.runtimeState == .ended, live != nil {
                return .shell
            }
            return SurfaceWorkload(agent: member.agent ?? live?.agent)
        }

        if let live {
            if live.workload == .unknown, let agent = member.agent {
                return SurfaceWorkload(agent: agent)
            }
            return live.workload
        }
        return SurfaceWorkload(agent: member.agent)
    }

    func promptPreview(for member: WorkMember) -> (text: String, date: Date?)? {
        let live = member.surfaceID.flatMap { surfaceID in
            liveSurfaces.first { $0.id == surfaceID }
        } ?? member.sessionID.flatMap { sessionID in
            liveSurfaces.first { $0.sessionID == sessionID }
        }

        if let text = live?.displayOnlyPromptText, !text.isEmpty {
            return (text, live?.displayOnlyPromptAt)
        }
        if let text = live?.lastSubmittedText, !text.isEmpty {
            return (text, live?.lastSubmittedAt)
        }
        if let text = member.lastSubmittedText, !text.isEmpty {
            return (text, member.lastSubmittedAt)
        }
        return nil
    }

    var hasLinkedDraggableItems: Bool {
        sets.contains { !$0.members.isEmpty || !$0.attachments.isEmpty }
    }

    var attentionCount: Int {
        evaluations.values.filter { $0.shouldNotify }.count
    }

    private func startEventStream() {
        guard let eventStream else { return }
        let root = CompanionPaths.defaultRootDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = CmuxEventStreamConfiguration(
            cursorFile: root.appendingPathComponent("events.cursor"),
            categories: ["window", "workspace", "pane", "surface", "notification", "feed", "agent"]
        )

        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await frame in eventStream.frames(configuration: configuration) {
                        guard !Task.isCancelled else { break }
                        self?.handle(event: frame)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.isCmuxConnected = false
                    self?.lastError = self?.storeLoadFailureMessage
                        ?? self?.friendlyCmuxError(error.localizedDescription)
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func handle(event: CmuxEventFrame) {
        if event.kind == .acknowledgement {
            isCmuxConnected = true
        }
        if event.resumeGap {
            Task { await refresh() }
            return
        }

        if event.category == "agent" || event.name?.hasPrefix("agent.hook.") == true {
            captureRemoteEvent(event)
        }
        if event.kind == .event {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                await self?.refresh()
            }
        }
    }

    private func captureRemoteEvent(_ frame: CmuxEventFrame) {
        guard let payload = frame.payload else { return }
        let sessionID = payload.firstString(forKeys: ["session_id", "sessionId", "workstream_id"])
        guard let sessionID else { return }
        // Local agent events share this event category. Only the session
        // namespace emitted by our SSH bridge is allowed into the remote
        // cache, otherwise a local session could be mislabeled as remote.
        guard let identity = CmuxRemoteEventIdentity(sessionID: sessionID, payload: payload) else { return }
        let source = payload.firstString(forKeys: ["_source", "source", "agent"])
            ?? frame.source
        let hookName = identity.originalHookName
            ?? frame.name?.replacingOccurrences(of: "agent.hook.", with: "")
            ?? payload.firstString(forKeys: ["hook_event_name", "hookEventName"])
        let surfaceID = frame.surfaceID
            ?? payload.firstString(forKeys: ["surface_id", "surfaceId", "panel_id"])
            ?? identity.surfaceID
        let workspaceID = frame.workspaceID
            ?? payload.firstString(forKeys: ["workspace_id", "workspaceId"])
        let text = payload.firstString(forKeys: ["prompt", "text", "message_preview", "last_user_message"])
        let order = identity.order
        let isHeartbeat = hookName?.caseInsensitiveCompare("Heartbeat") == .orderedSame
        let receivedAt = Date()
        let remoteReportedAt = payload.firstValue(forKeys: ["_received_at"])?.doubleValue
            .map(Date.init(timeIntervalSinceReferenceDate:))
        let occurredAt = CmuxRemoteLifecycle.canonicalEventDate(
            frameOccurredAt: parsedDate(frame.occurredAt),
            localReceivedAt: receivedAt,
            remoteReportedAt: remoteReportedAt
        )
        let exactExisting = lastEventByRemoteSession[sessionID]
        let surfaceExisting = lastEventByRemoteSession.values
            .filter { $0.surfaceID == surfaceID }
            .max { $0.receivedAt < $1.receivedAt }
        for candidate in [exactExisting, surfaceExisting].compactMap({ $0 }) {
            if !CmuxRemoteLifecycle.isEventNewer(
                incomingOrder: order,
                occurredAt: occurredAt,
                previousBootID: candidate.order?.bootID,
                previousSequence: candidate.order?.sequence,
                previousReceivedAt: candidate.lastSeenAt
            ) {
                return
            }
        }
        let persistedMember = persistedRemoteMember(sessionID: sessionID, surfaceID: surfaceID)
        let surfaceWatermarkMember = persistedSurfaceMember(
            sessionID: sessionID,
            surfaceID: surfaceID
        )
        if !CmuxRemoteLifecycle.isEventNewer(
            incomingOrder: order,
            occurredAt: occurredAt,
            previousBootID: surfaceWatermarkMember?.lastRemoteBootID,
            previousSequence: surfaceWatermarkMember?.lastRemoteSequence,
            previousReceivedAt: surfaceWatermarkMember?.lastHeartbeatAt
        ) {
            return
        }
        let localSurfaceMembers = sets.flatMap(\.members).filter {
            $0.surfaceID == surfaceID && !$0.isRemote
        }
        let localSurfaceOwnerExists = !localSurfaceMembers.isEmpty
        if localSurfaceOwnerExists {
            let localOwnershipSince = localSurfaceMembers.compactMap(\.localOwnershipSince).max()
            if !CmuxRemoteLifecycle.isAfterLocalOwnership(
                occurredAt: occurredAt,
                localOwnershipSince: localOwnershipSince
            ) {
                return
            }
            let activation = hookName?.caseInsensitiveCompare("SessionStart") == .orderedSame
                || hookName?.caseInsensitiveCompare("UserPromptSubmit") == .orderedSame
            guard !isHeartbeat && activation else { return }
        }
        let currentSurfaceSessionID = surfaceExisting?.sessionID ?? persistedMember?.sessionID
        guard CmuxRemoteLifecycle.shouldAcceptSessionEvent(
            currentSessionID: currentSurfaceSessionID,
            incomingSessionID: sessionID,
            hookName: hookName
        ) else { return }
        if !isHeartbeat,
           let currentSurfaceSessionID,
           currentSurfaceSessionID != sessionID {
            lastEventByRemoteSession[currentSurfaceSessionID] = nil
        }
        let existing = isHeartbeat ? surfaceExisting ?? exactExisting : exactExisting ?? surfaceExisting
        let state = CmuxRemoteLifecycle.state(
            forHookName: hookName,
            previous: existing?.runtimeState ?? persistedMember?.runtimeState
        )
        let effectiveSessionID = isHeartbeat
            ? existing?.sessionID ?? persistedMember?.sessionID ?? sessionID
            : sessionID
        let previousPromptText = existing?.lastSubmittedText ?? persistedMember?.lastSubmittedText
        let previousPromptDate = existing?.lastSubmittedAt ?? persistedMember?.lastSubmittedAt
        let promptText = hookName?.caseInsensitiveCompare("UserPromptSubmit") == .orderedSame
            ? text ?? previousPromptText
            : previousPromptText
        let promptDate = hookName?.caseInsensitiveCompare("UserPromptSubmit") == .orderedSame && text != nil
            ? occurredAt
            : previousPromptDate
        lastEventByRemoteSession[effectiveSessionID] = RemoteEventState(
            sessionID: effectiveSessionID,
            source: source ?? existing?.source ?? persistedMember?.agent,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            runtimeState: state,
            lastSubmittedText: promptText,
            lastSubmittedAt: promptDate,
            order: order,
            receivedAt: receivedAt,
            lastSeenAt: occurredAt
        )
    }

    private func apply(_ snapshot: CmuxTransportSnapshot) {
        let freshTree = snapshot.tree.value
        let freshSessions = snapshot.sessions.value?.sessions
        let freshFeedItems = snapshot.feed.value?.items
        let freshTop = snapshot.top.value
        let treeIsAuthoritative = freshTree != nil
        let sessionsAreAuthoritative = freshSessions != nil

        if let freshTree { lastGoodTree = freshTree }
        if let freshSessions {
            lastGoodSessions = freshSessions
            hasGoodSessionsSnapshot = true
        }
        if let freshFeedItems {
            lastGoodFeedItems = freshFeedItems
            hasGoodFeedSnapshot = true
        }

        if treeIsAuthoritative && sessionsAreAuthoritative {
            degradedSnapshotSince = nil
        } else if degradedSnapshotSince == nil {
            degradedSnapshotSince = snapshot.loadedAt
        }
        let topologyIsStale = degradedSnapshotSince.map {
            snapshot.loadedAt.timeIntervalSince($0) >= degradedSnapshotGrace
        } ?? false

        let freshSessionByID = Set(freshSessions?.map(\.id) ?? [])
        let freshSessionSurfaceIDs = Set(freshSessions?.compactMap(\.surfaceID) ?? [])
        let sessionsCanEvaluateTrackedMember = sessionsAreAuthoritative && sets.contains { set in
            set.members.contains { member in
                member.sessionID.map(freshSessionByID.contains) == true
                    || member.surfaceID.map(freshSessionSurfaceIDs.contains) == true
                    || (member.sessionID != nil && !member.isRemote)
            }
        }
        hasAuthoritativeRefresh = hasAuthoritativeRefresh
            || treeIsAuthoritative
            || sessionsCanEvaluateTrackedMember

        let tree = freshTree ?? lastGoodTree
        let sessions = freshSessions ?? (hasGoodSessionsSnapshot ? lastGoodSessions : [])
        let feedItems = freshFeedItems ?? (hasGoodFeedSnapshot ? lastGoodFeedItems : [])
        let surfaces = flatten(
            tree: tree,
            sessions: sessions,
            feedItems: feedItems,
            processWorkloads: freshTop,
            occupancyIsAuthoritative: treeIsAuthoritative && sessionsAreAuthoritative
        )

        liveSurfaces = surfaces.sorted {
            if $0.workspaceTitle != $1.workspaceTitle { return $0.workspaceTitle < $1.workspaceTitle }
            return $0.displayTitle < $1.displayTitle
        }
        isCmuxConnected = treeIsAuthoritative
        lastRefreshAt = snapshot.loadedAt
        let cmuxError = snapshot.failures.isEmpty
            ? nil
            : friendlyCmuxError(snapshot.failures.map(\.message).joined(separator: " · "))
        lastError = storeLoadFailureMessage ?? cmuxError

        reconcileMembers(
            with: surfaces,
            sessions: sessions,
            feedItems: feedItems,
            treeIsAuthoritative: treeIsAuthoritative,
            sessionsAreAuthoritative: sessionsAreAuthoritative,
            topologyIsStale: topologyIsStale
        )
        persistAndEvaluate(notifyTransitions: hasAuthoritativeRefresh)
    }

    private func flatten(
        tree: CmuxTreeSnapshot?,
        sessions: [CmuxTransportSession],
        feedItems: [CmuxTransportFeedItem],
        processWorkloads: CmuxTopSnapshot?,
        occupancyIsAuthoritative: Bool
    ) -> [LiveSurface] {
        guard let tree else { return [] }
        var result: [LiveSurface] = []
        let sessionBySurface = CmuxAgentSessionResolver.currentBySurface(sessions)
        let promptSourceBySurface = processWorkloads.map {
            CmuxAgentSessionResolver.promptDisplaySourcesBySurface(
                sessions,
                corroboratedBy: $0
            )
        } ?? [:]

        for window in tree.windows {
            for workspace in window.workspaces {
                for surface in workspace.surfaces {
                    let session = sessionBySurface[surface.id]
                        ?? surface.ref.flatMap { sessionBySurface[$0] }
                    let kind = surface.type ?? "terminal"
                    let prompt = session.flatMap { latestPrompt(for: $0, in: feedItems) }
                    let displayPrompt = session == nil && kind.lowercased() != "browser"
                        ? promptSourceBySurface[surface.id].flatMap {
                            latestPrompt(for: $0, in: feedItems)
                        }
                        : nil
                    let processWorkload = processWorkloads?.workload(forSurfaceID: surface.id)
                        ?? surface.ref.flatMap { processWorkloads?.workload(forSurfaceID: $0) }
                    let workload = SurfaceWorkload.resolved(
                        currentSession: session,
                        processWorkload: processWorkload,
                        hasFreshProcessSnapshot: processWorkloads != nil,
                        isBrowser: kind.lowercased() == "browser",
                        occupancyIsAuthoritative: occupancyIsAuthoritative
                    )
                    result.append(
                        LiveSurface(
                            id: surface.id,
                            windowID: window.id,
                            workspaceID: workspace.id,
                            workspaceTitle: workspace.title ?? workspace.ref ?? "Workspace",
                            title: surface.title ?? session?.agentDisplayName ?? session?.agent ?? surface.type ?? "Surface",
                            kind: kind,
                            url: surface.url.flatMap(URL.init(string:)),
                            agent: session?.agent ?? session?.agentDisplayName,
                            sessionID: session?.id,
                            runtimeState: session.map(runtimeState(for:)) ?? .unknown,
                            lastSubmittedText: prompt?.text,
                            lastSubmittedAt: prompt?.date,
                            displayOnlyPromptText: displayPrompt?.text,
                            displayOnlyPromptAt: displayPrompt?.date,
                            isRemote: session.map { CmuxRemoteEventIdentity.isRemoteSessionID($0.id) }
                                ?? false,
                            workload: workload
                        )
                    )
                }
            }
        }
        return result
    }

    private func reconcileMembers(
        with surfaces: [LiveSurface],
        sessions: [CmuxTransportSession],
        feedItems: [CmuxTransportFeedItem],
        treeIsAuthoritative: Bool,
        sessionsAreAuthoritative: Bool,
        topologyIsStale: Bool
    ) {
        let surfaceByID = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.id, $0) })
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let sessionBySurface = CmuxAgentSessionResolver.currentBySurface(sessions)
        let surfaceBySession = Dictionary(
            surfaces.compactMap { surface in surface.sessionID.map { ($0, surface) } },
            uniquingKeysWith: { lhs, _ in lhs }
        )
        let now = Date()

        for setIndex in sets.indices {
            for memberIndex in sets[setIndex].members.indices {
                var member = sets[setIndex].members[memberIndex]
                let live = member.sessionID.flatMap { surfaceBySession[$0] }
                    ?? member.surfaceID.flatMap { surfaceByID[$0] }
                let localSession = live?.sessionID.flatMap { sessionByID[$0] }
                    ?? member.surfaceID.flatMap { sessionBySurface[$0] }
                let remote = remoteState(matching: member)
                let localState = localSession.map(runtimeState(for:))
                let localUpdatedAt = localSession?.updatedAtUnix.map(Date.init(timeIntervalSince1970:))
                let shouldYieldToLocal = (member.isRemote || remote != nil)
                    && sessionsAreAuthoritative
                    && localSession.map { !CmuxRemoteEventIdentity.isRemoteSessionID($0.id) } == true
                    && localSession.map { session in
                        CmuxRemoteLifecycle.shouldYieldToLocalSession(
                            isActiveForSurface: session.isActiveForSurface,
                            state: localState ?? .unknown,
                            updatedAt: localUpdatedAt,
                            remoteLastSeenAt: remote?.lastSeenAt ?? member.lastHeartbeatAt
                        )
                    } == true

                if shouldYieldToLocal, let localSession {
                    let oldRemoteSessionID = member.sessionID
                    let takeoverSurfaceID = localSession.surfaceID ?? live?.id ?? member.surfaceID
                    member.surfaceID = takeoverSurfaceID
                    member.workspaceID = localSession.workspaceID ?? live?.workspaceID ?? member.workspaceID
                    member.windowID = live?.windowID ?? member.windowID
                    member.sessionID = localSession.id
                    member.agent = localSession.agent ?? live?.agent ?? member.agent
                    member.runtimeState = localState ?? .unknown
                    member.isRemote = false
                    member.localOwnershipSince = now
                    mergeLastSubmitted(latestPrompt(for: localSession, in: feedItems), into: &member)
                    lastEventByRemoteSession = lastEventByRemoteSession.filter { key, event in
                        key != oldRemoteSessionID && event.surfaceID != member.surfaceID
                    }
                } else if let remote {
                    // An SSH agent runs inside an otherwise ordinary terminal
                    // surface, so the tree match alone cannot describe its
                    // lifecycle. Preserve topology from the live surface while
                    // letting authenticated bridge events own agent state.
                    if let live {
                        member.surfaceID = live.id
                        member.workspaceID = live.workspaceID
                        member.windowID = live.windowID
                    }
                    member.surfaceID = remote.surfaceID ?? member.surfaceID
                    member.workspaceID = remote.workspaceID ?? member.workspaceID
                    member.sessionID = remote.sessionID
                    member.agent = remote.source ?? member.agent
                    member.runtimeState = CmuxRemoteLifecycle.stateApplyingLease(
                        remote.runtimeState,
                        lastSeenAt: remote.lastSeenAt,
                        now: now
                    )
                    member.isRemote = true
                    member.localOwnershipSince = nil
                    member.lastHeartbeatAt = remote.lastSeenAt
                    if let order = remote.order {
                        member.lastRemoteBootID = order.bootID
                        member.lastRemoteSequence = order.sequence
                    }
                    mergeLastSubmitted(
                        latestPrompt(
                        sessionID: remote.sessionID,
                        source: remote.source,
                        in: feedItems
                        ),
                        into: &member
                    )
                    if let text = remote.lastSubmittedText {
                        mergeLastSubmitted((text, remote.lastSubmittedAt), into: &member)
                    }
                } else if member.isRemote {
                    // The in-memory event cache is intentionally ephemeral.
                    // After an app restart, keep the persisted remote state for
                    // its conservative lease window, then degrade deterministically.
                    if let live {
                        member.surfaceID = live.id
                        member.workspaceID = live.workspaceID
                        member.windowID = live.windowID
                    }
                    member.runtimeState = CmuxRemoteLifecycle.stateApplyingLease(
                        member.runtimeState,
                        lastSeenAt: member.lastHeartbeatAt,
                        now: now
                    )
                } else if let live {
                    member.surfaceID = live.id
                    member.workspaceID = live.workspaceID
                    member.windowID = live.windowID
                    if treeIsAuthoritative && sessionsAreAuthoritative {
                        // A live terminal with no current agent session has
                        // returned to its shell. Clear historical identity so
                        // the badge cannot remain stuck on Codex or Claude.
                        member.sessionID = live.sessionID
                        member.agent = live.agent
                    } else {
                        // A failed sessions snapshot is not evidence that the
                        // agent ended; retain the last known identity.
                        member.sessionID = live.sessionID ?? member.sessionID
                        member.agent = live.agent ?? member.agent
                    }
                    if sessionsAreAuthoritative {
                        member.runtimeState = live.runtimeState
                    } else if topologyIsStale {
                        member.runtimeState = .stale
                    }
                    mergeLastSubmitted(
                        live.lastSubmittedText.map { ($0, live.lastSubmittedAt) },
                        into: &member
                    )
                    if !member.isRemote,
                       member.localOwnershipSince == nil,
                       member.lastRemoteBootID != nil {
                        member.localOwnershipSince = now
                    }
                } else if let surfaceID = member.surfaceID,
                          let session = sessionBySurface[surfaceID] {
                    // `cmux sessions` is readable even when the live control socket is
                    // restricted to cmux descendants. This keeps a terminal that was
                    // linked manually with `cmux-set join` observable without requiring
                    // the user to also discover and pass the agent session identifier.
                    member.sessionID = session.id
                    member.workspaceID = session.workspaceID ?? member.workspaceID
                    member.agent = session.agent ?? session.agentDisplayName ?? member.agent
                    if sessionsAreAuthoritative {
                        member.runtimeState = runtimeState(for: session)
                    } else if topologyIsStale {
                        member.runtimeState = .stale
                    }
                    mergeLastSubmitted(latestPrompt(for: session, in: feedItems), into: &member)
                } else if let sessionID = member.sessionID,
                          let session = sessionByID[sessionID],
                          session.isCurrentForSurface {
                    member.surfaceID = session.surfaceID ?? member.surfaceID
                    member.workspaceID = session.workspaceID ?? member.workspaceID
                    member.agent = session.agent ?? session.agentDisplayName ?? member.agent
                    if sessionsAreAuthoritative {
                        member.runtimeState = runtimeState(for: session)
                    } else if topologyIsStale {
                        member.runtimeState = .stale
                    }
                    mergeLastSubmitted(latestPrompt(for: session, in: feedItems), into: &member)
                } else if sessionsAreAuthoritative,
                          member.sessionID != nil,
                          !member.isRemote {
                    member.runtimeState = .ended
                } else if treeIsAuthoritative,
                          member.sessionID == nil,
                          member.surfaceID != nil {
                    member.runtimeState = .ended
                } else if topologyIsStale && member.runtimeState != .ended {
                    member.runtimeState = .stale
                }
                sets[setIndex].members[memberIndex] = member
            }

            for attachmentIndex in sets[setIndex].attachments.indices {
                let surfaceID = sets[setIndex].attachments[attachmentIndex].surfaceID
                if let live = surfaceID.flatMap({ surfaceByID[$0] }) {
                    sets[setIndex].attachments[attachmentIndex].windowID = live.windowID
                    sets[setIndex].attachments[attachmentIndex].workspaceID = live.workspaceID
                    if let url = live.url {
                        sets[setIndex].attachments[attachmentIndex].url = url
                    }
                }
            }
        }
    }

    private func latestPrompt(
        for session: CmuxTransportSession,
        in items: [CmuxTransportFeedItem]
    ) -> (text: String, date: Date?)? {
        latestPrompt(
            sessionID: session.id,
            source: session.agent,
            transcriptPath: session.transcriptPath,
            in: items
        )
    }

    private func latestPrompt(
        for source: CmuxPromptDisplaySource,
        in items: [CmuxTransportFeedItem]
    ) -> (text: String, date: Date?)? {
        latestPrompt(
            sessionID: source.sessionID,
            source: source.source,
            transcriptPath: source.transcriptPath,
            in: items
        )
    }

    private func latestPrompt(
        sessionID: String,
        source: String?,
        transcriptPath: String?,
        in items: [CmuxTransportFeedItem]
    ) -> (text: String, date: Date?)? {
        let feedPrompt = latestPrompt(sessionID: sessionID, source: source, in: items)
        let transcriptPrompt: (text: String, date: Date?)?
        if let path = transcriptPath {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let cached = transcriptCache[url.path], cached.modificationDate == modificationDate {
                transcriptPrompt = cached.prompt.map { ($0.text, $0.date) }
            } else {
                let prompt = try? TranscriptPromptExtractor.latestUserPrompt(at: url)
                transcriptCache[url.path] = TranscriptCacheEntry(
                    modificationDate: modificationDate,
                    prompt: prompt ?? nil
                )
                transcriptPrompt = prompt.map { ($0.text, $0.date) }
            }
        } else {
            transcriptPrompt = nil
        }
        return newerPrompt(feedPrompt, transcriptPrompt)
    }

    private func newerPrompt(
        _ lhs: (text: String, date: Date?)?,
        _ rhs: (text: String, date: Date?)?
    ) -> (text: String, date: Date?)? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        switch (lhs.date, rhs.date) {
        case let (left?, right?): return right > left ? rhs : lhs
        case (nil, _?): return rhs
        case (_?, nil): return lhs
        case (nil, nil): return lhs
        }
    }

    private func mergeLastSubmitted(
        _ candidate: (text: String, date: Date?)?,
        into member: inout WorkMember
    ) {
        guard let candidate, !candidate.text.isEmpty else { return }
        switch (member.lastSubmittedAt, candidate.date) {
        case let (current?, incoming?) where incoming >= current:
            member.lastSubmittedText = candidate.text
            member.lastSubmittedAt = incoming
        case (nil, let incoming?):
            member.lastSubmittedText = candidate.text
            member.lastSubmittedAt = incoming
        case (nil, nil) where member.lastSubmittedText == nil:
            member.lastSubmittedText = candidate.text
        default:
            break
        }
    }

    private func latestPrompt(
        sessionID: String,
        source: String?,
        in items: [CmuxTransportFeedItem]
    ) -> (text: String, date: Date?)? {
        let candidates = items.filter { item in
            let kind = item.kind?.lowercased().replacingOccurrences(of: "_", with: "")
            guard kind == "userprompt", let text = item.text, !text.isEmpty else { return false }
            guard let workstreamID = item.workstreamID?.lowercased() else { return false }
            let normalizedSessionID = sessionID.lowercased()
            let sourceMatches = source.map { item.source?.caseInsensitiveCompare($0) == .orderedSame } ?? true
            return sourceMatches && (
                workstreamID == normalizedSessionID
                    || workstreamID.hasSuffix("-\(normalizedSessionID)")
                    || workstreamID.contains(normalizedSessionID)
            )
        }
        let latest = candidates.max { lhs, rhs in
            parsedDate(lhs.createdAt ?? lhs.updatedAt) ?? .distantPast
                < parsedDate(rhs.createdAt ?? rhs.updatedAt) ?? .distantPast
        }
        return latest.flatMap { item in item.text.map { ($0, parsedDate(item.createdAt ?? item.updatedAt)) } }
    }

    private func runtimeState(for session: CmuxTransportSession) -> MemberRuntimeState {
        let raw = (session.effectiveLifecycle ?? "unknown")
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch raw {
        case "running", "working", "busy", "active": return .running
        case "needsinput", "waiting", "permission", "blocked": return .waiting
        case "idle", "stopped", "stop", "done": return .idle
        case "ended", "closed", "exited": return .ended
        case "stale": return .stale
        case "disconnected", "offline": return .disconnected
        case "error", "failed": return .error
        default: return .unknown
        }
    }

    private func removeMemberID(_ memberID: UUID, fromGroupsIn setIndex: Int) {
        for groupIndex in sets[setIndex].groups.indices {
            sets[setIndex].groups[groupIndex].memberIDs.removeAll { $0 == memberID }
        }
        sets[setIndex].groups.removeAll { $0.memberIDs.isEmpty }
    }

    /// Publishes a drag mutation only after its atomic store write succeeds.
    /// A failed save therefore cannot leave the UI ahead of the on-disk state
    /// or make a move appear successful until the next app launch reverts it.
    private func commitDragMutation(_ proposedSets: [WorkSet]) -> Bool {
        if let storeLoadFailureMessage {
            lastError = storeLoadFailureMessage
            return false
        }
        do {
            try store.save(sets: proposedSets)
        } catch {
            lastError = "드래그 변경을 저장하지 못했습니다: \(error.localizedDescription)"
            return false
        }
        sets = proposedSets
        lastError = nil
        recalculateEvaluations(notifyTransitions: true)
        return true
    }

    private func persistAndEvaluate(notifyTransitions: Bool = true) {
        if let storeLoadFailureMessage {
            // Never overwrite unreadable or newer-schema data with the empty
            // in-memory fallback created during launch.
            lastError = storeLoadFailureMessage
            recalculateEvaluations(notifyTransitions: notifyTransitions)
            return
        }
        do {
            try store.save(sets: sets)
        } catch {
            lastError = "세트를 저장하지 못했습니다: \(error.localizedDescription)"
        }
        recalculateEvaluations(notifyTransitions: notifyTransitions)
    }

    private func recalculateEvaluations(notifyTransitions: Bool) {
        let current = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, SetEvaluator.evaluate($0)) })
        if notifyTransitions {
            let currentSetIDs = Set(sets.map(\.id))
            for removedID in Array(lastNotificationFingerprints.keys) where !currentSetIDs.contains(removedID) {
                lastNotificationFingerprints[removedID] = nil
            }
            for set in sets {
                guard let evaluation = current[set.id] else { continue }
                guard evaluation.shouldNotify else {
                    lastNotificationFingerprints[set.id] = nil
                    continue
                }
                let previous = previousEvaluations[set.id]
                let fingerprint = NotificationFingerprint(set: set, evaluation: evaluation)
                if lastNotificationFingerprints[set.id] != fingerprint {
                    onAttentionTransition?(set, evaluation, previous)
                }
                lastNotificationFingerprints[set.id] = fingerprint
            }
        }
        previousEvaluations = current
        evaluations = current
        onEvaluationsChanged?(sets, current)
    }

    private func drainInbox() async {
        // Keep command files intact while the store is quarantined so they can
        // be replayed after the user repairs the protected snapshot.
        guard storeLoadFailureMessage == nil else { return }
        do {
            let commands = try inbox.drain()
            guard !commands.isEmpty else { return }
            for command in commands { apply(command) }
            persistAndEvaluate()
            await refresh()
        } catch {
            lastError = "cmux-set 명령을 처리하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func apply(_ command: InboxCommand) {
        var snapshot = CompanionSnapshot(sets: sets)
        do {
            let result = try CommandReducer.apply(command, to: &snapshot)
            sets = snapshot.sets

            // The pure reducer intentionally knows nothing about live cmux
            // topology. Enrich a freshly linked row with the current title,
            // lifecycle, URL, and prompt after the wire command is accepted.
            if command.kind == .join,
               let surfaceID = command.cmuxContext.effectiveSurfaceID,
               let live = liveSurfaces.first(where: { $0.id == surfaceID }) {
                if let memberID = result.joinedMemberID,
                   let setIndex = sets.firstIndex(where: { $0.members.contains(where: { $0.id == memberID }) }),
                   let memberIndex = sets[setIndex].members.firstIndex(where: { $0.id == memberID }) {
                    var member = sets[setIndex].members[memberIndex]
                    if command.label == nil { member.label = live.displayTitle }
                    member.agent = command.agent ?? live.agent
                    member.sessionID = command.session ?? live.sessionID
                    member.runtimeState = live.runtimeState
                    mergeLastSubmitted(
                        live.lastSubmittedText.map { ($0, live.lastSubmittedAt) },
                        into: &member
                    )
                    sets[setIndex].members[memberIndex] = member
                } else if command.role == .pr,
                          let setIndex = sets.firstIndex(where: { set in
                              set.attachments.contains(where: { $0.surfaceID == surfaceID })
                          }),
                          let attachmentIndex = sets[setIndex].attachments.firstIndex(where: { $0.surfaceID == surfaceID }) {
                    if command.label == nil { sets[setIndex].attachments[attachmentIndex].label = live.displayTitle }
                    if let url = live.url {
                        sets[setIndex].attachments[attachmentIndex].url = url
                    }
                }
            }
        } catch {
            lastError = "cmux-set 명령 거부: \(error.localizedDescription)"
        }
    }

    private func focus(windowID: String?, workspaceID: String?, surfaceID: String?) {
        var targetWindowID = windowID
        var targetWorkspaceID = workspaceID
        var targetSurfaceID = surfaceID
        if isCmuxConnected {
            if let surfaceID,
               let live = liveSurfaces.first(where: { $0.id == surfaceID }) {
                targetSurfaceID = live.id
                targetWorkspaceID = live.workspaceID ?? targetWorkspaceID
                targetWindowID = live.windowID ?? targetWindowID
            } else {
                targetSurfaceID = nil
            }
            if let workspaceID = targetWorkspaceID,
               !liveSurfaces.contains(where: { $0.workspaceID == workspaceID }) {
                targetWorkspaceID = nil
            }
            if let windowID = targetWindowID,
               !liveSurfaces.contains(where: { $0.windowID == windowID }) {
                targetWindowID = nil
            }
        }

        // cmux 0.64+ registers a first-party navigation URL. Prefer it because
        // it focuses the owning window as well and works even when the control
        // socket is restricted to descendants of cmux.
        if let targetWorkspaceID {
            let navigationURL = CmuxNavigationLink.workspace(targetWorkspaceID, surfaceID: targetSurfaceID)
                ?? CmuxNavigationLink.workspace(targetWorkspaceID)
            if let navigationURL, NSWorkspace.shared.open(navigationURL) {
                lastError = storeLoadFailureMessage
                return
            }
        }

        guard targetWindowID != nil || targetWorkspaceID != nil || targetSurfaceID != nil,
              let commandClient else {
            lastError = "cmux 위치로 이동할 정보가 부족합니다."
            return
        }
        Task {
            do {
                try await commandClient.focus(
                    CmuxFocusTarget(
                        windowID: targetWindowID,
                        workspaceID: targetWorkspaceID,
                        surfaceID: targetSurfaceID
                    )
                )
                await MainActor.run {
                    _ = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app")
                        .first?
                        .activate(options: [.activateAllWindows])
                }
            } catch {
                await MainActor.run { self.lastError = "cmux 위치로 이동하지 못했습니다: \(error.localizedDescription)" }
            }
        }
    }

    private func remoteState(matching member: WorkMember) -> RemoteEventState? {
        lastEventByRemoteSession.values
            .filter { event in
                if let sessionID = member.sessionID, event.sessionID == sessionID { return true }
                if let surfaceID = member.surfaceID, event.surfaceID == surfaceID { return true }
                return false
            }
            .max { $0.receivedAt < $1.receivedAt }
    }

    private func persistedRemoteMember(sessionID: String, surfaceID: String?) -> WorkMember? {
        if let exact = sets.lazy.compactMap({ set in
            set.members.first { $0.isRemote && $0.sessionID == sessionID }
        }).first {
            return exact
        }
        guard let surfaceID else { return nil }
        return sets.lazy.compactMap { set in
            set.members.first { $0.isRemote && $0.surfaceID == surfaceID }
        }.first
    }

    private func persistedSurfaceMember(sessionID: String, surfaceID: String) -> WorkMember? {
        sets.flatMap(\.members)
            .filter { $0.sessionID == sessionID || $0.surfaceID == surfaceID }
            .max {
                ($0.lastHeartbeatAt ?? .distantPast) < ($1.lastHeartbeatAt ?? .distantPast)
            }
    }

    private func parsedDate(_ value: String?) -> Date? {
        value.flatMap(dateParser.parse)
    }

    private func paletteColor(for index: Int) -> String {
        CompanionColorPalette.hex(for: index)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func friendlyCmuxError(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("socket not found")
            || lowered.contains("connection refused")
            || lowered.contains("broken pipe") {
            return "cmux가 실행 중이 아닙니다. cmux를 열면 자동으로 다시 연결합니다."
        }
        if lowered.contains("not allowed")
            || lowered.contains("access denied")
            || lowered.contains("only processes started inside cmux")
            || lowered.contains("json text did not start with array or object")
            || lowered.contains("unauthorized")
            || lowered.contains("authentication")
            || lowered.contains("cmuxonly") {
            let configuredMode = UserDefaults(suiteName: "com.cmuxterm.app")?
                .string(forKey: "socketControlMode")?
                .lowercased()
            if configuredMode == "automation" || configuredMode == "password" || configuredMode == "allowall" {
                return "Socket Control Mode는 설정됐지만 실행 중인 cmux에 아직 반영되지 않았습니다. 활성 작업을 저장한 뒤 cmux를 한 번 재실행하세요."
            }
            return "cmux 연결이 차단되었습니다. cmux Settings → Automation → Socket Control Mode를 Automation 또는 Password로 설정하세요."
        }
        return message
    }
}

private struct RemoteEventState {
    var sessionID: String
    var source: String?
    var surfaceID: String?
    var workspaceID: String?
    var runtimeState: MemberRuntimeState
    var lastSubmittedText: String?
    var lastSubmittedAt: Date?
    var order: CmuxRemoteEventOrder?
    /// Local processing time used only to choose the most recently handled
    /// cache entry. Lease age is based on `lastSeenAt` instead.
    var receivedAt: Date
    /// Mac-side cmux event timestamp, never the remote host's wall clock.
    var lastSeenAt: Date
}

private struct NotificationFingerprint: Equatable {
    var generation: Int
    var status: SetActivityStatus
    var attentionMemberIDs: [UUID]
    var attentionMemberStates: [String]
    var deficientGroupIDs: [UUID]

    init(set: WorkSet, evaluation: SetEvaluation) {
        generation = set.generation
        status = evaluation.status
        attentionMemberIDs = evaluation.attentionMemberIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        let memberByID = Dictionary(uniqueKeysWithValues: set.members.map { ($0.id, $0) })
        attentionMemberStates = evaluation.attentionMemberIDs.compactMap { memberID in
            memberByID[memberID].map { "\(memberID.uuidString):\($0.runtimeState.rawValue)" }
        }.sorted()
        deficientGroupIDs = evaluation.deficientGroupIDs.sorted {
            $0.uuidString < $1.uuidString
        }
    }
}

private struct TranscriptCacheEntry {
    var modificationDate: Date?
    var prompt: ExtractedPrompt?
}

private final class FlexibleDateParser {
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? standard.date(from: value)
    }
}
