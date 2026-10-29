#ifndef SHOU_MAC_LEGACY_H
#define SHOU_MAC_LEGACY_H

#if defined(__APPLE__)
#include <CoreServices/CoreServices.h>
#include <Security/Security.h>
#include <stdbool.h>

CF_IMPLICIT_BRIDGING_ENABLED

OSStatus ShouLegacyKeychainAccessCreate(CFArrayRef _Nonnull executablePaths, SecAccessRef _Nullable * _Nonnull access);
LSSharedFileListRef _Nullable ShouLegacyLoginItemsCreate(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable ShouLegacyLoginItemsCopySnapshot(LSSharedFileListRef _Nonnull list) CF_RETURNS_RETAINED;
CFURLRef _Nullable ShouLegacyLoginItemCopyURL(LSSharedFileListItemRef _Nonnull item) CF_RETURNS_RETAINED;
CFStringRef _Nullable ShouLegacyLoginItemCopyName(LSSharedFileListItemRef _Nonnull item) CF_RETURNS_RETAINED;
UInt32 ShouLegacyLoginItemGetID(LSSharedFileListItemRef _Nonnull item);
bool ShouLegacyLoginItemInsert(LSSharedFileListRef _Nonnull list, CFURLRef _Nonnull url);
OSStatus ShouLegacyLoginItemRemove(LSSharedFileListRef _Nonnull list, LSSharedFileListItemRef _Nonnull item);

CF_IMPLICIT_BRIDGING_DISABLED
#endif
#endif
