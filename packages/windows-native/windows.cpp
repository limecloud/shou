#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;

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
        auto base=part.substr(0,part.find(L'.')); for(auto &c:base)c=towupper(c);
        if (base==L"CON" || base==L"PRN" || base==L"AUX" || base==L"NUL" ||
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
struct Handles {
    std::vector<HANDLE> values;
    ~Handles(){for(auto h:values)CloseHandle(h);}
};
// Pin ancestors against rename while opening an object. Never follow a reparse point.
DWORD open(const std::wstring &path, Handles &pins, HANDLE &last, DWORD access=FILE_READ_ATTRIBUTES|READ_CONTROL, DWORD share=FILE_SHARE_READ|FILE_SHARE_WRITE) {
    size_t end=3;
    while (true) {
        auto part=extended(path.substr(0,end));
        bool final=end==path.size();
        HANDLE h=CreateFileW(part.c_str(),final?access:FILE_READ_ATTRIBUTES, final?share:FILE_SHARE_READ|FILE_SHARE_WRITE,
            nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
        if(h==INVALID_HANDLE_VALUE)return GetLastError();
        pins.values.push_back(h);
        FILE_ATTRIBUTE_TAG_INFO tag{};
        if(!GetFileInformationByHandleEx(h,FileAttributeTagInfo,&tag,sizeof(tag)))return GetLastError();
        if(tag.FileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE|0x00040000|0x00400000))return ERROR_REPARSE_TAG_INVALID;
        if(tag.FileAttributes&FILE_ATTRIBUTE_DIRECTORY){
            FILE_CASE_SENSITIVE_INFO sensitive{};
            if(!GetFileInformationByHandleEx(h,FileCaseSensitiveInfo,&sensitive,sizeof(sensitive)))return GetLastError();
            if(sensitive.Flags&FILE_CS_FLAG_CASE_SENSITIVE_DIR)return ERROR_NOT_SUPPORTED;
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
    out->modified_ns=(basic.LastWriteTime.QuadPart-epoch)*100;
    out->changed_ns=(basic.ChangeTime.QuadPart-epoch)*100;return 0;
}
bool same(const shou_win_info &a,const shou_win_info &b,bool directoryMutation=false) {
    return a.volume==b.volume && !memcmp(a.file_id,b.file_id,16) && !strcmp(a.owner_sid,b.owner_sid) &&
        a.kind==b.kind && a.links==b.links && (directoryMutation ||
        (a.logical_bytes==b.logical_bytes && a.modified_ns==b.modified_ns && a.changed_ns==b.changed_ns));
}
DWORD expected(const std::wstring &path,const shou_win_info *saved) {
    Handles handles;HANDLE h;DWORD code=open(path,handles,h);if(code)return code;
    shou_win_info current{};if((code=info(h,&current)))return code;
    return same(current,*saved)?0:ERROR_FILE_INVALID;
}
DWORD private_acl(const std::wstring &path,bool create) {
    Handles parentPins;HANDLE parent;
    auto parentPath=path.substr(0,path.find_last_of(L'\\'));if(parentPath.size()==2)parentPath+=L'\\';
    DWORD parentCode=open(parentPath,parentPins,parent);if(parentCode)return parentCode;
    auto user=user_sid();if(user.empty())return ERROR_INVALID_SID;
    LPWSTR sid=nullptr;if(!ConvertSidToStringSidW(user.data(),&sid))return GetLastError();
    std::wstring sddl=L"O:"+std::wstring(sid)+L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+std::wstring(sid)+L")";LocalFree(sid);
    PSECURITY_DESCRIPTOR descriptor=nullptr;
    if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&descriptor,nullptr))return GetLastError();
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

extern "C" {
void shou_win_free(void *value){free(value);}
int shou_win_normalize(const char *input,char **result){*result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;std::replace(path.begin(),path.end(),L'\\',L'/');*result=utf8(path);return *result?0:ERROR_NOT_ENOUGH_MEMORY;}
int shou_win_stat(const char *input,shou_win_info *out){std::wstring path;auto code=normalized(input,path);if(code)return code;Handles pins;HANDLE h;if((code=open(path,pins,h)))return code;return info(h,out);}
int shou_win_list(const char *input,size_t limit,char **result){
    *result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;Handles pins;HANDLE directory;
    if((code=open(path,pins,directory)))return code;
    WIN32_FIND_DATAW data{};HANDLE search=FindFirstFileExW((extended(path)+L"\\*").c_str(),FindExInfoBasic,&data,FindExSearchNameMatch,nullptr,FIND_FIRST_EX_LARGE_FETCH);
    if(search==INVALID_HANDLE_VALUE){code=GetLastError();if(code==ERROR_FILE_NOT_FOUND){*result=utf8(L"");return 0;}return code;}
    std::wstring names;size_t count=0;
    do{if(!wcscmp(data.cFileName,L".")||!wcscmp(data.cFileName,L".."))continue;
       if(++count>limit || names.size()>8*1024*1024){code=ERROR_MORE_DATA;break;}names+=data.cFileName;names+=L'\n';
    }while(FindNextFileW(search,&data));
    if(!code && GetLastError()!=ERROR_NO_MORE_FILES)code=GetLastError();FindClose(search);
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
int shou_win_private_directory(const char *input){std::wstring path;auto code=normalized(input,path);return code?code:private_acl(path,true);}
struct shou_win_lock{HANDLE handle;OVERLAPPED range;};
int shou_win_lock_acquire(const char *input,shou_win_lock **result){
    *result=nullptr;std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE parent;auto p=path.substr(0,path.find_last_of(L'\\'));if((code=open(p,pins,parent)))return code;
    HANDLE h=CreateFileW(extended(path).c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    if(h==INVALID_HANDLE_VALUE)return GetLastError();shou_win_info current{};code=info(h,&current);
    if(code||current.kind!=1||!current.current_user||(current.attributes&FILE_ATTRIBUTE_REPARSE_POINT)){CloseHandle(h);return code?code:ERROR_ACCESS_DENIED;}
    auto lock=new shou_win_lock{h,{}};
    if(!LockFileEx(h,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&lock->range)){code=GetLastError();CloseHandle(h);delete lock;return code;}
    *result=lock;return 0;
}
void shou_win_lock_release(shou_win_lock *lock){if(lock){UnlockFileEx(lock->handle,0,1,0,&lock->range);CloseHandle(lock->handle);delete lock;}}
int shou_win_write(const char *input,const void *bytes,size_t count){
    std::wstring path;auto code=normalized(input,path);if(code)return code;
    Handles pins;HANDLE parent;auto p=path.substr(0,path.find_last_of(L'\\'));if((code=open(p,pins,parent)))return code;
    GUID id;CoCreateGuid(&id);wchar_t name[40];StringFromGUID2(id,name,40);auto temp=extended(p+L"\\.pending-"+name);
    HANDLE h=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr);if(h==INVALID_HANDLE_VALUE)return GetLastError();
    size_t offset=0;while(offset<count){DWORD n=0;if(!WriteFile(h,static_cast<const char *>(bytes)+offset,static_cast<DWORD>(std::min<size_t>(count-offset,65536)),&n,nullptr)||!n){code=ERROR_WRITE_FAULT;break;}offset+=n;}
    if(!code&&!FlushFileBuffers(h))code=GetLastError();CloseHandle(h);
    if(!code&&!MoveFileExW(temp.c_str(),extended(path).c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))code=GetLastError();
    if(code)DeleteFileW(temp.c_str());return code;
}
int shou_win_recycle(const char *path,const shou_win_info *saved,char **result){return shell_move(path,nullptr,saved,result);}
int shou_win_restore(const char *path,const char *target,const shou_win_info *saved,char **result){return shell_move(path,target,saved,result);}
int shou_win_remove(const char *input,const shou_win_info *saved){
    std::wstring path;auto code=normalized(input,path);if(code)return code;Handles pins;HANDLE h;
    if((code=open(path,pins,h,DELETE|FILE_READ_ATTRIBUTES|READ_CONTROL,FILE_SHARE_READ)))return code;
    shou_win_info current{};if((code=info(h,&current)))return code;
    if(!same(current,*saved,current.kind==2))return ERROR_FILE_INVALID;
    FILE_DISPOSITION_INFO disposition{TRUE};return SetFileInformationByHandle(h,FileDispositionInfo,&disposition,sizeof(disposition))?0:GetLastError();
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
