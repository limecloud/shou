import Foundation
import ShouCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Windows uses the same bounded tools and checkpoints without the Apple-only SDK APIs.
enum PortableModelRuntime {
    static var preferred: Bool {
        #if canImport(SwiftAISDK)
        ProcessInfo.processInfo.environment["SHOU_AI_RUNTIME"] == "portable"
        #else
        true
        #endif
    }
    struct Call: Codable, Sendable { let id: String; let name: String; let input: JSONValue }
    struct Message: Codable, Sendable {
        let role: String
        var text: String = ""
        var calls: [Call] = []
        var results: [String: JSONValue] = [:]
        var responseItems: [JSONValue]? = nil
    }
    struct Reply { let message: Message; let tokens: Int }
    static func initial(_ text: String) throws -> Data { try JSONEncoder().encode([Message(role: "user", text: text)]) }
    static func answer(_ data: Data, values: [String: String]) throws -> Data {
        var messages=try JSONDecoder().decode([Message].self, from: data)
        messages.append(Message(role: "tool", results: values.mapValues(JSONValue.string)))
        return try JSONEncoder().encode(messages)
    }
    static func append(_ data: Data, text: String) throws -> Data {
        var messages=try JSONDecoder().decode([Message].self, from: data)
        messages.append(Message(role: "user", text: text)); return try JSONEncoder().encode(messages)
    }
    static func run(_ evidence: InvestigationEvidence, credentials: any AICredentialStore, permit: AIRequestPermit) async throws -> AIInvestigation {
        let checkpoint=await evidence.value(), connection=checkpoint.state.connection
        try permit.check(); let key=try credentials.key(for: connection); try permit.check()
        var messages=try JSONDecoder().decode([Message].self, from: checkpoint.messages)
        var seenCalls=Set(messages.flatMap { $0.calls.map(\.id) })
        while true {
            try await evidence.beginStep()
            try await evidence.mainRequest()
            let reply=try await request(connection, key: key, messages: messages, tools: tools(questions: checkpoint.questionCount < 3), permit: permit)
            try await evidence.checkBudget()
            guard reply.message.calls.allSatisfy({ seenCalls.insert($0.id).inserted }) else {
                throw ShouError("ai_response_invalid", "The model returned an invalid tool call.")
            }
            messages.append(reply.message)
            try await evidence.endStep(tokens: reply.tokens, messages: JSONEncoder().encode(messages))
            let consumed=await evidence.value().state
            if consumed.tokens >= AIEvidencePolicy.maximumTokens {
                return try await evidence.finish(summary: reply.message.text, questions: [], pending: [], messages: JSONEncoder().encode(messages), limited: true)
            }
            var results: [String: JSONValue]=[:], questions: [AIQuestion]=[]
            for call in reply.message.calls {
                try await evidence.checkBudget()
                if call.name == "ask_user" {
                    let input=try JSONDecoder().decode(QuestionInput.self, from: Codec.encode(call.input))
                    guard checkpoint.questionCount + questions.count < 3, (1...1000).contains(input.question.count),
                          input.choices.count <= 4, input.choices.allSatisfy({ (1...200).contains($0.count) }) else {
                        throw ShouError("invalid_ai_question", "The model returned an invalid retention question.")
                    }
                    questions.append(.init(id: call.id, text: input.question, choices: input.choices))
                } else {
                    do {
                        let data=try Codec.encode(call.input)
                        switch call.name {
                        case "list_directory": results[call.id]=try await evidence.directory(JSONDecoder().decode(DirectoryInput.self, from: data))
                        case "inspect_directory": results[call.id]=try await evidence.inspect(JSONDecoder().decode(InspectInput.self, from: data))
                        case "propose_rule": results[call.id]=try await evidence.propose(JSONDecoder().decode(AdviceInput.self, from: data))
                        default: throw ShouError("invalid_ai_tool", "Choose an available read-only investigation tool.")
                        }
                    } catch {
                        if Task.isCancelled || error is CancellationError || ["ai_disabled", "ai_budget_exceeded", "ai_decision_failed"].contains((error as? ShouError)?.code ?? "") { throw error }
                        results[call.id] = .object(["error": .string((error as? ShouError)?.code ?? "invalid_ai_tool"), "message": .string("The tool input was refused. Use an exact observed relative path and the declared schema.")])
                    }
                }
            }
            if !results.isEmpty { messages.append(Message(role: "tool", results: results)) }
            let data=try JSONEncoder().encode(messages)
            try await evidence.replaceMessages(data)
            let state=await evidence.value().state
            let limited=state.steps >= AIEvidencePolicy.maximumSteps || state.tokens >= AIEvidencePolicy.maximumTokens
            if limited || !questions.isEmpty || reply.message.calls.isEmpty {
                return try await evidence.finish(summary: reply.message.text, questions: questions, pending: questions.map(\.id), messages: data, limited: limited)
            }
        }
    }
    static func test(connection: AIConnection, credentials: any AICredentialStore, permit: AIRequestPermit) async throws {
        try permit.check(); let key=try credentials.key(for: connection); try permit.check()
        let token=UUID().uuidString
        var messages=[Message(role: "user", text: "Call verify_connection exactly once with token '\(token)'. After its result reply 'Ready'.")]
        let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["token": .object(["type": .string("string")])]), "required": .array([.string("token")]), "additionalProperties": .bool(false)])
        var verified=false
        for _ in 0..<3 {
            let reply=try await request(connection, key: key, messages: messages, tools: [("verify_connection", "Verify the synthetic token.", schema)], permit: permit)
            messages.append(reply.message)
            if verified && reply.message.calls.isEmpty && !reply.message.text.isEmpty { return }
            guard !verified, reply.message.calls.count == 1, let call=reply.message.calls.first,
                  call.name == "verify_connection", call.input["token"]?.string == token else {
                throw ShouError("ai_probe_failed", "The model did not complete the tool check.")
            }
            verified=true; messages.append(Message(role: "tool", results: [call.id: .string("verified")]))
        }
        throw ShouError("ai_probe_failed", "The model did not complete the tool check.")
    }
    private static func tools(questions: Bool) -> [(String, String, JSONValue)] {
        func schema(_ properties: [String: JSONValue]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        let string: JSONValue = .object(["type": .string("string")]), strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        var result=[("list_directory", "Read at most 30 saved relative child metadata rows. No content. Start with path '.' and offset 0.", schema(["path": string, "offset": .object(["type": .string("integer")])])),
                    ("inspect_directory", "Inspect a saved relative directory. Names do not prove rebuildability.", schema(["path": string])),
                    ("propose_rule", "Propose one exact observed directory as a disabled high-risk draft. No import, enablement or deletion.", schema(["path": string,"name": string,"explanation": string,"rebuildNote": string,"limitations": strings,"minimumAgeDays": .object(["type": .array([.string("integer"),.string("null")])])]))]
        if questions { result.append(("ask_user", "Pause for one necessary retention/rebuild question; never invent answers.", schema(["question": string,"choices": strings]))) }
        return result
    }
    private static func request(_ source: AIConnection, key: String?, messages: [Message], tools: [(String, String, JSONValue)], permit: AIRequestPermit) async throws -> Reply {
        let connection=try source.validated()
        guard connection.usesMainModel else { throw ShouError("ai_model_unconfigured", "Add a main model connection to handle open-ended understanding.") }
        guard connection.authentication == .none || key?.isEmpty == false else { throw ShouError("ai_credential_missing", "The selected AI connection needs an API key.") }
        let encoded=try payload(messages, tools: tools, protocol: connection.apiProtocol)
        var fields=encoded.object ?? [:]; fields["model"] = .string(connection.model)
        let endpoint: String
        switch connection.apiProtocol { case .responses: endpoint="/responses"; case .chatCompletions: endpoint="/chat/completions"; case .anthropic: endpoint="/messages" }
        var request=URLRequest(url: URL(string: connection.baseURL + endpoint)!)
        request.httpMethod="POST"; request.httpBody=try Codec.encode(JSONValue.object(fields)); request.timeoutInterval=60
        guard request.httpBody!.count <= 1_048_576 else { throw ShouError("ai_budget_exceeded", "The investigation reached its evidence budget.") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if connection.apiProtocol == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if connection.authentication != .none, let key {
            request.setValue(connection.apiProtocol == .anthropic ? key : "Bearer " + key, forHTTPHeaderField: connection.apiProtocol == .anthropic ? "x-api-key" : "Authorization")
        }
        let body=try await BoundedAITransport.send(request, limit: 1_048_576, permit: permit)
        return try parse(Codec.decode(JSONValue.self, from: body), protocol: connection.apiProtocol)
    }
    private static func payload(_ messages: [Message], tools: [(String, String, JSONValue)], protocol api: AIProtocol) throws -> JSONValue {
        func arguments(_ value: JSONValue) throws -> JSONValue { .string(String(decoding: try Codec.encode(value), as: UTF8.self)) }
        var items: [JSONValue]=[]
        if api == .chatCompletions { items.append(.object(["role": .string("system"), "content": .string(AIModelInstructions.value)])) }
        for message in messages {
            switch api {
            case .responses:
                if let original=message.responseItems { items += original; continue }
                if !message.text.isEmpty { items.append(.object(["role": .string(message.role), "content": .string(message.text)])) }
                for call in message.calls { items.append(.object(["type": .string("function_call"), "call_id": .string(call.id), "name": .string(call.name), "arguments": try arguments(call.input)])) }
                for (id,result) in message.results.sorted(by: { $0.key < $1.key }) { items.append(.object(["type": .string("function_call_output"), "call_id": .string(id), "output": try arguments(result)])) }
            case .chatCompletions:
                if message.role == "tool" {
                    for (id,result) in message.results.sorted(by: { $0.key < $1.key }) { items.append(.object(["role": .string("tool"), "tool_call_id": .string(id), "content": try arguments(result)])) }
                } else {
                    var item: [String: JSONValue]=["role": .string(message.role), "content": .string(message.text)]
                    if !message.calls.isEmpty { item["tool_calls"] = .array(try message.calls.map { call in .object(["id": .string(call.id), "type": .string("function"), "function": .object(["name": .string(call.name), "arguments": try arguments(call.input)])]) }) }
                    items.append(.object(item))
                }
            case .anthropic:
                var parts: [JSONValue]=[]
                if !message.text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(message.text)])) }
                parts += message.calls.map { .object(["type": .string("tool_use"), "id": .string($0.id), "name": .string($0.name), "input": $0.input]) }
                parts += try message.results.sorted(by: { $0.key < $1.key }).map { .object(["type": .string("tool_result"), "tool_use_id": .string($0.key), "content": try arguments($0.value)]) }
                let role=message.role == "tool" ? "user" : message.role
                if let last=items.last, last["role"]?.string == role, let previous=last["content"]?.array {
                    items[items.count-1] = .object(["role": .string(role), "content": .array(previous+parts)])
                } else { items.append(.object(["role": .string(role), "content": .array(parts)])) }
            }
        }
        let declarations=tools.map { name,description,schema -> JSONValue in
            let value: [String: JSONValue]=["name": .string(name),"description": .string(description), api == .anthropic ? "input_schema" : "parameters": schema]
            if api == .chatCompletions { return .object(["type": .string("function"), "function": .object(value)]) }
            if api == .anthropic { return .object(value) }
            return .object(value.merging(["type": .string("function")]) { _,new in new })
        }
        var result: [String: JSONValue]=[api == .responses ? "input" : "messages": .array(items),"tools": .array(declarations),"stream": .bool(false),api == .responses ? "max_output_tokens" : api == .chatCompletions ? "max_completion_tokens" : "max_tokens": .integer(3072)]
        if api != .chatCompletions { result[api == .responses ? "instructions" : "system"] = .string(AIModelInstructions.value) }
        if api == .responses {
            result["store"] = .bool(false)
            result["include"] = .array([.string("reasoning.encrypted_content")])
        }
        return .object(result)
    }
    private static func parse(_ value: JSONValue, protocol api: AIProtocol) throws -> Reply {
        var text="", calls: [Call]=[]
        func call(_ item: JSONValue, id: String, name: String, input: JSONValue?) throws -> Call {
            guard (1...200).contains(id.count), (1...100).contains(name.count), let input, input.object != nil else { throw ShouError("ai_response_invalid", "The model returned an invalid tool call.") }
            return Call(id: id, name: name, input: input)
        }
        func decoded(_ source: JSONValue?) throws -> JSONValue? {
            guard let string=source?.string else { return nil }; return try Codec.decode(JSONValue.self, from: Data(string.utf8))
        }
        switch api {
        case .responses:
            guard let output=value["output"]?.array, value["status"]?.string == "completed" else { throw ShouError("ai_response_invalid", "The model returned an invalid response.") }
            for item in output {
                if item["type"]?.string == "function_call" { calls.append(try call(item,id: item["call_id"]?.string ?? "",name: item["name"]?.string ?? "", input: decoded(item["arguments"]))) }
                else if item["type"]?.string == "message" { text += (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined() }
            }
        case .chatCompletions:
            guard ["stop", "tool_calls"].contains(value["choices"]?.array?.first?["finish_reason"]?.string ?? "") else { throw ShouError("ai_response_invalid", "The model returned an invalid response.") }
            guard let message=value["choices"]?.array?.first?["message"], message.object != nil else { throw ShouError("ai_response_invalid", "The model returned an invalid response.") }
            text=message["content"]?.string ?? ""
            for item in message["tool_calls"]?.array ?? [] { calls.append(try call(item,id: item["id"]?.string ?? "",name: item["function"]?["name"]?.string ?? "",input: decoded(item["function"]?["arguments"]))) }
        case .anthropic:
            guard ["end_turn", "tool_use"].contains(value["stop_reason"]?.string ?? "") else { throw ShouError("ai_response_invalid", "The model returned an invalid response.") }
            guard let content=value["content"]?.array else { throw ShouError("ai_response_invalid", "The model returned an invalid response.") }
            for item in content {
                if item["type"]?.string == "tool_use" { calls.append(try call(item,id: item["id"]?.string ?? "",name: item["name"]?.string ?? "",input: item["input"])) }
                else if item["type"]?.string == "text" { text += item["text"]?.string ?? "" }
            }
        }
        guard calls.count <= 8, Set(calls.map(\.id)).count == calls.count, !text.isEmpty || !calls.isEmpty else { throw ShouError("ai_response_invalid", "The model returned an invalid response.") }
        let usage=value["usage"]
        let tokens=usage?["total_tokens"]?.numeric ?? ((usage?[api == .chatCompletions ? "prompt_tokens" : "input_tokens"]?.numeric ?? 0) + (usage?[api == .chatCompletions ? "completion_tokens" : "output_tokens"]?.numeric ?? 0))
        guard tokens.isFinite, (0...2_000_000).contains(tokens) else { throw ShouError("ai_response_invalid", "The model returned invalid usage.") }
        return Reply(message: Message(role: "assistant",text: String(text.prefix(12_000)),calls: calls, responseItems: api == .responses ? value["output"]?.array : nil), tokens: Int(tokens))
    }
}
