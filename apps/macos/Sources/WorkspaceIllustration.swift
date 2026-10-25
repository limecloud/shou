import SwiftUI

/// Original, resolution-independent artwork. Decorative layers never represent scan evidence.
struct WorkspaceIllustration: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let scale=min(geometry.size.width / 440, geometry.size.height / 330)
            artwork
                .frame(width: 440, height: 330)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true).allowsHitTesting(false)
    }

    private var artwork: some View {
        ZStack {
            Ellipse().fill(ShouDesign.artworkTeal.opacity(scheme == .dark ? 0.22 : 0.12))
                .frame(width: 290, height: 38).blur(radius: 15).offset(x: 14, y: 116)
            Ellipse().stroke(ShouDesign.artworkTeal.opacity(0.14), lineWidth: 1)
                .frame(width: 365, height: 205).rotationEffect(.degrees(-23)).offset(x: 7, y: 6)
            Ellipse().trim(from: 0.12, to: 0.68).stroke(ShouDesign.artworkBlue.opacity(0.5), lineWidth: 1)
                .frame(width: 395, height: 245).rotationEffect(.degrees(20)).offset(x: 2, y: 3)

            // The back panel, loose documents, and translucent front create depth without a bitmap.
            FolderSilhouette()
                .fill(LinearGradient(colors: [ShouDesign.artworkTeal, ShouDesign.artworkDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { FolderSilhouette().stroke(ShouDesign.artworkPaper.opacity(0.45), lineWidth: 1) }
                .frame(width: 240, height: 170).rotationEffect(.degrees(-8)).offset(x: 8, y: 28)
                .shadow(color: ShouDesign.artworkInk.opacity(0.18), radius: 18, y: 18)

            document(symbol: "curlybraces", tint: ShouDesign.artworkLilac)
                .rotationEffect(.degrees(-19)).offset(x: -48, y: -22)
            document(symbol: "photo", tint: ShouDesign.artworkBlue)
                .rotationEffect(.degrees(12)).offset(x: 43, y: -40)

            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(stops: [
                    .init(color: ShouDesign.artworkPaper.opacity(0.88), location: 0),
                    .init(color: ShouDesign.artworkMint.opacity(0.94), location: 0.36),
                    .init(color: ShouDesign.artworkTeal, location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(LinearGradient(colors: [ShouDesign.artworkPaper, ShouDesign.artworkMint.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                }
                .overlay(alignment: .top) {
                    Capsule().fill(ShouDesign.artworkPaper.opacity(0.65)).frame(width: 182, height: 2).padding(.top, 8)
                }
                .overlay {
                    Image(systemName: "sparkles").font(.system(size: 37, weight: .light))
                        .foregroundStyle(ShouDesign.artworkPaper.opacity(0.85)).offset(x: 54, y: 10)
                }
                .frame(width: 247, height: 140)
                .rotationEffect(.degrees(-8)).offset(x: 19, y: 66)
                .shadow(color: ShouDesign.artworkDeep.opacity(0.18), radius: 20, y: 18)

            floatingTile("square.grid.2x2.fill", tint: ShouDesign.artworkBlue, size: 55)
                .rotationEffect(.degrees(-13)).offset(x: -134, y: -61)
            floatingTile("terminal", tint: ShouDesign.artworkLilac, size: 47)
                .rotationEffect(.degrees(14)).offset(x: 139, y: 22)

            Image(systemName: "sparkle").font(.system(size: 23, weight: .light))
                .foregroundStyle(ShouDesign.artworkTeal).offset(x: 120, y: -112)
            Image(systemName: "sparkle").font(.system(size: 13, weight: .light))
                .foregroundStyle(ShouDesign.artworkTeal.opacity(0.7)).offset(x: -148, y: 64)
            Circle().fill(ShouDesign.artworkMint).frame(width: 8, height: 8).offset(x: -101, y: -122)
            Circle().fill(ShouDesign.artworkLilac).frame(width: 6, height: 6).offset(x: 165, y: -57)
        }
    }

    private func document(symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(ShouDesign.artworkDeep)
                .frame(width: 47, height: 43).background(tint.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            Capsule().fill(tint).frame(width: 67, height: 5)
            Capsule().fill(tint.opacity(0.6)).frame(width: 50, height: 5)
            Capsule().fill(tint.opacity(0.4)).frame(width: 59, height: 5)
            Spacer(minLength: 0)
        }
        .padding(15).frame(width: 107, height: 146)
        .background(LinearGradient(colors: [ShouDesign.artworkPaper, tint.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(ShouDesign.artworkPaper.opacity(0.9), lineWidth: 1) }
        .shadow(color: ShouDesign.artworkInk.opacity(0.12), radius: 12, y: 6)
    }

    private func floatingTile(_ symbol: String, tint: Color, size: CGFloat) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(ShouDesign.artworkDeep)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [ShouDesign.artworkPaper, tint], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay { RoundedRectangle(cornerRadius: size * 0.28).stroke(ShouDesign.artworkPaper.opacity(0.85), lineWidth: 1) }
            .shadow(color: ShouDesign.artworkInk.opacity(0.12), radius: 10, y: 8)
    }
}

private struct FolderSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.height * 0.14))
            path.addQuadCurve(to: CGPoint(x: rect.width * 0.08, y: 0), control: .zero)
            path.addLine(to: CGPoint(x: rect.width * 0.35, y: 0))
            path.addCurve(to: CGPoint(x: rect.width * 0.5, y: rect.height * 0.13),
                          control1: CGPoint(x: rect.width * 0.43, y: 0), control2: CGPoint(x: rect.width * 0.43, y: rect.height * 0.13))
            path.addLine(to: CGPoint(x: rect.width * 0.92, y: rect.height * 0.13))
            path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height * 0.25), control: CGPoint(x: rect.width, y: rect.height * 0.13))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.9))
            path.addQuadCurve(to: CGPoint(x: rect.width * 0.92, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width * 0.08, y: rect.height))
            path.addQuadCurve(to: CGPoint(x: 0, y: rect.height * 0.9), control: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
    }
}

enum WorkspaceArtworkKind { case applications, projects, space, largeFiles, privacy, startup, rules, history, settings }

/// Small editorial illustrations for the three real destinations on the start page.
struct WorkspaceFeatureArtwork: View {
    let kind: WorkspaceArtworkKind

    var body: some View {
        ZStack {
            switch kind {
            case .applications:
                tile("curlybraces", color: ShouDesign.artworkLilac).rotationEffect(.degrees(-15)).offset(x: -20, y: -7)
                tile("square.grid.2x2.fill", color: ShouDesign.artworkMint).rotationEffect(.degrees(8)).offset(x: 16, y: 8)
            case .space:
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 7).fill(ShouDesign.artworkTeal.gradient).frame(width: 33, height: 56)
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6).fill(ShouDesign.artworkBlue.gradient).frame(width: 29, height: 29)
                        RoundedRectangle(cornerRadius: 5).fill(ShouDesign.artworkLilac.gradient).frame(width: 29, height: 23)
                    }
                }.padding(7).background(ShouDesign.artworkPaper, in: RoundedRectangle(cornerRadius: 14))
                    .rotationEffect(.degrees(-8))
                    .shadow(color: ShouDesign.artworkInk.opacity(0.1), radius: 8, y: 5)
            case .rules:
                RoundedRectangle(cornerRadius: 10).fill(ShouDesign.artworkLilac.opacity(0.5)).frame(width: 48, height: 61).rotationEffect(.degrees(-17)).offset(x: -9)
                VStack(spacing: 8) {
                    ruleLine(width: 32, knob: 8)
                    ruleLine(width: 32, knob: -7)
                    ruleLine(width: 32, knob: 4)
                }.frame(width: 50, height: 63)
                    .background(LinearGradient(colors: [ShouDesign.artworkPaper, ShouDesign.artworkBlue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
                    .rotationEffect(.degrees(8)).offset(x: 10, y: 4)
                    .shadow(color: ShouDesign.artworkInk.opacity(0.1), radius: 8, y: 5)
            default:
                WorkspacePageArtwork(kind: kind).frame(width: 110, height: 90)
            }
        }.frame(width: 110, height: 90).accessibilityHidden(true).allowsHitTesting(false)
    }

    private func tile(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(ShouDesign.artworkDeep)
            .frame(width: 52, height: 55)
            .background(LinearGradient(colors: [ShouDesign.artworkPaper, color], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(ShouDesign.artworkPaper.opacity(0.8), lineWidth: 1) }
            .shadow(color: ShouDesign.artworkInk.opacity(0.1), radius: 8, y: 5)
    }

    private func ruleLine(width: CGFloat, knob: CGFloat) -> some View {
        Capsule().fill(ShouDesign.artworkTeal.opacity(0.45)).frame(width: width, height: 3)
            .overlay { Circle().fill(ShouDesign.artworkTeal).frame(width: 8, height: 8).offset(x: knob) }
    }
}
