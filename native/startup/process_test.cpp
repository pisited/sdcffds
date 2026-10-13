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
    bool entry=false,autoEntry=false,initFailure=false;
    bool imports=false,missingImport=false;
    bool ordinalImport=false;
    bool pipeline=false,pipelineMiss=false,badShaderHash=false,existingRoot=false,wrongShaderStage=false;
    bool pipelineConflict=false;
};
static void run(const fs::path& root,const fs::path& directory,const Case& test) {
    const auto target=test.pipeline?root/L"beamrt_pipeline_startup_fixture.exe":test.imports && !test.missingImport?root/(test.ordinalImport?L"beamrt_import_ordinal_fixture.exe":L"beamrt_import_fixture.exe"):test.entry?root/L"beamrt_entry_fixture.exe":test.device?root/L"beamrt_device_fixture.exe":root/L"beamrt_startup_fixture.exe";
    const auto host=root/(test.faultHost?L"beamrt_startup_fault_host.exe":L"beamrt_startup_host.exe");
    const auto dll=root/(test.entry?(test.initFailure?L"beamrt_entry_fail_fixture.dll":test.autoEntry?L"beamrt_entry_auto_fixture.dll":L"beamrt_entry_passive_fixture.dll")
        :test.noReceipt?L"beamrt_startup_no_receipt.dll":L"beamrt_startup_bootstrap.dll");
    const auto report=directory/(std::string(test.name)+".bin");
    std::vector<std::wstring> args={L"--launch-reviewed",L"--target",target.wstring(),L"--dll",dll.wstring(),
        L"--workdir",directory.wstring(),L"--expected-target-sha256",hash(target),L"--expected-dll-sha256",test.badHash?std::wstring(64,L'0'):hash(dll),
        L"--acknowledge-native-insertion",L"startup-observation-only",L"--"};
    if(test.entry || test.imports || test.pipeline)args.insert(args.end()-1,L"--entry-rendezvous");
    if(test.imports || test.pipeline)args.insert(args.end()-1,L"--observe-device-import");
    const auto vs=root.parent_path()/L"native-capture/fixture.vs.cso",ps=root.parent_path()/L"native-capture/fixture.ps.cso";
    const auto rootOutput=directory/(std::string(test.name)+".root.bin");
    if(test.pipeline){
        const auto expectedPixel=test.wrongShaderStage?vs:test.pipelineMiss?root/L"fixture.alt.ps.cso":ps;
        if(test.existingRoot){std::ofstream sentinel(rootOutput,std::ios::binary);sentinel<<"preserve existing artifact";require(bool(sentinel),"root-output sentinel failed");}
        args.insert(args.end()-1,{L"--observe-gi-creation",L"--gi-vertex",vs.wstring(),L"--gi-pixel",expectedPixel.wstring(),
            L"--expected-gi-vertex-sha256",hash(vs),L"--expected-gi-pixel-sha256",test.badShaderHash?std::wstring(64,L'0'):hash(expectedPixel),
            L"--pipeline-root-out",rootOutput.wstring(),L"--pipeline-wait-seconds",(test.pipelineMiss || test.pipelineConflict)?L"1":L"10"});
    }
    if(!test.fault.empty())args.insert(args.end(),{L"--fixture-host-fault",test.fault});
    if(test.device || test.pipeline || (test.imports && !test.missingImport))args.insert(args.end(),{L"--device-backend",test.warp?L"warp":L"hardware"});
    if(test.pipeline)args.insert(args.end(),{L"--vs",vs.wstring(),L"--ps",ps.wstring()});
    if(test.pipelineConflict)args.insert(args.end(),L"--root-conflict");
    if(test.entry)args.insert(args.end(),{L"--entry-mode",test.initFailure?L"init-failure":test.autoEntry?L"auto":L"passive",
        L"--device-backend",test.warp?L"warp":L"hardware"});
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
        if(test.pipeline){
            const auto data=read<BeamRTPipelineFixtureReport>(report);result=data.startup;
            const auto& info=data.audit;require(info.bytes==sizeof(info) && info.abi==beamrtPipelineAuditInfoABI
                && info.enabled && info.rootsObserved>50 && info.cacheEvictions && info.metadataBytes<=beamrtPipelineMetadataBudget
                && info.attachedSlots>=2 && info.ownerThread==result.status.attachThread
                && !info.drawBindingsVerified && !info.cameraVerified && !info.gpuOrderingVerified && !info.lightingConsumed,"creation audit falsely certified draw/resources");
            if(test.pipelineConflict)require(!info.healthy && !info.creationMatchAvailable
                && info.failureReason==static_cast<uint32_t>(BeamRTPipelineFailure::rootEvidenceConflict) && info.failureResult==E_INVALIDARG,
                "startup fault did not preserve precise first failure");
            else require(info.healthy && !info.failureReason && info.liveRootTags==1 && info.liveLayouts==1,"startup metadata pressure/lifetime failed");
            require(data.matched==uint32_t(!test.pipelineMiss && !test.pipelineConflict) && !data.reserved,"creation match expectation failed");
            if(test.pipelineMiss || test.pipelineConflict)require(!data.ownerMatches && !data.rootBytes && !fs::exists(rootOutput),"no-match run wrote a root artifact");
            else {std::wstring digest;const wchar_t* hex=L"0123456789abcdef";for(uint8_t value:data.rootDigest){digest+=hex[value>>4];digest+=hex[value&15];}
                require(data.ownerMatches && data.rootBytes && fs::file_size(rootOutput)==data.rootBytes && hash(rootOutput)==digest,"parent root bytes differ from fixture's native root");}
        }else if(test.imports && !test.missingImport){
            const auto imported=read<BeamRTImportFixtureReport>(report);result=imported.startup;
            require(imported.testsMask==2047 && imported.guardsRejected>=7 && imported.warp==uint32_t(test.warp) && !imported.reserved,"import observer fixture guards/backend mismatch");
            const auto& before=imported.beforeDisable;const auto& after=imported.afterDisable;
            require(before.hookAttached && before.ambiguous && !before.complete && before.candidateReady && before.deviceResults>=2
                && !before.cameraVerified && !before.resourceStateChainVerified && !before.gpuOrderingVerified && !before.lightingConsumed,
                "import observation improperly certified a render device or graphics state");
            require(!after.hookAttached && after.slotRestored && after.protectionRestored && after.disabled && after.ambiguous && !after.complete,
                "import observer failed atomic disable/concurrent forwarding");
        }else if(test.entry){
            const auto entryReport=read<BeamRTEntryFixtureReport>(report);result=entryReport.startup;
            require(entryReport.frameMatches==1 && entryReport.preMainReached==1 && entryReport.warp==uint32_t(test.warp),"native entry state forwarding/pre-main/backend mismatch");
            const auto& info=entryReport.entry;
            require(info.abi==1 && info.bytes==sizeof(info) && info.armed && info.reached && info.released && !info.hookAttached
                && info.entryBytesRestored && SUCCEEDED(info.result) && !info.graphicsQuiescenceVerified && !info.cameraVerified
                && !info.gpuOrderingVerified && !info.lightingConsumed,"entry rendezvous improperly certified graphics context");
            if(test.autoEntry && !test.initFailure)require(info.deviceStarted && info.deviceStopped && SUCCEEDED(info.deviceResult)
                && entryReport.device.deviceResults==1 && entryReport.device.complete && !entryReport.device.lightingConsumed,"automatic fixture observer missed pre-main device");
            else require(!info.deviceStarted && !info.deviceStopped && (test.initFailure?FAILED(info.deviceResult):info.deviceResult==E_NOTIMPL),"passive/failed entry path activated device observer");
        }else if(test.device){
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
    if(test.existingRoot){std::ifstream sentinel(rootOutput,std::ios::binary);const std::string content((std::istreambuf_iterator<char>(sentinel)),std::istreambuf_iterator<char>());
        require(content=="preserve existing artifact","existing root output was overwritten");}
    std::cout<<"PASS: "<<test.name<<"; hostExit="<<exit<<"; totalProcesses="<<stats.TotalProcesses<<"; active=0\n"<<std::flush;
}
int wmain(int argc,wchar_t** argv) {
    try {
        require(argc==2 || (argc==3 && (std::wstring(argv[2])==L"--device" || std::wstring(argv[2])==L"--entry" || std::wstring(argv[2])==L"--import" || std::wstring(argv[2])==L"--pipeline")),"usage: process_test <owned native-startup artifact directory> [--device|--entry|--import|--pipeline]");const auto root=fs::canonical(argv[1]);
        const bool devices=argc==3 && std::wstring(argv[2])==L"--device",entries=argc==3 && std::wstring(argv[2])==L"--entry",imports=argc==3 && std::wstring(argv[2])==L"--import",pipelines=argc==3 && std::wstring(argv[2])==L"--pipeline";
        require(root.filename()==L"native-startup" && root.parent_path().filename()==L".beamrt-validation","fixture confined to native-startup artifacts");
        for(const wchar_t* name:{L"beamrt_startup_fixture.exe",L"beamrt_startup_host.exe",L"beamrt_startup_fault_host.exe",
            L"beamrt_startup_bootstrap.dll",L"beamrt_startup_no_receipt.dll"})require(fs::is_regular_file(root/name),"required owned fixture artifact missing");
        if(devices)require(fs::is_regular_file(root/L"beamrt_device_fixture.exe"),"device fixture missing");
        if(pipelines)require(fs::is_regular_file(root/L"beamrt_pipeline_startup_fixture.exe") && fs::is_regular_file(root/L"fixture.alt.ps.cso"),"pipeline startup fixtures missing");
        if(imports)for(const wchar_t* name:{L"beamrt_import_fixture.exe",L"beamrt_import_ordinal_fixture.exe"})require(fs::is_regular_file(root/name),"import fixture missing");
        if(entries)for(const wchar_t* name:{L"beamrt_entry_fixture.exe",L"beamrt_entry_passive_fixture.dll",L"beamrt_entry_auto_fixture.dll",L"beamrt_entry_fail_fixture.dll"})
            require(fs::is_regular_file(root/name),"entry fixture missing");
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
        if(pipelines){
            for(bool warp:{false,true}){Case test{warp?"pipeline-startup-warp":"pipeline-startup-hardware"};test.pipeline=true;test.warp=warp;test.hold=1000;run(root,directory,test);}
            for(bool warp:{false,true}){Case test{warp?"pipeline-conflict-warp":"pipeline-conflict-hardware"};test.pipeline=true;test.pipelineConflict=true;
                test.warp=warp;test.hostExit=7;test.hold=2500;test.expectAliveAfterHost=true;run(root,directory,test);}
            Case miss{"pipeline-installed-without-match"};miss.pipeline=true;miss.pipelineMiss=true;miss.hostExit=7;miss.hold=2500;miss.expectAliveAfterHost=true;run(root,directory,miss);
            Case bad{"pipeline-shader-hash-refused"};bad.pipeline=true;bad.badShaderHash=true;bad.hostExit=1;bad.totalProcesses=1;bad.expectEntry=false;run(root,directory,bad);
            Case exists{"pipeline-output-preserved"};exists.pipeline=true;exists.existingRoot=true;exists.hostExit=1;exists.totalProcesses=1;exists.expectEntry=false;run(root,directory,exists);
            Case stage{"pipeline-wrong-stage-refused"};stage.pipeline=true;stage.wrongShaderStage=true;stage.hostExit=1;stage.totalProcesses=1;stage.expectEntry=false;run(root,directory,stage);
        }else if(imports){
            for(bool warp:{false,true}){Case test{warp?"import-warp":"import-hardware"};test.imports=true;test.warp=warp;test.hold=1000;run(root,directory,test);}
            for(bool warp:{false,true}){Case test{warp?"import-ordinal-warp":"import-ordinal-hardware"};test.imports=true;test.ordinalImport=true;test.warp=warp;test.hold=1000;run(root,directory,test);}
            Case absent{"import-absent-fails-closed"};absent.imports=true;absent.missingImport=true;absent.hostExit=5;absent.hold=1000;run(root,directory,absent);
        }else if(entries){
            Case passive{"entry-passive"};passive.entry=true;passive.hold=1000;run(root,directory,passive);
            for(bool warp:{false,true}){Case test{warp?"entry-auto-warp":"entry-auto-hardware"};test.entry=true;test.autoEntry=true;test.warp=warp;test.hold=1000;run(root,directory,test);}
            Case failed{"entry-init-failure-fallback"};failed.entry=true;failed.autoEntry=true;failed.initFailure=true;failed.hold=1000;run(root,directory,failed);
        }else if(devices){
            for(bool warp:{false,true}){Case test{warp?"device-warp":"device-hardware"};test.device=true;test.warp=warp;test.hold=1000;run(root,directory,test);}
        }else for(const auto& test:tests)run(root,directory,test);
        std::wcout<<L"PASS: "<<(pipelines?8:imports?5:entries?4:devices?2:9)<<L" disposable "<<(pipelines?L"startup-connected pipeline":imports?L"import-observer":entries?L"entry-rendezvous":devices?L"device-observer":L"startup")<<L" cases; all private jobs drained. Reports: "<<directory.wstring()
            <<L"\nNo game executable selected or started; no capture/GI renderer loaded.\n";return 0;
    }catch(const std::exception& error){std::cerr<<"Startup process fixture failed: "<<error.what()<<'\n';return 1;}
}
