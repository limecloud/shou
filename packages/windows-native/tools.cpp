#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
struct Handle {
    HANDLE value=nullptr;
    explicit Handle(HANDLE handle=nullptr):value(handle){}
    Handle(const Handle &)=delete;
    Handle &operator=(const Handle &)=delete;
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
};
std::wstring wide(const char *value){
    if(!value)return {};
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,nullptr,0);if(!count || count>32768)return {};
    std::wstring result(count,0);if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,result.data(),count))return {};
    result.pop_back();return result;
}
std::string utf8(const std::wstring &value){
    int count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,nullptr,0,nullptr,nullptr);if(!count)return {};
    std::string result(count,0);if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,result.data(),count,nullptr,nullptr))return {};
    result.pop_back();return result;
}
std::wstring quote(const std::wstring &value){
    std::wstring result=L"\"";size_t slashes=0;
    for(auto ch:value){if(ch==L'\\'){++slashes;continue;}result.append(ch==L'"'?slashes*2+1:slashes,L'\\');result+=ch;slashes=0;}
    result.append(slashes*2,L'\\');return result+L'"';
}
std::wstring folder(REFKNOWNFOLDERID id){PWSTR raw=nullptr;if(FAILED(SHGetKnownFolderPath(id,0,nullptr,&raw)))return {};std::wstring result=raw;CoTaskMemFree(raw);return result;}
DWORD canonical(const char *input,std::wstring &result){
    char *raw=nullptr;auto code=shou_win_normalize(input,&raw);
    if(!code){result=wide(raw);std::replace(result.begin(),result.end(),L'/',L'\\');}shou_win_free(raw);return code;
}
bool same(const shou_win_info &a,const shou_win_info &b){
    return a.volume==b.volume && !memcmp(a.file_id,b.file_id,sizeof(a.file_id)) && !strcmp(a.owner_sid,b.owner_sid) &&
        a.logical_bytes==b.logical_bytes && a.allocated_bytes==b.allocated_bytes && a.modified_ns==b.modified_ns && a.changed_ns==b.changed_ns &&
        a.kind==b.kind && a.links==b.links && a.attributes==b.attributes;
}
DWORD safeACL(HANDLE handle,bool directory){
    Handle token;if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token.value))return GetLastError();
    DWORD count=0;GetTokenInformation(token.value,TokenUser,nullptr,0,&count);if(!count || count>65536)return ERROR_INVALID_DATA;
    std::vector<BYTE> bytes(count);if(!GetTokenInformation(token.value,TokenUser,bytes.data(),count,&count))return GetLastError();
    auto user=reinterpret_cast<TOKEN_USER *>(bytes.data())->User.Sid;
    PSID owner=nullptr;PACL acl=nullptr;PSECURITY_DESCRIPTOR security=nullptr;
    auto code=GetSecurityInfo(handle,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&owner,nullptr,&acl,nullptr,&security);
    if(code)return code;
    struct Security{PSECURITY_DESCRIPTOR value;~Security(){LocalFree(value);}} release{security};
    PSID installer=nullptr;
    if(!ConvertStringSidToSidW(L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",&installer))return GetLastError();
    struct Sid{PSID value;~Sid(){LocalFree(value);}} installed{installer};
    auto trusted=[&](PSID sid){return sid && (EqualSid(sid,user) || EqualSid(sid,installer) || IsWellKnownSid(sid,WinLocalSystemSid) || IsWellKnownSid(sid,WinBuiltinAdministratorsSid));};
    if(!acl || !trusted(owner))return ERROR_ACCESS_DENIED;
    const DWORD writes=GENERIC_ALL|GENERIC_WRITE|DELETE|WRITE_DAC|WRITE_OWNER|FILE_WRITE_DATA|FILE_WRITE_ATTRIBUTES|FILE_WRITE_EA|FILE_DELETE_CHILD|(directory?0:FILE_APPEND_DATA);
    for(DWORD index=0;index<acl->AceCount;index++){
        void *raw=nullptr;if(!GetAce(acl,index,&raw))return GetLastError();auto header=static_cast<ACE_HEADER *>(raw);
        if(header->AceFlags & INHERIT_ONLY_ACE)continue;
        if(header->AceType==ACCESS_ALLOWED_ACE_TYPE){auto ace=static_cast<ACCESS_ALLOWED_ACE *>(raw);if((ace->Mask&writes) && !trusted(&ace->SidStart))return ERROR_ACCESS_DENIED;}
        else if(header->AceType!=ACCESS_DENIED_ACE_TYPE)return ERROR_ACCESS_DENIED;
    }
    return 0;
}
// Pin every ancestor without delete sharing, then the executable without
// write/delete sharing. CreateProcess cannot race a reviewed image replacement.
DWORD pin(const std::wstring &path,std::vector<std::unique_ptr<Handle>> &pins,shou_win_info &identity,bool requireSingleLink=true){
    for(size_t end=3;;){
        const bool image=end==path.size();auto current=path.substr(0,end);
        const auto opaque=FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE|FILE_ATTRIBUTE_RECALL_ON_OPEN|FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;
        auto attributes=GetFileAttributesW(current.c_str());if(attributes==INVALID_FILE_ATTRIBUTES)return GetLastError();if(attributes&opaque)return ERROR_ACCESS_DENIED;
        auto handle=std::make_unique<Handle>(CreateFileW(current.c_str(),FILE_READ_ATTRIBUTES|READ_CONTROL|(image?FILE_READ_DATA:0),
            FILE_SHARE_READ|(image?0:FILE_SHARE_WRITE),nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,nullptr));
        if(handle->value==INVALID_HANDLE_VALUE)return GetLastError();
        FILE_ATTRIBUTE_TAG_INFO tag{};if(!GetFileInformationByHandleEx(handle->value,FileAttributeTagInfo,&tag,sizeof(tag)))return GetLastError();
        if((tag.FileAttributes & opaque) ||
           bool(tag.FileAttributes&FILE_ATTRIBUTE_DIRECTORY)==image)return ERROR_ACCESS_DENIED;
        auto code=safeACL(handle->value,!image);if(code)return code;
        pins.push_back(std::move(handle));if(image)break;
        auto next=path.find(L'\\',end+1);end=next==std::wstring::npos?path.size():next;
    }
    auto text=utf8(path);auto code=shou_win_stat(text.c_str(),&identity);if(code)return code;
    return identity.kind==1 && identity.links>=1 && (!requireSingleLink || identity.links==1)?0:ERROR_ACCESS_DENIED;
}
DWORD locate(const char *inputHome,const std::string &tool,std::wstring &home,std::wstring &path){
    auto code=canonical(inputHome,home);if(code)return code;
    std::vector<std::wstring> candidates;
    if(tool=="rustup")candidates.push_back(home+L"\\.cargo\\bin\\rustup.exe");
    else if(tool=="docker"){auto programs=folder(FOLDERID_ProgramFiles);if(!programs.empty())candidates.push_back(programs+L"\\Docker\\Docker\\resources\\bin\\docker.exe");}
    else if(tool=="conda"){
        for(auto name:{L"miniforge3",L"miniconda3",L"anaconda3"})candidates.push_back(home+L"\\"+name+L"\\Scripts\\conda.exe");
        auto shared=folder(FOLDERID_ProgramData);if(!shared.empty())for(auto name:{L"miniforge3",L"miniconda3",L"anaconda3"})candidates.push_back(shared+L"\\"+name+L"\\Scripts\\conda.exe");
    }else return ERROR_NOT_SUPPORTED;
    for(const auto &candidate:candidates){
        auto attributes=GetFileAttributesW(candidate.c_str());
        if(attributes==INVALID_FILE_ATTRIBUTES){auto error=GetLastError();if(error==ERROR_FILE_NOT_FOUND || error==ERROR_PATH_NOT_FOUND)continue;return error;}
        auto text=utf8(candidate);return canonical(text.c_str(),path);
    }
    return ERROR_FILE_NOT_FOUND;
}
std::vector<wchar_t> environment(const std::wstring &home,const std::wstring &executable,const std::string &tool){
    wchar_t windows[32768];auto size=GetWindowsDirectoryW(windows,32768);if(!size || size>=32768)return {};
    const std::wstring system=std::wstring(windows)+L"\\System32";
    std::wstring path=system+L";"+windows;
    if(tool=="conda"){
        const auto scripts=executable.substr(0,executable.find_last_of(L'\\'));const auto prefix=scripts.substr(0,scripts.find_last_of(L'\\'));
        path=prefix+L";"+scripts+L";"+prefix+L"\\Library\\bin;"+path;
    }
    std::vector<std::wstring> values={L"SystemRoot="+std::wstring(windows),L"WINDIR="+std::wstring(windows),L"PATH="+path,L"USERPROFILE="+home,
        L"HOMEDRIVE="+home.substr(0,2),L"HOMEPATH="+home.substr(2),L"APPDATA="+home+L"\\AppData\\Roaming",L"LOCALAPPDATA="+home+L"\\AppData\\Local",
        L"TEMP="+home+L"\\AppData\\Local\\Temp",L"TMP="+home+L"\\AppData\\Local\\Temp",L"DOCKER_CONFIG="+home+L"\\.docker",
        L"RUSTUP_HOME="+home+L"\\.rustup",L"CARGO_HOME="+home+L"\\.cargo",L"RUSTUP_AUTO_INSTALL=0",L"PYTHONUTF8=1",L"PYTHONNOUSERSITE=1",L"CONDA_NO_PLUGINS=true",L"LC_ALL=C",L"NO_COLOR=1"};
    std::sort(values.begin(),values.end(),[](const auto &a,const auto &b){return _wcsicmp(a.c_str(),b.c_str())<0;});
    std::vector<wchar_t> result;for(const auto &value:values){result.insert(result.end(),value.begin(),value.end());result.push_back(0);}result.push_back(0);return result;
}
DWORD spawn(const std::wstring &path,const std::wstring &home,const std::string &tool,const std::vector<std::wstring> &args,DWORD milliseconds,shou_win_read_cancelled cancelled,void *context,std::string &output){
    SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};Handle read,write,errorRead,errorWrite,input;
    if(!CreatePipe(&read.value,&write.value,&security,0) || !CreatePipe(&errorRead.value,&errorWrite.value,&security,0))return GetLastError();
    if(!SetHandleInformation(read.value,HANDLE_FLAG_INHERIT,0) || !SetHandleInformation(errorRead.value,HANDLE_FLAG_INHERIT,0))return GetLastError();
    input.value=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,nullptr);if(input.value==INVALID_HANDLE_VALUE)return GetLastError();
    SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);std::vector<BYTE> attributes(bytes);
    auto list=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());if(!InitializeProcThreadAttributeList(list,1,0,&bytes))return GetLastError();
    struct Attributes{LPPROC_THREAD_ATTRIBUTE_LIST value;~Attributes(){DeleteProcThreadAttributeList(value);}} release{list};
    HANDLE inherited[]={write.value,errorWrite.value,input.value};if(!UpdateProcThreadAttribute(list,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,inherited,sizeof(inherited),nullptr,nullptr))return GetLastError();
    STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);startup.lpAttributeList=list;startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput=input.value;startup.StartupInfo.hStdOutput=write.value;startup.StartupInfo.hStdError=errorWrite.value;
    Handle job(CreateJobObjectW(nullptr,nullptr));if(!job.value)return GetLastError();
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if(!SetInformationJobObject(job.value,JobObjectExtendedLimitInformation,&limits,sizeof(limits)))return GetLastError();
    auto command=quote(path);for(const auto &arg:args)command+=L" "+quote(arg);
    auto env=environment(home,path,tool);if(env.empty())return ERROR_INVALID_DATA;
    if(cancelled && cancelled(context))return ERROR_CANCELLED;
    PROCESS_INFORMATION child{};
    if(!CreateProcessW(path.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_SUSPENDED|CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT,env.data(),home.c_str(),&startup.StartupInfo,&child))return GetLastError();
    Handle process(child.hProcess),thread(child.hThread);
    if(!AssignProcessToJobObject(job.value,process.value)){auto code=GetLastError();TerminateProcess(process.value,code);return code;}
    if(ResumeThread(thread.value)==DWORD(-1))return GetLastError();
    CloseHandle(write.value);write.value=nullptr;CloseHandle(errorWrite.value);errorWrite.value=nullptr;
    const auto deadline=GetTickCount64()+milliseconds;size_t diagnosticBytes=0;bool outputEnd=false,errorEnd=false;
    auto drain=[&](HANDLE pipe,bool capture,bool &ended)->DWORD{
        DWORD available=0;if(!PeekNamedPipe(pipe,nullptr,0,nullptr,&available,nullptr)){auto code=GetLastError();if(code==ERROR_BROKEN_PIPE){ended=true;return 0;}return code;}
        char buffer[65536];if(!available)return 0;DWORD count=0;
        if(!ReadFile(pipe,buffer,std::min<DWORD>(available,sizeof(buffer)),&count,nullptr))return GetLastError();
        if(capture)output.append(buffer,count);else diagnosticBytes+=count;
        return output.size()>4*1024*1024 || diagnosticBytes>1024*1024?ERROR_MORE_DATA:0;
    };
    while(true){
        if(cancelled && cancelled(context))return ERROR_CANCELLED;
        if(GetTickCount64()>=deadline)return ERROR_TIMEOUT;
        auto code=drain(read.value,true,outputEnd);if(code)return code;if((code=drain(errorRead.value,false,errorEnd)))return code;
        auto state=WaitForSingleObject(process.value,0);if(state==WAIT_FAILED)return GetLastError();
        if(state==WAIT_OBJECT_0 && outputEnd && errorEnd)break;
        Sleep(5);
    }
    DWORD exit=0;if(!GetExitCodeProcess(process.value,&exit))return GetLastError();return exit==0?0:ERROR_PROCESS_ABORTED;
}
}

struct shou_win_managed_image { std::vector<std::unique_ptr<Handle>> pins; };
extern "C" int shou_win_managed_image_acquire(const char *path,shou_win_info *identity,shou_win_managed_image **result){
    if(!path || !identity || !result)return ERROR_INVALID_PARAMETER;*result=nullptr;*identity={};
    std::wstring normalized;auto code=canonical(path,normalized);if(code)return code;
    auto image=std::make_unique<shou_win_managed_image>();
    // Windows system installers can be hard-linked into the component store.
    // These pins authorize only loading an image, never deleting any link;
    // write/delete sharing is denied on the file object for all its aliases.
    if((code=pin(normalized,image->pins,*identity,false)))return code;
    *result=image.release();return 0;
}
extern "C" void shou_win_managed_image_release(shou_win_managed_image *image){delete image;}

extern "C" int shou_win_cleanup_tool_info(const char *home,const char *tool,char **result,shou_win_info *identity){
    if(!home || !tool || !result || !identity)return ERROR_INVALID_PARAMETER;*result=nullptr;*identity={};
    std::wstring directory,path;auto code=locate(home,tool,directory,path);if(code)return code;
    std::vector<std::unique_ptr<Handle>> pins;if((code=pin(path,pins,*identity)))return code;
    auto text=utf8(path);*result=static_cast<char *>(malloc(text.size()+1));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;memcpy(*result,text.c_str(),text.size()+1);return 0;
}
extern "C" int shou_win_cleanup_tool_run(const char *home,uint32_t operation,const char *toolchain,const char *expectedPath,const shou_win_info *expected,uint32_t milliseconds,shou_win_read_cancelled cancelled,void *context,char **result){
    if(!home || !expectedPath || !expected || !result || milliseconds<1000 || milliseconds>300000 || !memchr(expected->owner_sid,0,sizeof(expected->owner_sid)))return ERROR_INVALID_PARAMETER;
    *result=nullptr;std::string tool;std::vector<std::wstring> args;
    switch(operation){
    case 1:tool="docker";args={L"context",L"inspect",L"default",L"--format",L"{{json .Endpoints.docker.Host}}"};break;
    case 2:tool="docker";args={L"--host",L"npipe:////./pipe/docker_engine",L"system",L"df",L"--format",L"{{json .}}"};break;
    case 3:tool="docker";args={L"--host",L"npipe:////./pipe/docker_engine",L"builder",L"prune",L"--all",L"--force"};break;
    case 4:tool="conda";args={L"clean",L"--all",L"--dry-run",L"--json"};break;
    case 5:tool="conda";args={L"clean",L"--all",L"--yes",L"--json"};break;
    case 6:tool="rustup";args={L"toolchain",L"list",L"--verbose"};break;
    case 7:tool="rustup";args={L"override",L"list"};break;
    case 8:tool="rustup";args={L"show",L"active-toolchain"};break;
    case 9:{
        tool="rustup";auto name=wide(toolchain);if(name.size()<2 || name.size()>161 || !isalnum(static_cast<unsigned char>(name[0])))return ERROR_INVALID_PARAMETER;
        for(auto ch:name)if(!((ch>=L'a' && ch<=L'z') || (ch>=L'A' && ch<=L'Z') || (ch>=L'0' && ch<=L'9') || ch==L'_' || ch==L'.' || ch==L'+' || ch==L'-'))return ERROR_INVALID_PARAMETER;
        args={L"toolchain",L"uninstall",name};break;
    }
    default:return ERROR_NOT_SUPPORTED;
    }
    std::wstring directory,path,reviewed;auto code=locate(home,tool,directory,path);if(code)return code;if((code=canonical(expectedPath,reviewed)))return code;
    if(path!=reviewed)return ERROR_FILE_INVALID;
    std::vector<std::unique_ptr<Handle>> pins;shou_win_info identity{};if((code=pin(path,pins,identity)))return code;if(!same(identity,*expected))return ERROR_FILE_INVALID;
    std::string output;if((code=spawn(path,directory,tool,args,milliseconds,cancelled,context,output)))return code;
    if(output.find('\0')!=std::string::npos)return ERROR_INVALID_DATA;
    shou_win_info after{};auto text=utf8(path);if((code=shou_win_stat(text.c_str(),&after)))return code;if(!same(identity,after))return ERROR_FILE_INVALID;
    *result=static_cast<char *>(malloc(output.size()+1));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;memcpy(*result,output.c_str(),output.size()+1);return 0;
}
