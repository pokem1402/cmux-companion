import Foundation

public struct CmuxTreeSnapshot: Sendable, Equatable {
    public let windows: [CmuxTransportWindow]
    public let active: JSONValue?
    public let caller: JSONValue?
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.active = raw["active"] ?? raw["result"]?["active"]
        self.caller = raw["caller"] ?? raw["result"]?["caller"]
        self.windows = raw.transportArray(forKeys: ["windows", "window_list"])
            .map(CmuxTransportWindow.init(raw:))
    }
}

public struct CmuxTransportWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let ref: String?
    public let title: String?
    public let index: Int64?
    public let isActive: Bool
    public let isKey: Bool
    public let workspaces: [CmuxTransportWorkspace]
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.id = raw.firstString(forKeys: ["id", "window_id", "windowId", "uuid"])
            ?? raw.firstString(forKeys: ["ref", "window_ref", "windowRef"])
            ?? "unknown-window"
        self.ref = raw.firstString(forKeys: ["ref", "window_ref", "windowRef"])
        self.title = raw.firstString(forKeys: ["title", "name", "label"])
        self.index = raw.firstInt64(forKeys: ["index", "window_index"])
        self.isActive = raw.firstBool(forKeys: ["active", "current", "focused"]) ?? false
        self.isKey = raw.firstBool(forKeys: ["key", "is_key", "is_key_window"]) ?? false
        self.workspaces = raw.transportArray(forKeys: ["workspaces", "tabs"])
            .map(CmuxTransportWorkspace.init(raw:))
    }
}

public struct CmuxTransportWorkspace: Sendable, Equatable, Identifiable {
    public let id: String
    public let ref: String?
    public let title: String?
    public let index: Int64?
    public let isActive: Bool
    public let isSelected: Bool
    public let panes: [CmuxTransportPane]
    public let ungroupedSurfaces: [CmuxTransportSurface]
    public let raw: JSONValue

    public var surfaces: [CmuxTransportSurface] {
        panes.flatMap(\.surfaces) + ungroupedSurfaces
    }

    public init(raw: JSONValue) {
        self.raw = raw
        self.id = raw.firstString(forKeys: ["id", "workspace_id", "workspaceId", "tab_id", "tabId", "uuid"])
            ?? raw.firstString(forKeys: ["ref", "workspace_ref", "workspaceRef", "tab_ref", "tabRef"])
            ?? "unknown-workspace"
        self.ref = raw.firstString(forKeys: ["ref", "workspace_ref", "workspaceRef", "tab_ref", "tabRef"])
        self.title = raw.firstString(forKeys: ["title", "name", "label", "tab_title"])
        self.index = raw.firstInt64(forKeys: ["index", "workspace_index", "tab_index"])
        self.isActive = raw.firstBool(forKeys: ["active", "focused"]) ?? false
        self.isSelected = raw.firstBool(forKeys: ["selected", "current", "is_selected"]) ?? false
        self.panes = raw.transportArray(forKeys: ["panes", "pane_list"])
            .map(CmuxTransportPane.init(raw:))
        self.ungroupedSurfaces = raw.transportArray(forKeys: ["surfaces", "surface_list"])
            .map(CmuxTransportSurface.init(raw:))
    }
}

public struct CmuxTransportPane: Sendable, Equatable, Identifiable {
    public let id: String
    public let ref: String?
    public let index: Int64?
    public let isActive: Bool
    public let isFocused: Bool
    public let surfaces: [CmuxTransportSurface]
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.id = raw.firstString(forKeys: ["id", "pane_id", "paneId", "uuid"])
            ?? raw.firstString(forKeys: ["ref", "pane_ref", "paneRef"])
            ?? "unknown-pane"
        self.ref = raw.firstString(forKeys: ["ref", "pane_ref", "paneRef"])
        self.index = raw.firstInt64(forKeys: ["index", "pane_index"])
        self.isActive = raw.firstBool(forKeys: ["active", "current"]) ?? false
        self.isFocused = raw.firstBool(forKeys: ["focused", "is_focused"]) ?? false
        self.surfaces = raw.transportArray(forKeys: ["surfaces", "tabs", "surface_list"])
            .map(CmuxTransportSurface.init(raw:))
    }
}

public struct CmuxTransportSurface: Sendable, Equatable, Identifiable {
    public let id: String
    public let ref: String?
    public let paneID: String?
    public let workspaceID: String?
    public let type: String?
    public let title: String?
    public let url: String?
    public let index: Int64?
    public let isActive: Bool
    public let isFocused: Bool
    public let isSelected: Bool
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.id = raw.firstString(forKeys: ["id", "surface_id", "surfaceId", "panel_id", "panelId", "uuid"])
            ?? raw.firstString(forKeys: ["ref", "surface_ref", "surfaceRef", "panel_ref", "panelRef"])
            ?? "unknown-surface"
        self.ref = raw.firstString(forKeys: ["ref", "surface_ref", "surfaceRef", "panel_ref", "panelRef"])
        self.paneID = raw.firstString(forKeys: ["pane_id", "paneId", "pane_ref", "paneRef"])
        self.workspaceID = raw.firstString(forKeys: [
            "workspace_id", "workspaceId", "workspace_ref", "workspaceRef", "tab_id", "tabId"
        ])
        self.type = raw.firstString(forKeys: ["type", "surface_type", "kind"])
        self.title = raw.firstString(forKeys: ["title", "name", "label"])
        self.url = raw.firstString(forKeys: ["url", "current_url"])
            ?? raw["browser"]?.firstString(forKeys: ["url", "current_url"])
        self.index = raw.firstInt64(forKeys: ["index_in_pane", "index", "surface_index"])
        self.isActive = raw.firstBool(forKeys: ["active", "current"]) ?? false
        self.isFocused = raw.firstBool(forKeys: ["focused", "is_focused"]) ?? false
        self.isSelected = raw.firstBool(forKeys: ["selected", "selected_in_pane", "is_selected"]) ?? false
    }
}

public struct CmuxSessionsSnapshot: Sendable, Equatable {
    public let sessions: [CmuxTransportSession]
    public let stateDirectory: String?
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.stateDirectory = raw.firstString(forKeys: ["state_dir", "stateDirectory"])
            ?? raw["result"]?.firstString(forKeys: ["state_dir", "stateDirectory"])
        self.sessions = raw.transportArray(forKeys: ["sessions", "records", "items"])
            .map(CmuxTransportSession.init(raw:))
    }
}

public struct CmuxTransportSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let agent: String?
    public let agentDisplayName: String?
    public let hookSessionID: String?
    public let workspaceID: String?
    public let surfaceID: String?
    public let cwd: String?
    public let pid: Int64?
    public let transcriptPath: String?
    public let isRestorable: Bool?
    public let transcriptBacked: Bool
    public let agentLifecycle: String?
    public let runtimeStatus: String?
    public let startedAt: String?
    public let updatedAt: String?
    public let updatedAtUnix: Double?
    public let isActiveForWorkspace: Bool
    /// `nil` preserves compatibility with older cmux snapshots that did not
    /// publish an explicit surface-ownership bit.
    public let activeForSurface: Bool?
    public let isActiveForSurface: Bool
    public let raw: JSONValue

    public var effectiveLifecycle: String? { agentLifecycle ?? runtimeStatus }

    public init(raw: JSONValue) {
        self.raw = raw
        self.id = raw.firstString(forKeys: ["session_id", "sessionId", "id"])
            ?? "unknown-session"
        self.agent = raw.firstString(forKeys: ["agent", "source", "agent_name"])
        self.agentDisplayName = raw.firstString(forKeys: ["agent_display_name", "agentDisplayName"])
        self.hookSessionID = raw.firstString(forKeys: ["hook_session_id", "hookSessionId"])
        self.workspaceID = raw.firstString(forKeys: ["workspace_id", "workspaceId", "tab_id"])
        self.surfaceID = raw.firstString(forKeys: ["surface_id", "surfaceId", "panel_id"])
        self.cwd = raw.firstString(forKeys: ["cwd", "working_directory", "launch_working_directory"])
        self.pid = raw.firstInt64(forKeys: ["pid", "process_id"])
        self.transcriptPath = raw.firstString(forKeys: [
            "transcript_path", "transcriptPath", "codex_transcript_path", "codexTranscriptPath"
        ])
        self.isRestorable = raw.firstValue(forKeys: ["is_restorable", "isRestorable"])?.boolValue
        self.transcriptBacked = raw.firstBool(forKeys: ["transcript_backed", "transcriptBacked"]) ?? false
        self.agentLifecycle = raw.firstString(forKeys: ["agent_lifecycle", "agentLifecycle", "lifecycle"])
        self.runtimeStatus = raw.firstString(forKeys: ["runtime_status", "runtimeStatus", "status"])
        self.startedAt = raw.firstString(forKeys: ["started_at", "startedAt"])
        self.updatedAt = raw.firstString(forKeys: ["updated_at", "updatedAt"])
        self.updatedAtUnix = raw.firstValue(forKeys: ["updated_at_unix", "updatedAtUnix"])?.doubleValue
        self.isActiveForWorkspace = raw.firstBool(forKeys: ["active_for_workspace", "activeForWorkspace"]) ?? false
        self.activeForSurface = raw.firstValue(
            forKeys: ["active_for_surface", "activeForSurface"]
        )?.boolValue
        self.isActiveForSurface = activeForSurface ?? false
    }

    /// Whether this record can describe the agent that currently owns its
    /// surface. An explicit cmux ownership bit wins. Legacy snapshots fall
    /// back to excluding lifecycle states that unambiguously ended.
    public var isCurrentForSurface: Bool {
        if let activeForSurface { return activeForSurface }
        guard surfaceID != nil else { return false }
        let normalized = (effectiveLifecycle ?? "")
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return !["ended", "closed", "exited"].contains(normalized)
    }
}

public enum CmuxAgentSessionResolver {
    /// Resolves at most one current agent session for each surface. Historical
    /// records with `active_for_surface=false` must never keep a stale Codex or
    /// Claude badge attached to a terminal that has returned to its shell.
    public static func currentBySurface(
        _ sessions: [CmuxTransportSession]
    ) -> [String: CmuxTransportSession] {
        Dictionary(
            sessions.filter(\.isCurrentForSurface).compactMap { session in
                session.surfaceID.map { ($0, session) }
            },
            uniquingKeysWith: prefer
        )
    }

    private static func prefer(
        _ lhs: CmuxTransportSession,
        _ rhs: CmuxTransportSession
    ) -> CmuxTransportSession {
        if lhs.isActiveForSurface != rhs.isActiveForSurface {
            return lhs.isActiveForSurface ? lhs : rhs
        }
        return (lhs.updatedAtUnix ?? 0) >= (rhs.updatedAtUnix ?? 0) ? lhs : rhs
    }
}

public struct CmuxFeedSnapshot: Sendable, Equatable {
    public let items: [CmuxTransportFeedItem]
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.items = raw.transportArray(forKeys: ["items", "feed", "events"])
            .map(CmuxTransportFeedItem.init(raw:))
    }
}

public struct CmuxTransportFeedItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let workstreamID: String?
    public let source: String?
    public let kind: String?
    public let status: String?
    public let title: String?
    public let text: String?
    public let cwd: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let isTextRedacted: Bool
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.id = raw.firstString(forKeys: ["id", "item_id", "event_id"])
            ?? "unknown-feed-item"
        self.workstreamID = raw.firstString(forKeys: ["workstream_id", "workstreamId", "session_id"])
        self.source = raw.firstString(forKeys: ["source", "agent"])
        self.kind = raw.firstString(forKeys: ["kind", "type", "event"])
        self.status = raw.firstString(forKeys: ["status", "state"])
        self.title = raw.firstString(forKeys: ["title", "label"])
        self.text = raw.firstString(forKeys: ["text", "prompt", "message"])
        self.cwd = raw.firstString(forKeys: ["cwd", "working_directory"])
        self.createdAt = raw.firstString(forKeys: ["created_at", "createdAt"])
        self.updatedAt = raw.firstString(forKeys: ["updated_at", "updatedAt"])
        self.isTextRedacted = raw.redactedFields.contains("text")
            || raw.firstBool(forKeys: ["text_redacted", "is_redacted"]) == true
            || (self.text == nil && raw.firstValue(forKeys: ["text_length", "prompt_length"]) != nil)
    }
}

public struct CmuxNotificationsSnapshot: Sendable, Equatable {
    public let notifications: [CmuxTransportNotification]
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.notifications = raw.transportArray(forKeys: ["notifications", "items"])
            .map(CmuxTransportNotification.init(raw:))
    }
}

public struct CmuxTransportNotification: Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String?
    public let surfaceID: String?
    public let title: String?
    public let subtitle: String?
    public let body: String?
    public let createdAt: String?
    public let tabTitle: String?
    public let isRead: Bool
    public let isContentRedacted: Bool
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.id = raw.firstString(forKeys: ["id", "notification_id", "notificationId"])
            ?? "unknown-notification"
        self.workspaceID = raw.firstString(forKeys: ["workspace_id", "workspaceId", "tab_id"])
        self.surfaceID = raw.firstString(forKeys: ["surface_id", "surfaceId", "panel_id"])
        self.title = raw.firstString(forKeys: ["title"])
        self.subtitle = raw.firstString(forKeys: ["subtitle"])
        self.body = raw.firstString(forKeys: ["body", "message"])
        self.createdAt = raw.firstString(forKeys: ["created_at", "createdAt"])
        self.tabTitle = raw.firstString(forKeys: ["tab_title", "tabTitle", "workspace_title"])
        self.isRead = raw.firstBool(forKeys: ["is_read", "isRead", "read"]) ?? false
        self.isContentRedacted = !raw.redactedFields.isEmpty
            || (self.body == nil && raw.firstValue(forKeys: ["body_length"]) != nil)
    }
}

extension JSONValue {
    fileprivate var redactedFields: Set<String> {
        guard case .array(let values)? = self["redacted_fields"] else { return [] }
        return Set(values.compactMap(\.stringValue))
    }
}
