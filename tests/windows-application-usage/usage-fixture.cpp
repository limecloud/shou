#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <objbase.h>
#include <bcrypt.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

namespace {
void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
int cancel(void *){return 1;}
std::string utf8(const std::wstring &value){auto n=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,nullptr,0,nullptr,nullptr);require(n>0,"UTF-8 size");std::string text(n,0);require(WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,text.data(),n,nullptr,nullptr)>0,"UTF-8 conversion");text.pop_back();return text;}
std::string quote(const std::wstring &value){std::string text="\"";for(char c:utf8(value)){if(c=='\\'||c=='"')text+='\\';text+=c;}return text+'"';}
std::string hash(const std::string &value){BCRYPT_ALG_HANDLE provider=nullptr;require(BCryptOpenAlgorithmProvider(&provider,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0,"SHA provider");BYTE bytes[32]{};auto status=BCryptHash(provider,nullptr,0,reinterpret_cast<PUCHAR>(const_cast<char *>(value.data())),static_cast<ULONG>(value.size()),bytes,32);BCryptCloseAlgorithmProvider(provider,0);require(status>=0,"SHA calculation");std::string text;const char hex[]="0123456789abcdef";for(auto b:bytes){text+=hex[b>>4];text+=hex[b&15];}return text;}
struct Fixture {
    std::wstring home,keyPath,registration=L"HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\GeneratedUsage";
    HKEY root=nullptr,key=nullptr;bool redirected=false;
    void set(const wchar_t *name,const std::wstring &value){require(RegSetValueExW(key,name,0,REG_SZ,reinterpret_cast<const BYTE *>(value.c_str()),static_cast<DWORD>((value.size()+1)*2))==0,"Generated registry value");}
    void write(const std::wstring &name,DWORD size){auto file=CreateFileW((home+L"\\"+name).c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,0,nullptr);require(file!=INVALID_HANDLE_VALUE,"Generated file creation");std::string text(size,'x');DWORD written=0;auto ok=WriteFile(file,text.data(),size,&written,nullptr);CloseHandle(file);require(ok&&written==size,"Generated file write");}
    Fixture(){try {
        wchar_t temp[32768]{},id[40]{};GUID guid{};require(GetTempPathW(32768,temp)>0 && SUCCEEDED(CoCreateGuid(&guid)) && StringFromGUID2(guid,id,40)>0,"Generated fixture location");
        home=std::wstring(temp)+L"shou-generated-usage-"+id;require(shou_win_private_directory(utf8(home).c_str())==0,"Private generated directory");
        require(CreateDirectoryW((home+L"\\nested").c_str(),nullptr),"Generated child directory");write(L"payload.bin",4096);write(L"nested\\child.txt",3);
        require(CreateHardLinkW((home+L"\\alias.bin").c_str(),(home+L"\\payload.bin").c_str(),nullptr),"Generated hard link");
        keyPath=L"Software\\Shou\\GeneratedUsageFixtures\\"+std::wstring(id);
        require(RegCreateKeyExW(HKEY_CURRENT_USER,keyPath.c_str(),0,nullptr,0,KEY_ALL_ACCESS,nullptr,&root,nullptr)==0,"Private generated registry root");
        require(RegCreateKeyExW(root,L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\GeneratedUsage",0,nullptr,0,KEY_ALL_ACCESS,nullptr,&key,nullptr)==0,"Generated registration");
        set(L"DisplayName",L"Generated usage fixture");set(L"DisplayVersion",L"1.0");set(L"Publisher",L"Generated");set(L"InstallLocation",home);
        require(RegOverridePredefKey(HKEY_CURRENT_USER,root)==0,"Process-local registry redirection");redirected=true;
    }catch(...){release();throw;}}
    ~Fixture(){release();}
    void release(){if(redirected)RegOverridePredefKey(HKEY_CURRENT_USER,nullptr);redirected=false;if(key)RegCloseKey(key);key=nullptr;if(root)RegCloseKey(root);root=nullptr;if(!keyPath.empty())RegDeleteTreeW(HKEY_CURRENT_USER,keyPath.c_str());if(!home.empty()){ for(auto name:{L"alias.bin",L"payload.bin",L"nested\\child.txt"})DeleteFileW((home+L"\\"+name).c_str());RemoveDirectoryW((home+L"\\nested").c_str());RemoveDirectoryW(home.c_str());}}
    std::string evidence()const{return hash(quote(registration)+quote(L"Generated usage fixture")+quote(L"1.0")+quote(L"Generated")+quote(home)+quote(L"")+"0:0:0:null");}
    std::string measure(size_t limit=100){char *raw=nullptr;auto code=shou_win_application_usage("windows.user_uninstall64",utf8(registration).c_str(),evidence().c_str(),limit,5000,nullptr,nullptr,&raw);std::string text=raw?raw:"";shou_win_free(raw);require(code==0,"Generated measurement failed");return text;}
};
}
int main(int argc,char **argv){
    char *result=nullptr;const auto evidence=std::string(64,'a');const char *name="HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Missing";
    if(shou_win_application_usage(nullptr,name,evidence.c_str(),1,1000,nullptr,nullptr,&result)!=87)return 1;
    if(shou_win_application_usage("windows.user_uninstall64",name,"short",1,1000,nullptr,nullptr,&result)!=87)return 2;
    if(shou_win_application_usage("windows.user_uninstall64",name,evidence.c_str(),0,1000,nullptr,nullptr,&result)!=87)return 3;
    if(shou_win_application_usage("windows.user_uninstall64",name,evidence.c_str(),1000001,1000,nullptr,nullptr,&result)!=87)return 4;
    if(shou_win_application_usage("windows.user_uninstall64",name,evidence.c_str(),1,120001,nullptr,nullptr,&result)!=87)return 5;
    if(shou_win_application_usage("windows.user_uninstall64",name,evidence.c_str(),1,1000,cancel,nullptr,&result)!=1223 || result)return 6;
    std::puts("PASS 6 application-usage native input/pre-cancellation gates; no registration read or files changed.");
    if(argc==1)return 0;
    if(argc!=2 || strcmp(argv[1],"--generated-fixture"))return 2;
    HANDLE token=nullptr;TOKEN_ELEVATION elevation{};DWORD count=0;if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return 1;
    auto ok=GetTokenInformation(token,TokenElevation,&elevation,sizeof(elevation),&count);CloseHandle(token);if(!ok)return 1;
    if(elevation.TokenIsElevated){std::puts("NOT RUN: generated usage fixtures require a standard-user session.");return 77;}
    try {
        Fixture fixture;const auto full=fixture.measure();
        require(full.find("\"status\":\"complete\"")!=std::string::npos && full.find("\"logical_bytes\":4099")!=std::string::npos && full.find("\"file_count\":2")!=std::string::npos && full.find("\"visited_entries\":5")!=std::string::npos,"Generated directory/hard-link accounting");
        const auto partial=fixture.measure(2);require(partial.find("\"status\":\"partial\"")!=std::string::npos && partial.find("entry_limit")!=std::string::npos,"Bounded partial measurement");
        fixture.set(L"DisplayVersion",L"changed");result=nullptr;
        auto code=shou_win_application_usage("windows.user_uninstall64",utf8(fixture.registration).c_str(),fixture.evidence().c_str(),100,5000,nullptr,nullptr,&result);shou_win_free(result);
        require(code==1006,"Changed generated registration was accepted");
        WIN32_FILE_ATTRIBUTE_DATA data{};require(GetFileAttributesExW((fixture.home+L"\\payload.bin").c_str(),GetFileExInfoStandard,&data) && data.nFileSizeLow==4096,"Generated payload changed");
        std::puts("PASS generated application usage, hard-link deduplication, partial budgets, stale registration and payload preservation. Real installation and MSIX measurement NOT RUN.");return 0;
    }catch(const std::exception &error){std::fprintf(stderr,"FAIL %s\n",error.what());return 1;}
}
