#include "shou_windows.h"
#include <cstdio>
#include <string>

namespace {
int cancelled(void *) { return 1; }
}
int main() {
    // These calls all stop at input or cancellation gates. They never inspect
    // a real package, create an app-data store or invoke ClearAllAsync.
    constexpr int invalid=87,stopped=1223;
    const auto evidence=std::string(64,'a');
    const char *registration="Shou.Generated.Missing_1.0.0.0_x64__fixture1234";
    shou_win_info identity{};char *result=nullptr;int started=9,completed=9;
    if(shou_win_package_data_review(nullptr,evidence.c_str(),nullptr,nullptr,&identity,&result)!=invalid)return 1;
    if(shou_win_package_data_review(registration,"short",nullptr,nullptr,&identity,&result)!=invalid)return 2;
    if(shou_win_package_data_clear(registration,evidence.c_str(),evidence.c_str(),0,nullptr,nullptr,&started,&completed)!=invalid)return 3;
    if(shou_win_package_data_clear(registration,evidence.c_str(),evidence.c_str(),120001,nullptr,nullptr,&started,&completed)!=invalid)return 4;
    if(shou_win_package_data_clear(registration,evidence.c_str(),"short",1000,nullptr,nullptr,&started,&completed)!=invalid)return 5;
    if(shou_win_package_data_review(registration,evidence.c_str(),cancelled,nullptr,&identity,&result)!=stopped || result)return 6;
    if(shou_win_package_data_clear(registration,evidence.c_str(),evidence.c_str(),1000,cancelled,nullptr,&started,&completed)!=stopped || started || completed)return 7;
    std::puts("PASS 7 native MSIX input/pre-cancellation gates; no package API invocation or user data changed. Positive MSIX runtime acceptance NOT RUN.");
}
