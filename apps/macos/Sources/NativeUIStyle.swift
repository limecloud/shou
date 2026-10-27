import AppKit
import SwiftUI

/// Shared typography and semantic colors for native working pages.
enum ShouType {
    static let title = Font.system(size: ShouDesign.toolTitleSize, weight: .semibold)
    static let body = Font.system(size: ShouDesign.bodyFontSize)
    static let caption = Font.system(size: ShouDesign.captionFontSize)
    static let code = Font.system(size: ShouDesign.captionFontSize, design: .monospaced)
}

enum ShouPalette {
    static let text = adaptive(ShouDesign.textLight, ShouDesign.textDark)
    static let secondary = adaptive(ShouDesign.textSecondaryLight, ShouDesign.textSecondaryDark)
    static let accent = adaptive(ShouDesign.accent, ShouDesign.accentDark)
    static let surface = adaptive(ShouDesign.surfaceLight, ShouDesign.surfaceDark)
    static let inset = adaptive(ShouDesign.tableStripeLight, ShouDesign.tableStripeDark)
    static let selection = adaptive(ShouDesign.navSelectionLight, ShouDesign.navSelectionDark)
    static let border = adaptive(ShouDesign.dividerLight, ShouDesign.dividerDark)
    static let success = adaptive(ShouDesign.successLight, ShouDesign.successDark)
    static let warning = adaptive(ShouDesign.warningLight, ShouDesign.warningDark)
    static let danger = adaptive(ShouDesign.dangerLight, ShouDesign.dangerDark)

    private static func adaptive(_ light: Color, _ dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

struct ShouDivider: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(ShouPalette.border)
            .frame(width: vertical ? ShouDesign.hairlineWidth : nil,
                   height: vertical ? nil : ShouDesign.hairlineWidth)
            .accessibilityHidden(true)
    }
}
