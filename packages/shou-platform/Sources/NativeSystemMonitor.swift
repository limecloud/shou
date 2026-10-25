import Foundation
import ShouCore
#if os(macOS)
import Darwin
import IOKit
import IOKit.ps

public struct NativeSystemMonitor: SystemMonitorSampling {
    public init() {}
    public func observe() async throws -> SystemMonitorObservation {
        try Task.checkCancellation()
        let worker=Task.detached(priority:.utility) { try Self.read() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func read() throws -> SystemMonitorObservation {
        try Task.checkCancellation()
        var result=SystemMonitorObservation()
        result.uptime=ProcessInfo.processInfo.systemUptime
        result.logicalCPUCount=ProcessInfo.processInfo.activeProcessorCount
        result.hardware=systemString("machdep.cpu.brand_string") ?? systemString("hw.model") ?? ""
        let version=ProcessInfo.processInfo.operatingSystemVersion
        result.operatingSystem="macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        result.thermalState=switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unavailable"
        }
        var volume=statfs()
        if statfs("/",&volume) == 0 {
            result.volumeTotal=UInt64(volume.f_blocks)*UInt64(volume.f_bsize)
            result.volumeAvailable=UInt64(volume.f_bavail)*UInt64(volume.f_bsize)
        }
        let sensors=MonitorHardwareSensors.read(chip:result.hardware)
        result.cpuTemperature=sensors.cpu; result.gpuTemperature=sensors.gpu; result.fanRPM=sensors.fans
        if let battery=registry("AppleSmartBattery",key:nil).first?.1 {
            if let cycle=battery["CycleCount"] as? NSNumber, (0...100_000).contains(cycle.intValue) { result.batteryCycles=cycle.intValue }
            #if arch(arm64)
            let full=(battery["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue
            #else
            let full=(battery["AppleRawMaxCapacity"] as? NSNumber ?? battery["MaxCapacity"] as? NSNumber)?.doubleValue
            #endif
            if let full, let design=(battery["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0, full > 0 {
                result.batteryHealth=min(100,full/design*100)
            }
        }
        let host=mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count: natural_t=0, info: processor_info_array_t?
        var length: mach_msg_type_number_t=0
        if host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &length) == KERN_SUCCESS, let info {
            defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(length)*vm_size_t(MemoryLayout<integer_t>.size)) }
            if count <= 4096 && Int(length) >= Int(count)*Int(CPU_STATE_MAX) {
                for core in 0..<Int(count) {
                    let base=core*Int(CPU_STATE_MAX)
                    func tick(_ index: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base+Int(index)])) }
                    result.cpu.append(MonitorCPUCounter(busy: tick(CPU_STATE_USER)+tick(CPU_STATE_SYSTEM)+tick(CPU_STATE_NICE), idle: tick(CPU_STATE_IDLE)))
                }
            }
        }
        var memory=vm_statistics64(), memoryCount=mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size/MemoryLayout<integer_t>.size)
        let memoryStatus=withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &memoryCount) }
        }
        if memoryStatus == KERN_SUCCESS {
            let total=ProcessInfo.processInfo.physicalMemory, page=UInt64(getpagesize())
            let available=(UInt64(memory.free_count)+UInt64(memory.inactive_count))*page
            result.memoryTotal=total; result.memoryUsed=total-min(total,available)
            result.memoryCompressed=UInt64(memory.compressor_page_count)*page
        }
        var swap=xsw_usage(), swapSize=MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { result.swapUsed=swap.xsu_used }
        var pressure: Int32=0, pressureSize=MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 {
            result.memoryPressure=pressure == 1 ? "Normal" : pressure == 2 ? "Warning" : pressure == 4 ? "Critical" : "Unavailable"
        }
        let disks=registry("IOBlockStorageDriver", key: "Statistics")
        var read: UInt64=0, written: UInt64=0, diskIds: [String]=[], diskOverflow=false
        for (identity, stats) in disks {
            if let bytesRead=stats["Bytes (Read)"] as? NSNumber, let bytesWritten=stats["Bytes (Write)"] as? NSNumber {
                let nextRead=read.addingReportingOverflow(bytesRead.uint64Value), nextWrite=written.addingReportingOverflow(bytesWritten.uint64Value)
                if nextRead.overflow || nextWrite.overflow { diskOverflow=true; break }
                read=nextRead.partialValue; written=nextWrite.partialValue; diskIds.append(identity)
            }
        }
        if !diskOverflow && !diskIds.isEmpty { result.disk=MonitorIOCounter(received: read, sent: written, scope: diskIds.sorted().joined(separator: ",")) }
        let gpu=registry("IOAccelerator", key: "PerformanceStatistics").compactMap { _, stats in
            (stats["Device Utilization %"] as? NSNumber)?.doubleValue
        }.filter { $0.isFinite && $0 >= 0 && $0 <= 100 }
        result.gpuPercent=gpu.max()
        if gpu.isEmpty { result.issues["gpu"]="GPU counters are unavailable on this device." }
        result.network=network()
        if let powerInfo=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources=IOPSCopyPowerSourcesList(powerInfo)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description=IOPSGetPowerSourceDescription(powerInfo, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current=description[kIOPSCurrentCapacityKey] as? NSNumber,
                      let maximum=description[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0 else { continue }
                result.batteryPercent=current.doubleValue/maximum.doubleValue*100
                result.powerSource=(description[kIOPSIsChargingKey] as? Bool) == true ? "Charging" :
                    description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue ? "AC Power" : "Battery Power"
                break
            }
        }
        if result.batteryPercent == nil { result.issues["battery"]="No readable internal battery was found." }
        let processStart=ProcessInfo.processInfo.systemUptime
        let required=proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        if required > 0 {
            let capacity=min(Int(required)/MemoryLayout<Int32>.size+128,4096)
            var pids=[Int32](repeating: 0,count: capacity)
            let returned=pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS),0,$0.baseAddress,Int32($0.count)) }
            var skipped=0
            for pid in pids.prefix(max(0, min(Int(returned)/4,capacity))) where pid > 0 {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime-processStart > 0.6 { result.processCoverage="Partial process coverage"; break }
                var task=proc_taskinfo(), bsd=proc_bsdinfo()
                let taskSize=Int32(MemoryLayout<proc_taskinfo>.size), bsdSize=Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid,PROC_PIDTASKINFO,0,&task,taskSize) == taskSize,
                      proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&bsd,bsdSize) == bsdSize else { skipped += 1; continue }
                var name=[CChar](repeating:0,count:256)
                guard proc_name(pid,&name,UInt32(name.count)) > 0 else { skipped += 1; continue }
                result.processes.append(MonitorProcessCounter(id: "\(pid):\(bsd.pbi_start_tvsec):\(bsd.pbi_start_tvusec)", pid: pid,
                    name: String(decoding:name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern:$0) },as:UTF8.self), cpuSeconds: (Double(task.pti_total_user)+Double(task.pti_total_system))/1e9, memoryBytes: task.pti_resident_size))
            }
            if skipped > 0 || required/4 >= capacity { result.processCoverage="Partial process coverage" }
        } else { result.processCoverage="Partial process coverage" }
        return result
    }
    private static func systemString(_ key: String) -> String? {
        var length=0
        guard sysctlbyname(key,nil,&length,nil,0) == 0, (1...4096).contains(length) else { return nil }
        var bytes=[UInt8](repeating:0,count:length)
        guard sysctlbyname(key,&bytes,&length,nil,0) == 0 else { return nil }
        return String(decoding:bytes.prefix(while: { $0 != 0 }),as:UTF8.self)
    }
    private static func registry(_ kind: String, key: String?) -> [(String,[String: Any])] {
        var iterator: io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kind), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(String,[String: Any])]=[]
        for _ in 0..<256 {
            let service=IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            var identity: UInt64=0
            guard IORegistryEntryGetRegistryEntryID(service,&identity) == KERN_SUCCESS else { continue }
            var properties: Unmanaged<CFMutableDictionary>?
            let property: [String: Any]?
            if let key { property=IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? [String: Any] }
            else { _ = IORegistryEntryCreateCFProperties(service,&properties,kCFAllocatorDefault,0); property=properties?.takeRetainedValue() as? [String: Any] }
            guard let property else { continue }
            result.append((String(identity),property))
        }
        return result
    }
    private static func network() -> MonitorIOCounter? {
        var mib: [Int32]=[CTL_NET,PF_ROUTE,0,0,NET_RT_IFLIST2,0], length=0
        guard sysctl(&mib,6,nil,&length,nil,0) == 0, length > 0, length <= 2_097_152 else { return nil }
        var bytes=[UInt8](repeating:0,count:length)
        guard sysctl(&mib,6,&bytes,&length,nil,0) == 0, length <= bytes.count else { return nil }
        var offset=0, received: UInt64=0, sent: UInt64=0, names: [String]=[]
        while offset+4 <= length {
            let size=bytes.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset:offset,as:UInt16.self)) }
            guard size >= 4, offset+size <= length else { return nil }
            if bytes[offset+3] == RTM_IFINFO2, size >= MemoryLayout<if_msghdr2>.size {
                let info=bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:offset,as:if_msghdr2.self) }
                var name=[CChar](repeating:0,count:Int(IF_NAMESIZE))
                if if_indextoname(UInt32(info.ifm_index),&name) != nil, info.ifm_flags & IFF_UP != 0 {
                    let value=String(decoding:name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern:$0) },as:UTF8.self)
                    // Physical Ethernet/Wi-Fi interfaces; exclude loopback, VPN and virtual tunnels.
                    if value.hasPrefix("en"), value.dropFirst(2).allSatisfy(\.isNumber), value.count > 2 {
                        let nextRead=received.addingReportingOverflow(info.ifm_data.ifi_ibytes), nextWrite=sent.addingReportingOverflow(info.ifm_data.ifi_obytes)
                        guard !nextRead.overflow && !nextWrite.overflow else { return nil }
                        received=nextRead.partialValue; sent=nextWrite.partialValue; names.append(value)
                    }
                }
            }
            offset += size
        }
        return names.isEmpty ? nil : MonitorIOCounter(received:received,sent:sent,scope:names.sorted().joined(separator:","))
    }
}
#endif
