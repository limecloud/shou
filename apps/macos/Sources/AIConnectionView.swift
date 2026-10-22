import ShouAI
import ShouCore
import ShouPlatform
import SwiftUI

struct AIConnectionsSettings: View {
    var model: AppModel
    @Bindable var session: AIWorkspaceSession
    @State private var editing: AIConnection?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("AI Investigation")).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $session.enabled) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.t("Enable AI Investigation")).font(.headline)
                        Text(model.t("Off by default. Disabling stops desktop investigations and tests; saved rules keep working offline. Explicit CLI AI commands have separate authorization."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).accessibilityLabel(model.t("Enable AI Investigation")).accessibilityIdentifier("ai.settings.enabled")
                Divider()
                HStack {
                    Image(systemName: "sparkles").font(.title3).foregroundStyle(.secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.t("Model Connections")).font(.headline)
                        Text(model.t("Use your own model service. API keys stay in Keychain; ordinary scans work offline."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.t("Saved Investigations")) {
                        model.section="storage"; session.showingInspector=true; session.loadHistory(app: model)
                    }.disabled(session.running || session.investigation?.status == .waiting)
                    Button(model.t("Add Connection…")) { editing=AIConnection() }.disabled(session.running)
                        .accessibilityIdentifier("ai.connection.add")
                }
                ForEach(session.connections) { connection in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.name).font(.body.weight(.medium))
                            if connection.usesMainModel { Text(connection.model + " · " + (URL(string: connection.baseURL)?.host ?? connection.baseURL))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let decision=connection.decision { Text(decision.providerName + " · " + decision.model).font(.caption).foregroundStyle(.secondary) }
                            Text(model.t(connection.strategy == .decisionFirst ? "Structured decisions first" : "Main model only")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.connectionId == connection.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).accessibilityLabel(model.t("Selected")) }
                        else { Button(model.t("Use Connection")) { session.connectionId=connection.id } }
                        Button(model.t("Edit…")) { editing=connection }.disabled(session.running)
                    }
                }
            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        }
        .task { session.loadConnections() }
        .sheet(item: $editing) { connection in AIConnectionEditor(model: model, connection: connection, didSave: { session.loadConnections() }) }
    }
}

private struct EditorCredentials: AICredentialStore {
    let supplied: String
    let suppliedDecision: String
    func key(for connection: AIConnection) throws -> String? {
        if connection.authentication == .keychain && !supplied.isEmpty { return supplied }
        return try SystemAICredentials().key(for: connection)
    }
    func decisionKey(for connection: AIConnection) throws -> String? {
        if connection.decision?.authentication == .keychain && !suppliedDecision.isEmpty { return suppliedDecision }
        return try SystemAICredentials().decisionKey(for: connection)
    }
}

struct AIConnectionEditor: View {
    var model: AppModel
    @State var connection: AIConnection
    var didSave: () -> Void
    @State private var key=""
    @State private var decisionKey=""
    @State private var testing=false
    @State private var saving=false
    @State private var tested=false
    @State private var issue: String?
    @State private var testTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "network").font(.title2).foregroundStyle(.secondary)
                Text(model.t("Model Connection")).font(.title2.weight(.semibold))
            }.padding(24)
            Divider()
            Form {
                Section {
                    TextField(model.t("Connection Name"), text: $connection.name).accessibilityIdentifier("ai.connection.name")
                    Toggle(model.t("Use a Main Model for Open-ended Understanding"), isOn: Binding(get: { connection.usesMainModel }, set: { connection.mainModelEnabled=$0 }))
                    if connection.usesMainModel {
                    Picker(model.t("API Protocol"), selection: $connection.apiProtocol) {
                        ForEach(AIProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("ai.connection.protocol")
                    TextField(model.t("API Base URL"), text: $connection.baseURL, prompt: Text("https://api.openai.com/v1"))
                        .accessibilityIdentifier("ai.connection.url")
                    TextField(model.t("Model"), text: $connection.model).accessibilityIdentifier("ai.connection.model")
                    }
                } footer: {
                    Text(model.t("Enter the API base URL, including any gateway prefix. Shou adds the protocol endpoint. HTTP is supported only on this Mac."))
                }
                if connection.usesMainModel { Section {
                    Picker(model.t("Authentication"), selection: $connection.authentication) {
                        Text(model.t("API Key in Keychain")).tag(AIAuthentication.keychain)
                        Text(model.t("Environment Variable")).tag(AIAuthentication.environment)
                        Text(model.t("No Authentication")).tag(AIAuthentication.none)
                    }
                    if connection.authentication == .keychain {
                        SecureField(model.t("API Key"), text: $key, prompt: Text(model.t("Leave blank to keep the saved key")))
                            .accessibilityIdentifier("ai.connection.key")
                    } else if connection.authentication == .environment {
                        TextField(model.t("Variable Name"), text: $connection.environmentVariable)
                    }
                } footer: {
                    Text(model.t("Connection tests send synthetic data only and verify a complete tool-calling round trip."))
                } }
                Section {
                    Toggle(model.t("Use Structured Decisions"), isOn: Binding(
                        get: { connection.decision != nil }, set: { connection.decision=$0 ? DecisionConnection() : nil; connection.routingStrategy=$0 ? .decisionFirst : .mainOnly }))
                    if connection.decision != nil {
                        Picker(model.t("Decision Provider"), selection: Binding(get: { connection.decision?.providerID ?? "jev" }, set: { id in
                            if let provider=StructuredDecisionService().availableProviders.first(where: { $0.id == id }) {
                                connection.decision=provider.connection; decisionKey=""
                            }
                        })) {
                            ForEach(StructuredDecisionService().availableProviders, id: \.id) { Text($0.name).tag($0.id) }
                            if let value=connection.decision, !StructuredDecisionService().availableProviders.contains(where: { $0.id == value.providerID }) {
                                Text(value.providerName + " · " + model.t("Unavailable")).tag(value.providerID)
                            }
                        }
                        TextField(model.t("Decision API Base URL"), text: Binding(get: { connection.decision?.baseURL ?? "" }, set: { connection.decision?.baseURL=$0 }))
                        TextField(model.t("Decision Model"), text: Binding(get: { connection.decision?.model ?? "" }, set: { connection.decision?.model=$0 }))
                        Picker(model.t("Decision Authentication"), selection: Binding(get: { connection.decision?.authentication ?? .keychain }, set: { connection.decision?.authentication=$0 })) {
                            Text(model.t("API Key in Keychain")).tag(AIAuthentication.keychain)
                            Text(model.t("Environment Variable")).tag(AIAuthentication.environment)
                            Text(model.t("No Authentication")).tag(AIAuthentication.none)
                        }
                        if connection.decision?.authentication == .keychain {
                            SecureField(model.t("Decision API Key"), text: $decisionKey, prompt: Text(model.t("Leave blank to keep the saved key")))
                                .accessibilityIdentifier("ai.connection.jev-key")
                        } else if connection.decision?.authentication == .environment {
                            TextField(model.t("Decision Variable Name"), text: Binding(get: { connection.decision?.environmentVariable ?? "" }, set: { connection.decision?.environmentVariable=$0 }))
                        }
                    }
                    if connection.usesMainModel && connection.decision != nil {
                        Picker(model.t("Processing Strategy"), selection: Binding(get: { connection.strategy }, set: { connection.routingStrategy=$0 })) {
                            Text(model.t("Structured decisions first")).tag(AIRoutingStrategy.decisionFirst)
                            Text(model.t("Main model only")).tag(AIRoutingStrategy.mainOnly)
                        }
                    }
                } footer: {
                    Text(model.t("The decision provider receives bounded relative metadata and retention answers. Local processing comes first; only open-ended understanding escalates to the main model. Neither service can authorize deletion."))
                }
            }.formStyle(.grouped).disabled(testing || saving)
            if let issue { Text(model.diagnostic(issue)).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 12) }
            if tested {
                Label(model.t(connection.usesMainModel ? "Connected · Tool calling verified" : "Structured decision connection verified"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green).padding(.horizontal, 24).padding(.bottom, 12)
                if connection.usesMainModel, let decision=connection.decision { Text(decision.providerName + " · " + model.t("Structured decision connection verified")).font(.caption).foregroundStyle(.green).padding(.horizontal, 24).padding(.bottom, 12) }
            }
            Divider()
            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text(model.t("Saving connection…")).font(.callout).foregroundStyle(.secondary)
                } else if testing {
                    ProgressView().controlSize(.small)
                    Text(model.t("Testing connection…")).font(.callout).foregroundStyle(.secondary)
                    Button(model.t("Stop")) { testTask?.cancel() }
                } else {
                    Button(model.t("Test Connection")) { test() }.disabled(!model.ai.enabled)
                        .help(model.t(model.ai.enabled ? "Connection tests send synthetic data only and verify a complete tool-calling round trip." : "Enable AI Investigation before testing a connection.")).accessibilityIdentifier("ai.connection.test")
                }
                Spacer()
                Button(model.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(model.t("Save")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(testing || saving)
                    .accessibilityIdentifier("ai.connection.save")
            }.padding(20)
        }.frame(width: 580, height: 690)
            .interactiveDismissDisabled(saving)
            .onDisappear { testTask?.cancel(); key=""; decisionKey="" }
            .onChange(of: connection) { _, _ in tested=false }
            .onChange(of: key) { _, _ in tested=false }
            .onChange(of: decisionKey) { _, _ in tested=false }
            .onChange(of: model.ai.enabled) { _, enabled in if !enabled { testTask?.cancel() } }
    }
    private func test() {
        guard model.ai.enabled else { return }
        do {
            let value=try connection.validated(), credentials=EditorCredentials(supplied: key, suppliedDecision: decisionKey)
            let permit=model.ai.networkPermit()
            testing=true; issue=nil; tested=false
            testTask=Task {
                defer { testing=false; testTask=nil }
                do {
                    try Task.checkCancellation()
                    if value.usesMainModel { try await AIConnectionTest.run(connection: value, credentials: credentials, permit: permit) }
                    try Task.checkCancellation()
                    if value.decision != nil { _ = try await StructuredDecisionService().test(connection: value, credentials: credentials, permit: permit) }
                    try Task.checkCancellation(); tested=true
                }
                catch { if !Task.isCancelled { issue=error.localizedDescription } }
            }
        } catch { issue=error.localizedDescription }
    }
    private func save() {
        guard !testing, !saving else { return }
        do {
            let value=try connection.validated(), supplied=key, suppliedDecision=decisionKey
            saving=true; issue=nil
            Task {
                defer { saving=false }
                do {
                    // Keychain may wait for a system prompt; keep the main actor responsive.
                    try await Task.detached(priority: .userInitiated) {
                        let credentials=SystemAICredentials()
                        if value.usesMainModel && value.authentication == .keychain {
                            if supplied.isEmpty { _ = try credentials.key(for: value) }
                            else { try credentials.save(supplied, for: value) }
                        }
                        if value.decision?.authentication == .keychain {
                            if suppliedDecision.isEmpty { _ = try credentials.decisionKey(for: value) }
                            else { try credentials.save(suppliedDecision, for: value, decision: true) }
                        }
                        try AIConnectionStore(store: LocalRecordStore()).save(value)
                    }.value
                    key=""; decisionKey=""; didSave(); dismiss()
                } catch { issue=error.localizedDescription }
            }
        } catch { issue=error.localizedDescription }
    }
}
