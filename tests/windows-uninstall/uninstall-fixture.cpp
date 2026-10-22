// Only a generated copy of this fixture is launched. Registry lookups are
// redirected inside this process to exclusively generated test keys.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <shellapi.h>
#include <objbase.h>
#include <bcrypt.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>
#include <utility>

namespace {
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
std::string utf8(const std::wstring &value){auto size=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,nullptr,0,nullptr,nullptr);require(size>0,"UTF-8 conversion failed");std::string result(size,0);WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,result.data(),size,nullptr,nullptr);result.pop_back();return result;}
std::string quote(const std::wstring &value){std::string result="\"";for(auto c:utf8(value)){if(c=='"'||c=='\\')result+='\\';result+=c;}return result+'"';}
std::string hash(const std::string &value){BCRYPT_ALG_HANDLE algorithm=nullptr;require(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0,"Hash provider failed");BYTE digest[32]{};auto status=BCryptHash(algorithm,nullptr,0,reinterpret_cast<PUCHAR>(const_cast<char *>(value.data())),static_cast<ULONG>(value.size()),digest,32);BCryptCloseAlgorithmProvider(algorithm,0);require(status>=0,"Hash failed");std::string result;const char hex[]="0123456789abcdef";for(auto byte:digest){result+=hex[byte>>4];result+=hex[byte&15];}return result;}
void write(const std::wstring &path,const char *text){auto file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,0,nullptr);require(file!=INVALID_HANDLE_VALUE,"Generated file creation failed");DWORD written=0;auto size=static_cast<DWORD>(strlen(text));auto ok=WriteFile(file,text,size,&written,nullptr);CloseHandle(file);require(ok && written==size,"Generated file write failed");}
bool exists(const std::wstring &path){return GetFileAttributesW(path.c_str())!=INVALID_FILE_ATTRIBUTES;}
struct Fixture {
    std::wstring home,image,keyPath,registration=L"HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Generated";
    HKEY root=nullptr,key=nullptr;bool overridden=false;
    Fixture(const std::wstring &module){
        try {
            wchar_t temp[32768]{};require(GetTempPathW(32768,temp)>0,"Temp directory failed");
            GUID id{};wchar_t unique[40]{};require(SUCCEEDED(CoCreateGuid(&id)) && StringFromGUID2(id,unique,40)>0,"Fixture identity failed");
            home=std::wstring(temp)+L"shou-generated-uninstall-"+unique;require(shou_win_private_directory(utf8(home).c_str())==0,"Private fixture directory failed");
            image=home+L"\\uninstall.exe";require(CopyFileW(module.c_str(),image.c_str(),TRUE),"Generated image copy failed");
            keyPath=L"Software\\Shou\\GeneratedUninstallFixtures\\"+std::wstring(unique);
            require(RegCreateKeyExW(HKEY_CURRENT_USER,keyPath.c_str(),0,nullptr,0,KEY_ALL_ACCESS,nullptr,&root,nullptr)==ERROR_SUCCESS,"Generated registry root failed");
            require(RegCreateKeyExW(root,L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Generated",0,nullptr,0,KEY_ALL_ACCESS,nullptr,&key,nullptr)==ERROR_SUCCESS,"Generated registration failed");
            set(L"DisplayName",L"Generated fixture");set(L"DisplayVersion",L"1.0");set(L"Publisher",L"Generated fixture publisher");set(L"InstallLocation",home);
            require(RegOverridePredefKey(HKEY_CURRENT_USER,root)==ERROR_SUCCESS,"Registry redirection failed");overridden=true;
            write(home+L"\\retained.txt","generated retained sibling");
        }catch(...){release();throw;}
    }
    void set(const wchar_t *name,const std::wstring &value){require(RegSetValueExW(key,name,0,REG_SZ,reinterpret_cast<const BYTE *>(value.c_str()),static_cast<DWORD>((value.size()+1)*sizeof(wchar_t)))==ERROR_SUCCESS,"Generated registration write failed");}
    std::string command(const std::wstring &value){set(L"UninstallString",value);return hash(quote(registration)+quote(L"Generated fixture")+quote(L"1.0")+quote(L"Generated fixture publisher")+quote(home)+quote(value)+"0:0:0:null");}
    std::pair<int,std::string> review(const std::string &evidence){char *raw=nullptr;auto code=shou_win_application_uninstall_review("windows.user_uninstall64",utf8(registration).c_str(),evidence.c_str(),&raw);std::string value=raw?raw:"";shou_win_free(raw);return {code,value};}
    std::string action(const std::string &evidence){auto result=review(evidence);require(result.first==0,"Generated installer review failed");const std::string prefix="\"action_digest\":\"";auto start=result.second.find(prefix);require(start!=std::string::npos,"Action identity missing");return result.second.substr(start+prefix.size(),64);}
    int run(const std::string &evidence,const std::string &action,int &started,uint32_t &exit,uint32_t timeout=5000,shou_win_read_cancelled cancel=nullptr){int restart=0;return shou_win_application_uninstall_execute("windows.user_uninstall64",utf8(registration).c_str(),evidence.c_str(),action.c_str(),timeout,cancel,nullptr,&started,&exit,&restart);}
    void release(){if(overridden)RegOverridePredefKey(HKEY_CURRENT_USER,nullptr);overridden=false;if(key)RegCloseKey(key);key=nullptr;if(root)RegCloseKey(root);root=nullptr;if(!keyPath.empty())RegDeleteTreeW(HKEY_CURRENT_USER,keyPath.c_str());for(auto name:{L"uninstall.exe",L"uninstall.original.exe",L"uninstall.alias.exe",L".invoked",L".finished",L"retained.txt"})DeleteFileW((home+L"\\"+name).c_str());if(!home.empty())RemoveDirectoryW(home.c_str());}
    ~Fixture(){release();}
};
}
int main(){
    wchar_t raw[32768]{};auto size=GetModuleFileNameW(nullptr,raw,32768);if(!size || size>=32768)return 1;std::wstring module=raw;
    if(!_wcsicmp(module.substr(module.find_last_of(L'\\')+1).c_str(),L"uninstall.exe")) {
        auto home=module.substr(0,module.find_last_of(L'\\'));int count=0;auto args=CommandLineToArgvW(GetCommandLineW(),&count);if(!args)return 9;
        std::wstring mode=count==2?args[1]:L"";LocalFree(args);if(mode!=L"--generated-normal" && mode!=L"--generated-fail" && mode!=L"--generated-wait")return 9;
        write(home+L"\\.invoked","generated fixture started");if(mode==L"--generated-wait"){Sleep(2000);write(home+L"\\.finished","generated installer continued");}return mode==L"--generated-fail"?7:0;
    }
    HANDLE token=nullptr;TOKEN_ELEVATION elevated{};DWORD bytes=0;if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return 1;
    auto inspected=GetTokenInformation(token,TokenElevation,&elevated,sizeof(elevated),&bytes);CloseHandle(token);if(!inspected)return 1;
    if(elevated.TokenIsElevated){std::puts("NOT RUN: generated installer fixtures require a standard-user session.");return 77;}
    try {
        Fixture fixture(module);int started=0;uint32_t exit=0;
        auto evidence=fixture.command(L"\""+fixture.image+L"\" --generated-normal"),action=fixture.action(evidence);
        require(fixture.run(evidence,action,started,exit,5000,[](void *){return 1;})==ERROR_CANCELLED && !started && !exists(fixture.home+L"\\.invoked"),"Pre-cancellation launched an installer");
        require(fixture.run(evidence,std::string(64,'b'),started,exit)==ERROR_FILE_INVALID && !started && !exists(fixture.home+L"\\.invoked"),"Changed action launched an installer");
        fixture.set(L"DisplayVersion",L"changed");require(fixture.run(evidence,action,started,exit)==ERROR_FILE_INVALID && !started,"Changed registration launched an installer");fixture.set(L"DisplayVersion",L"1.0");
        require(MoveFileW(fixture.image.c_str(),(fixture.home+L"\\uninstall.original.exe").c_str()),"Generated reviewed image rename failed");
        require(CopyFileW(module.c_str(),fixture.image.c_str(),TRUE),"Generated replacement image copy failed");
        require(fixture.run(evidence,action,started,exit)==ERROR_FILE_INVALID && !started && !exists(fixture.home+L"\\.invoked"),"Replaced installer image launched without fresh review");
        action=fixture.action(evidence);
        require(CreateHardLinkW((fixture.home+L"\\uninstall.alias.exe").c_str(),fixture.image.c_str(),nullptr),"Generated installer hard link failed");
        require(fixture.run(evidence,action,started,exit)==ERROR_FILE_INVALID && !started,"Changed installer link identity was accepted");
        action=fixture.action(evidence);
        require(fixture.run(evidence,action,started,exit)==0 && started && exit==0 && exists(fixture.home+L"\\.invoked"),"Generated normal installer failed");
        evidence=fixture.command(L"\""+fixture.image+L"\" --generated-fail");action=fixture.action(evidence);
        require(fixture.run(evidence,action,started,exit)==ERROR_PROCESS_ABORTED && started && exit==7,"Installer failure was accepted as success");
        evidence=fixture.command(L"\""+fixture.image+L"\" --generated-wait");action=fixture.action(evidence);DeleteFileW((fixture.home+L"\\.invoked").c_str());
        require(fixture.run(evidence,action,started,exit,1000)==ERROR_TIMEOUT && started && exists(fixture.home+L"\\.invoked"),"Installer wait did not time out after a positive launch");
        Sleep(1500);require(exists(fixture.home+L"\\.finished"),"Stopping the wait terminated the installer");
        evidence=fixture.command(L"cmd.exe /c echo unsafe");require(fixture.review(evidence).first!=0,"Relative shell registration was accepted");
        require(exists(fixture.home+L"\\retained.txt"),"Generated sibling changed");
        std::puts("PASS generated installer review, changed registration/action/image, cancellation, exit status and timeout without termination; no installed uninstaller or package operation invoked");return 0;
    }catch(const std::exception &error){std::fprintf(stderr,"FAIL %s\n",error.what());return 1;}
}
