import Foundation

public enum CmuxEventFrameKind: String, Sendable, Equatable {
    case acknowledgement = "ack"
    case event
    case heartbeat
    case error
    case unknown
}

public struct CmuxEventFrame: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: CmuxEventFrameKind
    public let bootID: String?
    public let sequence: Int64?
    public let name: String?
    public let category: String?
    public let source: String?
    public let occurredAt: String?
    public let workspaceID: String?
    public let surfaceID: String?
    public let paneID: String?
    public let windowID: String?
    public let payload: JSONValue?
    public let resumeGap: Bool
    public let isContentRedacted: Bool
    public let raw: JSONValue

    public init(raw: JSONValue) throws {
        guard raw.objectValue != nil else {
            throw CmuxTransportError.invalidEventFrame("expected a JSON object")
        }

        if raw.firstBool(forKeys: ["ok"]) == false {
            let message = raw["error"]?.firstString(forKeys: ["message", "code"])
                ?? raw.firstString(forKeys: ["message"])
                ?? "unknown server error"
            throw CmuxTransportError.eventStreamError(message)
        }

        let type = raw.firstString(forKeys: ["type", "frame_type"])?.lowercased()
        self.kind = type.flatMap(CmuxEventFrameKind.init(rawValue:)) ?? .unknown
        self.bootID = raw.firstString(forKeys: ["boot_id", "bootId"])
        self.sequence = raw.firstInt64(forKeys: ["seq", "sequence"])
        self.name = raw.firstString(forKeys: ["name", "event_name"])
        self.category = raw.firstString(forKeys: ["category"])
        self.source = raw.firstString(forKeys: ["source"])
        self.occurredAt = raw.firstString(forKeys: ["occurred_at", "occurredAt", "timestamp"])
        self.workspaceID = raw.firstString(forKeys: ["workspace_id", "workspaceId", "tab_id"])
        self.surfaceID = raw.firstString(forKeys: ["surface_id", "surfaceId", "panel_id"])
        self.paneID = raw.firstString(forKeys: ["pane_id", "paneId"])
        self.windowID = raw.firstString(forKeys: ["window_id", "windowId"])
        self.payload = raw["payload"] ?? raw["data"]
        self.resumeGap = raw["resume"]?.firstBool(forKeys: ["gap", "has_gap"]) ?? false
        self.isContentRedacted = Self.detectRedaction(payload: self.payload, raw: raw)
        self.raw = raw
        self.id = raw.firstString(forKeys: ["id", "event_id"])
            ?? [self.bootID, self.sequence.map(String.init)].compactMap { $0 }.joined(separator: "-")
            .nilIfEmptyTransport
            ?? UUID().uuidString
    }

    public static func decode(line: String) throws -> CmuxEventFrame {
        do {
            return try CmuxEventFrame(raw: CmuxJSON.decode(line))
        } catch let error as CmuxTransportError {
            throw error
        } catch {
            let preview = String(line.prefix(240))
            throw CmuxTransportError.invalidEventFrame("\(preview): \(error.localizedDescription)")
        }
    }

    private static func detectRedaction(payload: JSONValue?, raw: JSONValue) -> Bool {
        if raw.firstBool(forKeys: ["payload_truncated", "redacted", "is_redacted"]) == true {
            return true
        }
        guard let payload else { return false }
        if payload.firstBool(forKeys: ["payload_truncated", "redacted", "is_redacted"]) == true {
            return true
        }
        if case .array(let fields)? = payload["redacted_fields"], !fields.isEmpty {
            return true
        }
        for field in ["text", "prompt", "message", "title", "subtitle", "body", "tool_input"] {
            if payload[field] == .null,
               payload.firstValue(forKeys: ["\(field)_length", "\(field)Length"]) != nil {
                return true
            }
        }
        if case .array(let fields)? = raw["redacted_fields"], !fields.isEmpty {
            return true
        }
        return false
    }
}

public struct CmuxEventStreamConfiguration: Sendable, Equatable {
    public var cursorFile: URL
    public var names: [String]
    public var categories: [String]

    public init(cursorFile: URL, names: [String] = [], categories: [String] = []) {
        self.cursorFile = cursorFile
        self.names = names
        self.categories = categories
    }

    public var arguments: [String] {
        var result = [
            "events",
            "--cursor-file", cursorFile.path,
            "--reconnect",
            "--no-heartbeat"
        ]
        for name in names { result += ["--name", name] }
        for category in categories { result += ["--category", category] }
        return result
    }
}

/// Typed facade over `cmux events`. The CLI owns reconnect and cursor-file
/// persistence; cancelling the consuming task terminates that CLI process.
/// Calling `frames` again creates a fresh process that resumes from the cursor.
public final class CmuxEventStream: Sendable {
    private let runner: any CmuxLineStreaming

    public init(runner: any CmuxLineStreaming) {
        self.runner = runner
    }

    public convenience init(locator: CmuxExecutableLocator = CmuxExecutableLocator()) throws {
        try self.init(runner: CmuxProcessRunner(locator: locator))
    }

    public func frames(
        configuration: CmuxEventStreamConfiguration
    ) -> AsyncThrowingStream<CmuxEventFrame, Error> {
        let lines = runner.streamLines(arguments: configuration.arguments)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        continuation.yield(try CmuxEventFrame.decode(line: line))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

extension String {
    fileprivate var nilIfEmptyTransport: String? { isEmpty ? nil : self }
}
