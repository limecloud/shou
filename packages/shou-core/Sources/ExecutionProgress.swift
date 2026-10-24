import Foundation

extension ExecutionProgress {
    /// Late callbacks must not reset batch totals or replace entry progress
    /// with an earlier item boundary, including across stage changes.
    public func canFollow(_ previous: ExecutionProgress) -> Bool {
        guard itemCount == previous.itemCount, processedCount >= previous.processedCount,
              processedCount >= 0, processedCount <= itemCount else { return false }
        if let before=previous.fractionCompleted {
            guard let after=fractionCompleted, after >= before else { return false }
        }
        return true
    }

    /// Preserve the operation-wide denominator across independently checked plans.
    /// A partial plan contributes only durable outcomes, not its unprocessed tail.
    public func inBatch(processedBefore: Int, itemCount total: Int) -> ExecutionProgress {
        let total=max(0, total), offset=min(max(0, processedBefore), total)
        let local=min(max(0, processedCount), max(0, itemCount))
        return ExecutionProgress(stage: stage, processedCount: offset + min(local, total - offset), itemCount: total, path: path,
            currentItemProcessedCount: currentItemProcessedCount, currentItemCount: currentItemCount)
    }
}
