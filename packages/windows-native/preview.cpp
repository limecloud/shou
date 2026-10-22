#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <tlhelp32.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <wrl/client.h>
#include <string>
#include <new>
using Microsoft::WRL::ComPtr;

namespace {
constexpr UINT hostTab=WM_APP+71,hostClose=WM_APP+72,focusPreview=WM_APP+73;
constexpr wchar_t surfaceClass[]=L"ShouSystemPreviewSurface";
constexpr wchar_t previewCategory[]=L"{8895b1c6-b41f-4c1c-a562-0d564250836f}";

std::wstring wide(const char *text){
    if(!text)return {};
    const auto size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,nullptr,0);
    if(size<=1 || size>32768)return {};
    std::wstring value(static_cast<size_t>(size),L'\0');
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,value.data(),size))return {};
    value.resize(static_cast<size_t>(size-1));return value;
}
bool actualParent(DWORD expected){
    const auto snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    if(snapshot==INVALID_HANDLE_VALUE)return false;
    PROCESSENTRY32W process{};process.dwSize=sizeof(process);bool result=false;
    if(Process32FirstW(snapshot,&process))do{
        if(process.th32ProcessID==GetCurrentProcessId()){result=process.th32ParentProcessID==expected;break;}
    }while(Process32NextW(snapshot,&process));
    CloseHandle(snapshot);return result;
}
bool declaredHandler(const wchar_t *id){
    constexpr wchar_t key[]=L"Software\\Microsoft\\Windows\\CurrentVersion\\PreviewHandlers";
    for(const auto hive:{HKEY_LOCAL_MACHINE,HKEY_CURRENT_USER}){
        wchar_t name[512]{};DWORD bytes=sizeof(name);
        if(RegGetValueW(hive,key,id,RRF_RT_REG_SZ,nullptr,name,&bytes)==ERROR_SUCCESS && bytes>sizeof(wchar_t))return true;
    }
    return false;
}

struct PreviewDpiScope {
    DPI_AWARENESS_CONTEXT previous;
    explicit PreviewDpiScope(HWND parent):previous(SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(parent))){}
    ~PreviewDpiScope(){if(previous)SetThreadDpiAwarenessContext(previous);}
};

struct PreviewSurface;
class PreviewFrame final:public IPreviewHandlerFrame,public IOleWindow {
    LONG references=1;
    HWND parent;
public:
    explicit PreviewFrame(HWND value):parent(value){}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void **result) override {
        if(!result)return E_POINTER;*result=nullptr;
        if(id==IID_IUnknown || id==__uuidof(IPreviewHandlerFrame))*result=static_cast<IPreviewHandlerFrame *>(this);
        else if(id==IID_IOleWindow)*result=static_cast<IOleWindow *>(this);
        else return E_NOINTERFACE;
        AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return static_cast<ULONG>(InterlockedIncrement(&references));}
    ULONG STDMETHODCALLTYPE Release() override{const auto count=InterlockedDecrement(&references);if(!count)delete this;return static_cast<ULONG>(count);}
    HRESULT STDMETHODCALLTYPE GetWindow(HWND *result) override{if(!result)return E_POINTER;*result=parent;return S_OK;}
    HRESULT STDMETHODCALLTYPE ContextSensitiveHelp(BOOL) override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE GetWindowContext(PREVIEWHANDLERFRAMEINFO *result) override;
    HRESULT STDMETHODCALLTYPE TranslateAccelerator(MSG *message) override {
        if(!message)return E_POINTER;
        if(message->message==WM_KEYDOWN && message->wParam==VK_TAB){
            PostMessageW(parent,hostTab,GetKeyState(VK_SHIFT)<0,0);return S_OK;
        }
        if((message->message==WM_KEYDOWN && message->wParam==VK_ESCAPE) ||
           (message->message==WM_SYSKEYDOWN && message->wParam==VK_F4)){
            PostMessageW(parent,hostClose,0,0);return S_OK;
        }
        return S_FALSE;
    }
};

HRESULT PreviewFrame::GetWindowContext(PREVIEWHANDLERFRAMEINFO *result){
    if(!result)return E_POINTER;*result={};return S_OK;
}

struct PreviewSurface {
    HWND parent=nullptr,window=nullptr;
    ComPtr<IPreviewHandler> handler;
    ComPtr<PreviewFrame> frame;
    RECT last{};
    void resize(){
        RECT bounds{};
        if(!IsWindow(parent) || !GetClientRect(parent,&bounds)){if(window)DestroyWindow(window);return;}
        if(EqualRect(&bounds,&last))return;
        last=bounds;SetWindowPos(window,nullptr,0,0,bounds.right,bounds.bottom,SWP_NOACTIVATE|SWP_NOZORDER);
        if(handler)handler->SetRect(&bounds);
    }
    static LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM wparam,LPARAM lparam){
        auto self=reinterpret_cast<PreviewSurface *>(GetWindowLongPtrW(window,GWLP_USERDATA));
        if(message==WM_NCCREATE){
            const auto create=reinterpret_cast<CREATESTRUCTW *>(lparam);self=static_cast<PreviewSurface *>(create->lpCreateParams);
            self->window=window;SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));
        }
        if(self){
            if(message==WM_TIMER){self->resize();return 0;}
            if(message==focusPreview || message==WM_SETFOCUS){if(self->handler)self->handler->SetFocus();return 0;}
            if(message==WM_DESTROY){KillTimer(window,1);PostQuitMessage(0);return 0;}
            if(message==WM_NCDESTROY){SetWindowLongPtrW(window,GWLP_USERDATA,0);self->window=nullptr;}
        }
        return DefWindowProcW(window,message,wparam,lparam);
    }
};
}

extern "C" int shou_win_preview_host(const char *input,void *stream,uint64_t parentWindow,uint32_t parentPid,shou_win_preview_ready ready,void *context){
    const auto parent=reinterpret_cast<HWND>(static_cast<uintptr_t>(parentWindow));DWORD observed=0;
    if(!stream || !ready || !IsWindow(parent) || !GetWindowThreadProcessId(parent,&observed) || observed!=parentPid || !actualParent(parentPid))return ERROR_INVALID_PARAMETER;
    // Child coordinates and handler windows use the WPF parent's DPI context.
    // Restore the worker thread's context when this one preview ends.
    PreviewDpiScope dpi(parent);if(!dpi.previous)return ERROR_INVALID_STATE;
    const auto path=wide(input);const auto dot=path.find_last_of(L'.');
    if(path.empty() || dot==std::wstring::npos || path.size()-dot>16)return ERROR_INVALID_PARAMETER;
    wchar_t identifier[64]{};DWORD size=64;
    auto status=AssocQueryStringW(ASSOCF_NONE,ASSOCSTR_SHELLEXTENSION,path.substr(dot).c_str(),previewCategory,identifier,&size);
    if(FAILED(status) || !declaredHandler(identifier))return ERROR_NOT_SUPPORTED;
    CLSID clsid{};if(FAILED(CLSIDFromString(identifier,&clsid)))return ERROR_NOT_SUPPORTED;
    status=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED|COINIT_DISABLE_OLE1DDE);
    if(FAILED(status))return static_cast<int>(status);
    {
        PreviewSurface surface;surface.parent=parent;
        status=CoCreateInstance(clsid,nullptr,CLSCTX_LOCAL_SERVER|CLSCTX_INPROC_SERVER|CLSCTX_DISABLE_AAA,IID_PPV_ARGS(&surface.handler));
        if(SUCCEEDED(status)){
            ComPtr<IInitializeWithStream> withStream;
            if(SUCCEEDED(surface.handler.As(&withStream)))status=withStream->Initialize(static_cast<IStream *>(stream),STGM_READ);
            else {
                // File-only handlers (including some Office providers) keep
                // the same pinned, non-writable file for their entire lifetime.
                ComPtr<IInitializeWithFile> withFile;
                status=surface.handler.As(&withFile);
                if(SUCCEEDED(status))status=withFile->Initialize(path.c_str(),STGM_READ);
            }
        }
        if(SUCCEEDED(status)){
            WNDCLASSW cls{};cls.lpfnWndProc=PreviewSurface::procedure;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=surfaceClass;
            if(!RegisterClassW(&cls) && GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)status=HRESULT_FROM_WIN32(GetLastError());
        }
        if(SUCCEEDED(status)){
            surface.window=CreateWindowExW(WS_EX_CONTROLPARENT,surfaceClass,L"",WS_CHILD|WS_VISIBLE|WS_CLIPCHILDREN|WS_TABSTOP,
                0,0,1,1,parent,nullptr,GetModuleHandleW(nullptr),&surface);
            if(!surface.window)status=HRESULT_FROM_WIN32(GetLastError());
        }
        if(SUCCEEDED(status)){
            surface.frame.Attach(new(std::nothrow) PreviewFrame(parent));
            if(!surface.frame)status=E_OUTOFMEMORY;
            ComPtr<IObjectWithSite> site;
            if(SUCCEEDED(status) && SUCCEEDED(surface.handler.As(&site)))status=site->SetSite(static_cast<IPreviewHandlerFrame *>(surface.frame.Get()));
            RECT bounds{};GetClientRect(parent,&bounds);surface.last=bounds;
            SetWindowPos(surface.window,nullptr,0,0,bounds.right,bounds.bottom,SWP_NOACTIVATE|SWP_NOZORDER);
            if(SUCCEEDED(status))status=surface.handler->SetWindow(surface.window,&bounds);
            if(SUCCEEDED(status))status=surface.handler->DoPreview();
        }
        if(SUCCEEDED(status)){
            if(!SetTimer(surface.window,1,100,nullptr))status=HRESULT_FROM_WIN32(GetLastError());
            else {
                ready(context);MSG message{};int next=0;
                while((next=GetMessageW(&message,nullptr,0,0))>0){
                    if(message.message==WM_KEYDOWN || message.message==WM_SYSKEYDOWN){
                        if((message.message==WM_KEYDOWN && message.wParam==VK_ESCAPE) || (message.message==WM_SYSKEYDOWN && message.wParam==VK_F4)){
                            PostMessageW(parent,hostClose,0,0);continue;
                        }
                        if(surface.handler->TranslateAccelerator(&message)==S_OK)continue;
                        if(surface.frame->TranslateAccelerator(&message)==S_OK)continue;
                    }
                    TranslateMessage(&message);DispatchMessageW(&message);
                }
                if(next<0)status=HRESULT_FROM_WIN32(GetLastError());
            }
        }
        if(surface.handler){surface.handler->Unload();ComPtr<IObjectWithSite> site;if(SUCCEEDED(surface.handler.As(&site)))site->SetSite(nullptr);}
        if(surface.window)DestroyWindow(surface.window);
    }
    CoUninitialize();return SUCCEEDED(status)?0:static_cast<int>(status);
}
