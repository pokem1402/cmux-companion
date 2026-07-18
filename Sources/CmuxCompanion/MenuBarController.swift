import AppKit
import Combine
import SwiftUI

enum MenuBarStatusLayout {
    /// A stable popover anchor that still has room for the symbol and a
    /// two-digit attention count. Variable-length items move the open popover
    /// whenever monitoring adds or removes the count label.
    static let itemLength: CGFloat = 48

    static func title(attentionCount: Int, updateAvailable: Bool) -> String {
        if attentionCount > 0 {
            return " \(min(attentionCount, 99))"
        }
        return updateAvailable ? " ↑" : ""
    }
}

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: CompanionAppModel
    private let updater: AppUpdateController
    private var cancellables: Set<AnyCancellable> = []

    /// Kept internal so the app self-test can guard the real AppKit anchor,
    /// rather than only testing the value supplied by the layout helper.
    var statusItemLengthForTesting: CGFloat { statusItem.length }
    var statusItemTitleForTesting: String { statusItem.button?.title ?? "" }

    init(model: CompanionAppModel, updater: AppUpdateController) {
        self.model = model
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: MenuBarStatusLayout.itemLength)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: CompanionRootView(model: model, updater: updater)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.toolTip = "Cmux Companion"
        }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        updater.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        updateStatusItem()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            presentPopover(relativeTo: button)
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            presentPopover(relativeTo: button)
        }
    }

    private func presentPopover(relativeTo button: NSStatusBarButton) {
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let attention = model.attentionCount
        let active = model.evaluations.values.filter { $0.status == .active }.count
        let updateAvailable = updater.phase == .available
        let symbol: String
        if attention > 0 {
            symbol = "exclamationmark.bubble.fill"
        } else if updateAvailable {
            symbol = "arrow.down.circle.fill"
        } else if active > 0 {
            symbol = "bolt.fill"
        } else if model.isCmuxConnected {
            symbol = "terminal.fill"
        } else {
            symbol = "terminal"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Cmux Companion")
        image?.isTemplate = attention == 0 && !updateAvailable
        button.image = image
        button.title = MenuBarStatusLayout.title(
            attentionCount: attention,
            updateAvailable: updateAvailable
        )
        button.contentTintColor = attention > 0
            ? .systemOrange
            : updateAvailable ? .systemBlue : nil
        if attention > 0 {
            button.toolTip = "\(attention)개 작업 세트에 확인이 필요합니다"
        } else if updateAvailable {
            button.toolTip = "Cmux Companion v\(updater.updateVersionText ?? "새 버전") 업데이트 가능"
        } else if active > 0 {
            button.toolTip = "\(active)개 작업 세트 진행 중"
        } else {
            button.toolTip = "Cmux Companion"
        }
    }
}
