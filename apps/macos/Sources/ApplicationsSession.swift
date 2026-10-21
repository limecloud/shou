import AppKit
import Foundation
import Observation
import ShouCore
import ShouPlatform

@MainActor @Observable final class ApplicationsSession {
    var catalog: ApplicationCatalog?
    var summaries=[String: ApplicationSummary]()
    var reviews=[String: ApplicationUninstallReview]()
    var selection=[String: Set<String>]()
    var personalDataConsent=Set<String>()
    var expandedID: String?
    var scanning=false
    var stopRequested=false
    var reviewingID: String?
    var preparing=false
    var includeSystem=false
    var processedCount=0
    var applicationCount=0
    var currentPath=""
    var hasChanges=false
    var plan: ApplicationUninstallBatchPlan?
    private var operation=UUID()
    private var task: Task<Void, Never>?

    var items: [ApplicationSummary] { catalog?.items.compactMap { summaries[$0.id] } ?? Array(summaries.values) }
    var selectedAppIDs: Set<String> { Set(selection.filter { !$0.value.isEmpty }.map(\.key)) }
    var selectedComponents: [UninstallComponent] {
        selectedAppIDs.sorted().flatMap { id in reviews[id]?.components.filter { selection[id]?.contains($0.id) == true } ?? [] }
    }
    var selectedBytes: Int64 { selectedComponents.reduce(0) { $0 + $1.allocatedBytesEstimate } }

    func scan(app: AppModel) {
        guard let engine=app.engine, !app.busy else { return }
        task?.cancel()
        let token=UUID(); operation=token
        scanning=true; stopRequested=false; app.busy=true; processedCount=0; applicationCount=0; currentPath=""
        catalog=nil; summaries=[:]; reviews=[:]; selection=[:]; personalDataConsent=[]; expandedID=nil; hasChanges=false
        let options=ApplicationCatalogOptions(includeSystem: includeSystem)
        app.statusKey="Reading installed applications…"
        task=Task {
            defer { if operation == token { scanning=false; app.busy=false } }
            do {
                let result=try await engine.applicationSummaries(options: options, progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.operation == token, self.scanning, update.processedCount >= self.processedCount else { return }
                        self.processedCount=update.processedCount; self.applicationCount=update.applicationCount; self.currentPath=update.currentPath
                    }
                }, onSummary: { [weak self] summary in
                    Task { @MainActor in
                        guard let self, self.operation == token, self.scanning else { return }
                        self.summaries[summary.application.id]=summary
                    }
                })
                try Task.checkCancellation()
                catalog=result.catalog
                summaries=Dictionary(uniqueKeysWithValues: result.items.map { ($0.application.id, $0) })
                app.statusKey="Applications checked. Review components before uninstalling."
            } catch {
                app.statusKey="Application scan stopped."
                if !Task.isCancelled { app.error=error.localizedDescription }
            }
        }
    }

    func expand(_ summary: ApplicationSummary, app: AppModel) {
        let id=summary.application.id
        if expandedID == id { expandedID=nil; return }
        expandedID=id
        guard reviews[id] == nil else { return }
        review([summary], select: false, app: app)
    }

    func selectable(_ summary: ApplicationSummary) -> Bool {
        !hasChanges && summary.status == "ready"
    }
    func isSelected(_ id: String) -> Bool { !(selection[id] ?? []).isEmpty }
    func toggle(_ summary: ApplicationSummary, app: AppModel) {
        let id=summary.application.id
        guard !app.busy else { return }
        if isSelected(id) { selection[id]=nil }
        else if selectable(summary) { review([summary], select: true, app: app) }
    }
    func selectVisible(_ summaries: [ApplicationSummary], app: AppModel) {
        guard !app.busy else { return }
        let eligible=summaries.filter(selectable)
        guard !eligible.isEmpty else { return }
        if eligible.allSatisfy({ isSelected($0.application.id) }) {
            for summary in eligible { selection[summary.application.id]=nil }
        } else {
            review(eligible.filter { !isSelected($0.application.id) }, select: true, app: app)
        }
    }
    func clear(app: AppModel) { if !app.busy { selection=[:] } }

    private func review(_ items: [ApplicationSummary], select: Bool, app: AppModel) {
        guard let engine=app.engine, !app.busy, !items.isEmpty else { return }
        app.busy=true; preparing=true; stopRequested=false; processedCount=0; applicationCount=items.count
        app.statusKey="Reviewing application components…"
        task=Task {
            defer { reviewingID=nil; preparing=false; app.busy=false }
            var failures=[String]()
            for summary in items {
                if Task.isCancelled { break }
                let id=summary.application.id
                reviewingID=id; currentPath=summary.application.path
                do {
                    let value: ApplicationUninstallReview
                    if let cached=reviews[id] { value=cached }
                    else { value=try await engine.reviewApplication(path: summary.application.path); reviews[id]=value }
                    if select, value.components.contains(where: { $0.kind == .application && $0.eligible }) {
                        selection[id]=Set(value.components.filter { $0.eligible && !$0.requiresUserDataConsent && ($0.kind == .application || $0.warnings.isEmpty) }.map(\.id))
                    }
                } catch { if !Task.isCancelled { failures.append(summary.application.name + "\n" + error.localizedDescription) } }
                processedCount += 1
            }
            app.statusKey=Task.isCancelled ? "Application review stopped." : "Ready to review"
            if !failures.isEmpty { app.error=failures.joined(separator: "\n\n") }
        }
    }

    func allowPersonalData(_ id: String, allowed: Bool, app: AppModel) {
        guard !app.busy else { return }
        if allowed { personalDataConsent.insert(id) }
        else {
            personalDataConsent.remove(id)
            selection[id]?.subtract(reviews[id]?.components.filter(\.requiresUserDataConsent).map(\.id) ?? [])
        }
    }
    func componentSelectable(_ component: UninstallComponent, appID: String) -> Bool {
        !hasChanges && component.eligible && (!component.requiresUserDataConsent || personalDataConsent.contains(appID))
    }
    func toggleComponent(_ component: UninstallComponent, appID: String, app: AppModel) {
        guard !app.busy, componentSelectable(component, appID: appID) else { return }
        if selection[appID]?.contains(component.id) == true {
            if component.kind == .application { selection[appID]=nil }
            else { selection[appID]?.remove(component.id) }
        } else {
            guard let application=reviews[appID]?.components.first(where: { $0.kind == .application && $0.eligible }) else { return }
            selection[appID, default: []].formUnion([application.id, component.id])
        }
    }

    func prepare(app: AppModel, action: String) {
        guard let engine=app.engine, !app.busy, !selectedAppIDs.isEmpty else { return }
        let choices=selectedAppIDs.sorted().compactMap { id -> ApplicationUninstallSelection? in
            guard let review=reviews[id], let components=selection[id] else { return nil }
            return ApplicationUninstallSelection(reviewId: review.id, componentIds: components.sorted(), includeUserData: personalDataConsent.contains(id))
        }
        preparing=true; stopRequested=false; processedCount=0; applicationCount=0; currentPath=""; app.busy=true; app.statusKey="Preparing cleanup preview…"
        task=Task {
            defer { preparing=false; app.busy=false }
            do {
                plan=try await engine.createUninstallBatchPlan(selections: choices, action: action)
                app.statusKey="Ready to review"
            } catch { if !Task.isCancelled { app.error=error.localizedDescription }; app.statusKey="Review application components again." }
        }
    }

    func execute(_ reviewed: ApplicationUninstallBatchPlan, app: AppModel) {
        guard let engine=app.engine, !app.busy, plan?.id == reviewed.id else { return }
        plan=nil; app.busy=true
        let execution=app.beginExecution(total: reviewed.plans.reduce(0) { $0 + $1.components.count })
        let token=UUID(); operation=token
        task=Task {
            defer { app.busy=false; app.isExecuting=false; app.stopRequested=false }
            do {
                let receipt=try await engine.executeUninstallBatch(planId: reviewed.id, confirmedDigest: reviewed.digest, entryPoint: "desktop", progress: { [weak self, weak app] update in
                    Task { @MainActor in
                        guard let self, self.operation == token, let app, app.isExecuting else { return }
                        app.updateExecutionProgress(update, operation: execution)
                    }
                })
                app.operationHadError=receipt.items.contains { ["failed", "unknown", "moving", "purging"].contains($0.state) }
                let remaining=receipt.items.filter { !["trashed","purged"].contains($0.state) }
                let remainingApps=Set(remaining.compactMap { $0.uninstallOrigin?.applicationPath })
                let installed=Set(reviewed.plans.filter { plan in !receipt.items.contains { $0.originalPath == plan.application.path && ["trashed","purged"].contains($0.state) } }.map { $0.application.path })
                app.completion=CleanupCompletion(receipts: [receipt], sourceSection: "applications", retryPaths: Set(remaining.map(\.originalPath)),
                    retryApplicationPaths: remainingApps.intersection(installed), retryOrphans: !remaining.isEmpty && remainingApps.isDisjoint(with: installed))
                let removed=Set(receipt.items.filter { $0.uninstallOrigin?.kind == .application && ["trashed", "purged"].contains($0.state) }.map(\.originalPath))
                for summary in items where removed.contains(summary.application.path) { summaries[summary.application.id]=nil }
                selection=[:]; reviews=[:]; personalDataConsent=[]; expandedID=nil; hasChanges=true
                app.statusKey=receipt.state == "completed" ? (reviewed.action == "permanent" ? "Selected applications permanently uninstalled." : "Application components moved to Trash. Restore them from History.") : "Some items were not moved. Inspect history."
                await app.refresh()
            } catch {
                app.operationHadError=true
                if !Task.isCancelled { app.error=error.localizedDescription }
                let activityUnavailable=(error as? ShouError)?.code == "application_activity_unavailable"
                app.statusKey=activityUnavailable ? "Application processes and helpers could not be verified." : "Review application components again."
                hasChanges = !activityUnavailable
                await app.refresh()
            }
        }
    }

    func retry(paths: Set<String>, app: AppModel) {
        guard !app.busy, let engine=app.engine else { return }
        app.busy=true; preparing=true
        task=Task {
            defer { app.busy=false; preparing=false }
            for path in paths.sorted() {
                if Task.isCancelled { break }
                do {
                    let summary=try await engine.applicationSummary(at: path)
                    summaries[summary.id]=summary
                    let value=try await engine.reviewApplication(path: path)
                    reviews[summary.id]=value
                    selection[summary.id]=Set(value.components.filter { $0.eligible && !$0.requiresUserDataConsent }.map(\.id))
                } catch { if !Task.isCancelled { app.error=error.localizedDescription } }
            }
            app.statusKey="Affected items refreshed. Review your selection to continue."
        }
    }
    func quit(_ summary: ApplicationSummary, app: AppModel) {
        guard !app.busy, let engine=app.engine else { return }
        app.busy=true
        task=Task {
            defer { app.busy=false }
            do {
                let plan=try await engine.applicationClosePlan(applications: [summary.application])
                let results=try await engine.closeApplications(planId: plan.id, confirmedDigest: plan.digest, controller: NativeApplicationClosing())
                if results.allSatisfy({ $0.state == "closed" }) {
                    summaries[summary.application.id]=try await engine.applicationSummary(at: summary.application.path)
                    reviews[summary.application.id]=nil
                    app.statusKey="Application closed. Review its components to continue."
                } else { app.error=results.compactMap(\.error).first ?? app.t("Still running. Save your work and quit the application.") }
            } catch { if !Task.isCancelled { app.error=error.localizedDescription } }
        }
    }
    func stop() { if scanning || preparing { stopRequested=true }; task?.cancel() }
    func waitForOperation() async { await task?.value }
}
