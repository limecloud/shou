import SwiftUI

/// One continuous background behind navigation, landing artwork and working surfaces.
struct WorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        GeometryReader { geometry in
            let span=max(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(colors: scheme == .dark
                    ? [ShouDesign.heroStartDark, ShouDesign.canvasDark, ShouDesign.heroEndDark]
                    : [ShouDesign.heroStartLight, ShouDesign.canvasLight, ShouDesign.heroEndLight],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                if contrast != .increased {
                    RadialGradient(colors: [ShouDesign.artworkMint.opacity(scheme == .dark ? 0.13 : 0.32), .clear], center: .topLeading, startRadius: 0, endRadius: span * 0.75)
                    RadialGradient(colors: [ShouDesign.artworkBlue.opacity(scheme == .dark ? 0.1 : 0.32), .clear], center: .topTrailing, startRadius: 0, endRadius: span * 0.6)
                    RadialGradient(colors: [ShouDesign.artworkLilac.opacity(scheme == .dark ? 0.07 : 0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: span * 0.7)
                }
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
