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
