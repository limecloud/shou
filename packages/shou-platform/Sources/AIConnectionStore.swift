import Foundation
import ShouCore
#if canImport(Security)
import Security
#endif
#if os(Windows)
import CShouWindows
#endif

public struct AIConnectionStore: Sendable {
    private let store: any RecordStore
    public init(store: any RecordStore) { self.store=store }
    public func connections() throws -> [AIConnection] {
        try store.ids("ai-connections").compactMap { id in
            try store.read("ai-connections", id: id).map { try Codec.decode(AIConnection.self, from: $0).validated() }
        }.sorted { $0.name < $1.name }
    }
    public func save(_ connection: AIConnection) throws {
        let value=try connection.validated()
        let lease=try store.lock(); defer { lease.release() }
        try store.write("ai-connections", id: value.id, data: Codec.encode(value))
    }
    public static func profile(_ json: JSONValue) throws -> AIConnection {
        let fields: Set<String>=["id", "name", "api_protocol", "base_url", "model", "authentication", "environment_variable", "decision", "main_model_enabled", "routing_strategy"]
        guard let object=json.object, Set(object.keys).isSubset(of: fields) else {
            throw ShouError("invalid_ai_connection", "A connection profile contains only connection fields. Do not store API keys in JSON.")
        }
        if let decision=object["decision"], decision != .null {
            guard let fields=decision.object, Set(fields.keys).isSubset(of: ["base_url", "model", "authentication", "environment_variable", "provider"]) else {
                throw ShouError("invalid_ai_connection", "A decision profile contains only provider, base_url, model, authentication and environment_variable. Do not store API keys in JSON.")
            }
        }
        return try Codec.decode(AIConnection.self, from: Codec.encode(json)).validated()
    }
}

/// Only explicitly selected credentials are read; provider environment defaults are never used.
public struct SystemAICredentials: AICredentialStore {
    public init() {}
    public func key(for connection: AIConnection) throws -> String? {
        try key(authentication: connection.authentication, environmentVariable: connection.environmentVariable, id: connection.id)
    }
    public func decisionKey(for connection: AIConnection) throws -> String? {
        guard let decision=connection.decision else { throw ShouError("invalid_ai_connection", "A structured decision provider is not configured for this connection.") }
        return try key(authentication: decision.authentication, environmentVariable: decision.environmentVariable, id: connection.id + Self.decisionSuffix(connection))
    }
    private static func decisionSuffix(_ connection: AIConnection) -> String {
        let provider=connection.decision?.providerID ?? "jev"
        return provider == "jev" ? ".jev" : ".decision." + provider
    }
    private func key(authentication: AIAuthentication, environmentVariable: String, id: String) throws -> String? {
        switch authentication {
        case .none: return nil
        case .environment:
            guard let value=ProcessInfo.processInfo.environment[environmentVariable], !value.isEmpty else {
                throw ShouError("ai_credential_missing", "The selected API key environment variable is empty.")
            }
            return value
        case .keychain:
            #if canImport(Security)
            var query=Self.query(id)
            query[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
            query[kSecReturnData as String]=true
            query[kSecMatchLimit as String]=kSecMatchLimitOne
            var result: CFTypeRef?
            let status=SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data=result as? Data, let key=String(data: data, encoding: .utf8), !key.isEmpty else {
                throw ShouError("ai_credential_missing", "The API key is unavailable in Keychain. Open AI settings to save it again.")
            }
            return key
            #elseif os(Windows)
            var bytes: UnsafeMutableRawPointer?, count=0
            guard shou_win_ai_credential_read(id, &bytes, &count) == 0, let bytes else {
                throw ShouError("ai_credential_missing", "The API key is unavailable in Windows Credential Manager. Open AI settings to save it again.")
            }
            defer { shou_win_free(bytes) }
            guard let key=String(data: Data(bytes: bytes, count: count), encoding: .utf8), !key.isEmpty else {
                throw ShouError("ai_credential_missing", "The saved API key is invalid. Open AI settings to save it again.")
            }
            return key
            #else
            throw ShouError("ai_credential_unavailable", "System Keychain credentials are available on macOS. Select an explicit environment variable on this platform.")
            #endif
        }
    }

    public func save(_ key: String, for connection: AIConnection, decision: Bool = false) throws {
        guard !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: { $0.isWhitespace }) else {
            throw ShouError("invalid_ai_key", "Enter one API key no larger than 8 KiB.")
        }
        #if canImport(Security)
        let query=Self.query(connection.id + (decision ? Self.decisionSuffix(connection) : "")), data=Data(key.utf8)
        var updateQuery=query
        updateQuery[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
        var status=SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes=query
            attributes[kSecValueData as String]=data
            attributes[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrLabel as String]="Shou AI · " + connection.name + (decision ? " · " + (connection.decision?.providerName ?? "Decision") : "")
            #if os(macOS)
            attributes[kSecAttrAccess as String]=try Self.applicationAccess()
            #endif
            status=SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ShouError("ai_credential_unavailable", "Could not save the API key in Keychain.") }
        #elseif os(Windows)
        let data=Data(key.utf8)
        let status=data.withUnsafeBytes { shou_win_ai_credential_write(connection.id + (decision ? Self.decisionSuffix(connection) : ""), $0.baseAddress, $0.count) }
        guard status == 0 else { throw ShouError("ai_credential_unavailable", "Could not save the API key in Windows Credential Manager.") }
        #else
        throw ShouError("ai_credential_unavailable", "Use an explicit environment variable on this platform.")
        #endif
    }
    #if canImport(Security)
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.limecloud.shou.ai", kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }
    #if os(macOS)
    /// Trust only this executable and its signed companion in the same app bundle.
    private static func applicationAccess() throws -> SecAccess {
        let executable=URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        var paths=[executable.path]
        let parent=executable.deletingLastPathComponent()
        let contents=parent.deletingLastPathComponent()
        if contents.lastPathComponent == "Contents", ["MacOS", "Helpers"].contains(parent.lastPathComponent) {
            let companion=contents.appendingPathComponent(parent.lastPathComponent == "MacOS" ? "Helpers/shou" : "MacOS/Shou")
            var code: SecStaticCode?
            if SecStaticCodeCreateWithPath(companion as CFURL, [], &code) == errSecSuccess, let code,
               SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess { paths.append(companion.path) }
        }
        let trusted=try paths.map { path -> SecTrustedApplication in
            var application: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(path, &application) == errSecSuccess, let application else {
                throw ShouError("ai_credential_unavailable", "Could not prepare Shou's Keychain access.")
            }
            return application
        }
        var access: SecAccess?
        guard SecAccessCreate("Shou AI credentials" as CFString, trusted as CFArray, &access) == errSecSuccess, let access else {
            throw ShouError("ai_credential_unavailable", "Could not prepare Shou's Keychain access.")
        }
        return access
    }
    #endif
    #endif
}
