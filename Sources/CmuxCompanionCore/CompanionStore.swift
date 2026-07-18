import Foundation

public enum CompanionStoreError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            return "Unsupported companion schema version \(found); this build supports \(supported)."
        }
    }
}

enum CompanionJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }

            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date or Unix timestamp."
            )
        }
        return decoder
    }
}

/// Atomic JSON persistence for the companion's complete logical-set snapshot.
public final class CompanionStore: @unchecked Sendable {
    public let url: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        url: URL = CompanionPaths.defaultSetsURL,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> CompanionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: url.path) else {
            return CompanionSnapshot()
        }

        let data = try Data(contentsOf: url)
        let snapshot = try CompanionJSON.decoder().decode(CompanionSnapshot.self, from: data)
        guard snapshot.schemaVersion == CompanionSnapshot.currentSchemaVersion else {
            throw CompanionStoreError.unsupportedSchemaVersion(
                found: snapshot.schemaVersion,
                supported: CompanionSnapshot.currentSchemaVersion
            )
        }
        return snapshot
    }

    public func save(_ snapshot: CompanionSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }

        guard snapshot.schemaVersion == CompanionSnapshot.currentSchemaVersion else {
            throw CompanionStoreError.unsupportedSchemaVersion(
                found: snapshot.schemaVersion,
                supported: CompanionSnapshot.currentSchemaVersion
            )
        }

        let parentDirectory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let data = try CompanionJSON.encoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func save(sets: [WorkSet]) throws {
        try save(CompanionSnapshot(sets: sets))
    }
}
