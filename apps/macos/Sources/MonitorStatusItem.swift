import AppKit
import ShouCore

@MainActor final class MonitorStatusItem: NSObject, NSMenuDelegate {
    private weak var model: AppModel?
    private let session: SystemMonitorSession
    private var item: NSStatusItem?
    init(model: AppModel) {
        self.model=model; self.session=model.monitor
        super.init()
        session.updated={ [weak self] in self?.refresh() }
        refresh()
    }
    private func refresh() {
        guard session.backgroundEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }; item=nil; return
        }
        if item == nil {
            item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            let menu=NSMenu(); menu.delegate=self; item?.menu=menu
        }
        func percent(_ key: String) -> String { session.sample?.values[key].map { String(format:"%.0f%%",$0) } ?? "—" }
        let state=session.paused ? "Monitoring paused" : session.failed ? "Sampling failed; showing the last observation." : "Live, Every 2 seconds"
        item?.button?.title=(session.paused || session.failed ? "◷ " : "")+"CPU "+percent("cpu")+", "+t("Memory")+" "+percent("memory")
        item?.button?.toolTip="Shou, "+t("System Monitor")+", "+t(state)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ value: String) { let row=NSMenuItem(title:value,action:nil,keyEquivalent:""); row.isEnabled=false; menu.addItem(row) }
        func percent(_ key: String) -> String { session.sample?.values[key].map { String(format:"%.1f%%",$0) } ?? "—" }
        func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.decimal) } ?? "—" }
        func rate(_ key: String) -> String { session.sample?.values[key].map { bytes(UInt64(min(Double(Int64.max),$0)))+"/s" } ?? "—" }
        let observation=session.sample?.observation
        info("Shou, "+t("System Monitor"))
        info(t(session.paused ? "Monitoring paused" : session.failed ? "Sampling failed; showing the last observation." : "Live, Every 2 seconds")+(observation.map { ", "+$0.timestamp.formatted(date:.omitted,time:.standard) } ?? ""))
        menu.addItem(.separator())
        info("CPU "+percent("cpu")+", GPU "+percent("gpu"))
        info(t("Memory")+" "+bytes(observation?.memoryUsed)+" / "+bytes(observation?.memoryTotal)+", "+percent("memory"))
        info(t("Disk")+", "+t("Read")+" "+rate("diskRead")+", "+t("Write")+" "+rate("diskWrite"))
        info(t("Network")+", ↓ "+rate("networkReceive")+", ↑ "+rate("networkSend"))
        info(t("Battery")+" "+percent("battery")+", "+t(observation?.powerSource ?? "Unavailable"))
        info(t("Thermals & Fans")+", "+t(observation?.thermalState ?? "Unavailable")+", "+(observation?.fanRPM.first.map { String(format:"%.0f RPM",$0) } ?? "—"))
        if let processes=session.sample?.processes, !processes.isEmpty {
            menu.addItem(.separator()); info(t("Top CPU processes"))
            for process in processes.sorted(by:{ ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }).prefix(3) {
                info(String(process.counter.name.prefix(40))+", "+(process.cpuPercent.map { String(format:"%.1f%%",$0) } ?? "—"))
            }
        }
        menu.addItem(.separator())
        add(menu,t("Open System Monitor"),#selector(openMonitor))
        add(menu,t(session.paused ? "Resume Monitoring" : "Pause Monitoring"),#selector(togglePause))
        menu.addItem(.separator())
        add(menu,t("Disable Summary"),#selector(disable))
        add(menu,t("Quit Shou"),#selector(quit))
    }
    private func t(_ key: String) -> String { model?.t(key) ?? key }
    private func add(_ menu: NSMenu,_ title: String,_ action: Selector) {
        let command=NSMenuItem(title:title,action:action,keyEquivalent:""); command.target=self; menu.addItem(command)
    }
    @objc private func openMonitor() {
        model?.openSystemMonitor()
    }
    @objc private func togglePause() { session.setPaused(!session.paused) }
    @objc private func disable() { session.setBackgroundEnabled(false) }
    @objc private func quit() { NSApp.terminate(nil) }
}
