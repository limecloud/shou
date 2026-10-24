import Foundation
import ShouCore

func executionProgressKeepsBatchTotalsAndPartialBoundaries() throws {
    let updates=[
        ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: 2),
        ExecutionProgress(stage: "purging", processedCount: 1, itemCount: 2),
        ExecutionProgress(stage: "purging", processedCount: 2, itemCount: 2)
    ]
    let second=updates.map { $0.inBatch(processedBefore: 3, itemCount: 7) }
    try expect(second.map(\.processedCount) == [3, 4, 5])
    try expect(second.allSatisfy { $0.itemCount == 7 })
    let next=ExecutionProgress(stage: "moving", processedCount: 0, itemCount: 2).inBatch(processedBefore: 5, itemCount: 7)
    try expect(next.processedCount == 5 && next.itemCount == 7)
    let malformed=ExecutionProgress(stage: "moving", processedCount: Int.max, itemCount: Int.max).inBatch(processedBefore: Int.max, itemCount: Int.max)
    try expect(malformed.processedCount == Int.max)
    let empty=updates[1].inBatch(processedBefore: -1, itemCount: -1)
    try expect(empty.processedCount == 0 && empty.itemCount == 0)
    let negative=ExecutionProgress(stage: "preflight", processedCount: -20, itemCount: 3).inBatch(processedBefore: 2, itemCount: 7)
    try expect(negative.processedCount == 2)
}

func executionProgressRejectsLateStageAndEntryCallbacks() throws {
    let checking=ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: 73)
    let deleting=ExecutionProgress(stage: "purging", processedCount: 55, itemCount: 73,
        currentItemProcessedCount: 1900, currentItemCount: 1939)
    try expect(deleting.canFollow(checking))
    // A delayed preflight or bare item boundary must not erase nested progress.
    try expect(!checking.canFollow(deleting))
    try expect(!ExecutionProgress(stage: "preflight", processedCount: 55, itemCount: 73).canFollow(deleting))
    try expect(!ExecutionProgress(stage: "purging", processedCount: 55, itemCount: 73).canFollow(deleting))
    try expect(!ExecutionProgress(stage: "finalizing", processedCount: 55, itemCount: 73).canFollow(deleting))
    let saved=ExecutionProgress(stage: "purging", processedCount: 56, itemCount: 73)
    try expect(saved.canFollow(deleting))
    let next=ExecutionProgress(stage: "purging", processedCount: 56, itemCount: 73,
        currentItemProcessedCount: 1, currentItemCount: 2000)
    try expect(next.canFollow(saved) && !deleting.canFollow(next))
    try expect(!ExecutionProgress(stage: "purging", processedCount: 57, itemCount: 2000).canFollow(next))
    try expect(!ExecutionProgress(stage: "purging", processedCount: -1, itemCount: 73).canFollow(next))
    try expect(!ExecutionProgress(stage: "purging", processedCount: 74, itemCount: 73).canFollow(next))
    // A later location may perform its own checks without resetting the batch.
    let batchCheck=ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: 2).inBatch(processedBefore: 56, itemCount: 73)
    try expect(batchCheck.canFollow(saved))
    let partial=ExecutionProgress(stage: "finalizing", processedCount: 56, itemCount: 73)
    try expect(partial.canFollow(saved) && partial.fractionCompleted != 1)
    let empty=ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: 0)
    try expect(empty.canFollow(empty))
}
