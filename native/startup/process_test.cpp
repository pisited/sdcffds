#include "fixture_contract.h"
#include <bcrypt.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
namespace fs=std::filesystem;
static void require(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
static void check(BOOL ok,const char* why){if(!ok)throw std::runtime_error(std::string(why)+" Win32="+std::to_string(GetLastError()));}
struct Handle {
    HANDLE value=nullptr;explicit Handle(HANDLE h):value(h){}
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
    Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;
};
static std::wstring quote(const std::wstring& arg) {
    std::wstring out=L"\"";size_t slashes=0;
    for(wchar_t c:arg){if(c==L'\\'){++slashes;continue;}
        out.append(c==L'\"'?slashes*2+1:slashes,L'\\');out+=c;slashes=0;}
    out.append(slashes*2,L'\\');out+=L'\"';return out;
}
static std::wstring hash(const fs::path& path) {
    std::ifstream file(path,std::ios::binary|std::ios::ate);require(bool(file),"fixture hash file unavailable");const auto size=file.tellg();
    require(size>0 && size<=16*1024*1024,"fixture artifact exceeds hash budget");std::vector<uint8_t> bytes(static_cast<size_t>(size));
    file.seekg(0);file.read(reinterpret_cast<char*>(bytes.data()),static_cast<std::streamsize>(bytes.size()));require(bool(file),"fixture hash read failed");
    BCRYPT_ALG_HANDLE algorithm=nullptr;require(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0,"fixture hash algorithm");
    uint8_t output[32]{};const NTSTATUS status=BCryptHash(algorithm,nullptr,0,bytes.data(),static_cast<ULONG>(bytes.size()),output,sizeof(output));
    BCryptCloseAlgorithmProvider(algorithm,0);require(status>=0,"fixture hash failed");std::wstring result;const wchar_t* hex=L"0123456789abcdef";
    for(uint8_t value:output){result+=hex[value>>4];result+=hex[value&15];}return result;
}
static JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting(HANDLE job) {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info{};
    check(QueryInformationJobObject(job,JobObjectBasicAccountingInformation,&info,sizeof(info),nullptr),"fixture job accounting");return info;
}
static void describeOwnedJob(HANDLE job) {
    std::vector<uint8_t> bytes(sizeof(JOBOBJECT_BASIC_PROCESS_ID_LIST)+16*sizeof(ULONG_PTR));
    auto ids=reinterpret_cast<JOBOBJECT_BASIC_PROCESS_ID_LIST*>(bytes.data());
    if(!QueryInformationJobObject(job,JobObjectBasicProcessIdList,ids,static_cast<DWORD>(bytes.size()),nullptr))return;
    for(DWORD i=0;i<ids->NumberOfProcessIdsInList;++i){
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,static_cast<DWORD>(ids->ProcessIdList[i])));
        BOOL member=FALSE;if(!process.value || !IsProcessInJob(process.value,job,&member) || !member)continue;
        wchar_t path[32768]{};DWORD count=32768;
        if(QueryFullProcessImageNameW(process.value,0,path,&count))std::wcerr<<L"Owned fixture job PID "<<ids->ProcessIdList[i]<<L": "<<path<<L'\n';
    }
}
static HANDLE retainOwnedTarget(HANDLE job,const fs::path& target) {
    std::vector<uint8_t> bytes(sizeof(JOBOBJECT_BASIC_PROCESS_ID_LIST)+16*sizeof(ULONG_PTR));
    auto ids=reinterpret_cast<JOBOBJECT_BASIC_PROCESS_ID_LIST*>(bytes.data());
    if(!QueryInformationJobObject(job,JobObjectBasicProcessIdList,ids,static_cast<DWORD>(bytes.size()),nullptr))return nullptr;
    for(DWORD i=0;i<ids->NumberOfProcessIdsInList;++i){
        HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,static_cast<DWORD>(ids->ProcessIdList[i]));
        if(!process)continue;BOOL member=FALSE;wchar_t path[32768]{};DWORD count=32768;
        if(IsProcessInJob(process,job,&member) && member && QueryFullProcessImageNameW(process,0,path,&count)
            && fs::path(path)==target)return process;
        CloseHandle(process);
    }
    return nullptr;
}
static void waitEmpty(HANDLE job) {
    const auto deadline=GetTickCount64()+30000;
    while(accounting(job).ActiveProcesses){require(GetTickCount64()<deadline,"owned fixture job did not drain");Sleep(10);}
}
template<class T>static T read(const fs::path& path) {
    T out{};std::ifstream file(path,std::ios::binary|std::ios::ate);require(bool(file) && file.tellg()==static_cast<std::streamoff>(sizeof(T)),"fixture report missing/incorrect size");
    file.seekg(0);file.read(reinterpret_cast<char*>(&out),sizeof(out));require(bool(file),"fixture report unreadable");return out;
}
struct Case {
    const char* name;bool faultHost=false,noReceipt=false,badHash=false;
    std::wstring fault;DWORD hostExit=0,hold=0,targetExit=0,totalProcesses=2;
    bool expectEntry=true,expectAliveAfterHost=false;
    bool device=false,warp=false;
};
static void run(const fs::path& root,const fs::path& directory,const Case& test) {
    const auto target=test.device?root/L"beamrt_device_fixture.exe":root/L"beamrt_startup_fixture.exe";
    const auto host=root/(test.faultHost?L"beamrt_startup_fault_host.exe":L"beamrt_startup_host.exe");
    const auto dll=root/(test.noReceipt?L"beamrt_startup_no_receipt.dll":L"beamrt_startup_bootstrap.dll");
    const auto report=directory/(std::string(test.name)+".bin");
    std::vector<std::wstring> args={L"--launch-reviewed",L"--target",target.wstring(),L"--dll",dll.wstring(),
        L"--workdir",directory.wstring(),L"--expected-target-sha256",hash(target),L"--expected-dll-sha256",test.badHash?std::wstring(64,L'0'):hash(dll),
        L"--acknowledge-native-insertion",L"startup-observation-only",L"--"};
    if(!test.fault.empty())args.insert(args.end(),{L"--fixture-host-fault",test.fault});
    if(test.device)args.insert(args.end(),{L"--device-backend",test.warp?L"warp":L"hardware"});
    args.insert(args.end(),{L"--report",report.wstring(),L"--module",dll.filename().wstring(),L"--hold-ms",std::to_wstring(test.hold),
        L"--exit-code",std::to_wstring(test.targetExit),L"--",L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"});
    auto command=quote(host.wstring());for(const auto& a:args)command+=L" "+quote(a);
    std::vector<wchar_t> mutableCommand(command.begin(),command.end());mutableCommand.push_back(0);
    Handle job(CreateJobObjectW(nullptr,nullptr));check(job.value!=nullptr,"create private fixture job");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    check(SetInformationJobObject(job.value,JobObjectExtendedLimitInformation,&limits,sizeof(limits)),"fixture kill-on-close scope");
    // Only our newly created launcher and its inherited disposable child enter
    // this unnamed job. No process enumeration or existing-process attachment.
    STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;PROCESS_INFORMATION process{};
    // Reuse the test console instead of requesting another headless console
    // host, which is an additional OS-owned process on this Windows version.
    check(CreateProcessW(host.c_str(),mutableCommand.data(),nullptr,nullptr,FALSE,CREATE_SUSPENDED,
        nullptr,directory.c_str(),&startup,&process),"create fixture launcher");
    Handle launcher(process.hProcess),thread(process.hThread);
    if(!AssignProcessToJobObject(job.value,process.hProcess)){
        const auto error=GetLastError();TerminateProcess(process.hProcess,1);WaitForSingleObject(process.hProcess,5000);
        SetLastError(error);check(FALSE,"assign owned launcher to fixture job");}
    const auto started=GetTickCount64();require(ResumeThread(process.hThread)==1,"resume fixture launcher");
    Handle targetProcess(nullptr);
    for(;;){
        if(!targetProcess.value)targetProcess.value=retainOwnedTarget(job.value,target);
        const DWORD wait=WaitForSingleObject(process.hProcess,10);if(wait==WAIT_OBJECT_0)break;
        require(wait==WAIT_TIMEOUT && GetTickCount64()-started<30000,"fixture launcher timed out");
    }
    if(test.expectEntry && !targetProcess.value)targetProcess.value=retainOwnedTarget(job.value,target);
    DWORD exit=0;check(GetExitCodeProcess(process.hProcess,&exit),"fixture launcher exit");
    if(exit!=test.hostExit)throw std::runtime_error(std::string(test.name)+": launcher exit="+std::to_string(exit)+", expected="+std::to_string(test.hostExit));
    auto stats=accounting(job.value);
    if(stats.TotalProcesses!=test.totalProcesses){describeOwnedJob(job.value);throw std::runtime_error(std::string(test.name)+": job total="+std::to_string(stats.TotalProcesses)
        +", active="+std::to_string(stats.ActiveProcesses)+", expected total="+std::to_string(test.totalProcesses));}
    if(test.expectAliveAfterHost)require(stats.ActiveProcesses==1,"launcher terminated its resumed fixture child");
    if(test.noReceipt && test.hold>=16000)require(GetTickCount64()-started>=14000,"missing receipt bypassed the real timeout");
    waitEmpty(job.value);stats=accounting(job.value);require(!stats.ActiveProcesses,"fixture child orphaned");
    if(test.expectEntry){
        BeamRTStartupFixtureReport result{};
        if(test.device){
            const auto deviceReport=read<BeamRTDeviceFixtureReport>(report);result=deviceReport.startup;
            if(deviceReport.errorStep || deviceReport.testsMask!=511)throw std::runtime_error(std::string(test.name)+": device test step="
                +std::to_string(deviceReport.errorStep)+", mask="+std::to_string(deviceReport.testsMask));
            require(deviceReport.guardsRejected>=9 && deviceReport.warp==uint32_t(test.warp),"device guard/backend mismatch");
            const auto& info=deviceReport.observation;
            require(info.abi==1 && info.bytes==sizeof(info) && info.complete && info.calls==4 && info.deviceResults==2
                && info.probes==1 && info.failedCalls==1 && !info.cameraVerified && !info.resourceStateChainVerified
                && !info.gpuOrderingVerified && !info.lightingConsumed,"device observation improperly certified render resources");
        }else result=read<BeamRTStartupFixtureReport>(report);
        const auto done=read<DWORD>(report.wstring()+L".done");
        require(targetProcess.value && result.processId==GetProcessId(targetProcess.value),"fixture report not bound to retained owned child");
        DWORD childExit=0;check(GetExitCodeProcess(targetProcess.value,&childExit),"retained fixture child exit");
        require(childExit==test.targetExit && childExit!=STILL_ACTIVE,"actual child exit differs from fixture report");
        require(result.bytes==sizeof(result) && result.magic==beamrtStartupFixtureMagic && result.queryOK==1
            && result.initialThread==1 && result.cwdMatches==1 && result.argsMatch==1 && result.processId>0 && !result.reserved,
            "fixture entry/arguments/directory/loaded status mismatch");
        require(result.status.attached==1 && result.status.abi==1 && result.status.bytes==sizeof(result.status)
            && result.status.processId==result.processId && !result.status.captureInstalled && !result.status.gpuWorkSubmitted
            && !result.status.lightingConsumed && done==test.targetExit,"startup receipt incorrectly certified rendering or wrong fixture exit");
    }else require(!fs::exists(report) && !fs::exists(report.wstring()+L".done"),"pre-resume failure executed target entry");
    std::cout<<"PASS: "<<test.name<<"; hostExit="<<exit<<"; totalProcesses="<<stats.TotalProcesses<<"; active=0\n"<<std::flush;
}
int wmain(int argc,wchar_t** argv) {
    try {
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--device"),"usage: process_test <owned native-startup artifact directory> [--device]");const auto root=fs::canonical(argv[1]);
        const bool devices=argc==3;
        require(root.filename()==L"native-startup" && root.parent_path().filename()==L".beamrt-validation","fixture confined to native-startup artifacts");
        for(const wchar_t* name:{L"beamrt_startup_fixture.exe",L"beamrt_startup_host.exe",L"beamrt_startup_fault_host.exe",
            L"beamrt_startup_bootstrap.dll",L"beamrt_startup_no_receipt.dll"})require(fs::is_regular_file(root/name),"required owned fixture artifact missing");
        if(devices)require(fs::is_regular_file(root/L"beamrt_device_fixture.exe"),"device fixture missing");
        // No dialogs/windows on expected loader/test failures; children inherit.
        SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
        const auto directory=root/(L"process-tests-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
        require(fs::create_directory(directory),"fresh fixture report directory unavailable");
        const Case tests[]={
            {"receipt-and-exact-arguments",false,false,false,L"",0,250},
            {"receipt-does-not-certify-target-success",false,false,false,L"",0,250,37},
            {"hash-refused-before-child",false,false,true,L"",1,0,0,1,false},
            {"cleanup-before-insert",true,false,false,L"before-insert",1,0,0,2,false},
            {"cleanup-before-payload",true,false,false,L"before-payload",1,0,0,2,false},
            {"cleanup-before-resume",true,false,false,L"before-resume",1,0,0,2,false},
            {"failure-after-resume-retains-child",true,false,false,L"after-resume",1,1000,0,2,true,true},
            {"missing-receipt-child-exit",false,true,false,L"",2,250},
            {"missing-receipt-real-timeout",false,true,false,L"",2,18000,0,2,true,true}
        };
        if(devices){
            for(bool warp:{false,true}){Case test{warp?"device-warp":"device-hardware"};test.device=true;test.warp=warp;test.hold=1000;run(root,directory,test);}
        }else for(const auto& test:tests)run(root,directory,test);
        std::wcout<<L"PASS: "<<(devices?2:9)<<L" disposable "<<(devices?L"device-observer":L"startup")<<L" cases; all private jobs drained. Reports: "<<directory.wstring()
            <<L"\nNo game executable selected or started; no capture/GI renderer loaded.\n";return 0;
    }catch(const std::exception& error){std::cerr<<"Startup process fixture failed: "<<error.what()<<'\n';return 1;}
}
