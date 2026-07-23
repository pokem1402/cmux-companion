import AppKit
import SwiftUI
import CmuxCompanionCore

struct MenuBarStatusAnchor {
    var frame: NSRect
    var screen: NSScreen
}

private final class FirstMouseInteractionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AttentionPanelController {
    fileprivate static let panelWidth: CGFloat = 382
    private static let basePanelHeight: CGFloat = 124
    private static let completionLifetime: TimeInterval = 30

    private let panel: NSPanel
    private let anchorProvider: () -> MenuBarStatusAnchor?
    private var queue = PendingInteractionQueue()
    private var dismissWorkItem: DispatchWorkItem?
    private var presentationGeneration = 0

    var onOpen: ((PendingInteraction) -> Void)?

    var currentInteractionForTesting: PendingInteraction? { queue.current }
    var pendingCountForTesting: Int { queue.items.count }
    var panelFrameForTesting: NSRect { panel.frame }

    init(anchorProvider: @escaping () -> MenuBarStatusAnchor?) {
        self.anchorProvider = anchorProvider
        self.panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.panelWidth,
                height: Self.basePanelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
    }

    func enqueue(_ interaction: PendingInteraction) {
        queue.enqueue(interaction)
        removeExpiredCompletions(now: Date())
        presentCurrent()
    }

    /// Removes cards whose underlying state has already cleared. Completion
    /// cards are short-lived event receipts, while input/attention cards track
    /// the latest authoritative member and set evaluations.
    func reconcile(sets: [WorkSet], evaluations: [UUID: SetEvaluation], now: Date = Date()) {
        let setByID = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0) })
        queue.removeAll { interaction in
            guard let set = setByID[interaction.setID] else { return true }
            switch interaction.kind {
            case .inputRequired:
                guard let memberID = interaction.memberID,
                      let member = set.members.first(where: { $0.id == memberID }) else { return true }
                return member.runtimeState != .waiting
            case .attention:
                return evaluations[interaction.setID]?.shouldNotify != true
            case .completion:
                return now.timeIntervalSince(interaction.createdAt) > Self.completionLifetime
            }
        }
        presentCurrent()
    }

    func dismissCurrent() {
        guard let current = queue.current else {
            hidePanel()
            return
        }
        _ = queue.remove(id: current.id)
        presentCurrent()
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        queue.removeAll { _ in true }
        hidePanel()
    }

    private func openCurrent() {
        guard let current = queue.current else { return }
        _ = queue.remove(id: current.id)
        presentCurrent()
        onOpen?(current)
    }

    private func presentCurrent() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        removeExpiredCompletions(now: Date())

        guard let current = queue.current else {
            hidePanel()
            return
        }

        presentationGeneration += 1
        let showsOptions = current.sensitivity == .normal && !current.options.isEmpty
        let showsPrompt = current.sensitivity == .normal
            && current.promptPreview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let optionsHeight: CGFloat = showsOptions ? 30 : 0
        let promptHeight: CGFloat = showsPrompt ? 30 : 0
        let height = Self.basePanelHeight + optionsHeight + promptHeight
        panel.setContentSize(NSSize(width: Self.panelWidth, height: height))
        panel.contentView = FirstMouseInteractionHostingView(
            rootView: AttentionCardView(
                interaction: current,
                pendingCount: queue.items.count,
                onOpen: { [weak self] in self?.openCurrent() },
                onDismiss: { [weak self] in self?.dismissCurrent() }
            )
        )
        positionPanel()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
        scheduleAutoDismiss(for: current)
    }

    private func scheduleAutoDismiss(for interaction: PendingInteraction) {
        let delay: TimeInterval?
        switch interaction.kind {
        case .inputRequired:
            delay = nil
        case .completion:
            delay = 5
        case .attention:
            delay = 6
        }
        guard let delay else { return }
        let interactionID = interaction.id
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.queue.current?.id == interactionID else { return }
            _ = self.queue.remove(id: interactionID)
            self.presentCurrent()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func removeExpiredCompletions(now: Date) {
        queue.removeAll { interaction in
            interaction.kind == .completion
                && now.timeIntervalSince(interaction.createdAt) > Self.completionLifetime
        }
    }

    private func positionPanel() {
        if let anchor = anchorProvider() {
            let visible = anchor.screen.visibleFrame
            let x = min(
                max(anchor.frame.midX - panel.frame.width / 2, visible.minX + 8),
                visible.maxX - panel.frame.width - 8
            )
            let desiredY = anchor.frame.minY - panel.frame.height - 7
            let y = min(
                max(desiredY, visible.minY + 8),
                visible.maxY - panel.frame.height - 8
            )
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.maxY - panel.frame.height - 8
            )
        )
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      self.queue.current == nil else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}

private struct AttentionCardView: View {
    let interaction: PendingInteraction
    let pendingCount: Int
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var tint: Color {
        switch interaction.kind {
        case .inputRequired: return .orange
        case .completion: return .green
        case .attention: return .yellow
        }
    }

    private var symbol: String {
        switch interaction.kind {
        case .inputRequired: return "exclamationmark.bubble.fill"
        case .completion: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        }
    }

    private var kindLabel: String {
        switch interaction.kind {
        case .inputRequired: return "입력 필요"
        case .completion: return "작업 완료"
        case .attention: return "확인 필요"
        }
    }

    private var contextLabel: String? {
        [interaction.memberTitle, interaction.agent?.capitalized, interaction.isRemote ? "Remote" : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    private var promptPreview: String? {
        guard interaction.sensitivity == .normal,
              let prompt = interaction.promptPreview?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        return String(prompt.prefix(180))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kindLabel)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint)
                        Text(interaction.setTitle)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    if let contextLabel {
                        Text(contextLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(interaction.sensitivity == .sensitive ? "민감한 입력이 원래 터미널에서 대기 중입니다." : interaction.detail)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(2)
                    if let promptPreview {
                        Text("“\(promptPreview)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if pendingCount > 1 {
                    Text("+\(pendingCount - 1)")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("이 알림 닫기")
            }

            if interaction.sensitivity == .normal, !interaction.options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(interaction.options.prefix(3))) { option in
                        Text(option.label)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                }
                .padding(.leading, 38)
            }

            HStack {
                if interaction.kind == .inputRequired,
                   interaction.replyCapability == .openTerminalOnly {
                    Text("응답은 원래 터미널에서 진행됩니다")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("cmux에서 열기", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(tint)
            }
            .padding(.leading, 38)
        }
        .padding(12)
        .frame(width: AttentionPanelController.panelWidth - 6)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(3)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
