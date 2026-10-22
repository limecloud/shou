import Foundation
import ShouAI
import ShouCore
import ShouPlatform

enum AICLI {
    static let commands: [CommandSpec] = [
        .init("ai providers", "read", [], [], "Discover installed structured decision providers and default profiles. No network request."),
        .init("ai list", "read", [], [], "List the latest 100 saved investigations with status, questions and suggestions. No network request."),
        .init("ai cancel", "configuration", ["investigation-id"], [], "Cancel a waiting or running investigation across processes. Pending network work stops cooperatively; saved evidence remains available."),
        .init("ai connections list", "read", [], ["state"], "List AI configurations without keys. state is active (default), deleted or all. No network request."),
        .init("ai connections show", "read", ["connection-id"], [], "Read one AI configuration, including a recoverably deleted profile, without keys. No network request."),
        .init("ai connections delete", "configuration", ["connection-id"], [], "Recoverably remove one configuration from active choices. Saved investigations and their credential references are retained. Use restore to undo."),
        .init("ai connections restore", "configuration", ["connection-id"], [], "Restore one recoverably deleted AI configuration. No network request."),
        .init("ai connections save", "configuration", ["file"], [], "Save one AIConnection JSON profile (at most 16 KiB), containing only a credential reference or an explicit environment-variable name. Authentication is local, keychain, environment or none. Never accepts API keys."),
        .init("ai connections test", "network", ["connection-id"], [], "Send synthetic data to the selected service and verify a complete tool-calling round trip; never reads a scan."),
        .init("ai connections credential save", "configuration", ["connection-id"], ["service"], "Save an API key from standard input to the profile's local or system credential store. macOS defaults to private local files; Windows defaults to Credential Manager (keychain). service is model (default) or decision; jev is a Jev-only legacy alias. Never pass keys as arguments or in profile files."),
        .init("ai connections decision test", "network", ["connection-id"], [], "Verify the selected structured decision provider with synthetic evidence only."),
        .init("ai investigate", "network", ["scan-id", "connection-id"], ["path", "request", "goal"], "Investigate a saved space-analysis directory with bounded relative metadata. Sends evidence to the selected service and saves a local checkpoint. No file content, Shell or deletion tools."),
        .init("ai show", "read", ["investigation-id"], [], "Read a local investigation, pending questions and independent rule suggestions. No model request."),
        .init("ai resume", "network", ["investigation-id", "file"], [], "Resume a waiting investigation using a JSON object mapping current question IDs to answers (at most 16 KiB). Uses the same saved connection and scope."),
        .init("ai advice import", "configuration", ["investigation-id", "advice-id"], [], "Import exactly one suggestion as a disabled personal rule. Preview, enabling, rescan and cleanup confirmation remain separate operations.")
    ]
    static func run(_ args: Arguments, engine: ShouEngine, store: any RecordStore) async throws -> Bool {
        guard args.command.hasPrefix("ai ") else { return false }
        let connections=AIConnectionStore(store: store)
        let credentials=SystemAICredentials(directory: (store as? LocalRecordStore)?.directory ?? LocalRecordStore.defaultDirectory)
        let service=AIInvestigationService(engine: engine, store: store, credentials: credentials)
        func connection() throws -> AIConnection {
            guard let value=try connections.connections().first(where: { $0.id == args.value("connection-id") }) else {
                throw ShouError("not_found", "AI connection not found.")
            }
            return value
        }
        let value: JSONValue
        switch args.command {
        case "ai providers": value=decisionProviders()
        case "ai list": value=try .from(await service.list())
        case "ai cancel":
            try await service.cancel(args.value("investigation-id")); value=try .from(await service.read(args.value("investigation-id")))
        case "ai connections list":
            let state=args.value("state")
            guard ["", "active", "deleted", "all"].contains(state) else { throw ShouError("invalid_argument", "Choose active, deleted or all as the configuration state.") }
            value=try .from(state == "all" ? connections.connections() + connections.connections(deleted: true) : connections.connections(deleted: state == "deleted"))
        case "ai connections show": value=try .from(connections.connection(args.value("connection-id"), includingDeleted: true))
        case "ai connections delete", "ai connections restore":
            let deleted=args.command == "ai connections delete"
            try connections.setDeleted(deleted, id: args.value("connection-id"))
            value = .object(["status": .string(deleted ? "deleted" : "restored"), "recoverable": .bool(true), "connection_id": .string(args.value("connection-id"))])
        case "ai connections save":
            let data=try boundedFile(args.value("file"))
            let profile=try AIConnectionStore.profile(Codec.decode(JSONValue.self, from: data))
            try connections.save(profile); value=try .from(profile)
        case "ai connections test":
            try await AIConnectionTest.run(connection: connection(), credentials: credentials)
            value = .object(["status": .string("verified"), "tool_round_trip": .bool(true)])
        case "ai connections credential save":
            let profile=try connection(), selected=args.value("service")
            let isDecision=["decision", "jev"].contains(selected)
            guard ["", "model", "decision", "jev"].contains(selected), !isDecision || profile.decision != nil,
                  selected != "jev" || profile.decision?.providerID == "jev",
                  (isDecision ? profile.decision?.authentication : profile.authentication)?.storesKey == true else {
                throw ShouError("invalid_argument", "Choose a configured local or system credential service: model or decision.")
            }
            let data=try FileHandle.standardInput.read(upToCount: 8193) ?? Data()
            guard data.count <= 8192, let key=String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw ShouError("invalid_ai_key", "Provide one API key of at most 8 KiB on standard input.")
            }
            try credentials.save(key, for: profile, decision: isDecision)
            let authentication=isDecision ? profile.decision!.authentication : profile.authentication
            value = .object(["status": .string(authentication == .local ? "saved_locally" : "saved_in_keychain"), "service": .string(isDecision ? selected : "model"), "authentication": .string(authentication.rawValue)])
        case "ai connections decision test":
            let review=try await StructuredDecisionService().test(connection: connection(), credentials: credentials)
            value=try .from(review)
        case "ai investigate":
            guard let goal=AIInvestigationGoal(rawValue: args.value("goal").isEmpty ? "investigate" : args.value("goal")) else { throw ShouError("invalid_argument", "Choose investigate, space or rules as the AI goal.") }
            let state=try await service.start(scanId: args.value("scan-id"), scope: args.value("path").isEmpty ? "." : args.value("path"),
                                             connection: connection(), request: args.value("request"), locale: args.locale, goal: goal)
            value=try .from(state)
        case "ai show": value=try .from(await service.read(args.value("investigation-id")))
        case "ai resume":
            let answers=try Codec.decode([String: String].self, from: boundedFile(args.value("file")))
            value=try .from(await service.resume(args.value("investigation-id"), answers: answers))
        case "ai advice import":
            value=try .from(await service.importAdvice(investigationId: args.value("investigation-id"), adviceId: args.value("advice-id")))
        default: return false
        }
        if args.command != "ai cancel", ["failed", "cancelled", "limited"].contains(value["status"]?.string ?? "") {
            var envelope=try ResultEnvelope(data: value)
            envelope.ok=false; envelope.status="partial"
            try ShouCLI.output(envelope, json: args.json)
            Foundation.exit(6)
        }
        try ShouCLI.result(value, json: args.json)
        return true
    }
    static func decisionProviders() -> JSONValue {
        .array(StructuredDecisionService().availableProviders.map { .object(["id": .string($0.id), "name": .string($0.name), "default_connection": (try? .from($0.connection)) ?? .null]) })
    }
    private static func boundedFile(_ path: String) throws -> Data {
        let handle=try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        let data=try handle.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384 else { throw ShouError("invalid_argument", "AI configuration and answer files must be at most 16 KiB.") }
        return data
    }
}
