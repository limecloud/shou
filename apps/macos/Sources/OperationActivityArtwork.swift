import SwiftUI

/// Files converge into a quiet intake. This decorative loop never represents
/// deleted items, elapsed time or measured completion.
struct OperationActivityArtwork: View {
    var symbol: String
    var stopped=false
    @ReduceMotion private var reduceMotion

    private var paused: Bool { stopped || reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: paused)) { timeline in
            let duration=Double(ShouDesign.cleanupMotionDuration)
            let phase=paused ? 0.35 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
            let width=ShouDesign.cleanupArtworkWidth
            ZStack {
                Circle().fill(ShouPalette.accent.opacity(0.035)).frame(width: width * 0.61)
                Circle().stroke(ShouPalette.accent.opacity(0.06), lineWidth: ShouDesign.hairlineWidth).frame(width: width * 0.48)
                Ellipse().fill(ShouPalette.accent.opacity(0.06))
                    .frame(width: width * 0.58, height: width * 0.14).offset(y: width * 0.17)
                    .blur(radius: width * 0.035)
                ForEach(0..<7) { index in
                    let progress=(phase + Double(index) / 7).truncatingRemainder(dividingBy: 1)
                    let travel=progress * progress
                    let side=index.isMultiple(of: 2) ? -1.0 : 1.0
                    let originX=side * (0.27 + Double(index % 3) * 0.065)
                    let originY = -0.24 + Double(index % 3) * 0.05
                    let opacity=min(1, progress / 0.12) * max(0, 1 - max(0, progress - 0.7) / 0.3)
                    Image(systemName: index.isMultiple(of: 3) ? "doc.fill" : "doc.text.fill")
                        .font(.system(size: width * 0.095, weight: .light))
                        .foregroundStyle(ShouPalette.accent.opacity(index.isMultiple(of: 2) ? 0.5 : 0.28))
                        .rotationEffect(.degrees(side * (18 - travel * 40)))
                        .scaleEffect(1 - travel * 0.82)
                        .offset(x: width * (originX * (1 - travel) + side * sin(progress * .pi) * 0.035),
                                y: width * (originY * (1 - travel) + 0.11 * travel))
                        .opacity(paused ? 0 : opacity)
                }
                Ellipse().fill(ShouPalette.accent.opacity(0.1))
                    .frame(width: width * 0.37, height: width * 0.075).offset(y: width * 0.115)
                Image(systemName: symbol == "trash" ? "tray.fill" : symbol)
                    .font(.system(size: width * 0.23, weight: .light))
                    .foregroundStyle(ShouPalette.accent.gradient)
                    .offset(y: width * 0.13)
                Ellipse().stroke(ShouPalette.accent.opacity(paused ? 0.12 : 0.12 + 0.1 * sin(phase * 2 * .pi)), lineWidth: ShouDesign.hairlineWidth)
                    .frame(width: width * 0.56, height: width * 0.15).offset(y: width * 0.165)
            }.frame(width: width, height: ShouDesign.cleanupArtworkHeight)
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
