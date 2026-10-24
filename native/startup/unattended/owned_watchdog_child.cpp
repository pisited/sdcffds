#define NOMINMAX
#include <windows.h>
#include <shellapi.h>

#include <string>

// Fixed disposable Windows-subsystem child. It cannot load a DLL, run a shell,
// spawn a process, or write a game setting. Every mode self-exits within 15 s.
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    int count = 0;
    LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!arguments || count != 4) { if (arguments) LocalFree(arguments); return 241; }
    const std::wstring mode = arguments[1];
    const std::wstring quitName = arguments[2];
    const std::wstring readyName = arguments[3];
    LocalFree(arguments);
    if (mode != L"cooperative" && mode != L"ignore" && mode != L"exit259" && mode != L"release42") return 241;
    HANDLE quit = OpenEventW(SYNCHRONIZE, FALSE, quitName.c_str());
    HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, readyName.c_str());
    if (!quit || !ready) {
        if (quit) CloseHandle(quit);
        if (ready) CloseHandle(ready);
        return 242;
    }
    SetEvent(ready);
    CloseHandle(ready);
    if (mode == L"exit259") { CloseHandle(quit); return 259; }
    if (mode == L"ignore") { Sleep(15000); CloseHandle(quit); return 240; }
    const DWORD waited = WaitForSingleObject(quit, 15000);
    CloseHandle(quit);
    return waited == WAIT_OBJECT_0 ? (mode == L"release42" ? 42 : 0) : 240;
}
