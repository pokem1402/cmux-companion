import AppKit
import SwiftUI

enum DashboardWindowMetrics {
    static let defaultContentSize = NSSize(width: 1_180, height: 760)
    static let minimumWindowSize = NSSize(width: 900, height: 600)
    static let frameAutosaveName = "CmuxCompanionDashboardWindow"

    /// Keeps a restored window wholly reachable after a display is removed or
    /// its resolution changes. The minimum size remains an AppKit constraint;
    /// on an unusually small display the visible frame wins so the title bar
    /// and resize controls do not become inaccessible.
    static func clampedFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        guard !visibleFrame.isEmpty else { return frame }

        let width = min(max(1, frame.width), visibleFrame.width)
        let height = min(max(1, frame.height), visibleFrame.height)
        let maximumX = visibleFrame.maxX - width
        let maximumY = visibleFrame.maxY - height
        let origin = NSPoint(
            x: min(max(frame.minX, visibleFrame.minX), maximumX),
            y: min(max(frame.minY, visibleFrame.minY), maximumY)
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let model: CompanionAppModel
    private let updater: AppUpdateController
    private let frameAutosaveName: String
    private var isTerminating = false

    var modelForTesting: CompanionAppModel { model }
    var updaterForTesting: AppUpdateController { updater }
    var frameAutosaveNameForTesting: String { frameAutosaveName }
    var minimumWindowSizeForTesting: NSSize { window?.minSize ?? .zero }
    var supportsFullScreenForTesting: Bool {
        window?.collectionBehavior.contains(.fullScreenPrimary) == true
    }
    var isReleasedWhenClosedForTesting: Bool { window?.isReleasedWhenClosed ?? true }

    init(
        model: CompanionAppModel,
        updater: AppUpdateController,
        frameAutosaveName: String = DashboardWindowMetrics.frameAutosaveName
    ) {
        self.model = model
        self.updater = updater
        self.frameAutosaveName = frameAutosaveName

        let dashboardWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: DashboardWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        dashboardWindow.title = "Cmux Companion"
        dashboardWindow.minSize = DashboardWindowMetrics.minimumWindowSize
        dashboardWindow.collectionBehavior.insert(.fullScreenPrimary)
        dashboardWindow.tabbingMode = .disallowed
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.contentViewController = NSHostingController(
            rootView: DashboardRootView(model: model, updater: updater)
        )

        super.init(window: dashboardWindow)
        dashboardWindow.delegate = self
        restoreFrame(of: dashboardWindow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }

        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func showDashboard(_ sender: Any?) {
        show()
    }

    func prepareForTermination() {
        isTerminating = true
    }

    func windowWillClose(_ notification: Notification) {
        // Defer until AppKit has finished closing. If another entry point
        // reopens the retained window in the meantime, it must keep the app in
        // regular mode and retain its Dock icon.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isTerminating,
                  self.window?.isVisible != true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func restoreFrame(of window: NSWindow) {
        let restored = window.setFrameUsingName(frameAutosaveName)
        _ = window.setFrameAutosaveName(frameAutosaveName)

        if !restored {
            window.center()
            return
        }

        let targetScreen = bestScreen(for: window.frame)
        guard let targetScreen else {
            window.center()
            return
        }
        let clamped = DashboardWindowMetrics.clampedFrame(
            window.frame,
            to: targetScreen.visibleFrame
        )
        if clamped != window.frame {
            window.setFrame(clamped, display: false)
        }
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let intersectingScreen = screens.max { lhs, rhs in
            intersectionArea(frame, lhs.visibleFrame) < intersectionArea(frame, rhs.visibleFrame)
        }
        if let intersectingScreen,
           intersectionArea(frame, intersectingScreen.visibleFrame) > 0 {
            return intersectingScreen
        }
        return NSScreen.main ?? screens.first
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
