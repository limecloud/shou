#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "shou_windows.h"
#include <windows.h>
#include <wincred.h>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {
std::wstring credentialTarget(const char *account) {
    if (!account || std::strlen(account) > 256) return {};
    std::wstring target=L"Shou/AI/";
    for (const unsigned char *c=reinterpret_cast<const unsigned char *>(account); *c; ++c) {
        if (!( (*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '_' || *c == '-' || *c == '.')) return {};
        target.push_back(*c);
    }
    return target;
}
}
extern "C" int shou_win_ai_credential_read(const char *account, void **bytes, size_t *count) {
    if (!bytes || !count) return ERROR_INVALID_PARAMETER;
    *bytes=nullptr; *count=0;
    auto target=credentialTarget(account); if (target.empty()) return ERROR_INVALID_PARAMETER;
    PCREDENTIALW value=nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &value)) return GetLastError();
    if (!value->CredentialBlobSize || value->CredentialBlobSize > CRED_MAX_CREDENTIAL_BLOB_SIZE) { CredFree(value); return ERROR_INVALID_DATA; }
    void *copy=std::malloc(value->CredentialBlobSize);
    if (!copy) { CredFree(value); return ERROR_NOT_ENOUGH_MEMORY; }
    std::memcpy(copy,value->CredentialBlob,value->CredentialBlobSize);
    *bytes=copy; *count=value->CredentialBlobSize;
    CredFree(value); return 0;
}
extern "C" int shou_win_ai_credential_write(const char *account, const void *bytes, size_t count) {
    auto target=credentialTarget(account);
    if (target.empty() || !bytes || !count || count > CRED_MAX_CREDENTIAL_BLOB_SIZE) return ERROR_INVALID_PARAMETER;
    CREDENTIALW value{};
    value.Type=CRED_TYPE_GENERIC; value.TargetName=target.data();
    value.CredentialBlobSize=static_cast<DWORD>(count);
    value.CredentialBlob=static_cast<LPBYTE>(const_cast<void *>(bytes));
    value.Persist=CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&value,0) ? 0 : GetLastError();
}
