import Foundation
import UniformTypeIdentifiers

/// An in-memory reference to a logical set being reordered. The pasteboard
/// receives only a short-lived random token, keeping the set identifier inside
/// the Companion process and separate from surface/member drag payloads.
struct SetOrderDragPayload: Hashable, Sendable {
    let setID: UUID
}

final class SetOrderDragRegistry: @unchecked Sendable {
    static let shared = SetOrderDragRegistry()

    private struct Entry {
        let payload: SetOrderDragPayload
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var latestToken: String?

    func issue(_ payload: SetOrderDragPayload, now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }

        entries = entries.filter { $0.value.expiresAt > now }
        while entries.count >= 128,
              let oldest = entries.min(by: {
                  $0.value.expiresAt < $1.value.expiresAt
              })?.key {
            entries.removeValue(forKey: oldest)
        }

        var token: String
        repeat { token = UUID().uuidString } while entries[token] != nil
        entries[token] = Entry(
            payload: payload,
            expiresAt: now.addingTimeInterval(120)
        )
        latestToken = token
        return token
    }

    func take(_ token: String, now: Date = Date()) -> SetOrderDragPayload? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries.removeValue(forKey: token),
              entry.expiresAt > now else { return nil }
        if latestToken == token {
            latestToken = nil
        }
        return entry.payload
    }

    func latest(now: Date = Date()) -> SetOrderDragPayload? {
        lock.lock()
        defer { lock.unlock() }

        guard let latestToken,
              let entry = entries[latestToken],
              entry.expiresAt > now else {
            self.latestToken = nil
            return nil
        }
        return entry.payload
    }
}

enum SetOrderDragTransport {
    static let contentType = UTType(
        exportedAs: "dev.cmuxcompanion.set-order-drag-token",
        conformingTo: .data
    )

    private static let registry = SetOrderDragRegistry.shared

    static var currentPayload: SetOrderDragPayload? {
        registry.latest()
    }

    static func provider(for payload: SetOrderDragPayload) -> NSItemProvider {
        let data = Data(registry.issue(payload).utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: contentType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Starts loading exactly one app-private set-order drag token. Returning
    /// true means the provider was accepted; callers validate that the source
    /// and destination sets still exist when the asynchronous load completes.
    @discardableResult
    static func receiveOne(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable (SetOrderDragPayload) -> Void
    ) -> Bool {
        let matches = providers.filter {
            $0.hasItemConformingToTypeIdentifier(contentType.identifier)
        }
        guard matches.count == 1, let provider = matches.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, error in
            guard error == nil,
                  let data,
                  data.count == 36,
                  let token = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: token),
                  uuid.uuidString == token,
                  let payload = registry.take(token) else { return }
            Task { @MainActor in completion(payload) }
        }
        return true
    }

    static func selfTest() -> Bool {
        let payload = SetOrderDragPayload(setID: UUID())
        let token = registry.issue(payload)
        let registryRoundTrip = registry.take(token) == payload
        let itemProvider = provider(for: payload)
        let providerAdvertisesType = itemProvider.hasItemConformingToTypeIdentifier(
            contentType.identifier
        )
        let currentPayloadIsVisibleToDropIndicators = currentPayload == payload
        return registryRoundTrip
            && providerAdvertisesType
            && currentPayloadIsVisibleToDropIndicators
    }
}
