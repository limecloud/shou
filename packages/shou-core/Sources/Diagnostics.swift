import Foundation

public enum DiagnosticState: String, Codable, Sendable {
    case normal, attention, unknown, notConfigured = "not_configured", notApplicable = "not_applicable"

    public var title: String {
        switch self {
        case .normal: "Available"
        case .attention: "Needs attention"
        case .unknown: "Could not verify"
        case .notConfigured: "Not configured"
        case .notApplicable: "Not required"
        }
    }
}

public enum DiagnosticRecordState: String, Codable, Sendable {
    case privateDirectory = "private_directory", missing, unsafe, unavailable
}

public enum DiagnosticDiskAccess: String, Codable, Sendable {
    case available, limited, unknown, notRequired = "not_required"
}

public struct DiagnosticCheck: Codable, Sendable, Identifiable {
    public let id: String
    public let state: DiagnosticState
    public let title: String
    public let explanation: String
    public let nextStep: String?
}

/// Export only explicitly modelled facts. Errors, paths and process metadata
/// cannot enter a support report through a free-form diagnostic payload.
public struct DiagnosticReport: Codable, Sendable {
    public let formatVersion: Int
    public let createdAt: Date
    public let applicationVersion: String
    public let platform: String
    public let architecture: String
    public let systemVersion: String
    public let processorCount: Int
    public let physicalMemoryBytes: UInt64
    public let volumeCapacityBytes: Int64?
    public let volumeFreeBytes: Int64?
    public let checks: [DiagnosticCheck]
    public let status: String

    public init(applicationVersion: String, platform: String, architecture: String, systemVersion: String,
                processorCount: Int, physicalMemoryBytes: UInt64, capacityBytes: Int64?, freeBytes: Int64?,
                diskAccess: DiagnosticDiskAccess, records: DiagnosticRecordState, now: Date = Date()) {
        self.formatVersion=1; self.createdAt=now; self.applicationVersion=applicationVersion; self.platform=platform
        self.architecture=architecture; self.systemVersion=systemVersion
        self.processorCount=processorCount; self.physicalMemoryBytes=physicalMemoryBytes
        let capacity=capacityBytes ?? 0, free=freeBytes ?? -1
        let spaceValid=capacity > 0 && free >= 0 && free <= capacity
        self.volumeCapacityBytes=spaceValid ? capacityBytes : nil
        self.volumeFreeBytes=spaceValid ? freeBytes : nil
        var result=[DiagnosticCheck]()
        let lowSpace=spaceValid && (free < 1_073_741_824 || Double(free) / Double(capacity) <= 0.1)
        result.append(DiagnosticCheck(id: "disk_capacity", state: !spaceValid ? .unknown : lowSpace ? .attention : .normal,
            title: "Available disk space", explanation: !spaceValid ? "Disk capacity could not be observed." : lowSpace ? "Low free space can prevent scans and durable operation records." : "Disk capacity was observed without scanning files.",
            nextStep: !spaceValid ? "Check that the home volume is available, then run diagnostics again." : lowSpace ? "Review large files and old scan indexes, then rescan after freeing space." : nil))
        let accessState: DiagnosticState = switch diskAccess {
        case .available: .normal
        case .limited: .attention
        case .unknown: .unknown
        case .notRequired: .notApplicable
        }
        let accessExplanation: String = switch diskAccess {
        case .available: "The disk-access sentinel is readable; individual locations may still be restricted."
        case .limited: "Protected locations may be omitted because disk access is limited."
        case .unknown: "Disk access could not be verified; this does not establish complete scan coverage."
        case .notRequired: "This platform does not use the macOS disk-access sentinel."
        }
        result.append(DiagnosticCheck(id: "disk_access", state: accessState, title: "Disk access", explanation: accessExplanation,
            nextStep: accessState == .attention || accessState == .unknown ? "Review disk permissions in the Setup Guide, then scan again." : nil))
        let recordState: DiagnosticState = switch records {
        case .privateDirectory: .normal
        case .missing: .notConfigured
        case .unsafe: .attention
        case .unavailable: .unknown
        }
        let recordExplanation: String = switch records {
        case .privateDirectory: "The local record directory is private to the current user. Contents and write access were not tested."
        case .missing: "Local records have not been created. Diagnostics does not create them."
        case .unsafe: "The local record location is not a verified private directory."
        case .unavailable: "The local record directory could not be inspected."
        }
        result.append(DiagnosticCheck(id: "local_records", state: recordState, title: "Local records", explanation: recordExplanation,
            nextStep: records == .unsafe || records == .unavailable ? "Review the configured local data location. Existing records and permissions were not changed." : nil))
        checks=result
        status=result.contains { $0.state == .unknown } ? "partial" : "complete"
    }

    public func text(locale: String) -> String {
        func t(_ key: String) -> String { L10n.string(key, locale: locale) }
        var lines=[t("Shou Diagnostic Report"), "\(t("Version")): \(applicationVersion)",
            "\(t("System")): \(platform) \(systemVersion) (\(architecture))",
            "\(t("Observed at")): \(ISO8601DateFormatter().string(from: createdAt))",
            "\(t("Processor count")): \(processorCount)", "\(t("Physical memory (bytes)")): \(physicalMemoryBytes)"]
        if let volumeFreeBytes, let volumeCapacityBytes { lines.append("\(t("Disk free / capacity (bytes)")): \(volumeFreeBytes) / \(volumeCapacityBytes)") }
        for check in checks {
            lines += ["", "\(t(check.title)): \(t(check.state.title))", t(check.explanation)]
            if let next=check.nextStep { lines.append(t(next)) }
        }
        lines += ["", t("This report contains bounded system facts, not personal paths or file contents. Nothing is uploaded.")]
        return lines.joined(separator: "\n") + "\n"
    }
}
