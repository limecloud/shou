import AppKit
import SwiftUI

/// NSButton supplies the standard macOS mixed checkbox state and keyboard behavior.
struct SelectionCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let enabled: Bool
    let label: String
    var identifier: String?=nil
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button=NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.allowsMixedState=true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action=action
        context.coordinator.enabled=enabled
        context.coordinator.state=state
        button.state=state; button.isEnabled=enabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        var enabled=false
        var state=NSControl.StateValue.off
        init(_ action: @escaping () -> Void) { self.action=action }
        @objc func toggle(_ sender: NSButton) {
            guard enabled else { sender.state=state; return }
            action()
        }
    }
}
