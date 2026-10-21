import Foundation

/// Serialize delivery as well as counters: late worker events cannot regress
/// totals when the desktop receives them on another executor.
final class BatchScanProgress: @unchecked Sendable {
    private let lock=NSLock()
    private var entries: [Int]
    private var units: [Int]
    private var limited=false
    private let output: @Sendable (KnownLocation, ScanProgress) -> Void
    init(count: Int, output: @escaping @Sendable (KnownLocation, ScanProgress) -> Void) {
        entries=Array(repeating: 0, count: count); units=entries; self.output=output
    }
    func report(_ update: ScanProgress, index: Int, location: KnownLocation) {
        lock.lock(); defer { lock.unlock() }
        entries[index]=max(entries[index], update.entryCount)
        units[index]=max(units[index], min(3, update.completedUnitCount ?? 0))
        limited = limited || update.limitReached
        output(location, ScanProgress(stage: update.stage, entryCount: entries.reduce(0,+), currentPath: update.currentPath,
            limitReached: limited, completedUnitCount: units.reduce(0,+), totalUnitCount: units.count * 3))
    }
}
