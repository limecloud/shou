#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <tlhelp32.h>
#include <aclapi.h>
#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <bcrypt.h>
#include <algorithm>
#include <cstdlib>
#include <cctype>
#include <cstring>
#include <cwctype>
#include <limits>
#include <map>
#include <numeric>
#include <new>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;

extern "C" int shou_win_process_running(const char *name, int *running) {
    if (!name || !running) return ERROR_INVALID_PARAMETER;
    *running=0;
    HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return GetLastError();
    PROCESSENTRY32W entry{}; entry.dwSize=sizeof(entry);
    if (!Process32FirstW(snapshot, &entry)) {
        const DWORD error=GetLastError(); CloseHandle(snapshot);
        return error == ERROR_NO_MORE_FILES ? 0 : error;
    }
    do {
        std::wstring expected;
        for (const unsigned char *c=reinterpret_cast<const unsigned char *>(name); *c; ++c) expected.push_back(*c);
        if (_wcsicmp(entry.szExeFile, expected.c_str()) == 0) { *running=1; CloseHandle(snapshot); return 0; }
    } while (Process32NextW(snapshot, &entry));
    const DWORD error=GetLastError(); CloseHandle(snapshot);
    return error == ERROR_NO_MORE_FILES ? 0 : error;
}

namespace {
std::wstring wide(const char *text) {
    int n=MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
    if (!n) return {};
    std::wstring value(n, 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, value.data(), n);
    value.resize(n-1); return value;
}
char *utf8(const std::wstring &text) {
    int n=WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (!n) return nullptr;
    auto result=static_cast<char *>(malloc(n));
    if (result) WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.c_str(), -1, result, n, nullptr, nullptr);
    return result;
}
DWORD normalized(const char *input, std::wstring &path) {
    path=wide(input);
    if (path.size()>3 && path[0]==L'/' && path[2]==L':') path.erase(0,1);
    std::replace(path.begin(),path.end(),L'/',L'\\');
    if (path.size()<3 || !((path[0]>=L'A' && path[0]<=L'Z') || (path[0]>=L'a' && path[0]<=L'z')) || path[1]!=L':' || path[2]!=L'\\' || path.size()>32000) return ERROR_INVALID_NAME;
    for (size_t start=3; start<path.size();) {
        size_t end=path.find(L'\\',start); if (end==std::wstring::npos) end=path.size();
        auto part=path.substr(start,end-start);
        if (part.empty() || part==L"." || part==L".." || part.back()==L'.' || part.back()==L' ' || part.find_first_of(L"<>:\"|?*")!=std::wstring::npos) return ERROR_INVALID_NAME;
        for (auto c:part) if (c<32) return ERROR_INVALID_NAME;
        auto base=part.substr(0,part.find(L'.')); while(!base.empty() && base.back()==L' ')base.pop_back();for(auto &c:base)c=towupper(c);
        if (base==L"CON" || base==L"PRN" || base==L"AUX" || base==L"NUL" || base==L"CONIN$" || base==L"CONOUT$" ||
            (base.size()==4 && (base.substr(0,3)==L"COM" || base.substr(0,3)==L"LPT") &&
             ((base[3]>=L'1' && base[3]<=L'9') || base[3]==L'\u00b9' || base[3]==L'\u00b2' || base[3]==L'\u00b3'))) return ERROR_INVALID_NAME;
        start=end+1;
    }
    if (path.size()>3 && path.back()==L'\\') path.pop_back();
    path[0]=towupper(path[0]);
    std::wstring drive=path.substr(0,3);
    if (GetDriveTypeW(drive.c_str())!=DRIVE_FIXED) return ERROR_NOT_SUPPORTED;
    return 0;
}
std::wstring extended(const std::wstring &path) { return L"\\\\?\\"+path; }
// Expand existing DOS 8.3 aliases before Swift applies protected-root policy.
// New destinations inherit the canonical spelling of their nearest existing
// ancestor. This does not resolve reparse points; open() still rejects them.
DWORD canonicalSpelling(std::wstring &path){
    std::vector<std::wstring> missing;
    auto parent=path;
    while(true){
        const auto input=extended(parent);
        const auto count=GetLongPathNameW(input.c_str(),nullptr,0);
        if(count){
            if(count>32768)return ERROR_FILENAME_EXCED_RANGE;
            std::wstring value(count,0);
            const auto written=GetLongPathNameW(input.c_str(),value.data(),count);
            if(!written)return GetLastError();
            if(written>=count)return ERROR_MORE_DATA;
            value.resize(written);
            if(value.rfind(L"\\\\?\\",0)!=0)return ERROR_INVALID_NAME;
            value.erase(0,4);
            for(auto item=missing.rbegin();item!=missing.rend();++item){if(value.back()!=L'\\')value+=L'\\';value+=*item;}
            auto encoded=utf8(value);if(!encoded)return ERROR_NO_UNICODE_TRANSLATION;
            const auto code=normalized(encoded,path);free(encoded);return code;
        }
        const auto code=GetLastError();
        if((code!=ERROR_FILE_NOT_FOUND && code!=ERROR_PATH_NOT_FOUND) || parent.size()<=3)return code;
        const auto split=parent.find_last_of(L'\\');
        missing.push_back(parent.substr(split+1));parent.resize(split==2?3:split);
    }
}
struct Handles {
    std::vector<HANDLE> values;
    ~Handles(){for(auto h:values)if(h!=INVALID_HANDLE_VALUE)CloseHandle(h);}
};
// Pin ancestors against rename while opening an object. Never follow a reparse point.
DWORD open(const std::wstring &path, Handles &pins, HANDLE &last, DWORD access=FILE_READ_ATTRIBUTES|READ_CONTROL, DWORD share=FILE_SHARE_READ|FILE_SHARE_WRITE, DWORD ancestorShare=FILE_SHARE_READ|FILE_SHARE_WRITE, DWORD ancestorAccess=FILE_READ_ATTRIBUTES) {
    size_t end=3;
    while (true) {
        auto part=extended(path.substr(0,end));
        bool final=end==path.size();
        HANDLE h=CreateFileW(part.c_str(),final?access:ancestorAccess, final?share:ancestorShare,
            nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
        if(h==INVALID_HANDLE_VALUE)return GetLastError();
        pins.values.push_back(h);
        FILE_ATTRIBUTE_TAG_INFO tag{};
        if(!GetFileInformationByHandleEx(h,FileAttributeTagInfo,&tag,sizeof(tag)))return GetLastError();
        if(tag.FileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE|0x00040000|0x00400000))return ERROR_REPARSE_TAG_INVALID;
        if(tag.FileAttributes&FILE_ATTRIBUTE_DIRECTORY){
            FILE_CASE_SENSITIVE_INFO sensitive{};
            if(!GetFileInformationByHandleEx(h,FileCaseSensitiveInfo,&sensitive,sizeof(sensitive)))return GetLastError();
            if(sensitive.Flags!=0)return ERROR_NOT_SUPPORTED;
        }
        if(final){last=h;return 0;}
        end=path.find(L'\\',end==3?3:end+1);if(end==std::wstring::npos)end=path.size();
    }
}
std::vector<BYTE> user_sid() {
    HANDLE token=nullptr; if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return {};
    DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);
    std::vector<BYTE> data(size);
    bool ok=GetTokenInformation(token,TokenUser,data.data(),size,&size)!=0;CloseHandle(token);
    if(!ok)return {};
    PSID sid=reinterpret_cast<TOKEN_USER *>(data.data())->User.Sid;
    std::vector<BYTE> value(GetLengthSid(sid));CopySid(static_cast<DWORD>(value.size()),value.data(),sid);return value;
}
DWORD info(HANDLE h, shou_win_info *out) {
    *out={};FILE_ID_INFO id{};FILE_BASIC_INFO basic{};FILE_STANDARD_INFO size{};
    if(!GetFileInformationByHandleEx(h,FileIdInfo,&id,sizeof(id)) ||
       !GetFileInformationByHandleEx(h,FileBasicInfo,&basic,sizeof(basic)) ||
       !GetFileInformationByHandleEx(h,FileStandardInfo,&size,sizeof(size)))return GetLastError();
    PSID owner=nullptr;PSECURITY_DESCRIPTOR descriptor=nullptr;
    DWORD code=GetSecurityInfo(h,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION,&owner,nullptr,nullptr,nullptr,&descriptor);
    if(code)return code;
    LPSTR sid=nullptr;BOOL converted=ConvertSidToStringSidA(owner,&sid);
    auto user=user_sid();out->current_user=!user.empty() && EqualSid(owner,user.data());
    if(converted && strlen(sid)<sizeof(out->owner_sid))strcpy_s(out->owner_sid,sid);
    if(sid)LocalFree(sid);LocalFree(descriptor);
    if(!converted || !out->owner_sid[0])return ERROR_INVALID_SID;
    out->volume=id.VolumeSerialNumber;memcpy(out->file_id,id.FileId.Identifier,16);
    out->kind=basic.FileAttributes&FILE_ATTRIBUTE_DIRECTORY?2:1;
    out->attributes=basic.FileAttributes;out->links=size.NumberOfLinks;
    out->logical_bytes=size.EndOfFile.QuadPart;out->allocated_bytes=size.AllocationSize.QuadPart;
    constexpr int64_t epoch=116444736000000000LL;
    if(basic.LastWriteTime.QuadPart<0 || basic.ChangeTime.QuadPart<0 || out->logical_bytes<0 || out->allocated_bytes<0)return ERROR_INVALID_DATA;
    auto modified=basic.LastWriteTime.QuadPart-epoch,changed=basic.ChangeTime.QuadPart-epoch;
    constexpr auto minimum=std::numeric_limits<int64_t>::min()/100,maximum=std::numeric_limits<int64_t>::max()/100;
    if(modified<minimum || modified>maximum || changed<minimum || changed>maximum)return ERROR_INVALID_DATA;
    out->modified_ns=modified*100;out->changed_ns=changed*100;return 0;
}
bool same(const shou_win_info &a,const shou_win_info &b,bool directoryMutation=false) {
    return a.volume==b.volume && !memcmp(a.file_id,b.file_id,16) && !strcmp(a.owner_sid,b.owner_sid) &&
        a.kind==b.kind && ((directoryMutation && a.kind==2) || a.links==b.links) && a.attributes==b.attributes && (directoryMutation ||
        (a.logical_bytes==b.logical_bytes && a.allocated_bytes==b.allocated_bytes && a.modified_ns==b.modified_ns && a.changed_ns==b.changed_ns));
}
DWORD expected(const std::wstring &path,const shou_win_info *saved) {
    Handles handles;HANDLE h;DWORD code=open(path,handles,h);if(code)return code;
    shou_win_info current{};if((code=info(h,&current)))return code;
    return same(current,*saved)?0:ERROR_FILE_INVALID;
}
DWORD hashFile(HANDLE file,char result[65],uint32_t milliseconds,shou_win_read_cancelled cancelled,void *context){
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;PUCHAR object=nullptr;
    DWORD objectSize=0,bytes=0,read=0,code=ERROR_INVALID_DATA;BYTE hashBytes[32]{};BYTE buffer[65536];
    const auto deadline=GetTickCount64()+milliseconds;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)!=0)goto done;
    if(BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&objectSize),sizeof(objectSize),&bytes,0)!=0 || !objectSize)goto done;
    object=static_cast<PUCHAR>(malloc(objectSize));if(!object){code=ERROR_NOT_ENOUGH_MEMORY;goto done;}
    if(BCryptCreateHash(algorithm,&hash,object,objectSize,nullptr,0,0)!=0)goto done;
    while(true){
        if(cancelled && cancelled(context)){code=ERROR_CANCELLED;goto done;}
        if(GetTickCount64()>=deadline){code=ERROR_TIMEOUT;goto done;}
        if(!ReadFile(file,buffer,sizeof(buffer),&read,nullptr)){code=GetLastError();goto done;}
        if(!read)break;
        if(BCryptHashData(hash,buffer,read,0)!=0)goto done;
    }
    if(BCryptFinishHash(hash,hashBytes,sizeof(hashBytes),0)!=0)goto done;
    for(size_t i=0;i<32;++i)sprintf_s(result+i*2,3,"%02x",hashBytes[i]);
    result[64]='\0';code=0;
done:
    if(hash)BCryptDestroyHash(hash);if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);free(object);return code;
}
bool digest(HANDLE file,const char *expectedDigest){
    if(!expectedDigest || !*expectedDigest)return true;
    if(strlen(expectedDigest)!=64)return false;
    for(size_t i=0;i<64;++i)if(!isxdigit(static_cast<unsigned char>(expectedDigest[i])))return false;
    LARGE_INTEGER origin{};char observed[65]{};
    return SetFilePointerEx(file,origin,nullptr,FILE_BEGIN) && hashFile(file,observed,180000,nullptr,nullptr)==0 && _stricmp(observed,expectedDigest)==0;
}
DWORD private_descriptor(const std::vector<BYTE> &user,PSECURITY_DESCRIPTOR &descriptor) {
    if(user.empty())return ERROR_INVALID_SID;
    LPWSTR sid=nullptr;if(!ConvertSidToStringSidW(reinterpret_cast<PSID>(const_cast<BYTE *>(user.data())),&sid))return GetLastError();
    std::wstring sddl=L"O:"+std::wstring(sid)+L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+std::wstring(sid)+L")";LocalFree(sid);
    if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&descriptor,nullptr))return GetLastError();
    return 0;
}
DWORD private_acl(const std::wstring &path,bool create) {
    Handles parentPins;HANDLE parent;
    auto parentPath=path.substr(0,path.find_last_of(L'\\'));if(parentPath.size()==2)parentPath+=L'\\';
    DWORD parentCode=open(parentPath,parentPins,parent);if(parentCode)return parentCode;
    auto user=user_sid();PSECURITY_DESCRIPTOR descriptor=nullptr;
    if((parentCode=private_descriptor(user,descriptor)))return parentCode;
    SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
    if(create && !CreateDirectoryW(extended(path).c_str(),&attributes) && GetLastError()!=ERROR_ALREADY_EXISTS){DWORD code=GetLastError();LocalFree(descriptor);return code;}
    LocalFree(descriptor);
    Handles pins;HANDLE h;DWORD code=open(path,pins,h);if(code)return code;
    PSID owner=nullptr;PACL acl=nullptr;descriptor=nullptr;
    code=GetSecurityInfo(h,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&owner,nullptr,&acl,nullptr,&descriptor);
    if(code)return code;
    bool valid=EqualSid(owner,user.data()) && acl;
    BYTE system[SECURITY_MAX_SID_SIZE];DWORD systemSize=sizeof(system);CreateWellKnownSid(WinLocalSystemSid,nullptr,system,&systemSize);
    for(DWORD i=0;valid && i<acl->AceCount;i++){
        void *raw=nullptr;if(!GetAce(acl,i,&raw)){valid=false;break;}
        auto ace=static_cast<ACCESS_ALLOWED_ACE *>(raw);
        if(ace->Header.AceType!=ACCESS_ALLOWED_ACE_TYPE || (!EqualSid(&ace->SidStart,user.data()) && !EqualSid(&ace->SidStart,system)))valid=false;
    }
    LocalFree(descriptor);return valid?0:ERROR_ACCESS_DENIED;
}

// Browser data may inherit read permissions. Mutation rights must remain with
// this user, SYSTEM or Administrators; discovery never rewrites an existing ACL.
// Trusted directory owners are allowed; database and sidecar owners stay exact.
DWORD privacy_acl(HANDLE file,bool trustedDirectoryOwner=false){
    auto user=user_sid();if(user.empty())return ERROR_INVALID_SID;
    PSID owner=nullptr;PACL acl=nullptr;PSECURITY_DESCRIPTOR descriptor=nullptr;
    auto code=GetSecurityInfo(file,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&owner,nullptr,&acl,nullptr,&descriptor);
    if(code)return code;
    BYTE system[SECURITY_MAX_SID_SIZE],administrators[SECURITY_MAX_SID_SIZE];
    DWORD systemSize=sizeof(system),adminSize=sizeof(administrators);
    bool valid=owner && acl &&
        CreateWellKnownSid(WinLocalSystemSid,nullptr,system,&systemSize) &&
        CreateWellKnownSid(WinBuiltinAdministratorsSid,nullptr,administrators,&adminSize);
    valid=valid && (EqualSid(owner,user.data()) || (trustedDirectoryOwner &&
        (EqualSid(owner,system) || EqualSid(owner,administrators))));
    constexpr DWORD mutations=GENERIC_ALL|GENERIC_WRITE|DELETE|WRITE_DAC|WRITE_OWNER|FILE_WRITE_DATA|FILE_APPEND_DATA|FILE_WRITE_EA|FILE_WRITE_ATTRIBUTES|FILE_DELETE_CHILD;
    for(DWORD i=0;valid && i<acl->AceCount;i++){
        void *raw=nullptr;if(!GetAce(acl,i,&raw)){valid=false;break;}
        auto header=static_cast<ACE_HEADER *>(raw);
        if(header->AceFlags&INHERIT_ONLY_ACE || header->AceType==ACCESS_DENIED_ACE_TYPE)continue;
        if(header->AceType!=ACCESS_ALLOWED_ACE_TYPE){valid=false;break;}
        auto ace=static_cast<ACCESS_ALLOWED_ACE *>(raw);
        if((ace->Mask&mutations) && !EqualSid(&ace->SidStart,user.data()) &&
           !EqualSid(&ace->SidStart,system) && !EqualSid(&ace->SidStart,administrators))valid=false;
    }
    LocalFree(descriptor);return valid?0:ERROR_ACCESS_DENIED;
}

class Sink final:public IFileOperationProgressSink {
    LONG references=1;
public:
    std::wstring source,destination,result;shou_win_info saved{};HRESULT outcome=E_PENDING;bool recycle;
    Sink(std::wstring from,std::wstring to,const shou_win_info &identity,bool trash):source(std::move(from)),destination(std::move(to)),saved(identity),recycle(trash){}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **value) override {if(iid==IID_IUnknown || iid==__uuidof(IFileOperationProgressSink)){*value=this;AddRef();return S_OK;}*value=nullptr;return E_NOINTERFACE;}
    ULONG STDMETHODCALLTYPE AddRef() override{return InterlockedIncrement(&references);}
    ULONG STDMETHODCALLTYPE Release() override{auto n=InterlockedDecrement(&references);if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE StartOperations() override{return S_OK;}
    HRESULT STDMETHODCALLTYPE FinishOperations(HRESULT hr) override{if(FAILED(hr))outcome=hr;return S_OK;}
    HRESULT STDMETHODCALLTYPE PreDeleteItem(DWORD flags,IShellItem *) override {
        if(!recycle || !(flags&TSF_DELETE_RECYCLE_IF_POSSIBLE))return E_ABORT;
        DWORD code=expected(source,&saved);return code?HRESULT_FROM_WIN32(code):S_OK;
    }
    HRESULT STDMETHODCALLTYPE PostDeleteItem(DWORD,IShellItem *,HRESULT hr,IShellItem *created) override {return finish(hr,created);}
    HRESULT STDMETHODCALLTYPE PreMoveItem(DWORD,IShellItem *,IShellItem *,LPCWSTR) override {
        if(recycle)return E_ABORT;
        if(GetFileAttributesW(extended(destination).c_str())!=INVALID_FILE_ATTRIBUTES)return HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);
        DWORD code=expected(source,&saved);return code?HRESULT_FROM_WIN32(code):S_OK;
    }
    HRESULT STDMETHODCALLTYPE PostMoveItem(DWORD,IShellItem *,IShellItem *,LPCWSTR,HRESULT hr,IShellItem *created) override{return finish(hr,created);}
    HRESULT finish(HRESULT hr,IShellItem *created){outcome=hr;if(SUCCEEDED(hr)&&created){PWSTR text=nullptr;if(SUCCEEDED(created->GetDisplayName(SIGDN_FILESYSPATH,&text))){result=text;CoTaskMemFree(text);}}return S_OK;}
    HRESULT STDMETHODCALLTYPE PreRenameItem(DWORD,IShellItem *,LPCWSTR) override{return E_ABORT;}
    HRESULT STDMETHODCALLTYPE PostRenameItem(DWORD,IShellItem *,LPCWSTR,HRESULT,IShellItem *) override{return S_OK;}
    HRESULT STDMETHODCALLTYPE PreCopyItem(DWORD,IShellItem *,IShellItem *,LPCWSTR) override{return E_ABORT;}
    HRESULT STDMETHODCALLTYPE PostCopyItem(DWORD,IShellItem *,IShellItem *,LPCWSTR,HRESULT,IShellItem *) override{return S_OK;}
    HRESULT STDMETHODCALLTYPE PreNewItem(DWORD,IShellItem *,LPCWSTR) override{return E_ABORT;}
    HRESULT STDMETHODCALLTYPE PostNewItem(DWORD,IShellItem *,LPCWSTR,LPCWSTR,DWORD,HRESULT,IShellItem *) override{return S_OK;}
    HRESULT STDMETHODCALLTYPE UpdateProgress(UINT,UINT) override{return S_OK;}
    HRESULT STDMETHODCALLTYPE ResetTimer() override{return S_OK;}
    HRESULT STDMETHODCALLTYPE PauseTimer() override{return S_OK;}
    HRESULT STDMETHODCALLTYPE ResumeTimer() override{return S_OK;}
};
int shell_move(const char *input,const char *target,const shou_win_info *saved,char **result) {
    *result=nullptr;std::wstring path,destination;DWORD code=normalized(input,path);if(code)return code;
    if(target && (code=normalized(target,destination)))return code;
    if(target && path[0]!=destination[0])return ERROR_NOT_SAME_DEVICE;
    if((code=expected(path,saved)))return code;
    Handles pins;HANDLE parent;auto parentPath=path.substr(0,path.find_last_of(L'\\'));if(parentPath.size()==2)parentPath+=L'\\';
    if((code=open(parentPath,pins,parent)))return code;
    if(target){auto p=destination.substr(0,destination.find_last_of(L'\\'));if(p.size()==2)p+=L'\\';if((code=open(p,pins,parent)))return code;}
    HRESULT initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    if(FAILED(initialized))return static_cast<int>(initialized);
    HRESULT hr;
    {
        ComPtr<IFileOperation> operation;ComPtr<IShellItem> source,folder;ComPtr<Sink> sink;
        sink.Attach(new Sink(path,destination,*saved,!target));
        hr=CoCreateInstance(CLSID_FileOperation,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&operation));
        if(SUCCEEDED(hr))hr=operation->SetOperationFlags(FOF_SILENT|FOF_NOERRORUI|FOFX_EARLYFAILURE|FOFX_NOCOPYHOOKS|
            (target?FOF_RENAMEONCOLLISION:FOFX_RECYCLEONDELETE|FOF_WANTNUKEWARNING));
        if(SUCCEEDED(hr))hr=SHCreateItemFromParsingName(path.c_str(),nullptr,IID_PPV_ARGS(&source));
        if(SUCCEEDED(hr) && target){
            auto p=destination.substr(0,destination.find_last_of(L'\\'));if(p.size()==2)p+=L'\\';
            hr=SHCreateItemFromParsingName(p.c_str(),nullptr,IID_PPV_ARGS(&folder));
            if(SUCCEEDED(hr))hr=operation->MoveItem(source.Get(),folder.Get(),destination.substr(destination.find_last_of(L'\\')+1).c_str(),sink.Get());
        }else if(SUCCEEDED(hr))hr=operation->DeleteItem(source.Get(),sink.Get());
        if(SUCCEEDED(hr))hr=operation->PerformOperations();
        BOOL aborted=FALSE;if(SUCCEEDED(hr))hr=operation->GetAnyOperationsAborted(&aborted);
        if(SUCCEEDED(hr) && aborted)hr=E_ABORT;
        if(!sink->result.empty())*result=utf8(sink->result);
        if(SUCCEEDED(hr))hr=sink->outcome;
    }
    CoUninitialize();return SUCCEEDED(hr)?0:static_cast<int>(hr);
}
}

// The cursor pins the directory and all ancestors against rename. It returns
// one name at a time, keeping wide-directory memory independent of entry count.
struct shou_win_directory {
    Handles pins;
    HANDLE directory=INVALID_HANDLE_VALUE, search=INVALID_HANDLE_VALUE;
    WIN32_FIND_DATAW data{};
    DWORD nextError=0;
    bool first=true;
    ~shou_win_directory(){if(search!=INVALID_HANDLE_VALUE)FindClose(search);}
};
struct shou_win_privacy_access { Handles pins; };

extern "C" {
void shou_win_free(void *value){free(value);}
int shou_win_privacy_directory(const char *input){
    std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE directory;if((code=open(path,pins,directory)))return code;
    shou_win_info metadata{};if((code=info(directory,&metadata)))return code;
    return metadata.kind==2?privacy_acl(directory,true):ERROR_DIRECTORY;
}
void shou_win_privacy_release(shou_win_privacy_access *access){delete access;}
int shou_win_privacy_acquire(const char *homeInput,const char *input,int writable,shou_win_privacy_access **result){
    if(!homeInput || !input || !result || (writable!=0 && writable!=1))return ERROR_INVALID_PARAMETER;
    *result=nullptr;std::wstring home,path;auto code=normalized(homeInput,home);if(code)return code;
    if((code=normalized(input,path)))return code;
    if(home.size()<=3 || path.size()<=home.size()+1 || path[home.size()]!=L'\\' ||
       _wcsnicmp(home.c_str(),path.c_str(),home.size())!=0 || std::count(path.begin(),path.end(),L'\\')>32)return ERROR_ACCESS_DENIED;
    auto access=new(std::nothrow) shou_win_privacy_access();if(!access)return ERROR_NOT_ENOUGH_MEMORY;
    auto acquire=[&]()->DWORD {
        HANDLE file;
        const DWORD rights=GENERIC_READ|READ_CONTROL|(writable?GENERIC_WRITE:0);
        if(auto failure=open(path,access->pins,file,rights,FILE_SHARE_READ|FILE_SHARE_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,FILE_READ_ATTRIBUTES|READ_CONTROL))return failure;
        size_t end=3,index=0;
        while(true){
            if(end>=home.size()){
                shou_win_info metadata{};
                if(auto failure=info(access->pins.values[index],&metadata))return failure;
                const bool directory=end!=path.size();
                if(directory ? metadata.kind!=2 : (metadata.kind!=1 || metadata.links!=1 || !metadata.current_user))return ERROR_ACCESS_DENIED;
                if(auto failure=privacy_acl(access->pins.values[index],directory))return failure;
            }
            if(end==path.size())break;
            end=path.find(L'\\',end==3?3:end+1);if(end==std::wstring::npos)end=path.size();index++;
        }
        for(const auto suffix:{L"-wal",L"-shm",L"-journal"}){
            HANDLE sidecar;
            const auto failure=open(path+suffix,access->pins,sidecar,rights);
            if(failure==ERROR_FILE_NOT_FOUND || failure==ERROR_PATH_NOT_FOUND)continue;
            if(failure)return failure;
            shou_win_info metadata{};if(auto status=info(sidecar,&metadata))return status;
            if(metadata.kind!=1 || metadata.links!=1 || !metadata.current_user)return ERROR_ACCESS_DENIED;
            if(auto status=privacy_acl(sidecar))return status;
        }
        return 0;
    };
    code=acquire();if(code){delete access;return code;}*result=access;return 0;
}
int shou_win_hash(const char *input,const shou_win_info *saved,uint32_t milliseconds,shou_win_read_cancelled cancelled,void *context,char **result){
    if(!input || !saved || !result || !milliseconds || milliseconds>600000 || saved->kind!=1)return ERROR_INVALID_PARAMETER;
    *result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE file;if((code=open(path,pins,file,GENERIC_READ|READ_CONTROL,FILE_SHARE_READ)))return code;
    shou_win_info before{},after{};char value[65]{};
    if((code=info(file,&before)))return code;
    if(!same(before,*saved))return ERROR_FILE_INVALID;
    if((code=hashFile(file,value,milliseconds,cancelled,context)))return code;
    if((code=info(file,&after)))return code;
    if(!same(before,after))return ERROR_FILE_INVALID;
    *result=static_cast<char *>(malloc(sizeof(value)));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;
    memcpy(*result,value,sizeof(value));return 0;
}
void shou_win_directory_close(shou_win_directory *directory){delete directory;}
int shou_win_directory_open(const char *input,const shou_win_info *saved,shou_win_directory **result){
    if(!input || !saved || !result || saved->kind!=2)return ERROR_INVALID_PARAMETER;
    *result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;
    auto cursor=new(std::nothrow) shou_win_directory();if(!cursor)return ERROR_NOT_ENOUGH_MEMORY;
    shou_win_info current{};
    if((code=open(path,cursor->pins,cursor->directory,FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES|READ_CONTROL)) ||
       (code=info(cursor->directory,&current))){delete cursor;return code;}
    if(!same(current,*saved)){delete cursor;return ERROR_FILE_INVALID;}
    const auto pattern=extended(path)+(path.back()==L'\\'?L"*":L"\\*");
    cursor->search=FindFirstFileExW(pattern.c_str(),FindExInfoBasic,&cursor->data,FindExSearchNameMatch,nullptr,FIND_FIRST_EX_LARGE_FETCH);
    if(cursor->search==INVALID_HANDLE_VALUE){
        code=GetLastError();
        if(code!=ERROR_FILE_NOT_FOUND){delete cursor;return code;}
        cursor->nextError=ERROR_NO_MORE_FILES;
    }
    *result=cursor;return 0;
}
int shou_win_directory_next(shou_win_directory *cursor,char **name){
    if(!cursor || !name)return ERROR_INVALID_PARAMETER;
    *name=nullptr;
    if(cursor->nextError)return cursor->nextError;
    while(true){
        if(cursor->first)cursor->first=false;
        else if(!FindNextFileW(cursor->search,&cursor->data)){cursor->nextError=GetLastError();return cursor->nextError;}
        const std::wstring value=cursor->data.cFileName;
        if(value==L"." || value==L"..")continue;
        *name=utf8(value);return *name?0:ERROR_NO_UNICODE_TRANSLATION;
    }
}
int shou_win_directory_verify(shou_win_directory *cursor,const shou_win_info *saved){
    if(!cursor || !saved)return ERROR_INVALID_PARAMETER;
    shou_win_info current{};const auto code=info(cursor->directory,&current);
    return code?code:same(current,*saved)?0:ERROR_FILE_INVALID;
}
int shou_win_normalize(const char *input,char **result){*result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;if((code=canonicalSpelling(path)))return code;std::replace(path.begin(),path.end(),L'\\',L'/');*result=utf8(path);return *result?0:ERROR_NOT_ENOUGH_MEMORY;}
int shou_win_stat(const char *input,shou_win_info *out){std::wstring path;auto code=normalized(input,path);if(code)return code;Handles pins;HANDLE h;if((code=open(path,pins,h)))return code;return info(h,out);}
int shou_win_list(const char *input,size_t limit,char **result){
    *result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;Handles pins;HANDLE directory;
    if((code=open(path,pins,directory)))return code;
    WIN32_FIND_DATAW data{};HANDLE search=FindFirstFileExW((extended(path)+L"\\*").c_str(),FindExInfoBasic,&data,FindExSearchNameMatch,nullptr,FIND_FIRST_EX_LARGE_FETCH);
    if(search==INVALID_HANDLE_VALUE){code=GetLastError();if(code==ERROR_FILE_NOT_FOUND){*result=utf8(L"");return 0;}return code;}
    std::wstring names;size_t count=0;
    do{if(!wcscmp(data.cFileName,L".")||!wcscmp(data.cFileName,L".."))continue;
       for(auto c:std::wstring(data.cFileName))if(c<32){code=ERROR_INVALID_NAME;break;}
       if(code)break;
       if(++count>limit || names.size()>8*1024*1024){code=ERROR_MORE_DATA;break;}names+=data.cFileName;names+=L'\n';
    }while(FindNextFileW(search,&data));
    if(!code && GetLastError()!=ERROR_NO_MORE_FILES)code=GetLastError();FindClose(search);
    if(code)return code;*result=utf8(names);return *result?0:ERROR_NOT_ENOUGH_MEMORY;
}
int shou_win_list_bounded(const char *input,size_t limit,uint32_t milliseconds,char **result,int *truncated,shou_win_cancelled cancelled){
    if(!result || !truncated || !limit || limit>1000000 || !milliseconds || milliseconds>600000)return ERROR_INVALID_PARAMETER;
    *result=nullptr;*truncated=0;std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE directory;if((code=open(path,pins,directory)))return code;
    WIN32_FIND_DATAW data{};HANDLE search=FindFirstFileExW((extended(path)+L"\\*").c_str(),FindExInfoBasic,&data,FindExSearchNameMatch,nullptr,FIND_FIRST_EX_LARGE_FETCH);
    if(search==INVALID_HANDLE_VALUE){code=GetLastError();if(code==ERROR_FILE_NOT_FOUND){*result=utf8(L"");return *result?0:ERROR_NOT_ENOUGH_MEMORY;}return code;}
    std::wstring names;size_t count=0;ULONGLONG deadline=GetTickCount64()+milliseconds;
    do {
        if(cancelled && cancelled()){code=ERROR_CANCELLED;break;}
        if(!wcscmp(data.cFileName,L".") || !wcscmp(data.cFileName,L".."))continue;
        if(count>=limit || GetTickCount64()>=deadline || names.size()+wcslen(data.cFileName)+1>8*1024*1024){*truncated=1;break;}
        for(auto ch:std::wstring(data.cFileName))if(ch<32){code=ERROR_INVALID_NAME;break;}
        if(code)break;
        names+=data.cFileName;names+=L'\n';++count;
    }while(FindNextFileW(search,&data));
    if(!code && !*truncated && GetLastError()!=ERROR_NO_MORE_FILES)code=GetLastError();FindClose(search);
    if(code)return code;*result=utf8(names);return *result?0:ERROR_NOT_ENOUGH_MEMORY;
}
int shou_win_read(const char *input,size_t limit,void **bytes,size_t *count){
    *bytes=nullptr;*count=0;std::wstring path;auto code=normalized(input,path);if(code)return code;Handles pins;HANDLE h;
    if((code=open(path,pins,h,GENERIC_READ|READ_CONTROL,FILE_SHARE_READ)))return code;
    shou_win_info before{},after{};if((code=info(h,&before)))return code;
    if(before.kind!=1 || before.logical_bytes<0 || static_cast<uint64_t>(before.logical_bytes)>limit)return ERROR_FILE_TOO_LARGE;
    auto data=malloc(static_cast<size_t>(before.logical_bytes)+1);if(!data)return ERROR_NOT_ENOUGH_MEMORY;
    size_t total=0;while(total<static_cast<size_t>(before.logical_bytes)){DWORD n=0;if(!ReadFile(h,static_cast<char *>(data)+total,static_cast<DWORD>(std::min<size_t>(65536,static_cast<size_t>(before.logical_bytes)-total)),&n,nullptr)||!n){code=ERROR_READ_FAULT;break;}total+=n;}
    if(!code)code=info(h,&after);if(!code&&!same(before,after))code=ERROR_FILE_INVALID;
    if(code){free(data);return code;}*bytes=data;*count=total;return 0;
}
int shou_win_preview_read(const char *input,const shou_win_info *saved,size_t limit,void **bytes,size_t *count){
    *bytes=nullptr;*count=0;
    if(!saved || !limit || limit>4194304 || saved->kind!=1)return ERROR_INVALID_PARAMETER;
    std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE h;if((code=open(path,pins,h,GENERIC_READ|READ_CONTROL,FILE_SHARE_READ)))return code;
    shou_win_info before{},after{};if((code=info(h,&before)))return code;
    if(before.kind!=1 || before.logical_bytes<0 || !same(before,*saved))return ERROR_FILE_INVALID;
    const auto wanted=static_cast<size_t>(std::min<uint64_t>(static_cast<uint64_t>(before.logical_bytes),limit));
    auto data=malloc(wanted+1);if(!data)return ERROR_NOT_ENOUGH_MEMORY;
    const auto deadline=GetTickCount64()+10000;
    size_t total=0;
    while(total<wanted){
        if(GetTickCount64()>=deadline){code=ERROR_TIMEOUT;break;}
        DWORD n=0;
        if(!ReadFile(h,static_cast<char *>(data)+total,static_cast<DWORD>(std::min<size_t>(65536,wanted-total)),&n,nullptr)||!n){code=ERROR_READ_FAULT;break;}
        total+=n;
    }
    if(!code)code=info(h,&after);
    if(!code&&!same(before,after))code=ERROR_FILE_INVALID;
    if(code){free(data);return code;}
    *bytes=data;*count=total;return 0;
}
int shou_win_private_directory(const char *input){std::wstring path;auto code=normalized(input,path);return code?code:private_acl(path,true);}
int shou_win_create_private_catalog(const char *input){
    std::wstring path;auto code=normalized(input,path);if(code)return code;
    const auto parentPath=path.substr(0,path.find_last_of(L'\\'));
    if((code=private_acl(parentPath,false)))return code;
    Handles pins;HANDLE parent;if((code=open(parentPath,pins,parent)))return code;
    PSECURITY_DESCRIPTOR descriptor=nullptr;if((code=private_descriptor(user_sid(),descriptor)))return code;
    SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
    // SQLite inherits the token's default owner when it creates the database.
    // Elevated Windows accounts can default to Administrators instead of their
    // user SID. Create the new empty database with explicit private ownership;
    // an existing object is never truncated, adopted or repaired here.
    HANDLE file=CreateFileW(extended(path).c_str(),GENERIC_READ|GENERIC_WRITE|READ_CONTROL,FILE_SHARE_READ|FILE_SHARE_WRITE,&attributes,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    code=file==INVALID_HANDLE_VALUE?GetLastError():0;LocalFree(descriptor);if(code)return code;
    pins.values.push_back(file);shou_win_info current{};
    if((code=info(file,&current)))return code;
    if(current.kind!=1 || !current.current_user || current.links!=1 || current.logical_bytes!=0)return ERROR_ACCESS_DENIED;
    return private_acl(path,false);
}
int shou_win_remove_record(const char *input){
    std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE handle;
    if((code=open(path,pins,handle,FILE_READ_ATTRIBUTES|READ_CONTROL|DELETE,FILE_SHARE_READ)))return code==ERROR_FILE_NOT_FOUND?0:code;
    shou_win_info current{};if((code=info(handle,&current)))return code;
    if(current.kind!=1 || !current.current_user || current.links!=1)return ERROR_ACCESS_DENIED;
    FILE_DISPOSITION_INFO disposition{TRUE};
    return SetFileInformationByHandle(handle,FileDispositionInfo,&disposition,sizeof(disposition))?0:GetLastError();
}
struct shou_win_lock{HANDLE handle;OVERLAPPED range;};
int shou_win_lock_acquire(const char *input,shou_win_lock **result){
    *result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE parent;auto p=path.substr(0,path.find_last_of(L'\\'));if((code=open(p,pins,parent)))return code;
    PSECURITY_DESCRIPTOR descriptor=nullptr;if((code=private_descriptor(user_sid(),descriptor)))return code;
    SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
    HANDLE h=CreateFileW(extended(path).c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&attributes,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    code=GetLastError();LocalFree(descriptor);
    if(h==INVALID_HANDLE_VALUE)return code;shou_win_info current{};code=info(h,&current);
    if(code||current.kind!=1||!current.current_user||(current.attributes&FILE_ATTRIBUTE_REPARSE_POINT)){CloseHandle(h);return code?code:ERROR_ACCESS_DENIED;}
    auto lock=new shou_win_lock{h,{}};
    if(!LockFileEx(h,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&lock->range)){code=GetLastError();CloseHandle(h);delete lock;return code;}
    *result=lock;return 0;
}
void shou_win_lock_release(shou_win_lock *lock){if(lock){UnlockFileEx(lock->handle,0,1,0,&lock->range);CloseHandle(lock->handle);delete lock;}}
int shou_win_write(const char *input,const void *bytes,size_t count){
    std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE parent;auto p=path.substr(0,path.find_last_of(L'\\'));if((code=open(p,pins,parent)))return code;
    GUID id;if(FAILED(CoCreateGuid(&id)))return ERROR_GEN_FAILURE;wchar_t name[40];if(!StringFromGUID2(id,name,40))return ERROR_GEN_FAILURE;auto temp=extended(p+L"\\.pending-"+name);
    PSECURITY_DESCRIPTOR descriptor=nullptr;if((code=private_descriptor(user_sid(),descriptor)))return code;
    SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
    HANDLE h=CreateFileW(temp.c_str(),GENERIC_WRITE,0,&attributes,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr);
    code=h==INVALID_HANDLE_VALUE?GetLastError():0;LocalFree(descriptor);if(code)return code;
    size_t offset=0;while(offset<count){DWORD n=0;if(!WriteFile(h,static_cast<const char *>(bytes)+offset,static_cast<DWORD>(std::min<size_t>(count-offset,65536)),&n,nullptr)||!n){code=ERROR_WRITE_FAULT;break;}offset+=n;}
    if(!code&&!FlushFileBuffers(h))code=GetLastError();CloseHandle(h);
    if(!code&&!MoveFileExW(temp.c_str(),extended(path).c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))code=GetLastError();
    if(code)DeleteFileW(temp.c_str());return code;
}
int shou_win_recycle(const char *path,const shou_win_info *saved,char **result){return shell_move(path,nullptr,saved,result);}
int shou_win_restore(const char *path,const char *target,const shou_win_info *saved,char **result){return shell_move(path,target,saved,result);}
int shou_win_purge(const char *input,const char *const *relative,const char *const *digests,const shou_win_info *saved,size_t count,shou_win_cancelled cancelled,size_t *removed){
    *removed=0;
    if(!count || count>1000000 || !relative || !digests || !saved)return ERROR_INVALID_PARAMETER;
    std::wstring root;DWORD code=normalized(input,root);if(code)return code;
    if(root.size()<=3)return ERROR_ACCESS_DENIED;
    Handles ancestors,objects;HANDLE parent;
    auto parentPath=root.substr(0,root.find_last_of(L'\\'));if(parentPath.size()==2)parentPath+=L'\\';
    if((code=open(parentPath,ancestors,parent)))return code;
    std::vector<std::wstring> paths;
    std::vector<shou_win_info> baseline(saved,saved+count);
    std::map<std::wstring,size_t> indices;
    Handles recycleRecord;HANDLE metadata=INVALID_HANDLE_VALUE;shou_win_info metadataBaseline{};
    // A recorded $R item has one paired $I metadata file in the same SID
    // directory. Pin that exact regular file too; never empty the whole Bin.
    auto nameAt=root.find_last_of(L'\\');auto binParent=root.substr(0,nameAt);
    auto sidAt=binParent.find_last_of(L'\\');auto bin=binParent.substr(0,sidAt);
    auto binName=bin.size()>3?bin.substr(3):L"";for(auto &c:binName)c=towlower(c);
    if(binName==L"$recycle.bin" && root.substr(nameAt+1,2)==L"$R"){
        auto sid=wide(saved[0].owner_sid);
        if(binParent.substr(sidAt+1)!=sid)return ERROR_ACCESS_DENIED;
        auto record=root;record[nameAt+2]=L'I';
        if((code=open(record,recycleRecord,metadata,GENERIC_READ|DELETE|READ_CONTROL,FILE_SHARE_READ)))return code;
        shou_win_info value{};if((code=info(metadata,&value)))return code;
        if(value.kind!=1 || !value.current_user || value.links!=1 || value.volume!=saved[0].volume || strcmp(value.owner_sid,saved[0].owner_sid) || value.logical_bytes<28 || value.logical_bytes>64028)return ERROR_INVALID_DATA;
        uint64_t header[4]{};DWORD bytes=0;
        if(!ReadFile(metadata,header,28,&bytes,nullptr))return GetLastError();
        if(bytes!=28 || !((header[0]==1 && value.logical_bytes==544) ||
            (header[0]==2 && static_cast<uint32_t>(header[3])>0 && static_cast<uint32_t>(header[3])<=32000 && value.logical_bytes==28+2LL*static_cast<uint32_t>(header[3]))))return ERROR_INVALID_DATA;
        metadataBaseline=value;
    }
    // Pin every reviewed object before the first mutation. Deny write/delete
    // sharing; temporary ancestor handles allow our own DELETE handles.
    for(size_t i=0;i<count;++i){
        if(cancelled && cancelled())return ERROR_CANCELLED;
        auto name=wide(relative[i]);std::wstring path;
        if(name==L".")path=root;
        else{
            if(name.empty() || name.front()==L'/' || name.front()==L'\\' || name.find(L'\\')!=std::wstring::npos)return ERROR_INVALID_NAME;
            auto full=root+L"\\"+name;auto bytes=utf8(full);if(!bytes)return ERROR_NOT_ENOUGH_MEMORY;
            code=normalized(bytes,path);free(bytes);if(code)return code;
        }
        auto key=path;for(auto &c:key)c=towlower(c);
        if(!indices.emplace(key,i).second)return ERROR_INVALID_PARAMETER;
        Handles pins;HANDLE h;
        if((code=open(path,pins,h,GENERIC_READ|DELETE|FILE_READ_ATTRIBUTES|READ_CONTROL,FILE_SHARE_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE)))return code;
        shou_win_info current{};if((code=info(h,&current)))return code;
        if(!current.current_user || current.volume!=saved[0].volume || (current.kind==1 && current.links!=1) || !same(current,saved[i]) || !digest(h,digests[i]))return ERROR_FILE_INVALID;
        pins.values.pop_back();objects.values.push_back(h);paths.push_back(path);
    }
    auto rootKey=root;for(auto &c:rootKey)c=towlower(c);
    auto rootIndex=indices.find(rootKey);if(rootIndex==indices.end())return ERROR_INVALID_PARAMETER;
    std::vector<size_t> parents(count,count),order(count);std::iota(order.begin(),order.end(),0);
    for(size_t i=0;i<count;++i){
        if(i==rootIndex->second)continue;
        auto key=paths[i].substr(0,paths[i].find_last_of(L'\\'));for(auto &c:key)c=towlower(c);
        auto found=indices.find(key);
        if(found==indices.end() || saved[found->second].kind!=2)return ERROR_INVALID_PARAMETER;
        parents[i]=found->second;
    }
    // Check the entire pinned manifest again before deleting any member.
    for(size_t i=0;i<count;++i){
        shou_win_info current{};if((code=info(objects.values[i],&current)))return code;
        if(!same(current,baseline[i]) || !digest(objects.values[i],digests[i]))return ERROR_FILE_INVALID;
    }
    std::sort(order.begin(),order.end(),[&](size_t a,size_t b){return paths[a].size()>paths[b].size();});
    for(auto i:order){
        if(cancelled && cancelled())return ERROR_CANCELLED;
        shou_win_info current{};if((code=info(objects.values[i],&current)))return code;
        if(!same(current,baseline[i]) || !digest(objects.values[i],digests[i]))return ERROR_FILE_INVALID;
        auto p=parents[i];
        if(p<count){
            if((code=info(objects.values[p],&current)))return code;
            if(!same(current,baseline[p]))return ERROR_FILE_INVALID;
        }
        // This disposition never recurses: unreviewed children keep a directory
        // nonempty and stop removal. The handle binds deletion to the File ID.
        FILE_DISPOSITION_INFO disposition{TRUE};
        if(!SetFileInformationByHandle(objects.values[i],FileDispositionInfo,&disposition,sizeof(disposition)))return GetLastError();
        ++*removed;
        HANDLE deleted=objects.values[i];objects.values[i]=INVALID_HANDLE_VALUE;
        if(!CloseHandle(deleted))return GetLastError();
        if(p<count){
            if((code=info(objects.values[p],&current)))return code;
            if(!same(current,baseline[p],true))return ERROR_FILE_INVALID;
            // Only the direct parent of our just-removed member gets a new
            // timestamp/size baseline. Other directories remain fully checked.
            baseline[p]=current;
        }
    }
    if(metadata!=INVALID_HANDLE_VALUE){
        shou_win_info current{};if((code=info(metadata,&current)))return code;
        if(!same(current,metadataBaseline))return ERROR_FILE_INVALID;
        FILE_DISPOSITION_INFO disposition{TRUE};
        if(!SetFileInformationByHandle(metadata,FileDispositionInfo,&disposition,sizeof(disposition)))return GetLastError();
        ++*removed;
    }
    return 0;
}
int shou_win_available(const char *input,uint64_t *result){std::wstring path;auto code=normalized(input,path);if(code)return code;ULARGE_INTEGER bytes;if(!GetDiskFreeSpaceExW(path.c_str(),&bytes,nullptr,nullptr))return GetLastError();*result=bytes.QuadPart;return 0;}
int shou_win_stdin(void *buffer,uint32_t capacity,uint32_t *count){
    DWORD read=0;BOOL ok=ReadFile(GetStdHandle(STD_INPUT_HANDLE),buffer,capacity,&read,nullptr);
    *count=read;DWORD code=ok?0:GetLastError();return code==ERROR_BROKEN_PIPE?0:code;
}
int shou_win_console_confirm(const char *review,const char *prompt,const char *phrase){
    HANDLE input=CreateFileW(L"CONIN$",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,0,nullptr);
    HANDLE output=CreateFileW(L"CONOUT$",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,0,nullptr);
    DWORD mode=0,n=0;if(input==INVALID_HANDLE_VALUE||output==INVALID_HANDLE_VALUE||!GetConsoleMode(input,&mode)){if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);if(output!=INVALID_HANDLE_VALUE)CloseHandle(output);return ERROR_INVALID_HANDLE;}
    auto text=wide(review)+wide(prompt);WriteConsoleW(output,text.c_str(),static_cast<DWORD>(text.size()),&n,nullptr);
    wchar_t buffer[256]{};BOOL ok=ReadConsoleW(input,buffer,255,&n,nullptr);CloseHandle(input);CloseHandle(output);
    std::wstring answer(buffer,n);while(!answer.empty()&&(answer.back()==L'\r'||answer.back()==L'\n'))answer.pop_back();return ok&&answer==wide(phrase)?0:ERROR_CANCELLED;
}
}
