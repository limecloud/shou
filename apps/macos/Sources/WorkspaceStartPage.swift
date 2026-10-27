import SwiftUI

/// Reuses composition and controls, while each page retains its own scan and safety decisions.
struct WorkspaceStartPage<Controls: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let kind: WorkspaceArtworkKind
    var footnote=""
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 20) {
                        if !eyebrow.isEmpty && !title.localizedCaseInsensitiveContains(eyebrow) { Text(eyebrow).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                        Text(title).font(ShouType.title)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        controls().padding(.top, 5)
                        if !footnote.isEmpty {
                            Text(footnote).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: 470, alignment: .leading).layoutPriority(1)
                    WorkspacePageArtwork(kind: kind).frame(width: geometry.size.width < 1100 ? 310 : 400, height: 330)
                }
                .frame(maxWidth: ShouDesign.homeMaxWidth)
                .padding(42)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}

struct WorkspaceEmptyState: View {
    let title: String
    var description=""
    let kind: WorkspaceArtworkKind
    var body: some View {
        VStack(spacing: 12) {
            WorkspacePageArtwork(kind: kind).frame(width: 190, height: 145)
            Text(title).font(ShouType.body.weight(.medium))
            if !description.isEmpty { Text(description).font(ShouType.body).foregroundStyle(ShouPalette.secondary).multilineTextAlignment(.center).frame(maxWidth: 440) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
