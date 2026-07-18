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

/// A conservative, display-only interpretation of `cmux top --processes`.
///
/// This snapshot never manufactures an agent session or lifecycle state. It
/// only provides a fresh process-based workload hint for a surface when cmux's
/// hook-backed session store has no current owner for that surface.
public struct CmuxTopSnapshot: Sendable, Equatable {
    public let workloadsBySurfaceID: [String: SurfaceWorkload]
    public let processIDsBySurfaceID: [String: Set<Int64>]
    public let agentWorkloadsBySurfaceAndProcessID: [String: [Int64: SurfaceWorkload]]

    public init(
        workloadsBySurfaceID: [String: SurfaceWorkload] = [:],
        processIDsBySurfaceID: [String: Set<Int64>] = [:],
        agentWorkloadsBySurfaceAndProcessID: [String: [Int64: SurfaceWorkload]] = [:]
    ) {
        self.workloadsBySurfaceID = workloadsBySurfaceID
        self.processIDsBySurfaceID = processIDsBySurfaceID
        self.agentWorkloadsBySurfaceAndProcessID = agentWorkloadsBySurfaceAndProcessID
    }

    public init(tsv: String) throws {
        let rows = try Self.parseRows(tsv)
        let interpretation = Self.interpret(rows)
        workloadsBySurfaceID = interpretation.workloads
        processIDsBySurfaceID = interpretation.processIDs
        agentWorkloadsBySurfaceAndProcessID = interpretation.agentWorkloadsByProcessID
    }

    public func workload(forSurfaceID id: String) -> SurfaceWorkload? {
        workloadsBySurfaceID[id]
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
        processIDs: [String: Set<Int64>],
        agentWorkloadsByProcessID: [String: [Int64: SurfaceWorkload]]
    ) {
        let surfaceIDs = rows.lazy.filter { $0.kind == "surface" }.map(\.ref)
        let processRows = rows.filter { $0.kind == "process" }

        let taggedAgentByRef = Dictionary(
            rows.compactMap { row -> (String, AgentFamily)? in
                guard row.kind == "tag", let family = AgentFamily(tagRef: row.ref) else {
                    return nil
                }
                return (row.ref, family)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var taggedAgentsByPID: [String: Set<AgentFamily>] = [:]
        for process in processRows {
            guard let family = taggedAgentByRef[process.parentRef] else { continue }
            taggedAgentsByPID[process.ref, default: []].insert(family)
        }
        var ownAgentsByPID = taggedAgentsByPID
        for process in processRows {
            guard let family = AgentFamily(processTitle: process.title) else { continue }
            ownAgentsByPID[process.ref, default: []].insert(family)
        }

        var result: [String: SurfaceWorkload] = [:]
        var processIDsBySurfaceID: [String: Set<Int64>] = [:]
        var agentWorkloadsBySurfaceAndProcessID: [String: [Int64: SurfaceWorkload]] = [:]
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
            var hasConflictingPID = false
            for process in processRows where includedPIDs.contains(process.ref) {
                if let family = AgentFamily(processTitle: process.title) {
                    executableAgents.insert(family)
                }
                taggedAgents.formUnion(taggedAgentsByPID[process.ref] ?? [])
                hasConflictingPID = hasConflictingPID
                    || (ownAgentsByPID[process.ref]?.count ?? 0) > 1
                foundShell = foundShell || ShellFamily.matches(process.title)
            }

            if hasConflictingPID || taggedAgents.count > 1 {
                continue
            } else if let taggedAgent = taggedAgents.first {
                // A cmux status tag identifies the owning agent. A nested
                // Codex/Claude helper may appear in the same process tree and
                // must not replace that owner.
                result[surfaceID] = taggedAgent.workload
            } else if executableAgents.count == 1, let family = executableAgents.first {
                result[surfaceID] = family.workload
            } else if executableAgents.isEmpty, foundShell {
                result[surfaceID] = .shell
            }
            // Conflicting agent evidence and unrecognized process-only
            // surfaces deliberately have no fallback instead of guessing.
        }
        return (result, processIDsBySurfaceID, agentWorkloadsBySurfaceAndProcessID)
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
    struct Row: Sendable, Equatable {
        let kind: String
        let ref: String
        let parentRef: String
        let title: String
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
            guard let marker = tagRef.range(of: ":tag:", options: .backwards) else {
                return nil
            }
            switch CmuxTopSnapshot.normalizedToken(String(tagRef[marker.upperBound...])) {
            case "codex": self = .codex
            case "claude", "claudecode": self = .claude
            default: return nil
            }
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
