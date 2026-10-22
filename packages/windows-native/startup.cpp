#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#define SECURITY_WIN32
#include "shou_windows.h"
#include <windows.h>
#include <taskschd.h>
#include <sddl.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <bcrypt.h>
#include <security.h>
#include <secext.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace {
struct Error { DWORD code; };
struct BString {
    BSTR value=nullptr;
    BString()=default;
    explicit BString(const wchar_t *text):value(SysAllocString(text)) { if(!value)throw Error{ERROR_NOT_ENOUGH_MEMORY}; }
    ~BString(){SysFreeString(value);}
    BString(const BString &)=delete;
    BString &operator=(const BString &)=delete;
    std::wstring text() const { return value?std::wstring(value,SysStringLen(value)):L""; }
};
struct ComSession {
    HRESULT status=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    ~ComSession(){if(SUCCEEDED(status))CoUninitialize();}
};
struct RegistryKey { HKEY value=nullptr; ~RegistryKey(){if(value)RegCloseKey(value);} };
struct ServiceHandle { SC_HANDLE value=nullptr; ~ServiceHandle(){if(value)CloseServiceHandle(value);} };
std::string utf8(const std::wstring &value) {
    if(value.size()>262144)throw Error{ERROR_MORE_DATA};
    if(value.empty())return {};
    int count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),nullptr,0,nullptr,nullptr);
    if(!count)throw Error{ERROR_NO_UNICODE_TRANSLATION};
    std::string result(count,0);
    if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),result.data(),count,nullptr,nullptr))throw Error{ERROR_NO_UNICODE_TRANSLATION};
    return result;
}
std::wstring wide(const char *value) {
    if(!value || std::strlen(value)>32768)throw Error{ERROR_INVALID_PARAMETER};
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,nullptr,0);
    if(!count)throw Error{ERROR_NO_UNICODE_TRANSLATION};
    std::wstring result(count,0);
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,result.data(),count))throw Error{ERROR_NO_UNICODE_TRANSLATION};
    result.pop_back();return result;
}
std::string json(const std::string &value) {
    std::string result="\"";
    const char hex[]="0123456789abcdef";
    for(unsigned char c:value) {
        if(c=='"' || c=='\\'){result+='\\';result+=static_cast<char>(c);}
        else if(c<32){result+="\\u00";result+=hex[c>>4];result+=hex[c&15];}
        else result+=static_cast<char>(c);
    }
    return result+'"';
}
std::string q(const std::wstring &value){return json(utf8(value));}
std::string array(const std::vector<std::string> &rows){std::string result="[";for(const auto &row:rows){if(result.size()>1)result+=',';result+=row;}return result+"]";}
std::string sid() {
    HANDLE token=nullptr;
    if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))throw Error{GetLastError()};
    DWORD count=0;GetTokenInformation(token,TokenUser,nullptr,0,&count);
    if(!count || count>65536){CloseHandle(token);throw Error{ERROR_INVALID_DATA};}
    std::vector<BYTE> bytes(count);
    if(!GetTokenInformation(token,TokenUser,bytes.data(),count,&count)){DWORD code=GetLastError();CloseHandle(token);throw Error{code};}
    CloseHandle(token);LPWSTR text=nullptr;
    if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(bytes.data())->User.Sid,&text))throw Error{GetLastError()};
    auto result=utf8(text);LocalFree(text);return result;
}
struct CurrentUser {
    std::string userSid=sid();
    std::vector<std::wstring> names;
    CurrentUser() {
        for(auto format:{NameSamCompatible,NameUserPrincipal}) {
            ULONG size=0;GetUserNameExW(format,nullptr,&size);
            if(!size || size>32768)continue;
            std::wstring value(size,0);
            if(!GetUserNameExW(format,value.data(),&size))continue;
            value.resize(size);if(!value.empty() && value.back()==L'\0')value.pop_back();
            names.push_back(value);
        }
        wchar_t computer[MAX_COMPUTERNAME_LENGTH+1]{};DWORD size=MAX_COMPUTERNAME_LENGTH+1;
        std::wstring bareName;
        if(GetComputerNameW(computer,&size))for(const auto &name:names) {
            auto separator=name.find(L'\\');
            if(separator!=std::wstring::npos && CompareStringOrdinal(name.data(),static_cast<int>(separator),computer,static_cast<int>(size),TRUE)==CSTR_EQUAL) {
                bareName=name.substr(separator+1);break;
            }
        }
        if(!bareName.empty())names.push_back(bareName);
    }
    bool matches(const std::wstring &name) const {
        if(utf8(name)==userSid)return true;
        return std::any_of(names.begin(),names.end(),[&](const auto &known){return CompareStringOrdinal(known.c_str(),-1,name.c_str(),-1,TRUE)==CSTR_EQUAL;});
    }
};
std::string hash(const std::string &value) {
    BCRYPT_ALG_HANDLE algorithm=nullptr;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw Error{ERROR_INVALID_DATA};
    BYTE digest[32]{};
    auto status=BCryptHash(algorithm,nullptr,0,reinterpret_cast<PUCHAR>(const_cast<char *>(value.data())),static_cast<ULONG>(value.size()),digest,32);
    BCryptCloseAlgorithmProvider(algorithm,0);
    if(status<0)throw Error{ERROR_INVALID_DATA};
    const char hex[]="0123456789abcdef";std::string result;
    for(BYTE c:digest){result+=hex[c>>4];result+=hex[c&15];}return result;
}
std::wstring executable(const std::wstring &input,bool command) {
    if(input.empty() || input.size()>32767 || input.find(L'\0')!=std::wstring::npos)return {};
    auto path=input;
    if(path.front()==L'"') {
        auto end=path.find(L'"',1);if(end==std::wstring::npos)return {};path=path.substr(1,end-1);
    } else if(command) {
        // Unquoted commands with spaces are ambiguous; never search PATH or
        // guess which executable Windows would choose.
        auto end=path.find_first_of(L" \t");if(end!=std::wstring::npos)path=path.substr(0,end);
    }
    DWORD count=ExpandEnvironmentStringsW(path.c_str(),nullptr,0);
    if(!count || count>32768)return {};
    std::wstring expanded(count,0);
    if(ExpandEnvironmentStringsW(path.c_str(),expanded.data(),count)!=count)return {};
    expanded.pop_back();
    if(expanded.size()<3 || expanded[1]!=L':' || (expanded[2]!=L'\\' && expanded[2]!=L'/'))return {};
    // An unquoted command's first token must explicitly name an executable.
    if(command && input.front()!=L'"' && (expanded.size()<4 || _wcsicmp(expanded.c_str()+expanded.size()-4,L".exe")!=0))return {};
    char *normalized=nullptr;auto code=shou_win_normalize(utf8(expanded).c_str(),&normalized);
    if(code)return {};
    auto result=wide(normalized);shou_win_free(normalized);return result;
}
std::string targetState(const std::wstring &path) {
    if(path.empty())return "unknown";
    shou_win_info info{};auto code=shou_win_stat(utf8(path).c_str(),&info);
    if(code==ERROR_FILE_NOT_FOUND || code==ERROR_PATH_NOT_FOUND)return "missing";
    return !code && info.kind==1?"exists":"unknown";
}
std::wstring shortcutProgram(const std::string &path) {
    void *bytes=nullptr;size_t count=0;
    auto code=shou_win_read(path.c_str(),262144,&bytes,&count);
    if(code)throw Error{static_cast<DWORD>(code)};
    HGLOBAL memory=GlobalAlloc(GMEM_MOVEABLE,count);
    if(!memory){shou_win_free(bytes);throw Error{ERROR_NOT_ENOUGH_MEMORY};}
    auto destination=GlobalLock(memory);
    if(!destination){GlobalFree(memory);shou_win_free(bytes);throw Error{ERROR_NOT_ENOUGH_MEMORY};}
    std::memcpy(destination,bytes,count);GlobalUnlock(memory);shou_win_free(bytes);
    ComPtr<IStream> stream;
    if(FAILED(CreateStreamOnHGlobal(memory,TRUE,&stream))){GlobalFree(memory);throw Error{ERROR_INVALID_DATA};}
    ComPtr<IShellLinkW> link;ComPtr<IPersistStream> persistence;
    if(FAILED(CoCreateInstance(__uuidof(ShellLink),nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&link))) || FAILED(link.As(&persistence)) || FAILED(persistence->Load(stream.Get())))throw Error{ERROR_INVALID_DATA};
    wchar_t target[32768]{};
    // Read the embedded path only. Resolve would search, access network paths,
    // track moved targets or display UI, so it is deliberately never called.
    if(FAILED(link->GetPath(target,32768,nullptr,SLGP_RAWPATH)))throw Error{ERROR_INVALID_DATA};
    return executable(target,false);
}
struct Source {
    std::string id,path,kind,scope,status="complete";
    bool system=false;size_t entries=0,definitions=0;
    std::string encoded() const {
        return "{\"location\":{\"id\":"+json(id)+",\"path\":"+json(path)+",\"kind\":"+json(kind)+",\"scope\":"+json(scope)+",\"system_owned\":"+(system?"true":"false")+"},\"status\":"+json(status)+",\"entry_count\":"+std::to_string(entries)+",\"definition_count\":"+std::to_string(definitions)+"}";
    }
};
struct Inventory {
    size_t limit,visited=0,bytes=0;ULONGLONG deadline;
    shou_win_read_cancelled cancelled;void *context;
    std::vector<Source> sources;std::vector<std::string> items,issues;
    void issue(Source &source,const std::string &path,const char *code) {
        source.status="partial";
        if(issues.size()<128)issues.push_back("{\"source_id\":"+json(source.id)+",\"path\":"+json(path)+",\"code\":"+json(code)+"}");
    }
    bool available(Source &source) {
        if(cancelled && cancelled(context))throw Error{ERROR_CANCELLED};
        if(visited>=limit || GetTickCount64()>=deadline || bytes>=6*1024*1024){issue(source,source.path,"resource_limit");return false;}
        return true;
    }
    bool step(Source &source){if(!available(source))return false;++visited;++source.entries;return true;}
    void add(Source &source,const std::wstring &path,const std::wstring &label,const std::wstring &program,const std::string &configured,const std::string &runtime,const std::vector<std::string> &triggers,const std::string &evidence="",bool control=false) {
        std::string row="{\"source_id\":"+json(source.id)+",\"path\":"+q(path)+",\"label\":"+q(label)+",\"program_path\":"+(program.empty()?"null":q(program))+",\"disabled_by_definition\":"+(configured=="disabled"?"true":"false")+",\"configured_state\":"+json(configured)+",\"runtime_state\":"+json(runtime)+",\"control_capability\":"+json(control?"windows_user_task":"system_settings")+",\"triggers\":"+array(triggers)+",\"target_state\":"+json(targetState(program))+",\"evidence_digest\":"+(evidence.empty()?"null":json(evidence))+"}";
        if(bytes+row.size()>6*1024*1024){bytes=6*1024*1024;issue(source,source.path,"resource_limit");return;}
        bytes+=row.size();items.push_back(row);++source.definitions;
    }
};
void registry(Inventory &inventory,HKEY hive,const wchar_t *key,REGSAM view,const char *id,const char *scope) {
    Source source{id,utf8(std::wstring(hive==HKEY_CURRENT_USER?L"HKEY_CURRENT_USER\\":L"HKEY_LOCAL_MACHINE\\")+key),"registry",scope};
    source.system=hive==HKEY_LOCAL_MACHINE;
    if(!inventory.available(source)){source.status="not_scanned";inventory.sources.push_back(source);return;}
    RegistryKey opened;auto code=RegOpenKeyExW(hive,key,0,KEY_QUERY_VALUE|view,&opened.value);
    if(code==ERROR_FILE_NOT_FOUND || code==ERROR_PATH_NOT_FOUND)source.status="missing";
    else if(code){source.status="unavailable";inventory.issue(source,source.path,"access_unavailable");}
    else {
        FILETIME before{},after{};
        if(RegQueryInfoKeyW(opened.value,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&before)!=ERROR_SUCCESS)inventory.issue(source,source.path,"state_unavailable");
        const auto first=inventory.items.size();
        for(DWORD index=0;;++index) {
            if(!inventory.available(source))break;
            wchar_t name[16384];DWORD nameCount=16384,type=0,dataCount=65536;std::vector<BYTE> bytes(dataCount+2,0);
            code=RegEnumValueW(opened.value,index,name,&nameCount,nullptr,&type,bytes.data(),&dataCount);
            if(code==ERROR_NO_MORE_ITEMS)break;
            if(!inventory.step(source))break;
            if(code){inventory.issue(source,source.path,"invalid_definition");continue;}
            if(type!=REG_SZ && type!=REG_EXPAND_SZ){inventory.issue(source,source.path,"unsupported_schema");continue;}
            if(dataCount%sizeof(wchar_t) || dataCount<sizeof(wchar_t)){inventory.issue(source,source.path,"invalid_definition");continue;}
            std::wstring command(reinterpret_cast<wchar_t *>(bytes.data()),dataCount/sizeof(wchar_t));
            while(!command.empty() && command.back()==L'\0')command.pop_back();
            if(command.empty() || command.find(L'\0')!=std::wstring::npos){inventory.issue(source,source.path,"invalid_definition");continue;}
            std::wstring label(name,nameCount);if(label.empty())label=L"(Default)";
            try { inventory.add(source,wide(source.path.c_str())+L"\\"+label,label,executable(command,true),"unknown","unknown",{json(wcsstr(key,L"RunOnce")?"login_once":"login")}); }
            catch(const Error &){inventory.issue(source,source.path,"invalid_definition");}
        }
        if(RegQueryInfoKeyW(opened.value,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&after)!=ERROR_SUCCESS || CompareFileTime(&before,&after)!=0){
            inventory.items.resize(first);source.definitions=0;inventory.issue(source,source.path,"definition_changed");
        }
    }
    inventory.sources.push_back(source);
}
void folder(Inventory &inventory,REFKNOWNFOLDERID known,const char *id,bool system) {
    Source source{id,"KnownFolder:Startup","startup_folder",system?"machine":"user"};source.system=system;
    PWSTR path=nullptr;auto status=SHGetKnownFolderPath(known,KF_FLAG_DONT_VERIFY,nullptr,&path);
    if(FAILED(status)){source.status="unavailable";inventory.issue(source,source.path,"access_unavailable");inventory.sources.push_back(source);return;}
    source.path=utf8(path);CoTaskMemFree(path);
    if(!inventory.available(source)){source.status="not_scanned";inventory.sources.push_back(source);return;}
    shou_win_info saved{};auto code=shou_win_stat(source.path.c_str(),&saved);
    if(code==ERROR_FILE_NOT_FOUND || code==ERROR_PATH_NOT_FOUND){source.status="missing";inventory.sources.push_back(source);return;}
    shou_win_directory *directory=nullptr;
    if(code || (code=shou_win_directory_open(source.path.c_str(),&saved,&directory))){source.status="unavailable";inventory.issue(source,source.path,"access_unavailable");inventory.sources.push_back(source);return;}
    const auto first=inventory.items.size();
    try {
        while(inventory.available(source)) {
            char *name=nullptr;code=shou_win_directory_next(directory,&name);
            if(code==ERROR_NO_MORE_FILES)break;
            if(code){inventory.issue(source,source.path,"read_failed");break;}
            auto label=wide(name);shou_win_free(name);
            if(!inventory.step(source))break;
            if(_wcsicmp(label.c_str(),L"desktop.ini")==0)continue;
            auto entry=source.path+"\\"+utf8(label);shou_win_info metadata{};
            if(shou_win_stat(entry.c_str(),&metadata) || metadata.kind!=1){inventory.issue(source,entry,"unsupported_definition");continue;}
            std::wstring program;
            if(label.size()>4 && _wcsicmp(label.c_str()+label.size()-4,L".lnk")==0) {
                try {program=shortcutProgram(entry);}
                catch(const Error &){inventory.issue(source,entry,"target_unavailable");}
            } else if(label.size()>4 && _wcsicmp(label.c_str()+label.size()-4,L".exe")==0)program=executable(wide(entry.c_str()),false);
            inventory.add(source,wide(entry.c_str()),label,program,"unknown","unknown",{json("login")});
        }
        if(shou_win_directory_verify(directory,&saved)){inventory.items.resize(first);source.definitions=0;inventory.issue(source,source.path,"definition_changed");}
    } catch(...){shou_win_directory_close(directory);throw;}
    shou_win_directory_close(directory);inventory.sources.push_back(source);
}
ComPtr<ITaskService> taskService() {
    ComPtr<ITaskService> service;
    HRESULT status=CoCreateInstance(__uuidof(TaskScheduler),nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&service));
    VARIANT empty;VariantInit(&empty);
    if(SUCCEEDED(status))status=service->Connect(empty,empty,empty,empty);
    if(FAILED(status))throw Error{static_cast<DWORD>(status)};
    return service;
}
struct TaskFacts {
    std::wstring path,name,program,xml;std::vector<std::string> triggers;
    std::string owner,runtime,digest;bool enabled=false,own=false;
};
TaskFacts taskFacts(IRegisteredTask *task,const CurrentUser &user) {
    TaskFacts facts;BString path,name,xml;
    VARIANT_BOOL enabled=VARIANT_FALSE;TASK_STATE state=TASK_STATE_UNKNOWN;
    ComPtr<ITaskDefinition> definition;ComPtr<IPrincipal> principal;
    if(FAILED(task->get_Path(&path.value)) || FAILED(task->get_Name(&name.value)) || FAILED(task->get_Xml(&xml.value)) || SysStringLen(xml.value)>262144 || FAILED(task->get_Enabled(&enabled)) || FAILED(task->get_Definition(&definition)) || FAILED(definition->get_Principal(&principal)))throw Error{ERROR_INVALID_DATA};
    BString owner;if(FAILED(principal->get_UserId(&owner.value)))throw Error{ERROR_ACCESS_DENIED};
    facts.path=path.text();facts.name=name.text();facts.xml=xml.text();facts.owner=utf8(owner.text());facts.enabled=enabled!=VARIANT_FALSE;facts.own=user.matches(owner.text());
    if(facts.path.size()>4096 || facts.name.empty())throw Error{ERROR_INVALID_DATA};
    if(SUCCEEDED(task->get_State(&state)))facts.runtime=state==TASK_STATE_RUNNING?"running":state==TASK_STATE_QUEUED?"queued":state==TASK_STATE_READY || state==TASK_STATE_DISABLED?"not_running":"unknown";
    else facts.runtime="unknown";
    ComPtr<ITriggerCollection> triggers;LONG count=0;
    if(FAILED(definition->get_Triggers(&triggers)) || FAILED(triggers->get_Count(&count)) || count<0 || count>64)throw Error{ERROR_INVALID_DATA};
    for(LONG index=1;index<=count;++index){ComPtr<ITrigger> trigger;TASK_TRIGGER_TYPE2 type=TASK_TRIGGER_EVENT;if(FAILED(triggers->get_Item(index,&trigger)) || FAILED(trigger->get_Type(&type)))throw Error{ERROR_INVALID_DATA};if(type==TASK_TRIGGER_LOGON)facts.triggers.push_back(json("login"));if(type==TASK_TRIGGER_BOOT)facts.triggers.push_back(json("boot"));}
    ComPtr<IActionCollection> actions;LONG actionCount=0;
    if(SUCCEEDED(definition->get_Actions(&actions)) && SUCCEEDED(actions->get_Count(&actionCount)) && actionCount==1){
        ComPtr<IAction> action;ComPtr<IExecAction> exec;BString program;
        if(SUCCEEDED(actions->get_Item(1,&action)) && SUCCEEDED(action.As(&exec)) && SUCCEEDED(exec->get_Path(&program.value)))facts.program=executable(program.text(),false);
    }
    BString after;if(FAILED(task->get_Xml(&after.value)) || after.text()!=facts.xml)throw Error{ERROR_FILE_INVALID};
    facts.digest=hash(utf8(facts.path)+"\n"+utf8(facts.xml)+"\n"+facts.owner+"\n"+(facts.enabled?"enabled":"disabled"));
    return facts;
}
void tasks(Inventory &inventory,bool includeSystem,const CurrentUser &user) {
    Source source{"windows.scheduled_tasks","TaskScheduler:\\","scheduled_task",includeSystem?"user_and_machine":"user"};
    if(!inventory.available(source)){source.status="not_scanned";inventory.sources.push_back(source);return;}
    try {
        auto service=taskService();BString root(L"\\");ComPtr<ITaskFolder> folder;
        if(FAILED(service->GetFolder(root.value,&folder)))throw Error{ERROR_ACCESS_DENIED};
        std::vector<std::pair<ComPtr<ITaskFolder>,int>> pending;pending.emplace_back(folder,0);
        while(!pending.empty() && inventory.available(source)) {
            auto current=pending.back();pending.pop_back();ComPtr<IRegisteredTaskCollection> collection;LONG count=0;
            if(FAILED(current.first->GetTasks(TASK_ENUM_HIDDEN,&collection)) || FAILED(collection->get_Count(&count)) || count<0 || count>100000){inventory.issue(source,source.path,"access_unavailable");continue;}
            for(LONG index=1;index<=count && inventory.available(source);++index) {
                if(!inventory.step(source))break;
                VARIANT key;VariantInit(&key);key.vt=VT_I4;key.lVal=index;ComPtr<IRegisteredTask> task;
                if(FAILED(collection->get_Item(key,&task))){inventory.issue(source,source.path,"read_failed");continue;}
                try {auto facts=taskFacts(task.Get(),user);if(facts.triggers.empty() || (!includeSystem && !facts.own))continue;
                    bool control=facts.own && _wcsnicmp(facts.path.c_str(),L"\\Microsoft\\",11)!=0;
                    inventory.add(source,facts.path,facts.name,facts.program,facts.enabled?"enabled":"disabled",facts.runtime,facts.triggers,facts.digest,control);
                } catch(const Error &error){if(error.code==ERROR_CANCELLED)throw;inventory.issue(source,source.path,error.code==ERROR_FILE_INVALID?"definition_changed":"state_unavailable");}
            }
            ComPtr<ITaskFolderCollection> children;LONG childCount=0;
            if(FAILED(current.first->GetFolders(0,&children)) || FAILED(children->get_Count(&childCount)) || childCount<0 || childCount>100000){inventory.issue(source,source.path,"access_unavailable");continue;}
            if(current.second>=32 && childCount){inventory.issue(source,source.path,"resource_limit");continue;}
            for(LONG index=1;index<=childCount && inventory.available(source);++index){
                ++inventory.visited;VARIANT key;VariantInit(&key);key.vt=VT_I4;key.lVal=index;ComPtr<ITaskFolder> child;BString name;
                if(FAILED(children->get_Item(key,&child)) || FAILED(child->get_Name(&name.value))){inventory.issue(source,source.path,"read_failed");continue;}
                pending.emplace_back(child,current.second+1);
            }
        }
    } catch(const Error &error){if(error.code==ERROR_CANCELLED)throw;inventory.issue(source,source.path,"access_unavailable");}
    inventory.sources.push_back(source);
}
void services(Inventory &inventory) {
    Source source{"windows.services","SCM:LocalMachine","service","machine"};source.system=true;
    if(!inventory.available(source)){source.status="not_scanned";inventory.sources.push_back(source);return;}
    ServiceHandle manager;manager.value=OpenSCManagerW(nullptr,nullptr,SC_MANAGER_ENUMERATE_SERVICE|SC_MANAGER_CONNECT);
    if(!manager.value){inventory.issue(source,source.path,"access_unavailable");inventory.sources.push_back(source);return;}
    DWORD resume=0;
    do {
        DWORD needed=0,count=0;std::vector<BYTE> data(256*1024);
        BOOL success=EnumServicesStatusExW(manager.value,SC_ENUM_PROCESS_INFO,SERVICE_WIN32,SERVICE_STATE_ALL,data.data(),static_cast<DWORD>(data.size()),&needed,&count,&resume,nullptr);
        DWORD code=success?0:GetLastError();if(code && code!=ERROR_MORE_DATA){inventory.issue(source,source.path,"read_failed");break;}
        auto entries=reinterpret_cast<ENUM_SERVICE_STATUS_PROCESSW *>(data.data());
        for(DWORD index=0;index<count;++index){
            if(!inventory.step(source))break;
            ServiceHandle service;service.value=OpenServiceW(manager.value,entries[index].lpServiceName,SERVICE_QUERY_CONFIG);
            if(!service.value){inventory.issue(source,source.path,"access_unavailable");continue;}
            DWORD size=0;QueryServiceConfigW(service.value,nullptr,0,&size);
            if(!size || size>65536){inventory.issue(source,source.path,"unsupported_schema");continue;}
            std::vector<BYTE> config(size);auto value=reinterpret_cast<QUERY_SERVICE_CONFIGW *>(config.data());
            if(!QueryServiceConfigW(service.value,value,size,&size)){inventory.issue(source,source.path,"read_failed");continue;}
            if(value->dwStartType!=SERVICE_AUTO_START && value->dwStartType!=SERVICE_DISABLED)continue;
            inventory.add(source,L"SCM\\"+std::wstring(entries[index].lpServiceName),entries[index].lpDisplayName,executable(value->lpBinaryPathName,true),value->dwStartType==SERVICE_DISABLED?"disabled":"enabled",entries[index].ServiceStatusProcess.dwCurrentState==SERVICE_RUNNING?"running":entries[index].ServiceStatusProcess.dwCurrentState==SERVICE_STOPPED?"not_running":"unknown",{json("service")});
        }
        if(success || !inventory.available(source))break;
        if(!count){inventory.issue(source,source.path,"resource_limit");break;}
    }while(true);
    inventory.sources.push_back(source);
}
}

extern "C" int shou_win_startup_inventory(int includeSystem,size_t limit,uint32_t milliseconds,shou_win_read_cancelled cancelled,void *context,char **result) {
    if(!result || (includeSystem!=0 && includeSystem!=1) || !limit || limit>10000 || !milliseconds || milliseconds>30000)return ERROR_INVALID_PARAMETER;
    *result=nullptr;
    try {
        Inventory inventory{limit,0,0,GetTickCount64()+milliseconds,cancelled,context,{},{},{}};
        CurrentUser user;ComSession com;
        registry(inventory,HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,"windows.user_run","user");
        registry(inventory,HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",0,"windows.user_run_once","user");
        folder(inventory,FOLDERID_Startup,"windows.user_startup",false);
        if(SUCCEEDED(com.status) || com.status==RPC_E_CHANGED_MODE)tasks(inventory,includeSystem!=0,user);
        else {Source source{"windows.scheduled_tasks","TaskScheduler:\\","scheduled_task","user"};inventory.issue(source,source.path,"access_unavailable");inventory.sources.push_back(source);}
        if(includeSystem){
            registry(inventory,HKEY_LOCAL_MACHINE,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",KEY_WOW64_64KEY,"windows.machine_run64","machine");
            registry(inventory,HKEY_LOCAL_MACHINE,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",KEY_WOW64_64KEY,"windows.machine_run_once64","machine");
            registry(inventory,HKEY_LOCAL_MACHINE,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",KEY_WOW64_32KEY,"windows.machine_run32","machine");
            registry(inventory,HKEY_LOCAL_MACHINE,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",KEY_WOW64_32KEY,"windows.machine_run_once32","machine");
            folder(inventory,FOLDERID_CommonStartup,"windows.machine_startup",true);services(inventory);
        }
        if(cancelled && cancelled(context))throw Error{ERROR_CANCELLED};
        std::vector<std::string> sources;for(const auto &source:inventory.sources)sources.push_back(source.encoded());
        std::string value="{\"sources\":"+array(sources)+",\"items\":"+array(inventory.items)+",\"issues\":"+array(inventory.issues)+",\"unavailable_sources\":[\"packaged_app_startup_tasks\",\"group_policy_scripts\",\"winlogon_extensions\"]}";
        if(value.size()>8*1024*1024)throw Error{ERROR_MORE_DATA};
        *result=static_cast<char *>(std::malloc(value.size()+1));if(!*result)throw Error{ERROR_NOT_ENOUGH_MEMORY};
        std::memcpy(*result,value.c_str(),value.size()+1);return 0;
    }catch(const Error &error){return error.code;}catch(...){return ERROR_NOT_ENOUGH_MEMORY;}
}
extern "C" int shou_win_startup_task_control(const char *input,const char *expected,int enabled,int *writeStarted) {
    if(!input || !expected || std::strlen(expected)!=64 || !writeStarted || (enabled!=0 && enabled!=1))return ERROR_INVALID_PARAMETER;
    *writeStarted=0;
    try {
        auto path=wide(input);
        if(path.empty() || path.front()!=L'\\' || path.size()>4096 || path.find(L"..")!=std::wstring::npos || path.find(L'/')!=std::wstring::npos || _wcsnicmp(path.c_str(),L"\\Microsoft\\",11)==0)return ERROR_ACCESS_DENIED;
        ComSession com;if(FAILED(com.status) && com.status!=RPC_E_CHANGED_MODE)return static_cast<DWORD>(com.status);
        auto service=taskService();BString root(L"\\"),name(path.c_str());ComPtr<ITaskFolder> folder;ComPtr<IRegisteredTask> task;
        if(FAILED(service->GetFolder(root.value,&folder)) || FAILED(folder->GetTask(name.value,&task)))return ERROR_FILE_INVALID;
        CurrentUser user;auto before=taskFacts(task.Get(),user);
        if(!before.own || before.triggers.empty())return ERROR_ACCESS_DENIED;
        if(before.path!=path || before.digest!=expected)return ERROR_FILE_INVALID;
        *writeStarted=1;
        auto changed=task->put_Enabled(enabled?VARIANT_TRUE:VARIANT_FALSE);if(FAILED(changed))return static_cast<DWORD>(changed);
        ComPtr<IRegisteredTask> reread;if(FAILED(folder->GetTask(name.value,&reread)))return ERROR_WRITE_FAULT;
        auto after=taskFacts(reread.Get(),user);
        if(after.path!=before.path || after.owner!=before.owner || after.enabled!=(enabled!=0))return ERROR_WRITE_FAULT;
        // Task Scheduler rewrites only Settings/Enabled. Compare the complete
        // task definition after normalizing that setting through the COM model.
        ComPtr<ITaskDefinition> original,current;ComPtr<ITaskSettings> settings;
        if(FAILED(service->NewTask(0,&original)))return ERROR_WRITE_FAULT;
        BString xml(before.xml.c_str());if(FAILED(original->put_XmlText(xml.value)) || FAILED(original->get_Settings(&settings)) || FAILED(settings->put_Enabled(enabled?VARIANT_TRUE:VARIANT_FALSE)))return ERROR_WRITE_FAULT;
        BString normalized;if(FAILED(original->get_XmlText(&normalized.value)) || FAILED(reread->get_Definition(&current)))return ERROR_WRITE_FAULT;
        BString actual;if(FAILED(current->get_XmlText(&actual.value)) || normalized.text()!=actual.text())return ERROR_WRITE_FAULT;
        return 0;
    }catch(const Error &error){return error.code;}catch(...){return ERROR_NOT_ENOUGH_MEMORY;}
}
