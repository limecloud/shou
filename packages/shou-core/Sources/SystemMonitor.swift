import Foundation

public struct MonitorCPUCounter: Sendable {
    public var busy: UInt64
    public var idle: UInt64
    public init(busy: UInt64, idle: UInt64) { self.busy=busy; self.idle=idle }
}
public struct MonitorIOCounter: Sendable {
    public var received: UInt64
    public var sent: UInt64
    public var scope: String
    public init(received: UInt64, sent: UInt64, scope: String) { self.received=received; self.sent=sent; self.scope=scope }
}
public struct MonitorProcessCounter: Sendable, Identifiable {
    public var id: String
    public var pid: Int32
    public var name: String
    public var cpuSeconds: Double
    public var memoryBytes: UInt64
    public init(id: String, pid: Int32, name: String, cpuSeconds: Double, memoryBytes: UInt64) {
        self.id=id; self.pid=pid; self.name=String(name.prefix(256)); self.cpuSeconds=cpuSeconds; self.memoryBytes=memoryBytes
    }
}
/// Read-only, transient counters. No command lines, environment, file contents or cleanup authority.
public struct SystemMonitorObservation: Sendable {
    public var timestamp=Date()
    public var uptime: Double=0
    public var logicalCPUCount=1
    public var cpu: [MonitorCPUCounter]=[]
    public var corePercent: [Double]=[]
    public var memoryTotal: UInt64?
    public var memoryUsed: UInt64?
    public var memoryCompressed: UInt64?
    public var swapUsed: UInt64?
    public var memoryPressure="Unavailable"
    public var disk: MonitorIOCounter?
    public var network: MonitorIOCounter?
    public var gpuPercent: Double?
    public var batteryPercent: Double?
    public var powerSource="Unavailable"
    public var hardware=""
    public var operatingSystem=""
    public var volumeTotal: UInt64?
    public var volumeAvailable: UInt64?
    public var batteryHealth: Double?
    public var batteryCycles: Int?
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var fanRPM: [Double]=[]
    public var thermalState="Unavailable"
    public var processes: [MonitorProcessCounter]=[]
    public var processCoverage="Complete"
    public var issues: [String: String]=[:]
    public init() {}
}
public protocol SystemMonitorSampling: Sendable {
    func observe() async throws -> SystemMonitorObservation
}
public struct MonitorProcessUsage: Sendable, Identifiable {
    public let counter: MonitorProcessCounter
    public let cpuPercent: Double?
    public var id: String { counter.id }
}
public struct SystemMonitorSample: Sendable {
    public let observation: SystemMonitorObservation
    public let values: [String: Double]
    public let cores: [Double?]
    public let processes: [MonitorProcessUsage]
    public let baseline: Bool
}
/// Rate calculations require the same source, nondecreasing counters and a fresh monotonic interval.
public struct SystemMonitorCalculator: Sendable {
    private var previous: SystemMonitorObservation?
    public private(set) var history: [SystemMonitorSample]=[]
    public init() {}
    public mutating func resetBaseline() { previous=nil }
    public mutating func append(_ observation: SystemMonitorObservation) -> SystemMonitorSample {
        let elapsed=observation.uptime - (previous?.uptime ?? observation.uptime)
        let valid=elapsed.isFinite && elapsed > 0 && elapsed <= 30
        let prior=valid ? previous : nil
        var values: [String: Double]=[:]
        func percent(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0, value <= 100 else { return nil }; return value
        }
        var cores: [Double?]=[]
        if let prior, prior.cpu.count == observation.cpu.count {
            cores=zip(observation.cpu, prior.cpu).map { now, before in
                guard now.busy >= before.busy, now.idle >= before.idle else { return nil }
                let busy=Double(now.busy-before.busy), idle=Double(now.idle-before.idle)
                return busy+idle > 0 ? busy/(busy+idle)*100 : nil
            }
            let measured=cores.compactMap { $0 }
            if measured.count == cores.count && !measured.isEmpty { values["cpu"]=measured.reduce(0,+)/Double(measured.count) }
        }
        if prior != nil, !observation.corePercent.isEmpty {
            cores=observation.corePercent.map { percent($0) }
            if values["cpu"] == nil, cores.count == observation.logicalCPUCount, cores.allSatisfy({ $0 != nil }) {
                values["cpu"]=cores.compactMap { $0 }.reduce(0,+)/Double(cores.count)
            }
        }
        if let total=observation.memoryTotal, let used=observation.memoryUsed, total > 0, used <= total {
            values["memory"]=Double(used)/Double(total)*100
        }
        values["gpu"]=percent(observation.gpuPercent)
        values["battery"]=percent(observation.batteryPercent)
        func rates(_ now: MonitorIOCounter?, _ before: MonitorIOCounter?, _ read: String, _ write: String) {
            guard prior != nil, let now, let before, now.scope == before.scope,
                  now.received >= before.received, now.sent >= before.sent else { return }
            values[read]=Double(now.received-before.received)/elapsed
            values[write]=Double(now.sent-before.sent)/elapsed
        }
        rates(observation.disk, prior?.disk, "diskRead", "diskWrite")
        rates(observation.network, prior?.network, "networkReceive", "networkSend")
        let older=Dictionary((prior?.processes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let processes=observation.processes.map { process -> MonitorProcessUsage in
            var cpu: Double?
            if let before=older[process.id], process.cpuSeconds.isFinite, process.cpuSeconds >= before.cpuSeconds {
                cpu=percent((process.cpuSeconds-before.cpuSeconds)/elapsed/Double(max(1,observation.logicalCPUCount))*100)
            }
            return MonitorProcessUsage(counter: process, cpuPercent: cpu)
        }
        let sample=SystemMonitorSample(observation: observation, values: values, cores: cores, processes: processes, baseline: prior == nil)
        previous=observation; history.append(sample)
        if history.count > 60 { history.removeFirst(history.count-60) }
        return sample
    }
}
