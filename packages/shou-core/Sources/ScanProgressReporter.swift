import Foundation

/// Keeps measured discovery counts stable across worker transport and later phases.
final class ScanProgressReporter: @unchecked Sendable {
    private let lock=NSLock()
    private var entries=0
    private let output: @Sendable (ScanProgress) -> Void

    init(output: @escaping @Sendable (ScanProgress) -> Void) { self.output=output }

    var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func report(_ progress: ScanProgress) {
        lock.lock(); defer { lock.unlock() }
        entries=max(entries, progress.entryCount)
        output(ScanProgress(stage: progress.stage, entryCount: entries, currentPath: progress.currentPath,
            limitReached: progress.limitReached, completedUnitCount: progress.completedUnitCount, totalUnitCount: progress.totalUnitCount))
    }
}
