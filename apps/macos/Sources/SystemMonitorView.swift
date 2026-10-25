import SwiftUI
import ShouCore

struct SystemMonitorView: View {
    @Bindable var model: AppModel
    @Bindable var session: SystemMonitorSession
    @State private var search=""
    @State private var sort="cpu"
    private let columns=Array(repeating:GridItem(.flexible(),spacing:14),count:4)
    private var observation: SystemMonitorObservation? { session.sample?.observation }
    private var metrics: [(String,String)] { [("overview","Resource Status"),("cpu","CPU"),("gpu","GPU"),("memory","Memory"),("battery","Battery"),("diskRead","Disk"),("networkReceive","Network"),("thermal","Thermals & Fans")] }
    private var processes: [MonitorProcessUsage] {
        (session.sample?.processes ?? []).filter { search.isEmpty || $0.counter.name.localizedCaseInsensitiveContains(search) || String($0.counter.pid).contains(search) }.sorted {
            if sort == "memory", $0.counter.memoryBytes != $1.counter.memoryBytes { return $0.counter.memoryBytes > $1.counter.memoryBytes }
            if sort == "cpu", $0.cpuPercent != $1.cpuPercent { return ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
            return $0.counter.pid < $1.counter.pid
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading,spacing: 3) {
                    Text(model.t("System Monitor")).font(.headline)
                    HStack(spacing: 6) {
                        Text(model.t(session.paused ? "Monitoring paused" : session.failed ? "Sampling failed; showing the last observation." : session.sample == nil ? "Collecting rate baseline…" : "Live · Every 2 seconds"))
                        if let observation { Text(observation.timestamp,style:.time).monospacedDigit() }
                    }.font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle(model.t("Menu bar summary"),isOn:Binding(get:{ session.backgroundEnabled },set:{ session.setBackgroundEnabled($0) }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("monitor.background")
                Button(model.t(session.paused ? "Resume Monitoring" : "Pause Monitoring")) { session.setPaused(!session.paused) }
                    .accessibilityIdentifier("monitor.pause")
            }.padding(.horizontal,ShouDesign.workspaceInset).padding(.vertical,14)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    LazyVGrid(columns:columns,alignment:.leading,spacing:14) {
                        ForEach(metrics,id:\.0) { key,title in
                            metricSummary(key,title).accessibilityIdentifier("monitor.metric."+key)
                        }
                    }
                    DisclosureGroup(model.t("CPU cores and memory details")) {
                        VStack(alignment:.leading,spacing:12) {
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:120))],alignment:.leading,spacing:10) {
                                ForEach(Array((session.sample?.cores ?? []).enumerated()),id:\.offset) { index,value in
                                    HStack { Text("CPU \(index+1)"); Spacer(); Text(percent(value)).monospacedDigit() }
                                }
                            }
                            HStack(spacing:24) {
                                Text(model.t("Compressed")+": "+bytes(observation?.memoryCompressed))
                                Text(model.t("Swap Used")+": "+bytes(observation?.swapUsed))
                                Text(model.t("Memory Pressure")+": "+model.t(observation?.memoryPressure ?? "Unavailable"))
                            }.foregroundStyle(.secondary)
                        }.font(.callout).padding(.top,12)
                    }
                    VStack(alignment:.leading,spacing:10) {
                        HStack(spacing:14) {
                            Text(model.t("Processes")).font(.headline)
                            Spacer()
                            TextField(model.t("Search name or PID"),text:$search).textFieldStyle(.roundedBorder).frame(maxWidth:260)
                                .accessibilityIdentifier("monitor.process.search")
                            Picker(model.t("Sort"),selection:$sort) { Text("CPU").tag("cpu"); Text(model.t("Memory")).tag("memory") }.frame(width:170)
                        }
                        Text(model.t("Process CPU uses total machine capacity. Memory is resident size; shared pages may repeat."))
                            .font(.callout).foregroundStyle(.secondary)
                        HStack { Text(model.t("Process")); Spacer(); Text("PID").frame(width:70,alignment:.trailing); Text("CPU").frame(width:80,alignment:.trailing); Text(model.t("Memory")).frame(width:110,alignment:.trailing) }
                            .font(.callout).foregroundStyle(.secondary).padding(.horizontal,14)
                        LazyVStack(spacing:0) {
                            ForEach(processes.prefix(100)) { item in
                                HStack {
                                    Text(item.counter.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength:16)
                                    Text(String(item.counter.pid)).frame(width:70,alignment:.trailing)
                                    Text(percent(item.cpuPercent)).frame(width:80,alignment:.trailing)
                                    Text(bytes(item.counter.memoryBytes)).frame(width:110,alignment:.trailing)
                                }.font(.system(size:ShouDesign.bodyFontSize)).monospacedDigit().padding(.horizontal,14).padding(.vertical,12)
                                Divider().opacity(0.5)
                            }
                            if processes.isEmpty { Text(model.t(session.sample == nil ? "Collecting rate baseline…" : "No matching processes.")).foregroundStyle(.secondary).padding(20) }
                        }.modifier(WorkspaceSurface()).accessibilityIdentifier("monitor.processes")
                        Text(String(format:model.t("Showing %lld of %lld matching processes."),min(100,processes.count),processes.count)+" "+model.t(observation?.processCoverage ?? "Partial process coverage"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(model.t("Last 2 minutes · Gaps mean unavailable"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(model.t("Read-only · History stays in memory · Leaving this page stops sampling unless the summary is enabled."))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.horizontal,ShouDesign.workspaceInset).padding(.bottom,24)
            }
        }.onAppear { session.setVisible(true) }.onDisappear { session.setVisible(false) }
    }
    private func percent(_ value: Double?) -> String { value.map { String(format:"%.1f%%",$0) } ?? "—" }
    private func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.decimal) } ?? "—" }
    private func rate(_ key: String) -> String { session.sample?.values[key].map { bytes(UInt64(min($0,Double(Int64.max))))+"/s" } ?? "—" }
    private func summary(_ key: String) -> String {
        switch key {
        case "diskRead": model.t("Read")+" "+rate("diskRead")+" · "+model.t("Write")+" "+rate("diskWrite")
        case "networkReceive": "↓ "+rate("networkReceive")+" · ↑ "+rate("networkSend")
        default: percent(session.sample?.values[key])
        }
    }
    @ViewBuilder private func metricSummary(_ key: String,_ title: String) -> some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Label(model.t(title),systemImage:symbol(key)).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength:0)
                if key == "cpu" || key == "gpu" {
                    let temperature=key == "cpu" ? observation?.cpuTemperature : observation?.gpuTemperature
                    Text(temperature.map { String(format:"%.0f°C",$0) } ?? "— °C").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(key == "overview" ? model.t(loadState) : key == "thermal" ? model.t(observation?.thermalState ?? "Unavailable") : key == "diskRead" ? bytes(observation?.volumeAvailable) : key == "networkReceive" ? "↓ "+rate(key) : summary(key))
                .font(.system(size:key == "overview" || key == "thermal" ? 20 : ShouDesign.summaryFigureSize,weight:.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.9)
            if ["cpu","gpu","memory","networkReceive","battery"].contains(key) {
                MonitorTrend(history:session.history,keys:key == "networkReceive" ? [key,"networkSend"] : [key]).frame(height:40)
                    .accessibilityLabel(model.t("Recent resource trend")).accessibilityValue(summary(key))
            } else if key == "diskRead" {
                Group {
                    if let volumeFraction { ProgressView(value:volumeFraction).tint(.accentColor).frame(height:40) }
                    else { Text("—").frame(height:40) }
                }
                    .accessibilityLabel(model.t("System volume usage"))
            } else {
                Text(key == "overview" ? (observation?.hardware ?? "—")+" · "+(observation?.operatingSystem ?? "") : fanSummary)
                    .font(.callout).foregroundStyle(.secondary).frame(height:40,alignment:.leading).lineLimit(2)
            }
            Text(detail(key)).font(.callout).foregroundStyle(.secondary).lineLimit(3).frame(height:50,alignment:.topLeading)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            .modifier(WorkspaceSurface()).overlay(RoundedRectangle(cornerRadius:ShouDesign.cardRadius).stroke(Color.secondary.opacity(0.12),lineWidth:1))
    }
    private var volumeFraction: Double? {
        guard let total=observation?.volumeTotal, total > 0, let available=observation?.volumeAvailable else { return nil }
        return 1-Double(min(total,available))/Double(total)
    }
    private var loadState: String {
        guard !session.paused, !session.failed, let cpu=session.sample?.values["cpu"], let memory=session.sample?.values["memory"] else { return "Observation incomplete" }
        return cpu >= 90 || memory >= 90 || ["Serious","Critical"].contains(observation?.thermalState ?? "") ? "High resource usage" : "Observed load normal"
    }
    private var fanSummary: String {
        guard let fans=observation?.fanRPM, !fans.isEmpty else { return model.t("Fan telemetry unavailable") }
        return fans.enumerated().map { "\(model.t("Fan")) \($0.offset+1): \(Int($0.element)) RPM" }.joined(separator:" · ")
    }
    private func symbol(_ key: String) -> String {
        switch key {
        case "overview": "sun.max"
        case "cpu": "cpu"
        case "gpu": "display"
        case "memory": "memorychip"
        case "battery": "battery.100percent"
        case "diskRead": "internaldrive"
        case "networkReceive": "network"
        default: "fan"
        }
    }
    private func detail(_ key: String) -> String {
        if key == "overview" {
            let hours=Int((observation?.uptime ?? 0)/3600)
            return model.t("CPU and memory load; not a hardware health score.")+"\n"+String(format:model.t("Uptime: %lld hours"),hours)
        }
        if key == "thermal" { return model.t("Temperature: available sensor average. Fans are controlled by the system.") }
        if key == "memory" { return bytes(observation?.memoryUsed)+" / "+bytes(observation?.memoryTotal)+" · "+model.t("Swap Used")+" "+bytes(observation?.swapUsed) }
        if key == "battery", session.sample?.values[key] != nil {
            return model.t(observation?.powerSource ?? "Unavailable")+" · "+model.t("Battery Health")+" "+percent(observation?.batteryHealth)+" · "+model.t("Cycles")+" "+(observation?.batteryCycles.map(String.init) ?? "—")
        }
        if key == "diskRead" { return model.t("System volume available")+" / "+bytes(observation?.volumeTotal)+"\n"+summary(key) }
        if key == "networkReceive", session.sample?.values[key] != nil { return "↑ "+rate("networkSend")+"\n"+model.t("Active Ethernet / Wi-Fi interfaces") }
        if session.sample?.values[key] == nil {
            if let issue=observation?.issues[key] { return model.t(issue) }
            return model.t(session.sample?.baseline != false ? "Collecting rate baseline…" : "Counter unavailable or source changed.")
        }
        return key == "cpu" ? model.t("Total machine capacity")+" · "+String(observation?.logicalCPUCount ?? 0)+" "+model.t("Logical cores") : model.t("Busiest GPU engine or device")
    }

}

/// Paths break at missing samples and long gaps. The vertical scale is shared by both IO series.
private struct MonitorTrend: View {
    let history: [SystemMonitorSample]
    let keys: [String]
    var body: some View {
        Canvas { context,size in
            let end=history.last?.observation.timestamp.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            let maximum=keys.count == 1 ? 100 : max(1,history.flatMap { sample in keys.compactMap { sample.values[$0] } }.max() ?? 1)
            var grid=Path()
            for level in 0...4 { let y=size.height*Double(level)/4; grid.move(to:CGPoint(x:0,y:y)); grid.addLine(to:CGPoint(x:size.width,y:y)) }
            context.stroke(grid,with:.color(.secondary.opacity(0.16)),lineWidth:1)
            for (index,key) in keys.enumerated() {
                var path=Path(), previous: Double?
                for sample in history {
                    let time=sample.observation.timestamp.timeIntervalSince1970
                    guard let value=sample.values[key], time >= end-120 else { previous=nil; continue }
                    let point=CGPoint(x:max(0,(time-end+120)/120)*size.width,y:size.height*(1-min(1,value/maximum)))
                    if let previous, time-previous <= 6 && time > previous { path.addLine(to:point) } else { path.move(to:point) }
                    previous=time
                }
                context.stroke(path,with:.color(index == 0 ? .accentColor : .secondary),style:StrokeStyle(lineWidth:2,dash:index == 0 ? [] : [5,3]))
            }
        }
    }
}
