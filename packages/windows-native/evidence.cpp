#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <winternl.h>
#include <tlhelp32.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <map>
#include <string>
#include <vector>

namespace {
struct Handle {
    HANDLE value=nullptr;
    Handle()=default;
    explicit Handle(HANDLE h):value(h){}
    Handle(const Handle &)=delete;
    Handle &operator=(const Handle &)=delete;
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
};
std::wstring wide(const char *text) {
    if(!text)return {};
    int size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,nullptr,0);
    if(!size)return {};
    std::wstring result(size,0);
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,result.data(),size))return {};
    result.pop_back();return result;
}
DWORD canonical(const char *input,std::wstring &result) {
    char *value=nullptr;DWORD code=shou_win_normalize(input,&value);
    if(!code){result=wide(value);std::replace(result.begin(),result.end(),L'/',L'\\');}
    shou_win_free(value);return code;
}
bool contains(const std::wstring &parent,const std::wstring &child) {
    return _wcsicmp(parent.c_str(),child.c_str())==0 ||
        (child.size()>parent.size() && _wcsnicmp(parent.c_str(),child.c_str(),parent.size())==0 && (parent.back()==L'\\' || child[parent.size()]==L'\\'));
}
DWORD tokenUser(HANDLE process,std::vector<BYTE> &value) {
    Handle token;if(!OpenProcessToken(process,TOKEN_QUERY,&token.value))return GetLastError();
    DWORD size=0;GetTokenInformation(token.value,TokenUser,nullptr,0,&size);
    if(size==0 || size>65536)return ERROR_INVALID_DATA;
    value.resize(size);
    return GetTokenInformation(token.value,TokenUser,value.data(),size,&size)?0:GetLastError();
}
template<typename T> bool remote(HANDLE process,uintptr_t address,T &result) {
    SIZE_T size=0;return ReadProcessMemory(process,reinterpret_cast<const void *>(address),&result,sizeof(result),&size) && size==sizeof(result);
}
struct String32 {uint16_t length,capacity;uint32_t buffer;};
struct String64 {uint16_t length,capacity;uint32_t padding;uint64_t buffer;};
template<typename S> DWORD directoryString(HANDLE process,uintptr_t address,std::wstring &result) {
    S before{},after{};
    uint64_t directoryHandle=0,verifiedHandle=0;
    if constexpr(sizeof(S)==sizeof(String32)){
        uint32_t handle=0;if(!remote(process,address+sizeof(S),handle))return ERROR_PARTIAL_COPY;directoryHandle=handle;
    }else if(!remote(process,address+sizeof(S),directoryHandle))return ERROR_PARTIAL_COPY;
    if(!directoryHandle)return ERROR_PARTIAL_COPY;
    if(!remote(process,address,before) || !before.buffer || !before.length || before.length%2 || before.length>32768 || before.capacity<before.length)return ERROR_PARTIAL_COPY;
    result.resize(before.length/sizeof(wchar_t));SIZE_T count=0;
    if(!ReadProcessMemory(process,reinterpret_cast<const void *>(static_cast<uintptr_t>(before.buffer)),result.data(),before.length,&count) || count!=before.length ||
       !remote(process,address,after) || std::memcmp(&before,&after,sizeof(before)) || result.find(L'\0')!=std::wstring::npos)return ERROR_PARTIAL_COPY;
    std::wstring verified(result.size(),0);
    if(!ReadProcessMemory(process,reinterpret_cast<const void *>(static_cast<uintptr_t>(before.buffer)),verified.data(),before.length,&count) || count!=before.length || verified!=result)return ERROR_PARTIAL_COPY;
    int bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,result.data(),static_cast<int>(result.size()),nullptr,0,nullptr,nullptr);
    if(!bytes)return ERROR_INVALID_DATA;
    std::string text(bytes,0);WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,result.data(),static_cast<int>(result.size()),text.data(),bytes,nullptr,nullptr);
    shou_win_info metadata{};DWORD code=shou_win_stat(text.c_str(),&metadata);if(code)return code;
    if(metadata.kind!=2)return ERROR_DIRECTORY;
    // A plausible DOS path is not sufficient evidence of a supported PEB
    // layout. Its paired directory handle must identify that same directory.
    Handle directory;
    if(!DuplicateHandle(process,reinterpret_cast<HANDLE>(static_cast<uintptr_t>(directoryHandle)),GetCurrentProcess(),&directory.value,0,FALSE,DUPLICATE_SAME_ACCESS))return GetLastError();
    FILE_ID_INFO identity{};FILE_STANDARD_INFO standard{};
    if(!GetFileInformationByHandleEx(directory.value,FileIdInfo,&identity,sizeof(identity)) ||
       !GetFileInformationByHandleEx(directory.value,FileStandardInfo,&standard,sizeof(standard)))return GetLastError();
    if(!standard.Directory || identity.VolumeSerialNumber!=metadata.volume || std::memcmp(identity.FileId.Identifier,metadata.file_id,sizeof(metadata.file_id)))return ERROR_FILE_INVALID;
    if constexpr(sizeof(S)==sizeof(String32)){
        uint32_t handle=0;if(!remote(process,address+sizeof(S),handle))return ERROR_PARTIAL_COPY;verifiedHandle=handle;
    }else if(!remote(process,address+sizeof(S),verifiedHandle))return ERROR_PARTIAL_COPY;
    if(verifiedHandle!=directoryHandle || !remote(process,address,after) || std::memcmp(&before,&after,sizeof(before)))return ERROR_PARTIAL_COPY;
    return canonical(text.c_str(),result);
}
DWORD workingDirectory(HANDLE process,std::wstring &result) {
    // Windows 11 x64/ARM64 use the same native 64-bit process-parameter layout;
    // WOW64 has a separate 32-bit PEB. Reject unreadable or changing evidence.
    using Query=NTSTATUS(NTAPI *)(HANDLE,ULONG,PVOID,ULONG,PULONG);
    auto query=reinterpret_cast<Query>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryInformationProcess"));
    if(!query || sizeof(uintptr_t)!=8)return ERROR_NOT_SUPPORTED;
    USHORT machine=0,native=0;if(!IsWow64Process2(process,&machine,&native))return GetLastError();
    if(machine==IMAGE_FILE_MACHINE_I386){
        uintptr_t peb=0;uint32_t parameters=0;
        if(query(process,26,&peb,sizeof(peb),nullptr)<0 || !peb || !remote(process,peb+0x10,parameters) || !parameters)return ERROR_PARTIAL_COPY;
        return directoryString<String32>(process,parameters+0x24,result);
    }
    if(machine!=IMAGE_FILE_MACHINE_UNKNOWN && machine!=IMAGE_FILE_MACHINE_AMD64 && machine!=IMAGE_FILE_MACHINE_ARM64)return ERROR_NOT_SUPPORTED;
    PROCESS_BASIC_INFORMATION info{};uintptr_t parameters=0;
    if(query(process,0,&info,sizeof(info),nullptr)<0 || !info.PebBaseAddress ||
       !remote(process,reinterpret_cast<uintptr_t>(info.PebBaseAddress)+0x20,parameters) || !parameters)return ERROR_PARTIAL_COPY;
    return directoryString<String64>(process,parameters+0x38,result);
}
std::wstring quote(const std::wstring &value) {
    std::wstring result=L"\"";size_t slashes=0;
    for(auto ch:value){
        if(ch==L'\\'){++slashes;continue;}
        if(ch==L'"'){result.append(slashes*2+1,L'\\');result+=ch;}
        else {result.append(slashes,L'\\');result+=ch;}
        slashes=0;
    }
    result.append(slashes*2,L'\\');return result+L'"';
}
std::vector<wchar_t> gitEnvironment() {
    std::vector<std::wstring> values;auto environment=GetEnvironmentStringsW();
    if(!environment)return {};
    for(auto entry=environment;*entry;entry+=wcslen(entry)+1){
        if(_wcsnicmp(entry,L"GIT_",4) && _wcsnicmp(entry,L"GCM_",4))values.emplace_back(entry);
    }
    FreeEnvironmentStringsW(environment);
    for(auto value:{L"GIT_CONFIG_NOSYSTEM=1",L"GIT_CONFIG_GLOBAL=NUL",L"GIT_TERMINAL_PROMPT=0",L"GIT_OPTIONAL_LOCKS=0"})values.emplace_back(value);
    std::sort(values.begin(),values.end(),[](const auto &a,const auto &b){return _wcsicmp(a.c_str(),b.c_str())<0;});
    std::vector<wchar_t> result;
    for(const auto &value:values){result.insert(result.end(),value.begin(),value.end());result.push_back(0);}
    result.push_back(0);return result;
}
DWORD gitOutput(const std::wstring &executable,const std::wstring &directory,bool &tracked) {
    SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};
    Handle outputRead,outputWrite,errorRead,errorWrite,input;
    if(!CreatePipe(&outputRead.value,&outputWrite.value,&security,0) || !CreatePipe(&errorRead.value,&errorWrite.value,&security,0))return GetLastError();
    if(!SetHandleInformation(outputRead.value,HANDLE_FLAG_INHERIT,0) || !SetHandleInformation(errorRead.value,HANDLE_FLAG_INHERIT,0))return GetLastError();
    input.value=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,nullptr);
    if(input.value==INVALID_HANDLE_VALUE)return GetLastError();
    SIZE_T attributeBytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&attributeBytes);
    std::vector<BYTE> attributes(attributeBytes);auto attributeList=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    if(!InitializeProcThreadAttributeList(attributeList,1,0,&attributeBytes))return GetLastError();
    struct AttributeCleanup{LPPROC_THREAD_ATTRIBUTE_LIST value;~AttributeCleanup(){DeleteProcThreadAttributeList(value);}} cleanup{attributeList};
    HANDLE inherited[]={outputWrite.value,errorWrite.value,input.value};
    if(!UpdateProcThreadAttribute(attributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,inherited,sizeof(inherited),nullptr,nullptr))return GetLastError();
    STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);startup.lpAttributeList=attributeList;
    startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES;startup.StartupInfo.hStdOutput=outputWrite.value;startup.StartupInfo.hStdError=errorWrite.value;startup.StartupInfo.hStdInput=input.value;
    std::wstring command=quote(executable)+L" --no-optional-locks -c core.fsmonitor=false -c core.untrackedCache=false -C "+quote(directory)+L" ls-files --cached -z -- .";
    auto environment=gitEnvironment();if(environment.empty())return ERROR_INVALID_DATA;
    Handle job(CreateJobObjectW(nullptr,nullptr));if(!job.value)return GetLastError();
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if(!SetInformationJobObject(job.value,JobObjectExtendedLimitInformation,&limits,sizeof(limits)))return GetLastError();
    PROCESS_INFORMATION child{};
    if(!CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_SUSPENDED|CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT,environment.data(),directory.c_str(),&startup.StartupInfo,&child))return GetLastError();
    Handle process(child.hProcess),thread(child.hThread);
    if(!AssignProcessToJobObject(job.value,process.value)){DWORD code=GetLastError();TerminateProcess(process.value,code);return code;}
    if(ResumeThread(thread.value)==DWORD(-1))return GetLastError();
    CloseHandle(outputWrite.value);outputWrite.value=nullptr;CloseHandle(errorWrite.value);errorWrite.value=nullptr;
    ULONGLONG deadline=GetTickCount64()+3000;size_t output=0,errors=0;
    auto drain=[](HANDLE pipe,size_t &total,size_t limit)->DWORD{
        DWORD available=0;if(!PeekNamedPipe(pipe,nullptr,0,nullptr,&available,nullptr))return GetLastError()==ERROR_BROKEN_PIPE?0:GetLastError();
        char buffer[8192];
        while(available){
            DWORD count=0;if(!ReadFile(pipe,buffer,std::min<DWORD>(available,sizeof(buffer)),&count,nullptr))return GetLastError();
            if(!count)return ERROR_READ_FAULT;
            total+=count;if(total>limit)return ERROR_MORE_DATA;
            available-=count;
        }
        return 0;
    };
    while(true){
        DWORD code=drain(outputRead.value,output,2097152);if(code)return code;
        code=drain(errorRead.value,errors,65536);if(code)return code;
        DWORD state=WaitForSingleObject(process.value,0);
        if(state==WAIT_OBJECT_0){
            if((code=drain(outputRead.value,output,2097152)) || (code=drain(errorRead.value,errors,65536)))return code;
            DWORD exit=0;if(!GetExitCodeProcess(process.value,&exit))return GetLastError();
            if(exit || errors)return ERROR_INVALID_DATA;
            tracked=output>0;return 0;
        }
        if(state==WAIT_FAILED)return GetLastError();
        if(GetTickCount64()>=deadline)return ERROR_TIMEOUT;
        Sleep(5);
    }
}
}

extern "C" int shou_win_build_processes(const char *input,const char *projectInput,char **result) {
    if(!input || !result)return ERROR_INVALID_PARAMETER;
    *result=nullptr;std::wstring names=wide(input),project;
    if(names.size()>4096)return ERROR_INVALID_PARAMETER;
    if(projectInput){DWORD code=canonical(projectInput,project);if(code)return code;shou_win_info metadata{};if((code=shou_win_stat(projectInput,&metadata)))return code;if(metadata.kind!=2)return ERROR_DIRECTORY;}
    std::map<std::wstring,std::string> expected;
    for(size_t start=0;start<names.size();){
        auto end=names.find(L'\n',start);if(end==std::wstring::npos)end=names.size();auto name=names.substr(start,end-start);
        if(name.empty() || name.size()>128)return ERROR_INVALID_PARAMETER;
        std::string original;for(auto ch:name){if(!((ch>=L'a'&&ch<=L'z')||(ch>=L'A'&&ch<=L'Z')||(ch>=L'0'&&ch<=L'9')||ch==L'_'||ch==L'.'||ch==L'+'||ch==L'-'))return ERROR_INVALID_PARAMETER;original+=static_cast<char>(ch);}
        std::transform(name.begin(),name.end(),name.begin(),towlower);if(name.size()<4 || name.substr(name.size()-4)!=L".exe")name+=L".exe";
        expected[name]=original;start=end+1;
    }
    std::vector<BYTE> ownUser;if(projectInput){DWORD code=tokenUser(GetCurrentProcess(),ownUser);if(code)return code;}
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0));if(snapshot.value==INVALID_HANDLE_VALUE)return GetLastError();
    PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);std::map<std::string,bool> matches;
    if(!Process32FirstW(snapshot.value,&entry))return GetLastError();
    size_t count=0;ULONGLONG deadline=GetTickCount64()+3000;
    do {
        if(++count>32768 || GetTickCount64()>=deadline)return ERROR_TIMEOUT;
        std::wstring name=entry.szExeFile;std::transform(name.begin(),name.end(),name.begin(),towlower);
        auto found=expected.find(name);if(found==expected.end())continue;
        if(projectInput){
            Handle query(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,entry.th32ProcessID));
            if(!query.value){if(GetLastError()==ERROR_INVALID_PARAMETER)continue;return GetLastError();}
            if(WaitForSingleObject(query.value,0)==WAIT_OBJECT_0)continue;
            std::vector<BYTE> owner;DWORD code=tokenUser(query.value,owner);if(code)return code;
            if(!EqualSid(reinterpret_cast<TOKEN_USER *>(ownUser.data())->User.Sid,reinterpret_cast<TOKEN_USER *>(owner.data())->User.Sid))continue;
            Handle process(OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_VM_READ|PROCESS_DUP_HANDLE|SYNCHRONIZE,FALSE,entry.th32ProcessID));
            if(!process.value){if(WaitForSingleObject(query.value,0)==WAIT_OBJECT_0)continue;return GetLastError();}
            FILETIME queryStart{},processStart{},exit{},kernel{},user{};
            if(!GetProcessTimes(query.value,&queryStart,&exit,&kernel,&user) || !GetProcessTimes(process.value,&processStart,&exit,&kernel,&user))return GetLastError();
            if(CompareFileTime(&queryStart,&processStart))return ERROR_FILE_INVALID;
            std::wstring directory;if((code=workingDirectory(process.value,directory))){if(WaitForSingleObject(process.value,0)==WAIT_OBJECT_0)continue;return code;}
            if(!contains(project,directory) && !contains(directory,project))continue;
        }
        matches[found->second]=true;
    }while(Process32NextW(snapshot.value,&entry));
    if(GetLastError()!=ERROR_NO_MORE_FILES)return GetLastError();
    std::string output;for(const auto &match:matches)output+=match.first+"\n";
    *result=static_cast<char *>(malloc(output.size()+1));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;
    std::memcpy(*result,output.c_str(),output.size()+1);return 0;
}

extern "C" int shou_win_git_tracked(const char *input,int *tracked) {
    if(!input || !tracked)return ERROR_INVALID_PARAMETER;
    *tracked=0;std::wstring directory;DWORD code=canonical(input,directory);if(code)return code;
    // Never search the workspace or PATH for an executable. Only standard Git
    // installations are accepted, with no-follow verification before launch.
    std::vector<std::wstring> candidates;
    for(auto variable:{L"ProgramW6432",L"ProgramFiles",L"ProgramFiles(x86)",L"LOCALAPPDATA"}){
        DWORD count=GetEnvironmentVariableW(variable,nullptr,0);if(!count || count>32768)continue;
        std::wstring value(count,0);if(!GetEnvironmentVariableW(variable,value.data(),count))continue;value.resize(wcslen(value.c_str()));
        candidates.push_back(value+(wcscmp(variable,L"LOCALAPPDATA")==0?L"\\Programs\\Git\\cmd\\git.exe":L"\\Git\\cmd\\git.exe"));
    }
    for(const auto &candidate:candidates){
        int count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,candidate.c_str(),-1,nullptr,0,nullptr,nullptr);if(!count)continue;
        std::string path(count,0);WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,candidate.c_str(),-1,path.data(),count,nullptr,nullptr);
        shou_win_info metadata{};if(shou_win_stat(path.c_str(),&metadata)!=0 || metadata.kind!=1)continue;
        bool value=false;if((code=gitOutput(candidate,directory,value)))return code;
        *tracked=value?1:0;return 0;
    }
    return ERROR_FILE_NOT_FOUND;
}
