#include "fixture_contract.h"
#include <shellapi.h>
#include <filesystem>
#include <string>
#include <vector>

// GUI-subsystem process with no windows. No rendering, networking or child creation.
static bool writeNew(const std::wstring& path,const void* data,DWORD bytes) {
    HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;DWORD written=0;
    const BOOL ok=WriteFile(file,data,bytes,&written,nullptr);CloseHandle(file);return ok && written==bytes;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,LPWSTR,int) {
    int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(!argv)return 40;
    std::vector<std::wstring> args(argv,argv+argc);LocalFree(argv);
    size_t base=1;if(args.size()>3 && args[1]==L"--fixture-host-fault")base+=2;
    if(args.size()<base+8 || args[base]!=L"--report" || args[base+2]!=L"--module"
        || args[base+4]!=L"--hold-ms" || args[base+6]!=L"--exit-code")return 41;
    const auto reportPath=args[base+1];const int hold=_wtoi(args[base+5].c_str()),requestedExit=_wtoi(args[base+7].c_str());
    if(hold<0 || hold>20000 || requestedExit<0 || requestedExit>255)return 42;
    BeamRTStartupFixtureReport report{};report.bytes=sizeof(report);report.magic=beamrtStartupFixtureMagic;report.processId=GetCurrentProcessId();
    const auto module=GetModuleHandleW(args[base+3].c_str());
    using Query=BOOL(WINAPI*)(BeamRTStartupStatus*,DWORD);
    const auto query=module?reinterpret_cast<Query>(GetProcAddress(module,"BeamRT_StartupQuery")):nullptr;
    if(query)report.queryOK=query(&report.status,sizeof(report.status))?1u:0u;
    report.initialThread=report.status.attachThread==GetCurrentThreadId()?1u:0u;
    report.cwdMatches=std::filesystem::current_path()==std::filesystem::path(reportPath).parent_path()?1u:0u;
    const std::vector<std::wstring> expected={L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"};
    const size_t tail=base+8;bool matching=args.size()==tail+1+expected.size() && args[tail]==L"--";
    for(size_t i=0;matching && i<expected.size();++i)matching=args[tail+1+i]==expected[i];report.argsMatch=matching?1u:0u;
    const bool valid=report.queryOK && report.initialThread && report.cwdMatches && report.argsMatch
        && report.status.bytes==sizeof(report.status) && report.status.abi==1 && report.status.attached==1
        && report.status.processId==report.processId && !report.status.captureInstalled
        && !report.status.gpuWorkSubmitted && !report.status.lightingConsumed;
    if(!writeNew(reportPath,&report,sizeof(report)))return 43;
    if(hold)Sleep(static_cast<DWORD>(hold));
    const DWORD exitCode=valid?static_cast<DWORD>(requestedExit):44u;
    if(!writeNew(reportPath+L".done",&exitCode,sizeof(exitCode)))return 45;
    return static_cast<int>(exitCode);
}
