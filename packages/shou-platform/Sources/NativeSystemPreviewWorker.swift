import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

/// One read-only, scan-bound preview per child process. It opens no record store
/// and never invokes a file association's executable command.
public enum NativeSystemPreviewWorker {
    private static func emit(_ value: [String: Any]) {
        guard var bytes=try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        bytes.append(10);FileHandle.standardOutput.write(bytes)
    }
    public static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--native-preview-worker" else { return nil }
        guard arguments == ["--native-preview-worker"] else { emit(["version": 1, "kind": "error", "code": "invalid_preview"]);return 2 }
        do {
            var bytes=Data()
            while let part=try FileHandle.standardInput.read(upToCount: min(4096,65_537-bytes.count)), !part.isEmpty {
                bytes.append(part)
                guard bytes.count <= 65_536 else { throw ShouError("invalid_preview", "System preview request exceeded its limit.") }
            }
            let object=try JSONSerialization.jsonObject(with: bytes)
            guard let keys=(object as? [String: Any]).map({ Set($0.keys) }),
                  keys == ["version", "parent_pid", "host_window", "preview"] else { throw ShouError("invalid_preview", "System preview request is invalid.") }
            let request=try Codec.decode(SystemPreviewRequest.self, from: bytes)
            try request.validate()
            #if os(Windows)
            var root=try WindowsNative.savedInfo(request.preview.rootIdentity), file=try WindowsNative.savedInfo(request.preview.file)
            var stream: UnsafeMutableRawPointer?
            try WindowsNative.check(shou_win_preview_stream(request.preview.rootPath,&root,request.preview.absolutePath,&file,&stream), path: request.preview.file.path)
            guard let stream else { throw ShouError("invalid_preview", "System preview stream is unavailable.") }
            defer { shou_win_preview_stream_release(stream) }
            let status=shou_win_preview_host(request.preview.absolutePath,stream,request.hostWindow,request.parentPid,{ _ in
                NativeSystemPreviewWorker.emit(["version": 1, "kind": "ready"])
            },nil)
            guard status == 0 else {
                emit(["version": 1, "kind": "error", "code": "preview_unavailable", "native_code": status]);return 1
            }
            emit(["version": 1, "kind": "closed"]);return 0
            #else
            emit(["version": 1, "kind": "error", "code": "capability_unavailable"]);return 1
            #endif
        } catch {
            emit(["version": 1, "kind": "error", "code": (error as? ShouError)?.code ?? "invalid_preview"]);return 1
        }
    }
}
