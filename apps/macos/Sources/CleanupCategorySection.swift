import SwiftUI
import ShouCore

struct CleanupCategorySection: View {
    @Bindable var model: AppModel
    let category: CleanupReviewCategory
    let groups: [CleanupRuleGroup]
    let title: String
    let symbol: String
    let searching: Bool
    @State private var expanded=false
    private var sources: [CleanupSource] { groups.flatMap(\.sources) }
    private var selectable: [CleanupSource] { sources.filter(\.selectable) }
    private var selected: [CleanupSource] { selectable.filter { model.commonSelection.contains($0.id) } }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded || searching }, set: { expanded=$0 })) {
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Divider().opacity(0.5)
                    CommonRuleRow(model: model, group: group).padding(.horizontal, 8)
                }
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 16) {
                SelectionCheckbox(state: selected.isEmpty ? .off : selected.count == selectable.count ? .on : .mixed,
                    enabled: !model.busy && !selectable.isEmpty, label: model.t("Select") + " " + title,
                    identifier: "smart.category." + category.id) {
                    model.selectCommon(selectable, selected: selected.count != selectable.count)
                }.frame(width: 22, height: 24)
                Image(systemName: symbol).font(.system(size: 22, weight: .regular))
                    .foregroundStyle(ShouPalette.secondary).frame(width: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: ShouDesign.bodyFontSize, weight: .medium))
                    Text(String(format: model.t("%lld locations"), locale: model.language.locale, sources.count))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(model.bytes(sources.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate }))
                        .font(.system(size: 16, weight: .medium)).monospacedDigit()
                    if !selected.isEmpty {
                        Text(model.t("Selected") + " " + model.bytes(selected.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate }))
                            .font(ShouType.caption).foregroundStyle(ShouPalette.secondary).monospacedDigit()
                    }
                }
            }.padding(.vertical, 5)
        }
        .padding(18).modifier(WorkspaceSurface())
        .accessibilityIdentifier("smart.category-section." + category.id)
    }
}
