#include <windows.h>
// Disposable loader control only. The import library is built, but no DLL
// providing this symbol is supplied. Windows must refuse before entry/attach.
extern "C" __declspec(dllimport) void BeamRT_MissingFixtureDependency();
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
    BeamRT_MissingFixtureDependency();
    return 99; // Reaching this entry is a fixture failure, not a valid receipt.
}
