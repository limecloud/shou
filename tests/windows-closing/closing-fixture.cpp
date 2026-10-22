// Standalone normal-close safety checks. Only this program's exclusively
// generated Code.exe child is ever selected for a close request.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <shellapi.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

namespace {
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
HANDLE received=nullptr;
bool refuses=false;
LRESULT CALLBACK fixtureWindow(HWND window,UINT message,WPARAM wparam,LPARAM lparam){
    if(message==WM_CLOSE){SetEvent(received);if(refuses)return 0;}
    if(message==WM_DESTROY){PostQuitMessage(0);return 0;}
    return DefWindowProcW(window,message,wparam,lparam);
}
int windowMain(wchar_t **args){
    refuses=std::wstring(args[2])==L"refuse";
    auto stop=OpenEventW(SYNCHRONIZE,FALSE,args[3]);
    auto ready=OpenEventW(EVENT_MODIFY_STATE,FALSE,args[4]);
    received=OpenEventW(EVENT_MODIFY_STATE,FALSE,args[5]);
    if(!stop || !ready || !received)return 10;
    WNDCLASSW type{};type.lpfnWndProc=fixtureWindow;type.hInstance=GetModuleHandleW(nullptr);type.lpszClassName=L"ShouGeneratedCloseFixture";
    if(!RegisterClassW(&type))return 11;
    auto window=CreateWindowW(type.lpszClassName,L"Generated Shou close fixture; no user documents",WS_OVERLAPPEDWINDOW,CW_USEDEFAULT,CW_USEDEFAULT,400,200,nullptr,nullptr,type.hInstance,nullptr);
    if(!window)return 12;
    ShowWindow(window,SW_SHOWNOACTIVATE);SetEvent(ready);
    bool done=false;
    while(!done){
        auto status=MsgWaitForMultipleObjects(1,&stop,FALSE,30000,QS_ALLINPUT);
        if(status==WAIT_OBJECT_0 || status==WAIT_TIMEOUT)break;
        MSG message{};
        while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){
            if(message.message==WM_QUIT){done=true;break;}
            TranslateMessage(&message);DispatchMessageW(&message);
        }
    }
    if(IsWindow(window))DestroyWindow(window);
    CloseHandle(stop);CloseHandle(ready);CloseHandle(received);return 0;
}
struct Child {
    HANDLE stop=nullptr,ready=nullptr,notice=nullptr,process=nullptr;
    DWORD pid=0;
    Child(const std::wstring &executable,bool refusal){
        try {
        const auto prefix=L"Local\\ShouCloseFixture-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64());
        stop=CreateEventW(nullptr,TRUE,FALSE,(prefix+L"-stop").c_str());ready=CreateEventW(nullptr,TRUE,FALSE,(prefix+L"-ready").c_str());notice=CreateEventW(nullptr,TRUE,FALSE,(prefix+L"-notice").c_str());
        require(stop && ready && notice,"Could not create owned fixture events");
        auto command=L"\""+executable+L"\" --window "+(refusal?L"refuse":L"close")+L" \""+prefix+L"-stop\" \""+prefix+L"-ready\" \""+prefix+L"-notice\"";
        STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};
        require(CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,FALSE,0,nullptr,nullptr,&startup,&child),"Could not launch generated fixture");
        process=child.hProcess;pid=child.dwProcessId;CloseHandle(child.hThread);
        require(WaitForSingleObject(ready,10000)==WAIT_OBJECT_0,"Generated fixture did not create a window");
        }catch(...){release();throw;}
    }
    void release(){if(stop)SetEvent(stop);if(process){WaitForSingleObject(process,10000);CloseHandle(process);}for(auto event:{stop,ready,notice})if(event)CloseHandle(event);}
    ~Child(){release();}
};
shou_win_close_process selected(DWORD pid){
    shou_win_close_process *rows=nullptr;size_t count=0;
    const auto code=shou_win_close_process_inventory("Code.exe",&rows,&count);
    if(code){std::fprintf(stderr,"Native inventory failed: %d\n",code);throw std::runtime_error("Process inventory unavailable; no close request was sent");}
    shou_win_close_process value{};
    for(size_t index=0;index<count;index++)if(rows[index].pid==pid)value=rows[index];
    shou_win_free(rows);require(value.pid==pid,"Generated PID absent from exact inventory");return value;
}
}

int runChecks(int argc,wchar_t **argv){
    if(argc==6 && std::wstring(argv[1])==L"--window")return windowMain(argv);
    HANDLE token=nullptr;TOKEN_ELEVATION elevation{};DWORD size=0;
    if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return 1;
    const bool inspected=GetTokenInformation(token,TokenElevation,&elevation,sizeof(elevation),&size);CloseHandle(token);
    if(!inspected)return 1;
    if(elevation.TokenIsElevated){std::puts("SKIP positive normal-close fixture: run under a standard, non-elevated user.");return 77;}
    wchar_t temporary[MAX_PATH],module[32768];
    if(!GetTempPathW(MAX_PATH,temporary) || !GetModuleFileNameW(nullptr,module,32768))return 1;
    const auto directory=std::wstring(temporary)+L"shou-close-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64());
    if(!CreateDirectoryW(directory.c_str(),nullptr))return 1;
    const auto executable=directory+L"\\Code.exe";
    if(!CopyFileW(module,executable.c_str(),TRUE)){RemoveDirectoryW(directory.c_str());return 1;}
    int result=0;
    try {
        {
            Child child(executable,false);const auto saved=selected(child.pid);
            for(int change=0;change<6;change++){
                auto stale=saved;
                if(change==0)stale.created++;
                if(change==1)stale.session++;
                if(change==2)stale.executable_identity.file_id[0]^=1;
                if(change==3)stale.owner_sid[0]='X';
                if(change==4)stale.executable_path[0]='X';
                if(change==5)stale.executable_identity.modified_ns++;
                require(shou_win_request_process_close("Code.exe",&stale,1,nullptr,nullptr)!=0,"Changed process identity accepted");
                require(WaitForSingleObject(child.notice,0)==WAIT_TIMEOUT,"Stale identity sent a close message");
            }
            require(shou_win_request_process_close("Code.exe",&saved,1,[](void *){return 1;},nullptr)==ERROR_CANCELLED,"Cancelled request was not refused");
            require(WaitForSingleObject(child.notice,0)==WAIT_TIMEOUT,"Cancelled request sent a close message");
            require(shou_win_request_process_close("Code.exe",&saved,1,nullptr,nullptr)==0,"Exact normal-close request failed");
            require(WaitForSingleObject(child.notice,10000)==WAIT_OBJECT_0 && WaitForSingleObject(child.process,10000)==WAIT_OBJECT_0,"Generated window did not close normally");
        }
        {
            Child first(executable,false),second(executable,false);
            shou_win_close_process selection[2]={selected(first.pid),selected(second.pid)};
            selection[1].created++;
            require(shou_win_request_process_close("Code.exe",selection,2,nullptr,nullptr)!=0,"Partially stale selection accepted");
            require(WaitForSingleObject(first.notice,0)==WAIT_TIMEOUT && WaitForSingleObject(second.notice,0)==WAIT_TIMEOUT,"Preflight sent a close before validating all selected processes");
        }
        {
            Child child(executable,true);const auto saved=selected(child.pid);
            require(shou_win_request_process_close("Code.exe",&saved,1,nullptr,nullptr)==0,"Refusal fixture did not receive normal close");
            require(WaitForSingleObject(child.notice,10000)==WAIT_OBJECT_0 && WaitForSingleObject(child.process,0)==WAIT_TIMEOUT,"Refusing application was forced to exit");
        }
        std::puts("PASS exact generated PID, creation/session/owner/path/image identity refusal, whole-selection preflight, cancellation, normal window close and preserved quit refusal");
    }catch(const std::exception &error){std::fprintf(stderr,"FAIL %s\n",error.what());result=1;}
    if(!DeleteFileW(executable.c_str()) || !RemoveDirectoryW(directory.c_str()))return 1;
    return result;
}

int main(){
    int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(!argv)return 1;
    const auto result=runChecks(argc,argv);LocalFree(argv);return result;
}
