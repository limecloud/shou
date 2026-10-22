#if os(Windows)
import Foundation
import ShouCore
import CShouWindows

private final class WindowsHashCancellation {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check=check }
}

func windowsStorageFileDigest(_ path: String, entry: FileEntry, maxSeconds: Double, cancelled: @Sendable () -> Bool) throws -> String {
    if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Target inspection stopped.") }
    var expected=try WindowsNative.savedInfo(entry)
    return try withoutActuallyEscaping(cancelled) { callback in
        let context=WindowsHashCancellation(callback)
        return try WindowsNative.string({ result in
            shou_win_hash(path, &expected, UInt32(max(1, min(600_000, maxSeconds * 1000))), { pointer in
                guard let pointer else { return 1 }
                return Unmanaged<WindowsHashCancellation>.fromOpaque(pointer).takeUnretainedValue().check() || Task.isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(context).toOpaque(), result)
        }, path: path)
    }
}
#endif
