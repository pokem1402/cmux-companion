import Foundation
import UserNotifications
import CmuxCompanionCore

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let openAction = "CMUX_COMPANION_OPEN"
    static let snoozeAction = "CMUX_COMPANION_SNOOZE_15"
    static let category = "CMUX_COMPANION_ATTENTION"

    var onOpenSet: ((UUID) -> Void)?
    var onSnoozeSet: ((UUID) -> Void)?
    var isStillActionable: ((UUID) -> Bool)?
    var includePromptPreview: (() -> Bool)?

    private let center: UNUserNotificationCenter
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var currentTokens: [UUID: NotificationToken] = [:]
    private var latestPayloads: [UUID: NotificationPayload] = [:]
    private var authorizationRequestInFlight = false
    private var authorizationWaiters: [(Bool) -> Void] = []

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        let open = UNNotificationAction(
            identifier: Self.openAction,
            title: "cmux에서 열기",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction,
            title: "15분 미루기",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [open, snooze],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func update(sets: [WorkSet], evaluations: [UUID: SetEvaluation]) {
        let activeIDs = Set(sets.compactMap { set in
            evaluations[set.id]?.shouldNotify == true ? set.id : nil
        })
        var nextTokens: [UUID: NotificationToken] = [:]
        var nextPayloads: [UUID: NotificationPayload] = [:]
        for set in sets {
            guard let evaluation = evaluations[set.id], evaluation.shouldNotify else { continue }
            nextTokens[set.id] = NotificationToken(set: set, evaluation: evaluation)
            nextPayloads[set.id] = NotificationPayload(set: set, evaluation: evaluation)
        }
        currentTokens = nextTokens
        latestPayloads = nextPayloads
        for (id, work) in pending where !activeIDs.contains(id) {
            work.cancel()
            pending[id] = nil
        }
    }

    func schedule(set: WorkSet, evaluation: SetEvaluation) {
        pending[set.id]?.cancel()
        let token = NotificationToken(set: set, evaluation: evaluation)
        currentTokens[set.id] = token
        latestPayloads[set.id] = NotificationPayload(set: set, evaluation: evaluation)
        let delay: TimeInterval = evaluation.status == .attention ? 1.2 : 12
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(set.id, token: token) else { return }
            self.deliver(set: set, evaluation: evaluation, token: token)
            self.pending[set.id] = nil
        }
        pending[set.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func deliver(set: WorkSet, evaluation: SetEvaluation, token: NotificationToken) {
        requestAuthorizationIfNeeded { [weak self] allowed in
            guard allowed,
                  let self,
                  self.isCurrent(set.id, token: token),
                  let latest = self.latestPayloads[set.id] else { return }
            let set = latest.set
            let evaluation = latest.evaluation
            let content = UNMutableNotificationContent()
            content.title = evaluation.status == .attention
                ? "\(set.label): 확인이 필요합니다"
                : "\(set.label): 작업하지 않는 그룹이 있습니다"
            content.body = self.body(for: set, evaluation: evaluation)
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.threadIdentifier = "cmux-companion-\(set.id.uuidString)"
            content.userInfo = ["set_id": set.id.uuidString]
            let identifier = "\(set.id.uuidString)-\(set.generation)-\(evaluation.status.rawValue)"
            self.center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    private func isCurrent(_ setID: UUID, token: NotificationToken) -> Bool {
        currentTokens[setID] == token && isStillActionable?(setID) == true
    }

    private func body(for set: WorkSet, evaluation: SetEvaluation) -> String {
        if let member = set.members.first(where: { evaluation.attentionMemberIDs.contains($0.id) }) {
            return withPromptPreview(
                "\(member.label): \(member.runtimeState.displayNameForNotification)",
                member: member
            )
        }
        let deficientLabels = set.groups
            .filter { evaluation.deficientGroupIDs.contains($0.id) }
            .map(\.label)
        let fallback = deficientLabels.isEmpty
            ? "메뉴바에서 작업 상태를 확인하세요."
            : "\(deficientLabels.joined(separator: ", ")) 그룹을 확인하세요."
        return withPromptPreview(fallback, member: latestPromptMember(in: set, evaluation: evaluation))
    }

    private func withPromptPreview(_ body: String, member: WorkMember?) -> String {
        guard includePromptPreview?() == true,
              let member,
              let text = member.lastSubmittedText,
              !text.isEmpty else {
            return body
        }
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return body }
        return "\(body)\n\(member.label) · \(String(compact.prefix(150)))"
    }

    private func latestPromptMember(in set: WorkSet, evaluation: SetEvaluation) -> WorkMember? {
        let deficientMemberIDs = Set(
            set.groups
                .filter { evaluation.deficientGroupIDs.contains($0.id) }
                .flatMap(\.memberIDs)
        )
        let candidates = set.members.filter { member in
            if deficientMemberIDs.isEmpty {
                return member.lastSubmittedText?.isEmpty == false
            }
            return deficientMemberIDs.contains(member.id)
                && member.lastSubmittedText?.isEmpty == false
        }
        return candidates.max { lhs, rhs in
            (lhs.lastSubmittedAt ?? .distantPast) < (rhs.lastSubmittedAt ?? .distantPast)
        }
    }

    private func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)
                case .notDetermined:
                    self.authorizationWaiters.append(completion)
                    guard !self.authorizationRequestInFlight else { return }
                    self.authorizationRequestInFlight = true
                    self.center.requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in
                        DispatchQueue.main.async {
                            self.authorizationRequestInFlight = false
                            let waiters = self.authorizationWaiters
                            self.authorizationWaiters.removeAll()
                            for waiter in waiters { waiter(allowed) }
                        }
                    }
                case .denied:
                    completion(false)
                @unknown default:
                    completion(false)
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let rawID = response.notification.request.content.userInfo["set_id"] as? String,
              let setID = UUID(uuidString: rawID) else { return }
        if response.actionIdentifier == Self.snoozeAction {
            DispatchQueue.main.async { self.onSnoozeSet?(setID) }
        } else if response.actionIdentifier == Self.openAction
                    || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onOpenSet?(setID) }
        }
    }
}

private struct NotificationToken: Equatable {
    var generation: Int
    var status: SetActivityStatus
    var attentionMemberIDs: [UUID]
    var attentionMemberStates: [String]
    var deficientGroupIDs: [UUID]

    init(set: WorkSet, evaluation: SetEvaluation) {
        generation = set.generation
        status = evaluation.status
        attentionMemberIDs = evaluation.attentionMemberIDs.sorted { $0.uuidString < $1.uuidString }
        let memberByID = Dictionary(uniqueKeysWithValues: set.members.map { ($0.id, $0) })
        attentionMemberStates = evaluation.attentionMemberIDs.compactMap { memberID in
            memberByID[memberID].map { "\(memberID.uuidString):\($0.runtimeState.rawValue)" }
        }.sorted()
        deficientGroupIDs = evaluation.deficientGroupIDs.sorted { $0.uuidString < $1.uuidString }
    }
}

private struct NotificationPayload {
    var set: WorkSet
    var evaluation: SetEvaluation
}

private extension MemberRuntimeState {
    var displayNameForNotification: String {
        switch self {
        case .running: return "작업 중"
        case .waiting: return "사용자 입력 또는 승인을 기다리는 중"
        case .idle: return "현재 turn이 끝남"
        case .ended: return "세션이 종료됨"
        case .stale: return "상태가 오래됨"
        case .disconnected: return "연결이 끊김"
        case .unknown: return "상태를 확인할 수 없음"
        case .error: return "오류 발생"
        }
    }
}
