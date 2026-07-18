import AppKit
import Darwin
import CmuxCompanionCore

final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var model: CompanionAppModel!
    private var menuBar: MenuBarController!
    private var pet: FloatingPetController!
    private var hud: TopHUDController!
    private var notifications: NotificationCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        model = CompanionAppModel()
        menuBar = MenuBarController(model: model)
        pet = FloatingPetController()
        hud = TopHUDController()
        notifications = NotificationCoordinator()

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

        pet.onClick = { [weak self] in self?.menuBar.showPopover() }
        model.onPetVisibilityChanged = { [weak self] visible in self?.pet.setVisible(visible) }
        model.onEvaluationsChanged = { [weak self] sets, evaluations in
            guard let self else { return }
            self.notifications.update(sets: sets, evaluations: evaluations)
            self.updatePet(sets: sets, evaluations: evaluations)
        }
        model.onAttentionTransition = { [weak self] set, evaluation, _ in
            guard let self else { return }
            self.notifications.schedule(set: set, evaluation: evaluation)
            let detail = evaluation.status == .attention
                ? "사용자 입력, 연결 또는 오류 상태를 확인하세요."
                : "필수 Worker/Reviewer 그룹이 작업 중이 아닙니다."
            self.hud.show(title: set.label, detail: detail, status: evaluation.status)
        }

        pet.setVisible(model.showPet)
        updatePet(sets: model.sets, evaluations: model.evaluations)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
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

if CommandLine.arguments.contains("--self-test-drag-and-drop") {
    Task { @MainActor in
        do {
            try await DragAndDropSelfTest.run()
            print("Cmux Companion drag-and-drop self-test: PASS")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Cmux Companion drag-and-drop self-test: FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    RunLoop.main.run()
}

let application = NSApplication.shared
let delegate = CompanionAppDelegate()
application.delegate = delegate
application.run()
