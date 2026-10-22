import Foundation
import ShouCore
import ShouPlatform

private func registrationPayload() -> [String: Any] {
    let key="Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"
    let sources=["windows.user_uninstall64", "windows.user_uninstall32", "windows.machine_uninstall64", "windows.machine_uninstall32", "windows.user_packages"]
    func path(_ id: String) -> String { id == "windows.user_packages" ? "current_user:PackageManager" : (id.hasPrefix("windows.machine_") ? "HKEY_LOCAL_MACHINE\\" : "HKEY_CURRENT_USER\\") + key }
    let rows: [[String: Any]]=sources.enumerated().map { index,id in
        let packaged=index==4
        let registration=packaged ? "Example.App_1.2.3.4_x64__abcd1234" : path(id) + "\\Example"
        return ["id": Digest.sha256(Data((id + "\0" + registration).utf8)), "source_id": id, "registration": registration,
                "name": "同名应用", "version": "1.2.3", "publisher": "Fixture publisher",
                "install_location": packaged ? NSNull() : "C:/Program Files/Example", "estimated_bytes": packaged ? NSNull() : 1048576,
                "kind": packaged ? "msix" : index==2 ? "msi" : "desktop", "system_component": false,
                "uninstall_available": packaged ? NSNull() : true, "package_family_name": packaged ? "Example.App_abcd1234" : NSNull(),
                "evidence_digest": String(repeating: "a", count: 64)]
    }
    return ["sources": sources.map { id in ["source": ["id": id, "path": path(id), "system_owned": id.hasPrefix("windows.machine_")], "status": "complete", "entry_count": 1, "application_count": 1] as [String: Any] }, "items": rows, "issues": []]
}
private func readRegistrations(_ payload: [String: Any], options: ApplicationCatalogOptions = ApplicationCatalogOptions()) throws -> RegisteredApplicationCatalog {
    let data=try JSONSerialization.data(withJSONObject: payload)
    return try WindowsRegisteredApplications(reader: { _ in data }).read(options: options)
}

func windowsRegisteredApplicationsPreserveSourcesIdentityAndUnknownFacts() throws {
    let catalog=try readRegistrations(registrationPayload())
    try expect(catalog.status == "complete" && catalog.items.count == 5 && catalog.sources.count == 5)
    try expect(Set(catalog.items.map(\.id)).count == 5 && Set(catalog.items.map(\.name)).count == 1)
    let package=try require(catalog.items.first { $0.kind == "msix" })
    try expect(package.estimatedBytes == nil && package.uninstallAvailable == nil && package.installLocation == nil)
    try expect(catalog.items.first { $0.sourceId == "windows.machine_uninstall64" }?.kind == "msi")
    try expect(catalog.unavailableSources.contains("application_data_ownership") && catalog.unavailableSources.contains("unregistered_portable_applications"))
    let encoded=String(decoding: try Codec.encode(catalog), as: UTF8.self)
    try expect(!encoded.contains("uninstall_string") && !encoded.contains("command") && !encoded.contains("eligible"))
}

func windowsRegisteredApplicationsRejectForgedCoverageAndUnsafePaths() throws {
    let edits: [(inout [String: Any]) -> Void]=[
        { $0["sources"]=Array(($0["sources"] as! [[String: Any]]).dropLast()) },
        { var rows=$0["items"] as! [[String: Any]];rows[0]["id"]="forged";$0["items"]=rows },
        { var rows=$0["items"] as! [[String: Any]];rows.append(rows[0]);$0["items"]=rows },
        { var rows=$0["items"] as! [[String: Any]];rows[0]["source_id"]="foreign";$0["items"]=rows },
        { var rows=$0["sources"] as! [[String: Any]];rows[0]["application_count"]=0;$0["sources"]=rows },
        { var rows=$0["sources"] as! [[String: Any]];rows[0]["status"]="missing";$0["sources"]=rows },
        { var rows=$0["items"] as! [[String: Any]];rows[0]["evidence_digest"]="unknown";$0["items"]=rows },
        { var rows=$0["items"] as! [[String: Any]];rows[0]["system_component"]=true;$0["items"]=rows },
        { var rows=$0["items"] as! [[String: Any]];rows[0]["estimated_bytes"] = -1;$0["items"]=rows },
        { var rows=$0["items"] as! [[String: Any]];rows[4]["package_family_name"]="../foreign";$0["items"]=rows }
    ]
    for edit in edits { var invalid=registrationPayload();edit(&invalid);try expectThrows { try readRegistrations(invalid) } }
    for path in ["\\\\server\\share", "C:/Apps/../outside", "C:/Apps/cache:stream", "C:/Apps//other", "C:relative", "https://example.invalid"] {
        var invalid=registrationPayload();var rows=invalid["items"] as! [[String: Any]];rows[0]["install_location"]=path;invalid["items"]=rows
        try expectThrows { try readRegistrations(invalid) }
    }
    try expectThrows { try readRegistrations(registrationPayload(), options: ApplicationCatalogOptions(maxEntries: 4)) }
}

func windowsRegisteredApplicationsRetainPartialAndSystemCoverage() throws {
    var payload=registrationPayload();var sources=payload["sources"] as! [[String: Any]];var items=payload["items"] as! [[String: Any]]
    items.removeLast();sources[4]["application_count"]=0;sources[4]["entry_count"]=0;sources[4]["status"]="unavailable"
    payload["sources"]=sources;payload["items"]=items;payload["issues"]=[["path": "current_user:PackageManager", "code": "package_source_unavailable"]]
    let partial=try readRegistrations(payload)
    try expect(partial.status == "partial" && partial.items.count == 4 && partial.sources.last?.status == "unavailable")
    items[0]["system_component"]=true;payload["items"]=items
    try expect(try readRegistrations(payload, options: ApplicationCatalogOptions(includeSystem: true)).items.contains { $0.systemComponent })
    try expectThrows { try WindowsRegisteredApplications(reader: { _ in Data(repeating: 32, count: 8 * 1024 * 1024 + 1) }).read() }
}
