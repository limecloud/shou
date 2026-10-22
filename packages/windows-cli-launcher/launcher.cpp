#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

// Kernel32-only entry point: the user command needs neither Swift nor a CRT beside it.
namespace {
wchar_t own[32768], manifest[32768], target[16001], command[32768];
char bytes[32768];
HANDLE pins[512];
DWORD pinCount = 0;
bool launchFailed = true;

bool append(wchar_t *output, DWORD &size, const wchar_t *value, DWORD count) {
    if (count > 32766 - size) return false;
    for (DWORD index = 0; index < count; ++index) output[size++] = value[index];
    output[size] = 0; return true;
}

bool localPath(const wchar_t *path, DWORD size) {
    if (size < 4 || size > 16000 || path[1] != L':' || (path[2] != L'\\' && path[2] != L'/') ||
        !((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z'))) return false;
    for (DWORD start = 3; start < size;) {
        DWORD end = start;
        while (end < size && path[end] != L'/' && path[end] != L'\\') {
            auto c = path[end++];
            if (c < 32 || c == L'<' || c == L'>' || c == L':' || c == L'"' || c == L'|' || c == L'?' || c == L'*') return false;
        }
        if (end == start || (end - start == 1 && path[start] == L'.') ||
            (end - start == 2 && path[start] == L'.' && path[start + 1] == L'.') || path[end - 1] == L'.' || path[end - 1] == L' ') return false;
        start = end + 1;
    }
    wchar_t drive[] = {path[0], L':', L'\\', 0};
    return GetDriveTypeW(drive) == DRIVE_FIXED;
}

bool pin(const wchar_t *input, DWORD size, HANDLE &file) {
    if (!localPath(input, size)) return false;
    // Reuse a heap buffer rather than placing a long Windows path on the stack.
    auto path = static_cast<wchar_t *>(HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, (size + 5) * sizeof(wchar_t)));
    if (!path) return false;
    path[0] = L'\\'; path[1] = L'\\'; path[2] = L'?'; path[3] = L'\\';
    for (DWORD index = 0; index < size; ++index) path[index + 4] = input[index] == L'/' ? L'\\' : input[index];
    bool success = false;
    DWORD end = 3;
    while (pinCount < 512) {
        const bool final = end == size;
        const auto saved = path[end + 4]; path[end + 4] = 0;
        auto handle = CreateFileW(path, final ? GENERIC_READ : FILE_READ_ATTRIBUTES,
            final ? FILE_SHARE_READ : FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        path[end + 4] = saved;
        if (handle == INVALID_HANDLE_VALUE) break;
        pins[pinCount++] = handle;
        FILE_ATTRIBUTE_TAG_INFO tag;
        if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag, sizeof(tag)) ||
            (tag.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_OFFLINE | 0x00440000))) break;
        if (final) { file = handle; success = !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY); break; }
        if (!(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) break;
        DWORD next = end == 3 ? 3 : end + 1;
        while (next < size && path[next + 4] != L'\\') ++next;
        end = next;
    }
    HeapFree(GetProcessHeap(), 0, path); return success;
}

BOOL WINAPI consoleControl(DWORD event) { return event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT; }

DWORD run() {
    const auto length = GetModuleFileNameW(nullptr, own, 32768);
    if (!length || length >= 32768) return 126;
    DWORD separator = length;
    while (separator && own[separator - 1] != L'\\' && own[separator - 1] != L'/') --separator;
    DWORD manifestSize = 0;
    if (!separator || !append(manifest, manifestSize, own, separator) || !append(manifest, manifestSize, L"shou.target", 11)) return 126;
    HANDLE input = nullptr;
    if (!pin(manifest, manifestSize, input)) return 126;
    LARGE_INTEGER size; DWORD count = 0;
    if (!GetFileSizeEx(input, &size) || size.QuadPart < 24 || size.QuadPart > 32768 ||
        !ReadFile(input, bytes, static_cast<DWORD>(size.QuadPart), &count, nullptr) || count != size.QuadPart) return 126;
    static constexpr char header[] = "Shou CLI target v1\n";
    constexpr DWORD headerSize = sizeof(header) - 1;
    for (DWORD index = 0; index < headerSize; ++index) if (bytes[index] != header[index]) return 126;
    if (bytes[count - 1] != '\n') return 126;
    const auto units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes + headerSize, count - headerSize - 1, target, 16000);
    if (units < 9 || (CompareStringOrdinal(target + units - 9, 9, L"/shou.exe", 9, TRUE) != CSTR_EQUAL &&
        CompareStringOrdinal(target + units - 9, 9, L"\\shou.exe", 9, TRUE) != CSTR_EQUAL) || !pin(target, units, input)) return 126;
    target[units] = 0;
    BY_HANDLE_FILE_INFORMATION targetInfo, ownInfo; HANDLE ownHandle = nullptr;
    if (!GetFileInformationByHandle(input, &targetInfo) || !pin(own, length, ownHandle) || !GetFileInformationByHandle(ownHandle, &ownInfo)) return 126;
    if (ownInfo.dwVolumeSerialNumber == targetInfo.dwVolumeSerialNumber && ownInfo.nFileIndexHigh == targetInfo.nFileIndexHigh && ownInfo.nFileIndexLow == targetInfo.nFileIndexLow) return 126;
    // Keep the original argument tail intact, including empty arguments, quotes and backslashes.
    auto tail = GetCommandLineW(); bool quoted = false;
    while (*tail) { if (*tail == L'"') quoted = !quoted; else if (!quoted && (*tail == L' ' || *tail == L'\t')) break; ++tail; }
    while (*tail == L' ' || *tail == L'\t') ++tail;
    DWORD tailSize = 0; while (tail[tailSize] && tailSize < 32767) ++tailSize;
    DWORD commandSize = 0;
    if (!append(command, commandSize, L"\"", 1) || !append(command, commandSize, target, units) ||
        !append(command, commandSize, L"\" ", 2) || !append(command, commandSize, tail, tailSize)) return 126;
    static STARTUPINFOW startup; static PROCESS_INFORMATION process;
    startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE); startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE); startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    // A custom parent handler is not inherited; the child retains normal Ctrl+C handling.
    SetConsoleCtrlHandler(consoleControl, TRUE);
    if (!CreateProcessW(target, command, nullptr, nullptr, TRUE, 0, nullptr, nullptr, &startup, &process)) return 126;
    launchFailed = false;
    CloseHandle(process.hThread);
    DWORD exitCode = 126;
    if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess); return exitCode;
}
}

extern "C" void shou_cli_entry() {
    auto result = run();
    while (pinCount) CloseHandle(pins[--pinCount]);
    if (launchFailed) {
        static constexpr char message[] = "Shou CLI could not start. Keep the complete Shou package at its installed location and reinstall the CLI command from Settings.\r\n";
        DWORD written = 0; WriteFile(GetStdHandle(STD_ERROR_HANDLE), message, sizeof(message) - 1, &written, nullptr);
    }
    ExitProcess(result);
}
