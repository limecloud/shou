import Foundation
import ShouContracts

public struct CleanupRule: Codable, Sendable, Equatable, Identifiable {
    public struct Scope: Codable, Sendable, Equatable {
        public var rootRef: String
        public var maxDepth: Int
        public var followSymlinks: Bool
        public var crossFilesystems: Bool
    }
    public struct Match: Codable, Sendable, Equatable {
        public struct Markers: Codable, Sendable, Equatable { public var location: String; public var allOf: [String] }
        public var kind: String
        public var relativePatterns: [String]
        public var projectMarkers: Markers?
    }
    public struct Conditions: Codable, Sendable, Equatable {
        public var minAllocatedBytes: Int64
        public var newestDescendantModifiedDaysAtLeast: Int?
    }
    public struct Exclude: Codable, Sendable, Equatable { public var relativePatterns: [String] }
    public struct Risk: Codable, Sendable, Equatable {
        public var declaredLevel: String
        public var rebuildNote: String
        public var limitations: [String]
    }
    public struct Action: Codable, Sendable, Equatable { public var type: String }
    public var schemaVersion: String
    public var id: String
    public var version: String
    public var name: String
    public var description: String
    public var platforms: [String]
    public var scope: Scope
    public var match: Match
    public var conditions: Conditions
    public var exclude: Exclude
    public var risk: Risk
    public var action: Action

    public static func parse(_ data: Data) throws -> CleanupRule {
        guard data.count <= 262_144 else { throw ShouError("resource_limit", "Rule exceeds the 256 KiB limit.") }
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw ShouError("invalid_rule", "Rule must contain a valid JSON object.") }
        let schema = try JSONDecoder().decode(JSONValue.self, from: ShouContracts.ruleSchema())
        var issues: [String] = []
        SchemaValidation.check(value, schema: schema, root: schema, path: "$", issues: &issues)
        guard issues.isEmpty else { throw ShouError("invalid_rule", "Rule does not conform to the bundled schema.", details: ["issues": issues.joined(separator: "\n")]) }
        let rule: CleanupRule
        do { rule = try Codec.decode(CleanupRule.self, from: data) }
        catch { throw ShouError("invalid_rule", "Rule fields could not be decoded.") }
        for pattern in rule.match.relativePatterns { try PathPattern.validate(pattern, target: true) }
        for pattern in rule.exclude.relativePatterns { try PathPattern.validate(pattern) }
        for marker in rule.match.projectMarkers?.allOf ?? [] {
            try PathPattern.validate(marker)
            guard !marker.contains("/"), !marker.contains("*"), !marker.contains("?") else {
                throw ShouError("invalid_rule", "Project markers must be exact filenames.", details: ["marker": marker])
            }
        }
        return rule
    }
    public static func schema() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: ShouContracts.ruleSchema()) }
}

/// Implements only the schema vocabulary used by the bundled, closed rule contract.
enum SchemaValidation {
    static func check(_ value: JSONValue, schema: JSONValue, root: JSONValue, path: String, issues: inout [String]) {
        if let ref = schema["$ref"]?.string {
            var destination = root
            for part in ref.dropFirst(2).split(separator: "/") { destination = destination[String(part)] ?? .null }
            check(value, schema: destination, root: root, path: path, issues: &issues); return
        }
        if let constant = schema["const"], constant != value { issues.append("\(path): unexpected constant") }
        if let values = schema["enum"]?.array, !values.contains(value) { issues.append("\(path): unsupported value") }
        let type = schema["type"]?.string
        let valid: Bool
        switch (type, value) {
        case (nil, _), ("object", .object), ("array", .array), ("string", .string), ("integer", .integer), ("boolean", .bool): valid = true
        default: valid = false
        }
        guard valid else { issues.append("\(path): expected \(type ?? "value")"); return }
        switch value {
        case .object(let object):
            let properties = schema["properties"]?.object ?? [:]
            for key in schema["required"]?.array?.compactMap(\.string) ?? [] where object[key] == nil { issues.append("\(path).\(key): required") }
            for (key, child) in object {
                if let childSchema = properties[key] { check(child, schema: childSchema, root: root, path: path + "." + key, issues: &issues) }
                else if schema["additionalProperties"] == .bool(false) { issues.append("\(path).\(key): unknown field") }
            }
        case .array(let array):
            if let min = schema["minItems"]?.numeric, Double(array.count) < min { issues.append("\(path): too few items") }
            if let max = schema["maxItems"]?.numeric, Double(array.count) > max { issues.append("\(path): too many items") }
            if schema["uniqueItems"] == .bool(true) {
                for i in array.indices where array[..<i].contains(array[i]) { issues.append("\(path): duplicate item") }
            }
            if let item = schema["items"] { for (i, child) in array.enumerated() { check(child, schema: item, root: root, path: "\(path)[\(i)]", issues: &issues) } }
        case .string(let text):
            if let min = schema["minLength"]?.numeric, Double(text.unicodeScalars.count) < min { issues.append("\(path): string too short") }
            if let max = schema["maxLength"]?.numeric, Double(text.unicodeScalars.count) > max { issues.append("\(path): string too long") }
            if let pattern = schema["pattern"]?.string, text.range(of: pattern, options: .regularExpression) == nil { issues.append("\(path): invalid format") }
        case .integer(let n):
            if let min = schema["minimum"]?.numeric, Double(n) < min { issues.append("\(path): below minimum") }
            if let max = schema["maximum"]?.numeric, Double(n) > max { issues.append("\(path): above maximum") }
        default: break
        }
    }
}

public enum PathPattern {
    public static func validate(_ pattern: String, target: Bool = false) throws {
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\:$~{}[]`"))
        guard !pattern.isEmpty, pattern.utf8.count <= 2048, pattern.rangeOfCharacter(from: forbidden) == nil,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && (!$0.contains("**") || $0 == "**") }),
              !target || parts.contains(where: { $0.contains(where: { $0 != "*" && $0 != "?" }) }) else {
            throw ShouError("invalid_rule", "Unsafe or overbroad relative pattern.", details: ["pattern": pattern])
        }
    }
    public static func matches(_ pattern: String, _ path: String, caseSensitive: Bool = true) -> Bool {
        Compiled(pattern, caseSensitive: caseSensitive).matches((caseSensitive ? path : path.lowercased()).split(separator: "/").map(String.init))
    }

    /// Parse once per scan, rather than once per directory and rule comparison.
    public struct Compiled: Sendable {
        let parts: [String]
        let recursive: Bool
        public init(_ pattern: String, caseSensitive: Bool) {
            parts=(caseSensitive ? pattern : pattern.lowercased()).split(separator: "/").map(String.init)
            recursive=parts.contains("**")
        }
        private func segment(_ pattern: String, _ text: String) -> Bool {
            guard pattern.contains("*") || pattern.contains("?") else { return pattern == text }
            let a = Array(pattern), b = Array(text)
            var i=0, j=0, star: Int?, restart=0
            while j < b.count {
                if i < a.count && a[i] != "*" && (a[i] == "?" || a[i] == b[j]) { i += 1; j += 1 }
                else if i < a.count && a[i] == "*" { star=i; i += 1; restart=j }
                else if let position=star { restart += 1; j=restart; i=position + 1 }
                else { return false }
            }
            while i < a.count && a[i] == "*" { i += 1 }
            return i == a.count
        }
        public func matches(_ path: [String]) -> Bool {
            if !recursive { return parts.count == path.count && zip(parts, path).allSatisfy { segment($0, $1) } }
            var memo: [Int: Bool]=[:]
            func visit(_ i: Int, _ j: Int) -> Bool {
                let key=i * (path.count + 1) + j
                if let value=memo[key] { return value }
                let value: Bool
                if i == parts.count { value=j == path.count }
                else if parts[i] == "**" { value=visit(i + 1, j) || (j < path.count && visit(i, j + 1)) }
                else { value=j < path.count && segment(parts[i], path[j]) && visit(i + 1, j + 1) }
                memo[key]=value; return value
            }
            return visit(0, 0)
        }

        /// Whether at least one strictly deeper path can match. Callers supply
        /// segments with the same case normalization used for `matches`.
        public func couldMatchDescendant(of path: [String]) -> Bool {
            if !recursive {
                return path.count < parts.count && zip(parts, path).allSatisfy { segment($0, $1) }
            }
            // States are positions between pattern segments. A recursive wildcard
            // can advance without consuming input or remain while consuming one.
            func expand(_ states: inout [Bool]) {
                for index in parts.indices where states[index] && parts[index] == "**" { states[index+1]=true }
            }
            var states=Array(repeating: false, count: parts.count + 1)
            states[0]=true
            expand(&states)
            for text in path {
                var next=Array(repeating: false, count: states.count)
                for index in parts.indices where states[index] {
                    if parts[index] == "**" { next[index]=true }
                    else if segment(parts[index], text) { next[index+1]=true }
                }
                expand(&next)
                guard next.contains(true) else { return false }
                states=next
            }
            // Every remaining validated segment has a nonempty witness. The
            // accepting state alone cannot match a strictly deeper path.
            return parts.indices.contains { states[$0] }
        }
    }
}
