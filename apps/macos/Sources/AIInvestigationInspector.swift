import ShouCore
import SwiftUI

/// A task inspector beside the size browser, with independent rule decisions.
struct AIInvestigationInspector: View {
    var model: AppModel
    @Bindable var session: AIWorkspaceSession
    @State private var editing: AIConnection?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(model.t("AI Investigation"), systemImage: "sparkles").font(.headline)
                Spacer()
                Button { session.loadHistory(app: model) } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).help(model.t("Saved Investigations"))
                    .accessibilityLabel(model.t("Saved Investigations"))
                    .disabled(session.running || session.investigation?.status == .waiting)
                Button { session.showingInspector=false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(model.t("Close Inspector")).accessibilityLabel(model.t("Close Inspector"))
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.t("Investigation Folder")).font(.caption).foregroundStyle(.secondary)
                        Label(session.folder, systemImage: "folder").font(.callout.weight(.medium))
                            .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    }
                    if session.stale(app: model) {
                        Label(model.t("This snapshot changed. Start a new investigation from the current folder."), systemImage: "arrow.clockwise.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if !session.enabled {
                        Label(model.t("AI is off. Local scanning and cleanup remain available."), systemImage: "pause.circle").font(.callout)
                        Toggle(model.t("Enable AI Investigation"), isOn: $session.enabled).toggleStyle(.switch)
                            .accessibilityIdentifier("ai.inspector.enable")
                    }
                    if let state=session.investigation { investigation(state) }
                    else { setup }
                    if let issue=session.issue { Text(model.diagnostic(issue)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(16)
            }
            Divider()
            HStack {
                if session.running || session.investigation?.status == .waiting {
                    Button(model.t(session.stopping ? "Stopping investigation…" : "Stop Investigation")) { session.stop() }.disabled(session.stopping).accessibilityIdentifier("ai.investigation.stop")
                    Spacer()
                } else if session.investigation != nil || session.stale(app: model) {
                    Button(model.t("New Investigation")) { session.prepare(app: model) }.disabled(model.space.scanning || model.space.hasChanges)
                    Spacer()
                } else { Label(model.t("Nothing is deleted automatically"), systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary) }
            }.padding(14)
        }.background(.background)
            .accessibilityIdentifier("ai.investigation.inspector")
            .sheet(item: $editing) { AIConnectionEditor(model: model, connection: $0, didSave: { session.loadConnections() }) }
            .sheet(item: $session.review) { PersonalRuleReviewView(model: model, record: $0) }
            .sheet(isPresented: $session.showingHistory) { history }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Saved Investigations")).font(.title2.bold())
            Text(model.t("Opening a saved investigation makes no network request. Continuing uses its original connection and expires after 24 hours."))
                .font(.callout).foregroundStyle(.secondary)
            if session.loadingHistory { ProgressView() }
            List(session.savedInvestigations) { state in
                Button { session.restore(state, app: model) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.scope).font(.headline)
                        Text(state.connection.name + " · " + model.t(statusTitle(state.status))).font(.caption)
                        Text(state.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button(model.t("Done")) { session.showingHistory=false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(minWidth: 480, minHeight: 360)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("Understand large folders and turn useful findings into reusable rules.")).font(.callout)
            Picker(model.t("Investigation Goal"), selection: $session.goal) {
                Text(model.t("Understand this folder")).tag(AIInvestigationGoal.investigate)
                Text(model.t("Show largest entries locally")).tag(AIInvestigationGoal.space)
                Text(model.t("Create reusable rules")).tag(AIInvestigationGoal.rules)
            }
            if session.connections.isEmpty {
                ContentUnavailableView {
                    Label(model.t("Connect a Model"), systemImage: "network")
                } description: {
                    Text(model.t("Choose your own service to begin an investigation."))
                } actions: {
                    Button(model.t("Add Connection…")) { editing=AIConnection() }
                }.frame(maxWidth: .infinity)
            } else {
                Picker(model.t("Connection"), selection: $session.connectionId) {
                    ForEach(session.connections) { Text($0.name).tag($0.id) }
                }.pickerStyle(.menu)
                if let connection=session.connections.first(where: { $0.id == session.connectionId }) {
                    if connection.usesMainModel { Text(connection.model + " · " + connection.baseURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text(model.t(connection.strategy == .decisionFirst ? "Structured decisions first" : "Main model only")).font(.caption).foregroundStyle(.secondary)
                    Button(model.t("Edit Connection…")) { editing=connection }.buttonStyle(.link)
                    if let decision=connection.decision, connection.strategy == .decisionFirst {
                        Label(decision.providerName + " · " + decision.model + " · " + decision.baseURL, systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(model.t("Local processing comes first, then fixed-choice decisions. The main model is used only when open-ended understanding is needed."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField(model.t("What should be kept? (optional)"), text: $session.request, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder).accessibilityIdentifier("ai.investigation.request")
                Label(model.t("Sends relative folder names, sizes and your answers to the selected service. File contents and absolute home paths are excluded. Results are saved locally."), systemImage: "arrow.up.doc")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { session.start(app: model) } label: {
                    Text(model.t("Start Investigation")).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!session.enabled || session.stale(app: model) || session.request.count > 2000 || model.busy)
                    .accessibilityIdentifier("ai.investigation.start")
                if session.request.count > 2000 { Text(model.t("Keep investigation instructions within 2000 characters.")).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    @ViewBuilder private func investigation(_ state: AIInvestigation) -> some View {
        progressHeader(state)
        if !state.summary.isEmpty { Text(state.summary).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        if !state.evidence.isEmpty { evidenceDisclosure(state) }
        if let reviews=state.decisionReviews, !reviews.isEmpty { decisionDisclosure(reviews) }
        if let issue=state.issue { Text(model.diagnostic(issue)).font(.callout).foregroundStyle(.orange) }
        if state.status == .waiting && !session.running { questionForm(state) }
        if !state.advice.isEmpty { suggestions(state) }
        else if !session.running && state.status != .waiting {
            Label(model.t("No rule suggestions. Retained content and missing evidence are valid results; review the findings or start a smaller investigation."), systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let usage=state.serviceUsage {
            DisclosureGroup(model.t("Service Usage")) {
                ForEach(usage) { value in
                    Text(value.service + ": " + String(format: model.t("%lld requests · %lld reported tokens"), value.requests, value.reportedTokens)).font(.caption.monospacedDigit())
                }
                Text(model.t("Cost unavailable without your provider's actual rates.")).font(.caption).foregroundStyle(.secondary)
                ForEach(state.escalationReasons ?? [], id: \.self) { Text($0).font(.caption) }
            }
        }
    }
    private func decisionDisclosure(_ reviews: [AIDecisionReview]) -> some View {
        DisclosureGroup(model.t("Structured Decisions")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.t("A decision confidence is not a guarantee of safe deletion. Rule preview and your confirmation are still required."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(reviews.enumerated()), id: \.offset) { _, review in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(review.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text(model.t(verdictTitle(review.verdict)))
                            .font(.callout)
                        Text(review.model).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 8)
        }
    }
    private func verdictTitle(_ verdict: String) -> String {
        switch verdict {
        case "supported": "Evidence supports draft review"
        case "retain", "personal": "Retain this content"
        case "generated": "Generated content hypothesis"
        case "dependencies": "Dependency content hypothesis"
        case "mixed": "Mixed purposes; inspect children"
        default: "More evidence needed"
        }
    }
    private func progressHeader(_ state: AIInvestigation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if session.running { ProgressView().controlSize(.small) }
                else { Image(systemName: state.status == .waiting ? "questionmark.bubble" : state.status == .complete ? "checkmark.circle" : "pause.circle") }
                Text(model.t(session.stopping ? "Stopping investigation…" : session.running ? state.activity : statusTitle(state.status)))
                    .font(.callout.weight(.medium))
            }.accessibilityElement(children: .combine)
            Text(state.connection.name).font(.caption).foregroundStyle(.secondary)
            Text(String(format: model.t("%lld steps · %lld evidence rows"), state.steps, state.evidenceRows))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    private func statusTitle(_ status: AIInvestigationStatus) -> String {
        switch status {
        case .waiting: "Waiting for your answer"
        case .complete: "Investigation finished"
        case .failed: "Investigation failed"
        case .limited: "Investigation budget reached"
        case .cancelled: "Investigation cancelled."
        case .running: "Preparing investigation…"
        }
    }
    private func evidenceDisclosure(_ state: AIInvestigation) -> some View {
        DisclosureGroup(model.t("Observed Index Evidence")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("Saved scan metadata; current files are checked again in rule preview."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(state.evidence.prefix(40))) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(AIEvidencePolicy.relative(item.path, scope: state.scope)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text((item.complete ? "" : "≥ ") + model.bytes(item.allocatedBytes)).monospacedDigit().fixedSize()
                    }.font(.caption)
                }
                if state.evidence.count > 40 { Text(model.t("Showing the first 40 paths. Use a smaller folder for a focused investigation.")).font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 8)
        }
    }
    @ViewBuilder private func questionForm(_ state: AIInvestigation) -> some View {
        ForEach(state.questions) { question in questionCard(question) }
        Button(model.t("Continue Investigation")) { session.resume(app: model) }
            .buttonStyle(.borderedProminent)
            .disabled(!session.enabled || session.stopping || session.stale(app: model) || !answersComplete(state))
            .accessibilityIdentifier("ai.investigation.continue")
    }
    private func answersComplete(_ state: AIInvestigation) -> Bool {
        state.questions.allSatisfy { question in
            let answer=session.answers[question.id] ?? ""
            return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.count <= 2000
        }
    }
    private func questionCard(_ question: AIQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.text).font(.headline).textSelection(.enabled)
            ForEach(question.choices, id: \.self) { choice in
                Button { session.answers[question.id]=choice } label: {
                    HStack(alignment: .top) {
                        Image(systemName: session.answers[question.id] == choice ? "largecircle.fill.circle" : "circle")
                        Text(choice).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered)
            }
            TextField(model.t("Your answer"), text: Binding(get: { session.answers[question.id] ?? "" }, set: { session.answers[question.id]=$0 }), axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func suggestions(_ state: AIInvestigation) -> some View {
        Divider()
        Text(model.t("Rule Suggestions")).font(.headline)
        Text(model.t("Each suggestion is a separate choice. Preview imports a disabled draft; enabling and cleanup require review."))
            .font(.caption).foregroundStyle(.secondary)
        ForEach(state.advice) { advice in adviceCard(advice, state: state) }
    }
    private func adviceCard(_ advice: AIAdvice, state: AIInvestigation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(advice.rule.name).font(.headline)
            if let evidence=state.evidence.first(where: { $0.path == advice.path }) {
                Text((evidence.complete ? "" : "≥ ") + model.bytes(evidence.allocatedBytes)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Text(advice.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text(advice.explanation).font(.callout).textSelection(.enabled)
            DisclosureGroup(model.t("Rebuild Requirements")) {
                Text(advice.rule.risk.rebuildNote).font(.callout).textSelection(.enabled)
                ForEach(advice.rule.risk.limitations, id: \.self) { Text(model.t($0)).font(.caption).foregroundStyle(.secondary) }
            }
            Button(model.t("Preview This Rule…")) { session.preview(advice, app: model) }
                .disabled(session.running || session.importing || session.stale(app: model) || model.busy)
                .accessibilityIdentifier("ai.advice.preview")
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
