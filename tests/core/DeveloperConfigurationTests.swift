import Foundation
import ShouCore
import ShouPlatform

func developerConfigurationFilesPreserveIdentityAndSoftwarePaths() throws {
    #if os(macOS)
    let fixture=try Fixture(), files=NativeDeveloperConfigurationFiles(recordsDirectory:fixture.workspace.appendingPathComponent("file-records"))
    let original="port 6389\nlogfile \"/generated/redis.log\"\n# generated-token-never-journaled\n"
    try fixture.put("redis.conf",original)
    let path=fixture.workspace.appendingPathComponent("redis.conf").path
    let value=try files.read(path)
    let saved=try files.save(original + "timeout 60\n",expected:value)
    try expect(saved.text.hasSuffix("timeout 60\n"))
    try expectThrows { try files.save("stale",expected:value) }
    try FileManager.default.createSymbolicLink(atPath:fixture.workspace.appendingPathComponent("linked.conf").path,withDestinationPath:path)
    try expectThrows { try files.read(fixture.workspace.appendingPathComponent("linked.conf").path) }
    try fixture.put("large.conf",String(repeating:"x",count:262_145))
    try expectThrows { try files.read(fixture.workspace.appendingPathComponent("large.conf").path) }
    try fixture.put("unsafe.conf","generated")
    let unsafe=fixture.workspace.appendingPathComponent("unsafe.conf").path
    try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:unsafe)
    let readonly=try files.read(unsafe)
    try expect(!readonly.writable)
    try expectThrows { try files.save("changed",expected:readonly) }
    try expectThrows { try files.save("bad\0text",expected:saved) }
    try fixture.put("replace.conf","before")
    let replace=fixture.workspace.appendingPathComponent("replace.conf").path
    let before=try files.read(replace)
    try FileManager.default.moveItem(atPath:replace,toPath:replace + ".old")
    try fixture.put("replace.conf","after")
    try expectThrows { try files.save("must not overwrite replacement",expected:before) }
    try expect(try files.read(replace).text == "after")
    let records=try LocalRecordStore(directory:fixture.workspace.appendingPathComponent("file-records"))
    for item in try records.boundedRecords("developer-config-edits",limit:20).records {
        let data=try require(records.read(item.collection,id:item.id))
        try expect(!String(decoding:data,as:UTF8.self).contains("generated-token-never-journaled"))
    }
    let prefix=fixture.workspace.appendingPathComponent("brew").path
    let resolver=NativeDeveloperConfiguration(homeDirectory:fixture.workspace,referenceDataRoots:[],homebrewPrefixes:[prefix])
    let redisLogs=resolver.logs(toolID:"redis",document:saved,services:[])
    try expect(redisLogs.count == 1 && redisLogs[0].path == "/generated/redis.log")
    try fixture.put("brew/var/postgresql@17/postgresql.conf","port=5439\n")
    let copy=DeveloperToolInstallation(toolID:"postgresql",source:"Homebrew",version:"17.2",path:prefix + "/Cellar/postgresql@17/17.2",evidence:"fixture",status:"registered")
    try expect(resolver.targets(toolID:"postgresql",installations:[copy],services:[]).map(\.path) == [prefix + "/var/postgresql@17/postgresql.conf"])
    try expect(resolver.targets(toolID:"node",installations:[copy],services:[]).isEmpty)
    try fixture.put("nginx.conf","events {}\n")
    let nginx=DeveloperService(id:"generated",toolID:"nginx",source:"Local instance",name:"nginx",version:"1",installationPath:"/generated",configurationPath:fixture.workspace.appendingPathComponent("nginx.conf").path,state:"running",registeredAtLogin:false,identity:"generated",definitionIdentity:"generated",issue:nil)
    try expect(resolver.targets(toolID:"nginx",installations:[],services:[nginx]).map(\.path) == [nginx.configurationPath])
    try expect(resolver.targets(toolID:"redis",installations:[],services:[nginx]).isEmpty)
    #endif
}

func developerConfigurationAdaptersDiscoverSoftwareScopesWithoutExecutingPrograms() throws {
    #if os(macOS)
    let fixture=try Fixture(), root=fixture.workspace.appendingPathComponent("reference")
    let prefix=fixture.workspace.appendingPathComponent("brew").path
    let resolver=NativeDeveloperConfiguration(homeDirectory:fixture.workspace,referenceDataRoots:[root],homebrewPrefixes:[prefix])
    let cases:[(String,String,String)]=[
        ("apache","apache/common/conf/c9f8b151dfe74ed75ae681cd143f0ca5.conf","ErrorLog \"/generated/error log.log\"\nCustomLog \"/generated/access.log\" combined\n"),
        ("caddy","caddy/Caddyfile",":58199 {\n respond \"generated\"\n}\n"),
        ("meilisearch","meilisearch/meilisearch.toml","http_addr = '127.0.0.1:58198'\n"),
        ("consul","consul/consul-1.json","{\"server\":false}\n"),
        ("etcd","etcd/etcd.yaml","name: generated\n"),
        ("numa","numa/numa.toml","[server]\n"),
        ("mailpit","mailpit/mailpit.conf","# MP_LOG_FILE=/must/not/read\nMP_LOG_FILE=\"/generated/mail=pit.log\"\n")
    ]
    var copies=[DeveloperToolInstallation]()
    for (tool,path,text) in cases {
        try fixture.put("reference/server/" + path,text)
        let copy=DeveloperToolInstallation(toolID:tool,source:"Executable path",version:"1.2.3",path:"/generated/" + tool,evidence:"generated",status:"detected",launchPaths:tool == "apache" ? ["/generated/httpd"] : [])
        copies.append(copy)
        let found=resolver.targets(toolID:tool,installations:[copy],services:[])
        try expect(found.map(\.path) == [root.appendingPathComponent("server/" + path).path])
        try expect(found[0].source == "FlyEnv storage")
    }
    try expect(resolver.targets(toolID:"node",installations:copies,services:[]).isEmpty)
    try expect(resolver.targets(toolID:"caddy",installations:copies.filter { $0.toolID != "caddy" },services:[]).isEmpty)
    try fixture.put("brew/etc/Caddyfile",":58197 {}\n")
    let brew=DeveloperToolInstallation(toolID:"caddy",source:"Homebrew",version:"2.9.0",path:prefix + "/Cellar/caddy/2.9.0",evidence:"generated",status:"registered")
    let caddy=resolver.targets(toolID:"caddy",installations:[brew],services:[])
    try expect(caddy.count == 2 && caddy[0].source == "Homebrew" && caddy[1].source == "FlyEnv storage")
    try fixture.put("reference/server/caddy/caddy.log","generated request\n")
    let caddyLogs=resolver.logs(toolID:"caddy",document:nil,services:[],installations:[brew])
    try expect(caddyLogs.map(\.path) == [root.appendingPathComponent("server/caddy/caddy.log").path])
    for tool in ["meilisearch","etcd","numa"] {
        try fixture.put("reference/server/" + tool + "/" + tool + "-1.2.3-start-error.log","generated startup failure\n")
        let logs=resolver.logs(toolID:tool,document:nil,services:[],installations:copies)
        try expect(logs.map(\.path) == [root.appendingPathComponent("server/" + tool + "/" + tool + "-1.2.3-start-error.log").path])
    }
    let reader=NativeDeveloperConfigurationFiles(recordsDirectory:fixture.base.appendingPathComponent("config-records"))
    let apache=try reader.read(root.appendingPathComponent("server/" + cases[0].1).path)
    try expect(resolver.logs(toolID:"apache",document:apache,services:[]).map(\.path) == ["/generated/error log.log","/generated/access.log"])
    try fixture.put("reference/server/apache/common/logs/error_log","generated Apache failure\n")
    try expect(resolver.logs(toolID:"apache",document:nil,services:[],installations:copies).map(\.path) == [root.appendingPathComponent("server/apache/common/logs/error_log").path])
    let mailpit=try reader.read(root.appendingPathComponent("server/" + cases[6].1).path)
    try expect(resolver.logs(toolID:"mailpit",document:mailpit,services:[]).map(\.path) == ["/generated/mail=pit.log"])
    // Absolute and = forms are supported, but duplicate/relative/unfinished
    // options cannot silently choose another service's configuration.
    let path=root.appendingPathComponent("server/meilisearch/meilisearch.toml").path
    func service(_ args:[String]) throws -> DeveloperService {
        let plist=fixture.workspace.appendingPathComponent("generated.plist")
        try PropertyListSerialization.data(fromPropertyList:["ProgramArguments":args],format:.xml,options:0).write(to:plist)
        return .init(id:"generated",toolID:"meilisearch",source:"Homebrew",name:"meilisearch",version:"1",installationPath:"/generated",configurationPath:plist.path,state:"stopped",registeredAtLogin:false,identity:"generated",definitionIdentity:"generated",issue:nil)
    }
    try expect(resolver.targets(toolID:"meilisearch",installations:[],services:[try service(["/generated/meili","--config-file-path=" + path])]).map(\.path) == [path])
    for args in [["--config-file-path",path,"--config-file-path",path],["--config-file-path",path,"--config-file-path"],["--config-file-path=relative.toml"]] {
        try expect(resolver.targets(toolID:"meilisearch",installations:[],services:[try service(["/generated/meili"] + args)]).isEmpty)
    }
    #endif
}

func developerConfigurationFormatsPreserveExactFilesAndRejectUnknownWrites() throws {
    #if os(macOS)
    let fixture=try Fixture(), files=NativeDeveloperConfigurationFiles(recordsDirectory:fixture.base.appendingPathComponent("format-records"))
    for (name,text,changed) in [("Caddyfile",":58196 {}\n",":58195 {}\n"),("config.json","{\"generated\":1}\n","{\"generated\":2}\n"),("config.toml","port=58194\n","port=58193\n")] {
        try fixture.put(name,text)
        let path=fixture.workspace.appendingPathComponent(name).path
        let before=try files.read(path)
        try expect(before.writable)
        let after=try files.save(changed,expected:before)
        try expect(after.text == changed && after.identity.inode == before.identity.inode)
        try expectThrows { try files.save(text,expected:before) }
    }
    try fixture.put("unknown.txt","generated only\n")
    let unknown=try files.read(fixture.workspace.appendingPathComponent("unknown.txt").path)
    try expect(!unknown.writable)
    try expectThrows { try files.save("must not write",expected:unknown) }
    try expect(try files.read(unknown.path).text == "generated only\n")
    #endif
}
