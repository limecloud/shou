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
    var pendingSelectionIDs=Set<String>()
    var runningSelectionIDs=Set<String>()
    var reviewErrors=[String: String]()
    var expandedID: String?
    var scanning=false
    var stopRequested=false
    var reviewingID: String?
    var preparing=false
    private var reviewingComponents=false
    var canChangeSelection: Bool { !preparing || reviewingComponents }
    var includeSystem=false
    var processedCount=0
    var applicationCount=0
    var currentPath=""
    var hasChanges=false
    private var operation=UUID()
    private var task: Task<Void, Never>?
    private struct ReviewRequest { let summary: ApplicationSummary; var authorize: Bool }
    private var reviewQueue=[ReviewRequest]()

    var items: [ApplicationSummary] { catalog?.items.compactMap { summaries[$0.id] } ?? Array(summaries.values) }
    var selectedAppIDs: Set<String> { Set(selection.filter { !$0.value.isEmpty }.map(\.key)).union(pendingSelectionIDs).union(runningSelectionIDs) }
    var selectionHasShortcuts: Bool { selectedComponents.contains { $0.kind == .shortcut } }
    var selectedComponents: [UninstallComponent] {
        selectedAppIDs.sorted().flatMap { id in reviews[id]?.components.filter { selection[id]?.contains($0.id) == true } ?? [] }
    }
    var selectedBytes: Int64 { selectedComponents.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    var selectionRequiresTrash: Bool { selectedComponents.contains(where: \.requiresTrash) }

    func scan(app: AppModel, accessChecked: Bool = false) {
        guard let engine=app.engine, !app.busy, !preparing else { return }
        if !accessChecked {
            app.scanAccess.prepareScan { [weak self, weak app] in
                guard let self, let app else { return }
                self.scan(app: app, accessChecked: true)
            }
            return
        }
        task?.cancel()
        let token=UUID(); operation=token
        scanning=true; stopRequested=false; app.busy=true; processedCount=0; applicationCount=0; currentPath=""
        catalog=nil; summaries=[:]; reviews=[:]; selection=[:]; personalDataConsent=[]; expandedID=nil; hasChanges=false
        pendingSelectionIDs=[]; runningSelectionIDs=[]; reviewQueue=[]; reviewErrors=[:]
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
                if !Task.isCancelled { app.presentFailure(error) }
            }
        }
    }

    func expand(_ summary: ApplicationSummary, app: AppModel) {
        let id=summary.application.id
        if expandedID == id { expandedID=nil; return }
        expandedID=id
        guard summary.application.identity.kind == "directory" || summary.issues.contains("application_link_target_missing") else { return }
        guard reviews[id] == nil else { return }
        review([summary], select: false, app: app)
    }

    func selectable(_ summary: ApplicationSummary) -> Bool {
        !hasChanges && ["ready", "admin-required", "trash-required", "running", "shortcut"].contains(summary.status)
    }
    func isSelected(_ id: String) -> Bool { selectedAppIDs.contains(id) }
    func toggle(_ summary: ApplicationSummary, app: AppModel) {
        let id=summary.application.id
        guard !app.busy, canChangeSelection else { return }
        if isSelected(id) { selection[id]=nil; pendingSelectionIDs.remove(id); runningSelectionIDs.remove(id) }
        else if selectable(summary) {
            if summary.status == "running" { runningSelectionIDs.insert(id); expandedID=id }
            else { review([summary], select: true, app: app) }
        }
    }
    func selectVisible(_ summaries: [ApplicationSummary], app: AppModel) {
        guard !app.busy, canChangeSelection else { return }
        let eligible=summaries.filter(selectable)
        guard !eligible.isEmpty else { return }
        if eligible.allSatisfy({ isSelected($0.application.id) }) {
            for summary in eligible { let id=summary.application.id; selection[id]=nil; pendingSelectionIDs.remove(id); runningSelectionIDs.remove(id) }
        } else {
            let unselected=eligible.filter { !isSelected($0.application.id) }
            runningSelectionIDs.formUnion(unselected.filter { $0.status == "running" }.map(\.id))
            review(unselected.filter { $0.status != "running" }, select: true, app: app)
        }
    }
    func clear(app: AppModel) { if !app.busy { selection=[:]; pendingSelectionIDs=[]; runningSelectionIDs=[] } }

    func authorize(_ summary: ApplicationSummary, app: AppModel) {
        guard !app.busy else { return }
        expandedID=summary.id
        review([summary], select: false, app: app, authorize: true)
    }

    private func review(_ items: [ApplicationSummary], select: Bool, app: AppModel, authorize: Bool = false) {
        guard let engine=app.engine, !app.busy, canChangeSelection, !items.isEmpty else { return }
        for summary in items {
            if select { pendingSelectionIDs.insert(summary.id) }
            reviewErrors[summary.id]=nil
            if let index=reviewQueue.firstIndex(where: { $0.summary.id == summary.id }) { reviewQueue[index].authorize = reviewQueue[index].authorize || authorize }
            else if reviewingID != summary.id { reviewQueue.append(ReviewRequest(summary: summary, authorize: authorize)) }
        }
        guard !preparing else { return }
        preparing=true; reviewingComponents=true; stopRequested=false; processedCount=0; applicationCount=reviewQueue.count
        app.statusKey="Reviewing application components…"
        task=Task {
            defer { reviewingID=nil; preparing=false; reviewingComponents=false; reviewQueue=[]; pendingSelectionIDs=[] }
            var authorizationCancelled=false
            while !reviewQueue.isEmpty {
                if Task.isCancelled { break }
                let request=reviewQueue.removeFirst(), summary=request.summary
                let id=summary.application.id
                reviewingID=id; currentPath=summary.application.path
                do {
                    if (summary.status == "admin-required" || request.authorize), NativeSystemAuthorization.shared.administratorState != .authorized {
                        expandedID=id
                        app.statusKey="Waiting for administrator authorization…"
                        guard await app.scanAccess.ensureAdministratorAuthorization(allowRecovery: request.authorize) else { authorizationCancelled=true; break }
                        try Task.checkCancellation()
                        reviews[id]=nil
                        app.statusKey="Reviewing application components…"
                    }
                    let value: ApplicationUninstallReview
                    if let cached=reviews[id] { value=cached }
                    else { value=try await engine.reviewApplication(path: summary.application.path); reviews[id]=value }
                    if value.requiresAdministrator, NativeSystemAuthorization.shared.administratorState != .authorized {
                        guard await app.scanAccess.ensureAdministratorAuthorization() else { authorizationCancelled=true; break }
                        try Task.checkCancellation()
                    }
                    if pendingSelectionIDs.contains(id) {
                        if value.components.contains(where: { $0.kind.isApplicationRoot && $0.eligible }) {
                            selection[id]=Set(value.components.filter { $0.eligible && !$0.requiresUserDataConsent &&
                                (value.keepsAssociatedData ? $0.kind.isApplicationRoot : ($0.kind.isApplicationRoot || $0.warnings.isEmpty)) }.map(\.id))
                        } else {
                            expandedID=id
                            reviewErrors[id]=app.t("This application cannot be safely removed. Review its component details.")
                        }
                    }
                } catch { if !Task.isCancelled { reviewErrors[id]=app.t((error as? ShouError)?.code ?? error.localizedDescription); expandedID=id } }
                pendingSelectionIDs.remove(id)
                processedCount += 1
                applicationCount=processedCount + reviewQueue.count
            }
            app.statusKey=Task.isCancelled ? "Application review stopped." : authorizationCancelled ? "Administrator authorization was not completed. Your selection is kept." : "Ready to review"
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
        !hasChanges && component.eligible && (reviews[appID]?.keepsAssociatedData != true || component.kind.isApplicationRoot) &&
            (!component.requiresUserDataConsent || personalDataConsent.contains(appID))
    }
    func toggleComponent(_ component: UninstallComponent, appID: String, app: AppModel) {
        guard !app.busy, componentSelectable(component, appID: appID) else { return }
        if selection[appID]?.contains(component.id) == true {
            if component.kind.isApplicationRoot { selection[appID]=nil }
            else { selection[appID]?.remove(component.id) }
        } else {
            guard let application=reviews[appID]?.components.first(where: { $0.kind.isApplicationRoot && $0.eligible }) else { return }
            selection[appID, default: []].formUnion([application.id, component.id])
        }
    }

    func removeSelected(app: AppModel, action: String) {
        guard let engine=app.engine, !app.busy, !preparing, runningSelectionIDs.isEmpty, pendingSelectionIDs.isEmpty, !hasChanges, !selectedAppIDs.isEmpty else { return }
        let choices=selectedAppIDs.sorted().compactMap { id -> ApplicationUninstallSelection? in
            guard let review=reviews[id], let components=selection[id] else { return nil }
            return ApplicationUninstallSelection(reviewId: review.id, componentIds: components.sorted(), includeUserData: personalDataConsent.contains(id))
        }
        guard choices.count == selectedAppIDs.count, action != "permanent" || !selectionRequiresTrash else { return }
        preparing=true; stopRequested=false; app.busy=true; app.statusKey=action == "permanent" ? "Permanently removing…" : "Moving to Trash…"
        let execution=app.beginExecution(total: selectedComponents.count, action: action, stage: action == "permanent" ? "purging" : "moving")
        let token=UUID(); operation=token
        task=Task {
            defer { preparing=false; app.busy=false; app.isExecuting=false; app.stopRequested=false }
            do {
                let reviewed=try await engine.createUninstallBatchPlan(selections: choices, action: action)
                try Task.checkCancellation()
                preparing=false
                let receipt=try await engine.executeUninstallBatch(planId: reviewed.id, confirmedDigest: reviewed.digest, entryPoint: "desktop", progress: { [weak self, weak app] update in
                    Task { @MainActor in
                        guard let self, self.operation == token, let app, app.isExecuting else { return }
                        app.updateExecutionProgress(update, operation: execution)
                    }
                })
                app.operationHadError=receipt.items.contains { ["failed", "unknown", "moving", "purging"].contains($0.state) }
                if receipt.state == "cancelled", receipt.items.allSatisfy({ ["skipped", "pending"].contains($0.state) }) {
                    app.statusKey="Removal cancelled. Your selection is kept."
                    await app.refresh()
                    return
                }
                let remaining=receipt.items.filter { !["trashed","purged"].contains($0.state) }
                let remainingApps=Set(remaining.compactMap { $0.uninstallOrigin?.applicationPath })
                let installed=Set(reviewed.plans.filter { plan in !receipt.items.contains { $0.originalPath == plan.application.path && ["trashed","purged"].contains($0.state) } }.map { $0.application.path })
                app.completion=CleanupCompletion(receipts: [receipt], sourceSection: "applications", retryPaths: Set(remaining.map(\.originalPath)),
                    retryApplicationPaths: remainingApps.intersection(installed), retryOrphans: !remaining.isEmpty && remainingApps.isDisjoint(with: installed))
                let removed=Set(receipt.items.filter { $0.uninstallOrigin?.kind.isApplicationRoot == true && ["trashed", "purged"].contains($0.state) }.map(\.originalPath))
                for summary in items where removed.contains(summary.application.path) { summaries[summary.application.id]=nil }
                selection=[:]; reviews=[:]; personalDataConsent=[]; expandedID=nil; hasChanges=true
                app.statusKey=receipt.state == "cancelled" ? "Removal cancelled. Review History for any items already moved." : receipt.state == "completed" ? (reviewed.action == "permanent" ? "Selected applications permanently uninstalled." : "Application components moved to Trash. Restore them from History.") : "Some items were not moved. Inspect history."
                await app.refresh()
            } catch {
                app.operationHadError=true
                if !Task.isCancelled {
                    app.completion=CleanupCompletion(receipts: [], failures: [error.localizedDescription], sourceSection: "applications")
                }
                let activityUnavailable=(error as? ShouError)?.code == "application_activity_unavailable"
                app.statusKey=activityUnavailable ? "Application processes and helpers could not be verified." : "Review application components again."
                hasChanges = !activityUnavailable
                await app.refresh()
            }
        }
    }

    func retry(paths: Set<String>, app: AppModel) {
        guard !app.busy, !preparing, let engine=app.engine else { return }
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
                    selection[summary.id]=Set(value.components.filter { $0.eligible && !$0.requiresUserDataConsent &&
                        (!value.keepsAssociatedData || $0.kind.isApplicationRoot) }.map(\.id))
                } catch { if !Task.isCancelled { app.presentFailure(error) } }
            }
            app.statusKey="Affected items refreshed. Review your selection to continue."
        }
    }
    func quit(_ summary: ApplicationSummary, app: AppModel) {
        close([summary], app: app)
    }
    func closeSelected(app: AppModel) {
        close(items.filter { runningSelectionIDs.contains($0.id) }, app: app)
    }
    private func close(_ items: [ApplicationSummary], app: AppModel) {
        guard !app.busy, !preparing, !items.isEmpty, let engine=app.engine else { return }
        app.busy=true; preparing=true; stopRequested=false
        app.statusKey="Requesting applications to quit…"
        task=Task {
            var closed=[ApplicationSummary]()
            do {
                let plan=try await engine.applicationClosePlan(applications: items.map(\.application))
                let results=try await engine.closeApplications(planId: plan.id, confirmedDigest: plan.digest, controller: NativeApplicationClosing())
                for result in results {
                    guard let summary=items.first(where: { $0.id == result.applicationId }) else { continue }
                    if result.state == "closed" {
                        do {
                            let updated=try await engine.applicationSummary(at: summary.application.path)
                            summaries[summary.id]=updated; reviews[summary.id]=nil; reviewErrors[summary.id]=nil
                            if runningSelectionIDs.remove(summary.id) != nil { closed.append(updated) }
                        } catch { reviewErrors[summary.id]=app.t((error as? ShouError)?.code ?? error.localizedDescription) }
                    } else {
                        reviewErrors[summary.id]=result.error ?? app.t("Still running. Save your work and quit the application.")
                        expandedID=summary.id
                    }
                }
                app.statusKey=results.allSatisfy { $0.state == "closed" } ? "Application closed. Review its components to continue." : "Still running. Save your work and quit the application."
            } catch { if !Task.isCancelled { app.presentFailure(error) } }
            app.busy=false; preparing=false
            if !Task.isCancelled && !closed.isEmpty { review(closed, select: true, app: app) }
        }
    }
    func recheck(_ summary: ApplicationSummary, app: AppModel) {
        guard !app.busy, !preparing, let engine=app.engine else { return }
        let selected=isSelected(summary.id)
        preparing=true; reviewingID=summary.id; reviewErrors[summary.id]=nil
        task=Task {
            var updated: ApplicationSummary?
            do {
                updated=try await engine.applicationSummary(at: summary.application.path)
                try Task.checkCancellation()
                summaries[summary.id]=updated; reviews[summary.id]=nil; selection[summary.id]=nil; runningSelectionIDs.remove(summary.id)
            } catch { if !Task.isCancelled { reviewErrors[summary.id]=app.t((error as? ShouError)?.code ?? error.localizedDescription) } }
            preparing=false; reviewingID=nil
            if !Task.isCancelled, let updated {
                if selected && updated.status == "running" { runningSelectionIDs.insert(summary.id) }
                else { review([updated], select: selected, app: app) }
            }
        }
    }
    func stop() { if scanning || preparing { stopRequested=true }; task?.cancel() }
    func waitForOperation() async { await task?.value }
}
