import ShouAI
import ShouCore
import ShouPlatform
import SwiftUI

/// Shared by settings, launch confirmation and the investigation inspector.
struct AIConnectionSummary: View {
    var model: AppModel
    let connection: AIConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if connection.strategy == .decisionFirst, let decision=connection.decision {
                service(title: model.t("Decision Service, First"), name: decision.providerName + ", " + decision.model,
                        url: decision.baseURL, icon: "checkmark.shield")
            }
            if connection.usesMainModel {
                service(title: model.t(connection.strategy == .decisionFirst && connection.decision != nil ? "Main Model, When Needed" : "Main Model"),
                        name: connection.model, url: connection.baseURL, icon: "sparkles")
            }

        }.accessibilityElement(children: .contain).accessibilityIdentifier("ai.configuration.summary")
    }
    private func service(title: String, name: String, url: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                Text(name).font(ShouType.body.weight(.medium))
                Text(URL(string: url)?.host ?? url).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
            }
        } icon: { Image(systemName: icon).foregroundStyle(ShouPalette.accent).frame(width: 20) }
    }
}

struct AIConnectionsSettings: View {
    var model: AppModel
    @Bindable var session: AIWorkspaceSession
    @State private var editing: AIConnection?
    @State private var deleting: AIConnection?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("AI Investigation")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $session.enabled) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.t("Enable AI Investigation")).font(ShouType.body.weight(.semibold))
                        Text(model.t("Off by default. Disabling stops desktop investigations and tests; saved rules keep working offline. Explicit CLI AI commands have separate authorization."))
                            .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    }
                }.toggleStyle(.switch).accessibilityLabel(model.t("Enable AI Investigation")).accessibilityIdentifier("ai.settings.enabled")
                ShouDivider()
                HStack {
                    Image(systemName: "sparkles").font(ShouType.body).foregroundStyle(ShouPalette.secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.t("AI Configurations")).font(ShouType.body.weight(.semibold))
                    }
                    Spacer()
                    Button(model.t("Saved Investigations")) {
                        model.section="storage"; session.showingInspector=true; session.loadHistory(app: model)
                    }.disabled(session.running || session.investigation?.status == .waiting)
                    Button(model.t("Add Connection…")) { editing=AIConnection(decision: DecisionConnection()) }.disabled(!session.canManageConnections)
                        .accessibilityIdentifier("ai.connection.add")
                }
                ForEach(session.connections) { connection in
                    ShouDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.name).font(ShouType.body.weight(.medium))
                            AIConnectionSummary(model: model, connection: connection)
                            if connection.usesMainModel {
                                Toggle(model.t("Enable Decision Service"), isOn: Binding(get: { connection.decisionEnabled }, set: { enabled in
                                    if enabled && connection.decision == nil {
                                        var value=connection; value.decision=DecisionConnection(); value.routingStrategy = .decisionFirst; editing=value
                                    } else { session.setDecisionEnabled(enabled, connection: connection) }
                                }))
                                    .toggleStyle(.switch).controlSize(.small).disabled(!session.canManageConnections)
                                    .accessibilityIdentifier("ai.connection.decision-toggle." + connection.id)
                            } else { Text(model.t("Add a main model before using this legacy configuration.")).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
                        }
                        Spacer()
                        if session.connectionId == connection.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(ShouPalette.accent).accessibilityLabel(model.t("Selected")) }
                        else { Button(model.t("Set as Default")) { session.connectionId=connection.id }.disabled(!connection.usesMainModel || !session.canManageConnections) }
                        Button(model.t("Edit…")) { editing=connection }.disabled(!session.canManageConnections)
                        Button(role: .destructive) { deleting=connection } label: { Image(systemName: "trash") }
                            .help(model.t("Delete Configuration…")).accessibilityLabel(model.t("Delete Configuration…"))
                            .disabled(!session.canManageConnections)
                    }
                }
                if !session.deletedConnections.isEmpty {
                    ShouDivider()
                    DisclosureGroup(model.t("Deleted Configurations")) {
                        ForEach(session.deletedConnections) { connection in
                            HStack {
                                Text(connection.name); Spacer()
                                Button(model.t("Restore")) { session.setConnectionDeleted(false, connection: connection) }.disabled(!session.canManageConnections)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if let issue=session.issue { Text(model.diagnostic(issue)).font(ShouType.caption).foregroundStyle(ShouPalette.danger).textSelection(.enabled) }
            }.padding(18).background(ShouPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ShouPalette.border, lineWidth: ShouDesign.hairlineWidth))
        }
        .task { session.loadConnections() }
        .sheet(item: $editing) { connection in AIConnectionEditor(model: model, connection: connection, didSave: { session.loadConnections() }) }
        .confirmationDialog(model.t("Delete Configuration?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting=nil } }), titleVisibility: .visible) {
            if let connection=deleting {
                Button(model.t("Delete Configuration"), role: .destructive) { session.setConnectionDeleted(true, connection: connection); deleting=nil }
            }
        } message: {
            Text((deleting?.name ?? "") + "\n" + model.t("Remove this configuration from available choices. Saved investigations and their keys are retained. You can restore it from Deleted Configurations."))
        }
    }
}

private struct EditorCredentials: AICredentialStore {
    let supplied: String
    let suppliedDecision: String
    func key(for connection: AIConnection) throws -> String? {
        if connection.authentication.storesKey && !supplied.isEmpty { return supplied }
        return try SystemAICredentials().key(for: connection)
    }
    func decisionKey(for connection: AIConnection) throws -> String? {
        if connection.decision?.authentication.storesKey == true && !suppliedDecision.isEmpty { return suppliedDecision }
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
                Image(systemName: "network").font(ShouType.title).foregroundStyle(ShouPalette.secondary)
                Text(model.t("AI Configuration")).font(ShouType.title.weight(.semibold))
            }.padding(24)
            Divider()
            Form {
                Section {
                    TextField(model.t("Configuration Name"), text: $connection.name).accessibilityIdentifier("ai.connection.name")
                    Text(model.t("The main model is required. Enable the decision service to reduce token use; switch it off to let the main model handle the investigation directly."))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
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
                        Text(model.t("API Key in Local Storage")).tag(AIAuthentication.local)
                        if connection.authentication == .keychain { Text(model.t("Legacy Keychain Reference")).tag(AIAuthentication.keychain) }
                        Text(model.t("Environment Variable")).tag(AIAuthentication.environment)
                        Text(model.t("No Authentication")).tag(AIAuthentication.none)
                    }
                    if connection.authentication.storesKey {
                        SecureField(model.t("API Key"), text: $key, prompt: Text(model.t("Leave blank to keep the saved key")))
                            .accessibilityIdentifier("ai.connection.key")
                    } else if connection.authentication == .environment {
                        TextField(model.t("Variable Name"), text: $connection.environmentVariable)
                    }
                } footer: {
                    Text(model.t("Local keys are stored in private files accessible to your account, without Keychain encryption. Keys are excluded from profiles and investigation history. Tests send synthetic data only."))
                } }
                Section {
                    Toggle(model.t("Enable Decision Service"), isOn: Binding(
                        get: { connection.decisionEnabled }, set: { enabled in
                            if enabled && connection.decision == nil { connection.decision=DecisionConnection() }
                            connection.routingStrategy=enabled ? .decisionFirst : .mainOnly
                        }))
                    if connection.decisionEnabled {
                        Picker(model.t("Decision Provider"), selection: Binding(get: { connection.decision?.providerID ?? "jev" }, set: { id in
                            if let provider=StructuredDecisionService().availableProviders.first(where: { $0.id == id }) {
                                connection.decision=provider.connection; decisionKey=""
                            }
                        })) {
                            ForEach(StructuredDecisionService().availableProviders, id: \.id) { Text($0.name).tag($0.id) }
                            if let value=connection.decision, !StructuredDecisionService().availableProviders.contains(where: { $0.id == value.providerID }) {
                                Text(value.providerName + ", " + model.t("Unavailable")).tag(value.providerID)
                            }
                        }
                        TextField(model.t("Decision API Base URL"), text: Binding(get: { connection.decision?.baseURL ?? "" }, set: { connection.decision?.baseURL=$0 }))
                        TextField(model.t("Decision Model"), text: Binding(get: { connection.decision?.model ?? "" }, set: { connection.decision?.model=$0 }))
                        Picker(model.t("Decision Authentication"), selection: Binding(get: { connection.decision?.authentication ?? .preferred }, set: { connection.decision?.authentication=$0 })) {
                            Text(model.t("API Key in Local Storage")).tag(AIAuthentication.local)
                            if connection.decision?.authentication == .keychain { Text(model.t("Legacy Keychain Reference")).tag(AIAuthentication.keychain) }
                            Text(model.t("Environment Variable")).tag(AIAuthentication.environment)
                            Text(model.t("No Authentication")).tag(AIAuthentication.none)
                        }
                        if connection.decision?.authentication.storesKey == true {
                            SecureField(model.t("Decision API Key"), text: $decisionKey, prompt: Text(model.t("Leave blank to keep the saved key")))
                                .accessibilityIdentifier("ai.connection.jev-key")
                        } else if connection.decision?.authentication == .environment {
                            TextField(model.t("Decision Variable Name"), text: Binding(get: { connection.decision?.environmentVariable ?? "" }, set: { connection.decision?.environmentVariable=$0 }))
                        }
                    }
                    if !connection.decisionEnabled { Text(model.t("Decision service is off. The main model takes over; saved decision settings and keys are kept.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                } footer: {
                    Text(model.t("The decision provider receives bounded relative metadata and retention answers. Local processing comes first; only open-ended understanding escalates to the main model. Neither service can authorize deletion."))
                }
                if connection.authentication == .keychain || connection.decision?.authentication == .keychain {
                    Section {
                        Button(model.t("Switch to Local Key Storage")) {
                            if connection.authentication == .keychain { connection.authentication = .local; key="" }
                            if connection.decision?.authentication == .keychain { connection.decision?.authentication = .local; decisionKey="" }
                        }.accessibilityIdentifier("ai.connection.use-local")
                    } footer: {
                        Text(model.t("Legacy Keychain access depends on the app signature. Switch to local storage and enter each key once; the old Keychain entries are kept. Shou will not request your login Keychain password."))
                    }
                }
            }.formStyle(.grouped).disabled(testing || saving)
            if let issue { Text(model.diagnostic(issue)).font(ShouType.caption).foregroundStyle(ShouPalette.danger).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 12) }
            if tested {
                Label(model.t(connection.usesMainModel ? "Connected, Tool calling verified" : "Structured decision connection verified"), systemImage: "checkmark.circle.fill").font(ShouType.body).foregroundStyle(ShouPalette.success).padding(.horizontal, 24).padding(.bottom, 12)
                if connection.decisionEnabled, let decision=connection.decision { Text(decision.providerName + ", " + model.t("Structured decision connection verified")).font(ShouType.caption).foregroundStyle(ShouPalette.success).padding(.horizontal, 24).padding(.bottom, 12) }
            }
            Divider()
            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text(model.t("Saving connection…")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                } else if testing {
                    ProgressView().controlSize(.small)
                    Text(model.t("Testing connection…")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
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
        }.frame(width: 580, height: 520)
            .interactiveDismissDisabled(saving)
            .onDisappear { testTask?.cancel(); key=""; decisionKey="" }
            .onChange(of: connection) { _, _ in tested=false }
            .onChange(of: key) { _, _ in tested=false }
            .onChange(of: decisionKey) { _, _ in tested=false }
            .onChange(of: model.ai.enabled) { _, enabled in if !enabled { testTask?.cancel() } }
            .onAppear { connection.mainModelEnabled=true }
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
                    if value.decisionEnabled { _ = try await StructuredDecisionService().test(connection: value, credentials: credentials, permit: permit) }
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
                    // Durable credential writes run off the main actor.
                    try await Task.detached(priority: .userInitiated) {
                        let store=try AIConnectionStore(store: LocalRecordStore())
                        try store.checkEditable(value.id)
                        let credentials=SystemAICredentials()
                        if value.usesMainModel && value.authentication.storesKey {
                            if supplied.isEmpty { _ = try credentials.key(for: value) }
                            else { try credentials.save(supplied, for: value) }
                        }
                        if value.decision?.authentication.storesKey == true && (value.decisionEnabled || !suppliedDecision.isEmpty) {
                            if suppliedDecision.isEmpty { _ = try credentials.decisionKey(for: value) }
                            else { try credentials.save(suppliedDecision, for: value, decision: true) }
                        }
                        try store.save(value)
                    }.value
                    key=""; decisionKey=""; didSave(); dismiss()
                } catch { issue=error.localizedDescription }
            }
        } catch { issue=error.localizedDescription }
    }
}
