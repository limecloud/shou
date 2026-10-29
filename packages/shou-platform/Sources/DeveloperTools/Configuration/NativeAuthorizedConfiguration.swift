import Foundation
import ShouCore
#if os(macOS)
import Darwin

/// Exact configuration and log operations share native file checks and the
/// process authorization session. The worker never runs configuration content.
enum NativeAuthorizedConfiguration {
    static func supports(_ path: String, configuration: Bool, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        guard let parts=try? SecurePaths.components(path), path == "/" + parts.joined(separator: "/"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let protected=[".ssh", ".gnupg", ".aws", ".kube", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Application Support/Shou"]
            .map { home + "/" + $0 }
        let compared=path.lowercased()
        guard !protected.contains(where: { compared == $0.lowercased() || compared.hasPrefix($0.lowercased() + "/") }) else { return false }
        let roots=configuration ? [home, "/opt/homebrew/etc", "/usr/local/etc", "/private/etc/mysql", "/private/etc/nginx", "/private/etc/apache2"] :
            [home, "/opt/homebrew/var/log", "/usr/local/var/log", "/private/var/log"]
        let known=configuration && ["/private/etc/my.cnf", "/private/etc/redis.conf"].contains(path)
        return (known || roots.contains(where: { path.hasPrefix($0 + "/") })) && (!configuration || NativeDeveloperConfigurationFiles.accepts(path))
    }

    static func perform(_ request: AuthorizationRequest, home: String, uid: UInt32) throws -> AuthorizationReply {
        let configuration=[AuthorizationOperation.configurationRead, .configurationSave].contains(request.operation)
        guard supports(request.path,configuration:configuration,home:home), request.manifest == nil, request.budget == nil,
              request.action == nil, request.trashPath == nil, request.rules == nil, request.fullDiskAccess == nil else {
            throw ShouError("protected_content", "This file is outside supported configuration and log locations.")
        }
        let files=NativeDeveloperConfigurationFiles(currentUser:uid)
        switch request.operation {
        case .configurationRead:
            guard request.document == nil, request.text == nil, request.logInspection == nil, request.toolID == nil else { throw AuthorizationChannel.failure() }
            return AuthorizationReply(id:request.id,document:try files.read(request.path))
        case .configurationSave:
            guard let document=request.document, let text=request.text, document.path == request.path,
                  document.writable, document.identity.mode & 0o022 == 0, request.logInspection == nil, request.toolID == nil else { throw AuthorizationChannel.failure() }
            return AuthorizationReply(id:request.id,document:try files.overwrite(text,expected:document))
        case .logRead:
            guard request.document == nil, request.text == nil, request.logInspection == nil, request.toolID == nil else { throw AuthorizationChannel.failure() }
            return AuthorizationReply(id:request.id,text:try files.log(path:request.path))
        case .logInspect, .logClear:
            guard request.document == nil, request.text == nil else { throw AuthorizationChannel.failure() }
            let toolID: String
            if request.operation == .logClear {
                guard let inspection=request.logInspection, inspection.file.path == request.path, request.toolID == nil else { throw AuthorizationChannel.failure() }
                toolID=inspection.toolID
            } else {
                guard let requested=request.toolID, !requested.isEmpty, requested.utf8.count <= 255, request.logInspection == nil else { throw AuthorizationChannel.failure() }
                toolID=requested
            }
            let cleaner=NativeDeveloperLogCleanup(toolID:toolID,target:.init(path:request.path,title:"Service Log"),homeDirectory:URL(fileURLWithPath:home),currentUser:uid)
            if let inspection=request.logInspection { try cleaner.clear(expected:inspection) }
            return AuthorizationReply(id:request.id,logInspection:try cleaner.inspect())
        default: throw AuthorizationChannel.failure()
        }
    }
}
#endif
