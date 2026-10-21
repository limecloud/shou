import Foundation

public struct SpaceTile: Sendable, Identifiable {
    public let id: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public enum SpaceMap {
    /// Balanced partitions preserve area without dropping small entries. Layout
    /// coordinates use the caller's aspect ratio and are independent of SwiftUI.
    public static func layout(_ nodes: [StorageNode], width: Double, height: Double) -> [SpaceTile] {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return [] }
        let weighted=nodes.filter { $0.allocatedBytes > 0 }.sorted { $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes }
        var output: [SpaceTile]=[]
        func divide(_ values: ArraySlice<StorageNode>, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            guard let first=values.first else { return }
            if values.count == 1 { output.append(SpaceTile(id: first.path, x: x, y: y, width: w, height: h)); return }
            let total=values.reduce(0.0) { $0 + Double($1.allocatedBytes) }
            var sum=0.0, split=values.startIndex
            while split < values.endIndex-1 {
                let next=sum + Double(values[split].allocatedBytes)
                if split > values.startIndex && abs(sum-total/2) <= abs(next-total/2) { break }
                sum=next; split += 1
            }
            let fraction=sum/total
            if w >= h {
                divide(values[..<split], x, y, w*fraction, h)
                divide(values[split...], x+w*fraction, y, w*(1-fraction), h)
            } else {
                divide(values[..<split], x, y, w, h*fraction)
                divide(values[split...], x, y+h*fraction, w, h*(1-fraction))
            }
        }
        divide(weighted[...], 0, 0, width, height)
        return output
    }
}

public struct NestedSpaceTile: Sendable, Identifiable {
    public var id: String { tile.id }
    public let tile: SpaceTile
    public let depth: Int
    public let remainder: Bool
    public var aggregate: StorageMapAggregate? = nil
}

extension SpaceMap {
    public static func nested(_ nodes: [StorageNode], scope: StorageNode, width: Double, height: Double, aggregates: [StorageMapAggregate] = []) -> [NestedSpaceTile] {
        let children=Dictionary(grouping: nodes, by: { StorageIndex.parent($0.path) })
        let groups=Dictionary(grouping: aggregates, by: \.parentPath)
        let aggregateByID=Dictionary(uniqueKeysWithValues: aggregates.map { ($0.id,$0) })
        var output=[NestedSpaceTile]()
        func visit(_ parent: StorageNode, x: Double, y: Double, w: Double, h: Double, depth: Int) {
            guard w > 2, h > 2, depth < 32 else { return }
            var values=children[parent.path] ?? []
            values += (groups[parent.path] ?? []).map(\.node)
            guard !values.isEmpty else { return }
            let used=values.reduce(Int64(0)) { $0 + $1.allocatedBytes }
            let remainder=max(0, parent.allocatedBytes - used)
            let remainderID=parent.path + "/"
            if remainder > 0 { values.append(StorageNode(path: remainderID, kind: "remainder", logicalBytes: 0, allocatedBytes: remainder, fileCount: 0, newestModifiedNanoseconds: 0)) }
            for tile in layout(values, width: w, height: h) {
                let translated=SpaceTile(id: tile.id, x: x + tile.x, y: y + tile.y, width: tile.width, height: tile.height)
                output.append(NestedSpaceTile(tile: translated, depth: depth, remainder: tile.id == remainderID, aggregate: aggregateByID[tile.id]))
                if let child=values.first(where: { $0.path == tile.id }), child.kind == "directory", tile.width > 4, tile.height > 4 {
                    let header=tile.width > 64 && tile.height > 32 ? 13.0 : 0.0
                    visit(child, x: translated.x + 1, y: translated.y + header + 1, w: tile.width - 2, h: tile.height - header - 2, depth: depth + 1)
                }
            }
        }
        visit(scope, x: 0, y: 0, w: width, h: height, depth: 0)
        return output
    }
}
