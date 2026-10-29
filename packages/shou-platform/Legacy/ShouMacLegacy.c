#include "ShouMacLegacy.h"

#if defined(__APPLE__)
#include <limits.h>

// No equivalent public APIs exist for per-executable ACLs in the legacy file
// Keychain or another application's login registrations. SMAppService manages
// the calling app only; Keychain access groups require a different signing
// contract. Keep these exact operations here without broadening trust or scope.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

OSStatus ShouLegacyKeychainAccessCreate(CFArrayRef executablePaths, SecAccessRef *access) {
    *access = NULL;
    CFIndex count = CFArrayGetCount(executablePaths);
    if (count < 1 || count > 2) return errSecParam;
    CFMutableArrayRef trusted = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    if (!trusted) return errSecAllocate;
    OSStatus status = errSecSuccess;
    for (CFIndex index = 0; index < count; index++) {
        CFStringRef path = CFArrayGetValueAtIndex(executablePaths, index);
        char bytes[PATH_MAX];
        if (CFGetTypeID(path) != CFStringGetTypeID() || !CFStringGetFileSystemRepresentation(path, bytes, sizeof(bytes))) {
            status = errSecParam;
            break;
        }
        SecTrustedApplicationRef application = NULL;
        status = SecTrustedApplicationCreateFromPath(bytes, &application);
        if (status != errSecSuccess) break;
        CFArrayAppendValue(trusted, application);
        CFRelease(application);
    }
    if (status == errSecSuccess) status = SecAccessCreate(CFSTR("Shou AI credentials"), trusted, access);
    CFRelease(trusted);
    return status;
}

LSSharedFileListRef ShouLegacyLoginItemsCreate(void) {
    return LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
}

CFArrayRef ShouLegacyLoginItemsCopySnapshot(LSSharedFileListRef list) {
    return LSSharedFileListCopySnapshot(list, NULL);
}

CFURLRef ShouLegacyLoginItemCopyURL(LSSharedFileListItemRef item) {
    return LSSharedFileListItemCopyResolvedURL(item, kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL);
}

CFStringRef ShouLegacyLoginItemCopyName(LSSharedFileListItemRef item) {
    return LSSharedFileListItemCopyDisplayName(item);
}

UInt32 ShouLegacyLoginItemGetID(LSSharedFileListItemRef item) {
    return LSSharedFileListItemGetID(item);
}

bool ShouLegacyLoginItemInsert(LSSharedFileListRef list, CFURLRef url) {
    LSSharedFileListItemRef item = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast, NULL, NULL, url, NULL, NULL);
    if (!item) return false;
    CFRelease(item);
    return true;
}

OSStatus ShouLegacyLoginItemRemove(LSSharedFileListRef list, LSSharedFileListItemRef item) {
    return LSSharedFileListItemRemove(list, item);
}

#pragma clang diagnostic pop
#endif
