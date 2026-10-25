import SwiftUI

/// A shared material language with a distinct, original composition for each task.
struct WorkspacePageArtwork: View {
    let kind: WorkspaceArtworkKind

    var body: some View {
        GeometryReader { geometry in
            scene.frame(width: 360, height: 280)
                .scaleEffect(min(geometry.size.width / 360, geometry.size.height / 280))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

    private var scene: some View {
        ZStack {
            Ellipse().fill(ShouDesign.artworkTeal.opacity(0.14)).frame(width: 230, height: 26).blur(radius: 14).offset(y: 102)
            Ellipse().stroke(ShouDesign.artworkTeal.opacity(0.16), lineWidth: 1)
                .frame(width: 300, height: 190).rotationEffect(.degrees(-22))
            composition
            Image(systemName: "sparkle").font(.system(size: 20, weight: .light)).foregroundStyle(ShouDesign.artworkTeal).offset(x: 132, y: -83)
            Circle().fill(ShouDesign.artworkLilac).frame(width: 7, height: 7).offset(x: -134, y: 54)
            Circle().fill(ShouDesign.artworkMint).frame(width: 6, height: 6).offset(x: -99, y: -96)
        }
    }

    @ViewBuilder private var composition: some View {
        switch kind {
        case .applications:
            panel(width: 172, height: 163, tint: ShouDesign.artworkLilac).rotationEffect(.degrees(-15)).offset(x: -30, y: -9)
            VStack(spacing: 13) {
                HStack(spacing: 13) { appTile("photo", ShouDesign.artworkBlue); appTile("curlybraces", ShouDesign.artworkLilac) }
                HStack(spacing: 13) { appTile("music.note", ShouDesign.artworkMint); appTile("envelope", ShouDesign.artworkBlue) }
            }.padding(21).background { panel(width: 172, height: 163, tint: ShouDesign.artworkMint) }
                .rotationEffect(.degrees(8)).offset(x: 18, y: 13)
        case .projects:
            panel(width: 169, height: 135, tint: ShouDesign.artworkLilac).rotationEffect(.degrees(13)).offset(x: 35, y: -25)
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(ShouDesign.artworkPaper.opacity(0.55)).frame(width: 6, height: 6) } }
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 39, weight: .light)).foregroundStyle(ShouDesign.artworkMint)
                Capsule().fill(ShouDesign.artworkPaper.opacity(0.45)).frame(width: 97, height: 4)
                Capsule().fill(ShouDesign.artworkMint.opacity(0.6)).frame(width: 71, height: 4)
            }.padding(22).frame(width: 194, height: 148, alignment: .leading)
                .background(LinearGradient(colors: [ShouDesign.artworkDeep, ShouDesign.artworkInk], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 19))
                .overlay { RoundedRectangle(cornerRadius: 19).stroke(ShouDesign.artworkPaper.opacity(0.5), lineWidth: 1) }
                .rotationEffect(.degrees(-9)).offset(x: -18, y: 8)
            badge("shippingbox", tint: ShouDesign.artworkMint).rotationEffect(.degrees(10)).offset(x: 94, y: 77)
        case .space:
            panel(width: 202, height: 163, tint: ShouDesign.artworkBlue).rotationEffect(.degrees(8)).offset(x: 13, y: -13)
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 10).fill(ShouDesign.artworkTeal.gradient).frame(width: 75, height: 118)
                VStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 9).fill(ShouDesign.artworkBlue.gradient).frame(width: 73, height: 61)
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 7).fill(ShouDesign.artworkLilac.gradient).frame(width: 33, height: 50)
                        RoundedRectangle(cornerRadius: 7).fill(ShouDesign.artworkMint.gradient).frame(width: 33, height: 50)
                    }
                }
            }.padding(18).background { panel(width: 191, height: 154, tint: ShouDesign.artworkPaper) }
                .rotationEffect(.degrees(-9)).offset(x: -12, y: 12)
            badge("internaldrive", tint: ShouDesign.artworkMint).rotationEffect(.degrees(9)).offset(x: 105, y: 76)
        case .largeFiles:
            document("photo", tint: ShouDesign.artworkLilac).rotationEffect(.degrees(-17)).offset(x: -40, y: -8)
            document("play.rectangle", tint: ShouDesign.artworkBlue).rotationEffect(.degrees(8)).offset(x: 27, y: -4)
            Image(systemName: "magnifyingglass").font(.system(size: 112, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [ShouDesign.artworkMint, ShouDesign.artworkTeal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: ShouDesign.artworkDeep.opacity(0.18), radius: 6, y: 7).rotationEffect(.degrees(-9)).offset(x: 76, y: 61)
        case .privacy:
            document("globe", tint: ShouDesign.artworkBlue).rotationEffect(.degrees(-16)).offset(x: -46, y: -8)
            ArtworkShield().fill(LinearGradient(colors: [ShouDesign.artworkPaper, ShouDesign.artworkMint, ShouDesign.artworkTeal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { ArtworkShield().stroke(ShouDesign.artworkPaper.opacity(0.9), lineWidth: 2) }
                .overlay { Image(systemName: "lock.fill").font(.system(size: 53, weight: .light)).foregroundStyle(ShouDesign.artworkDeep) }
                .frame(width: 144, height: 171).rotationEffect(.degrees(8)).offset(x: 28, y: 15)
                .shadow(color: ShouDesign.artworkDeep.opacity(0.18), radius: 15, y: 13)
            badge("checkmark", tint: ShouDesign.artworkLilac).offset(x: 111, y: 78)
        case .startup:
            panel(width: 166, height: 166, tint: ShouDesign.artworkBlue).rotationEffect(.degrees(-15)).offset(x: -20, y: -5)
            Image(systemName: "power").font(.system(size: 75, weight: .light)).foregroundStyle(ShouDesign.artworkDeep)
                .frame(width: 150, height: 150)
                .background(LinearGradient(colors: [ShouDesign.artworkPaper, ShouDesign.artworkMint], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 38))
                .overlay { RoundedRectangle(cornerRadius: 38).stroke(ShouDesign.artworkPaper, lineWidth: 2) }
                .rotationEffect(.degrees(8)).offset(x: 16, y: 15)
                .shadow(color: ShouDesign.artworkDeep.opacity(0.13), radius: 14, y: 13)
            badge("arrow.up.right", tint: ShouDesign.artworkLilac).rotationEffect(.degrees(-6)).offset(x: 106, y: -66)
        case .rules, .settings:
            panel(width: 151, height: 175, tint: ShouDesign.artworkLilac).rotationEffect(.degrees(-16)).offset(x: -28, y: -4)
            VStack(spacing: 23) {
                slider(knob: -27, tint: ShouDesign.artworkTeal)
                slider(knob: 28, tint: ShouDesign.artworkTeal)
                slider(knob: -5, tint: ShouDesign.artworkTeal)
            }.frame(width: 156, height: 175).background { panel(width: 156, height: 175, tint: ShouDesign.artworkBlue) }
                .rotationEffect(.degrees(8)).offset(x: 22, y: 9)
            badge(kind == .rules ? "checkmark" : "gearshape.fill", tint: ShouDesign.artworkMint).offset(x: 103, y: 75)
        case .history:
            document("checkmark", tint: ShouDesign.artworkBlue).rotationEffect(.degrees(-15)).offset(x: -30, y: -4)
            Circle().fill(LinearGradient(colors: [ShouDesign.artworkPaper, ShouDesign.artworkMint], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Circle().stroke(ShouDesign.artworkPaper, lineWidth: 2) }
                .overlay { Image(systemName: "clock").font(.system(size: 94, weight: .ultraLight)).foregroundStyle(ShouDesign.artworkDeep) }
                .frame(width: 144, height: 144).offset(x: 35, y: 28)
                .shadow(color: ShouDesign.artworkDeep.opacity(0.15), radius: 14, y: 12)
        }
    }

    private func panel(width: CGFloat, height: CGFloat, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(LinearGradient(colors: [ShouDesign.artworkPaper, tint], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(ShouDesign.artworkPaper.opacity(0.8), lineWidth: 1.5) }
            .frame(width: width, height: height)
            .shadow(color: ShouDesign.artworkInk.opacity(0.13), radius: 12, y: 10)
    }
    private func appTile(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(ShouDesign.artworkDeep)
            .frame(width: 55, height: 52).background(tint.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 27, weight: .medium)).foregroundStyle(ShouDesign.artworkDeep)
            .frame(width: 61, height: 61).background { panel(width: 61, height: 61, tint: tint) }
    }
    private func document(_ symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(ShouDesign.artworkDeep)
            Capsule().fill(tint).frame(width: 64, height: 5)
            Capsule().fill(tint.opacity(0.6)).frame(width: 49, height: 5)
            Capsule().fill(tint.opacity(0.4)).frame(width: 57, height: 5)
        }.frame(width: 118, height: 163).background { panel(width: 118, height: 163, tint: tint) }
    }
    private func slider(knob: CGFloat, tint: Color) -> some View {
        Capsule().fill(tint.opacity(0.25)).frame(width: 99, height: 5)
            .overlay { Circle().fill(tint.gradient).frame(width: 19, height: 19).overlay { Circle().stroke(ShouDesign.artworkPaper, lineWidth: 2) }.offset(x: knob) }
    }
}

private struct ArtworkShield: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.17), control: CGPoint(x: rect.width * 0.8, y: rect.height * 0.13))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.48))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.height * 0.77), control2: CGPoint(x: rect.width * 0.7, y: rect.height * 0.93))
            path.addCurve(to: CGPoint(x: 0, y: rect.height * 0.48), control1: CGPoint(x: rect.width * 0.3, y: rect.height * 0.93), control2: CGPoint(x: 0, y: rect.height * 0.77))
            path.addLine(to: CGPoint(x: 0, y: rect.height * 0.17))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: 0), control: CGPoint(x: rect.width * 0.2, y: rect.height * 0.13))
            path.closeSubpath()
        }
    }
}
