import Foundation

public enum CmuxRemoteLifecycle {
    /// Remote hooks are edge-triggered, so a healthy agent can legitimately go
    /// quiet while it reasons or waits for one long-running tool. Keep the
    /// default lease deliberately longer than the app's five-second refresh.
    public static let defaultStaleAfter: TimeInterval = 15 * 60
    public static let defaultDisconnectedAfter: TimeInterval = 60 * 60

    /// A remote hook cannot prove that its agent process still owns the SSH
    /// terminal forever. This hard identity lease prevents an idle Codex
    /// session (which has no SessionEnd hook) from permanently relabeling a
    /// shell after the CLI exits. Long-lived sessions can renew it with the
    /// managed heartbeat.
    public static func isIdentityExpired(
        lastSeenAt: Date?,
        now: Date = Date(),
        expiresAfter: TimeInterval = defaultDisconnectedAfter
    ) -> Bool {
        guard let lastSeenAt else { return true }
        return max(0, now.timeIntervalSince(lastSeenAt)) > max(0, expiresAfter)
    }

    /// Resolves a remote hook into a lifecycle state. Heartbeats only prove
    /// connectivity; they must never invent `running` or erase a waiting/idle
    /// state reported by a real agent hook.
    public static func state(
        forHookName hookName: String?,
        previous: MemberRuntimeState?
    ) -> MemberRuntimeState {
        switch hookName?.lowercased() {
        case "heartbeat":
            switch previous {
            case .stale?, .disconnected?:
                // These are transport-age overlays, not agent lifecycle.
                // A fresh heartbeat clears them without claiming work began.
                return .unknown
            default:
                return previous ?? .unknown
            }
        case "userpromptsubmit", "pretooluse", "posttooluse", "todowrite", "sessionstart",
             "precompact", "postcompact", "subagentstart", "subagentstop":
            return .running
        case "permissionrequest", "askuserquestion", "exitplanmode", "notification":
            return .waiting
        case "stop":
            return .idle
        case "sessionend":
            return .ended
        default:
            return previous ?? .unknown
        }
    }

    /// Applies transport-age overlays only to states that make an ongoing
    /// liveness claim. Explicit lifecycle outcomes remain authoritative: an
    /// idle/ended agent must not later look disconnected, and a waiting/error
    /// condition must stay actionable until a real hook changes it.
    public static func stateApplyingLease(
        _ state: MemberRuntimeState,
        lastSeenAt: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter,
        disconnectedAfter: TimeInterval = defaultDisconnectedAfter
    ) -> MemberRuntimeState {
        switch state {
        case .running, .unknown, .stale:
            guard let lastSeenAt else { return .disconnected }
            let age = max(0, now.timeIntervalSince(lastSeenAt))
            let staleThreshold = max(0, staleAfter)
            let disconnectedThreshold = max(staleThreshold, disconnectedAfter)
            if age > disconnectedThreshold { return .disconnected }
            if state == .stale { return .stale }
            if age > staleThreshold { return .stale }
            return state
        case .waiting, .idle, .ended, .error, .disconnected:
            return state
        }
    }

    /// Decides when an authoritative local cmux agent session has replaced a
    /// prior SSH-bridge binding on the same terminal surface.
    public static func shouldYieldToLocalSession(
        isActiveForSurface: Bool,
        state: MemberRuntimeState,
        updatedAt: Date?,
        remoteLastSeenAt: Date?
    ) -> Bool {
        if isActiveForSurface { return true }
        guard state == .running else { return false }
        guard let remoteLastSeenAt else { return true }
        guard let updatedAt else { return false }
        return updatedAt > remoteLastSeenAt
    }

    /// Uses the event timestamp assigned by cmux on the Mac. A remote host's
    /// wall clock may be skewed and is metadata only; it must never renew a
    /// liveness lease. When the frame has no timestamp, receipt by the app is
    /// the only safe local fallback.
    public static func canonicalEventDate(
        frameOccurredAt: Date?,
        localReceivedAt: Date,
        remoteReportedAt: Date?
    ) -> Date {
        _ = remoteReportedAt
        return frameOccurredAt ?? localReceivedAt
    }

    public static func canonicalPromptDate(
        frameOccurredAt: Date?,
        localReceivedAt: Date,
        remoteReportedAt: Date?
    ) -> Date {
        canonicalEventDate(
            frameOccurredAt: frameOccurredAt,
            localReceivedAt: localReceivedAt,
            remoteReportedAt: remoteReportedAt
        )
    }

    /// Keeps one logical remote agent session bound to a surface. A different
    /// session may take ownership only through an activation event.
    public static func shouldAcceptSessionEvent(
        currentSessionID: String?,
        incomingSessionID: String,
        hookName: String?
    ) -> Bool {
        if hookName?.caseInsensitiveCompare("Heartbeat") == .orderedSame {
            return true
        }
        guard let currentSessionID, currentSessionID != incomingSessionID else { return true }
        switch hookName?.lowercased() {
        case "sessionstart", "userpromptsubmit": return true
        default: return false
        }
    }

    /// Returns nil when boot/sequence values cannot be compared, otherwise
    /// whether the incoming event is strictly newer than the persisted event.
    public static func isOrderNewer(
        _ incoming: CmuxRemoteEventOrder?,
        thanBootID previousBootID: String?,
        sequence previousSequence: UInt64?
    ) -> Bool? {
        guard let incoming, let previousBootID, let previousSequence,
              incoming.bootID == previousBootID else { return nil }
        return incoming.sequence > previousSequence
    }

    public static func isEventNewer(
        incomingOrder: CmuxRemoteEventOrder?,
        occurredAt: Date,
        previousBootID: String?,
        previousSequence: UInt64?,
        previousReceivedAt: Date?
    ) -> Bool {
        if let ordered = isOrderNewer(
            incomingOrder,
            thanBootID: previousBootID,
            sequence: previousSequence
        ) {
            return ordered
        }
        guard let previousReceivedAt else { return true }
        return occurredAt > previousReceivedAt
    }

    public static func isAfterLocalOwnership(
        occurredAt: Date,
        localOwnershipSince: Date?
    ) -> Bool {
        guard let localOwnershipSince else { return true }
        return occurredAt > localOwnershipSince
    }
}
