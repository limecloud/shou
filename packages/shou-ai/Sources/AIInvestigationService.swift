import Foundation
import ShouCore
#if canImport(SwiftAISDK)
import SwiftAISDK
import AISDKProviderUtils
#endif

/// Shared task service for the desktop and CLI. SDK messages remain private checkpoints.
public actor AIInvestigationService {
    public static let isAvailable=true
    private let engine: ShouEngine
    private let store: any RecordStore
    private let credentials: any AICredentialStore
    private let permit: AIRequestPermit
    private let decisions: StructuredDecisionService
    public init(engine: ShouEngine, store: any RecordStore, credentials: any AICredentialStore, permit: AIRequestPermit = .unrestricted,
                decisions: StructuredDecisionService = .init()) {
        self.engine=engine; self.store=store; self.credentials=credentials
        self.permit=permit; self.decisions=decisions
    }
    public func read(_ id: String) throws -> AIInvestigation { try load(id).state }
    public func list() throws -> [AIInvestigation] {
        var values: [AIInvestigation]=[], bytes=0
        for record in try store.records("ai-investigations").sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(100) {
            let state=try load(record.id).state, size=try Codec.encode(state).count
            guard bytes + size <= 2_097_152 else { break }
            values.append(state); bytes += size
        }
        return values.sorted { $0.createdAt > $1.createdAt }
    }
    public func cancel(_ id: String) throws {
        let lease=try store.lock(); defer { lease.release() }
        var checkpoint=try load(id)
        guard [.waiting, .running].contains(checkpoint.state.status) else { return }
        try store.write("ai-cancellations", id: id, data: Data("cancel".utf8))
        guard checkpoint.state.status == .waiting else { return }
        checkpoint.state.status = .cancelled; checkpoint.state.issue="Investigation cancelled."
        try store.write("ai-investigations", id: id, data: JSONEncoder().encode(checkpoint))
    }

    public func start(scanId: String, scope: String = ".", connection: AIConnection, request: String = "", locale: String = "en",
                      goal: AIInvestigationGoal = .investigate,
                      progress: @escaping @Sendable (AIInvestigation) async -> Void = { _ in }) async throws -> AIInvestigation {
        try permit.check()
        let connection=try connection.validated()
        try AIEvidencePolicy.validate(scope)
        guard request.count <= 2000 else { throw ShouError("invalid_argument", "Keep investigation instructions within 2000 characters.") }
        let scan=try await engine.storageScan(scanId)
        // Also block a private selected root; the model never sees its absolute name.
        try AIEvidencePolicy.validate(StorageRemovalPolicy.canonical(scan.rootPath).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        _ = try await engine.storageDirectoryPage(scanId: scanId, path: scope, limit: 1)
        var state=AIInvestigation(scanId: scanId, scope: scope, connection: connection)
        state.goal=goal; state.serviceUsage=[AIServiceUsage(service: "main")]
        if let decision=connection.decision { state.serviceUsage?.append(AIServiceUsage(service: decision.providerID)) }
        let prompt="Investigate the selected folder (relative root '.'). Reply in \(locale == "zh-CN" ? "Simplified Chinese" : "English"). Saved snapshot status: \(scan.status). User retention/request: \(request.isEmpty ? "No additional conditions; ask if needed." : request)"
        let messages: Data
        #if canImport(SwiftAISDK)
        messages=try PortableModelRuntime.preferred ? PortableModelRuntime.initial(prompt) : JSONEncoder().encode([ModelMessage.user(.init(content: .text(prompt)))])
        #else
        messages=try PortableModelRuntime.initial(prompt)
        #endif
        let checkpoint=InvestigationCheckpoint(state: state, messages: messages,
                                               pendingCalls: [], observedDirectories: [], questionCount: 0, locale: locale, retention: request.isEmpty ? [] : [request],
                                               routing: goal == .space || connection.strategy == .decisionFirst ? InvestigationRouting() : nil, runtime: PortableModelRuntime.preferred ? "portable" : nil)
        return await run(checkpoint, progress: progress)
    }

    public func resume(_ id: String, answers: [String: String],
                       progress: @escaping @Sendable (AIInvestigation) async -> Void = { _ in }) async throws -> AIInvestigation {
        var checkpoint: InvestigationCheckpoint
        try permit.check()
        do {
            let lease=try store.lock(); defer { lease.release() }
            checkpoint=try load(id)
            guard checkpoint.state.status == .waiting, Date().timeIntervalSince(checkpoint.state.createdAt) < 86400,
                  Set(answers.keys) == Set(checkpoint.state.questions.map(\.id)),
                  answers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 2000 }) else {
                throw ShouError("invalid_ai_answer", "Answer the current investigation question before continuing. Investigations expire after 24 hours.")
            }
            if checkpoint.routing == nil || checkpoint.routing?.escalated == true {
                if checkpoint.runtime == "portable" { checkpoint.messages=try PortableModelRuntime.answer(checkpoint.messages, values: answers) }
                else {
                    #if canImport(SwiftAISDK)
                    var messages=try JSONDecoder().decode([ModelMessage].self, from: checkpoint.messages)
                    let parts=checkpoint.pendingCalls.map { id in
                        ToolContentPart.toolResult(.init(toolCallId: id, toolName: "ask_user", output: .text(value: answers[id] ?? "")))
                    }
                    messages.append(.tool(.init(content: parts)))
                    checkpoint.messages=try JSONEncoder().encode(messages)
                    #else
                    throw ShouError("ai_runtime_unavailable", "This investigation uses a different platform runtime. Start a new investigation.")
                    #endif
                }
            } else {
                checkpoint.routing?.answer=answers.values.first
                if let answer=answers.values.first, ["Retain this folder; do not create a cleanup rule", "保留此目录，不生成清理规则"].contains(answer) { checkpoint.routing?.category="personal" }
            }
            checkpoint.retention=(checkpoint.retention ?? []) + checkpoint.state.questions.compactMap { question in
                answers[question.id].map { question.text + " Answer: " + $0 }
            }
            checkpoint.state.status = .running; checkpoint.state.questions=[]; checkpoint.pendingCalls=[]
            try store.write("ai-investigations", id: id, data: JSONEncoder().encode(checkpoint))
        }
        return await run(checkpoint, progress: progress)
    }

    public func importAdvice(investigationId: String, adviceId: String) async throws -> RuleRecord {
        let state=try read(investigationId)
        guard state.status != .running, let advice=state.advice.first(where: { $0.id == adviceId }) else {
            throw ShouError("invalid_ai_advice", "Choose a suggestion from a stopped or finished investigation.")
        }
        return try await engine.importInvestigationAdvice(advice, scanId: state.scanId)
    }

    private func load(_ id: String) throws -> InvestigationCheckpoint {
        guard let data=try store.read("ai-investigations", id: id), data.count <= 1_048_576 else {
            throw ShouError("not_found", "Investigation not found.")
        }
        return try JSONDecoder().decode(InvestigationCheckpoint.self, from: data)
    }
    private func run(_ checkpoint: InvestigationCheckpoint,
                     progress: @escaping @Sendable (AIInvestigation) async -> Void) async -> AIInvestigation {
        let worker=Task { await self.execute(checkpoint, progress: progress) }
        let store=self.store, id=checkpoint.state.id
        let monitor=Task {
            while !Task.isCancelled {
                do {
                    if try store.read("ai-cancellations", id: id) != nil { worker.cancel(); return }
                    try await Task.sleep(for: .milliseconds(200))
                } catch { if !Task.isCancelled { worker.cancel() }; return }
            }
        }
        defer { monitor.cancel() }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
    private func execute(_ checkpoint: InvestigationCheckpoint,
                     progress: @escaping @Sendable (AIInvestigation) async -> Void) async -> AIInvestigation {
        let evidence=InvestigationEvidence(engine: engine, store: store, checkpoint: checkpoint, credentials: credentials, permit: permit, decisions: decisions, progress: progress)
        do {
            try Task.checkCancellation()
            try await evidence.publish()
            if checkpoint.routing != nil && checkpoint.routing?.escalated != true,
               try await InvestigationRouter.run(evidence) { return await evidence.value().state }
            var current=await evidence.value()
            try permit.check()
            if checkpoint.routing?.escalated != true && current.routing?.escalated == true {
                let context=try Codec.encode(JSONValue.object([
                    "observed_metadata": try .from(current.state.evidence.map { item in
                        AIObservedEvidence(path: AIEvidencePolicy.relative(item.path, scope: current.state.scope), allocatedBytes: item.allocatedBytes, complete: item.complete)
                    }), "retention": .array((current.retention ?? []).map(JSONValue.string)),
                    "reason": .array((current.state.escalationReasons ?? []).map(JSONValue.string))]))
                let text=String(decoding: context, as: UTF8.self)
                if current.runtime == "portable" { current.messages=try PortableModelRuntime.append(current.messages, text: text) }
                else {
                    #if canImport(SwiftAISDK)
                    var initial=try JSONDecoder().decode([ModelMessage].self, from: current.messages)
                    initial.append(.user(.init(content: .text(text))))
                    current.messages=try JSONEncoder().encode(initial)
                    #endif
                }
                try await evidence.replaceMessages(current.messages)
            }
            if current.runtime == "portable" { return try await PortableModelRuntime.run(evidence, credentials: credentials, permit: permit) }
            #if canImport(SwiftAISDK)
            let key=try credentials.key(for: current.state.connection)
            try permit.check()
            let model=try SDKRuntime.model(current.state.connection, key: key, permit: permit, onRequest: { try await evidence.mainRequest() })
            let initial=try JSONDecoder().decode([ModelMessage].self, from: current.messages)
            let remaining=max(1, AIEvidencePolicy.maximumSteps - current.state.steps)
            let initialTokens=current.state.tokens
            let agent=BasicAgent(.init(instructions: .text(SDKRuntime.instructions), model: model,
                tools: SDKRuntime.tools(evidence, allowQuestions: checkpoint.questionCount < 3),
                stopWhen: [isStepCount(remaining), { steps in steps.reduce(0) { $0 + ($1.usage.totalTokens ?? 0) } + initialTokens >= AIEvidencePolicy.maximumTokens }],
                toolCallConcurrency: 1,
                prepareStep: { _ in try await evidence.beginStep(); return nil },
                onStepEnd: { step in
                    // Preserve a complete step for pause/resume without a second tool loop.
                    var current=try JSONDecoder().decode([ModelMessage].self, from: await evidence.value().messages)
                    current += SDKRuntime.messages(step.response.messages)
                    try await evidence.endStep(tokens: step.usage.totalTokens ?? 0, messages: JSONEncoder().encode(current))
                },
                callSettings: .init(maxOutputTokens: 3072, maxRetries: 0, timeout: .milliseconds(180_000))))
            let result=try await agent.generate(messages: initial, abortSignal: { Task.isCancelled })
            try Task.checkCancellation()
            var questions: [AIQuestion]=[]
            let unanswered=result.toolCalls.filter { $0.toolName == "ask_user" }
            for call in unanswered {
                let input=try JSONDecoder().decode(QuestionInput.self, from: JSONEncoder().encode(call.input))
                guard (1...1000).contains(input.question.count), input.choices.count <= 4, input.choices.allSatisfy({ (1...200).contains($0.count) }),
                      questions.count < 3, checkpoint.questionCount + questions.count < 3 else {
                    throw ShouError("invalid_ai_question", "The model returned an invalid retention question.")
                }
                questions.append(AIQuestion(id: call.toolCallId, text: input.question, choices: input.choices))
            }
            let state=await evidence.value().state
            let limited=state.steps >= AIEvidencePolicy.maximumSteps || state.tokens >= AIEvidencePolicy.maximumTokens
            return try await evidence.finish(summary: result.text, questions: questions, pending: questions.map(\.id),
                                             messages: JSONEncoder().encode(initial + SDKRuntime.messages(result.responseMessages)), limited: limited)
            #else
            throw ShouError("ai_runtime_unavailable", "This investigation uses a different platform runtime. Start a new investigation.")
            #endif
        } catch { return await evidence.fail(error) }
    }
}
