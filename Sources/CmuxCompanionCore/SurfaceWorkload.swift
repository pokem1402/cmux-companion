import Foundation

/// Display-safe classification of what currently owns a cmux surface.
///
/// `shell` deliberately does not claim Bash, zsh, or another specific shell:
/// cmux's public tree snapshot identifies a terminal surface but does not
/// expose its foreground shell process.
public enum SurfaceWorkload: Equatable, Sendable {
    case codex
    case claude
    case shell
    case browser
    case otherAgent(String)
    case unknown

    public init(
        agent: String?,
        isBrowser: Bool = false,
        shellIsAuthoritative: Bool = false
    ) {
        if isBrowser {
            self = .browser
            return
        }

        let trimmed = agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            self = shellIsAuthoritative ? .shell : .unknown
            return
        }

        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains("codex") {
            self = .codex
        } else if normalized.contains("claude") {
            self = .claude
        } else {
            self = .otherAgent(trimmed)
        }
    }

    /// Classifies a surface from the session selected as its current owner.
    /// A successful occupancy snapshot can prove "Shell" only when no current
    /// session exists. A current session without an agent name remains Unknown.
    public init(
        currentSession session: CmuxTransportSession?,
        isBrowser: Bool = false,
        occupancyIsAuthoritative: Bool
    ) {
        self.init(
            agent: session?.agent ?? session?.agentDisplayName,
            isBrowser: isBrowser,
            shellIsAuthoritative: occupancyIsAuthoritative && session == nil
        )
    }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .shell: return "Shell"
        case .browser: return "Browser"
        case let .otherAgent(name): return name
        case .unknown: return "Unknown"
        }
    }
}
