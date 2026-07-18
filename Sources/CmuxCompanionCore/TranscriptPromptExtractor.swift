import Foundation

public struct ExtractedPrompt: Equatable, Sendable {
    public var text: String
    public var date: Date?

    public init(text: String, date: Date? = nil) {
        self.text = text
        self.date = date
    }
}

/// Best-effort user-prompt extraction for local Codex and Claude JSONL files.
/// Only a bounded tail is read so large, long-running transcripts do not turn
/// the menu-bar refresh into an unbounded disk scan.
public enum TranscriptPromptExtractor {
    public static func latestUserPrompt(
        at url: URL,
        maximumBytes: Int = 2 * 1_024 * 1_024,
        maximumCharacters: Int = 8_000
    ) throws -> ExtractedPrompt? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let requested = UInt64(max(1, maximumBytes))
        let offset = size > requested ? size - requested : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return nil }

        // The first bytes may begin in the middle of a JSONL record.
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...newline)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let candidate = candidatePrompt(in: object),
                  !isInternal(candidate) else {
                continue
            }
            let limited = String(candidate.prefix(max(1, maximumCharacters)))
            return ExtractedPrompt(text: limited, date: parseDate(object["timestamp"]))
        }
        return nil
    }

    private static func candidatePrompt(in object: [String: Any]) -> String? {
        let type = string(object["type"])?.lowercased()
        let payload = object["payload"] as? [String: Any]

        // Codex's event copy is easier to distinguish from tool output than
        // its mirrored response_item message.
        if type == "event_msg",
           string(payload?["type"]) == "user_message",
           let message = string(payload?["message"]) {
            return normalized(message)
        }

        if type == "response_item",
           string(payload?["type"]) == "message",
           string(payload?["role"])?.lowercased() == "user" {
            return normalized(contentText(payload?["content"]))
        }

        // Claude Code JSONL stores the message one level below the envelope.
        if type == "user", object["isMeta"] as? Bool != true,
           let message = object["message"] as? [String: Any],
           string(message["role"])?.lowercased() == "user" {
            return normalized(contentText(message["content"]))
        }

        if string(object["role"])?.lowercased() == "user" {
            return normalized(contentText(object["content"]) ?? string(object["text"]))
        }
        return nil
    }

    private static func contentText(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        guard let values = value as? [Any] else { return nil }
        let parts = values.compactMap { element -> String? in
            guard let item = element as? [String: Any] else { return nil }
            let type = string(item["type"])?.lowercased()
            guard type == nil || type == "text" || type == "input_text" else { return nil }
            return string(item["text"]) ?? string(item["content"])
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func isInternal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let internalPrefixes = [
            "<codex_internal_context",
            "<environment_context",
            "<permissions instructions",
            "<system-reminder",
            "<local-command-caveat",
            "<collaboration_mode",
        ]
        return internalPrefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
