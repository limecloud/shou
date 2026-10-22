import Foundation
import ShouCore
#if os(macOS)
import AppKit
#endif

/// The native adapter owns both the asynchronous operation and the provenance
/// of its returned Trash location. Tests can supply an isolated fixture adapter.
public protocol ApplicationRecycling: Sendable {
    func recycle(_ url: URL, completion: @escaping @Sendable (Result<URL, any Error>) -> Void)
    func isTrashLocation(_ path: String) -> Bool
}

#if os(macOS)
struct SystemApplicationRecycler: ApplicationRecycling {
    func recycle(_ url: URL, completion: @escaping @Sendable (Result<URL, any Error>) -> Void) {
        DispatchQueue.main.async {
            NSWorkspace.shared.recycle([url]) { destinations,error in
                if let error { completion(.failure(error)); return }
                guard destinations.count == 1, let destination=destinations[url], destination.isFileURL else {
                    completion(.failure(ShouError("trash_outcome_unknown", "The system recycler did not report the application's Trash destination.")))
                    return
                }
                completion(.success(destination))
            }
        }
    }
    func isTrashLocation(_ path: String) -> Bool { NativeFileSystem().isTrashLocation(path) }
}

enum NativeApplicationTrash {
    private final class Completion: @unchecked Sendable {
        let lock=NSLock()
        let semaphore=DispatchSemaphore(value:0)
        private var value: Result<URL, any Error>?
        func finish(_ result: Result<URL, any Error>) {
            lock.lock()
            guard value == nil else { lock.unlock(); return }
            value=result; lock.unlock(); semaphore.signal()
        }
        func result() -> Result<URL, any Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func recycle(_ path: String, recycler: any ApplicationRecycling) throws -> String {
        // NSWorkspace and its native authorization UI run on the main queue.
        // A synchronous caller must wait elsewhere so callbacks remain runnable.
        guard !Thread.isMainThread else {
            throw ShouError("capability_unavailable", "Application recycling must run away from the main thread.")
        }
        let completion=Completion()
        recycler.recycle(URL(fileURLWithPath:path)) { completion.finish($0) }
        // Authorization belongs to the user's native dialog. Do not time it out
        // while Finder may still complete the move after the app reports a result.
        completion.semaphore.wait()
        guard let result=completion.result() else {
            throw ShouError("trash_outcome_unknown", "The system recycler has not reported a final outcome. Inspect the source and Trash before retrying.")
        }
        // Preserve native cancellation/authorization errors. The caller first
        // proves the source still matches its manifest before forwarding them.
        let destination=try result.get()
        guard destination.isFileURL, destination.path.hasPrefix("/"), destination.path.rangeOfCharacter(from:.controlCharacters) == nil else {
            throw ShouError("trash_outcome_unknown", "The system recycler returned an invalid Trash destination.")
        }
        return destination.path
    }
}
#endif
