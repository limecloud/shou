import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CommandSpec: Codable, Sendable {
    let command: String
    let sideEffect: String
    let required: [String]
    let optional: [String]
    let repeated: [String]
    let exactlyOne: [String]?
    let description: String
    init(_ command: String, _ sideEffect: String, _ required: [String] = [], _ optional: [String] = [], repeated: [String] = [], exactlyOne: [String]? = nil, _ description: String) {
        self.command=command; self.sideEffect=sideEffect; self.required=required; self.optional=optional; self.repeated=repeated; self.exactlyOne=exactlyOne; self.description=description
    }
}

let commands: [CommandSpec] = [
    .init("capabilities", "read", [], [], "Discover implemented operations, inputs, limits, and platform capabilities."),
    .init("locations list", "read", [], [], "List built-in application and developer cache roots, their existence, and scoped rules; does not scan or grant access."),
    .init("startup list", "read", [], ["include-system"], "Read bounded macOS launchd definitions (include-system true/false, default false). Report best-effort configured/runtime states and explicit unknowns; never changes startup settings. Login Items and background registrations remain in System Settings."),
    .init("startup control", "configuration", ["path", "action"], [], "Enable or disable one current-user LaunchAgent after rechecking its plist, owner, label and exact path. Action is enable or disable; system definitions remain read-only."),
    .init("applications list", "read", [], ["include-system"], "Discover macOS application bundles with explicit directory coverage; never changes applications."),
    .init("applications inspect", "snapshot", ["path"], ["max-entries", "max-seconds"], "Review an application and exact bundle-identifier associations. Personal data is separate; shared groups and package receipts are not removed."),
    .init("applications plan", "plan", ["review-id", "component"], ["include-user-data"], repeated: ["component"], "Plan explicitly selected eligible components, including the application. Personal data requires include-user-data true; defaults false."),
    .init("applications plan show", "read", ["plan-id"], [], "Inspect an uninstall plan, exact components, consent, digest and expiry."),
    .init("applications uninstall", "destructive", ["plan-id"], [], "Move reviewed application components to native Trash after current-scope terminal confirmation. Restore through history."),
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
    .init("scan", "snapshot", [], ["workspace", "location", "rule-id", "scope", "max-entries", "max-seconds"], repeated: ["rule-id"], exactlyOne: ["workspace", "location"], "Scan one registered workspace or built-in location. Scope full (default) measures the whole tree; cleanup discovers and measures rule targets. Save immutable evidence."),
    .init("system scan", "snapshot", [], ["include-projects", "max-entries", "max-seconds"], "Scan existing built-in cache roots with cleanup coverage; optionally include registered projects (true/false, default false). Report each location's failures."),
    .init("scan results", "read", ["scan-id"], ["limit", "cursor"], "Page through stable candidate results."),
    .init("analysis summary", "read", ["scan-id"], [], "Show non-overlapping cleanup categories and measured workspace usage."),
    .init("analysis children", "read", ["scan-id"], ["path", "limit", "cursor"], "Browse allocated space in a saved scan; default path is the workspace root (.)."),
    .init("plan create", "plan", ["scan-id", "candidate"], [], repeated: ["candidate"], "Create a plan from explicitly selected candidates."),
    .init("plan show", "read", ["plan-id"], [], "Inspect exact scope, manifest digest, risk, and expiry."),
    .init("plan execute", "destructive", ["plan-id"], [], "Move current plan targets to Trash after terminal confirmation."),
    .init("history list", "read", [], [], "List execution receipts."),
    .init("history show", "read", ["execution-id"], [], "Show item states and follow-up receipts."),
    .init("history inspect", "read", ["execution-id"], ["max-entries", "max-seconds"], "Verify exact recorded original and Trash locations without changing files or receipts; never searches Trash or retries interrupted actions."),
    .init("history restore", "destructive", ["execution-id", "item"], [], repeated: ["item"], "Confirm and restore selected verified receipt items without overwrite."),
    .init("history purge", "destructive", ["execution-id", "item"], [], repeated: ["item"], "Separately confirm irreversible removal of selected receipt items."),
    .init("presets list", "read", [], [], "List reusable rule selections."),
    .init("presets show", "read", ["preset-id"], [], "Show preset configuration."),
    .init("presets save", "configuration", ["name", "workspace", "rule-id"], [], repeated: ["rule-id"], "Save selection logic, never deletion permission."),
    .init("presets scan", "snapshot", ["preset-id"], [], "Generate a fresh scan using a saved preset.")
]

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
        if let requested=values["locale"]?.first {
            let normalized=requested.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: ".")[0]
            if normalized == "en" || normalized.hasPrefix("en-") { locale="en" }
            else if ["zh", "zh-cn", "zh-hans", "zh-hans-cn"].contains(normalized) { locale="zh-CN" }
            else { throw ShouError("invalid_argument", "Unsupported explicit locale. Available: en, zh-CN.") }
        } else if Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true { locale="zh-CN" }
        if help { return }
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
    static let version = "0.3.0"
    static func main() async {
        if let status=NativeReadWorker.runIfRequested(Array(CommandLine.arguments.dropFirst())) { Foundation.exit(status) }
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
                var help="Shou · 收拾一下 — Tidy up. That's it.\n\nUsage: shou <command> [options] [--json] [--locale en|zh-CN]\n\n"
                for spec in commands {
                    let inputs=spec.required.map { "--\($0) <value>" }.joined(separator: " ")
                    let alternatives=spec.exactlyOne.map { "(" + $0.map { "--\($0) <value>" }.joined(separator: " | ") + ")" } ?? ""
                    help += "  \(spec.command) \(inputs)\(alternatives)\n      \(spec.description)\n"
                }
                help += "\nUse capabilities --json for machine-readable definitions.\nDestructive operations require current-scope terminal confirmation.\n"
                if args.json { try output(ResultEnvelope(data: help), json: true) } else { print(help) }
                return
            }
            if args.command == "applications list" {
                let includeSystem=args.values["include-system"]?.first ?? "false"
                guard ["true", "false"].contains(includeSystem) else { throw ShouError("invalid_argument", "Include-system must be true or false.") }
                let catalog=try await ApplicationCatalogService(source: NativeApplicationCatalog()).scan(options: ApplicationCatalogOptions(includeSystem: includeSystem == "true"))
                try result(try .from(catalog), warnings: [], json: args.json)
                return
            }
            if args.command == "startup list" {
                let includeSystem=args.values["include-system"]?.first ?? "false"
                guard ["true", "false"].contains(includeSystem) else { throw ShouError("invalid_argument", "Include-system must be true or false.") }
                let inventory=try await StartupInventoryService(source: NativeStartupInventory()).scan(options: StartupInventoryOptions(includeSystem: includeSystem == "true"))
                try result(try .from(inventory), warnings: ["Only launchd definitions were inspected. Login Items, background-task registrations and embedded helpers require System Settings. Configured/runtime state is a best-effort read and may change immediately after inspection."], json: args.json)
                return
            }
            if args.command == "startup control" {
                let actionValue=args.value("action").lowercased()
                guard let action=StartupControlAction(rawValue: actionValue) else { throw ShouError("invalid_argument", "Startup action must be enable or disable.") }
                let inventory=try NativeStartupInventory().read(options: StartupInventoryOptions(includeSystem: false))
                guard let definition=inventory.items.first(where: { $0.path == args.value("path") }) else {
                    throw ShouError("invalid_argument", "The startup definition is not a current-user LaunchAgent in the inspected sources.")
                }
                let phrase="STARTUP \(action.rawValue.uppercased()) \(definition.label)"
                let scope=StartupControlReviewScope(action: action.rawValue, label: definition.label, path: definition.path, source: definition.sourceId,
                    notes: [args.locale == "zh-CN" ? "仅修改当前用户 LaunchAgent 的 launchd 覆盖设置，不会终止已运行进程。执行前会重新核验 plist、所有者和标签。" : "Only the current user's LaunchAgent launchd override will change; running processes are not terminated. The plist, owner and label are rechecked before execution."])
                try Terminal.confirm(scope, phrase: phrase, locale: args.locale)
                let controlResult=try NativeStartupControl().apply(definition: definition, action: action)
                try result(try .from(controlResult), json: args.json)
                return
            }
            let directory=ProcessInfo.processInfo.environment["SHOU_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? LocalRecordStore.defaultDirectory
            let store=try LocalRecordStore(directory: directory)
            let fs=NativeFileSystem()
            let engine=ShouEngine(store: store, filesystem: fs, applicationActivity: NativeApplicationActivity(), artifactEvidence: NativeArtifactEvidence(), applicationCatalog: NativeApplicationCatalog(), uninstallEvidence: NativeApplicationUninstallEvidence())
            var value: JSONValue = .null
            var warnings: [String] = []
            var next: [JSONValue] = []
            func scanValue(_ snapshot: ScanSnapshot) throws -> JSONValue { try summary(snapshot) }
            func nextResults(_ scan: ScanSnapshot) -> [JSONValue] { [.object(["command": .string("scan results"), "arguments": .object(["scan_id": .string(scan.id)])])] }
            switch args.command {
            case "capabilities":
                value = .object(["application_version": .string(version), "api_version": .string("1.0"), "rule_schema_version": .string("1.0"), "platform": .string(fs.platform), "runtime_locales": .array([.string("en"), .string("zh-CN")]), "commands": try .from(commands), "trash_available": .bool(fs.supportsTrash), "confirmation": .string("interactive_current_scope"), "limits": .object(["rule_bytes": .integer(262144), "scan_entries": .integer(100000), "scan_seconds": .integer(60), "scan_entries_max": .integer(1000000), "scan_seconds_max": .integer(600), "scan_depth_max": .integer(128), "page_size": .integer(500)]), "limitations": .array([.string("Cleanup requires local filesystem access and an explicit review of the current selection."), .string("Only local user-owned workspaces without ancestor links are supported."), .string("No model integration, agent hosting, or unattended destructive execution.")])])
            case "locations list": value=try .from(await engine.knownLocations())
            case "applications inspect":
                guard let entries=Int(args.values["max-entries"]?.first ?? "100000"), let seconds=Double(args.values["max-seconds"]?.first ?? "60") else { throw ShouError("invalid_argument", "Scan budgets must be numeric.") }
                let review=try await engine.reviewApplication(path: args.value("path"), budget: ScanBudget(maxEntries: entries, maxSeconds: seconds))
                value=try .from(review); warnings=review.limitations
            case "applications plan":
                let consent=args.values["include-user-data"]?.first ?? "false"
                guard ["true", "false"].contains(consent) else { throw ShouError("invalid_argument", "Include-user-data must be true or false.") }
                value=try .from(await engine.createUninstallPlan(reviewId: args.value("review-id"), componentIds: args.all("component"), includeUserData: consent == "true"))
            case "applications plan show": value=try .from(await engine.uninstallPlan(args.value("plan-id")))
            case "applications uninstall":
                let plan=try await engine.uninstallPlan(args.value("plan-id"))
                try Terminal.confirm(TerminalReviewScope(uninstall: plan, locale: args.locale), phrase: "UNINSTALL " + plan.id, locale: args.locale)
                value=try .from(await engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "cli"))
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
            case "plan create": value=try .from(await engine.createPlan(scanId: args.value("scan-id"), candidateIds: args.all("candidate")))
            case "plan show": value=try .from(await engine.plan(args.value("plan-id")))
            case "plan execute":
                let plan=try await engine.plan(args.value("plan-id"))
                try Terminal.confirm(TerminalReviewScope(plan: plan, locale: args.locale), phrase: "TRASH " + plan.id, locale: args.locale)
                value=try .from(await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "cli"))
            case "history list": value=try .from(await engine.history())
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
