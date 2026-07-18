import Foundation

/// A lossless-enough representation of arbitrary JSON returned by cmux.
///
/// cmux's socket/CLI schemas are additive and evolve independently of the
/// companion. Transport code therefore keeps the original JSON next to its
/// normalized DTOs instead of decoding directly into a rigid Codable model.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// A string projection intended only for identifiers and compatibility
    /// fields. It deliberately does not stringify objects or arrays.
    public var lossyStringValue: String? {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        case .null, .array, .object: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .integer(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .integer(let value): return value
        case .number(let value):
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int64.min),
                  value <= Double(Int64.max) else { return nil }
            return Int64(value)
        case .string(let value): return Int64(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }

    public func firstValue(forKeys keys: [String]) -> JSONValue? {
        guard let object = objectValue else { return nil }
        return keys.lazy.compactMap { object[$0] }.first
    }

    public func firstString(forKeys keys: [String]) -> String? {
        firstValue(forKeys: keys)?.lossyStringValue?.nilIfEmpty
    }

    public func firstBool(forKeys keys: [String]) -> Bool? {
        firstValue(forKeys: keys)?.boolValue
    }

    public func firstInt64(forKeys keys: [String]) -> Int64? {
        firstValue(forKeys: keys)?.int64Value
    }

    /// Looks for an array under any of `keys`, accepting the common v2 RPC
    /// wrappers used by cmux. A top-level array is returned unchanged.
    public func transportArray(forKeys keys: [String]) -> [JSONValue] {
        if case .array(let values) = self { return values }

        let candidates = [
            self,
            self["result"],
            self["data"],
            self["payload"],
            self["response"]
        ].compactMap { $0 }

        for candidate in candidates {
            if case .array(let values) = candidate { return values }
            for key in keys {
                if case .array(let values)? = candidate[key] { return values }
            }
        }
        return []
    }
}

public enum CmuxJSON {
    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func decode(_ string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw CmuxTransportError.invalidUTF8
        }
        return try decode(data)
    }

    public static func encode(_ value: JSONValue, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try encoder.encode(value)
    }
}

public enum CmuxTransportError: Error, LocalizedError, Sendable, Equatable {
    case emptyOutput(command: [String])
    case invalidUTF8
    case invalidEventFrame(String)
    case eventStreamError(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput(let command):
            return "cmux returned no JSON for: \((["cmux"] + command).joined(separator: " "))"
        case .invalidUTF8:
            return "cmux returned invalid UTF-8"
        case .invalidEventFrame(let detail):
            return "Invalid cmux event frame: \(detail)"
        case .eventStreamError(let message):
            return "cmux event stream error: \(message)"
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
