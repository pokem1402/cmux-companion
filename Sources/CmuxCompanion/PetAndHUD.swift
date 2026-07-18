import AppKit
import SwiftUI
import CmuxCompanionCore

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct CompanionVisualState: Equatable {
    var status: SetActivityStatus = .idle
    var attentionCount: Int = 0
    var activeCount: Int = 0
    var title: String = "Cmux Companion"
    var detail: String = "대기 중"
}

final class FloatingPetController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var visualState = CompanionVisualState()
    var onClick: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 112, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = FirstMouseHostingView(rootView: PetView(state: visualState, onClick: { [weak self] in
            self?.onClick?()
        }))
        restorePosition()
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
        }
    }

    func update(_ state: CompanionVisualState) {
        guard state != visualState else { return }
        visualState = state
        panel.contentView = FirstMouseHostingView(rootView: PetView(state: state, onClick: { [weak self] in
            self?.onClick?()
        }))
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "floatingPetFrame")
    }

    private func restorePosition() {
        if let raw = UserDefaults.standard.string(forKey: "floatingPetFrame") {
            let frame = NSRectFromString(raw)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrame(frame, display: false)
                return
            }
        }
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - 132, y: frame.minY + 36))
    }
}

private struct PetView: View {
    let state: CompanionVisualState
    let onClick: () -> Void

    private var face: String {
        switch state.status {
        case .attention: return "!"
        case .incomplete: return "…"
        case .active: return "›_"
        case .idle: return "zZ"
        }
    }

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThickMaterial)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(state.status.color.opacity(0.7), lineWidth: 2)
                    VStack(spacing: 1) {
                        Text(face)
                            .font(.system(size: 23, weight: .black, design: .monospaced))
                            .foregroundStyle(state.status.color)
                        if state.attentionCount > 0 {
                            Text("\(state.attentionCount)")
                                .font(.caption2.bold().monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 70, height: 62)
                Text(state.status.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .buttonStyle(.plain)
    }
}

final class TopHUDController {
    private let panel: NSPanel
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
    }

    func show(title: String, detail: String, status: SetActivityStatus) {
        hideWorkItem?.cancel()
        panel.contentView = NSHostingView(
            rootView: TransitionHUDView(title: title, detail: detail, status: status)
        )
        positionOnActiveScreen()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                self.panel.orderOut(nil)
            })
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 12))
    }
}

private struct TransitionHUDView: View {
    let title: String
    let detail: String
    let status: SetActivityStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.symbolName)
                .font(.title2)
                .foregroundStyle(status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(width: 360, height: 64)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(status.color.opacity(0.35), lineWidth: 1)
        )
        .padding(3)
    }
}
