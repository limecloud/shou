import Foundation
#if canImport(SwiftAISDK)
import SwiftAISDK
import AISDKProvider
import AISDKProviderUtils
import OpenAIProvider
import AnthropicProvider
import ShouCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Provider and tool-loop types stay inside this module.
enum SDKRuntime {
    static func model(_ connection: AIConnection, key: String?, permit: AIRequestPermit = .unrestricted,
                      onRequest: @escaping @Sendable () async throws -> Void = {}) throws -> any LanguageModelV4 {
        let connection=try connection.validated()
        try permit.check()
        guard connection.usesMainModel else { throw ShouError("ai_model_unconfigured", "Add a main model connection to handle open-ended understanding.") }
        guard connection.authentication == .none || key?.isEmpty == false else {
            throw ShouError("ai_credential_missing", "The selected AI connection needs an API key.")
        }
        let fetch=defaultFetchFunction()
        let boundedFetch: FetchFunction = { request in
            try permit.check()
            var request=request
            // Keep the selected destination and never forward evidence through redirects.
            request.fetchRedirectMode = .error
            request.timeoutInterval=60
            if connection.authentication == .none {
                request.setValue(nil, forHTTPHeaderField: "Authorization")
                request.setValue(nil, forHTTPHeaderField: "x-api-key")
            }
            try await onRequest()
            try permit.check()
            let response=try await fetch(request)
            var data=Data()
            for try await chunk in response.body.makeStream() {
                try Task.checkCancellation()
                guard data.count + chunk.count <= 1_048_576 else {
                    throw AIEvidencePolicy.budgetExceeded(.response)
                }
                data.append(chunk)
            }
            return FetchResponse(body: .data(data), urlResponse: response.urlResponse)
        }
        switch connection.apiProtocol {
        case .responses:
            return try createOpenAI(settings: .init(baseURL: connection.baseURL, apiKey: key ?? "shou-no-auth", fetch: boundedFetch)).responses(connection.model)
        case .chatCompletions:
            return try createOpenAI(settings: .init(baseURL: connection.baseURL, apiKey: key ?? "shou-no-auth", fetch: boundedFetch)).chat(connection.model)
        case .anthropic:
            return createAnthropic(settings: .init(baseURL: connection.baseURL, apiKey: key ?? "shou-no-auth", fetch: boundedFetch)).messages(connection.model)
        }
    }

    static func tools(_ evidence: InvestigationEvidence, allowQuestions: Bool) -> ToolSet {
        let list: TypedTool<DirectoryInput, ShouCore.JSONValue> = tool(
            description: "Read up to 30 child metadata rows from the saved size index. Paths are relative to the selected folder; start with path '.' and offset 0. No file content. Follow next_offset only if needed.",
            execute: { input, _ in .value(try await evidence.directory(input)) })
        let inspect: TypedTool<InspectInput, ShouCore.JSONValue> = tool(
            description: "Inspect one directory from the saved size index. Names and sizes do not establish disposability or rebuildability.",
            execute: { input, _ in .value(try await evidence.inspect(input)) })
        let propose: TypedTool<AdviceInput, ShouCore.JSONValue> = tool(
            description: "Propose one exact previously observed directory as a disabled high-risk rule draft. Explain rebuild requirements, personal-data risks and uncertainty. Use minimumAgeDays or null. Does not import, enable or delete anything.",
            execute: { input, _ in .value(try await evidence.propose(input)) })
        var result: ToolSet=["list_directory": list.tool, "inspect_directory": inspect.tool, "propose_rule": propose.tool]
        if allowQuestions {
            let ask: TypedTool<QuestionInput, String> = tool(description: "Pause to ask a necessary retention or rebuild question. Provide 0–4 short choices. Ask one question at a time and wait; never invent an answer.")
            result["ask_user"]=ask.tool
        }
        return result
    }

    static func messages(_ responses: [ResponseMessage]) -> [ModelMessage] {
        responses.map {
            switch $0 { case .assistant(let message): .assistant(message); case .tool(let message): .tool(message) }
        }
    }
    static let instructions=AIModelInstructions.value
}

private struct ProbeInput: Codable, Sendable { let token: String }
private actor ProbeResult {
    var verified=false
    func verify(_ value: String, expected: String) throws -> String {
        guard value == expected else { throw ShouError("ai_probe_failed", "The model did not complete the tool check.") }
        verified=true; return "verified"
    }
}

public enum AIConnectionTest {
    /// Synthetic data only. Proves a tool execution followed by another model turn.
    public static func run(connection: AIConnection, credentials: any AICredentialStore, permit: AIRequestPermit = .unrestricted) async throws {
        let connection=try connection.validated()
        if PortableModelRuntime.preferred { try await PortableModelRuntime.test(connection: connection, credentials: credentials, permit: permit); return }
        try permit.check()
        let key=try credentials.key(for: connection)
        let model=try SDKRuntime.model(connection, key: key, permit: permit)
        let token=UUID().uuidString, probe=ProbeResult()
        let verify: TypedTool<ProbeInput, String> = tool(description: "Verify the connection token.", execute: { input, _ in
            .value(try await probe.verify(input.token, expected: token))
        })
        let agent=BasicAgent(.init(model: model, tools: ["verify_connection": verify.tool], stopWhen: [isStepCount(3)], toolCallConcurrency: 1,
                                   callSettings: .init(maxOutputTokens: 256, maxRetries: 0, timeout: .milliseconds(30_000))))
        do {
            let result=try await agent.generate(prompt: "Call verify_connection exactly once with token '\(token)'. After receiving its result, reply 'Ready'. Do not call another tool.", abortSignal: { Task.isCancelled })
            guard await probe.verified, result.steps.count >= 2, !result.text.isEmpty else {
                throw ShouError("ai_probe_failed", "The model did not complete the tool check.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ShouError("ai_probe_failed", "Connection test failed. Check the protocol, API base URL, model, API key and tool-calling support.") }
    }
}
#endif
