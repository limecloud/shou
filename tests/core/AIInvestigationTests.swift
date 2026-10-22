import Foundation
import ShouCore
import ShouPlatform
import ShouAI

func aiInvestigationPreservesConnectionAndPhysicalSelectionBoundaries() throws {
    let gate=AIRequestGate()
    try expectThrows { try gate.permit().check() }
    gate.setEnabled(true)
    let old=gate.permit(); try old.check()
    gate.setEnabled(false)
    try expectThrows { try old.check() }
    gate.setEnabled(true)
    try expectThrows { try old.check() }
    try gate.permit().check()
    let connection=AIConnection(id: "connection_fixture", name: "Fixture", apiProtocol: .chatCompletions,
        baseURL: "http://127.0.0.1:8080/gateway/v1/", model: "fixture", authentication: .none)
    let normalized=try connection.validated()
    try expect(normalized.baseURL == "http://127.0.0.1:8080/gateway/v1")
    try expect(Codec.decode(AIConnection.self, from: Codec.encode(normalized)) == normalized)
    var withDecision=normalized
    withDecision.decision=JevConnection()
    try expect(Codec.decode(AIConnection.self, from: Codec.encode(withDecision.validated())) == withDecision)
    try expect(withDecision.strategy == .decisionFirst && withDecision.decision?.providerID == "jev")
    withDecision.mainModelEnabled=false; withDecision.model=""
    withDecision.baseURL=""; withDecision.authentication = .environment; withDecision.environmentVariable=""
    try expect(!withDecision.validated().usesMainModel)
    let legacy=Data("\"jev_first\"".utf8)
    try expect(JSONDecoder().decode(AIRoutingStrategy.self, from: legacy) == .decisionFirst)
    withDecision.decision?.baseURL="https://api.typesafe.ai/v1/systemone"
    try expectThrows { try withDecision.validated() }
    withDecision.decision?.provider="fixture-alternative"
    try expect(withDecision.validated().decision?.baseURL == "https://api.typesafe.ai/v1/systemone")
    for url in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?api_key=secret", "https://example.com/v1/responses"] {
        var value=connection; value.baseURL=url
        try expectThrows { try value.validated() }
    }
    for path in ["../outside", "/outside", ".ssh", "cache/.env.local", "cache/secret.key", "cache/\nsource"] {
        try expectThrows { try AIEvidencePolicy.resolve(path, scope: "build") }
    }
    try expect(AIEvidencePolicy.resolve("cache", scope: "build") == "build/cache")
    #if canImport(Darwin) || canImport(Glibc)
    let url=FileManager.default.temporaryDirectory.appendingPathComponent("shou-ai-selection-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let path=try NativeDirectorySelection.path(for: url)
    let identity=try NativeFileSystem().rootIdentity(path)
    try expect(identity.kind == "directory")
    let alias=url.appendingPathExtension("link")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: path)
    defer { try? FileManager.default.removeItem(at: alias) }
    try expect(NativeDirectorySelection.path(for: alias) == path)
    #endif
}

private actor AlternativeDecisionProvider: StructuredDecisionProvider {
    nonisolated let id="fixture-alternative"
    nonisolated let displayName="Alternative Fixture"
    nonisolated var defaultConnection: DecisionConnection { DecisionConnection(baseURL: "https://fixture.invalid/v1", model: "fixture", authentication: .none, provider: id) }
    var calls=0
    func decide(_ request: StructuredDecisionRequest, connection: AIConnection, key: String?, permit: AIRequestPermit) async throws -> AIDecisionReview {
        try permit.check(); calls += 1
        return AIDecisionReview(path: request.path, model: "alternative-fixture", verdict: "supported", confidence: 1,
                               probabilities: ["supported": 1, "retain": 0, "needs_information": 0], tokens: 3)
    }
}

private struct RevokingCredentials: AICredentialStore {
    let gate: AIRequestGate
    func key(for connection: AIConnection) throws -> String? { gate.setEnabled(false); return "synthetic-key" }
    func decisionKey(for connection: AIConnection) throws -> String? { gate.setEnabled(false); return "synthetic-key" }
}

func aiDecisionProvidersAreReplaceableAndRevokedCredentialsCannotSend() async throws {
    let provider=AlternativeDecisionProvider(), service=StructuredDecisionService(providers: [provider]), gate=AIRequestGate(enabled: true)
    let connection=AIConnection(name: "Alternative", model: "fixture", authentication: .none,
        decision: DecisionConnection(authentication: .none, provider: "fixture-alternative"), mainModelEnabled: false)
    let request=StructuredDecisionRequest(path: "cache", evidence: .object(["fixture": .bool(true)]))
    let result=try await service.decide(request, connection: connection, key: nil, permit: gate.permit())
    try expect(result.model == "alternative-fixture" && result.verdict == "supported")
    gate.setEnabled(false)
    try await expectThrows { try await service.decide(request, connection: connection, key: nil, permit: gate.permit()) }
    let calls=await provider.calls; try expect(calls == 1)
    try await expectThrows { try await StructuredDecisionService().decide(request, connection: connection, key: nil) }
    #if os(macOS)
    var jev=connection; jev.mainModelEnabled=true; jev.decision=DecisionConnection()
    // Simulate a Keychain read returning after the user disabled AI.
    for decision in [false, true] {
        gate.setEnabled(true); let permit=gate.permit()
        do {
            if decision { _ = try await StructuredDecisionService().test(connection: jev, credentials: RevokingCredentials(gate: gate), permit: permit) }
            else { try await AIConnectionTest.run(connection: jev, credentials: RevokingCredentials(gate: gate), permit: permit) }
            throw CheckFailure(description: "A revoked credential wait started a model request")
        } catch let error as ShouError { try expect(error.code == "ai_disabled") }
    }
    #endif
}
