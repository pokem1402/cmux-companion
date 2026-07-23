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
