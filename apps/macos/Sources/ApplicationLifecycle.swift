import AppKit
import SwiftUI
import os

private let lifecycleLog=Logger(subsystem: "dev.limecloud.shou", category: "Lifecycle")

@MainActor
private func confirmLeavingAI(_ model: AppModel) -> Bool {
    guard model.ai.running || model.ai.investigation?.status == .waiting else { return true }
    let alert=NSAlert(); alert.alertStyle = .warning
    alert.messageText=model.t("Stop the AI investigation before leaving?")
    alert.informativeText=model.t("Saved findings remain available. Unsubmitted answers will be lost; reopening the window does not resume this task automatically.")
    alert.addButton(withTitle: model.t("Keep Open")); alert.addButton(withTitle: model.t("Stop and Leave"))
    guard alert.runModal() == .alertSecondButtonReturn else { return false }
    model.ai.stop(); return true
}

@MainActor
private func confirmStopping(_ model: AppModel, closingWindow: Bool) -> Bool {
    let alert=NSAlert()
    alert.alertStyle = .warning
    alert.messageText=model.t(closingWindow ? "Stop the operation and close this window?" : "Stop the operation and quit Shou?")
    alert.informativeText=model.t(model.developerTools.executing || model.developerTools.configuration.mutating
        ? "The package manager is working. Shou will wait for its result before closing."
        : model.packageUpdates.executing
        ? "Stopping may leave the current package changed. Check its installed version before retrying."
        : "The operation will stop at a safe boundary. Unstarted items will stay unchanged. Review processed items in History; they are not automatically restored.")
    alert.addButton(withTitle: model.t("Keep Open"))
    alert.addButton(withTitle: model.t(closingWindow ? "Stop and Close" : "Stop and Quit"))
    return alert.runModal() == .alertSecondButtonReturn
}

@MainActor
final class ShouApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending=false

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let menu=NSMenu()
        let open=NSMenuItem(title:model.t("Open System Monitor"),action:#selector(openMonitor),keyEquivalent:"")
        open.target=self; open.isEnabled = !model.busy; menu.addItem(open)
        if model.monitor.backgroundEnabled {
            let pause=NSMenuItem(title:model.t(model.monitor.paused ? "Resume Monitoring" : "Pause Monitoring"),action:#selector(pauseMonitor),keyEquivalent:"")
            pause.target=self; menu.addItem(pause)
        }
        return menu
    }
    @objc private func openMonitor() {
        model?.openSystemMonitor()
    }
    @objc private func pauseMonitor() { if let model { model.monitor.setPaused(!model.monitor.paused) } }

    func applicationWillTerminate(_ notification: Notification) { model?.monitor.shutdown() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        if let model, !confirmLeavingAI(model) { return .terminateCancel }
        guard let model, model.isExecuting else { return .terminateNow }
        guard confirmStopping(model, closingWindow: false) else { return .terminateCancel }
        terminationPending=true
        Task {
            let finished=await model.stopAndWaitForExecution()
            terminationPending=false
            sender.reply(toApplicationShouldTerminate: finished)
        }
        return .terminateLater
    }
}

/// Preserve SwiftUI's window delegate while guarding close requests during mutations.
struct OperationWindowGuard: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> WindowProbe {
        let view=WindowProbe()
        view.coordinator=context.coordinator
        context.coordinator.model=model
        return view
    }
    func updateNSView(_ view: WindowProbe, context: Context) {
        context.coordinator.model=model
        context.coordinator.attach(to: view.window)
    }
    static func dismantleNSView(_ view: WindowProbe, coordinator: Coordinator) { coordinator.detach() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class WindowProbe: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var model: AppModel?
        private weak var window: NSWindow?
        private weak var originalDelegate: (any NSWindowDelegate)?
        private var closing=false

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                detach(); self.window=window
                lifecycleLog.notice("Window guard attached; number=\(window.windowNumber)")
                adaptToVisibleScreen(window)
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.adaptToVisibleScreen(window)
                }
            }
            if window.delegate !== self {
                originalDelegate=window.delegate
                window.delegate=self
            }
        }
        func detach() {
            if window?.delegate === self { window?.delegate=originalDelegate }
            window=nil; originalDelegate=nil
        }
        func adaptToVisibleScreen(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            var frame = window.frame
            var changed = false

            if frame.height > visible.height {
                frame.size.height = visible.height
                changed = true
            }
            if frame.width > visible.width {
                frame.size.width = visible.width
                changed = true
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY
                changed = true
            }
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - frame.height
                changed = true
            }
            if frame.minX < visible.minX {
                frame.origin.x = visible.minX
                changed = true
            } else if frame.maxX > visible.maxX {
                frame.origin.x = visible.maxX - frame.width
                changed = true
            }

            if changed {
                window.setFrame(frame, display: true)
                lifecycleLog.notice("Window adapted to visible frame; origin=(\(frame.origin.x),\(frame.origin.y)), size=\(frame.size.width)x\(frame.size.height)")
            }
        }
        func windowDidChangeScreen(_ notification: Notification) {
            if let window { adaptToVisibleScreen(window) }
            originalDelegate?.windowDidChangeScreen?(notification)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            lifecycleLog.notice("Window close requested; waiting=\(self.closing), executing=\(self.model?.isExecuting ?? false)")
            guard !closing else { return false }
            if let model, !confirmLeavingAI(model) { return false }
            guard let model, model.isExecuting else {
                let allowed=originalDelegate?.windowShouldClose?(sender) ?? true
                lifecycleLog.notice("Original window close decision=\(allowed)")
                return allowed
            }
            guard confirmStopping(model, closingWindow: true) else { return false }
            closing=true
            Task {
                let finished=await model.stopAndWaitForExecution()
                lifecycleLog.notice("Window stop completed; close allowed=\(finished)")
                closing=false
                if finished {
                    // Completion can present a sheet while the task is finishing.
                    // performClose ignores a parent with an attached sheet; the
                    // confirmed close must dismiss that result and close directly.
                    model.completion=nil
                    if originalDelegate?.windowShouldClose?(sender) ?? true { sender.close() }
                }
            }
            return false
        }
        func windowWillClose(_ notification: Notification) {
            model?.ai.stop()
            model?.packageUpdates.stop()
            model?.developerTools.stop()
            model?.monitor.setVisible(false)
            lifecycleLog.notice("Window will close; number=\(self.window?.windowNumber ?? -1)")
            originalDelegate?.windowWillClose?(notification)
        }
        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { originalDelegate?.responds(to: selector) ?? false }
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            MainActor.assumeIsolated {
                ForwardedTarget(value: originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector))
            }.value
        }
        // Objective-C forwarding runs synchronously on AppKit's main thread.
        // The box satisfies assumeIsolated's return constraint without transferring the delegate.
        private struct ForwardedTarget: @unchecked Sendable { let value: Any? }
    }
}
