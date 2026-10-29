import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue? { if case .object(let object) = self { object[key] } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var numeric: Double? {
        switch self { case .integer(let v): Double(v); case .number(let v): v; default: nil }
    }
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Codec.encode(value))
    }
}

public enum Codec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container=encoder.singleValueContainer()
            let epoch=date.timeIntervalSince1970
            let whole=epoch.rounded(.down)
            let nanos=Int64(((epoch-whole) * 1_000_000_000).rounded())
            let prefix=Date(timeIntervalSince1970: whole).formatted(.iso8601).dropLast()
            try container.encode(String(prefix) + String(format: ".%09lldZ", nanos))
        }
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container=try decoder.singleValueContainer()
            let text=try container.decode(String.self)
            if let dot=text.lastIndex(of: "."), text.hasSuffix("Z") {
                let fractional=text[text.index(after: dot)..<text.index(before: text.endIndex)]
                guard (1...9).contains(fractional.count), fractional.allSatisfy(\.isNumber), let digits=Double("0." + fractional) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected fractional UTC ISO 8601 timestamp.")
                }
                let whole=try Date(String(text[..<dot]) + "Z", strategy: .iso8601)
                return Date(timeIntervalSince1970: whole.timeIntervalSince1970 + digits)
            }
            return try Date(text, strategy: .iso8601)
        }
        return try decoder.decode(type, from: data)
    }
    public static func id(_ prefix: String) -> String { prefix + "_" + UUID().uuidString.lowercased() }
}

public struct ShouError: Error, Codable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var details: [String: String]
    public var retryable: Bool
    public var exitCode: Int {
        switch code {
        case "invalid_argument", "invalid_rule", "unsupported_schema": 2
        case "permission_denied", "access_expired", "authorization_denied": 3
        case "plan_stale", "already_executed", "store_busy", "version_conflict", "restore_conflict", "application_running": 4
        case "partial_result", "resource_limit": 6
        case "confirmation_required": 7
        case "unsupported_platform", "capability_unavailable", "application_activity_unavailable", "comparison_unavailable", "authorization_unavailable": 8
        case "cancelled", "authorization_cancelled": 130
        default: 5
        }
    }
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String, details: [String: String] = [:], retryable: Bool = false) {
        self.code = code; self.message = message; self.details = details; self.retryable = retryable
    }
}

public struct ResultEnvelope: Codable, Sendable {
    public var apiVersion = "1.0"
    public var requestId = Codec.id("request")
    public var ok: Bool
    public var status: String
    public var data: JSONValue
    public var warnings: [String]
    public var error: ShouError?
    public var nextActions: [JSONValue]

    public init<T: Encodable>(data: T, warnings: [String] = [], nextActions: [JSONValue] = []) throws {
        self.ok = true; self.status = "success"; self.data = try .from(data)
        self.warnings = warnings; self.error = nil; self.nextActions = nextActions
    }
    public init(error: ShouError) {
        ok = false; status = error.code == "cancelled" ? "cancelled" : "error"
        data = .null; warnings = []; self.error = error; nextActions = []
    }
    enum CodingKeys: String, CodingKey { case apiVersion, requestId, ok, status, data, warnings, error, nextActions }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiVersion, forKey: .apiVersion); try c.encode(requestId, forKey: .requestId)
        try c.encode(ok, forKey: .ok); try c.encode(status, forKey: .status); try c.encode(data, forKey: .data)
        try c.encode(warnings, forKey: .warnings); try c.encode(error, forKey: .error); try c.encode(nextActions, forKey: .nextActions)
    }
}
