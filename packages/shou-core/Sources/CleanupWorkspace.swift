import Foundation

public enum CleanupDisposition: String, Codable, CaseIterable, Sendable {
    case recommended, decision, protected
}

/// Read-only presentation of existing eligibility. Keeping or selecting a row
/// never changes the underlying scan or grants execution authority.
public struct CleanupReviewItem: Sendable, Identifiable {
    public let source: CleanupSource
    public let title: String
    public let category: String
    public var id: String { source.id }
    public var disposition: CleanupDisposition {
        guard source.selectable else { return .protected }
        return source.candidate.eligible && !source.requiresManualReview && source.recommendationEligible && source.candidate.risk != "high" ? .recommended : .decision
    }
}

extension CleanupReview {
    public var reviewItems: [CleanupReviewItem] {
        categories.flatMap { category in
            category.groups.flatMap { group in
                group.sources.map { CleanupReviewItem(source: $0, title: group.title, category: category.id) }
            }
        }.sorted {
            let left=$0.source.candidate.allocatedBytesEstimate, right=$1.source.candidate.allocatedBytesEstimate
            return left == right ? $0.source.path < $1.source.path : left > right
        }
    }
}

public struct CleanupVolumeObservation: Codable, Sendable, Identifiable {
    public var id: UInt64 { device }
    public let device: UInt64
    public let path: String
    public let availableBefore: Int64?
    public let availableAfter: Int64?
    public var change: Int64? {
        guard let availableBefore, let availableAfter, availableBefore >= 0, availableAfter >= 0 else { return nil }
        return availableAfter-availableBefore
    }

    /// One observation window per device. Sequential receipt deltas overlap
    /// background writes; summing them or summing devices would imply causality.
    public static func from(_ receipts: [ExecutionReceipt]) -> [CleanupVolumeObservation] {
        var seen=Set<String>()
        let unique=receipts.filter { seen.insert($0.id).inserted }
        return Dictionary(grouping: unique, by: { $0.workspace.identity.device }).map { device, values in
            let ordered=values.enumerated().sorted {
                $0.element.createdAt == $1.element.createdAt ? $0.offset < $1.offset : $0.element.createdAt < $1.element.createdAt
            }.map(\.element)
            let complete=ordered.allSatisfy { $0.volumeAvailableBefore != nil && $0.volumeAvailableAfter != nil }
            return CleanupVolumeObservation(device: device, path: ordered[0].workspace.path,
                availableBefore: complete ? ordered.first?.volumeAvailableBefore : nil,
                availableAfter: complete ? ordered.last?.volumeAvailableAfter : nil)
        }.sorted { $0.device < $1.device }
    }
}
