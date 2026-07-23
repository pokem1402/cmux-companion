import AppKit
import SwiftUI
import CmuxCompanionCore

struct DashboardRootView: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject var updater: AppUpdateController
    @AppStorage("CmuxCompanionDashboardSelectedSet") private var selectedSetIDRaw = ""
    @State private var searchText = ""
    @State private var newSetName = ""
    @State private var showUpdateConfirmation = false
    @State private var presentedSetNameConflict: String?

    private var searchResults: CompanionSearchResults {
        CompanionSearch.results(
            sets: model.sets,
            unlinkedSurfaces: model.unlinkedSurfaces,
            allLiveSurfaces: model.liveSurfaces,
            query: searchText
        )
    }

    private var selectedSetID: UUID? {
        UUID(uuidString: selectedSetIDRaw)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                DashboardHeader(
                    model: model,
                    updater: updater,
                    searchText: $searchText,
                    onSearchSubmit: { selectFirstSearchMatch(using: proxy) },
                    onInstallUpdate: requestUpdateInstall
                )

                DashboardNoticeArea(model: model, updater: updater)

                Divider()

                HSplitView {
                    DashboardSetSidebar(
                        model: model,
                        sets: searchResults.sets,
                        matchingSetIDs: searchResults.matchingSetIDs,
                        searchIsActive: searchResults.isActive,
                        usesDisplayOrder: searchResults.usesDisplayOrder,
                        selectedSetID: selectedSetID,
                        newSetName: $newSetName,
                        onSelectSet: { select($0, using: proxy) },
                        onCreateSet: { createSet(using: proxy) }
                    )
                    .frame(minWidth: 190, idealWidth: 225, maxWidth: 285)

                    DashboardSetBoard(
                        model: model,
                        searchResults: searchResults,
                        selectedSetID: selectedSetID,
                        onSelectSet: { selectedSetIDRaw = $0.uuidString }
                    )
                    .frame(minWidth: 410, idealWidth: 660)

                    DashboardSurfacePanel(
                        model: model,
                        searchResults: searchResults,
                        query: searchText,
                        onSelectSet: { select($0, using: proxy) }
                    )
                    .frame(minWidth: 270, idealWidth: 320, maxWidth: 430)
                }

                if model.hasLinkedDraggableItems {
                    Divider()
                    UnlinkDropTarget(model: model)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
            .onAppear {
                reconcileSelection(using: proxy, scroll: false)
            }
            .onChange(of: model.sets.map(\.id)) { _, _ in
                reconcileSelection(using: proxy, scroll: false)
            }
            .onChange(of: searchText) { _, value in
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                let matches = searchResults.matchingSetIDs
                if selectedSetID.map(matches.contains) != true,
                   let first = searchResults.sets.first(where: { matches.contains($0.id) }) {
                    select(first.id, using: proxy)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
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
            Text("GitHub digest와 SHA-256 파일을 확인한 뒤 현재 앱을 백업하고 교체합니다.")
        }
        .alert(
            "이미 사용 중인 세트 이름",
            isPresented: Binding(
                get: { presentedSetNameConflict != nil },
                set: { isPresented in
                    if !isPresented { presentedSetNameConflict = nil }
                }
            )
        ) {
            Button("확인", role: .cancel) { presentedSetNameConflict = nil }
        } message: {
            Text("“\(presentedSetNameConflict ?? "")” 세트가 이미 있습니다. 다른 이름을 입력해 주세요.")
        }
    }

    private func select(_ setID: UUID, using proxy: ScrollViewProxy) {
        selectedSetIDRaw = setID.uuidString
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(setID, anchor: .top)
            }
        }
    }

    private func selectFirstSearchMatch(using proxy: ScrollViewProxy) {
        let matches = searchResults.matchingSetIDs
        guard let first = searchResults.sets.first(where: { matches.contains($0.id) }) else {
            return
        }
        select(first.id, using: proxy)
    }

    private func reconcileSelection(using proxy: ScrollViewProxy, scroll: Bool) {
        if let selectedSetID, model.sets.contains(where: { $0.id == selectedSetID }) {
            return
        }
        guard let first = model.sets.first else {
            selectedSetIDRaw = ""
            return
        }
        selectedSetIDRaw = first.id.uuidString
        if scroll { select(first.id, using: proxy) }
    }

    private func createSet(using proxy: ScrollViewProxy) {
        guard model.createSet(named: newSetName), let created = model.sets.last else {
            if let conflict = model.conflictingSetName {
                model.dismissSetNameConflict()
                presentedSetNameConflict = conflict
            }
            return
        }
        newSetName = ""
        select(created.id, using: proxy)
    }

    private func requestUpdateInstall() {
        if updater.canInstallInPlace {
            showUpdateConfirmation = true
        } else {
            updater.openReleasePage()
        }
    }
}

private struct DashboardHeader: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject var updater: AppUpdateController
    @Binding var searchText: String
    let onSearchSubmit: () -> Void
    let onInstallUpdate: () -> Void

    private var activeCount: Int {
        model.evaluations.values.filter { $0.status == .active }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.attentionCount > 0 ? Color.orange.opacity(0.16) : Color.accentColor.opacity(0.14))
                Image(systemName: model.attentionCount > 0 ? "exclamationmark.bubble.fill" : "rectangle.3.group.fill")
                    .font(.title3)
                    .foregroundStyle(model.attentionCount > 0 ? Color.orange : Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cmux Companion")
                    .font(.headline)
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.isCmuxConnected ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(model.isCmuxConnected ? "cmux 연결됨" : "cmux 연결 대기 중")
                    Text("·")
                    Text("진행 \(activeCount)")
                    if model.attentionCount > 0 {
                        Text("· 확인 \(model.attentionCount)")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("세트 · 그룹 · workspace · shell 검색", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit(onSearchSubmit)
                    .onExitCommand { searchText = "" }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: 260, maxWidth: 520)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))

            Spacer(minLength: 0)

            Toggle("프롬프트", isOn: $model.showPromptPreview)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("각 터미널의 마지막 입력 미리보기")

            if updater.phase == .available {
                Button("v\(updater.updateVersionText ?? "?") 업데이트") {
                    onInstallUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button {
                    Task { await updater.checkForUpdates() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(updater.isBusy)
                .help("업데이트 확인")
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .help("cmux 상태 새로고침")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct DashboardNoticeArea: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject var updater: AppUpdateController

    var body: some View {
        VStack(spacing: 5) {
            if let error = model.lastError {
                DashboardNotice(
                    title: "상태를 확인해야 합니다",
                    detail: error,
                    color: .orange,
                    symbol: "exclamationmark.triangle.fill",
                    onDismiss: model.dismissError
                )
            }
            if let feedback = model.hookSetupFeedback {
                DashboardNotice(
                    title: feedback.title,
                    detail: feedback.detail,
                    color: feedback.kind == .success ? .green : .orange,
                    symbol: feedback.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    onDismiss: model.dismissHookSetupFeedback
                )
            }
            switch updater.phase {
            case .checking:
                DashboardNotice(title: "업데이트 확인 중…", detail: "", color: .secondary, symbol: "arrow.triangle.2.circlepath")
            case .upToDate:
                DashboardNotice(
                    title: "최신 버전입니다",
                    detail: "현재 v\(updater.currentVersionText)",
                    color: .green,
                    symbol: "checkmark.circle.fill",
                    onDismiss: updater.dismissStatus
                )
            case .downloading:
                DashboardNotice(title: "업데이트 다운로드 및 검증 중…", detail: "", color: .blue, symbol: "arrow.down.circle.fill")
            case .installing:
                DashboardNotice(title: "앱 교체 후 재실행 중…", detail: "", color: .blue, symbol: "arrow.clockwise.circle.fill")
            case .failed(let message):
                DashboardNotice(title: "업데이트 실패", detail: message, color: .orange, symbol: "exclamationmark.triangle.fill", onDismiss: updater.dismissStatus)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct DashboardNotice: View {
    let title: String
    let detail: String
    let color: Color
    let symbol: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DashboardSetSidebar: View {
    @ObservedObject var model: CompanionAppModel
    let sets: [WorkSet]
    let matchingSetIDs: Set<UUID>
    let searchIsActive: Bool
    let usesDisplayOrder: Bool
    let selectedSetID: UUID?
    @Binding var newSetName: String
    let onSelectSet: (UUID) -> Void
    let onCreateSet: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("작업 세트", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.sets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    if sets.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: searchIsActive ? "magnifyingglass" : "square.stack.3d.up.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(searchIsActive ? "일치하는 세트 없음" : "아직 세트가 없습니다")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }

                    ForEach(sets) { set in
                        let evaluation = model.evaluations[set.id] ?? SetEvaluator.evaluate(set)
                        DashboardSetSidebarItem(
                            model: model,
                            set: set,
                            evaluation: evaluation,
                            selected: selectedSetID == set.id,
                            reorderingEnabled: !searchIsActive && !usesDisplayOrder,
                            forceExpanded: searchIsActive && matchingSetIDs.contains(set.id),
                            onSelect: { onSelectSet(set.id) }
                        )
                        .opacity(searchIsActive && !matchingSetIDs.contains(set.id) ? 0.52 : 1)
                    }
                }
                .padding(8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("새 세트 이름", text: $newSetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onCreateSet)
                    Button(action: onCreateSet) {
                        Image(systemName: "plus")
                    }
                    .disabled(newSetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("세트 추가")
                }
                if let existing = model.existingSetName(matching: newSetName) {
                    Label("“\(existing)” 이름 사용 중", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct DashboardSetSidebarItem: View {
    @ObservedObject var model: CompanionAppModel
    let set: WorkSet
    let evaluation: SetEvaluation
    let selected: Bool
    let reorderingEnabled: Bool
    let forceExpanded: Bool
    let onSelect: () -> Void
    @State private var isOrderDropTargeted = false

    private var targetedBinding: Binding<Bool> {
        Binding(
            get: { reorderingEnabled && isOrderDropTargeted },
            set: { isOrderDropTargeted = reorderingEnabled && $0 }
        )
    }

    private var orderDropEdge: VerticalEdge? {
        guard let sourceSetID = SetOrderDragTransport.currentPayload?.setID,
              sourceSetID != set.id,
              let sourceIndex = model.sets.firstIndex(where: { $0.id == sourceSetID }),
              let targetIndex = model.sets.firstIndex(where: { $0.id == set.id }) else { return nil }
        return sourceIndex < targetIndex ? .bottom : .top
    }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onSelect) {
                DashboardSetNavigationRow(
                    set: set,
                    evaluation: evaluation,
                    selected: selected,
                    collapsed: !forceExpanded && model.isSetCollapsed(set.id)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            SetOrderDragHandle(
                set: set,
                isEnabled: reorderingEnabled,
                disabledHelp: "검색을 지우면 세트 순서를 변경할 수 있습니다"
            )
        }
        .padding(.trailing, 3)
        .background(
            isOrderDropTargeted && reorderingEnabled
                ? Color.accentColor.opacity(0.11)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(alignment: orderDropEdge == .bottom ? .bottom : .top) {
            if isOrderDropTargeted && reorderingEnabled, orderDropEdge != nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .padding(.horizontal, 3)
                    .offset(y: orderDropEdge == .bottom ? 2 : -2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [SetOrderDragTransport.contentType],
            isTargeted: targetedBinding
        ) { providers in
            guard reorderingEnabled else { return false }
            return SetOrderDragTransport.receiveOne(from: providers) { payload in
                _ = model.moveSet(payload.setID, relativeTo: set.id)
            }
        }
        .contextMenu {
            Button(
                forceExpanded
                    ? "검색 중 임시 펼쳐짐"
                    : (model.isSetCollapsed(set.id) ? "세트 펼치기" : "세트 최소화")
            ) {
                model.toggleSetCollapsed(set.id)
            }
            .disabled(forceExpanded)
            Divider()
            Button("한 칸 위로") { _ = model.moveSet(set.id, by: -1) }
                .disabled(!reorderingEnabled || !model.canMoveSet(set.id, by: -1))
            Button("한 칸 아래로") { _ = model.moveSet(set.id, by: 1) }
                .disabled(!reorderingEnabled || !model.canMoveSet(set.id, by: 1))
        }
    }
}

private struct DashboardSetNavigationRow: View {
    let set: WorkSet
    let evaluation: SetEvaluation
    let selected: Bool
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(companionHex: set.color))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(set.label)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(set.members.count)명 · PR \(set.attachments.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if collapsed {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("최소화됨")
            }
            Image(systemName: set.isCurrentGenerationCompleted ? "checkmark.circle.fill" : evaluation.status.symbolName)
                .foregroundStyle(set.isCurrentGenerationCompleted ? Color.blue : evaluation.status.color)
                .help(set.isCurrentGenerationCompleted ? "완료" : evaluation.status.displayName)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            selected ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }
}

private struct DashboardSetBoard: View {
    @ObservedObject var model: CompanionAppModel
    let searchResults: CompanionSearchResults
    let selectedSetID: UUID?
    let onSelectSet: (UUID) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 620), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("세트 보드")
                        .font(.headline)
                    Text("터미널과 PR을 역할 영역으로 끌어 그룹을 구성하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = model.lastRefreshAt {
                    HStack(spacing: 4) {
                        Text("갱신")
                        RelativeTimestamp(date: date)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.sets.isEmpty {
                DashboardBoardEmptyState(
                    symbol: "square.stack.3d.up.slash",
                    title: "아직 작업 세트가 없습니다",
                    detail: "왼쪽 아래에서 세트를 만든 뒤 오른쪽의 cmux 창을 끌어오세요."
                )
            } else if !searchResults.hasAnyMatch {
                DashboardBoardEmptyState(
                    symbol: "magnifyingglass",
                    title: "검색 결과가 없습니다",
                    detail: "세트, 그룹, workspace 또는 shell 이름을 다시 확인하세요."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(searchResults.sets) { set in
                            SetCardView(
                                model: model,
                                set: set,
                                evaluation: model.evaluations[set.id] ?? SetEvaluator.evaluate(set),
                                forceExpanded: searchResults.isActive
                                    && searchResults.matchingSetIDs.contains(set.id),
                                allowsReordering: !searchResults.isActive && !searchResults.usesDisplayOrder
                            )
                            .id(set.id)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        selectedSetID == set.id
                                            ? Color.accentColor.opacity(0.75)
                                            : Color.clear,
                                        lineWidth: 2
                                    )
                                    .allowsHitTesting(false)
                            }
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded { onSelectSet(set.id) })
                            .opacity(
                                searchResults.isActive
                                    && !searchResults.matchingSetIDs.contains(set.id)
                                    ? 0.52
                                    : 1
                            )
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DashboardBoardEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

private enum DashboardSurfaceScope: String, CaseIterable, Identifiable {
    case all
    case unlinked

    var id: Self { self }
    var label: String {
        switch self {
        case .all: return "전체"
        case .unlinked: return "미연결"
        }
    }
}

private struct DashboardSurfacePanel: View {
    @ObservedObject var model: CompanionAppModel
    let searchResults: CompanionSearchResults
    let query: String
    let onSelectSet: (UUID) -> Void
    @State private var scope: DashboardSurfaceScope = .all

    private var unlinkedSurfaceIDs: Set<String> {
        Set(model.unlinkedSurfaces.map(\.id))
    }

    private var directMatchIDs: Set<String> {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Set(model.liveSurfaces.map(\.id))
        }
        return Set(model.liveSurfaces.filter {
            CompanionSearch.matches(surface: $0, query: query)
        }.map(\.id))
    }

    private var displayedSurfaces: [LiveSurface] {
        let base = model.liveSurfaces.filter { surface in
            scope == .all || unlinkedSurfaceIDs.contains(surface.id)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [LiveSurface]
        if trimmed.isEmpty {
            filtered = base
        } else {
            let direct = base.filter { directMatchIDs.contains($0.id) }
            filtered = direct.isEmpty && !searchResults.matchingSetIDs.isEmpty ? base : direct
        }
        return filtered.sorted { lhs, rhs in
            let lhsUnlinked = unlinkedSurfaceIDs.contains(lhs.id)
            let rhsUnlinked = unlinkedSurfaceIDs.contains(rhs.id)
            if lhsUnlinked != rhsUnlinked { return lhsUnlinked && !rhsUnlinked }
            let workspaceOrder = lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle)
            if workspaceOrder != .orderedSame { return workspaceOrder == .orderedAscending }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("cmux 창", systemImage: "rectangle.stack.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(model.liveSurfaces.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Picker("표시 범위", selection: $scope) {
                    ForEach(DashboardSurfaceScope.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)

            Divider()

            if displayedSurfaces.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: scope == .unlinked ? "link.circle.fill" : "rectangle.stack.badge.minus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(scope == .unlinked ? "모든 창이 연결되었습니다" : "표시할 cmux 창이 없습니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(displayedSurfaces) { surface in
                            DashboardSurfaceRow(
                                model: model,
                                surface: surface,
                                linkedSet: model.linkedSet(for: surface),
                                isUnlinked: unlinkedSurfaceIDs.contains(surface.id),
                                onSelectSet: onSelectSet
                            )
                            .opacity(
                                !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && !directMatchIDs.contains(surface.id)
                                    ? 0.54
                                    : 1
                            )
                        }
                    }
                    .padding(9)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

}

private struct DashboardSurfaceRow: View {
    @ObservedObject var model: CompanionAppModel
    let surface: LiveSurface
    let linkedSet: WorkSet?
    let isUnlinked: Bool
    let onSelectSet: (UUID) -> Void

    private var promptText: String? {
        let candidate = [surface.displayOnlyPromptText, surface.lastSubmittedText]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let candidate else { return nil }
        return candidate.replacingOccurrences(of: "\n", with: " ")
    }

    private var promptDate: Date? {
        surface.displayOnlyPromptText?.isEmpty == false
            ? surface.displayOnlyPromptAt
            : surface.lastSubmittedAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: surface.isBrowser ? "globe" : surface.workload.symbolName)
                    .frame(width: 20)
                    .foregroundStyle(surface.isBrowser ? Color.purple : surface.workload.color)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(surface.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        WorkloadBadge(workload: surface.workload, isRemote: surface.isRemote)
                        RuntimeDot(state: surface.runtimeState)
                        RelativeTimestamp(date: promptDate)
                            .font(.caption2)
                    }
                    Text(surface.workspaceTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 3)

                if isUnlinked {
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
                    connectionMenu
                } else {
                    Button { model.focus(surface) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .help("cmux에서 열기")
                }
            }

            if model.showPromptPreview, let promptText {
                Text(promptText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let linkedSet {
                Button { onSelectSet(linkedSet.id) } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(companionHex: linkedSet.color))
                            .frame(width: 7, height: 7)
                        Text(linkedSet.label)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Text(surface.isBrowser ? "PR 영역으로 끌어 연결" : "역할 영역으로 끌어 연결")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(
            isUnlinked ? Color.accentColor.opacity(0.065) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isUnlinked ? Color.accentColor.opacity(0.15) : Color.clear)
                .allowsHitTesting(false)
        }
    }

    private var connectionMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: "link.badge.plus")
                .frame(width: 24, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(model.sets.isEmpty)
        .help("메뉴로 세트에 연결")
    }
}
