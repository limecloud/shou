import AppKit
import ShouCore
import SwiftUI

struct ApplicationsWorkspaceView: View {
    @Bindable var model: AppModel
    @Bindable var updates: PackageUpdatesSession

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker(model.t("Software source"), selection: $updates.source) {
                    Text(model.t("Applications")).tag("applications")
                    Text("Homebrew").tag("homebrew")
                    Text("mise").tag("mise")
                }.pickerStyle(.segmented).frame(maxWidth: 360).disabled(model.busy)
                    .accessibilityIdentifier("applications.source")
                Spacer()
            }.padding(.horizontal, ShouDesign.workspaceInset)
            if updates.source == "applications" {
                ApplicationsView(model: model, session: model.applicationsSession)
            } else {
                PackageUpdatesView(model: model, session: updates)
            }
        }.padding(.top, 8).font(ShouType.body).foregroundStyle(ShouPalette.text).tint(ShouPalette.accent)
            .onChange(of: updates.source) { _, _ in updates.changeSource() }
    }
}

private struct PackageUpdatesView: View {
    var model: AppModel
    @Bindable var session: PackageUpdatesSession
    @State private var search=""
    @State private var updatesOnly=false
    private var items: [PackageUpdateItem] {
        if let plan=session.plan { return plan.items }
        return (session.inventory?.items ?? []).filter { item in
            (!updatesOnly || item.canUpgrade) && (search.isEmpty || [item.name,item.token,item.summary ?? ""].contains { $0.localizedStandardContains(search) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var title: String { session.source == "mise" ? "mise" : "Homebrew" }
    private var hasContent: Bool { session.inventory != nil || !session.results.isEmpty }

    var body: some View {
        if !hasContent && !session.loading {
            WorkspaceStartPage(eyebrow: title, title: model.t("Keep your tools up to date."),
                subtitle: model.t(session.source == "mise" ? "Review globally configured developer tools without changing project versions." : "Review installed Formula and Cask packages, compare versions, then choose what to upgrade."),
                kind: session.source == "mise" ? .projects : .applications,
                footnote: model.t("Uses package manager metadata, which may be cached. Upgrades start only after your confirmation.")) {
                    VStack(spacing: 12) {
                        Button { session.load(app: model) } label: { Label(model.t("Check Software Updates"), systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(model.busy).accessibilityIdentifier("packages.check")
                        if let failure=session.failure {
                            Text(model.t(failure)).foregroundStyle(ShouPalette.warning).multilineTextAlignment(.center)
                            Link(model.t("Open Official Website"), destination: URL(string: session.source == "mise" ? "https://mise.jdx.dev/getting-started.html" : "https://brew.sh")!)
                        }
                    }
                }
        } else {
            VStack(spacing: 12) {
                toolbar
                if let failure=session.failure { Text(model.t(failure)).foregroundStyle(ShouPalette.warning).frame(maxWidth: .infinity, alignment: .leading) }
                if session.plan != nil { reviewNotice }
                if !session.results.isEmpty { results }
                else if session.loading && session.inventory == nil {
                    Spacer(); ProgressView(model.t("Checking installed software…")); Spacer()
                } else {
                    packageList
                }
                footer
            }.padding(.horizontal, ShouDesign.workspaceInset).padding(.bottom, 12)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(ShouType.body.weight(.semibold))
                if let inventory=session.inventory {
                    Text(inventory.issue == nil ? String(format: model.t("%lld installed, %lld updates"), inventory.items.count, inventory.items.filter(\.canUpgrade).count) : model.t("Update status unknown"))
                        .foregroundStyle(ShouPalette.secondary).font(ShouType.body)
                    Text(model.t("Last checked") + ": " + model.date(inventory.observedAt)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
            }
            Spacer(minLength: 8)
            if session.loading {
                ProgressView().controlSize(.small)
                Button(model.t("Stop")) { session.stop() }
            } else {
                TextField(model.t("Search packages"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .disabled(session.plan != nil).accessibilityIdentifier("packages.search")
                Toggle(model.t("Updates Only"), isOn: $updatesOnly).toggleStyle(.button).disabled(session.plan != nil)
                    .accessibilityIdentifier("packages.updates-only")
                Button { session.load(app: model) } label: { Label(model.t("Check Again"), systemImage: "arrow.clockwise") }
                    .disabled(model.busy || session.plan != nil).accessibilityIdentifier("packages.refresh")
            }
        }
    }

    private var packageList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.t("Name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(model.t("Version")).frame(width: 210, alignment: .leading)
                Text(model.t("Kind")).frame(width: 94, alignment: .leading)
                Text(model.t("Actions")).frame(width: 90)
            }.font(ShouType.caption).foregroundStyle(ShouPalette.secondary).padding(14)
            ShouDivider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Toggle(item.name, isOn: Binding(get: { session.selection.contains(item.id) }, set: { value in
                                if value { session.selection.insert(item.id) } else { session.selection.remove(item.id) }
                            })).labelsHidden().toggleStyle(.checkbox)
                                .disabled(!item.canUpgrade || model.busy || session.plan != nil)
                                .accessibilityLabel(item.name).accessibilityIdentifier("packages.select." + item.id)
                            Image(systemName: item.kind == "cask" ? "app.dashed" : "shippingbox").font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                                .frame(width: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).fontWeight(.medium)
                                if let summary=item.summary { Text(summary).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineLimit(2) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.installedVersion).lineLimit(1).truncationMode(.middle).help(item.installedVersion)
                                if let version=item.availableVersion, item.canUpgrade {
                                    Label(version, systemImage: "arrow.right").foregroundStyle(.tint).fontWeight(.semibold)
                                        .lineLimit(1).truncationMode(.middle).help(version)
                                } else if item.isPinned { Text(model.t("Pinned version")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                            }.monospacedDigit().frame(width: 210, alignment: .leading)
                            Text(model.t(item.kind == "dependency" ? "Dependency" : item.kind == "formula" ? "Formula" : item.kind == "cask" ? "Cask" : "Tool"))
                                .font(ShouType.body).foregroundStyle(ShouPalette.secondary).frame(width: 94, alignment: .leading)
                            Button(model.t("Upgrade…")) { session.prepare([item.id], app: model) }
                                .disabled(!item.canUpgrade || model.busy || session.plan != nil).frame(width: 90)
                                .accessibilityIdentifier("packages.upgrade." + item.id)
                        }.padding(14)
                        ShouDivider().padding(.leading, 52)
                    }
                }
            }.overlay {
                if items.isEmpty { WorkspaceEmptyState(title: model.t(updatesOnly ? "No upgradable packages in this result" : "No matching packages"), kind: .applications) }
            }
        }.modifier(WorkspaceSurface())
    }

    private var reviewNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.app").font(ShouType.title).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.t("Review these software upgrades")).font(ShouType.body.weight(.semibold))
                Text(model.t("The package manager may download files, run installation scripts and change dependencies. Close affected apps and save your work. Shou will not automatically accept agreements, request an administrator password, or restart the computer."))
                    .font(ShouType.body).fixedSize(horizontal: false, vertical: true)
                if session.source == "mise" { Text(model.t("Only global tools configured for latest are eligible. Project versions and lockfiles stay outside this operation.")).font(ShouType.body) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceSurface())
            .accessibilityIdentifier("packages.review")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if session.plan != nil {
                Spacer()
                Button(model.t("Cancel")) { session.plan=nil }.disabled(model.busy)
                Button(model.t("Confirm Upgrade")) { session.execute(app: model) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                    .accessibilityIdentifier("packages.confirm")
            } else if !session.results.isEmpty {
                Text(model.t("Check installed versions again before another upgrade.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                Spacer()
                Button(model.t("Check Again")) { session.load(app: model) }.buttonStyle(.borderedProminent).disabled(model.busy)
            } else {
                Text(String(format: model.t("%lld selected"), session.selection.count)).foregroundStyle(ShouPalette.secondary)
                Spacer()
                Button(model.t("Review All Updates…")) { session.prepare(Set((session.inventory?.items ?? []).filter(\.canUpgrade).map(\.id)), app: model) }
                    .disabled(model.busy || !(session.inventory?.items.contains(where: \.canUpgrade) ?? false)).accessibilityIdentifier("packages.review-all")
                Button(model.t("Review Selected Updates…")) { session.prepare(session.selection, app: model) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || session.selection.isEmpty)
                    .accessibilityIdentifier("packages.review-selected")
            }
        }.padding(.vertical, 8)
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.t("Software update results")).font(ShouType.body.weight(.semibold)).padding(16)
                ForEach(Array(session.results.enumerated()), id: \.offset) { _, result in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: result.state == "succeeded" ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(result.state == "succeeded" ? ShouPalette.success : ShouPalette.warning)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.item.name).fontWeight(.medium)
                            Text(model.t(result.state == "succeeded" ? "Installed version verified after upgrade." : result.state == "skipped" ? "Upgrade not started." : result.state == "failed" ? "The upgrade was blocked before installation. Check again before retrying." : "The upgrade could not be verified. Some software may have changed; inspect the package manager before retrying."))
                                .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                        }
                        Spacer()
                        Text(result.item.availableVersion ?? "").monospacedDigit()
                    }.padding(16)
                    ShouDivider()
                }
            }
        }.modifier(WorkspaceSurface()).accessibilityIdentifier("packages.results")
    }
}

struct PackageUpgradeProgressView: View {
    var model: AppModel
    @Bindable var session: PackageUpdatesSession
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            OperationActivityArtwork(symbol: "arrow.down.app", stopped: model.stopRequested)
            Text(model.t(model.stopRequested ? "Stopping software upgrades…" : "Updating software…")).font(ShouType.title)
            if let progress=session.progress {
                Text(progress.currentName).font(ShouType.body.weight(.semibold)).textSelection(.enabled)
                ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).frame(maxWidth: 460)
                Text(String(format: model.t("%lld of %lld processed"), progress.completed, progress.total)).foregroundStyle(ShouPalette.secondary)
            } else { ProgressView() }
            Text(model.t("Stopping may leave the current package changed. Check its installed version before retrying."))
                .foregroundStyle(ShouPalette.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Button(model.t("Stop Upgrading")) { model.cancel() }.disabled(model.stopRequested)
                .accessibilityIdentifier("packages.stop")
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
