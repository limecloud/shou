import AppKit
import SwiftUI

private struct DiskCapacity: Sendable {
    let name: String
    let total: Int64
    let available: Int64
    static func read(_ path: String) -> Self? {
        guard let values=try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total=values.volumeTotalCapacity, let available=values.volumeAvailableCapacity, total > 0 else { return nil }
        return Self(name: values.volumeName ?? "", total: Int64(total), available: Int64(available))
    }
}

struct DiskCapacityView: View {
    var model: AppModel
    var path="/System/Volumes/Data"
    @State private var capacity: DiskCapacity?
    var body: some View {
        HStack(spacing: 0) {
            if let capacity {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive").foregroundStyle(ShouPalette.secondary)
                    VStack(spacing: 3) {
                        HStack(spacing: 8) {
                            Text(capacity.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: model.t("%@ available"), model.bytes(capacity.available))).foregroundStyle(ShouPalette.secondary)
                        }.font(ShouType.caption)
                        ProgressView(value: Double(max(0, capacity.total - capacity.available)), total: Double(capacity.total))
                            .tint(ShouPalette.secondary).accessibilityLabel(model.t("Disk Usage"))
                    }
                }.frame(width: 190)
                    .accessibilityElement(children: .combine)
            }
        }
        .task(id: path) { await refresh() }
        .task(id: model.completion?.id) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await refresh() } }
    }
    private func refresh() async {
        let requested=path
        let value=await Task.detached(priority: .utility) { DiskCapacity.read(requested) }.value
        if path == requested { capacity=value }
    }
}
