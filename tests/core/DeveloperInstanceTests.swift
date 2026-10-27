import Foundation
import ShouCore
import ShouPlatform
#if os(macOS)
import Darwin

private struct GeneratedInstanceServices: DeveloperServiceOperating {
    let instances: NativeDeveloperInstances
    func scan(catalog: DeveloperToolCatalog, inventory: DeveloperToolInventory) throws -> DeveloperServiceSnapshot { try instances.scan(inventory: inventory) }
    func inspect(_ expected: DeveloperService) throws -> DeveloperService { try instances.inspect(expected) }
    func setRunning(_ running: Bool, expected: DeveloperService, expiresAt: Date) throws { try instances.setRunning(running, expected: expected, expiresAt: expiresAt) }
}
private func generatedServiceCommand(_ path: String, _ arguments: [String]) throws -> (Int32, String) {
    let process=Process(), output=Pipe()
    process.executableURL=URL(fileURLWithPath: path); process.arguments=arguments
    process.standardOutput=output; process.standardError=output
    try process.run()
    let data=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard data.count < 1_048_576 else { throw ShouError("fixture_failed", "Generated service output exceeded its limit.") }
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
private func compileGeneratedService(_ fixture: Fixture, path: String) throws -> URL {
    let code="""
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <signal.h>
    #include <unistd.h>
    static volatile sig_atomic_t done=0;
    static void stop(int value) { done=1; }
    int main(int argc, char **argv) {
      signal(SIGTERM,stop); signal(SIGQUIT,stop);
      const char *config=NULL, *pidfile=NULL, *data=NULL;
      for (int i=1;i<argc;i++) {
        if (strncmp(argv[i],"--defaults-file=",16)==0) config=argv[i]+16;
        if (strncmp(argv[i],"--pid-file=",11)==0) pidfile=argv[i]+11;
        if (strncmp(argv[i],"--datadir=",10)==0) data=argv[i]+10;
      }
      if (data) { char failure[4096]; snprintf(failure,sizeof(failure),"%s/fail-start",data); if (access(failure,F_OK)==0) { fprintf(stderr,"Generated startup failure; no real database was opened.\\n"); return 19; } }
      if (config) {
        FILE *file=fopen(config,"r"); if (!file) return 18;
        char line[4096];
        while (fgets(line,sizeof(line),file)) if (strstr(line,"fixture-failure=1")) { fprintf(stderr,"Generated startup failure; no real database was opened.\\n"); fclose(file); return 19; }
        fclose(file);
      }
      if (pidfile) { FILE *file=fopen(pidfile,"w"); if (!file) return 20; fprintf(file,"%d\\n",getpid()); fclose(file); }
      puts("Generated service ready"); fflush(stdout);
      while (!done) usleep(10000);
      return 0;
    }
    """
    try fixture.put("service.c", code)
    let executable=fixture.workspace.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let result=try generatedServiceCommand("/usr/bin/clang", [fixture.workspace.appendingPathComponent("service.c").path, "-o", executable.path])
    try expect(result.0 == 0)
    return executable
}

func nativeDeveloperInstancesSeparateAndRestartGeneratedDatabases() async throws {
    let fixture=try Fixture(), executable=try compileGeneratedService(fixture, path: "mysql/1.0/bin/mysqld")
    let adapter=NativeDeveloperInstances(homeDirectory: fixture.workspace, generatedRoot: fixture.workspace, makeStore: { fixture.store })
    let controller=DeveloperServiceController(catalog: try .bundled(), platform: GeneratedInstanceServices(instances: adapter), makeStore: { fixture.store })
    let installation=executable.deletingLastPathComponent().deletingLastPathComponent()
    let working=fixture.workspace.appendingPathComponent("working")
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: working.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: working.path) }
    let inventory=DeveloperToolInventory(installations: [.init(toolID: "mysql", source: "Generated", version: "1.0", path: installation.path, evidence: "generated", status: "registered")], issues: [])
    var initial=[Process]()
    defer {
        for process in initial where process.isRunning { process.terminate(); process.waitUntilExit() }
        // Only processes found inside this freshly generated fixture can be stopped.
        if let rows=try? adapter.scan(inventory: inventory) {
            for row in rows.services where row.controllable && row.state == "running" { try? adapter.setRunning(false, expected: row, expiresAt: Date().addingTimeInterval(5)) }
        }
    }
    for name in ["a", "b"] {
        let base=fixture.workspace.appendingPathComponent(name)
        try fixture.put(name + "/my.cnf", "[mysqld]\ndatadir=" + base.path + "\n# Generated fixture, no database engine.\n")
        let process=Process(); process.executableURL=executable; process.currentDirectoryURL=working
        process.arguments=["--defaults-file=" + base.appendingPathComponent("my.cnf").path, "--pid-file=" + base.appendingPathComponent("mysql.pid").path] + (name == "b" ? ["--datadir=" + base.path] : [])
        process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        try process.run(); initial.append(process)
    }
    for _ in 0..<50 {
        if ["a", "b"].allSatisfy({ FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent($0 + "/mysql.pid").path) }) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let rows=try await controller.scan(inventory).services
    try expect(rows.count == 2 && rows.allSatisfy(\.controllable) && Set(rows.map(\.id)).count == 2)
    let first=try require(rows.first { $0.configurationPath.contains("/a/") }), other=try require(rows.first { $0.configurationPath.contains("/b/") })
    let restarted=try await controller.perform(.restart, expected: first)
    if restarted.state != "succeeded" { print("Generated restart outcome: " + String(decoding: try Codec.encode(restarted), as: UTF8.self)) }
    try expect(restarted.state == "succeeded" && restarted.observed?.processID != first.processID)
    try expect(try adapter.inspect(other).processID == other.processID)
    // Same executable, explicit no-defaults and a disjoint data directory must
    // not turn this instance's successful stop into a 15-second timeout.
    try fixture.put("unrelated/marker", "generated only")
    let unrelated=Process(); unrelated.executableURL=executable; unrelated.currentDirectoryURL=executable.deletingLastPathComponent()
    unrelated.arguments=["--no-defaults","--datadir=" + fixture.workspace.appendingPathComponent("unrelated").path]
    unrelated.standardOutput=FileHandle.nullDevice; unrelated.standardError=FileHandle.nullDevice
    try unrelated.run(); initial.append(unrelated)
    try fixture.put("b/fail-start", "generated startup failure")
    let failed=try await controller.perform(.restart, expected: other)
    print("Generated second-instance failure: \(failed.state), \(failed.stage ?? "none"), \(failed.failureCode ?? "none")")
    try expect(failed.state == "partial" && failed.stage == "starting" && failed.failureCode == "developer_service_start_failed")
    let errorLog=try require(failed.observed?.errorLogPath)
    try expect(try String(contentsOfFile: errorLog, encoding: .utf8).contains("Generated startup failure"))
    let stopped=try await controller.perform(.stop, expected: try require(restarted.observed))
    print("Generated first-instance stop: \(stopped.state)")
    if stopped.state != "succeeded" { print(String(decoding: try Codec.encode(stopped), as: UTF8.self)) }
    try expect(stopped.state == "succeeded")
    try expect(unrelated.isRunning)
    let reopened=NativeDeveloperInstances(homeDirectory: fixture.workspace, generatedRoot: fixture.workspace, makeStore: { fixture.store })
    let stored=try require(reopened.scan(inventory: inventory).services.first { $0.id == first.id })
    print("Generated persisted recipe: \(stored.state), controllable=\(stored.controllable)")
    try expect(stored.state == "stopped" && stored.controllable)
    // No data identity means genuinely ambiguous. Do not relax the switch.
    let ambiguous=Process(); ambiguous.executableURL=executable; ambiguous.currentDirectoryURL=executable.deletingLastPathComponent()
    ambiguous.arguments=["--no-defaults"]; ambiguous.standardOutput=FileHandle.nullDevice; ambiguous.standardError=FileHandle.nullDevice
    try ambiguous.run(); initial.append(ambiguous)
    for _ in 0..<50 {
        if try reopened.inspect(stored).issue != nil { break }
        try await Task.sleep(for:.milliseconds(20))
    }
    try expect(try reopened.inspect(stored).state == "unknown")
    try expectThrows { try reopened.setRunning(true,expected:stored,expiresAt:Date().addingTimeInterval(5)) }
    ambiguous.terminate(); ambiguous.waitUntilExit()
    try fixture.put("a/my.cnf", "fixture-failure=1\n")
    // A changed recipe is rejected before mutation, even if an old PID is reused.
    try expectThrows { try reopened.setRunning(true, expected: stored, expiresAt: Date().addingTimeInterval(5)) }
    try expect(try adapter.inspect(other).state == "stopped")
}

func nativeDeveloperLaunchdRestartsGeneratedKeepAliveWithoutRegistrationChanges() async throws {
    let fixture=try Fixture(), token="shou-fixture-" + UUID().uuidString.lowercased()
    let executable=try compileGeneratedService(fixture, path: "Cellar/" + token + "/1.0/bin/nginx")
    let label="homebrew.mxcl." + token, domain="gui/\(getuid())"
    let packaged=fixture.workspace.appendingPathComponent("Cellar/" + token + "/1.0/" + label + ".plist")
    let registration=fixture.workspace.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
    let log=fixture.workspace.appendingPathComponent("var/log/service.log")
    try fixture.put("var/log/service.log", "")
    let plist:[String:Any] = ["Label":label,"KeepAlive":true,"ProgramArguments":[executable.path],"StandardOutPath":log.path,"StandardErrorPath":log.path]
    let bytes=try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try bytes.write(to: packaged)
    try fixture.put("Library/LaunchAgents/" + label + ".plist", String(decoding: bytes, as: UTF8.self))
    var root=try JSONSerialization.jsonObject(with: JSONEncoder().encode(try DeveloperToolCatalog.bundled())) as! [String:Any]
    var tools=root["tools"] as! [[String:Any]]
    let index=tools.firstIndex { $0["id"] as? String == "nginx" }!
    tools[index]["packages"]=[["provider":"homebrew","kind":"formula","token":token]]; root["tools"]=tools
    let catalog=try DeveloperToolCatalog.decode(JSONSerialization.data(withJSONObject: root))
    let user=String(data: try JSONSerialization.data(withJSONObject: NSUserName(), options: .fragmentsAllowed), encoding: .utf8)!
    try fixture.put("bin/brew", """
    #!/bin/sh
    if [ "$1" = info ]; then
      printf '{"formulae":[{"full_name":"\(token)","tap":"homebrew/core","installed":[{"version":"1.0"}],"versions":{"stable":"1.0"},"dependencies":[],"revision":0}],"casks":[]}'
    elif [ "$2" = list ]; then printf '[{"name":"\(token)"}]'
    elif [ "$2" = info ]; then
      pid=$(/bin/launchctl print '\(domain)/\(label)' 2>/dev/null | /usr/bin/awk '/^[[:space:]]*pid = / {print $3; exit}')
      running=false; status=none; user=null; file="$HOME/Cellar/\(token)/1.0/\(label).plist"; registered=false
      if [ -f "$HOME/login" ]; then registered=true; user='\(user)'; file="$HOME/Library/LaunchAgents/\(label).plist"; fi
      if [ -n "$pid" ]; then running=true; status=started; user='\(user)'; else pid=null; fi
      printf '[{"name":"\(token)","running":%s,"registered":%s,"status":"%s","user":%s,"file":"%s","pid":%s}]' "$running" "$registered" "$status" "$user" "$file" "$pid"
    else exit 12; fi
    """)
    let brew=fixture.workspace.appendingPathComponent("bin/brew")
    try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:brew.path)
    let platform=NativeDeveloperServices(homeDirectory: fixture.workspace, generatedExecutable: brew)
    let controller=DeveloperServiceController(catalog: catalog, platform: platform, makeStore: { fixture.store })
    let inventory=DeveloperToolInventory(installations:[.init(toolID:"nginx",source:"Homebrew",version:"1.0",path:executable.deletingLastPathComponent().deletingLastPathComponent().path,evidence:"generated",status:"registered")],issues:[])
    func override() throws -> String? {
        let output=try generatedServiceCommand("/bin/launchctl", ["print-disabled",domain]); try expect(output.0 == 0)
        return LaunchctlStateParser.disabledOverrides(output.1)?[label]
    }
    let before=try override()
    defer { _ = try? generatedServiceCommand("/bin/launchctl",["bootout",domain + "/" + label]) }
    for registered in [false,true] {
        if registered { try fixture.put("login", "generated registration") }
        let stopped=try require(try await controller.scan(inventory).services.first)
        let started=try await controller.perform(.start, expected: stopped)
        try expect(started.state == "succeeded")
        let first=try require(started.observed)
        // A job still running an older definition must not be controlled merely
        // because launchd reports the same plist path and executable.
        var changed=plist; changed["ProgramArguments"]=[executable.path,"--port=16380"]
        let changedBytes=try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0)
        try changedBytes.write(to: packaged); try changedBytes.write(to: registration)
        let mismatched=try require(try await controller.scan(inventory).services.first)
        let rejected=try await controller.perform(.stop, expected: mismatched)
        try expect(rejected.state == "unknown" && rejected.failureCode == "developer_service_unavailable" && rejected.observed?.processID == first.processID)
        try bytes.write(to: packaged); try bytes.write(to: registration)
        let refreshed=try require(try await controller.scan(inventory).services.first)
        let restarted=try await controller.perform(.restart, expected: refreshed)
        try expect(restarted.state == "succeeded" && restarted.observed?.processID != first.processID)
        try expect(try platform.readLog(try require(restarted.observed)).contains("Generated service ready"))
        try expect(try await controller.perform(.stop, expected: try require(restarted.observed)).state == "succeeded")
        try expect(try Data(contentsOf: packaged) == bytes && Data(contentsOf: registration) == bytes && override() == before)
    }
}
#else
func nativeDeveloperInstancesSeparateAndRestartGeneratedDatabases() async throws {}
func nativeDeveloperLaunchdRestartsGeneratedKeepAliveWithoutRegistrationChanges() async throws {}
#endif
