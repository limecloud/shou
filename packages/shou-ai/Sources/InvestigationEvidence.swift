import Foundation
import ShouCore

struct DirectoryInput: Codable, Sendable { let path: String; let offset: Int }
struct InspectInput: Codable, Sendable { let path: String }
struct QuestionInput: Codable, Sendable { let question: String; let choices: [String] }
struct AdviceInput: Codable, Sendable {
    let path: String
    let name: String
    let explanation: String
    let rebuildNote: String
    let limitations: [String]
    let minimumAgeDays: Int?
}

struct InvestigationCheckpoint: Codable, Sendable {
    var state: AIInvestigation
    var messages: Data
    var pendingCalls: [String]
    var observedDirectories: Set<String>
    var questionCount: Int
    var locale: String
    var retention: [String]?
    var routing: InvestigationRouting?
    var decisions: [String: AIDecisionReview]?
    var runtime: String?
}

/// Only published index metadata enters model evidence. No arbitrary file reads.
actor InvestigationEvidence {
    private let engine: ShouEngine
    private let store: any RecordStore
    private let progress: @Sendable (AIInvestigation) async -> Void
    private let credentials: any AICredentialStore
    private let permit: AIRequestPermit
    private let decisions: StructuredDecisionService
    private var checkpoint: InvestigationCheckpoint
    private var deadline=ContinuousClock.now.advanced(by: .seconds(180))

    init(engine: ShouEngine, store: any RecordStore, checkpoint: InvestigationCheckpoint, credentials: any AICredentialStore,
         permit: AIRequestPermit = .unrestricted, decisions: StructuredDecisionService = .init(), progress: @escaping @Sendable (AIInvestigation) async -> Void) {
        self.engine=engine; self.store=store; self.checkpoint=checkpoint; self.credentials=credentials; self.progress=progress
        self.permit=permit; self.decisions=decisions
    }
    func value() -> InvestigationCheckpoint { checkpoint }
    func replaceMessages(_ messages: Data) async throws { checkpoint.messages=messages; try await publish() }
    func publish() async throws {
        let data=try JSONEncoder().encode(checkpoint)
        guard data.count <= 1_048_576 else { throw AIEvidencePolicy.budgetExceeded(.evidence) }
        do {
            let lease=try store.lock(); defer { lease.release() }
            try store.write("ai-investigations", id: checkpoint.state.id, data: data)
        }
        await progress(checkpoint.state)
    }
    func beginStep() async throws {
        try checkBudget()
        guard checkpoint.state.issue == nil else { throw ShouError("ai_decision_failed", "Structured evidence review failed.") }
        guard checkpoint.state.steps < AIEvidencePolicy.maximumSteps else { throw AIEvidencePolicy.budgetExceeded(.steps) }
        checkpoint.state.activity="Analyzing evidence…"
        await progress(checkpoint.state)
    }
    func endStep(tokens: Int, messages: Data) async throws {
        checkpoint.state.steps += 1; checkpoint.state.tokens += max(0,tokens)
        usage("main", tokens: tokens)
        checkpoint.messages=messages
        try await publish()
    }
    func checkBudget() throws {
        try Task.checkCancellation()
        if try store.read("ai-cancellations", id: checkpoint.state.id) != nil { throw CancellationError() }
        try permit.check()
        guard ContinuousClock.now < deadline else { throw AIEvidencePolicy.budgetExceeded(.time) }
        guard checkpoint.state.tokens < AIEvidencePolicy.maximumTokens else { throw AIEvidencePolicy.budgetExceeded(.tokens) }
    }
    /// Credential resolution is setup, not model processing. Always recheck revocation afterwards.
    func credential(decision: Bool = false) throws -> String? {
        try checkBudget()
        let started=ContinuousClock.now
        defer { deadline=deadline.advanced(by: started.duration(to: .now)) }
        let key=try decision ? credentials.decisionKey(for: checkpoint.state.connection) : credentials.key(for: checkpoint.state.connection)
        try Task.checkCancellation(); try permit.check()
        return key
    }
    private func usage(_ service: String, requests: Int = 0, tokens: Int = 0) {
        var values=checkpoint.state.serviceUsage ?? []
        if let index=values.firstIndex(where: { $0.service == service }) {
            values[index].requests += requests; values[index].reportedTokens += max(0, tokens)
        } else { values.append(AIServiceUsage(service: service, requests: requests, reportedTokens: max(0, tokens))) }
        checkpoint.state.serviceUsage=values
    }
    func mainRequest() async throws {
        try checkBudget(); usage("main", requests: 1); try await publish()
    }
    func setRouting(_ routing: InvestigationRouting) async throws {
        try checkBudget(); checkpoint.routing=routing; try await publish()
    }
    func escalate(_ reason: String) async throws {
        try checkBudget()
        checkpoint.state.escalationReasons=(checkpoint.state.escalationReasons ?? []) + [reason]
        checkpoint.state.activity="Understanding unfamiliar conditions with the main model…"
        checkpoint.routing?.escalated=true
        try await publish()
    }
    func decide(path: String, state: ShouCore.JSONValue, criteria: [String: String]? = nil) async throws -> AIDecisionReview {
        try checkBudget()
        let fingerprint=try Codec.encode(ShouCore.JSONValue.object(["path": .string(path), "state": state,
            "criteria": criteria.map { .object($0.mapValues(ShouCore.JSONValue.string)) } ?? .null])).base64EncodedString()
        if let cached=checkpoint.decisions?[fingerprint] { return cached }
        let provider=checkpoint.state.connection.decision?.providerID ?? "decision"
        guard checkpoint.state.steps < AIEvidencePolicy.maximumSteps else { throw AIEvidencePolicy.budgetExceeded(.steps) }
        guard (checkpoint.state.serviceUsage?.first(where: { $0.service == provider })?.requests ?? 0) < 8 else { throw AIEvidencePolicy.budgetExceeded(.decisions) }
        checkpoint.state.activity="Reviewing evidence with the decision provider…"
        try await publish()
        let key=try credential(decision: true)
        try checkBudget(); checkpoint.state.steps += 1; usage(provider, requests: 1); try await publish()
        let review: AIDecisionReview
        do {
            review=try await decisions.decide(.init(path: path, evidence: state, criteria: criteria), connection: checkpoint.state.connection, key: key, permit: permit)
        } catch {
            checkpoint.state.issue="Structured evidence review failed. Check the decision connection before investigating again."
            try? await publish(); throw error
        }
        checkpoint.decisions=checkpoint.decisions ?? [:]; checkpoint.decisions?[fingerprint]=review
        checkpoint.state.decisionReviews=(checkpoint.state.decisionReviews ?? []) + [review]
        checkpoint.state.tokens += review.tokens; usage(provider, tokens: review.tokens)
        try await publish(); try checkBudget(); return review
    }
    private func tool(_ activity: String) async throws {
        try checkBudget()
        guard checkpoint.state.toolCalls < AIEvidencePolicy.maximumToolCalls else { throw AIEvidencePolicy.budgetExceeded(.tools) }
        checkpoint.state.toolCalls += 1; checkpoint.state.activity=activity
        await progress(checkpoint.state)
    }
    private func record(_ item: StorageCatalogItem) throws -> ShouCore.JSONValue {
        let path=AIEvidencePolicy.relative(item.node.path, scope: checkpoint.state.scope)
        try AIEvidencePolicy.validate(path)
        guard ["file", "directory"].contains(item.entry.kind) else { throw ShouError("ai_scope_denied", "Links and special files are excluded from AI evidence.") }
        let result: ShouCore.JSONValue = .object([
            "path": .string(path), "kind": .string(item.node.kind), "allocated_bytes": .integer(item.node.allocatedBytes),
            "file_count": .integer(Int64(item.node.fileCount)), "complete": .bool(item.node.isComplete != false),
            "newest_modified": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(item.node.newestModifiedNanoseconds) / 1_000_000_000)))
        ])
        let size=try Codec.encode(result).count
        guard checkpoint.state.evidenceRows < AIEvidencePolicy.maximumRows,
              checkpoint.state.evidenceBytes + size <= AIEvidencePolicy.maximumBytes else {
            throw AIEvidencePolicy.budgetExceeded(.evidence)
        }
        checkpoint.state.evidenceRows += 1; checkpoint.state.evidenceBytes += size
        if !checkpoint.state.evidence.contains(where: { $0.path == item.node.path }) {
            checkpoint.state.evidence.append(AIObservedEvidence(path: item.node.path, allocatedBytes: item.node.allocatedBytes, complete: item.node.isComplete != false))
        }
        if item.entry.kind == "directory" { checkpoint.observedDirectories.insert(item.node.path) }
        return result
    }
    func directory(_ input: DirectoryInput) async throws -> ShouCore.JSONValue {
        try await tool("Reading directory evidence…")
        let path=try AIEvidencePolicy.resolve(input.path, scope: checkpoint.state.scope)
        guard (0...100_000).contains(input.offset) else { throw ShouError("invalid_argument", "Invalid directory offset.") }
        let page=try await engine.storageDirectoryPage(scanId: checkpoint.state.scanId, path: path, offset: input.offset, limit: 30)
        let parent=try record(page.item)
        var children: [ShouCore.JSONValue]=[], omitted=0
        for child in page.children {
            do { children.append(try record(child)) }
            catch let error as ShouError where error.code == "ai_scope_denied" { omitted += 1 }
        }
        return .object(["directory": parent, "children": .array(children), "next_offset": page.nextOffset.map { .integer(Int64($0)) } ?? .null,
                        "omitted_private_or_special_items": .integer(Int64(omitted)), "snapshot_only": .bool(true)])
    }
    func inspect(_ input: InspectInput) async throws -> ShouCore.JSONValue {
        try await tool("Inspecting directory evidence…")
        let path=try AIEvidencePolicy.resolve(input.path, scope: checkpoint.state.scope)
        let item=try await engine.storageDirectory(scanId: checkpoint.state.scanId, path: path).item
        return try record(item)
    }
    func propose(_ input: AdviceInput) async throws -> ShouCore.JSONValue {
        guard checkpoint.state.issue == nil else { throw ShouError("ai_decision_failed", "Structured evidence review failed.") }
        try await tool("Checking a rule suggestion…")
        let path=try AIEvidencePolicy.resolve(input.path, scope: checkpoint.state.scope)
        guard path != ".", !path.contains("*"), !path.contains("?"), checkpoint.observedDirectories.contains(path), checkpoint.state.advice.count < 8,
              !checkpoint.state.advice.contains(where: { $0.path == path }),
              (1...100).contains(input.name.count), (1...2000).contains(input.explanation.count),
              (1...2000).contains(input.rebuildNote.count), input.limitations.count <= 8,
              input.limitations.allSatisfy({ $0.count <= 500 }), input.minimumAgeDays.map({ (1...3650).contains($0) }) ?? true else {
            throw ShouError("invalid_ai_advice", "Suggest one previously inspected directory with a rebuild explanation and bounded retention conditions.")
        }
        let limitations=input.limitations + ["AI-generated suggestion. Rebuild conditions and personal value must be verified before cleanup.", "Based on a saved size index; current files are rechecked by rule preview and cleanup."]
        if checkpoint.state.connection.decision != nil && checkpoint.state.connection.strategy == .decisionFirst {
            let item=checkpoint.state.evidence.first { $0.path == path }
            let review=try await decide(path: input.path, state: .object([
                    "path": .string(input.path), "allocated_bytes": .integer(item?.allocatedBytes ?? 0),
                    "snapshot_complete": .bool(item?.complete ?? false),
                    "proposal": .string(input.explanation), "rebuild_requirements": .string(input.rebuildNote),
                    "limitations": .array(input.limitations.map(JSONValue.string)),
                    "user_retention_statements": .array((checkpoint.retention ?? []).map(JSONValue.string)),
                    "evidence_limitations": .string("Saved directory metadata only. Proposed descriptions are model hypotheses, not independently verified file contents.")
                ]))
            if review.verdict != "supported" {
                return .object(["state": .string("not_proposed"), "decision": .string(review.verdict),
                                "next_step": .string("Gather missing rebuild evidence or ask a retention question. Retained content must not be proposed."), "enabled": .bool(false)])
            }
        }
        let draft=PersonalRuleDraft(name: input.name, relativePatterns: [path], maxDepth: min(64, max(8, path.split(separator: "/").count + 1)),
                                    minimumAgeDays: input.minimumAgeDays, rebuildNote: input.rebuildNote, limitations: limitations, highRisk: true)
        let id="personal.ai." + UUID().uuidString.lowercased()
        #if os(Windows)
        let platform="windows"
        #else
        let platform="macos"
        #endif
        var rule=try draft.rule(id: id, rootRef: "ai-investigation", platform: platform)
        rule.description=input.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        checkpoint.state.advice.append(AIAdvice(id: id, path: path, explanation: input.explanation, rule: rule))
        try await publish()
        return .object(["suggestion_id": .string(id), "state": .string("proposed_only"), "enabled": .bool(false)])
    }
    func finish(summary: String, questions: [AIQuestion], pending: [String], messages: Data, limited: Bool) async throws -> AIInvestigation {
        guard checkpoint.state.issue == nil else { throw ShouError("ai_decision_failed", "Structured evidence review failed.") }
        guard checkpoint.state.toolCalls + questions.count <= AIEvidencePolicy.maximumToolCalls else {
            throw AIEvidencePolicy.budgetExceeded(.tools)
        }
        checkpoint.messages=messages; checkpoint.pendingCalls=pending
        checkpoint.questionCount += questions.count
        checkpoint.state.toolCalls += questions.count
        checkpoint.state.questions=questions; checkpoint.state.summary=String(summary.prefix(12_000))
        checkpoint.state.status = limited ? .limited : questions.isEmpty ? .complete : .waiting
        if limited {
            checkpoint.state.limitReason = checkpoint.state.tokens >= AIEvidencePolicy.maximumTokens ? .tokens : checkpoint.state.steps >= AIEvidencePolicy.maximumSteps ? .steps : .directories
            checkpoint.state.issue=checkpoint.state.limitReason?.message
        }
        checkpoint.state.activity = limited ? "Investigation limit reached" : questions.isEmpty ? "Investigation finished" : "Waiting for your answer"
        try await publish(); return checkpoint.state
    }
    func fail(_ error: any Error) async -> AIInvestigation {
        let cancelled=Task.isCancelled || error is CancellationError || (error as? ShouError)?.code == "ai_disabled"
        let limited=(error as? ShouError)?.code == "ai_budget_exceeded"
        checkpoint.state.status = cancelled ? .cancelled : limited ? .limited : .failed
        let reason=(error as? ShouError)?.details["budget"].flatMap(AIInvestigationLimit.init(rawValue:))
        checkpoint.state.limitReason=limited ? reason : nil
        // Provider error bodies can echo credentials or evidence; never persist them.
        checkpoint.state.issue = cancelled ? "Investigation cancelled." : limited ? reason?.message ?? "The investigation reached its budget. Review the available suggestions or start a smaller investigation." : checkpoint.state.issue ?? "The model request failed. Check the connection and tool-calling support, then try again."
        if !cancelled, ["ai_credential_missing", "ai_credential_unavailable"].contains((error as? ShouError)?.code ?? "") {
            checkpoint.state.issue="An API key is unavailable. Open AI settings and save the key using local storage, then start a new investigation. No system password is required."
        }
        checkpoint.state.activity=cancelled ? "Investigation cancelled." : limited ? "Investigation limit reached" : "Investigation failed"
        try? await publish()
        return checkpoint.state
    }
}
