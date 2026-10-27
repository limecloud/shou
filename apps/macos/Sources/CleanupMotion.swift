import SwiftUI
import ShouCore

private struct ShouReduceMotionKey: EnvironmentKey {
    static let defaultValue=false
}

extension EnvironmentValues {
    var shouReduceMotion: Bool {
        get { self[ShouReduceMotionKey.self] }
        set { self[ShouReduceMotionKey.self]=newValue }
    }
}

@propertyWrapper struct ReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemPreference
    @Environment(\.shouReduceMotion) private var appPreference
    var wrappedValue: Bool { systemPreference || appPreference }
}

struct ActivityIndicator: View {
    let title: String
    @ReduceMotion private var reduceMotion

    var body: some View {
        if reduceMotion {
            Label(title, systemImage: "hourglass").accessibilityElement(children: .combine)
        } else {
            ProgressView(title)
        }
    }
}

struct CapacityValue: View {
    let bytes: Int64
    let measured: Bool
    @ReduceMotion private var reduceMotion

    private func formatted(unit: Bool) -> String {
        let formatter=ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting=false
        formatter.includesCount = !unit
        formatter.includesUnit=unit
        return formatter.string(fromByteCount: bytes)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(measured ? formatted(unit: false) : "—")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(measured ? bytes : 0)))
            Text(measured ? formatted(unit: true) : "")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShouPalette.secondary)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Double(ShouDesign.transitionDuration)), value: bytes)
        .animation(reduceMotion ? nil : .easeOut(duration: Double(ShouDesign.transitionDuration)), value: measured)
    }
}

struct CapacityDots: View {
    let segments: [(Int64, Color)]
    let scanning: Bool
    var body: some View { field.accessibilityHidden(true) }

    private var field: some View {
        var palette=[ShouPalette.secondary]
        var thresholds: [Double]=[]
        if !scanning {
            let total=segments.reduce(0.0) { $0 + Double(max(0, $1.0)) }
            var cumulative=0.0
            for segment in segments {
                cumulative += Double(max(0, segment.0))
                thresholds.append(total > 0 ? cumulative / total : 0)
                palette.append(segment.1.opacity(0.7))
            }
        }
        return Canvas { context, size in
            let step=max(7.0, Double(size.width) / 128.0), radius=2.2
            let columns=max(1, min(128, Int(Double(size.width) / step))), rows=12
            var paths=Array(repeating: Path(), count: palette.count)
            for column in 0..<columns {
                for row in 0..<rows {
                    let fraction=(Double(column * rows + row) + 0.5) / Double(columns * rows)
                    let rect=CGRect(x: Double(column) * step, y: Double(row) * step + 2, width: radius * 2, height: radius * 2)
                    var bucket=0
                    if !scanning, let index=thresholds.firstIndex(where: { fraction <= $0 }) {
                        bucket=index + 1
                    }
                    paths[bucket].addEllipse(in: rect)
                }
            }
            // Fill each category once, independent of the dot count.
            for index in paths.indices where !paths[index].isEmpty {
                context.fill(paths[index], with: context.resolve(.color(palette[index])))
            }
        }
    }
}

struct ScanActivity: View {
    var model: AppModel

    var body: some View {
        OperationProgressView(title: model.t(model.scanningCleanupPath != nil || model.scanningLocation == nil ? "Scanning this directory…" : "Scan Common Locations"),
            currentPath: model.scanProgress?.currentPath.isEmpty == false ? model.scanProgress?.currentPath ?? "" : model.scanningCleanupPath ?? model.scanningLocation?.path ?? model.workspace?.path ?? "",
            fraction: model.scanProgress?.fractionCompleted,
            stopRequested: model.stopRequested, stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping…"), onStop: model.cancel)
    }
}
