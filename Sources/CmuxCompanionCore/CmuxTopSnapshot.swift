import Foundation

public enum CmuxTopSnapshotError: Error, LocalizedError, Sendable, Equatable {
    case invalidTSVLine(Int)
    case noRows

    public var errorDescription: String? {
        switch self {
        case .invalidTSVLine(let line):
            return "Invalid cmux top TSV at line \(line)"
        case .noRows:
            return "cmux top returned no TSV rows"
        }
    }
}

/// A conservative interpretation of `cmux top --processes`.
///
/// Process names provide only a display workload hint. A runtime state is
/// exposed separately and only when cmux's own hook-backed agent tag, its
/// session-scoped PID, and the exact terminal surface all agree.
public struct CmuxTopSnapshot: Sendable, Equatable {
    public let workloadsBySurfaceID: [String: SurfaceWorkload]
    public let runtimeStatesBySurfaceID: [String: MemberRuntimeState]
    public let processIDsBySurfaceID: [String: Set<Int64>]
    public let agentWorkloadsBySurfaceAndProcessID: [String: [Int64: SurfaceWorkload]]
    /// SSH surfaces whose local process tree cannot expose the remote
    /// foreground process. The snapshot loader may inspect only these screens
    /// for conservative agent and runtime evidence.
    public let remoteProbeSurfaceIDs: Set<String>

    public init(
        workloadsBySurfaceID: [String: SurfaceWorkload] = [:],
        runtimeStatesBySurfaceID: [String: MemberRuntimeState] = [:],
        processIDsBySurfaceID: [String: Set<Int64>] = [:],
        agentWorkloadsBySurfaceAndProcessID: [String: [Int64: SurfaceWorkload]] = [:],
        remoteProbeSurfaceIDs: Set<String> = []
    ) {
        self.workloadsBySurfaceID = workloadsBySurfaceID
        self.runtimeStatesBySurfaceID = runtimeStatesBySurfaceID
        self.processIDsBySurfaceID = processIDsBySurfaceID
        self.agentWorkloadsBySurfaceAndProcessID = agentWorkloadsBySurfaceAndProcessID
        self.remoteProbeSurfaceIDs = remoteProbeSurfaceIDs
    }

    public init(tsv: String) throws {
        let rows = try Self.parseRows(tsv)
        let interpretation = Self.interpret(rows)
        workloadsBySurfaceID = interpretation.workloads
        runtimeStatesBySurfaceID = interpretation.runtimeStates
        processIDsBySurfaceID = interpretation.processIDs
        agentWorkloadsBySurfaceAndProcessID = interpretation.agentWorkloadsByProcessID
        remoteProbeSurfaceIDs = interpretation.remoteProbeSurfaceIDs
    }

    public func workload(forSurfaceID id: String) -> SurfaceWorkload? {
        workloadsBySurfaceID[id]
    }

    /// A hook-backed state published by cmux's agent status tag. Unlike a
    /// process-name workload hint, this may be used as lifecycle evidence when
    /// `cmux sessions` temporarily omits the active local agent record.
    public func runtimeState(forSurfaceID id: String) -> MemberRuntimeState? {
        runtimeStatesBySurfaceID[id]
    }

    /// Every numeric process ref attributed to the surface, including
    /// descendants whose flat TSV parent is another PID rather than the
    /// surface UUID. Callers can use this only as evidence that an already
    /// known PID is still alive; it does not establish an agent lifecycle.
    public func processIDs(forSurfaceID id: String) -> Set<Int64> {
        processIDsBySurfaceID[id] ?? []
    }

    /// Returns an agent family only when that exact PID has its own executable
    /// or tag evidence on the requested surface. Agent evidence from a sibling,
    /// ancestor, or descendant PID is never inherited here.
    public func agentWorkload(
        forProcessID processID: Int64,
        onSurfaceID surfaceID: String
    ) -> SurfaceWorkload? {
        agentWorkloadsBySurfaceAndProcessID[surfaceID]?[processID]
    }

    /// Applies remote terminal UI evidence only to surfaces already proven to
    /// contain a local SSH client. Visible choice controls mean `waiting`, an
    /// active interrupt control means `running`, and an otherwise intact agent
    /// prompt means `idle`. Screen contents are classified in memory; the
    /// original text is neither retained nor exposed by the snapshot.
    public func addingRemoteScreenEvidence(
        _ screenTextBySurfaceID: [String: String]
    ) -> CmuxTopSnapshot {
        var workloads = workloadsBySurfaceID
        var runtimeStates = runtimeStatesBySurfaceID
        for (surfaceID, text) in screenTextBySurfaceID
            where remoteProbeSurfaceIDs.contains(surfaceID) {
            guard let evidence = Self.remoteAgentEvidence(screenText: text) else {
                continue
            }
            workloads[surfaceID] = evidence.workload
            runtimeStates[surfaceID] = evidence.runtimeState
        }
        return CmuxTopSnapshot(
            workloadsBySurfaceID: workloads,
            runtimeStatesBySurfaceID: runtimeStates,
            processIDsBySurfaceID: processIDsBySurfaceID,
            agentWorkloadsBySurfaceAndProcessID: agentWorkloadsBySurfaceAndProcessID,
            remoteProbeSurfaceIDs: remoteProbeSurfaceIDs
        )
    }

    private static func parseRows(_ tsv: String) throws -> [Row] {
        var rows: [Row] = []
        var sawContent = false

        for (offset, rawLine) in tsv.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ).enumerated() {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            sawContent = true

            // The seventh column is a free-form title. Limiting the number of
            // splits preserves any tabs that cmux includes in that title.
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count == 7,
                  Double(fields[0]) != nil,
                  UInt64(fields[1]) != nil,
                  UInt64(fields[2]) != nil else {
                throw CmuxTopSnapshotError.invalidTSVLine(offset + 1)
            }

            let kind = fields[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ref = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let parentRef = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kind.isEmpty, !ref.isEmpty else {
                throw CmuxTopSnapshotError.invalidTSVLine(offset + 1)
            }
            if (kind == "surface" || kind == "process") && parentRef.isEmpty {
                throw CmuxTopSnapshotError.invalidTSVLine(offset + 1)
            }

            rows.append(Row(
                kind: kind,
                ref: ref,
                parentRef: parentRef,
                title: String(fields[6]).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        guard sawContent, !rows.isEmpty else {
            throw CmuxTopSnapshotError.noRows
        }
        return rows
    }

    private static func interpret(
        _ rows: [Row]
    ) -> (
        workloads: [String: SurfaceWorkload],
        runtimeStates: [String: MemberRuntimeState],
        processIDs: [String: Set<Int64>],
        agentWorkloadsByProcessID: [String: [Int64: SurfaceWorkload]],
        remoteProbeSurfaceIDs: Set<String>
    ) {
        let surfaceIDs = rows.lazy.filter { $0.kind == "surface" }.map(\.ref)
        let processRows = rows.filter { $0.kind == "process" }

        let agentTagByRef = Dictionary(
            rows.compactMap { row -> (String, AgentTagDescriptor)? in
                guard row.kind == "tag", let tag = AgentTagDescriptor(ref: row.ref) else {
                    return nil
                }
                return (row.ref, tag)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var runtimeValuesByWorkspaceAgent: [WorkspaceAgent: Set<String>] = [:]
        for row in rows where row.kind == "tag" {
            guard let tag = agentTagByRef[row.ref], tag.isWorkspaceStatus,
                  let state = runtimeState(statusTitle: row.title) else {
                continue
            }
            runtimeValuesByWorkspaceAgent[tag.workspaceAgent, default: []]
                .insert(state.rawValue)
        }
        let runtimeStateByWorkspaceAgent: [WorkspaceAgent: MemberRuntimeState] =
            runtimeValuesByWorkspaceAgent.compactMapValues { values -> MemberRuntimeState? in
                guard values.count == 1, let value = values.first else { return nil }
                return MemberRuntimeState(rawValue: value)
            }
        var taggedAgentsByPID: [String: Set<AgentFamily>] = [:]
        var taggedRuntimeValuesByPID: [String: Set<String>] = [:]
        for process in processRows {
            guard let tag = agentTagByRef[process.parentRef] else { continue }
            taggedAgentsByPID[process.ref, default: []].insert(tag.family)
            if let state = runtimeStateByWorkspaceAgent[tag.workspaceAgent] {
                taggedRuntimeValuesByPID[process.ref, default: []].insert(state.rawValue)
            }
        }
        var ownAgentsByPID = taggedAgentsByPID
        for process in processRows {
            guard let family = AgentFamily(processTitle: process.title) else { continue }
            ownAgentsByPID[process.ref, default: []].insert(family)
        }

        var result: [String: SurfaceWorkload] = [:]
        var runtimeStatesBySurfaceID: [String: MemberRuntimeState] = [:]
        var processIDsBySurfaceID: [String: Set<Int64>] = [:]
        var agentWorkloadsBySurfaceAndProcessID: [String: [Int64: SurfaceWorkload]] = [:]
        var remoteProbeSurfaceIDs = Set<String>()
        for surfaceID in surfaceIDs {
            var includedPIDs = Set(
                processRows.lazy.filter { $0.parentRef == surfaceID }.map(\.ref)
            )

            // Flat output retains parent refs rather than nesting. Resolve
            // descendants without relying on output order and stop naturally
            // when no PID is added, even if malformed input contains a cycle.
            var changed = true
            while changed {
                changed = false
                for process in processRows where includedPIDs.contains(process.parentRef) {
                    if includedPIDs.insert(process.ref).inserted {
                        changed = true
                    }
                }
            }

            guard !includedPIDs.isEmpty else { continue }
            let numericPIDs = Set(includedPIDs.compactMap { ref -> Int64? in
                guard let pid = Int64(ref), pid > 0 else { return nil }
                return pid
            })
            if !numericPIDs.isEmpty {
                processIDsBySurfaceID[surfaceID] = numericPIDs
            }
            var exactAgentWorkloads: [Int64: SurfaceWorkload] = [:]
            for processRef in includedPIDs {
                guard let pid = Int64(processRef), pid > 0,
                      let families = ownAgentsByPID[processRef],
                      families.count == 1,
                      let family = families.first else {
                    continue
                }
                exactAgentWorkloads[pid] = family.workload
            }
            if !exactAgentWorkloads.isEmpty {
                agentWorkloadsBySurfaceAndProcessID[surfaceID] = exactAgentWorkloads
            }
            var taggedAgents = Set<AgentFamily>()
            var executableAgents = Set<AgentFamily>()
            var foundShell = false
            var foundSSH = false
            var hasConflictingPID = false
            var taggedRuntimeValues = Set<String>()
            for process in processRows where includedPIDs.contains(process.ref) {
                if let family = AgentFamily(processTitle: process.title) {
                    executableAgents.insert(family)
                }
                taggedAgents.formUnion(taggedAgentsByPID[process.ref] ?? [])
                taggedRuntimeValues.formUnion(taggedRuntimeValuesByPID[process.ref] ?? [])
                hasConflictingPID = hasConflictingPID
                    || (ownAgentsByPID[process.ref]?.count ?? 0) > 1
                foundShell = foundShell || ShellFamily.matches(process.title)
                foundSSH = foundSSH || SecureShellFamily.matches(process.title)
            }

            if hasConflictingPID || taggedAgents.count > 1 {
                continue
            } else if let taggedAgent = taggedAgents.first {
                // A cmux status tag identifies the owning agent. A nested
                // Codex/Claude helper may appear in the same process tree and
                // must not replace that owner.
                result[surfaceID] = taggedAgent.workload
                if taggedRuntimeValues.count == 1,
                   let rawState = taggedRuntimeValues.first,
                   let state = MemberRuntimeState(rawValue: rawState) {
                    runtimeStatesBySurfaceID[surfaceID] = state
                }
            } else if executableAgents.count == 1, let family = executableAgents.first {
                result[surfaceID] = family.workload
            } else if executableAgents.isEmpty, foundShell {
                result[surfaceID] = .shell
            }
            if foundSSH && taggedAgents.isEmpty && executableAgents.isEmpty {
                remoteProbeSurfaceIDs.insert(surfaceID)
            }
            // Conflicting agent evidence and unrecognized process-only
            // surfaces deliberately have no fallback instead of guessing.
        }
        return (
            result,
            runtimeStatesBySurfaceID,
            processIDsBySurfaceID,
            agentWorkloadsBySurfaceAndProcessID,
            remoteProbeSurfaceIDs
        )
    }

    private static func remoteAgentEvidence(screenText: String) -> RemoteAgentEvidence? {
        let lines = screenText
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard let statusLine = lines.last else { return nil }

        // Both TUIs keep an identifying status bar at the bottom while they
        // own the terminal. Looking only at the last non-empty line prevents
        // exited agents or ordinary command output above a shell prompt from
        // leaving a stale badge behind.
        let claudeEvidence = statusLine.contains("shift+tab to cycle")
        let codexEvidence: Bool = {
            guard statusLine.contains(" · "),
                  let model = statusLine.split(separator: " ").first else {
                return false
            }
            return model.hasPrefix("gpt-")
                || ["o1", "o3", "o4", "o5"].contains(String(model))
        }()

        let workload: SurfaceWorkload
        switch (codexEvidence, claudeEvidence) {
        case (true, false): workload = .codex
        case (false, true): workload = .claude
        default: return nil
        }

        // State controls are transient and rendered near the bottom of both
        // TUIs. Limit classification to the bottom-most non-empty rows so an
        // old completed turn in scrollback cannot keep the agent `running`.
        let stateLines = lines.suffix(8)
        let waiting = stateLines.contains { line in
            line.contains("press enter to confirm")
                || line.contains("enter to select")
                || line.contains("tab to amend")
        } || (
            stateLines.contains(where: { $0.contains("esc to cancel") })
                && stateLines.contains(where: { line in
                    line.contains("yes, proceed")
                        || line.contains("yes, and don't ask again")
                        || line.contains("do you want to")
                        || line.contains("would you like to")
                })
        )
        let running = stateLines.contains { line in
            line.contains("esc to interrupt") || line.contains("ctrl+c to interrupt")
        }
        let runtimeState: MemberRuntimeState = waiting ? .waiting : (running ? .running : .idle)
        return RemoteAgentEvidence(workload: workload, runtimeState: runtimeState)
    }

    private static func runtimeState(statusTitle: String) -> MemberRuntimeState? {
        switch normalizedToken(statusTitle) {
        case "running", "working", "busy", "active": return .running
        case "needsinput", "waiting", "permission", "blocked": return .waiting
        case "idle", "stopped", "stop", "done": return .idle
        case "ended", "closed", "exited": return .ended
        case "stale": return .stale
        case "disconnected", "offline": return .disconnected
        case "error", "failed": return .error
        default: return nil
        }
    }
}

/// Minimal, display-only lookup data for a hook event whose session ownership
/// is missing but whose exact agent PID is still corroborated by a fresh top
/// snapshot. It must never be used as lifecycle or notification authority.
public struct CmuxPromptDisplaySource: Sendable, Equatable {
    public let sessionID: String
    public let source: String?
    public let transcriptPath: String?

    public init(sessionID: String, source: String?, transcriptPath: String?) {
        self.sessionID = sessionID
        self.source = source
        self.transcriptPath = transcriptPath
    }
}

public extension CmuxAgentSessionResolver {
    /// Finds inactive hook records that are safe enough for ephemeral prompt
    /// display only. Exact surface, exact PID, per-PID family, and aggregate
    /// surface family must all agree, and ambiguous candidates are rejected.
    static func promptDisplaySourcesBySurface(
        _ sessions: [CmuxTransportSession],
        corroboratedBy top: CmuxTopSnapshot
    ) -> [String: CmuxPromptDisplaySource] {
        let currentSurfaceIDs = Set(currentBySurface(sessions).keys)
        var candidates: [String: [CmuxTransportSession]] = [:]

        for session in sessions {
            guard session.activeForSurface == false,
                  !CmuxRemoteEventIdentity.isRemoteSessionID(session.id),
                  !isTerminalLifecycle(session.effectiveLifecycle),
                  let surfaceID = session.surfaceID,
                  !currentSurfaceIDs.contains(surfaceID),
                  let pid = session.pid else {
                continue
            }

            let family = SurfaceWorkload(
                agent: session.agent ?? session.agentDisplayName
            )
            guard family == .codex || family == .claude,
                  top.processIDs(forSurfaceID: surfaceID).contains(pid),
                  top.agentWorkload(forProcessID: pid, onSurfaceID: surfaceID) == family,
                  top.workload(forSurfaceID: surfaceID) == family else {
                continue
            }
            candidates[surfaceID, default: []].append(session)
        }

        return candidates.compactMapValues { matches in
            let byID = Dictionary(matches.map { ($0.id, $0) }) { lhs, rhs in
                (lhs.updatedAtUnix ?? 0) >= (rhs.updatedAtUnix ?? 0) ? lhs : rhs
            }
            guard byID.count == 1, let session = byID.values.first else { return nil }
            return CmuxPromptDisplaySource(
                sessionID: session.id,
                source: session.agent ?? session.agentDisplayName,
                transcriptPath: session.transcriptPath
            )
        }
    }

    private static func isTerminalLifecycle(_ value: String?) -> Bool {
        let normalized = (value ?? "")
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return ["ended", "closed", "exited"].contains(normalized)
    }
}

private extension CmuxTopSnapshot {
    struct RemoteAgentEvidence: Sendable, Equatable {
        let workload: SurfaceWorkload
        let runtimeState: MemberRuntimeState
    }

    struct Row: Sendable, Equatable {
        let kind: String
        let ref: String
        let parentRef: String
        let title: String
    }

    struct WorkspaceAgent: Hashable, Sendable {
        let workspaceID: String
        let family: AgentFamily
    }

    struct AgentTagDescriptor: Sendable, Equatable {
        let workspaceAgent: WorkspaceAgent
        let isWorkspaceStatus: Bool

        var family: AgentFamily { workspaceAgent.family }

        init?(ref: String) {
            guard let marker = ref.range(of: ":tag:", options: .backwards) else {
                return nil
            }
            let workspaceID = String(ref[..<marker.lowerBound])
            let rawTag = String(ref[marker.upperBound...])
            let components = rawTag.split(separator: ".", maxSplits: 1)
            guard !workspaceID.isEmpty, let familyToken = components.first else {
                return nil
            }
            let family: AgentFamily
            switch CmuxTopSnapshot.normalizedToken(String(familyToken)) {
            case "codex": family = .codex
            case "claude", "claudecode": family = .claude
            default: return nil
            }
            workspaceAgent = WorkspaceAgent(workspaceID: workspaceID, family: family)
            isWorkspaceStatus = components.count == 1
        }
    }

    enum AgentFamily: Hashable, Sendable {
        case codex
        case claude

        init?(processTitle: String) {
            switch CmuxTopSnapshot.normalizedExecutableName(processTitle) {
            case "codex", "codexcli": self = .codex
            case "claude", "claudecode": self = .claude
            default: return nil
            }
        }

        init?(tagRef: String) {
            guard let tag = AgentTagDescriptor(ref: tagRef) else { return nil }
            self = tag.family
        }

        var workload: SurfaceWorkload {
            switch self {
            case .codex: return .codex
            case .claude: return .claude
            }
        }
    }

    enum ShellFamily {
        private static let names: Set<String> = [
            "bash", "csh", "dash", "fish", "ksh", "nu", "sh", "tcsh", "zsh",
        ]

        static func matches(_ processTitle: String) -> Bool {
            names.contains(CmuxTopSnapshot.normalizedExecutableName(processTitle))
        }
    }

    enum SecureShellFamily {
        static func matches(_ processTitle: String) -> Bool {
            CmuxTopSnapshot.normalizedExecutableName(processTitle) == "ssh"
        }
    }

    static func normalizedExecutableName(_ value: String) -> String {
        let basename = value.split(separator: "/", omittingEmptySubsequences: true).last
            .map(String.init) ?? value
        var normalized = normalizedToken(basename)
        if normalized.hasSuffix("exe") {
            normalized.removeLast(3)
        }
        return normalized
    }

    static func normalizedToken(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
