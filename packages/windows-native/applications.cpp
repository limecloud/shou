#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <appmodel.h>
#include <msi.h>
#include <asyncinfo.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.management.deployment.h>
#include <windows.applicationmodel.h>
#include <windows.storage.h>
#include <wtsapi32.h>
#include <bcrypt.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <set>
#include <memory>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace {
struct InventoryError { DWORD code; };
struct Key { HKEY value=nullptr; ~Key(){if(value)RegCloseKey(value);} };
struct WinRT { HRESULT status=RoInitialize(RO_INIT_MULTITHREADED); ~WinRT(){if(SUCCEEDED(status))RoUninitialize();} };
struct Text {
    HSTRING value=nullptr;
    Text()=default;
    explicit Text(const wchar_t *text) { if(FAILED(WindowsCreateString(text,static_cast<UINT32>(wcslen(text)),&value)))throw InventoryError{ERROR_NOT_ENOUGH_MEMORY}; }
    ~Text(){WindowsDeleteString(value);}
    Text(const Text &)=delete;
    Text &operator=(const Text &)=delete;
    std::wstring string()const { UINT32 count=0;auto data=WindowsGetStringRawBuffer(value,&count);return std::wstring(data,count); }
};
std::string utf8(const std::wstring &value) {
    if(value.size()>32768)throw InventoryError{ERROR_MORE_DATA};
    if(value.empty())return {};
    int count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),nullptr,0,nullptr,nullptr);
    if(!count)throw InventoryError{ERROR_NO_UNICODE_TRANSLATION};
    std::string result(count,0);
    if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),result.data(),count,nullptr,nullptr))throw InventoryError{ERROR_NO_UNICODE_TRANSLATION};
    return result;
}
std::string quote(const std::string &value) {
    std::string result="\"";const char hex[]="0123456789abcdef";
    for(unsigned char c:value) {
        if(c=='"'||c=='\\'){result+='\\';result+=static_cast<char>(c);}
        else if(c<32){result+="\\u00";result+=hex[c>>4];result+=hex[c&15];}
        else result+=static_cast<char>(c);
    }
    return result+'"';
}
std::string q(const std::wstring &value){return quote(utf8(value));}
std::string optional(const std::wstring &value){return value.empty()?"null":q(value);}
std::string array(const std::vector<std::string> &rows){std::string result="[";for(const auto &row:rows){if(result.size()>1)result+=',';result+=row;}return result+"]";}
bool printable(const std::wstring &value,size_t limit=32768) {
    return !value.empty() && value.size()<=limit && std::none_of(value.begin(),value.end(),[](wchar_t c){return c<32 || c==127;});
}
std::string hash(const std::string &value) {
    BCRYPT_ALG_HANDLE algorithm=nullptr;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw InventoryError{ERROR_INVALID_DATA};
    BYTE digest[32]{};auto status=BCryptHash(algorithm,nullptr,0,reinterpret_cast<PUCHAR>(const_cast<char *>(value.data())),static_cast<ULONG>(value.size()),digest,32);
    BCryptCloseAlgorithmProvider(algorithm,0);if(status<0)throw InventoryError{ERROR_INVALID_DATA};
    const char hex[]="0123456789abcdef";std::string result;
    for(BYTE c:digest){result+=hex[c>>4];result+=hex[c&15];}return result;
}
std::wstring textValue(HKEY key,const wchar_t *name) {
    DWORD kind=0,count=0;auto status=RegQueryValueExW(key,name,nullptr,&kind,nullptr,&count);
    if(status==ERROR_FILE_NOT_FOUND)return {};
    if(status || (kind!=REG_SZ && kind!=REG_EXPAND_SZ) || count>65536 || count%2)throw InventoryError{ERROR_INVALID_DATA};
    if(!count)return {};
    std::vector<wchar_t> buffer(count/2+1,0);DWORD actual=count;
    if(RegQueryValueExW(key,name,nullptr,&kind,reinterpret_cast<BYTE *>(buffer.data()),&actual)!=ERROR_SUCCESS || actual!=count)throw InventoryError{ERROR_INVALID_DATA};
    std::wstring result(buffer.data(),count/2);while(!result.empty() && result.back()==L'\0')result.pop_back();
    if(!result.empty() && !printable(result))throw InventoryError{ERROR_INVALID_DATA};return result;
}
bool numberValue(HKEY key,const wchar_t *name,DWORD &value) {
    DWORD kind=0,count=sizeof(value);auto status=RegQueryValueExW(key,name,nullptr,&kind,reinterpret_cast<BYTE *>(&value),&count);
    if(status==ERROR_FILE_NOT_FOUND)return false;
    if(status || kind!=REG_DWORD || count!=sizeof(value))throw InventoryError{ERROR_INVALID_DATA};return true;
}
struct Registration {
    std::wstring label,version,publisher,install,command;
    DWORD system=0,noRemove=0,installer=0;
    std::string estimated,evidence;
};
Registration registrationValues(HKEY key,const std::wstring &registration) {
    FILETIME before{},after{};
    if(RegQueryInfoKeyW(key,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&before))throw InventoryError{ERROR_INVALID_DATA};
    Registration item;item.label=textValue(key,L"DisplayName");if(item.label.empty())return item;
    item.version=textValue(key,L"DisplayVersion");item.publisher=textValue(key,L"Publisher");
    item.install=textValue(key,L"InstallLocation");item.command=textValue(key,L"UninstallString");
    if(item.version.size()>256 || item.publisher.size()>512)throw InventoryError{ERROR_INVALID_DATA};
    numberValue(key,L"SystemComponent",item.system);numberValue(key,L"NoRemove",item.noRemove);numberValue(key,L"WindowsInstaller",item.installer);
    DWORD size=0;item.estimated=numberValue(key,L"EstimatedSize",size)?std::to_string(static_cast<uint64_t>(size)*1024):"null";
    if(RegQueryInfoKeyW(key,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&after) || CompareFileTime(&before,&after))throw InventoryError{ERROR_RETRY};
    item.evidence=hash(q(registration)+q(item.label)+q(item.version)+q(item.publisher)+q(item.install)+q(item.command)+std::to_string(item.system)+":"+std::to_string(item.noRemove)+":"+std::to_string(item.installer)+":"+item.estimated);
    return item;
}
std::wstring localDirectory(const std::wstring &input) {
    if(input.empty())return {};
    DWORD count=ExpandEnvironmentStringsW(input.c_str(),nullptr,0);if(!count||count>32768)return {};
    std::wstring value(count,0);if(ExpandEnvironmentStringsW(input.c_str(),value.data(),count)!=count)return {};value.pop_back();
    if(value.size()>=2 && value.front()==L'"' && value.back()==L'"')value=value.substr(1,value.size()-2);
    if(value.size()<3 || value[1]!=L':' || (value[2]!=L'/' && value[2]!=L'\\'))return {};
    std::replace(value.begin(),value.end(),L'\\',L'/');
    if(value.find(L':',2)!=std::wstring::npos || value.find(L"//")!=std::wstring::npos || value.find_first_of(L"*?\"<>|")!=std::wstring::npos || utf8(value).size()>32768)return {};
    for(size_t start=3;start<value.size();) {
        auto end=value.find(L'/',start);auto component=value.substr(start,end==std::wstring::npos?end:end-start);
        if(component==L"." || component==L"..")return {};
        if(end==std::wstring::npos)break;
        start=end+1;
    }
    // This is the declared location only. Do not access installation payloads,
    // network-backed drive mappings or infer directory ownership from a label.
    return value;
}
struct Source {
    std::string id,path,status="complete";bool machine=false;size_t entries=0,applications=0;
    std::string encode()const {return "{\"source\":{\"id\":"+quote(id)+",\"path\":"+quote(path)+",\"system_owned\":"+(machine?"true":"false")+"},\"status\":"+quote(status)+",\"entry_count\":"+std::to_string(entries)+",\"application_count\":"+std::to_string(applications)+"}";}
};
struct Inventory {
    size_t limit,visited=0,bytes=0;ULONGLONG deadline;bool includeSystem;
    shou_win_read_cancelled cancelled;void *context;
    std::vector<std::string> sources,items,issues;std::set<std::string> aliases;
    void issue(Source &source,const std::string &path,const char *code) {
        if(source.status=="complete")source.status="partial";
        if(issues.size()<128)issues.push_back("{\"path\":"+quote(path)+",\"code\":"+quote(code)+"}");
    }
    bool available(Source &source) {
        if(cancelled && cancelled(context))throw InventoryError{ERROR_CANCELLED};
        if(visited>=limit || GetTickCount64()>=deadline || bytes>=6*1024*1024){issue(source,source.path,"resource_limit");return false;}return true;
    }
    bool step(Source &source){if(!available(source))return false;++visited;++source.entries;return true;}
    void add(Source &source,const std::wstring &registration,const std::wstring &name,const std::wstring &version,const std::wstring &publisher,const std::wstring &location,const std::string &size,const char *kind,bool system,const char *uninstall,const std::wstring &family,const std::string &evidence) {
        if(!printable(name,512) || !printable(registration)){issue(source,source.path,"invalid_registration");return;}
        if((!version.empty() && !printable(version,256)) || (!publisher.empty() && !printable(publisher,512))){issue(source,source.path,"invalid_registration");return;}
        if(system && !includeSystem)return;
        // HKCU registry views can resolve to the same physical registration.
        // Retain distinct installations while collapsing identical view aliases.
        auto alias=utf8(registration)+std::string(1,'\0')+evidence;if(!aliases.insert(alias).second)return;
        auto id="sha256:"+hash(source.id+std::string(1,'\0')+utf8(registration));
        std::string row="{\"id\":"+quote(id)+",\"source_id\":"+quote(source.id)+",\"registration\":"+q(registration)+",\"name\":"+q(name)+",\"version\":"+optional(version)+",\"publisher\":"+optional(publisher)+",\"install_location\":"+optional(location)+",\"estimated_bytes\":"+size+",\"kind\":"+quote(kind)+",\"system_component\":"+(system?"true":"false")+",\"uninstall_available\":"+uninstall+",\"package_family_name\":"+optional(family)+",\"evidence_digest\":"+quote(evidence)+"}";
        if(bytes+row.size()>6*1024*1024){bytes=6*1024*1024;issue(source,source.path,"resource_limit");return;}
        bytes+=row.size();items.push_back(row);++source.applications;
    }
};
void registry(Inventory &inventory,HKEY hive,REGSAM view,const char *id) {
    const wchar_t *path=L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
    std::wstring prefix=hive==HKEY_CURRENT_USER?L"HKEY_CURRENT_USER\\":L"HKEY_LOCAL_MACHINE\\";
    prefix+=path;
    Source source{id,utf8(prefix)};source.machine=hive==HKEY_LOCAL_MACHINE;
    if(!inventory.available(source)){source.status="not_scanned";inventory.sources.push_back(source.encode());return;}
    Key root;auto status=RegOpenKeyExW(hive,path,0,KEY_READ|view,&root.value);
    if(status==ERROR_FILE_NOT_FOUND || status==ERROR_PATH_NOT_FOUND)source.status="missing";
    else if(status){source.status="unavailable";inventory.issue(source,source.path,"access_unavailable");}
    else {
        FILETIME before{},after{};auto first=inventory.items.size();auto aliases=inventory.aliases;
        if(RegQueryInfoKeyW(root.value,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&before))inventory.issue(source,source.path,"state_unavailable");
        for(DWORD index=0;;++index) {
            if(!inventory.available(source))break;
            wchar_t name[256];DWORD length=256;
            status=RegEnumKeyExW(root.value,index,name,&length,nullptr,nullptr,nullptr,nullptr);
            if(status==ERROR_NO_MORE_ITEMS)break;
            if(!inventory.step(source))break;
            if(status){inventory.issue(source,source.path,"unreadable_registration");continue;}
            std::wstring leaf(name,length),registration=prefix+L"\\"+leaf;
            try {
                Key key;if(RegOpenKeyExW(root.value,leaf.c_str(),0,KEY_READ|view,&key.value))throw InventoryError{ERROR_ACCESS_DENIED};
                auto item=registrationValues(key.value,registration);if(item.label.empty())continue;
                inventory.add(source,registration,item.label,item.version,item.publisher,localDirectory(item.install),item.estimated,item.installer?"msi":"desktop",item.system!=0,item.noRemove==0 && (!item.command.empty() || item.installer!=0)?"true":"false",L"",item.evidence);
            }catch(const InventoryError &error){inventory.issue(source,utf8(registration),error.code==ERROR_RETRY?"registration_changed":"invalid_registration");}
        }
        if(RegQueryInfoKeyW(root.value,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&after) || CompareFileTime(&before,&after)) {
            inventory.items.resize(first);inventory.aliases=std::move(aliases);source.applications=0;inventory.issue(source,source.path,"source_changed");
        }
    }
    inventory.sources.push_back(source.encode());
}
struct PackageRegistration {
    std::wstring label,family,full,publisher,version;
    bool system=false;
    std::string evidence;
};
PackageRegistration packageValues(ABI::Windows::ApplicationModel::IPackage *package) {
    ComPtr<ABI::Windows::ApplicationModel::IPackageId> identity;
    ComPtr<ABI::Windows::ApplicationModel::IPackage2> details;
    if(FAILED(package->get_Id(&identity)) || FAILED(package->QueryInterface(IID_PPV_ARGS(&details))))throw InventoryError{ERROR_INVALID_DATA};
    Text name,family,full,publisher,display;ABI::Windows::ApplicationModel::PackageVersion version{};
    boolean framework=false,resource=false,bundle=false;
    if(FAILED(identity->get_Name(&name.value)) || FAILED(identity->get_FullName(&full.value)) || FAILED(identity->get_FamilyName(&family.value)) ||
       FAILED(identity->get_Version(&version)) || FAILED(details->get_PublisherDisplayName(&publisher.value)) || FAILED(details->get_DisplayName(&display.value)) ||
       FAILED(package->get_IsFramework(&framework)) || FAILED(details->get_IsResourcePackage(&resource)) || FAILED(details->get_IsBundle(&bundle)))throw InventoryError{ERROR_INVALID_DATA};
    auto label=display.string();if(label.empty())label=name.string();
    auto versionText=std::to_wstring(version.Major)+L"."+std::to_wstring(version.Minor)+L"."+std::to_wstring(version.Build)+L"."+std::to_wstring(version.Revision);
    auto evidence=hash(q(full.string())+q(family.string())+q(label)+q(versionText)+q(publisher.string())+std::to_string(framework)+std::to_string(resource)+std::to_string(bundle));
    return {label,family.string(),full.string(),publisher.string(),versionText,bool(framework||resource||bundle),evidence};
}
ComPtr<ABI::Windows::Management::Deployment::IPackageManager> packageManager() {
    Text className(L"Windows.Management.Deployment.PackageManager");ComPtr<IInspectable> instance;
    if(FAILED(RoActivateInstance(className.value,&instance)))throw InventoryError{ERROR_NOT_SUPPORTED};
    ComPtr<ABI::Windows::Management::Deployment::IPackageManager> manager;
    if(FAILED(instance.As(&manager)))throw InventoryError{ERROR_NOT_SUPPORTED};return manager;
}
void packages(Inventory &inventory) {
    Source source{"windows.user_packages","current_user:PackageManager"};
    if(!inventory.available(source)){source.status="not_scanned";inventory.sources.push_back(source.encode());return;}
    const auto first=inventory.items.size();
    try {
        WinRT runtime;if(FAILED(runtime.status))throw InventoryError{ERROR_NOT_SUPPORTED};
        auto manager=packageManager();
        ComPtr<ABI::Windows::Foundation::Collections::IIterable<ABI::Windows::ApplicationModel::Package *>> collection;
        Text currentUser(L"");
        if(FAILED(manager->FindPackagesByUserSecurityId(currentUser.value,&collection)))throw InventoryError{ERROR_ACCESS_DENIED};
        ComPtr<ABI::Windows::Foundation::Collections::IIterator<ABI::Windows::ApplicationModel::Package *>> iterator;
        if(FAILED(collection->First(&iterator)))throw InventoryError{ERROR_INVALID_DATA};
        boolean available=false;if(FAILED(iterator->get_HasCurrent(&available)))throw InventoryError{ERROR_INVALID_DATA};
        while(available && inventory.step(source)) {
            try {
                ComPtr<ABI::Windows::ApplicationModel::IPackage> package;
                if(FAILED(iterator->get_Current(&package)))throw InventoryError{ERROR_INVALID_DATA};
                auto item=packageValues(package.Get());
                // Installer-owned locations and framework dependencies remain
                // outside file cleanup. No package payload is enumerated here.
                inventory.add(source,item.full,item.label,item.version,item.publisher,L"","null","msix",item.system,"null",item.family,item.evidence);
            }catch(const InventoryError &){inventory.issue(source,source.path,"invalid_package_registration");}
            if(FAILED(iterator->MoveNext(&available)))throw InventoryError{ERROR_INVALID_DATA};
        }
    }catch(const InventoryError &error){if(error.code==ERROR_CANCELLED)throw;inventory.items.resize(first);source.applications=0;source.status="unavailable";inventory.issue(source,source.path,"package_source_unavailable");}
    inventory.sources.push_back(source.encode());
}

std::wstring wide(const char *value) {
    if(!value)throw InventoryError{ERROR_INVALID_PARAMETER};
    auto count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,nullptr,0);
    if(!count || count>32768)throw InventoryError{ERROR_INVALID_PARAMETER};
    std::wstring result(count,0);
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,result.data(),count))throw InventoryError{ERROR_INVALID_PARAMETER};
    result.pop_back();if(!printable(result))throw InventoryError{ERROR_INVALID_PARAMETER};return result;
}
std::wstring argument(const std::wstring &value) {
    std::wstring result=L"\"";size_t slashes=0;
    for(auto c:value){if(c==L'\\'){++slashes;continue;}result.append(c==L'"'?slashes*2+1:slashes,L'\\');result+=c;slashes=0;}
    result.append(slashes*2,L'\\');return result+L'"';
}
bool within(const std::wstring &path,const std::wstring &root) {
    if(root.empty())return false;
    auto base=root;std::replace(base.begin(),base.end(),L'/',L'\\');while(base.size()>3 && base.back()==L'\\')base.pop_back();
    return _wcsicmp(path.c_str(),base.c_str())==0 || (path.size()>base.size() && path[base.size()]==L'\\' && _wcsnicmp(path.c_str(),base.c_str(),base.size())==0);
}
std::wstring normalizedExecutable(const std::wstring &input) {
    if(input.size()<7 || input[1]!=L':' || (input[2]!=L'\\' && input[2]!=L'/') || _wcsicmp(input.substr(input.size()-4).c_str(),L".exe"))throw InventoryError{ERROR_NOT_SUPPORTED};
    char *raw=nullptr;auto code=shou_win_normalize(utf8(input).c_str(),&raw);
    struct Buffer{char *value;~Buffer(){shou_win_free(value);}} release{raw};
    if(code)throw InventoryError{static_cast<DWORD>(code)};auto path=wide(raw);std::replace(path.begin(),path.end(),L'/',L'\\');
    if(GetDriveTypeW(path.substr(0,3).c_str())!=DRIVE_FIXED)throw InventoryError{ERROR_NOT_SUPPORTED};return path;
}
std::string imageEvidence(const shou_win_info &info) {
    std::string value=std::to_string(info.volume)+":";const char hex[]="0123456789abcdef";
    for(auto byte:info.file_id){value+=hex[byte>>4];value+=hex[byte&15];}
    return value+":"+std::to_string(info.logical_bytes)+":"+std::to_string(info.allocated_bytes)+":"+std::to_string(info.modified_ns)+":"+
        std::to_string(info.changed_ns)+":"+std::to_string(info.attributes)+":"+std::to_string(info.links)+":"+std::to_string(info.kind)+":"+info.owner_sid;
}
// Public Windows.Management.Core.IApplicationDataManagerStatics ABI. Keeping
// this single-method declaration also supports SDKs without its generated header.
struct ApplicationDataManagerStatics : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE CreateForPackageFamily(HSTRING family,ABI::Windows::Storage::IApplicationData **data)=0;
};
const IID applicationDataManagerIID={0x1e1862e3,0x698e,0x49a1,{0x97,0x52,0xde,0xe9,0x49,0x25,0xb9,0xb3}};
DWORD packageDataStopped(ULONGLONG deadline,shou_win_read_cancelled cancelled,void *context) {
    return cancelled && cancelled(context)?ERROR_CANCELLED:GetTickCount64()>=deadline?ERROR_TIMEOUT:0;
}
void requirePackageStopped(const std::wstring &family,ULONGLONG deadline,shou_win_read_cancelled cancelled,void *context) {
    HANDLE token=nullptr;if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))throw InventoryError{GetLastError()};
    struct Token{HANDLE value;~Token(){CloseHandle(value);}} closeToken{token};
    DWORD bytes=0;GetTokenInformation(token,TokenUser,nullptr,0,&bytes);
    if(!bytes || bytes>65536)throw InventoryError{ERROR_ACCESS_DENIED};
    std::vector<BYTE> user(bytes);if(!GetTokenInformation(token,TokenUser,user.data(),bytes,&bytes))throw InventoryError{GetLastError()};
    auto sid=reinterpret_cast<TOKEN_USER *>(user.data())->User.Sid;
    PWTS_PROCESS_INFOW processes=nullptr;DWORD count=0;
    if(!WTSEnumerateProcessesW(WTS_CURRENT_SERVER_HANDLE,0,1,&processes,&count))throw InventoryError{GetLastError()};
    struct Processes{PWTS_PROCESS_INFOW value;~Processes(){WTSFreeMemory(value);}} release{processes};
    if(count>20000)throw InventoryError{ERROR_MORE_DATA};
    for(DWORD index=0;index<count;++index) {
        if(auto code=packageDataStopped(deadline,cancelled,context))throw InventoryError{code};
        const auto &entry=processes[index];
        if(entry.ProcessId==0 || entry.ProcessId==4)continue;
        if(!entry.pUserSid)throw InventoryError{ERROR_ACCESS_DENIED};
        if(!EqualSid(sid,entry.pUserSid))continue;
        HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,entry.ProcessId);
        if(!process){if(GetLastError()==ERROR_INVALID_PARAMETER)continue;throw InventoryError{GetLastError()};}
        struct Process{HANDLE value;~Process(){CloseHandle(value);}} closeProcess{process};
        UINT32 length=0;auto code=GetPackageFamilyName(process,&length,nullptr);
        if(code==APPMODEL_ERROR_NO_PACKAGE)continue;
        if(code!=ERROR_INSUFFICIENT_BUFFER || !length || length>256)throw InventoryError{ERROR_ACCESS_DENIED};
        std::vector<wchar_t> name(length);
        if(GetPackageFamilyName(process,&length,name.data())!=ERROR_SUCCESS)throw InventoryError{ERROR_ACCESS_DENIED};
        if(_wcsicmp(name.data(),family.c_str())==0)throw InventoryError{ERROR_BUSY};
    }
}
struct PackageDataRecipe { std::wstring family,path; shou_win_info identity{}; std::string digest; };
PackageDataRecipe packageDataRecipe(const std::wstring &registration,const std::string &evidence,ULONGLONG deadline,shou_win_read_cancelled cancelled,void *context) {
    if(auto code=packageDataStopped(deadline,cancelled,context))throw InventoryError{code};
    auto manager=packageManager();Text user(L""),name(registration.c_str());ComPtr<ABI::Windows::ApplicationModel::IPackage> package;
    if(FAILED(manager->FindPackageByUserSecurityIdPackageFullName(user.value,name.value,&package)) || !package)throw InventoryError{ERROR_NOT_FOUND};
    const auto item=packageValues(package.Get());
    if(item.system || item.full!=registration || item.evidence!=evidence)throw InventoryError{ERROR_FILE_INVALID};
    PackageOrigin origin=PackageOrigin_Unknown;
    if(GetStagedPackageOrigin(registration.c_str(),&origin)!=ERROR_SUCCESS || origin==PackageOrigin_Unknown || origin==PackageOrigin_Inbox)throw InventoryError{ERROR_ACCESS_DENIED};
    UINT32 ownLength=0;auto ownCode=GetCurrentPackageFamilyName(&ownLength,nullptr);
    if(ownCode!=APPMODEL_ERROR_NO_PACKAGE) {
        if(ownCode!=ERROR_INSUFFICIENT_BUFFER || ownLength>256)throw InventoryError{ERROR_ACCESS_DENIED};
        std::vector<wchar_t> own(ownLength);if(GetCurrentPackageFamilyName(&ownLength,own.data())!=ERROR_SUCCESS || _wcsicmp(own.data(),item.family.c_str())==0)throw InventoryError{ERROR_ACCESS_DENIED};
    }
    requirePackageStopped(item.family,deadline,cancelled,context);
    PWSTR local=nullptr;if(FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&local)))throw InventoryError{ERROR_ACCESS_DENIED};
    auto path=std::wstring(local)+L"\\Packages\\"+item.family;CoTaskMemFree(local);
    char *normalized=nullptr;auto code=shou_win_normalize(utf8(path).c_str(),&normalized);
    struct Buffer{char *value;~Buffer(){shou_win_free(value);}} buffer{normalized};
    if(code)throw InventoryError{static_cast<DWORD>(code)};
    PackageDataRecipe recipe;recipe.family=item.family;recipe.path=wide(normalized);
    code=shou_win_stat(normalized,&recipe.identity);
    if(code)throw InventoryError{static_cast<DWORD>(code)};
    if(recipe.identity.kind!=2 || !recipe.identity.current_user)throw InventoryError{ERROR_ACCESS_DENIED};
    recipe.digest=hash(q(registration)+evidence+q(item.family)+q(recipe.path)+imageEvidence(recipe.identity));
    return recipe;
}
bool samePackageDataObject(const shou_win_info &a,const shou_win_info &b) {
    return a.volume==b.volume && !memcmp(a.file_id,b.file_id,16) && !strcmp(a.owner_sid,b.owner_sid) && b.kind==2 && b.current_user;
}
DWORD clearPackageData(const PackageDataRecipe &recipe,ULONGLONG deadline,shou_win_read_cancelled cancelled,void *context,int *started,int *completed) {
    if(auto code=packageDataStopped(deadline,cancelled,context))return code;
    Text className(L"Windows.Management.Core.ApplicationDataManager"),family(recipe.family.c_str());
    ComPtr<ApplicationDataManagerStatics> factory;
    if(FAILED(RoGetActivationFactory(className.value,applicationDataManagerIID,reinterpret_cast<void **>(factory.GetAddressOf()))))return ERROR_NOT_SUPPORTED;
    if(auto code=packageDataStopped(deadline,cancelled,context))return code;
    // Opening a store may initialize it. From here an interrupted call must be
    // reported as uncertain, even if clearing has not returned an async action.
    *started=1;ComPtr<ABI::Windows::Storage::IApplicationData> data;
    if(FAILED(factory->CreateForPackageFamily(family.value,&data)) || !data)return ERROR_PROCESS_ABORTED;
    shou_win_info current{};auto path=utf8(recipe.path);
    auto code=shou_win_stat(path.c_str(),&current);if(code || !samePackageDataObject(recipe.identity,current))return ERROR_FILE_INVALID;
    // Verify the public API resolves this same existing data store. Never call
    // ClearAllAsync for a redirected or unexpected package family directory.
    ComPtr<ABI::Windows::Storage::IStorageFolder> folder;ComPtr<ABI::Windows::Storage::IStorageItem> item;Text local;
    if(FAILED(data->get_LocalFolder(&folder)) || FAILED(folder.As(&item)) || FAILED(item->get_Path(&local.value)))return ERROR_ACCESS_DENIED;
    auto expected=recipe.path+L"/LocalState",actual=local.string();std::replace(actual.begin(),actual.end(),L'\\',L'/');
    if(_wcsicmp(expected.c_str(),actual.c_str()))return ERROR_ACCESS_DENIED;
    if(auto stopped=packageDataStopped(deadline,cancelled,context))return stopped;
    ComPtr<ABI::Windows::Foundation::IAsyncAction> operation;
    if(FAILED(data->ClearAllAsync(&operation)) || !operation)return ERROR_PROCESS_ABORTED;
    ComPtr<IAsyncInfo> info;if(FAILED(operation.As(&info)))return ERROR_IO_INCOMPLETE;
    while(true) {
        if(auto stopped=packageDataStopped(deadline,cancelled,context))return stopped;
        AsyncStatus status{};if(FAILED(info->get_Status(&status)))return ERROR_IO_INCOMPLETE;
        if(status==Completed){if(FAILED(operation->GetResults()))return ERROR_PROCESS_ABORTED;*completed=1;return 0;}
        if(status==Canceled)return ERROR_CANCELLED;if(status==Error)return ERROR_PROCESS_ABORTED;Sleep(25);
    }
}
std::wstring installerProperty(const wchar_t *product,MSIINSTALLCONTEXT context,const wchar_t *property) {
    DWORD count=0;auto code=MsiGetProductInfoExW(product,nullptr,context,property,nullptr,&count);
    if((code!=ERROR_SUCCESS && code!=ERROR_MORE_DATA) || count>32768)throw InventoryError{ERROR_NOT_SUPPORTED};
    std::vector<wchar_t> buffer(count+1);DWORD actual=static_cast<DWORD>(buffer.size());
    if(MsiGetProductInfoExW(product,nullptr,context,property,buffer.data(),&actual)!=ERROR_SUCCESS || actual!=count)throw InventoryError{ERROR_FILE_INVALID};
    return std::wstring(buffer.data(),actual);
}
std::string installerProductEvidence(const wchar_t *product,bool machine,const Registration &registration) {
    // A user-controlled uninstall key must not redirect a reviewed name to a
    // different MSI product or cross from a user install to a machine install.
    const std::vector<MSIINSTALLCONTEXT> contexts=machine?std::vector<MSIINSTALLCONTEXT>{MSIINSTALLCONTEXT_MACHINE}:
        std::vector<MSIINSTALLCONTEXT>{MSIINSTALLCONTEXT_USERMANAGED,MSIINSTALLCONTEXT_USERUNMANAGED};
    std::vector<std::string> matches;
    for(auto context:contexts) {
        try {
            if(installerProperty(product,context,L"State")!=L"5")continue;
            const auto name=installerProperty(product,context,L"InstalledProductName"),version=installerProperty(product,context,L"VersionString"),publisher=installerProperty(product,context,L"Publisher");
            if(name!=registration.label || version!=registration.version || publisher!=registration.publisher)continue;
            matches.push_back(std::to_string(context)+q(name)+q(version)+q(publisher));
        }catch(const InventoryError &){continue;}
    }
    if(matches.size()!=1)throw InventoryError{ERROR_NOT_SUPPORTED};return matches.front();
}
struct UninstallRecipe {
    std::string route,digest;
    std::wstring executable,registration;
    std::vector<std::wstring> arguments;
    std::unique_ptr<shou_win_managed_image,decltype(&shou_win_managed_image_release)> image{nullptr,shou_win_managed_image_release};
};
UninstallRecipe uninstallRecipe(const std::string &source,const std::wstring &registration,const std::string &expected) {
    UninstallRecipe recipe;recipe.registration=registration;
    if(source=="windows.user_packages") {
        WinRT runtime;if(FAILED(runtime.status))throw InventoryError{ERROR_NOT_SUPPORTED};
        auto manager=packageManager();Text user(L""),name(registration.c_str());ComPtr<ABI::Windows::ApplicationModel::IPackage> package;
        if(FAILED(manager->FindPackageByUserSecurityIdPackageFullName(user.value,name.value,&package)) || !package)throw InventoryError{ERROR_NOT_FOUND};
        auto item=packageValues(package.Get());if(item.system || item.full!=registration || item.evidence!=expected)throw InventoryError{ERROR_FILE_INVALID};
        UINT32 count=0;auto status=GetCurrentPackageFullName(&count,nullptr);
        if(status==ERROR_INSUFFICIENT_BUFFER) {
            std::vector<wchar_t> current(count);if(GetCurrentPackageFullName(&count,current.data())!=ERROR_SUCCESS)throw InventoryError{ERROR_ACCESS_DENIED};
            if(_wcsicmp(current.data(),registration.c_str())==0)throw InventoryError{ERROR_ACCESS_DENIED};
        } else if(status!=APPMODEL_ERROR_NO_PACKAGE)throw InventoryError{ERROR_ACCESS_DENIED};
        recipe.route="msix";recipe.digest=hash(source+q(registration)+expected+q(item.family));return recipe;
    }
    HKEY hive=nullptr;REGSAM view=0;
    if(source=="windows.user_uninstall64"){hive=HKEY_CURRENT_USER;view=KEY_WOW64_64KEY;}
    else if(source=="windows.user_uninstall32"){hive=HKEY_CURRENT_USER;view=KEY_WOW64_32KEY;}
    else if(source=="windows.machine_uninstall64"){hive=HKEY_LOCAL_MACHINE;view=KEY_WOW64_64KEY;}
    else if(source=="windows.machine_uninstall32"){hive=HKEY_LOCAL_MACHINE;view=KEY_WOW64_32KEY;}
    else throw InventoryError{ERROR_INVALID_PARAMETER};
    std::wstring keyPath=L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\";
    std::wstring prefix=(hive==HKEY_CURRENT_USER?L"HKEY_CURRENT_USER\\":L"HKEY_LOCAL_MACHINE\\")+keyPath;
    if(registration.compare(0,prefix.size(),prefix)!=0)throw InventoryError{ERROR_INVALID_PARAMETER};
    auto leaf=registration.substr(prefix.size());if(leaf.empty() || leaf.find_first_of(L"\\/")!=std::wstring::npos)throw InventoryError{ERROR_INVALID_PARAMETER};
    Key key;auto code=RegOpenKeyExW(hive,(keyPath+leaf).c_str(),0,KEY_READ|view,&key.value);if(code)throw InventoryError{static_cast<DWORD>(code)};
    auto item=registrationValues(key.value,registration);
    if(item.label.empty() || item.system || item.noRemove || item.evidence!=expected)throw InventoryError{ERROR_FILE_INVALID};
    wchar_t current[32768]{};if(!GetModuleFileNameW(nullptr,current,32768))throw InventoryError{ERROR_ACCESS_DENIED};
    if(within(current,localDirectory(item.install)))throw InventoryError{ERROR_ACCESS_DENIED};
    std::string productEvidence;
    if(item.installer) {
        GUID product{};wchar_t canonical[40]{};
        if(leaf.size()!=38 || FAILED(CLSIDFromString(leaf.c_str(),&product)) || !StringFromGUID2(product,canonical,40) || _wcsicmp(leaf.c_str(),canonical))throw InventoryError{ERROR_NOT_SUPPORTED};
        productEvidence=installerProductEvidence(canonical,hive==HKEY_LOCAL_MACHINE,item);
        wchar_t system[32768]{};if(!GetSystemDirectoryW(system,32768))throw InventoryError{ERROR_ACCESS_DENIED};
        recipe.route="msi";recipe.executable=normalizedExecutable(std::wstring(system)+L"\\msiexec.exe");recipe.arguments={L"/x",canonical,L"/norestart"};
    } else {
        if(item.command.empty())throw InventoryError{ERROR_NOT_SUPPORTED};
        auto size=ExpandEnvironmentStringsW(item.command.c_str(),nullptr,0);if(!size || size>32768)throw InventoryError{ERROR_INVALID_DATA};
        std::wstring command(size,0);if(ExpandEnvironmentStringsW(item.command.c_str(),command.data(),size)!=size)throw InventoryError{ERROR_INVALID_DATA};command.pop_back();
        int count=0;auto argv=CommandLineToArgvW(command.c_str(),&count);
        struct Args{wchar_t **value;~Args(){LocalFree(value);}} release{argv};
        if(!argv || count<1 || count>128)throw InventoryError{ERROR_NOT_SUPPORTED};
        recipe.route="desktop";recipe.executable=normalizedExecutable(argv[0]);
        wchar_t windows[32768]{};if(!GetWindowsDirectoryW(windows,32768))throw InventoryError{ERROR_ACCESS_DENIED};
        // System command interpreters and helper utilities are not vendor
        // uninstall executables. Never turn registry text into a shell call.
        if(within(recipe.executable,windows))throw InventoryError{ERROR_NOT_SUPPORTED};
        for(int index=1;index<count;++index)recipe.arguments.emplace_back(argv[index]);
    }
    if(_wcsicmp(recipe.executable.c_str(),current)==0)throw InventoryError{ERROR_ACCESS_DENIED};
    shou_win_info info{};shou_win_managed_image *image=nullptr;
    code=shou_win_managed_image_acquire(utf8(recipe.executable).c_str(),&info,&image);recipe.image.reset(image);if(code)throw InventoryError{static_cast<DWORD>(code)};
    std::string args;for(const auto &value:recipe.arguments)args+=q(value);
    recipe.digest=hash(source+q(registration)+expected+recipe.route+q(recipe.executable)+args+imageEvidence(info)+productEvidence);return recipe;
}
std::vector<wchar_t> installerEnvironment() {
    // Vendor installers receive standard Windows locations, not the desktop
    // process's AI credentials, runtime hooks or command injection variables.
    auto folder=[](REFKNOWNFOLDERID id) { PWSTR raw=nullptr;if(FAILED(SHGetKnownFolderPath(id,0,nullptr,&raw)))throw InventoryError{ERROR_ACCESS_DENIED};std::wstring result=raw;CoTaskMemFree(raw);return result; };
    const auto home=folder(FOLDERID_Profile),local=folder(FOLDERID_LocalAppData);
    std::vector<std::wstring> values={L"USERPROFILE="+home,L"APPDATA="+folder(FOLDERID_RoamingAppData),L"LOCALAPPDATA="+local,
        L"ProgramFiles="+folder(FOLDERID_ProgramFiles),L"ProgramFiles(x86)="+folder(FOLDERID_ProgramFilesX86),L"ProgramData="+folder(FOLDERID_ProgramData),
        L"PUBLIC="+folder(FOLDERID_Public),L"TEMP="+local+L"\\Temp",L"TMP="+local+L"\\Temp",L"HOMEDRIVE="+home.substr(0,2),L"HOMEPATH="+home.substr(2)};
    wchar_t windows[32768]{};if(!GetWindowsDirectoryW(windows,32768))throw InventoryError{ERROR_ACCESS_DENIED};
    values.emplace_back(L"SystemRoot="+std::wstring(windows));values.emplace_back(L"WINDIR="+std::wstring(windows));
    values.emplace_back(L"PATH="+std::wstring(windows)+L"\\System32;"+windows);values.emplace_back(L"COMSPEC="+std::wstring(windows)+L"\\System32\\cmd.exe");
    std::sort(values.begin(),values.end(),[](const auto &a,const auto &b){return _wcsicmp(a.c_str(),b.c_str())<0;});
    std::vector<wchar_t> result;for(const auto &value:values){result.insert(result.end(),value.begin(),value.end());result.push_back(0);}result.push_back(0);return result;
}
DWORD runInstaller(UninstallRecipe &recipe,ULONGLONG deadline,shou_win_read_cancelled cancelled,void *context,int *started,uint32_t *exitCode,int *restart) {
    auto stopped=[&]()->DWORD { return cancelled && cancelled(context)?ERROR_CANCELLED:GetTickCount64()>=deadline?ERROR_TIMEOUT:0; };
    if(auto code=stopped())return code;
    if(recipe.route=="msix") {
        WinRT runtime;if(FAILED(runtime.status))return ERROR_NOT_SUPPORTED;
        auto manager=packageManager();Text name(recipe.registration.c_str());
        using Operation=ABI::Windows::Foundation::IAsyncOperationWithProgress<ABI::Windows::Management::Deployment::DeploymentResult*,ABI::Windows::Management::Deployment::DeploymentProgress>;
        ComPtr<Operation> operation;if(auto code=stopped())return code;*started=1;
        if(FAILED(manager->RemovePackageAsync(name.value,&operation)))return ERROR_PROCESS_ABORTED;
        ComPtr<IAsyncInfo> info;if(FAILED(operation.As(&info)))return ERROR_IO_INCOMPLETE;
        while(true) {
            if(auto code=stopped())return code;
            AsyncStatus state{};if(FAILED(info->get_Status(&state)))return ERROR_IO_INCOMPLETE;
            if(state==Completed){
                ComPtr<ABI::Windows::Management::Deployment::IDeploymentResult> result;
                if(FAILED(operation->GetResults(&result)))return ERROR_PROCESS_ABORTED;
                HRESULT error=S_OK;if(!result || FAILED(result->get_ExtendedErrorCode(&error)) || FAILED(error))return ERROR_PROCESS_ABORTED;
                *exitCode=0;return 0;
            }
            if(state==Canceled)return ERROR_CANCELLED;if(state==Error)return ERROR_PROCESS_ABORTED;Sleep(25);
        }
    }
    auto command=argument(recipe.executable);std::wstring parameters;
    for(const auto &value:recipe.arguments){command+=L" "+argument(value);if(!parameters.empty())parameters+=L' ';parameters+=argument(value);}
    if(command.size()>32766)return ERROR_MORE_DATA;
    auto environment=installerEnvironment();auto directory=recipe.executable.substr(0,recipe.executable.find_last_of(L'\\'));
    STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};HANDLE process=nullptr;
    if(auto code=stopped())return code;
    if(CreateProcessW(recipe.executable.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_UNICODE_ENVIRONMENT,environment.data(),directory.c_str(),&startup,&child)) {
        *started=1;process=child.hProcess;CloseHandle(child.hThread);
    } else {
        auto code=GetLastError();if(code!=ERROR_ELEVATION_REQUIRED)return code;
        if((code=stopped()))return code;
        SHELLEXECUTEINFOW launch{};launch.cbSize=sizeof(launch);launch.fMask=SEE_MASK_NOCLOSEPROCESS|SEE_MASK_NOASYNC|SEE_MASK_FLAG_NO_UI;
        launch.lpVerb=L"runas";launch.lpFile=recipe.executable.c_str();launch.lpParameters=parameters.c_str();launch.lpDirectory=directory.c_str();launch.nShow=SW_SHOWNORMAL;
        // Windows owns the consent and elevated environment. The desktop
        // application remains asInvoker and never caches administrator access.
        if(!ShellExecuteExW(&launch))return GetLastError();*started=1;process=launch.hProcess;if(!process)return ERROR_IO_INCOMPLETE;
    }
    struct Process{HANDLE value;~Process(){CloseHandle(value);}} release{process};
    // The image is mapped now. Release ancestor pins so the official
    // uninstaller can remove its own installation directory normally.
    recipe.image.reset();
    while(true) {
        if(auto code=stopped())return code;
        auto state=WaitForSingleObject(process,25);if(state==WAIT_FAILED)return GetLastError();if(state==WAIT_OBJECT_0)break;
    }
    DWORD code=0;if(!GetExitCodeProcess(process,&code))return GetLastError();*exitCode=code;
    if(recipe.route=="msi" && (code==3010 || code==1641)){*restart=1;return 0;}
    return code==0?0:code==1602?ERROR_CANCELLED:ERROR_PROCESS_ABORTED;
}
}
extern "C" int shou_win_application_inventory(int includeSystem,size_t limit,uint32_t milliseconds,shou_win_read_cancelled cancelled,void *context,char **result) {
    if(!result || !limit || limit>20000 || !milliseconds || milliseconds>30000)return ERROR_INVALID_PARAMETER;
    *result=nullptr;
    try {
        Inventory inventory{limit,0,0,GetTickCount64()+milliseconds,includeSystem!=0,cancelled,context,{},{},{},{}};
        // Normal machine-wide programs are included without elevation. The
        // option only reveals hidden/system components and package dependencies.
        registry(inventory,HKEY_CURRENT_USER,KEY_WOW64_64KEY,"windows.user_uninstall64");
        registry(inventory,HKEY_CURRENT_USER,KEY_WOW64_32KEY,"windows.user_uninstall32");
        registry(inventory,HKEY_LOCAL_MACHINE,KEY_WOW64_64KEY,"windows.machine_uninstall64");
        registry(inventory,HKEY_LOCAL_MACHINE,KEY_WOW64_32KEY,"windows.machine_uninstall32");
        packages(inventory);
        if(cancelled && cancelled(context))return ERROR_CANCELLED;
        auto output="{\"sources\":"+array(inventory.sources)+",\"items\":"+array(inventory.items)+",\"issues\":"+array(inventory.issues)+"}";
        *result=static_cast<char *>(std::malloc(output.size()+1));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;
        std::memcpy(*result,output.c_str(),output.size()+1);return 0;
    }catch(const InventoryError &error){return error.code;}catch(...){return ERROR_NOT_ENOUGH_MEMORY;}
}

extern "C" int shou_win_application_uninstall_review(const char *source,const char *registration,const char *evidence,char **result) {
    if(!source || !registration || !evidence || !result || strlen(source)>64 || strlen(evidence)!=64)return ERROR_INVALID_PARAMETER;*result=nullptr;
    try {
        auto recipe=uninstallRecipe(source,wide(registration),evidence);auto executable=recipe.executable;std::replace(executable.begin(),executable.end(),L'\\',L'/');
        auto output="{\"route\":"+quote(recipe.route)+",\"executable_path\":"+optional(executable)+",\"action_digest\":"+quote(recipe.digest)+"}";
        *result=static_cast<char *>(malloc(output.size()+1));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;memcpy(*result,output.c_str(),output.size()+1);return 0;
    }catch(const InventoryError &error){return error.code;}catch(...){return ERROR_NOT_ENOUGH_MEMORY;}
}
extern "C" int shou_win_application_uninstall_execute(const char *source,const char *registration,const char *evidence,const char *actionDigest,
    uint32_t milliseconds,shou_win_read_cancelled cancelled,void *context,int *started,uint32_t *exitCode,int *restart) {
    if(!source || !registration || !evidence || !actionDigest || !started || !exitCode || !restart || milliseconds<1000 || milliseconds>900000 || strlen(source)>64 || strlen(evidence)!=64 || strlen(actionDigest)!=64)return ERROR_INVALID_PARAMETER;
    *started=0;*exitCode=UINT32_MAX;*restart=0;auto deadline=GetTickCount64()+milliseconds;
    if(cancelled && cancelled(context))return ERROR_CANCELLED;
    try {
        auto recipe=uninstallRecipe(source,wide(registration),evidence);
        if(recipe.digest!=actionDigest)return ERROR_FILE_INVALID;
        return runInstaller(recipe,deadline,cancelled,context,started,exitCode,restart);
    }catch(const InventoryError &error){return error.code;}catch(...){return ERROR_NOT_ENOUGH_MEMORY;}
}
extern "C" int shou_win_package_data_review(const char *registration,const char *evidence,shou_win_read_cancelled cancelled,void *context,shou_win_info *identity,char **result) {
    if(!registration || !evidence || !identity || !result || strlen(registration)>32768 || strlen(evidence)!=64)return ERROR_INVALID_PARAMETER;
    *result=nullptr;*identity={};
    if(cancelled && cancelled(context))return ERROR_CANCELLED;
    try {
        WinRT runtime;if(FAILED(runtime.status))return ERROR_NOT_SUPPORTED;
        auto recipe=packageDataRecipe(wide(registration),evidence,GetTickCount64()+5000,cancelled,context);
        auto output="{\"data_path\":"+q(recipe.path)+",\"action_digest\":"+quote(recipe.digest)+"}";
        *result=static_cast<char *>(malloc(output.size()+1));if(!*result)return ERROR_NOT_ENOUGH_MEMORY;
        memcpy(*result,output.c_str(),output.size()+1);*identity=recipe.identity;return 0;
    }catch(const InventoryError &error){return error.code;}catch(...){return ERROR_NOT_ENOUGH_MEMORY;}
}
extern "C" int shou_win_package_data_clear(const char *registration,const char *evidence,const char *actionDigest,
    uint32_t milliseconds,shou_win_read_cancelled cancelled,void *context,int *started,int *completed) {
    if(!registration || !evidence || !actionDigest || !started || !completed || strlen(registration)>32768 || strlen(evidence)!=64 || strlen(actionDigest)!=64 || milliseconds<1000 || milliseconds>120000)return ERROR_INVALID_PARAMETER;
    *started=0;*completed=0;auto deadline=GetTickCount64()+milliseconds;
    if(cancelled && cancelled(context))return ERROR_CANCELLED;
    try {
        WinRT runtime;if(FAILED(runtime.status))return ERROR_NOT_SUPPORTED;
        auto recipe=packageDataRecipe(wide(registration),evidence,deadline,cancelled,context);
        if(recipe.digest!=actionDigest)return ERROR_FILE_INVALID;
        return clearPackageData(recipe,deadline,cancelled,context,started,completed);
    }catch(const InventoryError &error){return error.code;}catch(...){return ERROR_NOT_ENOUGH_MEMORY;}
}
