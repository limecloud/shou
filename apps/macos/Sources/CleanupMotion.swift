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
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: bytes)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: measured)
    }
}

struct CapacityDots: View {
    let segments: [(Int64, Color)]
    let scanning: Bool
    @ReduceMotion private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if scanning && !reduceMotion {
                // Only this decorative field redraws. The scan and its counts
                // advance independently; a sweep does not imply a percentage.
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                    field(phase: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.0) / 3.0)
                }.transition(.opacity)
            } else { field(phase: nil).transition(.opacity) }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: scanning)
            .accessibilityHidden(true)
    }

    private func field(phase: Double?) -> some View {
        // Explicit sRGB avoids resolving NSColor appearances for decorative dots.
        // Category colors are resolved once per path, only in the static field.
        let gray=colorScheme == .dark ? 0.46 : 0.66
        var palette=[Color(.sRGB, red: gray, green: gray, blue: gray, opacity: 0.55)]
        let levels=5
        var thresholds: [Double]=[]
        if scanning {
            for level in 1...levels {
                palette.append(Color(.sRGB, red: 0.78, green: 0.34, blue: 0.03,
                                     opacity: 0.15 + Double(level) / Double(levels) * 0.65))
            }
        } else {
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
                    if scanning, let phase {
                        let position=Double(column) / Double(columns) + Double(row) * 0.012
                        let distance=abs(position - (phase * 1.5 - 0.2))
                        let strength=max(0, 1 - distance / 0.18)
                        if strength > 0 { bucket=min(levels, max(1, Int(ceil(strength * Double(levels))))) }
                    } else if !scanning, let index=thresholds.firstIndex(where: { fraction <= $0 }) {
                        bucket=index + 1
                    }
                    paths[bucket].addEllipse(in: rect)
                }
            }
            // At most six fills per animated frame, independent of the dot count.
            for index in paths.indices where !paths[index].isEmpty {
                context.fill(paths[index], with: context.resolve(.color(palette[index])))
            }
        }
    }
}

struct ScanActivity: View {
    var model: AppModel
    @ReduceMotion private var reduceMotion
    private var stage: Int { model.scanProgress?.stage == "saving" ? 2 : model.scanProgress?.stage == "analysis" ? 1 : 0 }
    private let stages=["Discover files", "Match rules", "Save results"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.scanningLocation == nil { HStack(spacing: 22) {
                ForEach(stages.indices, id: \.self) { index in
                    HStack(spacing: 7) {
                        Image(systemName: index < stage ? "checkmark.circle.fill" : index == stage ? "circle.inset.filled" : "circle")
                        Text(model.t(stages[index]))
                    }.foregroundStyle(index <= stage ? Color.accentColor : Color.secondary)
                }
                Spacer(minLength: 0)
            }.font(.system(size: 12, weight: .medium))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.t("Scan progress"))
                .accessibilityValue(model.t(stages[stage]))
                .accessibilityIdentifier("scan.stage")
            }
            OperationProgressView(title: model.t(model.scanningLocation == nil ? stages[stage] : "Scan Common Locations"),
                subtitle: model.scanningLocation.map { model.t($0.title) + " · " + model.t(stages[stage]) } ?? "",
                currentPath: model.scanProgress?.currentPath.isEmpty == false ? model.scanProgress?.currentPath ?? "" : model.scanningLocation?.path ?? model.workspace?.path ?? "",
                countText: String(format: model.t("%lld items discovered"), locale: model.language.locale, model.scanEntryCount),
                fraction: model.scanProgress?.fractionCompleted,
                stopRequested: model.stopRequested, stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping…"), onStop: model.cancel)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
