import Foundation

public struct RuleOpportunity: Codable, Sendable {
    public let relativePath: String
    public let absolutePath: String
    public let allocatedBytesEstimate: Int64
    public let complete: Bool
    public let containsCoveredDescendants: Bool
    public let eligible: Bool
}
public struct RuleOpportunityPage: Codable, Sendable {
    public let scanId: String
    public let workspaceId: String
    public let rootRef: String
    public let status: String
    public let items: [RuleOpportunity]
    public let totalCount: Int
    public let nextOffset: Int?
}
public struct RulePreviewBenefits: Codable, Sendable {
    public let eligibleMatchCount: Int
    public let blockedMatchCount: Int
    public let matchedAllocatedBytesEstimate: Int64
    public let alreadyCoveredAllocatedBytesEstimate: Int64
    public let additionalAllocatedBytesEstimate: Int64
}

extension ShouEngine {
    /// Investigation evidence only. Nested rows overlap and must not be summed.
    public func ruleOpportunities(scanId: String, minimumBytes: Int64 = 52_428_800, offset: Int = 0, limit: Int = 50) throws -> RuleOpportunityPage {
        guard minimumBytes >= 0, offset >= 0, (1...500).contains(limit) else { throw ShouError("invalid_argument", "Use a nonnegative minimum and offset, and limit 1–500.") }
        let scan=try scanSnapshot(scanId)
        guard !scan.previewOnly, scan.scope != .cleanup else { throw ShouError("invalid_argument", "Use a full workspace scan to discover uncovered directories.") }
        let classified=scan.candidates.filter { !$0.ruleIds.isEmpty }.map(\.relativePath)
        let tree=TreeSnapshot(entries: scan.entries, complete: scan.treeComplete ?? (scan.status == "complete"), issues: scan.issues, caseSensitive: scan.caseSensitive, completedPaths: scan.completedPaths)
        let rows=scan.candidates.filter { candidate in
            candidate.ruleIds.isEmpty && candidate.allocatedBytesEstimate >= minimumBytes &&
            !classified.contains { candidate.relativePath.hasPrefix($0 + "/") }
        }.sorted { $0.allocatedBytesEstimate == $1.allocatedBytesEstimate ? $0.relativePath < $1.relativePath : $0.allocatedBytesEstimate > $1.allocatedBytesEstimate }
        guard offset <= rows.count else { throw ShouError("invalid_argument", "Opportunity offset exceeds result count.") }
        let end=min(rows.count, offset + limit)
        return RuleOpportunityPage(scanId: scan.id, workspaceId: scan.workspace.id, rootRef: scan.workspace.rootRef, status: scan.status,
            items: rows[offset..<end].map { row in
                RuleOpportunity(relativePath: row.relativePath, absolutePath: URL(fileURLWithPath: scan.workspace.path).appendingPathComponent(row.relativePath).path,
                    allocatedBytesEstimate: row.allocatedBytesEstimate, complete: tree.isComplete(at: row.relativePath),
                    containsCoveredDescendants: classified.contains { $0.hasPrefix(row.relativePath + "/") }, eligible: false)
            }, totalCount: rows.count, nextOffset: end < rows.count ? end : nil)
    }
}
