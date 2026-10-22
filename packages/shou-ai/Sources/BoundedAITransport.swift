import Foundation
import ShouCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Non-streaming provider transport shared by macOS and Windows. Limits apply while receiving.
enum BoundedAITransport {
    static func send(_ request: URLRequest, limit: Int, permit: AIRequestPermit) async throws -> Data {
        try permit.check()
        let transfer=Transfer(limit: limit)
        let data=try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(request, continuation: $0) }
        } onCancel: { transfer.cancel() }
        try permit.check()
        return data
    }
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock=NSLock()
        private let limit: Int
        private var data=Data()
        private var continuation: CheckedContinuation<Data, any Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var stopped=false
        init(limit: Int) { self.limit=limit }
        func start(_ request: URLRequest, continuation: CheckedContinuation<Data, any Error>) {
            lock.lock()
            guard !stopped else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation=continuation
            let config=URLSessionConfiguration.ephemeral
            config.httpCookieStorage=nil; config.urlCredentialStorage=nil; config.urlCache=nil
            config.timeoutIntervalForRequest=60; config.timeoutIntervalForResource=180
            let session=URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session=session
            let task=session.dataTask(with: request); self.task=task
            task.resume(); lock.unlock()
        }
        func cancel() { finish(.failure(CancellationError())) }
        private func finish(_ result: Result<Data, any Error>) {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            stopped=true
            let continuation=self.continuation, session=self.session
            self.continuation=nil; self.session=nil; task=nil
            lock.unlock()
            session?.invalidateAndCancel(); continuation?.resume(with: result)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http=response as? HTTPURLResponse, http.statusCode == 200 else {
                completionHandler(.cancel)
                finish(.failure(ShouError("ai_request_failed", "AI request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the selected connection.")))
                return
            }
            guard response.expectedContentLength <= Int64(limit) else {
                completionHandler(.cancel); finish(.failure(AIEvidencePolicy.budgetExceeded(.response))); return
            }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            lock.lock()
            let oversized=data.count + chunk.count > limit
            if !stopped && !oversized { data.append(chunk) }
            lock.unlock()
            if oversized { finish(.failure(AIEvidencePolicy.budgetExceeded(.response))) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if error != nil { finish(.failure(ShouError("ai_request_failed", "The AI request failed. Check the connection and try again."))) }
            else { lock.lock(); let body=data; lock.unlock(); finish(.success(body)) }
        }
    }
}
