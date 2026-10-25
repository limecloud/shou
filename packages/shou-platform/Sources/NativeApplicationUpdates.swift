import Foundation
import ShouCore

/// Fetches only the public, fixed-host cask metadata API. The configuration
/// factory permits generated URLProtocol fixtures without changing endpoints.
public struct NativeHomebrewCaskClient: HomebrewCaskReading {
    private let configuration: @Sendable () -> URLSessionConfiguration
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configuration=configuration
    }

    public func metadata(token: String) async throws -> Data {
        try Task.checkCancellation()
        let source=try ApplicationUpdateSource.homebrewCask(token: token)
        let config=configuration()
        config.httpCookieStorage=nil; config.urlCredentialStorage=nil; config.urlCache=nil
        config.httpShouldSetCookies=false
        config.timeoutIntervalForRequest=10; config.timeoutIntervalForResource=15
        let session=URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request=URLRequest(url: URL(string: source.metadataURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Shou Catalog Check", forHTTPHeaderField: "User-Agent")
        let policy=SourcePolicy()
        do {
            let (stream, response)=try await session.bytes(for: request, delegate: policy)
            guard let http=response as? HTTPURLResponse, response.url == request.url else {
                throw ShouError("update_response_invalid", "The application catalog returned an invalid response.")
            }
            guard http.statusCode == 200 else {
                throw ShouError((300...399).contains(http.statusCode) ? "update_redirect_refused" : "update_response_invalid", "The application catalog request was not accepted.")
            }
            guard response.mimeType?.lowercased() == "application/json" else {
                throw ShouError("update_response_invalid", "The application catalog did not return JSON metadata.")
            }
            guard response.expectedContentLength <= Int64(ApplicationUpdateChecker.maximumMetadataBytes) else {
                throw ShouError("update_response_too_large", "The application catalog response exceeded its limit.")
            }
            var data=Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < ApplicationUpdateChecker.maximumMetadataBytes else {
                    throw ShouError("update_response_too_large", "The application catalog response exceeded its limit.")
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch {
            try Task.checkCancellation()
            if policy.refusedRedirect { throw ShouError("update_redirect_refused", "The application catalog redirected the request. No redirected request was sent.") }
            if let error=error as? ShouError { throw error }
            throw ShouError("update_network_unavailable", "The application catalog could not be reached. Try again when online.", retryable: true)
        }
    }

    private final class SourcePolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock=NSLock()
        private var redirected=false
        var refusedRedirect: Bool { lock.withLock { redirected } }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            lock.withLock { redirected=true }
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
}

public extension ApplicationUpdateChecker {
    static func native() -> ApplicationUpdateChecker {
        #if arch(arm64)
        let architecture="arm64"
        #elseif arch(x86_64)
        let architecture="x86_64"
        #else
        let architecture="unknown"
        #endif
        let os=ProcessInfo.processInfo.operatingSystemVersion
        return ApplicationUpdateChecker(catalog: NativeApplicationCatalog(), remote: NativeHomebrewCaskClient(),
            environment: ApplicationUpdateEnvironment(architecture: architecture, systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
    }
}
