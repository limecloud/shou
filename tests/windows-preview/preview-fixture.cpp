#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include "shou_windows.h"
#include <windows.h>
#include <shellapi.h>
#include <objidl.h>
#include <wrl/client.h>
#include <filesystem>
#include <string>
#include <stdexcept>
#include <iostream>
using Microsoft::WRL::ComPtr;

namespace {
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
std::string utf8(const std::wstring &value){
    const auto size=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,nullptr,0,nullptr,nullptr);
    require(size>0,"UTF-8 path conversion failed");std::string result(static_cast<size_t>(size),'\0');
    require(WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.c_str(),-1,result.data(),size,nullptr,nullptr)>0,"UTF-8 path conversion failed");
    result.pop_back();return result;
}
struct Fixture {
    std::filesystem::path root;
    ~Fixture(){std::error_code error;std::filesystem::remove_all(root,error);}
};
}

int main(){
    try {
        int count=0;auto args=CommandLineToArgvW(GetCommandLineW(),&count);
        require(args && count==2,"Pass one generated fixture parent");
        const std::filesystem::path parent(args[1]);LocalFree(args);
        require(parent.is_absolute() && std::filesystem::is_directory(parent),"Fixture parent must exist");
        Fixture fixture{parent/(L"shou-preview-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()))};
        require(std::filesystem::create_directory(fixture.root),"Fixture root already exists");
        const auto path=fixture.root/L"\x4e2d\x6587 report.pdf";
        const std::string payload="Generated read-only preview stream. This is not a real document.";
        HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        require(file!=INVALID_HANDLE_VALUE,"Fixture file creation failed");DWORD written=0;
        const auto saved=WriteFile(file,payload.data(),static_cast<DWORD>(payload.size()),&written,nullptr);CloseHandle(file);
        require(saved && written==payload.size(),"Fixture file write failed");
        const auto root=utf8(fixture.root.wstring()),name=utf8(path.wstring());
        shou_win_info rootInfo{},fileInfo{};
        require(shou_win_stat(root.c_str(),&rootInfo)==0 && shou_win_stat(name.c_str(),&fileInfo)==0,"Fixture identity unavailable");
        void *raw=nullptr;
        require(shou_win_preview_stream(root.c_str(),&rootInfo,name.c_str(),&fileInfo,&raw)==0 && raw,"Bound preview stream failed");
        ComPtr<IStream> stream;stream.Attach(static_cast<IStream *>(raw));
        char buffer[128]{};ULONG read=0;
        require(stream->Read(buffer,9,&read)==S_OK && read==9 && std::string(buffer,read)==payload.substr(0,9),"Read did not return the reviewed bytes");
        ComPtr<IStream> clone;require(stream->Clone(&clone)==S_OK,"Independent clone unavailable");
        LARGE_INTEGER origin{};origin.QuadPart=4;require(stream->Seek(origin,STREAM_SEEK_SET,nullptr)==S_OK,"Seek failed");
        require(clone->Read(buffer,4,&read)==S_OK && std::string(buffer,read)==payload.substr(9,4),"Clone shared its cursor");
        require(stream->Read(buffer,4,&read)==S_OK && std::string(buffer,read)==payload.substr(4,4),"Original cursor changed");
        ULONG altered=99;ULARGE_INTEGER size{};size.QuadPart=1;
        require(stream->Write("x",1,&altered)==STG_E_ACCESSDENIED && altered==0 && stream->SetSize(size)==STG_E_ACCESSDENIED,"Preview stream accepted mutation");
        require(stream->Read(buffer,1048577,&read)==STG_E_INVALIDPARAMETER,"Unbounded COM read accepted");
        origin.QuadPart=INT64_MIN;require(FAILED(stream->Seek(origin,STREAM_SEEK_CUR,nullptr)),"Negative seek overflow accepted");
        STATSTG stat{};require(stream->Stat(&stat,STATFLAG_DEFAULT)==S_OK && stat.cbSize.QuadPart==payload.size() && stat.grfMode==STGM_READ,"Read-only stream metadata changed");CoTaskMemFree(stat.pwcsName);
        origin.QuadPart=0;require(stream->Seek(origin,STREAM_SEEK_SET,nullptr)==S_OK,"Rewind failed");
        ComPtr<IStream> copy;require(CreateStreamOnHGlobal(nullptr,TRUE,&copy)==S_OK,"Copy fixture unavailable");
        size.QuadPart=payload.size();ULARGE_INTEGER copied{},received{};
        require(stream->CopyTo(copy.Get(),size,&copied,&received)==S_OK && copied.QuadPart==payload.size() && received.QuadPart==payload.size(),"Bounded stream copy failed");
        require(stream->Read(buffer,1,&read)==S_FALSE && read==0,"EOF did not remain bounded");
        file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,OPEN_EXISTING,0,nullptr);
        require(file==INVALID_HANDLE_VALUE,"Preview allowed a concurrent writer");
        require(!MoveFileW(path.c_str(),(fixture.root/L"moved.pdf").c_str()),"Pinned preview file was renamed");
        clone.Reset();stream.Reset();copy.Reset();
        file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,OPEN_EXISTING,0,nullptr);
        require(file!=INVALID_HANDLE_VALUE,"Preview did not release its handles");CloseHandle(file);
        auto stale=fileInfo;stale.file_id[0]^=1;
        require(shou_win_preview_stream(root.c_str(),&rootInfo,name.c_str(),&stale,&raw)!=0 && !raw,"Stale file identity was accepted");
        auto staleRoot=rootInfo;staleRoot.file_id[0]^=1;
        require(shou_win_preview_stream(root.c_str(),&staleRoot,name.c_str(),&fileInfo,&raw)!=0 && !raw,"Stale root identity was accepted");
        require(shou_win_preview_stream(name.c_str(),&rootInfo,name.c_str(),&fileInfo,&raw)!=0 && !raw,"A file became a preview root");
        const auto link=fixture.root/L"linked.pdf";
        if(CreateSymbolicLinkW(link.c_str(),path.c_str(),2)){
            const auto linkName=utf8(link.wstring());
            require(shou_win_preview_stream(root.c_str(),&rootInfo,linkName.c_str(),&fileInfo,&raw)!=0 && !raw,"Preview followed a link");
            std::cout<<"PASS generated symlink refusal\n";
        }else std::cout<<"NOT RUN generated symlink creation ("<<GetLastError()<<")\n";
        require(shou_win_preview_host(name.c_str(),nullptr,0,0,[](void *){},nullptr)==ERROR_INVALID_PARAMETER,"Preview accepted an unowned window");
        std::cout<<"PASS native preview identity, pinned ancestors, read/seek/clone/copy/EOF, read-only access, stale identity, handle release and invalid-host checks; generated files only, no installed preview provider activated.\n";
        return 0;
    } catch(const std::exception &error){std::cerr<<"FAIL native preview fixture: "<<error.what()<<"\n";return 1;}
}
