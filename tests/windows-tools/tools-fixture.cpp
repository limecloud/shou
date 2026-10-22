// Only an exclusively generated rustup.exe copy of this fixture is executed.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <utility>

namespace {
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
std::string utf8(const std::wstring &value){int size=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,nullptr,0,nullptr,nullptr);require(size>0,"UTF-8 encoding failed");std::string text(size,0);WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,text.data(),size,nullptr,nullptr);text.pop_back();return text;}
void write(const std::wstring &path,const std::string &text){auto file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,0,nullptr);require(file!=INVALID_HANDLE_VALUE,"Fixture file creation failed");DWORD size=0;auto ok=WriteFile(file,text.data(),static_cast<DWORD>(text.size()),&size,nullptr);CloseHandle(file);require(ok && size==text.size(),"Fixture file write failed");}
std::string read(const std::wstring &path){auto file=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,0,nullptr);if(file==INVALID_HANDLE_VALUE)return {};char buffer[64];DWORD size=0;auto ok=ReadFile(file,buffer,sizeof(buffer),&size,nullptr);CloseHandle(file);return ok?std::string(buffer,size):std::string();}
bool exists(const std::wstring &path){return GetFileAttributesW(path.c_str())!=INVALID_FILE_ATTRIBUTES;}
int generatedTool(const std::wstring &module,bool descendant){
    wchar_t profile[32768];auto size=GetEnvironmentVariableW(L"USERPROFILE",profile,32768);if(!size || size>=32768)return 10;
    const std::wstring home=profile;
    wchar_t autoInstall[8];if(GetEnvironmentVariableW(L"RUSTUP_AUTO_INSTALL",autoInstall,8)!=1 || std::wstring(autoInstall)!=L"0")return 13;
    if(descendant){write(home+L"\\.fixture-descendant-started","started");Sleep(4200);write(home+L"\\.fixture-escaped","unexpected");return 0;}
    write(home+L"\\.fixture-invoked","started");
    const auto mode=read(home+L"\\.fixture-mode");
    if(mode=="overflow"){for(int index=0;index<100000;index++)std::puts("generated bounded tool output fixture padding padding padding padding padding");return 0;}
    if(mode=="descendant"){
        auto command=L"\""+module+L"\" --descendant";STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};
        startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdInput=GetStdHandle(STD_INPUT_HANDLE);startup.hStdOutput=GetStdHandle(STD_OUTPUT_HANDLE);startup.hStdError=GetStdHandle(STD_ERROR_HANDLE);
        if(!CreateProcessW(module.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child))return 11;
        CloseHandle(child.hThread);CloseHandle(child.hProcess);return 0;
    }
    if(mode=="fail"){std::fputs("generated diagnostic must not be returned",stderr);return 7;}
    std::puts("fixture-tool");return 0;
}
struct Fixture {
    std::wstring home,executable;
    Fixture(const std::wstring &module){
        PWSTR profile=nullptr;require(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Profile,0,nullptr,&profile)),"Profile location unavailable");
        home=std::wstring(profile)+L"\\ShouToolFixture-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64());CoTaskMemFree(profile);
        require(CreateDirectoryW(home.c_str(),nullptr),"Fixture directory is not exclusive");
        try {
        for(const auto &directory:{home,home+L"\\.cargo",home+L"\\.cargo\\bin"})require(shou_win_private_directory(utf8(directory).c_str())==0,"Private fixture directory failed");
        executable=home+L"\\.cargo\\bin\\rustup.exe";require(CopyFileW(module.c_str(),executable.c_str(),TRUE),"Generated tool copy failed");
        }catch(...){release();throw;}
    }
    void release(){for(auto name:{L".fixture-mode",L".fixture-invoked",L".fixture-descendant-started",L".fixture-escaped"})DeleteFileW((home+L"\\"+name).c_str());if(!executable.empty())DeleteFileW(executable.c_str());for(const auto &directory:{home+L"\\.cargo\\bin",home+L"\\.cargo",home})RemoveDirectoryW(directory.c_str());}
    ~Fixture(){release();}
    void mode(const char *value){write(home+L"\\.fixture-mode",value);DeleteFileW((home+L"\\.fixture-invoked").c_str());}
};
}

int main(){
    wchar_t raw[32768];auto size=GetModuleFileNameW(nullptr,raw,32768);if(!size || size>=32768)return 1;std::wstring module=raw;
    if(!_wcsicmp(module.substr(module.find_last_of(L'\\')+1).c_str(),L"rustup.exe")){
        int count=0;auto args=CommandLineToArgvW(GetCommandLineW(),&count);if(!args)return 1;
        bool descendant=count==2 && std::wstring(args[1])==L"--descendant";LocalFree(args);return generatedTool(module,descendant);
    }
    HANDLE token=nullptr;TOKEN_ELEVATION elevated{};DWORD bytes=0;
    if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return 1;
    auto inspected=GetTokenInformation(token,TokenElevation,&elevated,sizeof(elevated),&bytes);CloseHandle(token);if(!inspected)return 1;
    if(elevated.TokenIsElevated){std::puts("NOT RUN: use a standard-user Windows session for positive tool fixture acceptance.");return 77;}
    try {
        Fixture fixture(module);auto home=utf8(fixture.home);char *path=nullptr;shou_win_info identity{};
        require(shou_win_cleanup_tool_info(home.c_str(),"rustup",&path,&identity)==0,"Generated tool inspection failed");
        std::string executable=path;shou_win_free(path);
        auto run=[&](uint32_t operation,const shou_win_info &expected,uint32_t milliseconds,shou_win_read_cancelled cancel=nullptr){char *output=nullptr;auto code=shou_win_cleanup_tool_run(home.c_str(),operation,"--default",executable.c_str(),&expected,milliseconds,cancel,nullptr,&output);std::string value=output?output:"";shou_win_free(output);return std::make_pair(code,value);};
        fixture.mode("normal");auto stale=identity;stale.file_id[0]^=1;
        require(run(6,stale,2000).first==ERROR_FILE_INVALID && !exists(fixture.home+L"\\.fixture-invoked"),"Stale image launched a tool");
        require(run(6,identity,2000,[](void *){return 1;}).first==ERROR_CANCELLED && !exists(fixture.home+L"\\.fixture-invoked"),"Pre-cancellation launched a tool");
        require(run(9,identity,2000).first==ERROR_INVALID_PARAMETER && !exists(fixture.home+L"\\.fixture-invoked"),"Option-like toolchain launched a tool");
        auto normal=run(6,identity,2000);require(normal.first==0 && (normal.second=="fixture-tool\r\n" || normal.second=="fixture-tool\n"),"Exact generated tool output failed");
        fixture.mode("fail");require(run(6,identity,2000).first==ERROR_PROCESS_ABORTED,"Nonzero tool exit accepted");
        fixture.mode("overflow");require(run(6,identity,5000).first==ERROR_MORE_DATA,"Tool output was not bounded");
        fixture.mode("descendant");require(run(6,identity,2000).first==ERROR_TIMEOUT,"Owned descendant did not keep bounded process channels");
        require(exists(fixture.home+L"\\.fixture-descendant-started"),"Descendant timeout was not a positive process acceptance check");
        Sleep(2500);require(!exists(fixture.home+L"\\.fixture-escaped"),"Owned descendant escaped the process job");
        std::puts("PASS generated fixed tool, reviewed image, option refusal, cancellation, bounded output, exit status and owned descendant timeout; no installed tool executed");return 0;
    }catch(const std::exception &error){std::fprintf(stderr,"FAIL %s\n",error.what());return 1;}
}
