import ShouCore
#if !canImport(SwiftAISDK)
public enum AIConnectionTest {
    public static func run(connection: AIConnection, credentials: any AICredentialStore, permit: AIRequestPermit = .unrestricted) async throws {
        try await PortableModelRuntime.test(connection: connection, credentials: credentials, permit: permit)
    }
}
#endif
