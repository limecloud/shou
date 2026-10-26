import Foundation
import ShouCore
import ShouPlatform
import ShouAgentSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CommandSpec: Codable, Sendable {
    let command: String
    let sideEffect: String
    let required: [String]
    let optional: [String]
    let repeated: [String]
    let exactlyOne: [String]?
    let inputSchema: JSONValue?
    let description: String
    init(_ command: String, _ sideEffect: String, _ required: [String] = [], _ optional: [String] = [], repeated: [String] = [], exactlyOne: [String]? = nil, inputSchema: JSONValue? = nil, _ description: String) {
        self.command=command; self.sideEffect=sideEffect; self.required=required; self.optional=optional; self.repeated=repeated; self.exactlyOne=exactlyOne; self.inputSchema=inputSchema; self.description=description
    }
}

private let completionInputSchema: JSONValue = .object([
    "type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("shell")]),
    "properties": .object([
        "shell": .object(["type": .string("string"), "enum": .array([.string("bash"), .string("zsh")])])
    ])
])

private let applicationUpdateInputSchema: JSONValue = .object([
    "type": .string("object"), "additionalProperties": .bool(false),
    "required": .array([.string("path"), .string("allow-network")]),
    "properties": .object([
        "path": .object(["type": .string("string")]),
        "allow-network": .object(["type": .string("string"), "enum": .array([.string("true")])])
    ])
])

private let largeFileInputSchema: JSONValue = .object([
    "type": .string("object"), "required": .array([.string("scan-id")]), "additionalProperties": .bool(false),
    "properties": .object([
        "scan-id": .object(["type": .string("string"), "description": .string("A saved analysis scan ID, including legacy scans without a catalog.")]),
        "minimum-bytes": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(Int64.max), "default": .integer(52_428_800)]),
        "type": .object(["type": .string("string"), "enum": .array(StorageFileType.allCases.map { .string($0.rawValue) }), "default": .string("all")]),
        "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(500), "default": .integer(100)]),
        "cursor": .object(["type": .string("string"), "description": .string("Opaque next_cursor for the same scan, minimum-bytes and type; omit after changing filters.")])
    ])
])

private let storageComparisonInputSchema: JSONValue = .object([
    "type": .string("object"), "additionalProperties": .bool(false),
    "required": .array([.string("baseline-id"), .string("scan-id")]),
    "properties": .object([
        "baseline-id": .object(["type": .string("string")]),
        "scan-id": .object(["type": .string("string")]),
        "path": .object(["type": .string("string"), "default": .string(".")]),
        "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(100), "default": .integer(50)]),
        "max-entries": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(100_000), "default": .integer(100_000)]),
        "max-seconds": .object(["type": .string("number"), "minimum": .integer(1), "maximum": .integer(30), "default": .integer(10)])
    ])
])

private let uninstallBatchInputSchema: JSONValue = .object([
    "type": .string("object"), "required": .array([.string("file")]), "additionalProperties": .bool(false),
    "properties": .object([
        "file": .object(["type": .string("string"), "description": .string("JSON array of 1–100 selections: review_id, component_ids (nonempty distinct strings), include_user_data (boolean, default false). Each selection must include its application component. File limit 1 MiB."),
            "contentMediaType": .string("application/json"), "contentSchema": .object([
                "type": .string("array"), "minItems": .integer(1), "maxItems": .integer(100), "items": .object([
                    "type": .string("object"), "required": .array([.string("review_id"), .string("component_ids")]), "additionalProperties": .bool(false),
                    "properties": .object([
                        "review_id": .object(["type": .string("string")]),
                        "component_ids": .object(["type": .string("array"), "minItems": .integer(1), "uniqueItems": .bool(true), "items": .object(["type": .string("string")])]),
                        "include_user_data": .object(["type": .string("boolean"), "default": .bool(false)])
                    ])
                ])
            ])]),
        "mode": .object(["type": .string("string"), "enum": .array([.string("permanent"), .string("trash")]), "default": .string("permanent")])
    ])
])

private let applicationSummaryInputSchema: JSONValue = .object([
    "type": .string("object"), "additionalProperties": .bool(false), "properties": .object([
        "include-system": .object(["type": .string("string"), "enum": .array([.string("true"), .string("false")]), "default": .string("false")]),
        "max-entries": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(1_000_000), "default": .integer(100_000)]),
        "max-seconds": .object(["type": .string("number"), "minimum": .integer(1), "maximum": .integer(600), "default": .integer(60)])
    ])
])

let commands: [CommandSpec] = [
    .init("completion", "read", ["shell"], [], inputSchema: completionInputSchema, "Print Bash or Zsh completion generated from public command discovery. Shell is bash or zsh. Does not install, edit shell configuration, open local records or execute operations."),
    .init("diagnostics", "read", [], [], "Collect a sanitized, metadata-only report of disk capacity, access and local-record directory safety. Never opens or creates the record store, changes permissions or uploads data."),
    .init("capabilities", "read", [], ["command"], "Discover operations, inputs, limits, and platform capabilities without opening storage. Command optionally selects one command or group."),
    .init("agent skill", "read", [], [], "Read the bundled rule-authoring skill and its local entrypoint. External agents use it to ask questions, inspect evidence, and preview custom rules; no model or agent is started."),
    .init("skills list", "read", [], [], "List the bundled rule-authoring skill and supporting files; no record-store access."),
    .init("skills read", "read", [], ["file"], "Read bundled instructions; file is SKILL.md (default), references/questionnaire.md, or agents/openai.yaml."),
    .init("skills install", "configuration", ["agent"], ["directory"], "Install the bundled Skill for codex or claude-code. Directory overrides the parent skills folder; default is the client's user skills folder. Preserve local edits; back up managed updates."),
    .init("skills export", "configuration", ["output"], [], "Export the whole Skill as a ZIP for WorkBuddy's Add Skill > Upload Skill. Never overwrite an existing output file."),
    .init("locations list", "read", [], [], "List built-in application and developer cache roots, their existence, and scoped rules; does not scan or grant access."),
    .init("startup list", "read", [], ["include-system"], "Read bounded macOS launchd definitions; include-system adds machine sources (true/false, default false). Report configured/runtime states and explicit unknowns without changing settings. macOS Login Items and background registrations remain in System Settings."),
    .init("startup control", "configuration", ["path", "action"], [], "Enable or disable one current-user LaunchAgent on macOS. Rechecks the exact definition and identity before mutation and verifies the result. Action is enable or disable; other sources use system management."),
    .init("applications list", "read", [], ["include-system"], "Discover macOS application bundles with explicit source coverage; never changes applications."),
    .init("applications leftovers scan", "snapshot", [], [], "Review exact orphan associations for maintained or previously verified bundle identifiers. Require complete standard-source and native-registration absence; shared containers are retained."),
    .init("applications leftovers plan", "plan", ["review-id", "component"], ["include-user-data", "mode"], repeated: ["component"], "Select eligible orphan components; personal data needs explicit consent. Defaults to permanent removal."),
    .init("applications leftovers show", "read", ["plan-id"], [], "Read the exact leftover selection, digest and expiry."),
    .init("applications leftovers execute", "destructive", ["plan-id"], [], "Recheck owner absence and every manifest before reviewed leftover removal; use shared cleanup history."),
    .init("applications summary", "read", [], ["include-system", "max-entries", "max-seconds"], inputSchema: applicationSummaryInputSchema, "Read application sizes, versions, activity/ownership status (ready/running/admin-required/protected/unavailable) and optional last-used metadata from one inventory. Size is an allocated-byte estimate; no removal manifests are saved. Last-used may be unknown. Per-application measurement budget defaults to 100000 entries/60 seconds. Admin-required items cannot be removed by this build."),
    .init("applications updates source", "read", ["path"], [], "Describe a supported Homebrew Cask catalog mapping without network access or local-store writes. A mapping does not prove Homebrew installed the application."),
    .init("applications updates check", "network", ["path", "allow-network"], [], inputSchema: applicationUpdateInputSchema, "Explicitly query formulae.brew.sh for one mapped application. Requires --allow-network true. Compares numeric catalog versions only; unknown is partial/exit 6. No package downloads, installation, inventory upload, redirects or record-store access."),
    .init("applications inspect", "snapshot", ["path"], ["max-entries", "max-seconds"], "Review an application and exact bundle-identifier associations. Personal data is separate; shared groups and package receipts are not removed."),
    .init("applications plan", "plan", ["review-id", "component"], ["include-user-data", "mode"], repeated: ["component"], "Plan explicitly selected eligible components, including the application. Personal data requires include-user-data true; defaults false. Mode trash (legacy default) or permanent (irreversible)."),
    .init("applications plan show", "read", ["plan-id"], [], "Inspect an uninstall plan, exact components, consent, digest and expiry."),
    .init("applications uninstall", "destructive", ["plan-id"], [], "Execute reviewed application components in the plan's mode after current-scope terminal confirmation. Trash supports history restore; permanent removal cannot be restored."),
    .init("applications batch plan", "plan", ["file"], ["mode"], inputSchema: uninstallBatchInputSchema, "Create one plan from a JSON array of explicit application-review selections. Each selection has review_id, component_ids and optional include_user_data (default false). Mode permanent (default, irreversible) or trash. Reject all duplicate/overlapping paths before execution; personal data requires consent per application."),
    .init("applications batch plan show", "read", ["plan-id"], [], "Show all application selections, exact components, removal mode, consent, total estimate, digest and expiry for one batch."),
    .init("applications batch uninstall", "destructive", ["plan-id"], [], "Execute a reviewed application batch after one current-scope terminal confirmation. Recheck every application before starting and each component before mutation; partial results enter shared history."),
    .init("workspaces list", "read", [], [], "List registered workspaces."),
    .init("workspaces show", "read", ["workspace"], [], "Show workspace and current process access."),
    .init("workspaces add", "configuration", ["path", "root-ref"], [], "Register a local workspace; does not grant OS permissions."),
    .init("workspaces remove", "configuration", ["workspace"], [], "Unregister a workspace and its bindings; does not remove target files or history."),
    .init("workspaces exclude add", "configuration", ["workspace", "pattern"], ["project"], "Exclude a workspace-relative pattern, or a pattern under a literal relative project directory."),
    .init("workspaces exclude remove", "configuration", ["workspace", "pattern"], ["project"], "Remove an explicit workspace exclusion; project uses the same literal prefix as add."),
    .init("exclusions list", "read", [], ["workspace"], "List global patterns and, optionally, workspace and combined patterns. Per-rule exclusions remain in rule definitions."),
    .init("exclusions global add", "configuration", ["pattern"], [], "Protect a relative pattern in all current and future workspaces. Requires configuration version 2; older builds refuse it."),
    .init("exclusions global remove", "configuration", ["pattern"], [], "Remove a global exclusion. This does not remove workspace or per-rule exclusions."),
    .init("rules schema", "read", [], [], "Get the bundled rule schema."),
    .init("rules validate", "read", ["file"], [], "Validate structure and static semantics without importing."),
    .init("rules import", "configuration", ["file"], [], "Import an immutable disabled draft."),
    .init("rules list", "read", [], [], "List rule versions and bindings."),
    .init("rules catalog", "read", [], ["workspace"], "List built-in templates, or their scoped definitions for a workspace."),
    .init("rules show", "read", ["rule-id"], ["version"], "Show a rule definition."),
    .init("rules export", "read", ["rule-id"], ["version", "output"], "Export only the shareable rule definition."),
    .init("rules enable", "configuration", ["rule-id", "workspace"], ["version"], "Enable a rule binding; does not authorize cleanup."),
    .init("rules disable", "configuration", ["rule-id", "workspace"], ["version"], "Disable a rule binding."),
    .init("rules preview", "snapshot", ["file", "workspace"], [], "Scan a draft without allowing executable plans."),
    .init("rules opportunities", "read", ["scan-id"], ["minimum-bytes", "offset", "limit"], "Find uncovered directories in a full workspace scan. Nested rows overlap; size is investigation evidence, never deletion permission."),
    .init("scan", "snapshot", [], ["workspace", "location", "rule-id", "scope", "max-entries", "max-seconds"], repeated: ["rule-id"], exactlyOne: ["workspace", "location"], "Scan one registered workspace or built-in location. Scope full (default) measures the whole tree; cleanup discovers and measures rule targets. Save immutable evidence."),
    .init("system scan", "snapshot", [], ["include-projects", "max-entries", "max-seconds"], "Scan built-in cache roots; optionally discover conventional developer folders and include remembered projects (include-projects true/false, default false). Report each location's failures."),
    .init("scan results", "read", ["scan-id"], ["limit", "cursor"], "Page through stable candidate results."),
    .init("analysis scan", "snapshot", ["path"], ["max-entries", "max-seconds"], "Analyze all accessible entries using a disk-backed index, without a cleanup workspace or automatic selection. Explicit max-entries/max-seconds select a bounded legacy snapshot."),
    .init("analysis plan", "plan", ["scan-id", "path"], ["mode"], repeated: ["path"], "Review explicit literal file and directory paths from space analysis; mode trash (default) or permanent. Parent selections subsume descendants."),
    .init("analysis plan show", "read", ["plan-id"], [], "Show the exact space removal scope, byte estimates, digest and expiry."),
    .init("analysis remove", "destructive", ["plan-id"], [], "Remove reviewed space-analysis items after terminal confirmation. File evidence is rechecked; results enter shared history."),
    .init("analysis summary", "read", ["scan-id"], [], "Show non-overlapping cleanup categories and measured workspace usage."),
    .init("analysis children", "read", ["scan-id"], ["path", "limit", "cursor"], "Browse allocated space in a saved scan; default path is the workspace root (.)."),
    .init("analysis context", "read", ["scan-id"], ["path"], "Export bounded space-analysis evidence and a ready-to-paste agent request from the saved scan; does not rescan or upload."),
    .init("analysis map", "read", ["scan-id"], ["path"], "Read a bounded multilevel space map and scoped extension totals from a saved scan."),
    .init("analysis history", "read", ["scan-id"], [], "Find earlier disk-index analyses of the same root identity within a bounded directory listing. Reads current metadata and at most 127 enumerated entries, 4 MiB per record and 8 MiB total; ranks only examined candidates by time. Truncation, unavailable or legacy records remain coverage issues."),
    .init("analysis compare", "read", ["baseline-id", "scan-id"], ["path", "limit", "max-entries", "max-seconds"], inputSchema: storageComparisonInputSchema, "Compare one directory in two immutable disk-index analyses. Limit 1–100 (default 50), max-entries 1–100000 (default 100000), max-seconds 1–30 (default 10). Rank observed changes by magnitude in the examined scope; absent, replaced or incomplete objects have no numeric growth claim. Allocated estimates are not reclaimable bytes; does not scan or authorize removal."),
    .init("analysis large-files", "read", ["scan-id"], ["minimum-bytes", "type", "limit", "cursor"], inputSchema: largeFileInputSchema,
          "Query saved space-analysis evidence across all directories without rescanning. Minimum-bytes is nonnegative allocated bytes (default 52428800 = 50 MiB); type is all (default), video, audio, image, archive, document, ai-model or other, inferred only from filename extensions. Limit 1..500 (default 100). Stable order is allocated bytes descending then full path ascending. Hard links follow saved space accounting; byte totals are estimates. Reuse returned paths with analysis plan, then analysis remove for confirmed execution."),
    .init("plan create", "plan", ["scan-id", "candidate"], ["mode"], repeated: ["candidate"], "Create a plan from explicitly selected candidates. Mode is trash (default) or permanent."),
    .init("plan show", "read", ["plan-id"], [], "Inspect exact scope, manifest digest, risk, and expiry."),
    .init("plan execute", "destructive", ["plan-id"], [], "Execute the current Trash or permanent plan after terminal confirmation."),
    .init("history list", "read", [], [], "List execution receipts."),
    .init("history summaries", "read", [], ["offset", "limit"], "Page through lightweight execution summaries without filesystem manifests. Use history show for full evidence."),
    .init("records preview", "read", [], [], "Preview automatic expiry/quota cleanup of derived Shou scans and plans. Recovery journals and user files are retained."),
    .init("records collect", "configuration", [], [], "Collect expired or over-quota derived Shou records under the mutation lease. Preserves active plans, recent scans and recovery journals."),
    .init("tools scan", "snapshot", [], [], "Preview local Docker build cache, Conda caches and non-current Rust toolchains with fixed owner-tool operations; Homebrew cleanup is macOS-only."),
    .init("tools plan", "plan", ["scan-id", "target-id"], [], "Create a short-lived plan for one explicit tool-managed target. Preview includes rebuild and environment impact."),
    .init("tools execute", "destructive", ["plan-id"], [], "Confirm permanent owner-tool cleanup; no arbitrary shell commands or remote Docker context. Outcomes enter tool history."),
    .init("tools history", "read", [], [], "Inspect tool-cleanup receipts, including interrupted or unverified outcomes."),
    .init("system close-plan", "plan", ["scan-id"], [], repeated: ["scan-id"], "Group running cleanup owners from current scans into an identity-bound quit preview."),
    .init("system close-applications", "destructive", ["plan-id"], [], "Request graceful quit after terminal confirmation and verify all helpers stopped; never force-kill applications or delete files."),
    .init("history cleanup-preview", "read", [], ["execution-id", "include-recoverable"], repeated: ["execution-id"], "Preview local receipt cleanup. Recoverable and unfinished records are kept by default; target files are never removed."),
    .init("history clear", "destructive", [], ["execution-id", "include-recoverable"], repeated: ["execution-id"], "Confirm removal of local receipt records only. include-recoverable=true also discards Shou recovery links; target files stay untouched."),
    .init("history show", "read", ["execution-id"], [], "Show item states and follow-up receipts."),
    .init("history inspect", "read", ["execution-id"], ["max-entries", "max-seconds"], "Verify exact recorded original and Trash locations without changing files or receipts; never searches Trash or retries interrupted actions."),
    .init("history restore", "destructive", ["execution-id", "item"], [], repeated: ["item"], "Confirm and restore selected verified receipt items without overwrite."),
    .init("history purge", "destructive", ["execution-id", "item"], [], repeated: ["item"], "Separately confirm irreversible removal of selected receipt items."),
    .init("presets list", "read", [], [], "List reusable rule selections."),
    .init("presets show", "read", ["preset-id"], [], "Show preset configuration."),
    .init("presets save", "configuration", ["name", "workspace", "rule-id"], [], repeated: ["rule-id"], "Save selection logic, never deletion permission."),
    .init("presets scan", "snapshot", ["preset-id"], [], "Generate a fresh scan using a saved preset.")
] + PrivacyCLI.commands + AICLI.commands

struct Arguments {
    var command: String
    var values: [String: [String]] = [:]
    var json: Bool
    var help: Bool
    var locale: String
    init(_ raw: [String]) throws {
        json=raw.contains("--json"); help=raw.contains("--help") || raw.contains("-h") || raw.isEmpty
        locale="en"
        var words: [String]=[], index=0
        while index < raw.count {
            let token=raw[index]
            if ["--json", "--help", "-h"].contains(token) { index += 1; continue }
            if token.hasPrefix("--") {
                let key=String(token.dropFirst(2))
                guard index+1 < raw.count, !raw[index+1].hasPrefix("--") else { throw ShouError("invalid_argument", "Option requires a value.", details: ["option": token]) }
                values[key, default: []].append(raw[index+1]); index += 2
            } else { words.append(token); index += 1 }
        }
        command=words.joined(separator: " ")
        if words.starts(with: ["skills", "read"]), words.count > 2 {
            let target=words[2].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard (3...4).contains(words.count), target.first.map(String.init) == ShouAgentSkill.name,
                  target.count == 1 || words.count == 3, values["file"] == nil else {
                throw ShouError("invalid_argument", "Use skills read shou-rule-authoring [relative-file], or skills read --file <relative-file>.")
            }
            if target.count == 2 { values["file"]=[String(target[1])] }
            else if words.count == 4 { values["file"]=[words[3]] }
            command="skills read"
        }
        if let requested=values["locale"]?.first {
            let normalized=requested.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: ".")[0]
            if normalized == "en" || normalized.hasPrefix("en-") { locale="en" }
            else if ["zh", "zh-cn", "zh-hans", "zh-hans-cn"].contains(normalized) { locale="zh-CN" }
            else { throw ShouError("invalid_argument", "Unsupported explicit locale. Available: en, zh-CN.") }
        } else if Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true { locale="zh-CN" }
        if help { return }
        if !commands.contains(where: { $0.command == command }),
           commands.contains(where: { $0.command.hasPrefix(command + " ") }),
           values.keys.allSatisfy({ $0 == "locale" }) { help=true; return }
        guard let spec=commands.first(where: { $0.command == command }) else { throw ShouError("invalid_argument", "Unknown command. Use shou --help.", details: ["command": command]) }
        let allowed=Set(spec.required + spec.optional + ["locale"])
        for (key, list) in values {
            guard allowed.contains(key), list.count == 1 || spec.repeated.contains(key) else { throw ShouError("invalid_argument", "Unknown or repeated option.", details: ["option": key]) }
        }
        for key in spec.required where values[key]?.isEmpty != false { throw ShouError("invalid_argument", "Required option is missing.", details: ["option": key]) }
        if let alternatives=spec.exactlyOne {
            guard alternatives.filter({ values[$0]?.isEmpty == false }).count == 1 else {
                throw ShouError("invalid_argument", "Exactly one scan target is required.", details: ["options": alternatives.map { "--" + $0 }.joined(separator: ", ")])
            }
        }
    }
    func value(_ key: String) -> String { values[key]?.first ?? "" }
    func all(_ key: String) -> [String] { values[key] ?? [] }
}

enum Terminal {
    static func confirm<T: Encodable>(_ scope: T, phrase: String, locale: String) throws {
        guard let tty=FileHandle(forUpdatingAtPath: "/dev/tty"), isatty(tty.fileDescriptor) == 1 else { throw ShouError("confirmation_required", "An interactive terminal is required. No targets were changed.") }
        defer { try? tty.close() }
        let scopeObject=try JSONSerialization.jsonObject(with: Codec.encode(scope))
        let scopeBytes=try JSONSerialization.data(withJSONObject: scopeObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try tty.write(contentsOf: scopeBytes)
        let prompt=locale == "zh-CN" ? "\n请核对以上具体范围。输入 \(phrase) 确认，其他输入取消：\n" : "\nReview the exact scope above. Type \(phrase) to confirm; any other input cancels:\n"
        try tty.write(contentsOf: Data(prompt.utf8))
        var response=Data()
        while response.count < 256 {
            guard let byte=try tty.read(upToCount: 1), !byte.isEmpty else { break }
            if byte.first == 10 { break }
            response.append(byte)
        }
        guard String(data: response, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == phrase else { throw ShouError("cancelled", "Operation cancelled. No targets were changed.") }
    }
}

@main enum ShouCLI {
    static let version = "0.17.0"
    static func main() async {
        #if canImport(Darwin) || canImport(Glibc)
        if let status=NativeReadWorker.runIfRequested(Array(CommandLine.arguments.dropFirst())) { Foundation.exit(status) }
        #endif
        await run()
    }
    static func ruleData(_ path: String) throws -> Data {
        let handle=try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        return try handle.read(upToCount: 262_145) ?? Data()
    }
    static func summary(_ scan: ScanSnapshot) throws -> JSONValue {
        .object(["scan_id": .string(scan.id), "status": .string(scan.status), "scope": .string((scan.scope ?? .full).rawValue), "tree_complete": .bool(scan.treeComplete ?? (scan.status == "complete")), "preview_only": .bool(scan.previewOnly), "workspace_id": .string(scan.workspace.id), "entry_count": .integer(Int64(scan.entries.count)), "candidate_count": .integer(Int64(scan.candidates.count)), "eligible_count": .integer(Int64(scan.candidates.filter(\.eligible).count)), "reviewable_bytes_estimate": .integer(CleanupOverview.candidates(scan.candidates).filter(\.eligible).reduce(0) { $0 + $1.allocatedBytesEstimate }), "issues": try .from(scan.issues)])
    }
    static func output(_ envelope: ResultEnvelope, json: Bool) throws {
        var data=try Codec.encode(envelope)
        if !json {
            let object=try JSONSerialization.jsonObject(with: data)
            data=try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
    }
    static func result(_ value: JSONValue, warnings: [String] = [], next: [JSONValue] = [], json: Bool) throws {
        var envelope=try ResultEnvelope(data: value, warnings: warnings, nextActions: next)
        let partial=value["status"] == .string("partial") || value["state"] == .string("partial") || value.array?.contains(where: { $0["state"] == .string("failed") }) == true
        if partial { envelope.ok=false; envelope.status="partial" }
        try output(envelope, json: json)
        if partial { exit(6) }
    }
    static func run() async {
        let raw=Array(CommandLine.arguments.dropFirst())
        if raw == ["--version"] { print("shou \(version) (CLI API 1.0, rule format 1.0)"); return }
        do {
            let args=try Arguments(raw)
            if args.help {
                let help=try CLICommandDiscovery.help(for: args.command)
                if args.json { try output(ResultEnvelope(data: help), json: true) } else { print(help) }
                return
            }
            if args.command == "completion" {
                let script=try CLICompletion.script(shell: args.value("shell"))
                if args.json { try result(.object(["shell": .string(args.value("shell")), "script": .string(script)]), json: true) }
                else { print(script, terminator: "") }
                return
            }
            if args.command == "diagnostics" {
                let report=try NativeDiagnostics.collect(applicationVersion: version)
                if args.json { try result(try .from(report), json: true) }
                else {
                    print(report.text(locale: args.locale), terminator: "")
                    if report.status == "partial" { exit(6) }
                }
                return
            }
            if args.command == "applications updates source" {
                let application=try NativeApplicationCatalog().application(at: args.value("path"))
                let source=try ApplicationUpdateChecker.source(for: application)
                try result(.object(["application": try .from(application), "source": try source.map { try JSONValue.from($0) } ?? .null,
                    "status": .string(source == nil ? "unsupported" : "available")]), json: args.json)
                return
            }
            if args.command == "applications updates check" {
                guard args.value("allow-network") == "true" else { throw ShouError("invalid_argument", "Catalog checks require explicit --allow-network true.") }
                let observation=try await ApplicationUpdateChecker.native().check(path: args.value("path"))
                try result(try .from(observation), json: args.json)
                return
            }
            if args.command == "capabilities" {
                let fs=NativeFileSystem()
                let selected=try CLICommandDiscovery.matching(args.value("command"))
                let value: JSONValue = .object(["application_version": .string(version), "api_version": .string("1.0"), "rule_schema_version": .string("1.0"), "platform": .string(fs.platform), "runtime_locales": .array([.string("en"), .string("zh-CN")]), "commands": try .from(selected), "trash_available": .bool(fs.supportsTrash), "confirmation": .string("interactive_current_scope"), "limits": .object(["rule_bytes": .integer(262144), "scan_entries": .integer(100000), "scan_seconds": .integer(60), "scan_entries_max": .integer(1000000), "scan_seconds_max": .integer(600), "scan_depth_max": .integer(128), "page_size": .integer(500)]), "limitations": .array([.string("Cleanup requires local filesystem access and an explicit review of the current selection."), .string("Only local user-owned workspaces without ancestor links are supported."), .string("AI investigation uses an explicitly selected model connection and bounded metadata. Cleanup always requires current-scope confirmation.")])])
                let discovery=value
                try result(discovery, json: args.json)
                return
            }
            if args.command == "agent skill" {
                try result(try .from(ShouAgentSkill.descriptor()), json: args.json)
                return
            }
            if args.command.hasPrefix("skills ") {
                let value: JSONValue
                switch args.command {
                case "skills list":
                    value = .array([.object(["name": .string(ShouAgentSkill.name), "files": try .from(ShouAgentSkill.files)])])
                case "skills read":
                    let file = args.values["file"]?.first ?? "SKILL.md"
                    guard ShouAgentSkill.files.contains(file) else { throw ShouError("invalid_argument", "Unknown bundled Skill file.", details: ["file": file]) }
                    let content = try ShouAgentSkill.read(file: file)
                    if !args.json { print(content, terminator: ""); return }
                    value = .object(["name": .string(ShouAgentSkill.name), "file": .string(file), "content": .string(content)])
                case "skills install":
                    guard let client = AgentSkillInstallation.Client(rawValue: args.value("agent")) else { throw ShouError("invalid_argument", "Choose agent codex or claude-code. Export a ZIP and use Upload Skill for WorkBuddy.") }
                    let directory = args.values["directory"]?.first.map { URL(fileURLWithPath: $0) }
                    value = try .from(AgentSkillInstallation.install(client: client, skillsDirectory: directory))
                case "skills export":
                    let output = URL(fileURLWithPath: args.value("output"))
                    try AgentSkillInstallation.exportArchive(to: output)
                    value = .object(["name": .string(ShouAgentSkill.name), "path": .string(output.path), "state": .string("exported")])
                default: throw ShouError("invalid_argument", "Unknown Skill operation.")
                }
                try result(value, json: args.json)
                return
            }
            if args.command == "applications list" {
                let includeSystem=args.values["include-system"]?.first ?? "false"
                guard ["true", "false"].contains(includeSystem) else { throw ShouError("invalid_argument", "Include-system must be true or false.") }
                let catalog: JSONValue
                catalog=try .from(await ApplicationCatalogService(source: NativeApplicationCatalog()).scan(options: ApplicationCatalogOptions(includeSystem: includeSystem == "true")))
                try result(catalog, warnings: [], json: args.json)
                return
            }
            if args.command == "startup list" {
                let includeSystem=args.values["include-system"]?.first ?? "false"
                guard ["true", "false"].contains(includeSystem) else { throw ShouError("invalid_argument", "Include-system must be true or false.") }
                let inventory=try await StartupInventoryService(source: NativeStartupInventory()).scan(options: StartupInventoryOptions(includeSystem: includeSystem == "true"))
                try result(try .from(inventory), warnings: ["Review source coverage and unavailable_sources before drawing conclusions. Configured/runtime state is a best-effort read and may change immediately after inspection."], json: args.json)
                return
            }
            if args.command == "startup control" {
                let actionValue=args.value("action").lowercased()
                guard let action=StartupControlAction(rawValue: actionValue), action == .enable || action == .disable else { throw ShouError("invalid_argument", "Startup action must be enable or disable.") }
                let inventory=try NativeStartupInventory().read(options: StartupInventoryOptions(includeSystem: false))
                guard let definition=inventory.items.first(where: { $0.path == args.value("path") && $0.sourceId == "macos.user_agents" }) else {
                    throw ShouError("invalid_argument", "The startup definition is not a directly controllable current-user item in the inspected sources.")
                }
                let phrase="STARTUP \(action.rawValue.uppercased()) \(definition.label)"
                let scope=StartupControlReviewScope(action: action.rawValue, label: definition.label, path: definition.path, source: definition.sourceId,
                    notes: [args.locale == "zh-CN" ? "仅修改所选当前用户启动项的配置，不会终止已运行进程。执行前重新核验定义与身份，执行后读取配置确认结果。" : "Only the selected current-user startup configuration changes; running processes are not terminated. The definition and identity are rechecked before execution and the configuration is read back afterwards."])
                try Terminal.confirm(scope, phrase: phrase, locale: args.locale)
                let controlResult=try NativeStartupControl().apply(definition: definition, action: action)
                try result(try .from(controlResult), json: args.json)
                return
            }
            let directory=ProcessInfo.processInfo.environment["SHOU_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? LocalRecordStore.defaultDirectory
            let store=try LocalRecordStore(directory: directory)
            let fs=NativeFileSystem()
            let engine=ShouEngine(store: store, filesystem: fs, applicationActivity: NativeApplicationActivity(), artifactEvidence: NativeArtifactEvidence(), applicationCatalog: NativeApplicationCatalog(), uninstallEvidence: NativeApplicationUninstallEvidence(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL))
            if try await AICLI.run(args, engine: engine, store: store) { return }
            if try await PrivacyCLI.run(args, engine: engine) { return }
            var value: JSONValue = .null
            var warnings: [String] = []
            var next: [JSONValue] = []
            func scanValue(_ snapshot: ScanSnapshot) throws -> JSONValue { try summary(snapshot) }
            func nextResults(_ scan: ScanSnapshot) -> [JSONValue] { [.object(["command": .string("scan results"), "arguments": .object(["scan_id": .string(scan.id)])])] }
            switch args.command {
            case "applications leftovers scan": value=try .from(await engine.reviewApplicationOrphans(presence: NativeApplicationAbsence()))
            case "applications leftovers plan":
                let include=args.values["include-user-data"]?.first ?? "false"
                guard ["true","false"].contains(include) else { throw ShouError("invalid_argument", "Include-user-data must be true or false.") }
                value=try .from(await engine.createApplicationOrphanPlan(reviewId: args.value("review-id"), componentIds: args.all("component"), includeUserData: include == "true", action: args.values["mode"]?.first ?? "permanent"))
            case "applications leftovers show": value=try .from(await engine.applicationOrphanPlan(args.value("plan-id")))
            case "applications leftovers execute":
                let plan=try await engine.applicationOrphanPlan(args.value("plan-id"))
                try Terminal.confirm(plan, phrase: (plan.action == "permanent" ? "PURGE " : "TRASH ") + plan.id, locale: args.locale)
                value=try .from(await engine.executeApplicationOrphans(planId: plan.id, confirmedDigest: plan.digest, presence: NativeApplicationAbsence(), entryPoint: "cli"))
            case "locations list": value=try .from(await engine.knownLocations())
            case "applications summary":
                let includeSystem=args.values["include-system"]?.first ?? "false"
                guard ["true", "false"].contains(includeSystem), let entries=Int(args.values["max-entries"]?.first ?? "100000"),
                      let seconds=Double(args.values["max-seconds"]?.first ?? "60") else { throw ShouError("invalid_argument", "Use boolean include-system and numeric measurement budgets.") }
                let summary=try await engine.applicationSummaries(options: ApplicationCatalogOptions(includeSystem: includeSystem == "true"), budget: ScanBudget(maxEntries: entries, maxSeconds: seconds))
                value = .object(["status": .string(summary.status), "catalog": try .from(summary.catalog), "items": try .from(summary.items), "metric": .string("allocated_bytes_estimate"), "last_used_detection": .string("native_last_used_metadata")])
            case "applications inspect":
                guard let entries=Int(args.values["max-entries"]?.first ?? "100000"), let seconds=Double(args.values["max-seconds"]?.first ?? "60") else { throw ShouError("invalid_argument", "Scan budgets must be numeric.") }
                let review=try await engine.reviewApplication(path: args.value("path"), budget: ScanBudget(maxEntries: entries, maxSeconds: seconds))
                value=try .from(review); warnings=review.limitations
            case "applications plan":
                let consent=args.values["include-user-data"]?.first ?? "false"
                guard ["true", "false"].contains(consent) else { throw ShouError("invalid_argument", "Include-user-data must be true or false.") }
                value=try .from(await engine.createUninstallPlan(reviewId: args.value("review-id"), componentIds: args.all("component"), includeUserData: consent == "true", action: args.values["mode"]?.first ?? "trash"))
            case "applications plan show": value=try .from(await engine.uninstallPlan(args.value("plan-id")))
            case "applications uninstall":
                let plan=try await engine.uninstallPlan(args.value("plan-id"))
                try Terminal.confirm(TerminalReviewScope(uninstall: plan, locale: args.locale), phrase: (plan.effectiveAction == "permanent" ? "PURGE " : "UNINSTALL ") + plan.id, locale: args.locale)
                value=try .from(await engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "cli"))
            case "applications batch plan":
                let url=URL(fileURLWithPath: args.value("file"))
                let bytes=try Data(contentsOf: url, options: .mappedIfSafe)
                guard bytes.count <= 1_048_576, let selections=try? Codec.decode([ApplicationUninstallSelection].self, from: bytes) else {
                    throw ShouError("invalid_argument", "Use a JSON selection array no larger than 1 MiB; see applications batch plan --help.")
                }
                value=try .from(await engine.createUninstallBatchPlan(selections: selections, action: args.values["mode"]?.first ?? "permanent"))
            case "applications batch plan show": value=try .from(await engine.uninstallBatchPlan(args.value("plan-id")))
            case "applications batch uninstall":
                let plan=try await engine.uninstallBatchPlan(args.value("plan-id"))
                try Terminal.confirm(TerminalReviewScope(uninstallBatch: plan, locale: args.locale), phrase: (plan.action == "permanent" ? "PURGE " : "UNINSTALL ") + plan.id, locale: args.locale)
                value=try .from(await engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "cli"))
            case "system scan":
                guard let maxEntries=Int(args.values["max-entries"]?.first ?? "100000"), let maxSeconds=Double(args.values["max-seconds"]?.first ?? "60") else { throw ShouError("invalid_argument", "Scan budgets must be numeric.") }
                let projectOption=args.values["include-projects"]?.first ?? "false"
                guard ["true", "false"].contains(projectOption) else { throw ShouError("invalid_argument", "Include-projects must be true or false.") }
                let result=try await engine.scanKnownLocations(includeProjects: projectOption == "true", budget: ScanBudget(maxEntries: maxEntries, maxSeconds: maxSeconds))
                value = .object(["status": .string(result.status), "locations": try .from(result.locations), "scans": .array(try result.snapshots.map(summary)), "issues": try .from(result.issues), "skipped_location_ids": try .from(result.skippedLocationIds)])
                warnings=result.issues.map { $0.locationId + ": " + $0.message }
                next=result.snapshots.flatMap(nextResults)
            case "workspaces list": value=try .from(await engine.configuration().workspaces)
            case "workspaces show":
                let workspace=try await engine.workspace(args.value("workspace"))
                let accessible=try await engine.workspaceAccessible(args.value("workspace"))
                value = .object(["workspace": try .from(workspace), "accessible": .bool(accessible)])
            case "workspaces add": value=try .from(await engine.addWorkspace(path: args.value("path"), rootRef: args.value("root-ref")))
            case "workspaces remove":
                try await engine.removeWorkspace(args.value("workspace"))
                value = .object(["removed": .bool(true), "workspace_id": .string(args.value("workspace"))])
            case "workspaces exclude add", "workspaces exclude remove": value=try .from(await engine.setExclusion(workspaceId: args.value("workspace"), pattern: args.value("pattern"), remove: args.command.hasSuffix("remove"), project: args.values["project"]?.first))
            case "exclusions list": value=try .from(await engine.exclusionSettings(workspaceId: args.values["workspace"]?.first))
            case "exclusions global add", "exclusions global remove":
                value = .object(["global_patterns": try .from(await engine.setGlobalExclusion(pattern: args.value("pattern"), remove: args.command.hasSuffix("remove")))])
            case "rules schema": value=try CleanupRule.schema()
            case "rules opportunities":
                guard let minimum=Int64(args.values["minimum-bytes"]?.first ?? "52428800"), let offset=Int(args.values["offset"]?.first ?? "0"), let limit=Int(args.values["limit"]?.first ?? "50") else { throw ShouError("invalid_argument", "Opportunity limits must be integers.") }
                value=try .from(await engine.ruleOpportunities(scanId: args.value("scan-id"), minimumBytes: minimum, offset: offset, limit: limit))
                warnings=["Nested directories overlap; do not sum rows. Unknown purpose is not permission to delete. Inspect children and confirm rebuild costs before drafting a rule."]
                next=[.object(["command": .string("analysis children"), "arguments": .object(["scan_id": .string(args.value("scan-id")), "path": .string(".")])])]
            case "rules validate":
                let rule=try CleanupRule.parse(ruleData(args.value("file")))
                value = .object(["valid": .bool(true), "rule_id": .string(rule.id), "version": .string(rule.version), "digest": .string(try Digest.of(rule)), "runtime_verified": .bool(false)])
            case "rules import": value=try .from(await engine.importRule(ruleData(args.value("file"))))
            case "rules list":
                let config=try await engine.configuration()
                value = .object(["rules": try .from(config.rules), "bindings": try .from(config.bindings), "builtin_templates": try .from(BuiltinCatalog.templates())])
            case "rules catalog":
                value=args.value("workspace").isEmpty ? try .from(BuiltinCatalog.templates()) : try .from(await engine.builtinRules(workspaceId: args.value("workspace")))
            case "rules show", "rules export":
                let records=try await engine.configuration().rules.filter { $0.rule.id == args.value("rule-id") && (args.value("version").isEmpty || $0.rule.version == args.value("version")) }
                guard let rule=records.max(by: { $0.importedAt < $1.importedAt })?.rule else { throw ShouError("invalid_argument", "Unknown rule/version.") }
                if args.command == "rules export", !args.value("output").isEmpty {
                    let destination=URL(fileURLWithPath: args.value("output"))
                    try Codec.encode(rule).write(to: destination, options: [.withoutOverwriting])
                    value = .object(["path": .string(destination.path), "rule_id": .string(rule.id)])
                } else { value=try .from(rule) }
            case "rules enable", "rules disable": value=try .from(await engine.setRule(ruleId: args.value("rule-id"), workspaceId: args.value("workspace"), enabled: args.command.hasSuffix("enable"), version: args.values["version"]?.first))
            case "rules preview", "scan":
                let draft=args.command == "rules preview" ? try CleanupRule.parse(ruleData(args.value("file"))) : nil
                guard let maxEntries=Int(args.values["max-entries"]?.first ?? "100000"), let maxSeconds=Double(args.values["max-seconds"]?.first ?? "60") else { throw ShouError("invalid_argument", "Scan budgets must be numeric.") }
                let budget=ScanBudget(maxEntries: maxEntries, maxSeconds: maxSeconds)
                guard let scope=ScanScope(rawValue: args.values["scope"]?.first ?? "full") else { throw ShouError("invalid_argument", "Scan scope must be full or cleanup.") }
                let snapshot: ScanSnapshot
                if args.command == "scan", !args.value("location").isEmpty {
                    snapshot=try await engine.scan(locationId: args.value("location"), ruleIds: args.all("rule-id"), scope: scope, budget: budget)
                } else {
                    snapshot=try await engine.scan(workspaceId: args.value("workspace"), ruleIds: args.all("rule-id"), previewRule: draft, scope: scope, budget: budget)
                }
                value=try scanValue(snapshot); warnings=snapshot.issues; next=nextResults(snapshot)
                if draft != nil {
                    if case .object(var fields)=value {
                        fields["benefits"]=try .from(await engine.rulePreviewBenefits(scanId: snapshot.id)); value = .object(fields)
                    }
                    next += [.object(["command": .string("rules enable"), "arguments": .object(["workspace": .string(snapshot.workspace.id), "rule_id": .string(draft!.id), "version": .string(draft!.version)]), "requires_user_choice": .bool(true)])]
                } else if scope == .full {
                    next += [.object(["command": .string("rules opportunities"), "arguments": .object(["scan_id": .string(snapshot.id)])])]
                }
            case "scan results":
                let snapshot=try await engine.scanSnapshot(args.value("scan-id"))
                let limit=Int(args.values["limit"]?.first ?? "50") ?? 0
                guard (1...500).contains(limit) else { throw ShouError("invalid_argument", "Limit must be between 1 and 500.") }
                var offset=0
                if let cursor=args.values["cursor"]?.first {
                    let parts=cursor.split(separator: ":")
                    guard parts.count == 2, parts[0] == snapshot.id, let parsed=Int(parts[1]), parsed >= 0, parsed <= snapshot.candidates.count else { throw ShouError("invalid_argument", "Cursor does not belong to this snapshot.") }
                    offset=parsed
                }
                let end=min(offset+limit,snapshot.candidates.count)
                value = .object(["scan_id": .string(snapshot.id), "status": .string(snapshot.status), "candidates": try .from(Array(snapshot.candidates[offset..<end])), "next_cursor": end < snapshot.candidates.count ? .string(snapshot.id + ":" + String(end)) : .null, "total": .integer(Int64(snapshot.candidates.count))])
            case "analysis scan":
                guard let count=Int(args.values["max-entries"]?.first ?? "1000000"), let seconds=Double(args.values["max-seconds"]?.first ?? "600") else { throw ShouError("invalid_argument", "Scan budgets must be numeric.") }
                let bounded=args.values["max-entries"] != nil || args.values["max-seconds"] != nil
                let result=try await engine.scanStorage(path: args.value("path"), budget: bounded ? ScanBudget(maxEntries: count, maxSeconds: seconds) : nil)
                value = .object(["scan_id": .string(result.id), "root_path": .string(result.rootPath), "status": .string(result.status), "entry_count": .integer(Int64(result.entryCount)), "issues": try .from(result.tree.issues)])
                warnings=result.tree.issues
            case "analysis plan":
                value=try .from(await engine.createStorageRemovalPlan(scanId: args.value("scan-id"), paths: args.all("path"), action: args.values["mode"]?.first ?? "trash"))
            case "analysis plan show": value=try .from(await engine.storageRemovalPlan(args.value("plan-id")))
            case "analysis remove":
                let plan=try await engine.storageRemovalPlan(args.value("plan-id"))
                try Terminal.confirm(TerminalReviewScope(storage: plan, locale: args.locale), phrase: (plan.action == "permanent" ? "PURGE " : "TRASH ") + plan.id, locale: args.locale)
                value=try .from(await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "cli"))
            case "analysis context":
                let context=try await engine.storageAnalysisContext(scanId: args.value("scan-id"), path: args.values["path"]?.first ?? ".")
                value = .object(["context": try .from(context), "text": .string(try context.text(locale: args.locale))])
            case "analysis history":
                let history=try await engine.storageComparisonHistory(scanId: args.value("scan-id"))
                value=try .from(history); warnings=history.issues
            case "analysis compare":
                guard let limit=Int(args.values["limit"]?.first ?? "50"),
                      let entries=Int(args.values["max-entries"]?.first ?? "100000"),
                      let seconds=Double(args.values["max-seconds"]?.first ?? "10") else {
                    throw ShouError("invalid_argument", "Comparison budgets must be numeric.")
                }
                let comparison=try await engine.compareStorage(baselineId: args.value("baseline-id"), scanId: args.value("scan-id"),
                    path: args.values["path"]?.first ?? ".", limit: limit, maxEntries: entries, maxSeconds: seconds)
                value=try .from(comparison); warnings=comparison.issues
            case "analysis map":
                value=try .from(await engine.storagePresentation(scanId: args.value("scan-id"), path: args.values["path"]?.first ?? "."))
            case "analysis large-files":
                guard let minimum=Int64(args.values["minimum-bytes"]?.first ?? "52428800"),
                      let limit=Int(args.values["limit"]?.first ?? "100"),
                      let type=StorageFileType(rawValue: args.values["type"]?.first ?? "all") else {
                    throw ShouError("invalid_argument", "Use integer minimum-bytes/limit and a supported filename type. See analysis large-files --help.")
                }
                let snapshot=try await engine.storageScan(args.value("scan-id"))
                let page=try await engine.storageLargeFiles(scanId: snapshot.id, minimumBytes: minimum, type: type,
                    limit: limit, cursor: args.values["cursor"]?.first)
                var rows=[JSONValue]()
                for item in page.items {
                    rows.append(.object(["entry": try .from(item.entry), "node": try .from(item.node),
                        "removal_block_reason": try .from(await engine.storageRemovalReason(scan: snapshot, path: item.entry.path))]))
                }
                value = .object(["scan_id": .string(snapshot.id), "root_path": .string(snapshot.rootPath), "status": .string(snapshot.status),
                    "metric": .string("allocated_bytes_estimate"), "minimum_bytes": .integer(minimum), "type": .string(type.rawValue),
                    "type_detection": .string("filename_extension"), "sort": .string("allocated_bytes_desc_path_asc"),
                    "entries": .array(rows), "total": .integer(Int64(page.totalCount)), "total_allocated_bytes": .integer(page.totalAllocatedBytes),
                    "next_cursor": try .from(page.nextCursor), "issues": try .from(snapshot.tree.issues)])
                warnings=snapshot.tree.issues
            case "analysis summary" where args.value("scan-id").hasPrefix("storage_"):
                let snapshot=try await engine.storageScan(args.value("scan-id"))
                let directory=try await engine.storageDirectory(scanId: snapshot.id)
                value = .object(["scan_id": .string(snapshot.id), "root_path": .string(snapshot.rootPath), "status": .string(snapshot.status), "metric": .string("allocated_bytes_estimate"), "entry_count": .integer(Int64(snapshot.entryCount)), "root": try .from(directory.item.node), "issues": try .from(snapshot.tree.issues)])
            case "analysis children" where args.value("scan-id").hasPrefix("storage_"):
                let snapshot=try await engine.storageScan(args.value("scan-id"))
                let path=args.values["path"]?.first ?? "."
                let limit=Int(args.values["limit"]?.first ?? "50") ?? 0
                let prefix=snapshot.id + ":" + String(try Digest.of(path).prefix(16)) + ":"
                var offset=0
                if let cursor=args.values["cursor"]?.first {
                    guard cursor.hasPrefix(prefix), let parsed=Int(cursor.dropFirst(prefix.count)), parsed >= 0 else { throw ShouError("invalid_argument", "Cursor does not belong to this scan and directory.") }
                    offset=parsed
                }
                let page=try await engine.storageDirectoryPage(scanId: snapshot.id, path: path, offset: offset, limit: limit)
                var rows=[JSONValue]()
                for item in page.children {
                    rows.append(.object(["node": try .from(item.node), "removal_block_reason": try .from(await engine.storageRemovalReason(scan: snapshot, path: item.node.path))]))
                }
                value = .object(["scan_id": .string(snapshot.id), "status": .string(snapshot.status), "path": .string(path), "directory": try .from(page.item.node), "entries": .array(rows), "total": .integer(Int64(page.totalCount)), "next_cursor": page.nextOffset.map { .string(prefix + String($0)) } ?? .null])
            case "analysis summary":
                let snapshot=try await engine.scanSnapshot(args.value("scan-id"))
                guard snapshot.scope != .cleanup else { throw ShouError("partial_result", "Space analysis requires a full-tree scan. Run scan with --scope full.") }
                let storage=StorageIndex(entries: snapshot.entries)
                value = .object(["scan_id": .string(snapshot.id), "status": .string(snapshot.status), "metric": .string("allocated_bytes_estimate"), "root": try .from(storage.nodes["."]), "categories": try .from(CleanupOverview.categories(snapshot.candidates)), "issues": try .from(snapshot.issues)])
            case "analysis children":
                let snapshot=try await engine.scanSnapshot(args.value("scan-id"))
                guard snapshot.scope != .cleanup else { throw ShouError("partial_result", "Space analysis requires a full-tree scan. Run scan with --scope full.") }
                let storage=StorageIndex(entries: snapshot.entries), path=args.values["path"]?.first ?? "."
                guard let directory=storage.nodes[path], directory.kind == "directory" else { throw ShouError("invalid_argument", "Path must name an exact directory in this scan.") }
                let children=storage.children(of: path), limit=Int(args.values["limit"]?.first ?? "50") ?? 0
                guard (1...500).contains(limit) else { throw ShouError("invalid_argument", "Limit must be between 1 and 500.") }
                let prefix=snapshot.id + ":" + String(try Digest.of(path).prefix(16)) + ":"
                var offset=0
                if let cursor=args.values["cursor"]?.first {
                    guard cursor.hasPrefix(prefix), let parsed=Int(cursor.dropFirst(prefix.count)), parsed >= 0, parsed <= children.count else { throw ShouError("invalid_argument", "Cursor does not belong to this scan and directory.") }
                    offset=parsed
                }
                let end=min(offset+limit, children.count)
                value = .object(["scan_id": .string(snapshot.id), "status": .string(snapshot.status), "path": .string(path), "directory": try .from(directory), "entries": try .from(Array(children[offset..<end])), "total": .integer(Int64(children.count)), "next_cursor": end < children.count ? .string(prefix + String(end)) : .null])
            case "plan create":
                let mode=args.values["mode"]?.first ?? "trash"
                value=try .from(await engine.createPlan(scanId: args.value("scan-id"), candidateIds: args.all("candidate"), action: mode))
            case "plan show": value=try .from(await engine.plan(args.value("plan-id")))
            case "plan execute":
                let plan=try await engine.plan(args.value("plan-id"))
                try Terminal.confirm(TerminalReviewScope(plan: plan, locale: args.locale), phrase: (plan.action == "permanent" ? "PURGE " : "TRASH ") + plan.id, locale: args.locale)
                value=try .from(await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "cli"))
            case "history list": value=try .from(await engine.history())
            case "history summaries":
                guard let offset=Int(args.values["offset"]?.first ?? "0"), let limit=Int(args.values["limit"]?.first ?? "50") else { throw ShouError("invalid_argument", "Invalid history page.") }
                value=try .from(await engine.historySummaries(offset: offset, limit: limit))
            case "records preview": value=try .from(await engine.recordRetentionPreview())
            case "records collect": value=try .from(await engine.collectRecords())
            case "tools scan", "tools plan", "tools execute", "tools history":
                let service=ToolCleanupService(runner: NativeCleanupTools(), store: try LocalRecordStore())
                switch args.command {
                case "tools scan": value=try .from(await service.scan())
                case "tools plan": value=try .from(await service.createPlan(scanId: args.value("scan-id"), targetId: args.value("target-id")))
                case "tools execute":
                    let plan=try await service.plan(args.value("plan-id"))
                    try Terminal.confirm(plan, phrase: "CLEAN TOOL " + plan.id, locale: args.locale)
                    value=try .from(await service.execute(planId: plan.id, confirmedDigest: plan.digest))
                default: value=try .from(await service.history())
                }
            case "system close-plan": value=try .from(await engine.cleanupApplicationClosePlan(scanIds: args.all("scan-id")))
            case "system close-applications":
                let plan=try await engine.applicationClosePlan(args.value("plan-id"))
                try Terminal.confirm(plan, phrase: "CLOSE " + plan.id, locale: args.locale)
                value=try .from(await engine.closeApplications(planId: plan.id, confirmedDigest: plan.digest, controller: NativeApplicationClosing()))
            case "history cleanup-preview", "history clear":
                guard let include=Bool(args.values["include-recoverable"]?.first ?? "false") else { throw ShouError("invalid_argument", "include-recoverable must be true or false.") }
                let ids=args.all("execution-id")
                let preview=try await engine.historyCleanupPreview(executionIds: ids.isEmpty ? nil : ids, includeRecoverable: include)
                if args.command == "history clear", !preview.executionIds.isEmpty {
                    try Terminal.confirm(["records": try JSONValue.from(preview), "warning": .string("Remove records only. Files stay untouched. Removed records can no longer be restored or verified through Shou.")], phrase: "CLEAR HISTORY", locale: args.locale)
                    value=try .from(await engine.clearHistory(executionIds: preview.executionIds, includeRecoverable: include))
                } else { value=try .from(preview) }
            case "history inspect":
                guard let maxEntries=Int(args.values["max-entries"]?.first ?? "100000"), let maxSeconds=Double(args.values["max-seconds"]?.first ?? "60") else { throw ShouError("invalid_argument", "Scan budgets must be numeric.") }
                value=try .from(await engine.inspectHistory(executionId: args.value("execution-id"), budget: ScanBudget(maxEntries: maxEntries, maxSeconds: maxSeconds)))
            case "history show":
                let receipt=try await engine.history(args.value("execution-id"))
                let followups=try await engine.followUps().filter { $0.executionId == receipt.id }
                value = .object(["receipt": try .from(receipt), "followups": try .from(followups), "trashed_bytes_estimate": .integer(receipt.trashedBytesEstimate)])
            case "history restore", "history purge":
                let action=args.command.hasSuffix("purge") ? "purge" : "restore"
                let id=args.value("execution-id"), items=args.all("item")
                let digest=try await engine.followUpDigest(executionId: id, itemIds: items, action: action)
                let receipt=try await engine.history(id)
                let originalPlan=try? await engine.plan(receipt.planId)
                let scope=TerminalReviewScope(receipt: receipt, selected: receipt.items.filter { items.contains($0.id) }, action: action, digest: digest, originalPlan: originalPlan, locale: args.locale)
                try Terminal.confirm(scope, phrase: action.uppercased() + " " + id, locale: args.locale)
                value=try .from(await engine.followUp(executionId: id, itemIds: items, action: action, confirmedDigest: digest))
            case "presets list": value=try .from(await engine.configuration().presets)
            case "presets save": value=try .from(await engine.savePreset(name: args.value("name"), workspaceId: args.value("workspace"), ruleIds: args.all("rule-id")))
            case "presets show", "presets scan":
                guard let preset=try await engine.configuration().presets.first(where: { $0.id == args.value("preset-id") }) else { throw ShouError("invalid_argument", "Unknown preset.") }
                if args.command == "presets show" { value=try .from(preset) }
                else { let scan=try await engine.scan(workspaceId: preset.workspaceId, ruleIds: preset.ruleIds); value=try scanValue(scan); warnings=scan.issues; next=nextResults(scan) }
            default: throw ShouError("invalid_argument", "Command is not implemented.")
            }
            try result(value, warnings: warnings, next: next, json: args.json)
        } catch {
            let failure=error as? ShouError ?? ShouError("io_error", error.localizedDescription)
            do { try output(ResultEnvelope(error: failure), json: raw.contains("--json")) }
            catch { try? FileHandle.standardError.write(contentsOf: Data("Shou could not write the result.\n".utf8)) }
            exit(Int32(failure.exitCode))
        }
    }
}
