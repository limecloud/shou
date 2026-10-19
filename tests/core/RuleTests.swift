import Foundation
import ShouCore

func fixtureRule(pattern: String = "**/target", exclusions: [String] = [], minimum: Int64 = 0, age: Int = 0) throws -> Data {
    let object: [String: Any] = [
        "schema_version": "1.0", "id": "test.artifacts", "version": "0.1.0", "name": "Reviewed test artifacts",
        "description": "Fictional build artifacts for isolated integration tests.", "platforms": ["macos"],
        "scope": ["root_ref": "test-workspace", "max_depth": 8, "follow_symlinks": false, "cross_filesystems": false],
        "match": ["kind": "directory", "relative_patterns": [pattern], "project_markers": ["location": "parent", "all_of": ["Cargo.toml"]]],
        "conditions": ["min_allocated_bytes": minimum, "newest_descendant_modified_days_at_least": age],
        "exclude": ["relative_patterns": exclusions],
        "risk": ["declared_level": "review", "rebuild_note": "Rebuild fictional artifacts.", "limitations": ["Test data only."]],
        "action": ["type": "trash"]
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func ruleSchemaAndRoundTrip() throws {
    let rule=try CleanupRule.parse(fixtureRule())
    try expect(rule.id == "test.artifacts")
    try expect(try CleanupRule.parse(Codec.encode(rule)) == rule)
}

func rejectsUnsafePatterns(_ pattern: String) throws {
    try expectThrows { try CleanupRule.parse(fixtureRule(pattern: pattern)) }
}

func rejectsContractViolations(_ field: String) throws {
    var object=try JSONSerialization.jsonObject(with: fixtureRule()) as! [String: Any]
    switch field {
    case "shell": object[field]="echo untrusted"
    case "schema_version": object[field]="99"
    case "action": object[field]=["type": "delete"]
    case "scope": var scope=object[field] as! [String: Any]; scope["follow_symlinks"]=true; object[field]=scope
    default: object[field]=["min_allocated_bytes": -1]
    }
    let bytes=try JSONSerialization.data(withJSONObject: object)
    try expectThrows { try CleanupRule.parse(bytes) }
}

func wildcardSemantics() throws {
    try expect(PathPattern.matches("**/target", "target"))
    try expect(PathPattern.matches("**/target", "one/two/target"))
    try expect(!PathPattern.matches("*/target", "one/two/target"))
    try expect(PathPattern.matches("p?o*/target", "project/target"))
    try expect(PathPattern.matches("**/target/**", "target"))
    try expect(!PathPattern.matches("**/Target", "project/target"))
    try expect(PathPattern.matches("**/Target", "project/target", caseSensitive: false))
    try expect(PathPattern.matches("*a", "*ba"))
    try expect(PathPattern.matches("Profile */Cache", "Profile 中文/Cache"))
}

func wildcardMatcherPreservesLanguage() throws {
    // Independent exhaustive oracle: wildcard matching by direct recursive expansion.
    func oracle(_ pattern: [Character], _ text: [Character]) -> Bool {
        guard let first=pattern.first else { return text.isEmpty }
        if first == "*" {
            return oracle(Array(pattern.dropFirst()), text) || (!text.isEmpty && oracle(pattern, Array(text.dropFirst())))
        }
        return !text.isEmpty && (first == "?" || first == text.first) && oracle(Array(pattern.dropFirst()), Array(text.dropFirst()))
    }
    func words(_ alphabet: [String], max: Int) -> [String] {
        var result=[""], level=[""]
        for _ in 0..<max { level=level.flatMap { prefix in alphabet.map { prefix + $0 } }; result += level }
        return result
    }
    for pattern in words(["a", "b", "*", "?"], max: 4) where !pattern.isEmpty && !pattern.contains("**") {
        for text in words(["a", "b", "*", "中"], max: 3) where !text.isEmpty {
            try expect(PathPattern.matches("root/" + pattern, "root/" + text) == oracle(Array(pattern), Array(text)))
        }
    }
    for path in ["target", "a/target", "a/b/target", "a/b/cache", "a/target/child"] {
        try expect(PathPattern.matches("**/target", path) == (path == "target" || path.hasSuffix("/target")))
    }
}

func wildcardPrefixReachabilityPreservesMatches() throws {
    func paths(_ alphabet: [String], maxDepth: Int) -> [[String]] {
        var result: [[String]]=[[]], level: [[String]]=[[]]
        for _ in 0..<maxDepth {
            level=level.flatMap { prefix in alphabet.map { prefix + [$0] } }
            result += level
        }
        return result
    }
    let prefixes=paths(["a", "b", "中"], maxDepth: 2)
    let suffixes=paths(["a", "b", "中"], maxDepth: 3).filter { !$0.isEmpty }
    // Enumerate actual matches independently of the prefix implementation. A
    // pruning decision must never discard any of these concrete witnesses.
    for pattern in paths(["a", "b", "*", "?", "**"], maxDepth: 3) where !pattern.isEmpty {
        let matcher=PathPattern.Compiled(pattern.joined(separator: "/"), caseSensitive: true)
        for prefix in prefixes {
            for suffix in suffixes where matcher.matches(prefix + suffix) {
                try expect(matcher.couldMatchDescendant(of: prefix))
            }
        }
    }
    for (pattern, prefix) in [
        ("a/b", ["b"]), ("a/b", ["a", "b"]), ("a/b", ["a", "b", "a"]),
        ("a/**/b", ["b"]), ("a/*/b", ["a", "a", "a"]),
        ("a/?/b", ["a", "中文"]), ("a/b/**", ["a", "a"])
    ] {
        try expect(!PathPattern.Compiled(pattern, caseSensitive: true).couldMatchDescendant(of: prefix))
    }
    try expect(PathPattern.Compiled("**", caseSensitive: true).couldMatchDescendant(of: ["a", "b"]))
    try expect(PathPattern.Compiled("**/a", caseSensitive: true).couldMatchDescendant(of: ["a"]))
    try expect(PathPattern.Compiled("a/**", caseSensitive: true).couldMatchDescendant(of: ["a"]))
    try expect(PathPattern.Compiled("**/**/a", caseSensitive: true).couldMatchDescendant(of: []))
    try expect(PathPattern.Compiled("a/?/b", caseSensitive: true).couldMatchDescendant(of: ["a", "中"]))
    try expect(PathPattern.Compiled("a/?/b", caseSensitive: true).couldMatchDescendant(of: ["a", "👩🏽‍💻"]))
    try expect(PathPattern.Compiled("A/Cache/b", caseSensitive: false).couldMatchDescendant(of: ["a", "cache"]))
}

func canonicalDigestIndependentOfObjectKeyOrder() throws {
    let a=Data("{\"one\":1,\"two\":2}".utf8), b=Data("{\"two\":2,\"one\":1}".utf8)
    try expect(try Digest.of(JSONDecoder().decode(JSONValue.self, from: a)) == Digest.of(JSONDecoder().decode(JSONValue.self, from: b)))
}

func envelopeUsesStableKeysAndExplicitNull() throws {
    let data=try Codec.encode(ResultEnvelope(data: ["value": "\u{1b}[31mfile\nname"]))
    let value=try JSONDecoder().decode(JSONValue.self, from: data)
    try expect(value["api_version"] == .string("1.0"))
    try expect(value["error"] == .null)
    try expect(!String(decoding: data, as: UTF8.self).contains("\u{1b}"))
}

func utcTimestampsPreserveDecisionPrecision() throws {
    struct Sample: Codable { var timestamp: Date }
    let value=Sample(timestamp: Date(timeIntervalSince1970: 1_792_378_123.987654))
    let bytes=try Codec.encode(value)
    let restored=try Codec.decode(Sample.self, from: bytes)
    try expect(abs(value.timestamp.timeIntervalSince1970-restored.timestamp.timeIntervalSince1970) < 0.000001)
    try expect(try Digest.of(value) == Digest.of(restored))
}
