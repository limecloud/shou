#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>

namespace {
bool emit(const char *bytes, DWORD size, DWORD stream = STD_OUTPUT_HANDLE) {
    DWORD written = 0; return WriteFile(GetStdHandle(stream), bytes, size, &written, nullptr) && written == size;
}
bool hex(const void *bytes, DWORD size) {
    static constexpr char digits[] = "0123456789abcdef";
    auto data = static_cast<const unsigned char *>(bytes);
    for (DWORD index = 0; index < size; ++index) {
        char pair[] = { digits[data[index] >> 4], digits[data[index] & 15] };
        if (!emit(pair, 2)) return false;
    }
    return emit("\n", 1);
}
}

// Independent argv decoder plus byte-stream probe; only generated copies are launched.
extern "C" void shou_cli_probe_entry() {
    int count = 0; auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!arguments) ExitProcess(126);
    DWORD exitCode = 37;
    for (int index = 1; index < count; ++index) {
        if (lstrcmpW(arguments[index], L"--return-126") == 0) exitCode = 126;
        if (!emit("arg:", 4) || !hex(arguments[index], static_cast<DWORD>(lstrlenW(arguments[index])) * sizeof(wchar_t))) ExitProcess(126);
    }
    LocalFree(arguments);
    static wchar_t directory[32768];
    auto size = GetCurrentDirectoryW(32768, directory);
    if (!size || size >= 32768 || !emit("cwd:", 4) || !hex(directory, size * sizeof(wchar_t))) ExitProcess(126);
    static unsigned char input[131072]; DWORD total = 0, read = 0;
    while (ReadFile(GetStdHandle(STD_INPUT_HANDLE), input + total, sizeof(input) - total, &read, nullptr) && read) {
        total += read; if (total == sizeof(input)) ExitProcess(126);
    }
    if (!emit("stdin:", 6) || !hex(input, total) || !emit("generated probe stderr\n", 23, STD_ERROR_HANDLE)) ExitProcess(126);
    ExitProcess(exitCode);
}
