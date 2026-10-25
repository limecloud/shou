import Foundation
import ShouCore
import ShouPlatform

private func monitorObservation(_ time: Double,_ busy: UInt64=100,_ received: UInt64=100) -> SystemMonitorObservation {
    var value=SystemMonitorObservation(); value.uptime=time; value.logicalCPUCount=2
    value.cpu=[MonitorCPUCounter(busy:busy,idle:100)]
    value.disk=MonitorIOCounter(received:received,sent:received,scope:"disk1")
    value.network=MonitorIOCounter(received:received,sent:received,scope:"en0")
    value.memoryTotal=1000; value.memoryUsed=500
    value.processes=[MonitorProcessCounter(id:"42:start1",pid:42,name:"fixture",cpuSeconds:time,memoryBytes:50)]
    return value
}
func monitorRatesRequireFreshStableCounters() throws {
    var calculator=SystemMonitorCalculator()
    let first=calculator.append(monitorObservation(1))
    try expect(first.values["cpu"] == nil && first.values["diskRead"] == nil && first.processes[0].cpuPercent == nil)
    let next=calculator.append(monitorObservation(3,200,500))
    try expect(next.values["cpu"] == 100 && next.values["diskRead"] == 200 && next.values["memory"] == 50)
    try expect(next.processes[0].cpuPercent == 50)
    var changed=monitorObservation(5,300,800); changed.disk?.scope="disk2"; changed.network?.received=1
    let reset=calculator.append(changed)
    try expect(reset.values["diskRead"] == nil && reset.values["networkReceive"] == nil)
    let sleep=calculator.append(monitorObservation(50,400,900))
    try expect(sleep.baseline && sleep.values["cpu"] == nil && sleep.processes[0].cpuPercent == nil)
    calculator.resetBaseline()
    try expect(calculator.append(monitorObservation(51,500,1000)).baseline)
}
func monitorHandlesGroupsReuseMissingDataAndBoundsHistory() throws {
    var calculator=SystemMonitorCalculator()
    var observation=monitorObservation(1); observation.cpu=[]; observation.corePercent=[20,60]; observation.gpuPercent = .nan
    try expect(calculator.append(observation).values["cpu"] == nil)
    observation.uptime=3; observation.processes=[MonitorProcessCounter(id:"42:start2",pid:42,name:"new",cpuSeconds:100,memoryBytes:0)]
    let next=calculator.append(observation)
    try expect(next.values["cpu"] == 40 && next.values["gpu"] == nil && next.processes[0].cpuPercent == nil)
    observation.uptime=5; observation.corePercent=[20]; observation.memoryUsed=1001
    let partial=calculator.append(observation)
    try expect(partial.values["cpu"] == nil && partial.values["memory"] == nil)
    for index in 0..<100 { observation.uptime=Double(index+10); _ = calculator.append(observation) }
    try expect(calculator.history.count == 60)
}

private actor MonitorControlledSource: SystemMonitorSampling {
    private var pending: CheckedContinuation<SystemMonitorObservation,any Error>?
    private(set) var calls=0
    func observe() async throws -> SystemMonitorObservation {
        calls += 1
        return try await withCheckedThrowingContinuation { pending=$0 }
    }
    func complete(_ value: SystemMonitorObservation) { pending?.resume(returning:value); pending=nil }
    func fail() { pending?.resume(throwing:CocoaError(.fileReadUnknown)); pending=nil }
}
@MainActor func monitorSessionRejectsLateResultsAndStopsWhenHidden() async throws {
    let source=MonitorControlledSource(), session=SystemMonitorSession(source:source,interval:.milliseconds(5))
    func waitFor(_ calls: Int) async throws {
        for _ in 0..<200 { if await source.calls >= calls { return }; try await Task.sleep(for:.milliseconds(2)) }
        throw CheckFailure(description:"monitor serial sampler timed out")
    }
    session.setVisible(true); try await waitFor(1)
    session.setPaused(true); session.setPaused(false)
    try await Task.sleep(for:.milliseconds(10)); try expect(await source.calls == 1)
    await source.complete(monitorObservation(1)); try await waitFor(2)
    try expect(session.sample == nil)
    await source.complete(monitorObservation(3)); try await waitFor(3)
    try expect(session.sample?.baseline == true)
    await source.fail(); try await waitFor(4); try expect(session.failed)
    session.setVisible(false); await source.complete(monitorObservation(5)); try await Task.sleep(for:.milliseconds(15))
    try expect(await source.calls == 4 && session.sample?.observation.uptime == 3)
    session.setBackgroundEnabled(true); try await waitFor(5)
    await source.complete(monitorObservation(7)); try await waitFor(6); try expect(session.sample?.baseline == true)
    session.shutdown(); await source.complete(monitorObservation(9)); try await Task.sleep(for:.milliseconds(10))
    try expect(session.sample?.observation.uptime == 7)
}
func nativeMonitorReadsWithoutMutation() async throws {
    #if os(macOS)
    let source=NativeSystemMonitor(), first=try await source.observe()
    try expect(first.uptime > 0 && first.logicalCPUCount > 0 && !first.cpu.isEmpty)
    try expect(first.memoryTotal != nil && first.memoryUsed != nil && !first.hardware.isEmpty)
    try expect(first.processes.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    try expect(first.processes.count <= 4096 && first.fanRPM.allSatisfy { $0.isFinite && $0 >= 0 })
    let before=try require(first.processes.first { $0.pid == ProcessInfo.processInfo.processIdentifier })
    let until=ProcessInfo.processInfo.systemUptime+0.12
    while ProcessInfo.processInfo.systemUptime < until { _ = sqrt(ProcessInfo.processInfo.systemUptime) }
    let after=try require(try await source.observe().processes.first { $0.pid == ProcessInfo.processInfo.processIdentifier })
    try expect(after.cpuSeconds-before.cpuSeconds >= 0.08 && after.cpuSeconds-before.cpuSeconds < 2)
    print("Native monitor: \(first.cpu.count) cores, \(first.processes.count) processes (\(first.processCoverage)); CPU temperature \(first.cpuTemperature.map(String.init(describing:)) ?? "unavailable"), GPU \(first.gpuPercent.map(String.init(describing:)) ?? "unavailable"), fans \(first.fanRPM.count).")
    #endif
}
