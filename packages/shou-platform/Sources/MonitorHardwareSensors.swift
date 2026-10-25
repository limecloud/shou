#if os(macOS)
import Foundation
import IOKit

/// Fixed telemetry requests only. This type has no SMC write command or fan-control API.
enum MonitorHardwareSensors {
    static func read(chip: String) -> (cpu: Double?,gpu: Double?,fans: [Double]) {
        var iterator: io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("AppleSMC"),&iterator) == KERN_SUCCESS else { return (nil,nil,[]) }
        defer { IOObjectRelease(iterator) }
        for _ in 0..<16 {
            let service=IOIteratorNext(iterator); guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var name=[CChar](repeating:0,count:128)
            guard IORegistryEntryGetName(service,&name) == KERN_SUCCESS else { continue }
            let endpoint=String(decoding:name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern:$0) },as:UTF8.self)
            #if arch(arm64)
            guard endpoint == "AppleSMCKeysEndpoint" else { continue }
            #else
            guard endpoint == "AppleSMC" else { continue }
            #endif
            var connection: io_connect_t=0
            guard IOServiceOpen(service,mach_task_self_,0,&connection) == KERN_SUCCESS, connection != 0 else { continue }
            defer { IOServiceClose(connection) }
            let keys=temperatureKeys(chip)
            func average(_ keys: [String]) -> Double? {
                let values=keys.compactMap { value($0,connection) }.filter { $0.isFinite && $0 > 0 && $0 < 128 }
                return values.isEmpty ? nil : values.reduce(0,+)/Double(values.count)
            }
            var fans: [Double]=[]
            if let count=value("FNum",connection), count >= 0, count <= 8, count.rounded() == count {
                for index in 0..<Int(count) {
                    if let speed=value("F\(index)Ac",connection), speed.isFinite, (0...30_000).contains(speed) { fans.append(speed) }
                    else { fans=[]; break }
                }
            }
            return (average(keys.0),average(keys.1),fans)
        }
        return (nil,nil,[])
    }
    // Known sensor identities; unknown generations do not inherit a guessed temperature mapping.
    private static func temperatureKeys(_ chip: String) -> ([String],[String]) {
        #if arch(x86_64)
        return (["TCAD"],["TCGC"])
        #else
        guard let generation=chip.split(separator:" ").dropFirst().first,
              ["", " Pro", " Max", " Ultra"].contains(String(chip.dropFirst("Apple \(generation)".count))) else { return ([],[]) }
        switch generation {
        case "M1": return (["Tp09","Tp0T","Tp01","Tp05","Tp0D","Tp0H","Tp0L","Tp0P","Tp0X","Tp0b"],["Tg05","Tg0D","Tg0L","Tg0T"])
        case "M2": return (["Tp1h","Tp1t","Tp1p","Tp1l","Tp01","Tp05","Tp09","Tp0D","Tp0X","Tp0b","Tp0f","Tp0j"],["Tg0f","Tg0j"])
        case "M3": return (["Te05","Te0L","Te0P","Te0S","Tf04","Tf09","Tf0A","Tf0B","Tf0D","Tf0E"],["Tf14","Tf18","Tf19","Tf1A","Tf24","Tf28","Tf29","Tf2A"])
        case "M4": return (["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e"],chip == "Apple M4" ? ["Tg0G","Tg0H","Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k"] : ["Tg1U","Tg1k","Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k"])
        case "M5": return (["Tp00","Tp04","Tp08","Tp0C","Tp0G","Tp0K","Tp0O","Tp0R","Tp0U","Tp0X","Tp0a","Tp0d","Tp0g","Tp0j","Tp0m","Tp0p","Tp0u","Tp0y"],[])
        default: return ([],[])
        }
        #endif
    }
    private static func value(_ key: String,_ connection: io_connect_t) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        let code=key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // AppleSMC fixed 80-byte ABI: key 0, key info 28, command 42, payload 48.
        func request(_ command: UInt8,_ metadata: [UInt8] = []) -> [UInt8]? {
            var input=[UInt8](repeating:0,count:80), output=input, length=80
            withUnsafeBytes(of:code) { input.replaceSubrange(0..<4,with:$0) }
            if metadata.count == 12 { input.replaceSubrange(28..<40,with:metadata) }
            input[42]=command
            let status=input.withUnsafeBytes { source in output.withUnsafeMutableBytes { target in
                IOConnectCallStructMethod(connection,2,source.baseAddress,80,target.baseAddress,&length)
            } }
            return status == KERN_SUCCESS && length == 80 && output[40] == 0 ? output : nil
        }
        guard let info=request(9) else { return nil }
        let size=info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:28,as:UInt32.self) }
        let type=info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:32,as:UInt32.self) }
        guard let data=request(5,Array(info[28..<40])) else { return nil }
        switch (type,size) {
        case (0x666c7420,4): return Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:48,as:Float.self) })
        case (0x73703738,2): return Double(Int16(bitPattern:(UInt16(data[48]) << 8)|UInt16(data[49])))/256
        case (0x66706532,2): return Double((UInt16(data[48]) << 8)|UInt16(data[49]))/4
        case (0x75693820,1): return Double(data[48])
        default: return nil
        }
    }
}
#endif
