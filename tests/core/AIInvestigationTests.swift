import Foundation
import ShouCore
import ShouPlatform
import ShouAI

func aiLocalCredentialsRemainPrivateAndIndependent() throws {
    let fixture=try Fixture(), store=fixture.store, url=store.directory
    defer { withExtendedLifetime(fixture) {} }
    var connection=AIConnection(name: "Synthetic local keys", model: "fixture", authentication: .local,
        decision: DecisionConnection(authentication: .local))
    let credentials=SystemAICredentials(directory: url)
    try expectThrows { try credentials.key(for: connection) }
    try credentials.save("synthetic-main-key", for: connection)
    try credentials.save("synthetic-decision-key", for: connection, decision: true)
    let reopened=SystemAICredentials(directory: url)
    try expect(reopened.key(for: connection) == "synthetic-main-key")
    try expect(reopened.decisionKey(for: connection) == "synthetic-decision-key")
    try credentials.save("synthetic-decision-rotated", for: connection, decision: true)
    try expect(reopened.key(for: connection) == "synthetic-main-key")
    try expect(reopened.decisionKey(for: connection) == "synthetic-decision-rotated")
    var oldCheckpoint=connection; oldCheckpoint.authentication = .keychain; oldCheckpoint.decision?.authentication = .keychain
    try expect(reopened.key(for: oldCheckpoint) == "synthetic-main-key")
    try expect(reopened.decisionKey(for: oldCheckpoint) == "synthetic-decision-rotated")
    var alternative=connection; alternative.decision?.provider="fixture-alternative"
    try expectThrows { try reopened.decisionKey(for: alternative) }
    try expect(reopened.key(for: alternative) == "synthetic-main-key")
    alternative.id=Codec.id("connection")
    try expectThrows { try reopened.key(for: alternative) }
    try AIConnectionStore(store: store).save(connection)
    let profile=String(decoding: try Codec.encode(AIConnectionStore(store: store).connections()), as: UTF8.self)
    try expect(!profile.contains("synthetic-main-key") && !profile.contains("synthetic-decision-rotated"))
    let configurations=AIConnectionStore(store: store)
    let snapshot=try Codec.encode(connection)
    try store.write("ai-investigations", id: "investigation_configuration_fixture", data: snapshot)
    try configurations.setDeleted(true, id: connection.id)
    try expect(configurations.connections().isEmpty)
    try expect(configurations.connections(deleted: true).map(\.id) == [connection.id])
    try expectThrows { try configurations.connection(connection.id) }
    try expectThrows { try configurations.save(connection) }
    try expect(configurations.connection(connection.id, includingDeleted: true) == connection)
    try expect(store.read("ai-investigations", id: "investigation_configuration_fixture") == snapshot)
    try configurations.setDeleted(false, id: connection.id)
    try expect(configurations.connections().map(\.id) == [connection.id])
    try expect(configurations.connections(deleted: true).isEmpty)
    try expect(reopened.key(for: connection) == "synthetic-main-key")
    try expect(reopened.decisionKey(for: connection) == "synthetic-decision-rotated")
    try expectThrows { try configurations.setDeleted(true, id: "connection_missing") }
    try expect(!DerivedRecords.collections.contains("ai-credentials"))
    try expectThrows { try credentials.save(String(repeating: "x", count: 8193), for: connection) }
    try expectThrows { try credentials.save("invalid key", for: connection) }
    connection.authentication = .environment
    try expectThrows { try credentials.save("synthetic-rejected", for: connection) }
    connection.authentication = .local
    let directory=url.appendingPathComponent("ai-credentials", isDirectory: true)
    let files=try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let file=try require(files.first { (try? String(contentsOf: $0, encoding: .utf8)) == "synthetic-main-key" })
    try Data(repeating: 120, count: 8193).write(to: file)
    try expectThrows { try reopened.key(for: connection) }
    try credentials.save("synthetic-main-key", for: connection)
    #if canImport(Darwin) || canImport(Glibc)
    try expect((FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    try expect((FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try expectThrows { try reopened.key(for: connection) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try expectThrows { try reopened.key(for: connection) }
    try expectThrows { try credentials.save("synthetic-main-key", for: connection) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let target=url.appendingPathComponent("must-not-overwrite")
    try Data("untouched".utf8).write(to: target)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    try expectThrows { try reopened.key(for: connection) }
    try credentials.save("synthetic-main-key", for: connection)
    try expect(String(contentsOf: target, encoding: .utf8) == "untouched")
    let alias=url.appendingPathComponent("hard-link")
    try FileManager.default.linkItem(at: file, to: alias)
    try expectThrows { try reopened.key(for: connection) }
    #endif
}

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
    try expectThrows { try withDecision.validated() }
    try expect(!withDecision.validated(allowLegacyDecisionOnly: true).usesMainModel)
    withDecision=normalized; withDecision.decision=JevConnection()
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

private struct UnreadableDecisionCredentials: AICredentialStore {
    func key(for connection: AIConnection) throws -> String? { nil }
    func decisionKey(for connection: AIConnection) throws -> String? {
        throw ShouError("unexpected_credential_read", "A disabled decision service must not read credentials.")
    }
}

func aiDecisionProvidersAreReplaceableAndRevokedCredentialsCannotSend() async throws {
    let provider=AlternativeDecisionProvider(), service=StructuredDecisionService(providers: [provider]), gate=AIRequestGate(enabled: true)
    let connection=AIConnection(name: "Alternative", model: "fixture", authentication: .none,
        decision: DecisionConnection(authentication: .none, provider: "fixture-alternative"))
    let request=StructuredDecisionRequest(path: "cache", evidence: .object(["fixture": .bool(true)]))
    let result=try await service.decide(request, connection: connection, key: nil, permit: gate.permit())
    try expect(result.model == "alternative-fixture" && result.verdict == "supported")
    var disabled=connection; disabled.routingStrategy = .mainOnly
    do {
        _ = try await service.test(connection: disabled, credentials: UnreadableDecisionCredentials(), permit: gate.permit())
        throw CheckFailure(description: "A disabled decision service ran a request")
    } catch let error as ShouError { try expect(error.code == "ai_decision_disabled") }
    try await expectThrows { try await service.decide(request, connection: disabled, key: nil, permit: gate.permit()) }
    do {
        _ = try await JevDecisionService.test(connection: disabled, credentials: UnreadableDecisionCredentials(), permit: gate.permit())
        throw CheckFailure(description: "The legacy Jev entry ignored the disabled decision service")
    } catch let error as ShouError { try expect(error.code == "ai_decision_disabled") }
    try expect(disabled.decision == connection.decision && disabled.validated().usesMainModel)
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
