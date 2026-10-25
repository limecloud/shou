import Foundation
import ShouCore
import ShouPlatform

private func updateApplication(version: String = "1.2.0", identifier: String = "com.microsoft.VSCode", name: String = "Visual Studio Code.app") -> ApplicationDefinition {
    ApplicationDefinition(path: "/Applications/" + name, source: ApplicationSource(id: "macos.local_applications", path: "/Applications"),
        identity: FileEntry(path: ".", kind: "directory", device: 1, inode: 2, logicalBytes: 0, allocatedBytes: 0,
            modifiedNanoseconds: 1, changedNanoseconds: 1, mode: 0o40755, owner: 501, links: 1),
        name: name, bundleIdentifier: identifier, version: version, executableName: "Code", infoDigest: "metadata-" + version)
}

private func updateMetadata(version: String = "1.3.0", changes: [String: JSONValue] = [:]) throws -> Data {
    var values: [String: JSONValue] = ["token": .string("visual-studio-code"), "version": .string(version),
        "artifacts": .array([.object(["app": .array([.string("Visual Studio Code.app")])])]),
        "depends_on": .object(["macos": .object([">=": .array([.string("13")])])]), "variations": .object([:])]
    values.merge(changes) { _, next in next }
    return try JSONEncoder().encode(JSONValue.object(values))
}

private let updateEnvironment=ApplicationUpdateEnvironment(architecture: "arm64", systemVersion: "15.8.1")

func applicationUpdatesCompareOnlyVerifiedNumericVersions() throws {
    let app=updateApplication(), source=try require(ApplicationUpdateChecker.source(for: app))
    for (version, expected): (String, ApplicationUpdateState) in [("1.3", .newerCatalogVersion), ("1.2.0.0", .sameCatalogVersion), ("1.1.99", .installedVersionNewer)] {
        let result=ApplicationUpdateChecker.evaluate(application: app, source: source, data: try updateMetadata(version: version), environment: updateEnvironment)
        try expect(result.state == expected && result.status == "complete" && result.catalogVersion == version)
    }
    for version in ["latest", "1.3b1", "v1.3", "1.3,45", "1..3", "1.3\n", "１２.3", "1234567890", "1.2.3.4.5.6.7.8.9"] {
        let result=ApplicationUpdateChecker.evaluate(application: app, source: source, data: try updateMetadata(version: version), environment: updateEnvironment)
        try expect(result.state == .unknown && result.issues == ["update_version_ambiguous"] && result.catalogVersion == nil)
        try expect(try JSONValue.from(result)["status"] == .string("partial"))
    }
    try expect(try ApplicationUpdateChecker.source(for: updateApplication(identifier: "com.microsoft.VSCodeInsiders")) == nil)
    try expect(try ApplicationUpdateChecker.source(for: updateApplication(name: "Renamed.app")) == nil)
    for token in ["../private", "firefox?path=/private", "a/b", "-foo", "foo\n"] { try expectThrows { try ApplicationUpdateSource.homebrewCask(token: token) } }
}

func applicationUpdatesBindCatalogIdentityAndSystemVariants() throws {
    let app=updateApplication(), source=try require(ApplicationUpdateChecker.source(for: app))
    func check(_ data: Data, environment: ApplicationUpdateEnvironment = updateEnvironment) -> ApplicationUpdateObservation {
        ApplicationUpdateChecker.evaluate(application: app, source: source, data: data, environment: environment)
    }
    try expect(check(try updateMetadata(changes: ["token": .string("firefox")])).issues == ["update_source_mismatch"])
    try expect(check(try updateMetadata(changes: ["artifacts": .array([.object(["app": .array([.string("Other.app")])])])])).state == .unknown)
    try expect(check(try updateMetadata(changes: ["disabled": .bool(true)])).issues == ["update_catalog_disabled"])
    try expect(check(try updateMetadata(changes: ["arch": .string("intel")])).issues == ["update_platform_unknown"])
    try expect(check(Data("not json".utf8)).state == .unknown)
    try expect(check(Data(repeating: 32, count: ApplicationUpdateChecker.maximumMetadataBytes + 1)).issues == ["update_response_too_large"])
    let variations: JSONValue = .object([
        "arm64_sequoia": .object(["version": .string("1.4.0")]),
        "sequoia": .object(["version": .string("1.1.0")])
    ])
    let data=try updateMetadata(changes: ["variations": variations])
    try expect(check(data).state == .newerCatalogVersion && check(data).catalogVersion == "1.4.0")
    try expect(check(data, environment: ApplicationUpdateEnvironment(architecture: "x86_64", systemVersion: "15.0")).state == .installedVersionNewer)
    try expect(check(try updateMetadata(), environment: ApplicationUpdateEnvironment(architecture: "arm64", systemVersion: "12.0")).issues == ["update_system_unsupported"])
    try expect(check(try updateMetadata(), environment: ApplicationUpdateEnvironment(architecture: "unknown", systemVersion: "15.0")).issues == ["update_platform_unknown"])
    try expect(check(try updateMetadata(), environment: ApplicationUpdateEnvironment(architecture: "arm64", systemVersion: "99.0")).state == .unknown)
}

private final class UpdateCatalogFixture: ApplicationCatalogReading, @unchecked Sendable {
    private let lock=NSLock()
    private var value=updateApplication()
    func replace() { lock.lock(); value=updateApplication(version: "1.2.1"); lock.unlock() }
    func application(at path: String) throws -> ApplicationDefinition { lock.lock(); defer { lock.unlock() }; return value }
    func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog { throw ShouError("not_expected", "Only one application may be read") }
}
private struct UpdateRemoteFixture: HomebrewCaskReading {
    let read: @Sendable (String) async throws -> Data
    func metadata(token: String) async throws -> Data { try await read(token) }
}

func applicationUpdatesRejectChangedAppsAndKeepFailedChecksUnknown() async throws {
    let catalog=UpdateCatalogFixture()
    let changed=ApplicationUpdateChecker(catalog: catalog, remote: UpdateRemoteFixture { token in
        try expect(token == "visual-studio-code")
        catalog.replace(); return try updateMetadata()
    }, environment: updateEnvironment)
    do { _ = try await changed.check(path: "/Applications/Visual Studio Code.app"); throw CheckFailure(description: "Changed applications must invalidate update observations") }
    catch let error as ShouError { try expect(error.code == "application_changed") }
    let failure=ApplicationUpdateChecker(catalog: catalog, remote: UpdateRemoteFixture { _ in
        throw ShouError("private-network-diagnostics", "generated private credential and server response")
    }, environment: updateEnvironment)
    let result=try await failure.check(path: "/Applications/Visual Studio Code.app")
    try expect(result.state == .unknown && result.status == "partial" && result.catalogVersion == nil && result.issues == ["update_network_unavailable"])
    try expect(!String(decoding: Codec.encode(result), as: UTF8.self).contains("private credential"))
    let work=Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await failure.check(path: "/Applications/Visual Studio Code.app")
    }
    do { _ = try await work.value; throw CheckFailure(description: "Cancelled checks must not publish") } catch is CancellationError {}
    do { _ = try await failure.check(path: "/Applications/Visual Studio Code.app", expectedApplication: updateApplication()); throw CheckFailure(description: "Stale row identity must be rejected") }
    catch let error as ShouError { try expect(error.code == "application_changed") }
}

private final class UpdateURLProtocolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode=request.value(forHTTPHeaderField: "X-Shou-Fixture") ?? "valid"
        guard request.url?.host == "formulae.brew.sh", request.url?.scheme == "https", request.url?.path == "/api/cask/visual-studio-code.json",
              request.value(forHTTPHeaderField: "Cookie") == nil, request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "User-Agent") == "Shou Catalog Check" else {
            client?.urlProtocol(self, didFailWithError: ShouError("unexpected_request", "Unexpected destination or request metadata")); return
        }
        if mode == "offline" { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let status=mode == "redirect" ? 302 : mode == "error" ? 503 : 200
        var headers=["Content-Type": mode == "html" ? "text/html" : "application/json"]
        if mode == "length" { headers["Content-Length"]=String(ApplicationUpdateChecker.maximumMetadataBytes + 1) }
        if mode == "redirect" { headers["Location"]="https://invalid.example/private" }
        let response=HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if mode == "follow" {
            let redirect=HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://invalid.example/private"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://invalid.example/private")!), redirectResponse: redirect)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data=mode == "chunk" ? Data(repeating: 32, count: ApplicationUpdateChecker.maximumMetadataBytes + 1) : Data("{\"token\":\"visual-studio-code\"}".utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func applicationUpdatesTransportBoundsAndSanitizesFailures() async throws {
    for (mode, expected): (String, String?) in [("valid", nil), ("redirect", "update_redirect_refused"), ("follow", "update_redirect_refused"), ("error", "update_response_invalid"),
        ("html", "update_response_invalid"), ("length", "update_response_too_large"), ("chunk", "update_response_too_large"), ("offline", "update_network_unavailable")] {
        let client=NativeHomebrewCaskClient {
            let configuration=URLSessionConfiguration.ephemeral
            configuration.protocolClasses=[UpdateURLProtocolFixture.self]
            configuration.httpAdditionalHeaders=["X-Shou-Fixture": mode]
            return configuration
        }
        do {
            let bytes=try await client.metadata(token: "visual-studio-code")
            try expect(expected == nil && !bytes.isEmpty)
        } catch let error as ShouError {
            guard error.code == expected else { throw CheckFailure(description: "Transport fixture \(mode) expected \(expected ?? "success"), received \(error.code)") }
        }
    }
}
