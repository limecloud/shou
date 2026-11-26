import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct NativeDockerStorage: DockerStorageOperating {
    private let home: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { home=homeDirectory }
    private var tools: NativeCleanupTools { NativeCleanupTools(homeDirectory: home) }
    public func availableBytes(inventory: DockerStorageInventory) -> Int64? {
        guard let profile=inventory.reclamation?.profile, validName(profile) else { return nil }
        let instance=profile == "default" ? "colima" : "colima-" + profile
        return NativeFileSystem().availableBytes(home.appendingPathComponent(".colima/_lima/_disks/" + instance + "/datadisk").path)
    }
    private func run(_ tool: String, _ arguments: [String], expected: String? = nil, timeout: Double = 30) throws -> (text: String, identity: String) {
        try Task.checkCancellation()
        let path=try tools.locate(tool), before=try tools.identity(path), identity=path + ":" + before
        guard expected == nil || expected == identity else { throw ShouError("tool_changed", "The Docker storage tool changed after review.") }
        let data=try NativeManagedToolProcess(homeDirectory: home).run(path, arguments: arguments, timeout: timeout)
        guard try tools.identity(path) == before, let text=String(data: data, encoding: .utf8) else { throw ShouError("tool_changed", "The Docker storage tool changed or returned unsupported output.") }
        return (text, identity)
    }
    private func validName(_ name: String) -> Bool { name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,119}$", options: .regularExpression) != nil }
    private func rows(_ text: String) throws -> [[String: Any]] {
        try text.split(whereSeparator: \.isNewline).map {
            guard let value=try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else { throw ShouError("unsupported_schema", "Docker returned an unsupported storage report.") }
            return value
        }
    }
    public func contexts() throws -> [DockerStorageContext] {
        try rows(run("docker", ["context", "ls", "--format", "{{json .}}"]).text).compactMap { row in
            guard let name=row["Name"] as? String, validName(name), let endpoint=row["DockerEndpoint"] as? String,
                  endpoint.hasPrefix("unix:///"), !endpoint.contains("\0"), !endpoint.contains("\n"), (row["Error"] as? String ?? "").isEmpty else { return nil }
            return DockerStorageContext(name: name, endpoint: endpoint, current: row["Current"] as? Bool == true)
        }
    }
    private func binding(_ context: String) throws -> (DockerStorageContext, String, String, String) {
        guard validName(context) else { throw ShouError("invalid_argument", "Select an exact local Docker context.") }
        let endpointOutput=try run("docker", ["context", "inspect", context, "--format", "{{json .Endpoints.docker.Host}}"])
        let endpoint=try JSONDecoder().decode(String.self, from: Data(endpointOutput.text.utf8))
        guard endpoint.hasPrefix("unix:///"), !endpoint.contains("\0"), !endpoint.contains("\n") else { throw ShouError("remote_context", "Only local Docker Unix sockets are supported.") }
        let server=try run("docker", ["--context", context, "info", "--format", "{\"id\":{{json .ID}},\"root\":{{json .DockerRootDir}}}"], expected: endpointOutput.identity)
        guard let value=try rows(server.text).first, let daemon=value["id"] as? String, !daemon.isEmpty, let root=value["root"] as? String else { throw ShouError("unsupported_schema", "The Docker daemon identity is unavailable.") }
        return (.init(name: context, endpoint: endpoint), daemon, server.identity, root)
    }
    public func observe(context: String) throws -> DockerStorageInventory { try observe(context: context, includeCache: true, includeDisk: true) }
    private func observe(context: String, includeCache: Bool, includeDisk: Bool) throws -> DockerStorageInventory {
        let (binding, daemon, identity, dockerRoot)=try binding(context)
        func docker(_ args: [String]) throws -> String { try run("docker", ["--context", context] + args, expected: identity).text }
        let ids=try docker(["container", "ls", "--all", "--no-trunc", "--quiet"]).split(whereSeparator: \.isWhitespace).map(String.init)
        guard ids.count <= 1000, ids.allSatisfy(Self.validId) else { throw ShouError("resource_limit", "Docker container discovery exceeded its supported scope.") }
        let template="{\"id\":{{json .Id}},\"image\":{{json .Image}},\"name\":{{json .Name}},\"state\":{{json .State.Status}},\"started\":{{json .State.StartedAt}},\"finished\":{{json .State.FinishedAt}},\"mounts\":{{json .Mounts}}}"
        var objects=[DockerStorageObject](), imageReferences=[String: Int](), volumeReferences=[String: Int]()
        for offset in stride(from: 0, to: ids.count, by: 50) {
            let result=try rows(docker(["container", "inspect", "--format", template] + Array(ids[offset..<min(offset+50, ids.count)])))
            guard result.count == min(50, ids.count-offset) else { throw ShouError("source_changed", "Docker containers changed during discovery.") }
            for row in result {
                guard let id=row["id"] as? String, ids.contains(id), let image=row["image"] as? String,
                      let name=row["name"] as? String, let state=row["state"] as? String, let mounts=row["mounts"] as? [[String: Any]] else { throw ShouError("unsupported_schema", "Container identity or mounts are unavailable.") }
                imageReferences[image, default: 0] += 1
                for mount in mounts where mount["Type"] as? String == "volume" {
                    guard let name=mount["Name"] as? String, !name.isEmpty else { throw ShouError("unsupported_schema", "A container volume reference is unavailable.") }
                    volumeReferences[name, default: 0] += 1
                }
                objects.append(.init(kind: .container, objectId: id, name: String(name.drop(while: { $0 == "/" })), bytes: nil,
                    revision: try Self.revision(row), state: state))
            }
        }
        var volumeSizes=[String: Int64]()
        if includeCache {
            // Restrict formatter output before it leaves Docker: verbose reports
            // also contain container commands and build descriptions we do not need.
            let format="{{range .Volumes}}{\"kind\":\"volume\",\"name\":{{json .Name}},\"size\":{{json .Size}}}{{println}}{{end}}{{range .BuildCache}}{\"kind\":\"cache\",\"id\":{{json .ID}},\"size\":{{json .Size}},\"used\":{{json .InUse}},\"shared\":{{json .Shared}}}{{println}}{{end}}"
            let usage=try rows(docker(["system", "df", "--verbose", "--format", format]))
            for row in usage where row["kind"] as? String == "volume" {
                if let name=row["name"] as? String, let raw=row["size"] as? String, let size=Self.bytes(raw) { volumeSizes[name]=size }
            }
            let caches=usage.filter { $0["kind"] as? String == "cache" }
            guard caches.allSatisfy({ row in
                row["id"] is String && ["true", "false"].contains(row["used"] as? String ?? "") && ["true", "false"].contains(row["shared"] as? String ?? "")
            }) else { throw ShouError("unsupported_schema", "Docker cache reference information is unavailable.") }
            let unused=caches.filter { $0["used"] as? String == "false" && $0["shared"] as? String == "false" }
            var amount: Int64=0
            for row in unused {
                guard let raw=row["size"] as? String, let size=Self.bytes(raw) else { throw ShouError("unsupported_schema", "Docker build-cache usage is unavailable.") }
                let sum=amount.addingReportingOverflow(size)
                guard !sum.overflow else { throw ShouError("resource_limit", "Docker cache size exceeds supported limits.") }
                amount=sum.partialValue
            }
            if amount > 0 { objects.append(.init(kind: .buildCache, objectId: "unused-build-cache", name: "Unused build cache", bytes: amount,
                revision: try Self.revision(["cache": unused.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }]), state: "unused")) }
        }
        let images=try rows(docker(["image", "ls", "--all", "--no-trunc", "--format", "{{json .}}"])), grouped=Dictionary(grouping: images) { $0["ID"] as? String ?? "" }
        for (id, values) in grouped {
            guard id.hasPrefix("sha256:"), Self.validId(String(id.dropFirst(7))) else { throw ShouError("unsupported_schema", "Docker image identity is unavailable.") }
            let names=values.compactMap { row -> String? in
                guard let repository=row["Repository"] as? String, let tag=row["Tag"] as? String else { return nil }
                return repository == "<none>" ? nil : repository + ":" + tag
            }.sorted()
            objects.append(.init(kind: .image, objectId: id, name: names.isEmpty ? id : names.joined(separator: ", "), bytes: values.first.flatMap { ($0["Size"] as? String).flatMap(Self.bytes) },
                revision: try Self.revision(["id": id, "names": names]), state: names.count > 1 ? "multiple_tags" : "local", references: imageReferences[id] ?? 0))
        }
        let volumes=try rows(docker(["volume", "ls", "--format", "{{json .}}"])).compactMap { $0["Name"] as? String }
        guard volumes.count <= 1000, volumes.allSatisfy(validName) else { throw ShouError("resource_limit", "Docker volume discovery exceeded its supported scope.") }
        let volumeTemplate="{\"name\":{{json .Name}},\"driver\":{{json .Driver}},\"scope\":{{json .Scope}},\"created\":{{json .CreatedAt}},\"options\":{{if .Options}}true{{else}}false{{end}},\"project\":{{json (index .Labels \"com.docker.compose.project\")}}}"
        for offset in stride(from: 0, to: volumes.count, by: 50) {
            let result=try rows(docker(["volume", "inspect", "--format", volumeTemplate] + Array(volumes[offset..<min(offset+50, volumes.count)])))
            guard result.count == min(50, volumes.count-offset) else { throw ShouError("source_changed", "Docker volumes changed during discovery.") }
            for row in result {
                guard let name=row["name"] as? String, volumes.contains(name), let created=row["created"] as? String, !created.isEmpty else { throw ShouError("unsupported_schema", "Docker volume identity is unavailable.") }
                let ordinary=row["driver"] as? String == "local" && row["scope"] as? String == "local" && row["options"] as? Bool == false
                let project=row["project"] as? String ?? ""
                objects.append(.init(kind: .volume, objectId: name, name: project.isEmpty ? name : name + " (" + project + ")", bytes: volumeSizes[name], revision: try Self.revision(row),
                    state: ordinary ? "local" : "unsupported", references: volumeReferences[name] ?? 0))
            }
        }
        guard Set(ids) == Set(try docker(["container", "ls", "--all", "--no-trunc", "--quiet"]).split(whereSeparator: \.isWhitespace).map(String.init)) else { throw ShouError("source_changed", "Docker containers changed during discovery.") }
        let after=try self.binding(context)
        guard binding.endpoint == after.0.endpoint, daemon == after.1, identity == after.2 else { throw ShouError("source_changed", "The Docker context or daemon changed during discovery.") }
        var disk: DockerDiskReclamation?, diskIssue: String?
        if includeDisk {
            do { disk=try diskEvidence(binding, dockerRoot: dockerRoot) }
            catch { diskIssue=(error as? ShouError)?.code ?? "disk_reclamation_unavailable" }
        }
        return .init(context: binding, daemonId: daemon, executableIdentity: identity, objects: objects.sorted { $0.id < $1.id }, reclamation: disk, reclamationIssue: diskIssue)
    }
    public func remove(_ object: DockerStorageObject, inventory: DockerStorageInventory, cacheBefore: Date) throws {
        let current=try observe(context: inventory.context.name, includeCache: object.kind == .buildCache, includeDisk: false)
        guard current.sameBackend(as: inventory), current.objects.contains(where: {
            $0.id == object.id && $0.revision == object.revision && $0.state == object.state && $0.references == object.references && $0.blockingReason == nil
        }) else { throw ShouError("source_changed", "The selected Docker object changed or is now in use.") }
        let arguments=try Self.removalArguments(object, cacheBefore: cacheBefore)
        // Pin the reviewed endpoint at dispatch; context-file edits must not
        // redirect the mutation after the final read-only identity check.
        _ = try run("docker", ["--host", current.context.endpoint] + arguments, expected: current.executableIdentity, timeout: 300)
        let after=try observe(context: current.context.name, includeCache: object.kind == .buildCache, includeDisk: false)
        guard after.sameBackend(as: current), !after.objects.contains(where: { $0.id == object.id }) else { throw ShouError("result_unverified", "Docker removal could not be verified.") }
    }
    public static func removalArguments(_ object: DockerStorageObject, cacheBefore: Date) throws -> [String] {
        switch object.kind {
        case .container:
            guard validId(object.objectId) else { throw ShouError("invalid_argument", "Invalid container identity.") }
            return ["container", "rm", "--", object.objectId]
        case .image:
            guard object.objectId.hasPrefix("sha256:"), validId(String(object.objectId.dropFirst(7))) else { throw ShouError("invalid_argument", "Invalid image identity.") }
            return ["image", "rm", "--", object.objectId]
        case .volume:
            guard object.objectId.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,119}$", options: .regularExpression) != nil else { throw ShouError("invalid_argument", "Invalid volume identity.") }
            return ["volume", "rm", "--", object.objectId]
        case .buildCache:
            guard object.objectId == "unused-build-cache", cacheBefore.timeIntervalSince1970.isFinite else { throw ShouError("invalid_argument", "Invalid build-cache scope.") }
            return ["builder", "prune", "--all", "--force", "--filter", "until=" + ISO8601DateFormatter().string(from: cacheBefore)]
        }
    }
    private static func validId(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    private static func revision(_ row: [String: Any]) throws -> String { Digest.sha256(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) }
    private static func bytes(_ text: String) -> Int64? {
        let units:[String: Double] = ["B":1, "kB":1e3, "KB":1e3, "MB":1e6, "GB":1e9, "TB":1e12, "KiB":1024, "MiB":1048576, "GiB":1073741824]
        for (suffix, unit) in units where text.hasSuffix(suffix) {
            if let value=Double(text.dropLast(suffix.count)), value.isFinite, value >= 0, value * unit < Double(Int64.max) { return Int64(value * unit) }
        }
        return nil
    }
    private func diskEvidence(_ context: DockerStorageContext, dockerRoot: String) throws -> DockerDiskReclamation {
        let prefix="unix://" + home.path + "/.colima/"
        guard dockerRoot == "/var/lib/docker", context.endpoint.hasPrefix(prefix), context.endpoint.hasSuffix("/docker.sock") else { throw ShouError("disk_backend_unsupported", "Disk reclamation currently supports running Colima VZ data disks.") }
        let profile=String(context.endpoint.dropFirst(prefix.count).dropLast("/docker.sock".count))
        guard validName(profile) else { throw ShouError("disk_backend_unsupported", "The Colima profile is unsupported.") }
        let colima=try run("colima", ["list", "--json"])
        guard try rows(colima.text).contains(where: { $0["name"] as? String == profile && $0["status"] as? String == "Running" && $0["runtime"] as? String == "docker" }) else { throw ShouError("disk_backend_stopped", "Start the selected Colima profile yourself before reviewing disk reclamation.") }
        let instance=profile == "default" ? "colima" : "colima-" + profile
        let directory=home.appendingPathComponent(".colima/_lima/" + instance)
        let config=try SecurePaths.directory(directory.path); defer { close(config) }
        let fd=openat(config, "lima.yaml", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ShouError("disk_backend_unsupported", "The Colima VM configuration could not be verified.") }
        let handle=FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata=stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_size <= 262144,
              let data=try handle.read(upToCount: 262145), let text=String(data: data, encoding: .utf8),
              text.split(whereSeparator: \.isNewline).filter({ $0.hasPrefix("vmType:") }) == ["vmType: vz"] else { throw ShouError("disk_backend_unsupported", "Only verified Colima VZ raw disks support online reclamation here.") }
        let mountOutput=try run("colima", ["--profile", profile, "ssh", "--", "findmnt", "-J", "-T", "/var/lib/docker", "-o", "TARGET,SOURCE,FSTYPE"], expected: colima.identity)
        guard let mounts=try JSONSerialization.jsonObject(with: Data(mountOutput.text.utf8)) as? [String: Any], let values=mounts["filesystems"] as? [[String: Any]], values.count == 1,
              let mount=values.first, mount["target"] as? String == "/var/lib/docker", mount["fstype"] as? String == "ext4",
              let source=mount["source"] as? String, source.hasPrefix("/dev/") else { throw ShouError("disk_mount_unsupported", "The container-data filesystem could not be verified.") }
        _ = try run("colima", ["--profile", profile, "ssh", "--", "sudo", "-n", "fstrim", "--dry-run", "--verbose", "--", "/var/lib/docker"], expected: colima.identity)
        let free=try run("colima", ["--profile", profile, "ssh", "--", "df", "-B1", "--output=avail", "/var/lib/docker"], expected: colima.identity)
        guard let available=free.text.split(whereSeparator: \.isWhitespace).last.flatMap({ Int64($0) }), available >= 0 else { throw ShouError("unsupported_schema", "Guest disk usage could not be measured.") }
        let root=try diskMetadata(directory.appendingPathComponent("disk")), disk=try diskMetadata(home.appendingPathComponent(".colima/_lima/_disks/" + instance + "/datadisk"))
        let fingerprint=try Digest.of(["profile": profile, "colima": colima.identity, "source": source, "root": root.identity, "disk": disk.identity])
        return .init(profile: profile, fingerprint: fingerprint, logicalBytes: root.logical + disk.logical, allocatedBytes: root.allocated + disk.allocated, guestAvailableBytes: available)
    }
    private func diskMetadata(_ url: URL) throws -> (identity: String, logical: Int64, allocated: Int64) {
        let parent=try SecurePaths.directory(url.deletingLastPathComponent().path); defer { close(parent) }
        let fd=openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ShouError("disk_identity_unavailable", "The Colima disk identity is unavailable.") }
        defer { close(fd) }
        var metadata=stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= Int64.max / 4, metadata.st_blocks >= 0, metadata.st_blocks <= Int64.max / 2048 else { throw ShouError("disk_identity_unavailable", "The Colima disk has an unsupported type, owner or size.") }
        return ("\(url.path):\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_uid)", metadata.st_size, metadata.st_blocks * 512)
    }
    public func reclaim(_ evidence: DockerDiskReclamation, inventory: DockerStorageInventory) throws -> DockerDiskReclamation {
        let colima=try tools.locate("colima"), identity=colima + ":" + (try tools.identity(colima))
        let current=try binding(inventory.context.name)
        let verified=try diskEvidence(current.0, dockerRoot: current.3)
        guard current.0.endpoint == inventory.context.endpoint, current.1 == inventory.daemonId, current.2 == inventory.executableIdentity,
              verified.profile == evidence.profile, verified.fingerprint == evidence.fingerprint else { throw ShouError("source_changed", "The Docker backend or virtual disk changed before reclamation.") }
        _ = try run("colima", ["--profile", evidence.profile, "ssh", "--", "sudo", "-n", "fstrim", "--verbose", "--", "/var/lib/docker"], expected: identity, timeout: 300)
        let after=try diskEvidence(current.0, dockerRoot: current.3), backend=try binding(inventory.context.name)
        guard after.fingerprint == evidence.fingerprint, backend.0.endpoint == inventory.context.endpoint, backend.1 == inventory.daemonId, backend.2 == inventory.executableIdentity else { throw ShouError("result_unverified", "Disk reclamation could not be verified.") }
        return after
    }
}
#endif
