import AppKit
import SwiftUI
import CmuxCompanionCore

struct CompanionRootView: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject var updater: AppUpdateController
    @State private var showHookConfirmation = false
    @State private var showUpdateConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if updater.phase != .idle {
                        updateBanner
                    }

                    if let feedback = model.hookSetupFeedback {
                        hookSetupBanner(feedback)
                    }

                    if let error = model.lastError {
                        errorBanner(error)
                    }

                    if model.sets.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.sets) { set in
                            SetCardView(
                                model: model,
                                set: set,
                                evaluation: model.evaluations[set.id] ?? SetEvaluator.evaluate(set)
                            )
                        }
                    }

                    createSetRow
                }
                .padding(12)
            }

            if !model.unlinkedSurfaces.isEmpty {
                Divider()
                unlinkedTray
            }

            if model.hasLinkedDraggableItems {
                Divider()
                UnlinkDropTarget(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }

            Divider()
            footer
        }
        .frame(width: 430, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "cmux Agent hooks를 설치할까요?",
            isPresented: $showHookConfirmation,
            titleVisibility: .visible
        ) {
            Button("Hooks 설치") { model.installHooks() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("cmux hooks setup이 지원 Agent의 사용자 설정을 업데이트합니다.")
        }
        .confirmationDialog(
            "v\(updater.updateVersionText ?? "새 버전")로 업데이트할까요?",
            isPresented: $showUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("다운로드하고 재실행") {
                Task { await updater.downloadAndInstall() }
            }
            Button("릴리스 노트 열기") { updater.openReleasePage() }
            Button("취소", role: .cancel) {}
        } message: {
            Text(
                "GitHub digest와 SHA-256 파일을 확인한 뒤 현재 앱을 백업하고 교체합니다. "
                    + "이 빌드는 Developer ID 서명·notarization 전이며 설치는 자동으로 시작되지 않습니다."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(model.attentionCount > 0 ? Color.orange.opacity(0.17) : Color.accentColor.opacity(0.14))
                Image(systemName: model.attentionCount > 0 ? "exclamationmark.bubble.fill" : "terminal.fill")
                    .foregroundStyle(model.attentionCount > 0 ? Color.orange : Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cmux Companion")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isCmuxConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(model.isCmuxConnected ? "cmux 연결됨" : "cmux 연결 대기 중")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.isRefreshing {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            Spacer()
            Button {
                Task { await updater.checkForUpdates() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .disabled(updater.isBusy)
            .help("업데이트 확인")
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("새로고침")
        }
        .padding(12)
    }

    @ViewBuilder
    private var updateBanner: some View {
        let color: Color = {
            switch updater.phase {
            case .failed: return .orange
            case .available: return .blue
            case .upToDate: return .green
            default: return .secondary
            }
        }()

        HStack(alignment: .top, spacing: 8) {
            Group {
                switch updater.phase {
                case .checking, .downloading, .installing:
                    ProgressView().controlSize(.small)
                case .upToDate:
                    Image(systemName: "checkmark.circle.fill")
                case .available:
                    Image(systemName: "arrow.down.circle.fill")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                case .idle:
                    EmptyView()
                }
            }
            .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 4) {
                switch updater.phase {
                case .checking:
                    Text("업데이트 확인 중…").font(.caption.weight(.semibold))
                case .upToDate:
                    Text("최신 버전입니다").font(.caption.weight(.semibold))
                    Text("현재 v\(updater.currentVersionText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .available:
                    Text("v\(updater.updateVersionText ?? "?") 사용 가능")
                        .font(.caption.weight(.semibold))
                    Text("GitHub Release에서 업데이트를 확인했습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .downloading:
                    Text("업데이트 다운로드 및 검증 중…")
                        .font(.caption.weight(.semibold))
                case .installing:
                    Text("앱 교체 후 재실행 중…")
                        .font(.caption.weight(.semibold))
                case .failed(let message):
                    Text("업데이트 실패").font(.caption.weight(.semibold))
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                case .idle:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if updater.phase == .available {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(updater.canInstallInPlace ? "업데이트" : "다운로드") {
                        if updater.canInstallInPlace {
                            showUpdateConfirmation = true
                        } else {
                            updater.openReleasePage()
                        }
                    }
                    .controlSize(.small)
                    Button("노트") { updater.openReleasePage() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                }
            } else if !updater.isBusy {
                Button { updater.dismissStatus() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(9)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissError() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    private func hookSetupBanner(_ feedback: HookSetupFeedback) -> some View {
        let isSuccess = feedback.kind == .success
        let color: Color = isSuccess ? .green : .orange
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(feedback.title)
                    .font(.caption.weight(.semibold))
                if !feedback.detail.isEmpty {
                    Text(feedback.detail)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissHookSetupFeedback() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("아직 작업 세트가 없습니다")
                .font(.headline)
            Text("아래에서 세트를 만든 뒤 터미널을 Worker 또는 Reviewer로 연결하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var createSetRow: some View {
        HStack(spacing: 8) {
            TextField("새 세트 이름 (예: PR-142)", text: $model.newSetName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.createSet() }
            Button("추가") { model.createSet() }
                .disabled(model.newSetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Keep drag sources visible while the independent set list scrolls. With
    /// up to three surfaces the tray needs no scrolling; larger sessions use a
    /// small local scroll instead of making the source disappear below sets.
    private var unlinkedTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("연결되지 않은 cmux 창", systemImage: "rectangle.stack.badge.plus")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("위 역할 칸으로 드래그")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.unlinkedSurfaces) { surface in
                        UnlinkedSurfaceRow(model: model, surface: surface)
                    }
                }
            }
            .frame(height: min(CGFloat(model.unlinkedSurfaces.count) * 51, 153))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Pet", isOn: $model.showPet)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: model.showPet) { _, _ in model.petVisibilityDidChange() }
            Toggle("프롬프트", isOn: $model.showPromptPreview)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            if model.isInstallingHooks {
                ProgressView()
                    .controlSize(.mini)
                    .help("Hooks 설치 중")
            }
            Button(model.isInstallingHooks ? "Hooks 설치 중…" : "Hooks…") {
                showHookConfirmation = true
            }
            .buttonStyle(.borderless)
            .disabled(model.isInstallingHooks)
            Text("v\(updater.currentVersionText)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(10)
    }
}

private struct SetCardView: View {
    @ObservedObject var model: CompanionAppModel
    let set: WorkSet
    let evaluation: SetEvaluation
    @State private var isExpanded = true
    @State private var isRenaming = false
    @State private var editedName = ""
    @State private var showAddLink = false
    @State private var linkLabel = "PR 페이지"
    @State private var linkURL = ""

    private var effectiveStatusName: String {
        if set.isCurrentGenerationCompleted { return "완료" }
        if evaluation.isSnoozed { return "미루는 중" }
        return evaluation.status.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            RoleDropStrip(model: model, set: set)
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
            if isExpanded {
                Divider().padding(.leading, 12)
                content
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(companionHex: set.color))
                .frame(width: 4)
                .padding(.vertical, 8)
        }
        .alert("PR 링크 추가", isPresented: $showAddLink) {
            TextField("라벨", text: $linkLabel)
            TextField("https://github.com/…/pull/…", text: $linkURL)
            Button("추가") {
                model.addLinkAttachment(to: set.id, label: linkLabel, urlString: linkURL)
                linkURL = ""
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("cmux 브라우저 자동 탐색 없이도 이 세트와 PR 페이지를 연결합니다.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)

            if isRenaming {
                TextField("세트 이름", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit { commitRename() }
            } else {
                Text(set.label)
                    .font(.headline)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        editedName = set.label
                        isRenaming = true
                    }
            }

            Text("#\(set.generation)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer()

            Label(effectiveStatusName, systemImage: set.isCurrentGenerationCompleted ? "checkmark.circle.fill" : evaluation.status.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(set.isCurrentGenerationCompleted ? Color.blue : evaluation.status.color)

            Menu {
                if set.armed {
                    Button("모니터링 해제") { model.disarm(set.id) }
                } else {
                    Button(set.isCurrentGenerationCompleted ? "새 라운드 시작" : "모니터링 시작") { model.arm(set.id) }
                }
                Button("현재 라운드 완료") { model.complete(set.id) }
                Button("PR 링크 추가") { showAddLink = true }
                Menu("터미널 연결 명령 복사") {
                    Button("Worker") { model.copyJoinCommand(for: set.id, role: .worker) }
                    Button("Reviewer") { model.copyJoinCommand(for: set.id, role: .reviewer) }
                    Button("Other") { model.copyJoinCommand(for: set.id, role: .other) }
                }
                Menu("알림 미루기") {
                    Button("15분") { model.snooze(set.id, minutes: 15) }
                    Button("30분") { model.snooze(set.id, minutes: 30) }
                    Button("1시간") { model.snooze(set.id, minutes: 60) }
                }
                Divider()
                Menu("색상") {
                    ForEach(["#0A84FF", "#BF5AF2", "#30D158", "#FF9F0A", "#FF375F", "#64D2FF", "#FFD60A"], id: \.self) { color in
                        Button { model.setColor(set.id, color: color) } label: {
                            Text(color)
                        }
                    }
                }
                Button("이름 변경") {
                    editedName = set.label
                    isRenaming = true
                }
                Divider()
                Button("세트 삭제", role: .destructive) { model.deleteSet(set.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(set.groups) { group in
                let members = group.memberIDs.compactMap { id in set.members.first { $0.id == id } }
                GroupBlock(model: model, set: set, group: group, members: members, evaluation: evaluation)
            }

            let orphanMembers = set.members.filter { member in
                !set.groups.contains(where: { $0.memberIDs.contains(member.id) })
            }
            ForEach(orphanMembers) { member in
                MemberRow(model: model, set: set, member: member)
            }

            ForEach(set.attachments) { attachment in
                AttachmentRow(model: model, set: set, attachment: attachment)
            }

            if set.members.isEmpty && set.attachments.isEmpty {
                Text("터미널을 이 세트에 연결하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            HStack {
                if set.armed {
                    Label("모니터링 중", systemImage: "bell.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("알림 꺼짐", systemImage: "bell.slash")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("세트 열기") { model.focusSet(set.id) }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(.leading, 17)
        .padding(.trailing, 11)
        .padding(.vertical, 10)
    }

    private func commitRename() {
        model.renameSet(set.id, to: editedName)
        isRenaming = false
    }
}

private struct GroupBlock: View {
    @ObservedObject var model: CompanionAppModel
    let set: WorkSet
    let group: CmuxCompanionCore.WorkGroup
    let members: [WorkMember]
    let evaluation: SetEvaluation
    @State private var isDropTargeted = false

    private var groupEvaluation: GroupEvaluation? {
        evaluation.groups.first { $0.groupID == group.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: group.role?.symbolName ?? "person.2.fill")
                    .foregroundStyle(.secondary)
                Text(group.label)
                    .font(.caption.weight(.semibold))
                if group.required {
                    Text("필수")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.13), in: Capsule())
                }
                Spacer()
                if let value = groupEvaluation {
                    Text("\(value.activeCount)/\(value.requiredActiveCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(value.isSatisfied ? .green : .secondary)
                }
                Menu {
                    Button(group.required ? "필수 해제" : "필수로 지정") {
                        model.setGroupRequired(group.id, in: set.id, required: !group.required)
                    }
                    Divider()
                    Button("모두 작업 중이어야 함") {
                        model.setGroupPolicy(group.id, in: set.id, policy: .all)
                    }
                    if members.count > 1 {
                        Button("한 명 이상 작업 중") {
                            model.setGroupPolicy(group.id, in: set.id, policy: .minActive(1))
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            ForEach(members) { member in
                MemberRow(model: model, set: set, member: member)
            }
        }
        .padding(6)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [SurfaceDragTransport.contentType],
            isTargeted: $isDropTargeted
        ) { providers in
            guard let role = group.role else { return false }
            return SurfaceDragTransport.receiveOne(from: providers) { payload in
                _ = model.acceptSurfaceDrop(
                    payload,
                    onto: set.id,
                    role: role,
                    targetGroupID: group.id
                )
            }
        }
    }
}

private struct RoleDropStrip: View {
    @ObservedObject var model: CompanionAppModel
    let set: WorkSet

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("끌어서 그룹 지정", systemImage: "hand.draw.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach([MemberRole.worker, .reviewer, .pr, .other], id: \.self) { role in
                    RoleDropTarget(model: model, setID: set.id, role: role)
                }
            }
        }
        .padding(7)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct RoleDropTarget: View {
    @ObservedObject var model: CompanionAppModel
    let setID: UUID
    let role: MemberRole
    @State private var isTargeted = false

    var body: some View {
        Label(role.displayName, systemImage: role.symbolName)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(isTargeted ? roleColor : Color.secondary)
            .background(
                isTargeted ? roleColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isTargeted ? roleColor : Color.secondary.opacity(0.22),
                        style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [4, 3])
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onDrop(
                of: [SurfaceDragTransport.contentType],
                isTargeted: $isTargeted
            ) { providers in
                SurfaceDragTransport.receiveOne(from: providers) { payload in
                    _ = model.acceptSurfaceDrop(payload, onto: setID, role: role)
                }
            }
            .help("터미널 카드를 \(role.displayName)로 끌어 놓기")
            .accessibilityLabel("\(role.displayName) 드롭 영역")
            .accessibilityHint("드래그한 cmux 창을 이 역할로 연결합니다")
    }

    private var roleColor: Color {
        switch role {
        case .worker: return .blue
        case .reviewer: return .purple
        case .pr: return .indigo
        case .other: return .secondary
        }
    }
}

private struct MemberRow: View {
    @ObservedObject var model: CompanionAppModel
    let set: WorkSet
    let member: WorkMember
    @State private var isRenaming = false
    @State private var editedLabel = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SurfaceDragHandle(
                payload: SurfaceDragPayload(
                    origin: .member,
                    surfaceID: member.surfaceID,
                    sourceSetID: set.id,
                    itemID: member.id
                ),
                previewTitle: member.label,
                previewSubtitle: member.role.displayName,
                previewSystemImage: member.role.symbolName,
                help: "다른 Worker/Reviewer 영역으로 드래그하여 이동"
            )
            .padding(.top, 2)

            Button { model.focus(member) } label: {
                HStack(alignment: .top, spacing: 8) {
                RuntimeDot(state: member.runtimeState)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(member.label)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        WorkloadBadge(
                            workload: model.workload(for: member),
                            isRemote: member.isRemote
                        )
                        Spacer()
                        Text(member.runtimeState.displayName)
                            .font(.caption)
                            .foregroundStyle(member.runtimeState.color)
                        RelativeTimestamp(date: member.lastSubmittedAt)
                            .font(.caption2)
                    }
                    if model.showPromptPreview, let text = member.lastSubmittedText, !text.isEmpty {
                        Text(text.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("이름 변경") {
                    editedLabel = member.label
                    isRenaming = true
                }
                Divider()
                Button("세트에서 제거", role: .destructive) {
                    model.removeMember(member.id, from: set.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(7)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .alert("멤버 라벨 변경", isPresented: $isRenaming) {
            TextField("라벨", text: $editedLabel)
            Button("저장") { model.renameMember(member.id, in: set.id, to: editedLabel) }
            Button("제거", role: .destructive) { model.removeMember(member.id, from: set.id) }
            Button("취소", role: .cancel) {}
        }
    }
}

private struct AttachmentRow: View {
    @ObservedObject var model: CompanionAppModel
    let set: WorkSet
    let attachment: WorkAttachment

    var body: some View {
        HStack(spacing: 8) {
            SurfaceDragHandle(
                payload: SurfaceDragPayload(
                    origin: .attachment,
                    surfaceID: attachment.surfaceID,
                    sourceSetID: set.id,
                    itemID: attachment.id
                ),
                previewTitle: attachment.label,
                previewSubtitle: "PR",
                previewSystemImage: "arrow.triangle.pull",
                help: "다른 세트의 PR 영역으로 이동하거나 그룹에서 내리기"
            )
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.purple)
            Button { model.focus(attachment) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let host = attachment.url?.host {
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { model.removeAttachment(attachment.id, from: set.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(7)
        .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UnlinkedSurfaceRow: View {
    @ObservedObject var model: CompanionAppModel
    let surface: LiveSurface

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: surface.workload.symbolName)
                .frame(width: 18)
                .foregroundStyle(surface.workload.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(surface.displayTitle)
                        .font(.subheadline)
                        .lineLimit(1)
                    WorkloadBadge(workload: surface.workload, isRemote: surface.isRemote)
                }
                Text(surface.workspaceTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            RuntimeDot(state: surface.runtimeState)
            SurfaceDragHandle(
                payload: SurfaceDragPayload(
                    origin: .liveSurface,
                    surfaceID: surface.id,
                    sourceSetID: nil,
                    itemID: nil
                ),
                previewTitle: surface.displayTitle,
                previewSubtitle: surface.isBrowser ? "PR" : surface.workspaceTitle,
                previewSystemImage: surface.isBrowser ? "globe" : "terminal",
                help: surface.isBrowser
                    ? "세트의 PR 영역으로 드래그"
                    : "세트의 Worker/Reviewer 영역으로 드래그"
            )
            Menu("연결") {
                ForEach(model.sets) { set in
                    Menu(set.label) {
                        if surface.isBrowser {
                            Button("PR 페이지") { model.add(surface: surface, to: set.id, role: .pr) }
                        } else {
                            Button("Worker") { model.add(surface: surface, to: set.id, role: .worker) }
                            Button("Reviewer") { model.add(surface: surface, to: set.id, role: .reviewer) }
                            Button("Other") { model.add(surface: surface, to: set.id, role: .other) }
                        }
                    }
                }
            }
            .disabled(model.sets.isEmpty)
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

private struct WorkloadBadge: View {
    let workload: SurfaceWorkload
    let isRemote: Bool

    private var label: String {
        isRemote ? "\(workload.displayName) · Remote" : workload.displayName
    }

    var body: some View {
        Label(label, systemImage: workload.symbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(workload.color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(workload.color.opacity(0.11), in: Capsule())
            .accessibilityLabel("실행 유형: \(label)")
    }
}

private extension SurfaceWorkload {
    var symbolName: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkles"
        case .shell: return "terminal"
        case .browser: return "globe"
        case .otherAgent: return "cpu"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .codex: return .teal
        case .claude: return .orange
        case .shell: return .secondary
        case .browser: return .purple
        case .otherAgent: return .indigo
        case .unknown: return .secondary
        }
    }
}

private struct SurfaceDragHandle: View {
    let payload: SurfaceDragPayload
    let previewTitle: String
    let previewSubtitle: String
    let previewSystemImage: String
    let help: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.medium))
            .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
            .frame(width: 32, height: 32)
            .background(
                isHovering ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(isHovering ? 0.30 : 0.12))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onDrag({
                SurfaceDragTransport.provider(for: payload)
            }, preview: {
                SurfaceDragPreview(
                    title: previewTitle,
                    subtitle: previewSubtitle,
                    systemImage: previewSystemImage
                )
            })
            .onHover { isHovering = $0 }
            .help(help)
            .accessibilityLabel("드래그 핸들")
            .accessibilityHint(help)
    }
}

private struct UnlinkDropTarget: View {
    @ObservedObject var model: CompanionAppModel
    @State private var isTargeted = false

    var body: some View {
        Label("그룹에서 내리기", systemImage: "tray.and.arrow.down.fill")
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(isTargeted ? Color.red : Color.secondary)
            .background(
                isTargeted ? Color.red.opacity(0.16) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isTargeted ? Color.red : Color.secondary.opacity(0.24),
                        style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [5, 3])
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onDrop(
                of: [SurfaceDragTransport.contentType],
                isTargeted: $isTargeted
            ) { providers in
                SurfaceDragTransport.receiveOne(from: providers) { payload in
                    _ = model.acceptUnlinkDrop(payload)
                }
            }
            .help("연결된 멤버 또는 PR을 여기에 놓아 논리 그룹에서만 해제")
            .accessibilityLabel("그룹에서 내리기 드롭 영역")
            .accessibilityHint("cmux 창은 닫지 않고 Companion 그룹 연결만 해제합니다")
    }
}

private struct SurfaceDragPreview: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.accentColor.opacity(0.45))
        }
    }
}
