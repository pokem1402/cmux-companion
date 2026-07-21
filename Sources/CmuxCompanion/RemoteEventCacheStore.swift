import Foundation
import CmuxCompanionCore

/// Privacy-minimized persistence for recent unlinked remote identities. Prompt
/// text is deliberately excluded; it remains in cmux Feed or linked set state.
enum RemoteEventCacheStore {
    private struct Envelope: Codable {
        var version = 1
        var states: [PersistedState]
    }

    private struct PersistedState: Codable {
        var sessionID: String
        var source: String?
        var surfaceID: String?
        var workspaceID: String?
        var runtimeState: MemberRuntimeState
        var orderBootID: String?
        var orderSequence: UInt64?
        var receivedAt: Date
        var lastSeenAt: Date

        init(_ state: RemoteEventState) {
            sessionID = state.sessionID
            source = state.source
            surfaceID = state.surfaceID
            workspaceID = state.workspaceID
            runtimeState = state.runtimeState
            orderBootID = state.order?.bootID
            orderSequence = state.order?.sequence
            receivedAt = state.receivedAt
            lastSeenAt = state.lastSeenAt
        }

        var state: RemoteEventState {
            RemoteEventState(
                sessionID: sessionID,
                source: source,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                runtimeState: runtimeState,
                lastSubmittedText: nil,
                lastSubmittedAt: nil,
                order: orderBootID.flatMap { bootID in
                    orderSequence.map {
                        CmuxRemoteEventOrder(bootID: bootID, sequence: $0)
                    }
                },
                receivedAt: receivedAt,
                lastSeenAt: lastSeenAt
            )
        }
    }

    static func load(from url: URL, now: Date = Date()) -> [String: RemoteEventState] {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1 else {
            return [:]
        }
        let states = Dictionary(
            envelope.states
                .map(\.state)
                .filter { state in
                    state.surfaceID.flatMap { UUID(uuidString: $0) } != nil
                }
                .map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, second in
                first.receivedAt >= second.receivedAt ? first : second
            }
        )
        return RemoteEventCachePolicy.retained(states, now: now)
    }

    static func encodedData(for states: [String: RemoteEventState]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(
            states: states.values
                .filter { state in
                    state.surfaceID.flatMap { UUID(uuidString: $0) } != nil
                }
                .sorted { $0.receivedAt > $1.receivedAt }
                .map(PersistedState.init)
        )
        return try encoder.encode(envelope)
    }

    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func save(_ states: [String: RemoteEventState], to url: URL) throws {
        try write(encodedData(for: states), to: url)
    }
}
