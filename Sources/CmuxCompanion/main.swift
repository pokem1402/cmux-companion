import AppKit
import Darwin
import CmuxCompanionCore

final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var model: CompanionAppModel!
    private var menuBar: MenuBarController!
    private var dashboard: DashboardWindowController!
    private var pet: FloatingPetController!
    private var attentionPanel: AttentionPanelController!
    private var notifications: NotificationCoordinator!
    private var updater: AppUpdateController!
    private var popoverLayout: PopoverLayoutSettings!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        model = CompanionAppModel()
        updater = AppUpdateController()
        popoverLayout = PopoverLayoutSettings()
        dashboard = DashboardWindowController(model: model, updater: updater)
        menuBar = MenuBarController(
            model: model,
            updater: updater,
            layout: popoverLayout,
            onOpenDashboard: { [weak self] in self?.dashboard.show() }
        )
        pet = FloatingPetController()
        attentionPanel = AttentionPanelController(
            anchorProvider: { [weak self] in self?.menuBar.attentionPanelAnchor }
        )
        notifications = NotificationCoordinator()
        configureMainMenu()

        notifications.onOpenSet = { [weak self] setID in
            self?.model.focusSet(setID)
        }
        notifications.onSnoozeSet = { [weak self] setID in
            self?.model.snooze(setID, minutes: 15)
        }
        notifications.isStillActionable = { [weak self] setID in
            self?.model.evaluations[setID]?.shouldNotify == true
        }
        notifications.includePromptPreview = { [weak self] in
            self?.model.showPromptPreview == true
        }
        attentionPanel.onOpen = { [weak self] interaction in
            self?.model.focus(interaction)
        }

        pet.onClick = { [weak self] in self?.menuBar.showPopover() }
        model.onPetVisibilityChanged = { [weak self] visible in self?.pet.setVisible(visible) }
        model.onEvaluationsChanged = { [weak self] sets, evaluations in
            guard let self else { return }
            self.notifications.update(sets: sets, evaluations: evaluations)
            self.attentionPanel.reconcile(sets: sets, evaluations: evaluations)
            self.updatePet(sets: sets, evaluations: evaluations)
        }
        model.onAttentionTransition = { [weak self] set, evaluation, _ in
            guard let self else { return }
            self.notifications.schedule(set: set, evaluation: evaluation)
        }
        model.onInteractionTransition = { [weak self] interaction in
            self?.attentionPanel.enqueue(interaction)
        }

        pet.setVisible(model.showPet)
        updatePet(sets: model.sets, evaluations: model.evaluations)
        model.start()
        updater.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dashboard.prepareForTermination()
        attentionPanel.hide()
        model.stop()
        updater.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        dashboard.show()
        return true
    }

    @MainActor @objc private func showDashboard(_ sender: Any?) {
        dashboard.show()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cmux Companion")
        let quitItem = NSMenuItem(
            title: "Cmux Companion 종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        let dashboardItem = NSMenuItem(
            title: "Dashboard 열기",
            action: #selector(showDashboard(_:)),
            keyEquivalent: "d"
        )
        dashboardItem.keyEquivalentModifierMask = [.command, .shift]
        dashboardItem.target = self
        windowMenu.addItem(dashboardItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "닫기",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "최소화",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func updatePet(sets: [WorkSet], evaluations: [UUID: SetEvaluation]) {
        let attention = evaluations.values.filter(\.shouldNotify).count
        let active = evaluations.values.filter { $0.status == .active }.count
        let actionable = evaluations.values.filter(\.shouldNotify)
        let status: SetActivityStatus
        if actionable.contains(where: { $0.status == .attention }) {
            status = .attention
        } else if actionable.contains(where: { $0.status == .incomplete }) {
            status = .incomplete
        } else if active > 0 {
            status = .active
        } else {
            status = .idle
        }
        let title = sets.first(where: { evaluations[$0.id]?.shouldNotify == true })?.label
            ?? sets.first(where: { evaluations[$0.id]?.status == .active })?.label
            ?? "Cmux Companion"
        pet.update(
            CompanionVisualState(
                status: status,
                attentionCount: attention,
                activeCount: active,
                title: title,
                detail: status.displayName
            )
        )
    }
}

private final class CompanionSelfTestAppDelegate: NSObject, NSApplicationDelegate {
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The self-test owns process termination so an unbundled AppKit launch
        // cannot silently convert an unfinished test into exit status zero.
        .terminateCancel
    }

    func start() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            do {
                try await DragAndDropSelfTest.run()
                fputs("Cmux Companion drag-and-drop self-test: PASS\n", stderr)
                fflush(stderr)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("Cmux Companion drag-and-drop self-test: FAIL: \(error)\n", stderr)
                fflush(stderr)
                exit(EXIT_FAILURE)
            }
        }
    }
}

if CommandLine.arguments.contains("--self-test-drag-and-drop") {
    let selfTestApplication = NSApplication.shared
    selfTestApplication.setActivationPolicy(.accessory)
    let selfTestDelegate = CompanionSelfTestAppDelegate()
    selfTestApplication.delegate = selfTestDelegate
    selfTestDelegate.start()
    // Do not call `NSApplication.run()` for the unbundled SwiftPM binary: on
    // some macOS builds it terminates with status zero before async tests
    // complete. Pump the physical main thread's run loop ourselves instead.
    while true {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

let application = NSApplication.shared
let delegate = CompanionAppDelegate()
application.delegate = delegate
application.run()
