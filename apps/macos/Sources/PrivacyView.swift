import SwiftUI
import ShouCore

struct PrivacyView: View {
    var app: AppModel
    @Bindable var session: PrivacySession
    init(app: AppModel, session: PrivacySession) { self.app=app; self.session=session }
    var body: some View {
        pageContent
            .task(id: app.initializing) { if !app.initializing { session.loadHistory(app: app) } }
            .onChange(of: session.range) { _, _ in session.changeRange() }
            .onChange(of: session.allowCookieReview) { _, allowed in cookieReviewChanged(allowed) }
            .sheet(item: $session.plan) { plan in PrivacyConfirmation(app: app, session: session, plan: plan) }
            .toolbar { ToolbarItemGroup { header } }
    }
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.working {
                OperationProgressView(title: app.t(app.statusKey), symbol: "hand.raised.fill", currentPath: session.progress?.path ?? "",
                    countText: session.progress.map { String(format: app.t("%lld of %lld sources processed"), locale: app.language.locale, $0.processedCount, $0.itemCount) } ?? app.t("Preparing privacy sources…"),
                    fraction: session.progress.flatMap { $0.itemCount > 0 ? Double($0.processedCount) / Double($0.itemCount) : nil },
                    stopRequested: app.stopRequested, stopLabel: app.t("Stop"), stoppingLabel: app.t("Stopping…"), onStop: session.cancel)
            } else {
            deletionNotice
            timeControls
            selectionContent
            currentReceipt
            historyContent
            coverageFootnote
            }
        }.padding(16)
    }
    private var deletionNotice: some View {
        Text(app.t("Close the browser first. Cleaning permanently deletes selected database records. It does not move them to Trash or provide restore. No sources are selected automatically."))
            .font(.callout).foregroundStyle(.secondary)
    }
    @ViewBuilder private var selectionContent: some View {
        if let scan=session.scan {
            sourceSelection(scan)
        } else if !session.working && session.receipt == nil {
            emptyState
        }
    }
    private var emptyState: some View {
        ContentUnavailableView(app.t("Review privacy sources"), systemImage: "hand.raised", description: Text(app.t("Scan to see aggregate counts and availability. Browsing records are never displayed.")))
            .frame(maxHeight: .infinity)
    }
    @ViewBuilder private var currentReceipt: some View {
        if let receipt=session.receipt { receiptView(receipt) }
    }
    @ViewBuilder private var historyContent: some View {
        if !session.history.isEmpty { recentHistory }
    }
    private var coverageFootnote: some View {
        Text(app.t("Supported: standard Chrome, Chromium, Edge, Brave and Firefox profiles; Safari history. Safari cookies, site storage, saved passwords, autofill, custom profiles, extensions and cloud copies are not cleaned."))
            .font(.caption).foregroundStyle(.secondary)
    }
    private func cookieReviewChanged(_ allowed: Bool) {
        guard !allowed else { return }
        let cookieIDs=(session.scan?.sources ?? []).filter(\.requiresSignOutConsent).map(\.id)
        session.selected.subtract(cookieIDs); session.plan=nil
    }
    private var header: some View {
        HStack {
            PageInfoButton(title: app.t("Privacy"), message: app.t("Review browser activity and account data separately."))
            if !session.working { Button(app.t("Scan Privacy Sources")) { session.scan(app: app) }.disabled(app.busy).accessibilityIdentifier("privacy.scan") }
        }
    }
    private var timeControls: some View {
        HStack {
            Picker(app.t("Time range"), selection: $session.range) {
                ForEach(PrivacyTimeRange.allCases, id: \.self) { range in Text(rangeTitle(range)).tag(range) }
            }.frame(maxWidth: 300).disabled(app.busy)
            Text(app.t("History: visit time · Cookies: last access time")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func sourceSelection(_ scan: PrivacyScan) -> some View {
        sourceList(scan)
        cookieConsent
        selectionFooter
    }
    private func sourceList(_ scan: PrivacyScan) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(scan.sources) { source in sourceRow(source) }
            }
        }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }
    private var cookieConsent: some View {
        Toggle(app.t("I understand that clearing cookies can sign me out of websites."), isOn: $session.allowCookieReview)
            .toggleStyle(.checkbox).disabled(app.busy).accessibilityIdentifier("privacy.cookie-consent")
    }
    private var selectionFooter: some View {
        HStack {
            Text(selectionSummary).foregroundStyle(.secondary)
            Spacer()
            Button(app.t("Clear Selection")) { session.selected=[] }.disabled(app.busy || session.selected.isEmpty)
            Button(app.t("Review Permanent Deletion…")) { session.review(app: app) }
                .disabled(reviewDisabled)
                .buttonStyle(.borderedProminent).accessibilityIdentifier("privacy.review")
        }
    }
    private var selectionSummary: String {
        app.t("Selected") + " \(session.selected.count) · \(session.selectedCount) " + app.t("records")
    }
    private var reviewDisabled: Bool {
        app.busy || session.selected.isEmpty || (session.selectedSources.contains(where: \.requiresSignOutConsent) && !session.allowCookieReview)
    }
    private func receiptView(_ receipt: PrivacyReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(receipt.state == "completed" ? app.t("Privacy cleaning completed") : app.t("Some sources were not cleaned"), systemImage: receipt.state == "completed" ? "checkmark.circle" : "exclamationmark.triangle")
            ForEach(receipt.items) { item in
                receiptItemRow(item)
            }
        }.padding().background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
    private func receiptItemRow(_ item: PrivacyItemResult) -> some View {
        HStack {
            Text(item.sourceId).font(.caption.monospaced()).lineLimit(1)
            Spacer()
            Text("\(item.removedRecords) · " + item.state).font(.caption)
            if let reason=item.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var recentHistory: some View {
        DisclosureGroup(app.t("Recent privacy receipts")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.history.prefix(20)) { receipt in
                        historyReceipt(receipt)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
        }
    }
    private func historyReceipt(_ receipt: PrivacyReceipt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(app.date(receipt.createdAt) + " · " + receipt.state).font(.caption.bold())
            ForEach(receipt.items) { item in
                Text(historyItemText(item)).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
    private func historyItemText(_ item: PrivacyItemResult) -> String {
        var fields=[item.sourceId, String(item.removedRecords), item.state]
        if let reason=item.reason { fields.append(reason) }
        return fields.joined(separator: " · ")
    }
    private func sourceRow(_ source: PrivacySource) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: selectionBinding(source.id))
                .toggleStyle(.checkbox).labelsHidden().disabled(sourceDisabled(source)).accessibilityIdentifier("privacy.source.\(source.id)")
            Image(systemName: source.definition.kind == .cookies ? "person.crop.circle.badge.exclamationmark" : "clock.arrow.circlepath").font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.definition.browserName + " · " + source.definition.profile).font(.body.weight(.medium))
                Text(kindTitle(source.definition.kind)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(source.recordCount.map { String($0) } ?? "—").monospacedDigit()
            Text(statusTitle(source.status)).font(.caption).foregroundStyle(source.eligible ? Color.secondary : Color.orange).frame(width: 140, alignment: .trailing)
        }.padding(14).help(source.reason ?? "").overlay(alignment: .bottom) { Divider() }
    }
    private func selectionBinding(_ sourceID: String) -> Binding<Bool> {
        Binding(get: { session.selected.contains(sourceID) }, set: { selected in
            if selected { session.selected.insert(sourceID) } else { session.selected.remove(sourceID) }
        })
    }
    private func sourceDisabled(_ source: PrivacySource) -> Bool {
        !source.eligible || app.busy || (source.requiresSignOutConsent && !session.allowCookieReview)
    }
    private func rangeTitle(_ range: PrivacyTimeRange) -> String {
        switch range {
        case .lastHour: app.t("Last hour")
        case .lastDay: app.t("Last 24 hours")
        case .lastSevenDays: app.t("Last seven days")
        case .allTime: app.t("All time")
        }
    }
    private func kindTitle(_ kind: PrivacyDataKind) -> String {
        switch kind {
        case .history: app.t("Browsing history")
        case .cookies: app.t("Cookies · may sign you out")
        case .siteStorage: app.t("Site storage")
        case .passwords: app.t("Saved passwords")
        case .autofill: app.t("Autofill")
        }
    }
    private func statusTitle(_ status: PrivacySourceStatus) -> String {
        switch status {
        case .ready: app.t("Ready to review")
        case .empty: app.t("No matching records")
        case .browserRunning: app.t("Close browser first")
        case .permissionRequired: app.t("Access required")
        case .unsupported: app.t("Not supported")
        case .schemaUnsupported: app.t("Unsupported database")
        case .unavailable: app.t("Unavailable")
        }
    }
}

private struct PrivacyConfirmation: View {
    var app: AppModel
    var session: PrivacySession
    let plan: PrivacyPlan
    @State private var permanent=false
    @State private var signOut=false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            title
            scopeSummary
            impactNotice
            sources
            timeBounds
            consentControls
            actions
        }.padding(28).frame(width: 640)
    }
    private var title: some View {
        Label(app.t("Permanently delete privacy records?"), systemImage: "exclamationmark.triangle.fill")
            .font(.title2.bold()).foregroundStyle(.red)
    }
    private var scopeSummary: some View {
        Text("\(plan.sources.count) " + app.t("sources") + " · \(plan.recordCount) " + app.t("records"))
    }
    private var impactNotice: some View {
        Text(app.t("This cannot be undone through Shou. Each source commits separately; a failure may leave a partial result. Cloud-synced copies and other browser data remain outside this scope."))
            .font(.callout).foregroundStyle(.secondary)
    }
    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.sources) { source in
                    Text("\(source.definition.browserName) · \(source.definition.profile) · \(source.definition.kind.rawValue) · \(source.recordCount ?? 0)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 180)
    }
    private var timeBounds: some View {
        Text((plan.rangeStart.map { app.date($0) } ?? app.t("All time")) + " → " + app.date(plan.rangeEnd))
            .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var consentControls: some View {
        Toggle(app.t("I understand that deletion is permanent and has no restore."), isOn: $permanent).toggleStyle(.checkbox)
        if plan.requiresSignOutConsent {
            Toggle(app.t("I accept that websites may sign me out."), isOn: $signOut).toggleStyle(.checkbox)
        }
    }
    private var actions: some View {
        HStack {
            Spacer()
            Button(app.t("Cancel")) { session.plan=nil }.keyboardShortcut(.cancelAction)
            Button(app.t("Delete Permanently"), role: .destructive) {
                session.execute(app: app, plan: plan, signOut: signOut)
            }
            .buttonStyle(.borderedProminent).tint(.red).disabled(!permanent || (plan.requiresSignOutConsent && !signOut))
            .accessibilityIdentifier("privacy.confirm-delete")
        }
    }
}
