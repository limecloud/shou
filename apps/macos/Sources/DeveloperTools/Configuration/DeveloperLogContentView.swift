import SwiftUI

struct DeveloperLogContentView: View {
    let text: String
    let emptyText: String
    let identifier: String

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Text(text.isEmpty ? emptyText : text)
                    .font(ShouType.code).textSelection(.enabled)
                    .frame(minWidth:max(0,geometry.size.width-24),minHeight:max(0,geometry.size.height-24),alignment:.topLeading)
                    .padding(12)
            }.accessibilityIdentifier(identifier)
        }.background(ShouPalette.inset)
    }
}
