import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: CompanionAppModel
    private var cancellables: Set<AnyCancellable> = []

    init(model: CompanionAppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 640)
        popover.contentViewController = NSHostingController(rootView: CompanionRootView(model: model))

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
        let symbol: String
        if attention > 0 {
            symbol = "exclamationmark.bubble.fill"
        } else if active > 0 {
            symbol = "bolt.fill"
        } else if model.isCmuxConnected {
            symbol = "terminal.fill"
        } else {
            symbol = "terminal"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Cmux Companion")
        image?.isTemplate = attention == 0
        button.image = image
        button.title = attention > 0 ? " \(attention)" : ""
        button.contentTintColor = attention > 0 ? .systemOrange : nil
        button.toolTip = attention > 0
            ? "\(attention)개 작업 세트에 확인이 필요합니다"
            : active > 0 ? "\(active)개 작업 세트 진행 중" : "Cmux Companion"
    }
}
