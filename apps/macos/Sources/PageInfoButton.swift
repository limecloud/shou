import SwiftUI

struct PageInfoButton: View {
    let title: String
    let message: String
    @State private var presented=false

    var body: some View {
        Button { presented.toggle() } label: { Label(title, systemImage: "info.circle") }
            .labelStyle(.iconOnly).help(message).accessibilityLabel(title)
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(width: 340, alignment: .leading)
            }
    }
}
