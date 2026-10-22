import Foundation

public enum AIProtocol: String, Codable, CaseIterable, Sendable {
    case responses, chatCompletions = "chat_completions", anthropic
    public var title: String {
        switch self {
        case .responses: "OpenAI Responses"
        case .chatCompletions: "OpenAI Chat Completions"
        case .anthropic: "Anthropic Messages"
        }
    }
}

public enum AIAuthentication: String, Codable, CaseIterable, Sendable {
    case keychain, environment, none
}

public enum AIRoutingStrategy: String, Codable, CaseIterable, Sendable {
    case decisionFirst = "decision_first", mainOnly = "main_only"
    public init(from decoder: any Decoder) throws {
        let container=try decoder.singleValueContainer(), value=try container.decode(String.self)
        if value == "jev_first" { self = .decisionFirst }
        else if let strategy=Self(rawValue: value) { self=strategy }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown AI routing strategy.") }
    }
}

public enum AIInvestigationGoal: String, Codable, CaseIterable, Sendable {
    case investigate, space, rules
}

/// A permit belongs to one enabled period. Re-enabling never revives old work.
public struct AIRequestPermit: Sendable {
    private let authorize: @Sendable () throws -> Void
    public init(authorize: @escaping @Sendable () throws -> Void) { self.authorize=authorize }
    public func check() throws { try Task.checkCancellation(); try authorize() }
    public static let unrestricted=AIRequestPermit(authorize: {})
}

public final class AIRequestGate: @unchecked Sendable {
    private let lock=NSLock()
    private var enabled: Bool
    private var generation=0
    public init(enabled: Bool = false) { self.enabled=enabled }
    public func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled=value; generation += 1
    }
    public func permit() -> AIRequestPermit {
        lock.lock(); let current=generation; lock.unlock()
        return AIRequestPermit { [self] in
            lock.lock(); defer { lock.unlock() }
            guard enabled, generation == current else { throw ShouError("ai_disabled", "AI investigation is disabled. Enable it in Settings before making a new request.") }
        }
    }
}

/// This record contains a credential reference, never an API key.
public struct AIConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var apiProtocol: AIProtocol
    public var baseURL: String
    public var model: String
    public var authentication: AIAuthentication
    public var environmentVariable: String
    public var decision: DecisionConnection?
    public var mainModelEnabled: Bool?
    public var routingStrategy: AIRoutingStrategy?
    public var usesMainModel: Bool { mainModelEnabled != false }
    public var strategy: AIRoutingStrategy { routingStrategy ?? (decision == nil ? .mainOnly : .decisionFirst) }
    private enum CodingKeys: String, CodingKey {
        case id, name, apiProtocol, model, authentication, environmentVariable, decision, mainModelEnabled, routingStrategy
        case baseURL = "baseUrl"
    }

    public init(id: String = Codec.id("connection"), name: String = "OpenAI", apiProtocol: AIProtocol = .responses,
                baseURL: String = "https://api.openai.com/v1", model: String = "", authentication: AIAuthentication = .keychain,
                environmentVariable: String = "SHOU_AI_API_KEY", decision: DecisionConnection? = nil,
                mainModelEnabled: Bool? = nil, routingStrategy: AIRoutingStrategy? = nil) {
        self.id=id; self.name=name; self.apiProtocol=apiProtocol; self.baseURL=baseURL; self.model=model
        self.authentication=authentication; self.environmentVariable=environmentVariable
        self.decision=decision
        self.mainModelEnabled=mainModelEnabled; self.routingStrategy=routingStrategy
    }

    public func validated() throws -> AIConnection {
        var copy=self
        copy.name=name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model=model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.baseURL=baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while copy.baseURL.hasSuffix("/") { copy.baseURL.removeLast() }
        guard id.hasPrefix("connection_"), id.count <= 100, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              !copy.name.isEmpty, copy.name.count <= 80 else {
            throw ShouError("invalid_ai_connection", "Choose a valid connection name and identifier.")
        }
        if usesMainModel {
            guard validAIModel(copy.model), validAIBaseURL(copy.baseURL),
                  !["/responses", "/chat/completions", "/messages"].contains(where: { copy.baseURL.hasSuffix($0) }) else {
            throw ShouError("invalid_ai_connection", "Use a model name and an HTTPS API base URL. HTTP is allowed only on loopback. Do not include credentials or an endpoint suffix in the URL.")
            }
        }
        if usesMainModel && authentication == .environment {
            guard !environmentVariable.isEmpty, environmentVariable.count <= 100,
                  environmentVariable.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw ShouError("invalid_ai_connection", "Choose an explicit environment variable for the API key.")
            }
        }
        copy.decision=try decision?.validated()
        guard usesMainModel || (copy.decision != nil && strategy == .decisionFirst) else {
            throw ShouError("invalid_ai_connection", "Configure a structured decision provider before disabling the main model.")
        }
        return copy
    }
}

public protocol AICredentialStore: Sendable {
    func key(for connection: AIConnection) throws -> String?
    func decisionKey(for connection: AIConnection) throws -> String?
}

extension AICredentialStore {
    public func decisionKey(for connection: AIConnection) throws -> String? {
        throw ShouError("ai_credential_missing", "The structured decision API key is unavailable.")
    }
}

public enum AIInvestigationStatus: String, Codable, Sendable {
    case running, waiting, complete, limited, cancelled, failed
}

public struct AIQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let choices: [String]
    public init(id: String, text: String, choices: [String]) { self.id=id; self.text=text; self.choices=choices }
}

public struct AIAdvice: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let explanation: String
    public let rule: CleanupRule
    public init(id: String, path: String, explanation: String, rule: CleanupRule) {
        self.id=id; self.path=path; self.explanation=explanation; self.rule=rule
    }
}

/// Provider configuration is independent of generative model protocols.
public struct DecisionConnection: Codable, Sendable, Equatable {
    public var provider: String?
    public var providerID: String { provider ?? "jev" }
    public var providerName: String { providerID == "jev" ? "Jev" : providerID }
    public var baseURL: String
    public var model: String
    public var authentication: AIAuthentication
    public var environmentVariable: String
    private enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl", model, authentication, environmentVariable, provider
    }
    public init(baseURL: String = "https://api.typesafe.ai/v1", model: String = "jev-1.13.0",
                authentication: AIAuthentication = .keychain, environmentVariable: String = "SHOU_JEV_API_KEY", provider: String? = nil) {
        self.baseURL=baseURL; self.model=model; self.authentication=authentication; self.environmentVariable=environmentVariable
        self.provider=provider
    }
    public func validated() throws -> DecisionConnection {
        guard providerID.count <= 80, !providerID.isEmpty, providerID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw ShouError("invalid_ai_connection", "Choose a valid structured decision provider.")
        }
        var copy=self
        copy.baseURL=baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while copy.baseURL.hasSuffix("/") { copy.baseURL.removeLast() }
        copy.model=model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validAIBaseURL(copy.baseURL), validAIModel(copy.model) else {
            throw ShouError("invalid_ai_connection", "Use a decision model and an HTTPS API base URL without credentials. HTTP is allowed only on loopback.")
        }
        if authentication == .environment {
            guard !environmentVariable.isEmpty, environmentVariable.count <= 100,
                  environmentVariable.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw ShouError("invalid_ai_connection", "Choose an explicit environment variable for the API key.")
            }
        }
        if providerID == "jev", copy.baseURL.hasSuffix("/systemone") {
            throw ShouError("invalid_ai_connection", "Enter the Jev API base URL without /systemone.")
        }
        return copy
    }
}

private func validAIModel(_ model: String) -> Bool {
    !model.isEmpty && model.count <= 200 && !model.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true })
}

private func validAIBaseURL(_ value: String) -> Bool {
    guard value.count <= 2048, let url=URLComponents(string: value), let host=url.host, !host.isEmpty,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
    return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()))
}

/// Source compatibility for profiles created before provider-independent routing.
public typealias JevConnection = DecisionConnection

public struct AIDecisionReview: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let model: String
    public let verdict: String
    public let confidence: Double?
    public let probabilities: [String: Double]
    public let tokens: Int
    public init(path: String, model: String, verdict: String, confidence: Double?, probabilities: [String: Double], tokens: Int) {
        self.path=path; self.model=model; self.verdict=verdict; self.confidence=confidence; self.probabilities=probabilities; self.tokens=tokens
    }
}

public struct AIObservedEvidence: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let allocatedBytes: Int64
    public let complete: Bool
    public init(path: String, allocatedBytes: Int64, complete: Bool) {
        self.path=path; self.allocatedBytes=allocatedBytes; self.complete=complete
    }
}

public struct AIInvestigation: Codable, Sendable, Identifiable {
    public let id: String
    public let scanId: String
    public let scope: String
    public let connection: AIConnection
    public let createdAt: Date
    public var status: AIInvestigationStatus = .running
    public var summary: String = ""
    public var questions: [AIQuestion] = []
    public var advice: [AIAdvice] = []
    public var evidence: [AIObservedEvidence] = []
    public var decisionReviews: [AIDecisionReview]?
    public var steps: Int = 0
    public var toolCalls: Int = 0
    public var evidenceRows: Int = 0
    public var evidenceBytes: Int = 0
    public var tokens: Int = 0
    public var activity: String = "Preparing investigation…"
    public var issue: String?
    public var goal: AIInvestigationGoal?
    public var serviceUsage: [AIServiceUsage]?
    public var escalationReasons: [String]?
    public init(id: String = Codec.id("investigation"), scanId: String, scope: String, connection: AIConnection) {
        self.id=id; self.scanId=scanId; self.scope=scope; self.connection=connection; createdAt=Date()
    }
}

public struct AIServiceUsage: Codable, Sendable, Identifiable {
    public var id: String { service }
    public let service: String
    public var requests: Int
    public var reportedTokens: Int
    public init(service: String, requests: Int = 0, reportedTokens: Int = 0) {
        self.service=service; self.requests=requests; self.reportedTokens=reportedTokens
    }
}

/// The model sees paths relative to the selected folder, never the home path.
public enum AIEvidencePolicy {
    public static let maximumSteps=12
    public static let maximumToolCalls=32
    public static let maximumRows=300
    public static let maximumBytes=65_536
    public static let maximumTokens=32_000
    public static func validate(_ path: String) throws {
        guard path == "." || (path.count <= 1024 && StorageRemovalPolicy.validRelative(path)),
              !path.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw ShouError("ai_scope_denied", "Use an exact relative path inside the investigation folder.")
        }
        let privateNames: Set<String> = [".ssh", ".aws", ".azure", ".gnupg", ".git", ".kube", ".docker", ".config", ".npmrc", ".pypirc", ".netrc", "keychains", "credentials", "secrets", "cookies", "login data", "wallets", "1password"]
        for part in path.lowercased().split(separator: "/").map(String.init) {
            if privateNames.contains(part) || part.hasPrefix(".env") || part.hasSuffix(".pem") || part.hasSuffix(".key") || part.hasSuffix(".keychain-db") {
                throw ShouError("ai_scope_denied", "Credential and private-data locations are excluded from AI evidence.")
            }
        }
    }
    public static func resolve(_ path: String, scope: String) throws -> String {
        try validate(scope); try validate(path)
        return scope == "." ? path : path == "." ? scope : scope + "/" + path
    }
    public static func relative(_ path: String, scope: String) -> String {
        scope == "." ? path : path == scope ? "." : String(path.dropFirst(scope.count + 1))
    }
}
