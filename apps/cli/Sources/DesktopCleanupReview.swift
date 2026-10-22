import Foundation
import ShouCore

/// Uses the same evidence projection as macOS. Paging never changes selection
/// eligibility or grants authority to execute a cleanup.
enum DesktopCleanupReview {
    static func page(input: JSONValue, engine: ShouEngine) async throws -> JSONValue {
        func invalid() -> ShouError { ShouError("invalid_argument", "Invalid cleanup review query.") }
        guard let values=input["scan_ids"]?.array, (1...500).contains(values.count),
              values.allSatisfy({ $0.string?.isEmpty == false }),
              Set(values.compactMap(\.string)).count == values.count else { throw invalid() }
        let ids=values.compactMap(\.string).sorted()
        var snapshots=[ScanSnapshot]()
        for id in ids {
            try Task.checkCancellation()
            snapshots.append(try await engine.scanSnapshot(id))
        }
        var refinements=[CleanupTargetRefinement]()
        if let value=input["refinements"] {
            guard let items=value.array, items.count <= 500 else { throw invalid() }
            for item in items {
                guard let original=item["original_scan_id"]?.string, let candidate=item["candidate_id"]?.string,
                      let updated=item["scan_id"]?.string, ids.contains(original), ids.contains(updated), !candidate.isEmpty,
                      !refinements.contains(where: { $0.originalSnapshotId == original && $0.candidateId == candidate }) else { throw invalid() }
                refinements.append(CleanupTargetRefinement(originalSnapshotId: original, candidateId: candidate, snapshotId: updated))
            }
        }
        func text(_ key: String) throws -> String {
            guard let value=input[key] else { return "" }
            guard let text=value.string, text.utf8.count <= 1024 else { throw invalid() }
            return text
        }
        let query=try text("query"), categoryID=try text("category_id"), groupID=try text("group_id")
        let offset: Int
        if let value=input["offset"] {
            guard case .integer(let count)=value, (0...1_000_000).contains(count) else { throw invalid() }
            offset=Int(count)
        } else { offset=0 }
        let recommendedOnly: Bool
        if let value=input["recommended_only"] {
            guard case .bool(let flag)=value else { throw invalid() }
            recommendedOnly=flag
        } else { recommendedOnly=false }
        let digest=try Digest.of(JSONValue.object(["scan_ids": .array(ids.map(JSONValue.string)),
            "refinements": input["refinements"] ?? .array([]), "query": .string(query),
            "category_id": .string(categoryID), "group_id": .string(groupID), "recommended_only": .bool(recommendedOnly)]))
        if offset > 0 || input["query_digest"] != nil {
            guard input["query_digest"]?.string == digest else { throw ShouError("plan_stale", "Cleanup review query changed. Load its first page again.") }
        }
        let review=try CleanupReview(snapshots: snapshots, locations: await engine.knownLocations(), refinements: refinements)
        let recommended=Set(review.recommendedSources.map(\.id))
        var categories=[JSONValue](), matches=[JSONValue]()
        var totalCount=0
        for category in review.categories {
            var groups=[JSONValue]()
            for group in category.groups {
                try Task.checkCancellation()
                groups.append(.object(["id": .string(group.id), "title": .string(group.title),
                    "count": .integer(Int64(group.sources.count)), "bytes": .integer(group.bytes),
                    "selectable_count": .integer(Int64(group.sources.filter(\.selectable).count)),
                    "recommended_count": .integer(Int64(group.sources.filter { recommended.contains($0.id) }.count))]))
                guard (categoryID.isEmpty || categoryID == category.id), (groupID.isEmpty || groupID == group.id) else { continue }
                for source in group.sources {
                    if totalCount % 500 == 0 { try Task.checkCancellation() }
                    guard !recommendedOnly || recommended.contains(source.id) else { continue }
                    let searchable=[source.path, group.title, source.candidate.risk] + source.candidate.reasons
                    guard query.isEmpty || searchable.contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { continue }
                    defer { totalCount += 1 }
                    guard totalCount >= offset, matches.count < 500 else { continue }
                    matches.append(.object(["key": .string(source.id), "scan_id": .string(source.snapshotId),
                        "workspace_id": .string(source.workspace.id), "root_path": .string(source.workspace.path),
                        "candidate": try .from(source.candidate), "selectable": .bool(source.selectable),
                        "recommended": .bool(recommended.contains(source.id)), "file_count": .integer(Int64(source.fileCount)),
                        "category_id": .string(category.id), "group_id": .string(group.id), "group_title": .string(group.title)]))
                }
            }
            categories.append(.object(["id": .string(category.id), "bytes": .integer(category.bytes), "groups": .array(groups)]))
        }
        guard categoryID.isEmpty || review.categories.contains(where: { $0.id == categoryID }),
              groupID.isEmpty || review.categories.contains(where: { category in
                  (categoryID.isEmpty || categoryID == category.id) && category.groups.contains(where: { $0.id == groupID })
              }), offset <= totalCount else { throw invalid() }
        return .object(["categories": .array(categories), "sources": .array(matches), "total_count": .integer(Int64(totalCount)),
            "bytes": .integer(review.bytes), "query_digest": .string(digest),
            "next_offset": offset + matches.count < totalCount ? .integer(Int64(offset + matches.count)) : .null])
    }
}
