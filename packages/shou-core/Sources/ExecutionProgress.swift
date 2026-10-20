import Foundation

extension ExecutionProgress {
    /// Preserve the operation-wide denominator across independently checked plans.
    /// A partial plan contributes only durable outcomes, not its unprocessed tail.
    public func inBatch(processedBefore: Int, itemCount total: Int) -> ExecutionProgress {
        let total=max(0, total), offset=min(max(0, processedBefore), total)
        let local=min(max(0, processedCount), max(0, itemCount))
        return ExecutionProgress(stage: stage, processedCount: offset + min(local, total - offset), itemCount: total, path: path)
    }
}
