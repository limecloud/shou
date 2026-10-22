#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <tlhelp32.h>
#include <sddl.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {
struct Handle {
    HANDLE value=nullptr;
    explicit Handle(HANDLE input=nullptr):value(input){}
    Handle(const Handle &)=delete;
    Handle &operator=(const Handle &)=delete;
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
};
std::wstring wide(const char *input){
    if(!input)return {};
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,input,-1,nullptr,0);
    if(!count || count>32768)return {};
    std::wstring result(count,0);
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,input,-1,result.data(),count))return {};
    result.pop_back();return result;
}
bool knownName(const std::wstring &name){
    for(auto candidate:{L"chrome.exe",L"msedge.exe",L"brave.exe",L"vivaldi.exe",L"firefox.exe",L"Code.exe",L"Code - Insiders.exe",L"slack.exe",L"Discord.exe",L"Notion.exe",L"Postman.exe",L"Cursor.exe"})
        if(!_wcsicmp(name.c_str(),candidate))return true;
    return false;
}
DWORD tokenOwner(HANDLE process,std::string &owner,bool rejectElevated){
    Handle token;if(!OpenProcessToken(process,TOKEN_QUERY,&token.value))return GetLastError();
    DWORD bytes=0;GetTokenInformation(token.value,TokenUser,nullptr,0,&bytes);
    if(!bytes || bytes>65536)return ERROR_INVALID_DATA;
    std::vector<BYTE> storage(bytes);
    if(!GetTokenInformation(token.value,TokenUser,storage.data(),bytes,&bytes))return GetLastError();
    auto user=reinterpret_cast<TOKEN_USER *>(storage.data());LPSTR sid=nullptr;
    if(!ConvertSidToStringSidA(user->User.Sid,&sid))return GetLastError();
    owner=sid;LocalFree(sid);
    if(rejectElevated){
        TOKEN_ELEVATION elevation{};
        if(!GetTokenInformation(token.value,TokenElevation,&elevation,sizeof(elevation),&bytes))return GetLastError();
        if(elevation.TokenIsElevated)return ERROR_ACCESS_DENIED;
    }
    return 0;
}
DWORD inspect(HANDLE process,DWORD pid,const std::wstring &name,shou_win_close_process &result){
    result={};
    if(pid==GetCurrentProcessId() || WaitForSingleObject(process,0)!=WAIT_TIMEOUT)return ERROR_PROCESS_ABORTED;
    DWORD ownSession=0,session=0;
    if(!ProcessIdToSessionId(GetCurrentProcessId(),&ownSession) || !ProcessIdToSessionId(pid,&session))return GetLastError();
    if(!session || session!=ownSession)return ERROR_ACCESS_DENIED;
    std::string ownUser,owner;DWORD code=tokenOwner(GetCurrentProcess(),ownUser,false);if(code)return code;
    if((code=tokenOwner(process,owner,true)))return code;
    if(owner!=ownUser || owner.size()>=sizeof(result.owner_sid))return ERROR_ACCESS_DENIED;
    FILETIME created{},exit{},kernel{},user{};
    if(!GetProcessTimes(process,&created,&exit,&kernel,&user))return GetLastError();
    std::wstring path(32768,0);DWORD length=static_cast<DWORD>(path.size());
    if(!QueryFullProcessImageNameW(process,0,path.data(),&length))return GetLastError();
    path.resize(length);
    if(_wcsicmp(path.substr(path.find_last_of(L"\\/")+1).c_str(),name.c_str()))return ERROR_FILE_INVALID;
    auto count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path.c_str(),-1,nullptr,0,nullptr,nullptr);
    if(!count || size_t(count)>sizeof(result.executable_path))return ERROR_FILENAME_EXCED_RANGE;
    std::string utf8(count,0);WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path.c_str(),-1,utf8.data(),count,nullptr,nullptr);
    char *canonical=nullptr;if((code=shou_win_normalize(utf8.c_str(),&canonical)))return code;
    if(strlen(canonical)>=sizeof(result.executable_path)){shou_win_free(canonical);return ERROR_FILENAME_EXCED_RANGE;}
    strcpy_s(result.executable_path,canonical);shou_win_free(canonical);
    if((code=shou_win_stat(result.executable_path,&result.executable_identity)))return code;
    if(result.executable_identity.kind!=1 || result.executable_identity.links!=1)return ERROR_ACCESS_DENIED;
    result.pid=pid;result.session=session;result.created=(uint64_t(created.dwHighDateTime)<<32)|created.dwLowDateTime;
    strcpy_s(result.owner_sid,owner.c_str());
    return WaitForSingleObject(process,0)==WAIT_TIMEOUT?0:ERROR_PROCESS_ABORTED;
}
bool same(const shou_win_close_process &a,const shou_win_close_process &b){
    return a.pid==b.pid && a.session==b.session && a.created==b.created &&
        !strcmp(a.owner_sid,b.owner_sid) && !strcmp(a.executable_path,b.executable_path) &&
        !memcmp(&a.executable_identity,&b.executable_identity,sizeof(a.executable_identity));
}
struct CloseWindows {
    const std::vector<HANDLE> &handles;
    const shou_win_close_process *expected;
    shou_win_read_cancelled cancelled;
    void *context;
    DWORD code=0;
    size_t windows=0;
};
BOOL CALLBACK closeWindow(HWND window,LPARAM context){
    auto &state=*reinterpret_cast<CloseWindows *>(context);
    if(state.cancelled && state.cancelled(state.context)){state.code=ERROR_CANCELLED;return FALSE;}
    DWORD pid=0;GetWindowThreadProcessId(window,&pid);
    for(size_t index=0;index<state.handles.size();index++){
        if(pid!=state.expected[index].pid)continue;
        if(++state.windows>1024){state.code=ERROR_MORE_DATA;return FALSE;}
        if(!IsWindowVisible(window) || GetWindow(window,GW_OWNER)!=nullptr)continue;
        if(WaitForSingleObject(state.handles[index],0)!=WAIT_TIMEOUT)continue;
        // An asynchronous normal close lets the owning application display
        // its save/quit dialog. Never send WM_QUIT or terminate a process.
        DWORD verified=0;GetWindowThreadProcessId(window,&verified);
        if(verified==pid && !PostMessageW(window,WM_CLOSE,0,0)){state.code=GetLastError();return FALSE;}
    }
    return TRUE;
}
}

extern "C" int shou_win_close_process_inventory(const char *input,shou_win_close_process **result,size_t *count){
    if(!input || !result || !count)return ERROR_INVALID_PARAMETER;
    *result=nullptr;*count=0;const auto name=wide(input);if(!knownName(name))return ERROR_ACCESS_DENIED;
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0));if(snapshot.value==INVALID_HANDLE_VALUE)return GetLastError();
    PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);std::vector<shou_win_close_process> values;
    if(!Process32FirstW(snapshot.value,&entry))return GetLastError();
    const auto deadline=GetTickCount64()+3000;
    do {
        if(GetTickCount64()>=deadline)return ERROR_TIMEOUT;
        if(_wcsicmp(entry.szExeFile,name.c_str()))continue;
        if(values.size()>=256)return ERROR_MORE_DATA;
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,entry.th32ProcessID));
        if(!process.value){if(GetLastError()==ERROR_INVALID_PARAMETER)continue;return GetLastError();}
        shou_win_close_process value{};auto code=inspect(process.value,entry.th32ProcessID,name,value);
        if(code==ERROR_PROCESS_ABORTED)continue;
        if(code)return code;
        values.push_back(value);
    }while(Process32NextW(snapshot.value,&entry));
    if(GetLastError()!=ERROR_NO_MORE_FILES)return GetLastError();
    std::sort(values.begin(),values.end(),[](const auto &a,const auto &b){return a.pid<b.pid;});
    if(values.empty())return 0;
    *result=static_cast<shou_win_close_process *>(malloc(values.size()*sizeof(values[0])));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;
    memcpy(*result,values.data(),values.size()*sizeof(values[0]));*count=values.size();return 0;
}

extern "C" int shou_win_request_process_close(const char *input,const shou_win_close_process *expected,size_t count,shou_win_read_cancelled cancelled,void *context){
    if(!input || !expected || !count || count>256)return ERROR_INVALID_PARAMETER;
    const auto name=wide(input);if(!knownName(name))return ERROR_ACCESS_DENIED;
    struct Pins{std::vector<HANDLE> values;~Pins(){for(auto value:values)CloseHandle(value);}} pins;
    for(size_t index=0;index<count;index++){
        if(cancelled && cancelled(context))return ERROR_CANCELLED;
        if(!memchr(expected[index].owner_sid,0,sizeof(expected[index].owner_sid)) || !memchr(expected[index].executable_path,0,sizeof(expected[index].executable_path)))return ERROR_INVALID_PARAMETER;
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,expected[index].pid));
        if(!process.value){if(GetLastError()==ERROR_INVALID_PARAMETER)continue;return GetLastError();}
        shou_win_close_process current{};auto code=inspect(process.value,expected[index].pid,name,current);
        if(code==ERROR_PROCESS_ABORTED)continue;
        if(code)return code;
        if(!same(current,expected[index]))return ERROR_FILE_INVALID;
        // Preserve one slot per reviewed PID, including exited processes.
        while(pins.values.size()<index)pins.values.push_back(nullptr);
        pins.values.push_back(process.value);process.value=nullptr;
    }
    while(pins.values.size()<count)pins.values.push_back(nullptr);
    CloseWindows state{pins.values,expected,cancelled,context};
    EnumWindows(closeWindow,reinterpret_cast<LPARAM>(&state));return state.code;
}
