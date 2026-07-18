import Foundation

/// Builds cmux's documented navigation deep links. These are handled by the
/// application itself and do not require access to the control socket.
public enum CmuxNavigationLink {
    public static func workspace(
        _ workspaceID: String,
        surfaceID: String? = nil
    ) -> URL? {
        guard let workspaceID = normalizedUUID(workspaceID) else { return nil }

        var path = "/\(workspaceID)"
        if let surfaceID {
            guard let surfaceID = normalizedUUID(surfaceID) else { return nil }
            path += "/surface/\(surfaceID)"
        }

        var components = URLComponents()
        components.scheme = "cmux"
        components.host = "workspace"
        components.path = path
        return components.url
    }

    private static func normalizedUUID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return trimmed
    }
}
