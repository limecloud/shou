import Foundation
import ShouCore
import ShouPlatform

func diagnosticsDistinguishesUnknownAndLowCapacity() throws {
    func report(_ capacity: Int64?, _ free: Int64?) -> DiagnosticReport {
        DiagnosticReport(applicationVersion: "0.14.0", platform: "macos", architecture: "arm64", systemVersion: "15.0.0",
            processorCount: 8, physicalMemoryBytes: 16_000_000_000, capacityBytes: capacity, freeBytes: free,
            diskAccess: .available, records: .privateDirectory, now: Date(timeIntervalSince1970: 1_000))
    }
    for (capacity, free): (Int64?, Int64?) in [(nil, nil), (0, 0), (100, -1), (100, 101), (100, nil)] {
        let value=report(capacity, free)
        try expect(value.status == "partial" && value.volumeFreeBytes == nil && value.volumeCapacityBytes == nil)
        try expect(value.checks.first?.state == .unknown)
    }
    try expect(report(100_000_000_000, 10_000_000_000).checks.first?.state == .attention)
    try expect(report(100_000_000_000, 10_000_000_001).checks.first?.state == .normal)
    try expect(report(2_000_000_000, 1_000_000_000).checks.first?.state == .attention)
    let full=report(Int64.max, Int64.max)
    try expect(full.status == "complete" && full.checks.first?.state == .normal)
    try expect(try JSONValue.from(full)["status"] == .string("complete"))
    try expect(full.text(locale: "zh-CN").contains("诊断报告"))
    try expect(full.text(locale: "zh-CN").contains("系统: macos"))
    try expect(full.text(locale: "en").contains("Nothing is uploaded"))
    try expect(Set(full.checks.map(\.id)).count == 3)
}

func nativeDiagnosticsPreservesRecordsAndExcludesPrivateData() throws {
    let fixture=try Fixture(), fm=FileManager.default
    let missing=fixture.base.appendingPathComponent("private-user-name/not-created")
    let report=try NativeDiagnostics.collect(applicationVersion: "0.14.0", directory: missing)
    try expect(report.checks.first { $0.id == "local_records" }?.state == .notConfigured)
    try expect(!fm.fileExists(atPath: missing.deletingLastPathComponent().path))
    let privateDirectory=fixture.base.appendingPathComponent("private-diagnostics-records")
    try fm.createDirectory(at: privateDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let secret=privateDirectory.appendingPathComponent("private-session-token.txt"), bytes=Data("generated-private-session-content".utf8)
    try bytes.write(to: secret)
    let before=try fm.attributesOfItem(atPath: secret.path)
    let observed=try NativeDiagnostics.collect(applicationVersion: "0.14.0", directory: privateDirectory)
    try expect(observed.checks.first { $0.id == "local_records" }?.state == .normal)
    let data=try Codec.encode(observed), text=String(decoding: data, as: UTF8.self) + observed.text(locale: "en")
    for value in [fixture.base.path, "private-user-name", secret.lastPathComponent, "generated-private-session-content"] { try expect(!text.contains(value)) }
    try expect(try Data(contentsOf: secret) == bytes)
    try expect(try fm.contentsOfDirectory(atPath: privateDirectory.path) == [secret.lastPathComponent])
    try expect((try fm.attributesOfItem(atPath: secret.path)[.modificationDate] as? Date) == (before[.modificationDate] as? Date))
    let link=fixture.base.appendingPathComponent("record-link")
    try fm.createSymbolicLink(at: link, withDestinationURL: privateDirectory)
    try expect(try NativeDiagnostics.collect(applicationVersion: "0.14.0", directory: link).checks.first { $0.id == "local_records" }?.state == .attention)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateDirectory.path)
    try expect(try NativeDiagnostics.collect(applicationVersion: "0.14.0", directory: privateDirectory).checks.first { $0.id == "local_records" }?.state == .attention)
    try expect((try fm.attributesOfItem(atPath: privateDirectory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
}

func nativeDiagnosticsHonorsCancellation() async throws {
    let fixture=try Fixture(), missing=fixture.base.appendingPathComponent("cancelled-records")
    let work=Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try NativeDiagnostics.collect(applicationVersion: "0.14.0", directory: missing)
    }
    do { _ = try await work.value; throw CheckFailure(description: "Cancelled diagnostics must not publish a report") }
    catch is CancellationError {}
    try expect(!FileManager.default.fileExists(atPath: missing.path))
}
