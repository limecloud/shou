import AppKit
import SwiftUI
import ServiceManagement
import ShouCore

func startupSourceTitle(_ id: String) -> String {
    switch id {
    case "macos.user_agents": "User Background Item"
    case "macos.local_agents": "Shared Background Item"
    case "macos.local_daemons": "System Background Item"
    case "macos.system_agents": "Apple system agents"
    case "macos.system_daemons": "Apple system daemons"
    case "macos.login_items", "macos.background_tasks": "Background Login Item"
    default: "Startup definition"
    }
}

private func startupStateTitle(_ state: String) -> String {
    switch state {
    case "enabled": "Enabled"
    case "disabled": "Disabled"
    case "mixed": "Partially Enabled"
    case "running": "Running"
    case "loaded": "Loaded"
    case "not_loaded": "Not loaded"
    default: "State unavailable"
    }
}

@MainActor private enum StartupArtwork {
    private static var icons: [String: NSImage]=[:]
    static func icon(_ path: String) -> NSImage {
        if let icon=icons[path] { return icon }
        let icon=NSWorkspace.shared.icon(forFile: path)
        icons[path]=icon
        return icon
    }
}

struct StartupInventoryRow: View {
    @Bindable var model: AppModel
    let group: StartupApplicationGroup
    let expanded: Bool
    let toggleExpanded: () -> Void
    let requestControl: ([StartupDefinition], StartupControlAction) -> Void
    @State private var hovered=false
    @FocusState private var actionFocused: Bool

    private var removable: [StartupDefinition] { group.items.filter(\.removable) }
    private var revealPath: String? {
        group.items.first(where: { $0.path.hasPrefix("/") })?.path ?? group.applicationPath ?? group.items.compactMap(\.programPath).first
    }
    private var sourceTitle: String {
        Set(group.items.map(\.sourceId)).count > 1 ? "Multiple Types" : startupSourceTitle(group.items[0].sourceId)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 12) {
                        artwork
                        Text(group.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 46, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(group.name)
                .accessibilityIdentifier("startup.group." + group.id)
                rowActions
                Text(model.t(sourceTitle)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary.opacity(0.5), in: Capsule())
                if group.items.count > 1 {
                    Text(String(format: model.t("%lld startup entries"), locale: model.language.locale, group.items.count))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
                groupControl
                Button(action: toggleExpanded) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(model.t(expanded ? "Collapse startup details" : "Expand startup details"))
                .accessibilityIdentifier("startup.disclosure." + group.id)
            }.padding(.horizontal, 10)
            if expanded { details }
        }
        .background(expanded || hovered || actionFocused ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered=$0 }
        .contextMenu {
            if let revealPath { Button(model.t("Reveal in Finder")) { reveal(revealPath) } }
            if !group.controllableItems.isEmpty {
                Button(model.t("Enable")) { requestControl(group.controllableItems, .enable) }.disabled(model.busy)
                Button(model.t("Disable")) { requestControl(group.controllableItems, .disable) }.disabled(model.busy)
            }
            if !removable.isEmpty {
                Button(model.t("Remove startup items…"), role: .destructive) { requestControl(removable, .remove) }.disabled(model.busy)
            }
        }
    }

    @ViewBuilder private var artwork: some View {
        if let path=group.applicationPath {
            Image(nsImage: StartupArtwork.icon(path)).resizable().interpolation(.high).scaledToFit().frame(width: 32, height: 32)
        } else {
            Image(systemName: "doc.badge.gearshape").font(.system(size: 19)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var rowActions: some View {
        HStack(spacing: 2) {
            if !removable.isEmpty {
                Button { requestControl(removable, .remove) } label: { Image(systemName: "trash").frame(width: 24, height: 26) }
                    .help(model.t("Remove startup items…")).accessibilityLabel(model.t("Remove startup items…")).disabled(model.busy)
            }
            if let revealPath {
                Button { reveal(revealPath) } label: { Image(systemName: "folder").frame(width: 24, height: 26) }
                    .help(model.t("Reveal in Finder")).accessibilityLabel(model.t("Reveal in Finder"))
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary).buttonStyle(.plain)
        .opacity(hovered || expanded || actionFocused ? 1 : 0).focused($actionFocused)
    }

    @ViewBuilder private var groupControl: some View {
        if group.configuredState == "enabled" || group.configuredState == "disabled" {
            Toggle(model.t(group.configuredState == "enabled" ? "Disable" : "Enable") + " " + group.name,
                isOn: Binding(get: { group.configuredState == "enabled" }, set: { enabled in
                    requestControl(group.controllableItems, enabled ? .enable : .disable)
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(model.busy || group.controllableItems.isEmpty)
                .help(model.t(group.controllableItems.isEmpty ? "Manage this item in Login Items Settings." : "Changes apply to future launches."))
                .accessibilityIdentifier("startup.toggle." + group.id)
        } else {
            Text(model.t(startupStateTitle(group.configuredState))).font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let publisher=group.publisher {
                detail(model.t("Publisher"), value: publisher)
            }
            ForEach(group.items) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Divider()
                    HStack(spacing: 8) {
                        Text(item.label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if item.targetState == "missing" {
                            Label(model.t("Startup Leftovers"), systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if group.items.count > 1 && group.controllableItems.contains(where: { $0.id == item.id }) {
                            Toggle(model.t(item.configuredState == "enabled" ? "Disable" : "Enable") + " " + item.label,
                                isOn: Binding(get: { item.configuredState == "enabled" }, set: { enabled in requestControl([item], enabled ? .enable : .disable) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.busy)
                                .accessibilityIdentifier("startup.item.toggle." + item.id)
                        }
                    }.padding(.top, 5)
                    detail(model.t("Source"), value: model.t(startupSourceTitle(item.sourceId)))
                    if item.path.hasPrefix("/") { pathDetail(model.t("Definition"), path: item.path) }
                    if let program=item.programPath { pathDetail(model.t("Executable"), path: program) }
                    detail(model.t("Startup State"), value: model.t(startupStateTitle(item.configuredState)))
                    detail(model.t("Runtime State"), value: model.t(startupStateTitle(item.runtimeState)))
                    if !item.triggers.isEmpty {
                        detail(model.t("Trigger clues"), value: item.triggers.map { model.t(triggerTitle($0)) }.joined(separator: " · "))
                    }
                    if item.controlCapability == "system_settings" {
                        Button { SMAppService.openSystemSettingsLoginItems() } label: {
                            Label(model.t("Open Login Items Settings"), systemImage: "arrow.up.forward.app")
                        }.buttonStyle(.link).font(.caption).padding(.vertical, 3)
                    }
                }.padding(.bottom, 10)
            }
        }.padding(.leading, 54).padding(.trailing, 16).padding(.bottom, 5)
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }

    private func pathDetail(_ label: String, path: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
            } label: { Image(systemName: "doc.on.doc").frame(width: 22, height: 22) }
                .buttonStyle(.plain).help(model.t("Copy Path")).accessibilityLabel(model.t("Copy Path"))
            Button { reveal(path) } label: { Image(systemName: "folder").frame(width: 22, height: 22) }
                .buttonStyle(.plain).help(model.t("Reveal in Finder")).accessibilityLabel(model.t("Reveal in Finder"))
        }.font(.caption)
    }

    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    private func triggerTitle(_ trigger: String) -> String {
        switch trigger {
        case "run_at_load": "At load"
        case "keep_alive": "Keep alive"
        case "conditional_keep_alive": "Conditional keep alive"
        case "scheduled": "Scheduled"
        case "watched_paths": "Watched paths"
        case "queued_directories": "Queued directories"
        case "socket_activation": "Socket activation"
        case "user_logon", "login_item": "At Login"
        default: "Service activation"
        }
    }
}
