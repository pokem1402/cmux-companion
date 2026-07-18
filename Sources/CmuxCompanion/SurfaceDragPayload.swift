import Foundation
import UniformTypeIdentifiers

enum SurfaceDragOrigin: String, Hashable, Sendable {
    case liveSurface
    case member
    case attachment
}

/// An in-memory reference to a drag source. The pasteboard receives only a
/// short-lived random token; surface IDs, session IDs, and prompts stay inside
/// the Companion process.
struct SurfaceDragPayload: Hashable, Sendable {
    let origin: SurfaceDragOrigin
    let surfaceID: String?
    let sourceSetID: UUID?
    let itemID: UUID?
}

final class SurfaceDragRegistry: @unchecked Sendable {
    static let shared = SurfaceDragRegistry()

    private struct Entry {
        let payload: SurfaceDragPayload
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func issue(_ payload: SurfaceDragPayload, now: Date = Date()) -> String {
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
        return token
    }

    func take(_ token: String, now: Date = Date()) -> SurfaceDragPayload? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries.removeValue(forKey: token),
              entry.expiresAt > now else { return nil }
        return entry.payload
    }
}

enum SurfaceDragTransport {
    static let contentType = UTType(
        exportedAs: "dev.cmuxcompanion.surface-drag-token",
        conformingTo: .data
    )

    private static let registry = SurfaceDragRegistry.shared

    static func provider(for payload: SurfaceDragPayload) -> NSItemProvider {
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

    /// Starts loading exactly one app-private drag token. Returning true means
    /// the provider was accepted; model validation happens on the main actor
    /// after the asynchronous representation load completes.
    @discardableResult
    static func receiveOne(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable (SurfaceDragPayload) -> Void
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
        let payload = SurfaceDragPayload(
            origin: .member,
            surfaceID: "selftest-surface",
            sourceSetID: UUID(),
            itemID: UUID()
        )
        let token = registry.issue(payload)
        let registryRoundTrip = registry.take(token) == payload
        let itemProvider = provider(for: payload)
        let providerAdvertisesType = itemProvider.hasItemConformingToTypeIdentifier(
            contentType.identifier
        )
        // A command-line self-test has no packaged Info.plist, so Launch
        // Services cannot resolve the exported type's public.data conformance
        // here. The packaging checks verify that declaration separately.
        return registryRoundTrip && providerAdvertisesType
    }
}
