#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.management.deployment.h>
#include <windows.applicationmodel.h>
#include <bcrypt.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <set>
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
                FILETIME entryBefore{},entryAfter{};
                if(RegQueryInfoKeyW(key.value,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&entryBefore))throw InventoryError{ERROR_INVALID_DATA};
                auto label=textValue(key.value,L"DisplayName");if(label.empty())continue;
                auto version=textValue(key.value,L"DisplayVersion"),publisher=textValue(key.value,L"Publisher");
                if(version.size()>256 || publisher.size()>512)throw InventoryError{ERROR_INVALID_DATA};
                auto install=textValue(key.value,L"InstallLocation"),command=textValue(key.value,L"UninstallString");
                DWORD system=0,noRemove=0,installer=0,size=0;
                numberValue(key.value,L"SystemComponent",system);numberValue(key.value,L"NoRemove",noRemove);numberValue(key.value,L"WindowsInstaller",installer);
                auto estimated=numberValue(key.value,L"EstimatedSize",size)?std::to_string(static_cast<uint64_t>(size)*1024):"null";
                if(RegQueryInfoKeyW(key.value,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&entryAfter) || CompareFileTime(&entryBefore,&entryAfter))throw InventoryError{ERROR_RETRY};
                auto evidence=hash(q(registration)+q(label)+q(version)+q(publisher)+q(install)+q(command)+std::to_string(system)+":"+std::to_string(noRemove)+":"+std::to_string(installer)+":"+estimated);
                inventory.add(source,registration,label,version,publisher,localDirectory(install),estimated,installer?"msi":"desktop",system!=0,noRemove==0 && (!command.empty() || installer!=0)?"true":"false",L"",evidence);
            }catch(const InventoryError &error){inventory.issue(source,utf8(registration),error.code==ERROR_RETRY?"registration_changed":"invalid_registration");}
        }
        if(RegQueryInfoKeyW(root.value,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,&after) || CompareFileTime(&before,&after)) {
            inventory.items.resize(first);inventory.aliases=std::move(aliases);source.applications=0;inventory.issue(source,source.path,"source_changed");
        }
    }
    inventory.sources.push_back(source.encode());
}
void packages(Inventory &inventory) {
    Source source{"windows.user_packages","current_user:PackageManager"};
    if(!inventory.available(source)){source.status="not_scanned";inventory.sources.push_back(source.encode());return;}
    const auto first=inventory.items.size();
    try {
        WinRT runtime;if(FAILED(runtime.status))throw InventoryError{ERROR_NOT_SUPPORTED};
        Text className(L"Windows.Management.Deployment.PackageManager");ComPtr<IInspectable> instance;
        if(FAILED(RoActivateInstance(className.value,&instance)))throw InventoryError{ERROR_NOT_SUPPORTED};
        ComPtr<ABI::Windows::Management::Deployment::IPackageManager> manager;
        if(FAILED(instance.As(&manager)))throw InventoryError{ERROR_NOT_SUPPORTED};
        ComPtr<ABI::Windows::Foundation::Collections::IIterable<ABI::Windows::ApplicationModel::Package *>> collection;
        Text currentUser(L"");
        if(FAILED(manager->FindPackagesByUserSecurityId(currentUser.value,&collection)))throw InventoryError{ERROR_ACCESS_DENIED};
        ComPtr<ABI::Windows::Foundation::Collections::IIterator<ABI::Windows::ApplicationModel::Package *>> iterator;
        if(FAILED(collection->First(&iterator)))throw InventoryError{ERROR_INVALID_DATA};
        boolean available=false;if(FAILED(iterator->get_HasCurrent(&available)))throw InventoryError{ERROR_INVALID_DATA};
        while(available && inventory.step(source)) {
            try {
                ComPtr<ABI::Windows::ApplicationModel::IPackage> package;
                ComPtr<ABI::Windows::ApplicationModel::IPackageId> identity;
                ComPtr<ABI::Windows::ApplicationModel::IPackage2> details;
                if(FAILED(iterator->get_Current(&package)) || FAILED(package->get_Id(&identity)) || FAILED(package.As(&details)))throw InventoryError{ERROR_INVALID_DATA};
                Text name,family,full,publisher;ABI::Windows::ApplicationModel::PackageVersion version{};
                boolean framework=false,resource=false,bundle=false;
                if(FAILED(identity->get_Name(&name.value)) || FAILED(identity->get_FullName(&full.value)) || FAILED(identity->get_FamilyName(&family.value)) ||
                   FAILED(identity->get_Version(&version)) || FAILED(details->get_PublisherDisplayName(&publisher.value)) ||
                   FAILED(package->get_IsFramework(&framework)) || FAILED(details->get_IsResourcePackage(&resource)) || FAILED(details->get_IsBundle(&bundle)))throw InventoryError{ERROR_INVALID_DATA};
                Text display;if(FAILED(details->get_DisplayName(&display.value)))throw InventoryError{ERROR_INVALID_DATA};
                auto label=display.string();if(label.empty())label=name.string();
                auto versionText=std::to_wstring(version.Major)+L"."+std::to_wstring(version.Minor)+L"."+std::to_wstring(version.Build)+L"."+std::to_wstring(version.Revision);
                auto evidence=hash(q(full.string())+q(family.string())+q(label)+q(versionText)+q(publisher.string())+std::to_string(framework)+std::to_string(resource)+std::to_string(bundle));
                // Installer-owned locations and framework dependencies remain
                // outside file cleanup. No package payload is enumerated here.
                inventory.add(source,full.string(),label,versionText,publisher.string(),L"","null","msix",framework||resource||bundle,"null",family.string(),evidence);
            }catch(const InventoryError &){inventory.issue(source,source.path,"invalid_package_registration");}
            if(FAILED(iterator->MoveNext(&available)))throw InventoryError{ERROR_INVALID_DATA};
        }
    }catch(const InventoryError &error){if(error.code==ERROR_CANCELLED)throw;inventory.items.resize(first);source.applications=0;source.status="unavailable";inventory.issue(source,source.path,"package_source_unavailable");}
    inventory.sources.push_back(source.encode());
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
