#include "fixture_contract.h"
#include "binding_handoff.h"
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
// Fixture-only evidence. Run the original artifacts at their original paths;
// the copies are evidence, not a replacement loader path or diagnostic host.
static void preserveInputs(const fs::path& root,const fs::path& directory) {
    const auto inputs=directory/L"inputs";require(fs::create_directory(inputs),"fresh evidence directory unavailable");
    std::wofstream manifest(directory/L"inputs.sha256.tsv",std::ios::binary);
    require(bool(manifest),"fixture input manifest unavailable");manifest<<L"sha256\tsource\tcopy\n";
    auto preserve=[&](const fs::path& source,const std::wstring& name){
        const auto destination=inputs/name;const auto before=hash(source);
        require(fs::copy_file(source,destination,fs::copy_options::none),"fixture input preservation failed");
        require(hash(destination)==before && hash(source)==before,"fixture input changed during preservation");
        manifest<<before<<L'\t'<<source.wstring()<<L'\t'<<destination.wstring()<<L'\n';
        require(bool(manifest),"fixture input manifest write failed");
    };
    for(const auto& file:fs::directory_iterator(root)){
        const auto extension=file.path().extension();
        if(file.is_regular_file() && (extension==L".exe" || extension==L".dll" || extension==L".cso"))
            preserve(file.path(),file.path().filename().wstring());
    }
    for(const wchar_t* name:{L"fixture.vs.cso",L"fixture.ps.cso"}){
        const auto source=root.parent_path()/L"native-capture"/name;
        if(fs::is_regular_file(source))preserve(source,std::wstring(L"capture-")+name);
    }
    manifest.flush();require(bool(manifest),"fixture input manifest flush failed");
    std::wcout<<L"Preserved exact fixture inputs: "<<inputs.wstring()<<L'\n'<<std::flush;
}
struct FixtureLog {
    fs::path path;Handle output,input;std::vector<uint8_t> storage;LPPROC_THREAD_ATTRIBUTE_LIST attributes=nullptr;
    HANDLE inherited[2]{};
    explicit FixtureLog(const fs::path& file):path(file),output(nullptr),input(nullptr){
        SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};
        output.value=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,&security,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        check(output.value!=INVALID_HANDLE_VALUE,"fresh fixture host log");
        input.value=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,nullptr);
        check(input.value!=INVALID_HANDLE_VALUE,"fixture host null input");
        inherited[0]=output.value;inherited[1]=input.value;SIZE_T bytes=0;
        InitializeProcThreadAttributeList(nullptr,1,0,&bytes);require(bytes>0,"fixture log attribute size");storage.resize(bytes);
        attributes=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
        check(InitializeProcThreadAttributeList(attributes,1,0,&bytes),"fixture log attributes");
        if(!UpdateProcThreadAttribute(attributes,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,inherited,sizeof(inherited),nullptr,nullptr)){
            const auto error=GetLastError();DeleteProcThreadAttributeList(attributes);attributes=nullptr;
            SetLastError(error);check(FALSE,"restrict fixture host log inheritance");}
    }
    ~FixtureLog(){if(attributes)DeleteProcThreadAttributeList(attributes);}
    std::string replay() const {
        check(FlushFileBuffers(output.value),"flush fixture host log");
        std::ifstream file(path);require(bool(file),"fixture host log unavailable");
        // Do not insert an empty rdbuf: that sets failbit on the shared console.
        const std::string contents((std::istreambuf_iterator<char>(file)),std::istreambuf_iterator<char>());
        std::cout<<contents<<std::flush;return contents;
    }
};
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
    bool bindingFixture=false,bindingObserve=false,existingBinding=false;std::wstring bindingMode=L"normal";
    bool loaderMissingDependency=false;
    bool existingThreadEvidence=false;
    bool resourceFixture=false,resourceObserve=false,existingResource=false;uint32_t resourceProbeBytes=16;
    bool resourceDescriptorsOnly=false;
    bool resourceCompactStorage=false;
    bool resourceInternedStorage=false;
};
static void run(const fs::path& root,const fs::path& directory,const Case& test) {
    const auto target=test.loaderMissingDependency?root/L"beamrt_loader_missing_fixture.exe":test.bindingFixture?root/L"beamrt_binding_startup_fixture.exe":test.pipeline?root/L"beamrt_pipeline_startup_fixture.exe":test.imports && !test.missingImport?root/(test.ordinalImport?L"beamrt_import_ordinal_fixture.exe":L"beamrt_import_fixture.exe"):test.entry?root/L"beamrt_entry_fixture.exe":test.device?root/L"beamrt_device_fixture.exe":root/L"beamrt_startup_fixture.exe";
    const auto host=root/(test.faultHost?L"beamrt_startup_fault_host.exe":L"beamrt_startup_host.exe");
    const auto dll=root/(test.entry?(test.initFailure?L"beamrt_entry_fail_fixture.dll":test.autoEntry?L"beamrt_entry_auto_fixture.dll":L"beamrt_entry_passive_fixture.dll")
        :test.noReceipt?L"beamrt_startup_no_receipt.dll":L"beamrt_startup_bootstrap.dll");
    const auto report=directory/(std::string(test.name)+".bin");
    std::vector<std::wstring> args={L"--launch-reviewed",L"--target",target.wstring(),L"--dll",dll.wstring(),
        L"--workdir",directory.wstring(),L"--expected-target-sha256",hash(target),L"--expected-dll-sha256",test.badHash?std::wstring(64,L'0'):hash(dll),
        L"--acknowledge-native-insertion",L"startup-observation-only",L"--"};
    if(test.entry || test.imports || test.pipeline)args.insert(args.end()-1,L"--entry-rendezvous");
    if(test.imports || test.pipeline)args.insert(args.end()-1,L"--observe-device-import");
    const auto vs=test.bindingFixture?root/L"binding.vs.cso":root.parent_path()/L"native-capture/fixture.vs.cso",ps=test.bindingFixture?root/L"binding.ps.cso":root.parent_path()/L"native-capture/fixture.ps.cso";
    const auto rootOutput=directory/(std::string(test.name)+".root.bin");
    const auto bindingOutput=directory/(std::string(test.name)+".bindings.bin");
    if(test.existingBinding){std::ofstream sentinel(bindingOutput,std::ios::binary);sentinel<<"preserve binding artifact";require(bool(sentinel),"binding sentinel failed");}
    if(test.existingThreadEvidence){std::ofstream sentinel(bindingOutput.wstring()+L".threads.bin",std::ios::binary);sentinel<<"preserve thread evidence";require(bool(sentinel),"thread sentinel failed");}
    if(test.existingResource){std::ofstream sentinel(bindingOutput.wstring()+L".resources.bin",std::ios::binary);sentinel<<"preserve resource evidence";require(bool(sentinel),"resource sentinel failed");}
    if(test.pipeline){
        const auto expectedPixel=test.wrongShaderStage?vs:test.pipelineMiss?root/L"fixture.alt.ps.cso":ps;
        if(test.existingRoot){std::ofstream sentinel(rootOutput,std::ios::binary);sentinel<<"preserve existing artifact";require(bool(sentinel),"root-output sentinel failed");}
        args.insert(args.end()-1,{L"--observe-gi-creation",L"--gi-vertex",vs.wstring(),L"--gi-pixel",expectedPixel.wstring(),
            L"--expected-gi-vertex-sha256",hash(vs),L"--expected-gi-pixel-sha256",test.badShaderHash?std::wstring(64,L'0'):hash(expectedPixel),
            L"--pipeline-root-out",rootOutput.wstring(),L"--pipeline-wait-seconds",(test.pipelineMiss || test.pipelineConflict)?L"1":L"10"});
    }
    if(test.bindingObserve)args.insert(args.end()-1,{L"--observe-gi-bindings",L"--bindings-out",bindingOutput.wstring(),L"--bindings-wait-seconds",test.hostExit==10?L"1":L"10"});
    if(test.resourceObserve){args.insert(args.end()-1,L"--observe-gi-resources");if(test.resourceProbeBytes)args.insert(args.end()-1,{L"--resource-cbv-probe-bytes",std::to_wstring(test.resourceProbeBytes)});
        if(test.resourceDescriptorsOnly){require(!test.resourceProbeBytes,"descriptor startup case requested a CBV probe");args.insert(args.end()-1,L"--resource-descriptors-only");}
        require(!test.resourceCompactStorage || !test.resourceInternedStorage,"resource fixture selected conflicting storage profiles");
        if(test.resourceCompactStorage){require(test.resourceDescriptorsOnly && !test.resourceProbeBytes,"compact startup case requires descriptor-only mode");args.insert(args.end()-1,L"--resource-compact-storage");}
        if(test.resourceInternedStorage){require(test.resourceDescriptorsOnly && !test.resourceProbeBytes,"interned startup case requires descriptor-only mode");args.insert(args.end()-1,L"--resource-interned-storage");}}
    if(!test.fault.empty())args.insert(args.end(),{L"--fixture-host-fault",test.fault});
    if(test.device || test.pipeline || (test.imports && !test.missingImport))args.insert(args.end(),{L"--device-backend",test.warp?L"warp":L"hardware"});
    if(test.pipeline)args.insert(args.end(),{L"--vs",vs.wstring(),L"--ps",ps.wstring()});
    if(test.bindingFixture)args.insert(args.end(),{L"--binding-case",test.bindingMode});
    if(test.pipelineConflict)args.insert(args.end(),L"--root-conflict");
    if(test.entry)args.insert(args.end(),{L"--entry-mode",test.initFailure?L"init-failure":test.autoEntry?L"auto":L"passive",
        L"--device-backend",test.warp?L"warp":L"hardware"});
    args.insert(args.end(),{L"--report",report.wstring(),L"--module",dll.filename().wstring(),L"--hold-ms",std::to_wstring(test.hold),
        L"--exit-code",std::to_wstring(test.targetExit),L"--",L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"});
    auto command=quote(host.wstring());for(const auto& a:args)command+=L" "+quote(a);
    std::vector<wchar_t> mutableCommand(command.begin(),command.end());mutableCommand.push_back(0);
    // Preserve the exact UTF-16 command independently of locale-dependent logs.
    {std::ofstream invocation(directory/(std::string(test.name)+".command.utf16"),std::ios::binary);
        invocation.write(reinterpret_cast<const char*>(command.data()),static_cast<std::streamsize>(command.size()*sizeof(wchar_t)));
        require(bool(invocation),"fixture invocation evidence failed");}
    FixtureLog log(directory/(std::string(test.name)+".host.log"));
    Handle job(CreateJobObjectW(nullptr,nullptr));check(job.value!=nullptr,"create private fixture job");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    check(SetInformationJobObject(job.value,JobObjectExtendedLimitInformation,&limits,sizeof(limits)),"fixture kill-on-close scope");
    // Only our newly created launcher and its inherited disposable child enter
    // this unnamed job. No process enumeration or existing-process attachment.
    STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);startup.StartupInfo.dwFlags=STARTF_USESHOWWINDOW|STARTF_USESTDHANDLES;
    startup.StartupInfo.wShowWindow=SW_HIDE;startup.StartupInfo.hStdOutput=log.output.value;startup.StartupInfo.hStdError=log.output.value;
    startup.StartupInfo.hStdInput=log.input.value;startup.lpAttributeList=log.attributes;PROCESS_INFORMATION process{};
    // Reuse the test console instead of requesting another headless console
    // host, which is an additional OS-owned process on this Windows version.
    check(CreateProcessW(host.c_str(),mutableCommand.data(),nullptr,nullptr,TRUE,CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,
        nullptr,directory.c_str(),&startup.StartupInfo,&process),"create fixture launcher");
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
    {std::ofstream result(directory/(std::string(test.name)+".host-exit.txt"));result<<exit<<'\n';require(bool(result),"fixture host exit evidence failed");}
    const auto hostLog=log.replay();
    if(test.loaderMissingDependency)require(hostLog.find("No startup receipt")!=std::string::npos
        && hostLog.find("Observed child exit/status: 0xc0000135.")!=std::string::npos,
        "known unresolved dependency did not retain actual loader status");
    if(exit!=test.hostExit){
        // Preserve the retained disposable child's actual status even when it
        // crashes before writing a fixture report. This is observation only;
        // existing private-job ownership and failure cleanup stay unchanged.
        std::ofstream childStatus(directory/(std::string(test.name)+".target-exit.txt"));
        childStatus<<"retained="<<(targetProcess.value?1:0)<<'\n';
        if(targetProcess.value){const auto wait=WaitForSingleObject(targetProcess.value,250);DWORD code=0;
            const auto queried=GetExitCodeProcess(targetProcess.value,&code);
            childStatus<<"processId="<<GetProcessId(targetProcess.value)<<"\nwait="<<wait<<"\nqueried="<<queried<<"\nexit=0x"<<std::hex<<code<<'\n';}
        require(bool(childStatus),"fixture failure child-status evidence failed");
        throw std::runtime_error(std::string(test.name)+": launcher exit="+std::to_string(exit)+", expected="+std::to_string(test.hostExit));
    }
    auto stats=accounting(job.value);
    if(stats.TotalProcesses!=test.totalProcesses){describeOwnedJob(job.value);throw std::runtime_error(std::string(test.name)+": job total="+std::to_string(stats.TotalProcesses)
        +", active="+std::to_string(stats.ActiveProcesses)+", expected total="+std::to_string(test.totalProcesses));}
    if(test.expectAliveAfterHost)require(stats.ActiveProcesses==1,"launcher terminated its resumed fixture child");
    if(test.noReceipt && test.hold>=16000)require(GetTickCount64()-started>=14000,"missing receipt bypassed the real timeout");
    waitEmpty(job.value);stats=accounting(job.value);require(!stats.ActiveProcesses,"fixture child orphaned");
    if(test.expectEntry){
        BeamRTStartupFixtureReport result{};
        if(test.bindingFixture){const auto data=read<BeamRTBindingFixtureReport>(report);result=data.startup;
            if(test.bindingObserve){require(data.status.enabled && data.status.healthy && data.status.ownerThread==result.status.attachThread && data.disabled,"binding startup/status/OFF mismatch");
                const bool expected=test.bindingMode==L"normal" || test.bindingMode==L"worker" || test.bindingMode==L"thread-rejections" || (test.resourceFixture && test.bindingMode!=L"resource-no-draw");require(data.captured==uint32_t(expected),"binding capture expectation failed");
                if(expected){const auto receipt=read<BeamRTBindingRecordReceipt>(bindingOutput);require(receipt.abi==1 && receipt.processId==result.processId && receipt.recordThread
                    && beamrtBindingSnapshotValid(receipt.snapshot) && std::memcmp(&receipt.snapshot,&data.snapshot,sizeof(data.snapshot))==0,"parent snapshot differs from fixture's actual bindings");
                    const auto threads=read<BeamRTBindingThreadReceipt>(bindingOutput.wstring()+L".threads.bin");
                    require(threads.bytes==sizeof(threads) && threads.abi==beamrtBindingThreadABI && threads.processId==result.processId
                        && threads.recordThread==receipt.recordThread && threads.snapshotSerial==receipt.snapshot.serial
                        && beamrtBindingThreadDiagnosticsValid(threads.diagnostics) && std::memcmp(&threads.diagnostics,&data.diagnostics,sizeof(data.diagnostics))==0,
                        "parent thread ledger differs from actual fixture diagnostics");}
                else require(!fs::exists(bindingOutput) && !fs::exists(bindingOutput.wstring()+L".threads.bin") && !data.snapshot.recordedDraw,"no-draw/unsupported root wrote binding artifact");
                const auto prefix=read<BeamRTBindingThreadPrefix>(bindingOutput.wstring()+L".thread-samples.bin");
                require(prefix.bytes==sizeof(prefix) && prefix.abi==beamrtBindingThreadABI && prefix.processId==result.processId
                    && prefix.count==static_cast<LONG>(data.diagnostics.sampleCount),"timeout/record thread sample prefix mismatch");
                for(LONG i=0;i<prefix.count;++i)require(beamrtBindingThreadSampleValid(prefix.samples[i])
                    && std::memcmp(&prefix.samples[i],&data.diagnostics.samples[i],sizeof(prefix.samples[i]))==0,"parent thread conflict sample differs from fixture");
            }else require(!data.status.enabled && !data.captured && !data.disabled && !fs::exists(bindingOutput),"default-off binding component activated");
            if(test.resourceFixture){
                const auto resources=read<BeamRTResourceFixtureReport>(report.wstring()+L".resource-report");
                const auto expectedMode=test.resourceDescriptorsOnly?beamrtResourceDescriptorTextures:beamrtResourceAllAllocations;
                const auto expectedProfile=test.resourceInternedStorage?beamrtResourceStorageInterned:test.resourceCompactStorage?beamrtResourceStorageCompact:beamrtResourceStorageLegacy;
                require(resources.bytes==sizeof(resources) && resources.abi==3 && resources.enabled==uint32_t(test.resourceObserve)
                    && resources.mode==expectedMode && resources.profile==expectedProfile && !resources.reserved && !resources.reserved2 && !resources.reservedProfile,"resource fixture startup mismatch");
                if(test.resourceObserve){require(resources.disabled && resources.after.restoredSlots==10 && !resources.after.attachedSlots && !resources.after.enabled,"resource OFF restoration failed");
                    if(test.bindingMode==L"resource-descriptors")require(data.pixelOK && resources.pixelAfterOff==1 && resources.after.healthy
                        && resources.after.liveHeaps==2 && resources.after.liveResources==7 && resources.after.views==7
                        && !resources.after.pressure && !resources.after.overlaps,"mixed descriptor copy regression did not preserve final GI baseline/GPU output/OFF join");
                    const auto start=read<BeamRTResourceStartReceipt>(bindingOutput.wstring()+L".resources-start.bin");
                    require(beamrtResourceStartReceiptValid(start,result.processId,result.status.attachThread,expectedMode,expectedProfile)
                        && start.status.attachedSlots==10 && !start.firstFailure.kind && !start.storage.locations && !start.storage.payloads
                        && start.storage.usedBytes==(test.resourceInternedStorage?512u:0u) && !start.storage.heaps
                        && start.storage.directoryBytes==(test.resourceInternedStorage?512u:0u)
                        && start.storage.locationBytes==(test.resourceInternedStorage?14u:24u)
                        && start.storage.heapLimit==(test.resourceInternedStorage?32u:0u)
                        && !std::memcmp(&start.storage,&resources.storageBefore,sizeof(start.storage)),"resource start artifact mismatch");
                    require(beamrtResourceStorageSnapshotValid(resources.storageAfter,expectedProfile) && resources.storageAfter.locations==resources.after.views,
                        "resource OFF storage profile/counts mismatch");
                    if(data.captured){const auto receipt=read<BeamRTResourceRecordReceipt>(bindingOutput.wstring()+L".resources.bin");
                        require(std::memcmp(&receipt,&resources.receipt,sizeof(receipt))==0 && receipt.processId==result.processId
                            && receipt.recordThread==result.status.attachThread && receipt.snapshotSerial==data.snapshot.serial && receipt.mode==expectedMode && !receipt.reserved
                            && receipt.profile==expectedProfile && !receipt.reserved2
                            && beamrtResourceObservationValid(receipt.observation,data.snapshot,receipt.recordThread,expectedProfile)
                            && beamrtResourceCopyFailureValid(receipt.copyFailure,receipt.observation.firstFailure,receipt.observation.status,expectedMode,expectedProfile)
                            && (!beamrtResourceCopyFailureExpected(receipt.observation.firstFailure)
                                || !std::memcmp(&receipt.copyFailure.storageFailure,&receipt.observation.storageFailure,sizeof(receipt.observation.storageFailure))),
                            "parent resource receipt differs from actual fixture");
                        const auto& o=receipt.observation;require(o.cbvProbeBytes==test.resourceProbeBytes,"resource probe silently changed");
                        require(beamrtResourceStorageEvidenceValid(resources.storageAfter,resources.storageFailureAfter,o.firstFailure,resources.after,expectedProfile)
                            && !std::memcmp(&resources.storageFailureAfter,&o.storageFailure,sizeof(o.storageFailure)),"resource OFF changed recorded storage failure");
                        if(test.bindingMode==L"resource-pressure")require(!o.intervalAccepted && !o.status.healthy && o.status.pressure && FAILED(o.result)
                            && o.firstFailure.kind==BeamRTResourceFailureHeapCapacity && o.firstFailure.capacityLimit==beamrtResourceHeapLimit
                            && o.firstFailure.attemptedCount==beamrtResourceHeapLimit+1,"resource pressure falsely accepted");
                        else if(test.resourceCompactStorage && test.bindingMode!=L"resource-compact"){
                            const bool locations=test.bindingMode==L"resource-compact-locations",payloads=test.bindingMode==L"resource-compact-payloads";
                            const uint32_t kind=locations?BeamRTResourceFailureViewCapacity:payloads?BeamRTResourceFailureViewPayloadCapacity:BeamRTResourceFailureViewByteCapacity;
                            const uint32_t limit=locations?1024u:payloads?256u:47104u,attempted=locations?1025u:payloads?257u:47128u;
                            const auto& storage=o.storage;const auto& e=o.storageFailure;const auto& copy=receipt.copyFailure;
                            require(!o.intervalAccepted && !o.status.healthy && o.status.pressure==1 && !o.status.overlaps && FAILED(o.result)
                                && o.status.liveResources==7 && o.firstFailure.kind==kind && o.firstFailure.method==(payloads?BeamRTResourceMethodCreateSRV:BeamRTResourceMethodCopyRanges)
                                && o.firstFailure.capacityLimit==limit && o.firstFailure.attemptedCount==attempted
                                && storage.locations==(locations?1024u:256u) && storage.payloads==(locations?7u:256u)
                                && storage.usedBytes==(locations?25696u:47104u)
                                && e.cause==(locations?beamrtResourceStorageFailureLocations:payloads?beamrtResourceStorageFailurePayloads:beamrtResourceStorageFailureBytes)
                                && e.attemptedLocations==storage.locations+1 && e.attemptedPayloads==storage.payloads+(payloads?1u:0u)
                                && e.requiredBytes==storage.usedBytes+24+(payloads?160u:0u),"co-linked compact capacity/demand misattributed");
                            if(!payloads)require(copy.present==1 && copy.profile==expectedProfile && copy.laneCount==1 && !copy.failedLane && !copy.appliedLanes
                                && copy.entryViews==storage.locations && copy.afterClearViews==storage.locations
                                && copy.lanes[0].source.canonicalIdentity==resources.inputIdentities[0] && beamrtResourceZero(copy.lanes[0].previousDestination),
                                "compact copy-capacity topology did not match real fixture descriptors");
                            else require(!copy.present,"non-copy compact payload pressure invented copy topology");
                            require(!std::memcmp(&resources.storageAfter,&storage,sizeof(storage)),"compact OFF changed retained pressure occupancy");
                        }
                        else if(test.resourceInternedStorage && test.bindingMode!=L"resource-interned"){
                            const bool payloads=test.bindingMode==L"resource-interned-payloads";
                            const auto& storage=o.storage;const auto& e=o.storageFailure;const auto& copy=receipt.copyFailure;
                            require(!o.intervalAccepted && !o.status.healthy && o.status.pressure==1 && !o.status.overlaps && FAILED(o.result)
                                && o.status.liveResources==7 && o.firstFailure.kind==(payloads?BeamRTResourceFailureViewPayloadCapacity:BeamRTResourceFailureViewByteCapacity)
                                && o.firstFailure.method==(payloads?BeamRTResourceMethodCreateSRV:BeamRTResourceMethodCopyRanges)
                                && o.firstFailure.capacityLimit==(payloads?256u:47104u) && o.firstFailure.attemptedCount==(payloads?257u:47118u)
                                && storage.locations==(payloads?256u:3248u) && storage.payloads==(payloads?256u:7u) && storage.heaps==3
                                && storage.usedBytes==(payloads?45056u:47104u) && storage.directoryBytes==512 && storage.locationBytes==14 && storage.heapLimit==32
                                && e.cause==(payloads?beamrtResourceStorageFailurePayloads:beamrtResourceStorageFailureBytes)
                                && e.attemptedLocations==storage.locations+1 && e.attemptedPayloads==storage.payloads+(payloads?1u:0u)
                                && e.attemptedHeaps==3 && e.requiredBytes==storage.usedBytes+14+(payloads?160u:0u),"co-linked interned capacity/demand misattributed");
                            if(!payloads)require(copy.present==1 && copy.profile==expectedProfile && copy.laneCount==1 && !copy.failedLane && !copy.appliedLanes
                                && copy.entryViews==3248 && copy.afterClearViews==3248 && copy.lanes[0].source.canonicalIdentity==resources.inputIdentities[0]
                                && beamrtResourceZero(copy.lanes[0].previousDestination),"interned byte-capacity topology did not match actual fixture descriptors");
                            else require(!copy.present,"non-copy interned payload pressure invented copy topology");
                            require(!std::memcmp(&resources.storageAfter,&storage,sizeof(storage)),"interned OFF changed retained pressure occupancy");
                        }
                        else if(test.bindingMode==L"resource-objects")require(!o.intervalAccepted && !o.status.healthy && o.status.pressure==1 && !o.status.overlaps
                            && o.status.liveResources==beamrtResourceObjectLimit && FAILED(o.result)
                            && o.firstFailure.kind==BeamRTResourceFailureObjectCapacity && o.firstFailure.method==BeamRTResourceMethodCommitted
                            && o.firstFailure.capacityLimit==beamrtResourceObjectLimit && o.firstFailure.attemptedCount==beamrtResourceObjectLimit+1
                            && o.firstFailure.liveResources==beamrtResourceObjectLimit && o.firstFailure.callerThread==receipt.recordThread,
                            "co-linked resource object capacity falsely accepted or misattributed");
                        else if(test.bindingMode==L"resource-descriptor-pressure")require(!o.intervalAccepted && !o.status.healthy && o.status.pressure==1 && !o.status.overlaps
                            && o.status.liveResources==beamrtResourceObjectLimit && FAILED(o.result)
                            && o.firstFailure.kind==BeamRTResourceFailureObjectCapacity && o.firstFailure.method==BeamRTResourceMethodCreateSRV
                            && o.firstFailure.capacityLimit==beamrtResourceObjectLimit && o.firstFailure.attemptedCount==beamrtResourceObjectLimit+1
                            && o.firstFailure.liveResources==beamrtResourceObjectLimit && o.firstFailure.callerThread==receipt.recordThread,
                            "co-linked descriptor object capacity falsely accepted or misattributed");
                         else if(test.bindingMode==L"resource-copy-pressure"){
                             const auto& copy=receipt.copyFailure;
                             require(!o.intervalAccepted && !o.status.healthy && o.status.pressure==1 && !o.status.overlaps && FAILED(o.result)
                                 && o.status.liveResources==7 && o.status.views==beamrtResourceViewLimit
                                 && o.firstFailure.kind==BeamRTResourceFailureViewCapacity && o.firstFailure.method==BeamRTResourceMethodCopyRanges
                                 && o.firstFailure.capacityLimit==beamrtResourceViewLimit && o.firstFailure.attemptedCount==beamrtResourceViewLimit+1
                                 && copy.present==1 && copy.mode==expectedMode && copy.laneCount==3 && !copy.failedLane && !copy.appliedLanes
                                 && copy.entryViews==beamrtResourceViewLimit && copy.afterClearViews==beamrtResourceViewLimit,
                                 "co-linked copy-capacity companion absent or misattributed");
                             for(unsigned i=0;i<copy.laneCount;++i)require(copy.lanes[i].source.canonicalIdentity==resources.inputIdentities[0]
                                 && beamrtResourceZero(copy.lanes[i].previousDestination),"copy-capacity topology did not match real fixture resources");
                         }
                        else if(test.bindingMode==L"resource-output-write")require(!o.intervalAccepted && o.status.healthy && o.outputCheckpointValid
                            && o.outputCallbacks<o.callbacksBegin && o.callbacksBegin==o.callbacksEnd && !o.rtvs[0].resourceId && FAILED(o.result),"RTV reuse after binding falsely accepted");
                        else {require(o.intervalAccepted && o.result==S_OK,"resource interval was not accepted");
                            if(test.resourceCompactStorage)require(o.status.liveHeaps==3 && o.status.liveResources==7 && o.storage.locations==307
                                && o.storage.payloads==7 && o.storage.usedBytes==8488 && !o.status.pressure && !o.status.overlaps && !o.firstFailure.kind
                                && resources.after.healthy && resources.after.liveHeaps==2 && resources.after.liveResources==7
                                && resources.storageAfter.locations==7 && resources.storageAfter.payloads==7 && resources.storageAfter.usedBytes==1288,
                                "co-linked compact fanout receipt/OFF baseline mismatch");
                            else if(test.resourceInternedStorage)require(o.status.liveHeaps==3 && o.status.liveResources==7 && o.storage.locations==2000
                                && o.storage.payloads==7 && o.storage.heaps==3 && o.storage.usedBytes==29632 && o.storage.directoryBytes==512 && o.storage.locationBytes==14
                                && !o.status.pressure && !o.status.overlaps && !o.firstFailure.kind && resources.after.healthy && resources.after.liveHeaps==2
                                && resources.after.liveResources==7 && resources.storageAfter.locations==7 && resources.storageAfter.payloads==7
                                && resources.storageAfter.heaps==2 && resources.storageAfter.usedBytes==1730,"co-linked interned fanout receipt/OFF baseline mismatch");
                            else if(test.resourceDescriptorsOnly)require(o.status.liveHeaps==2 && o.status.liveResources==7 && o.status.views==7 && !o.status.pressure && !o.status.overlaps
                                && !o.firstFailure.kind,"co-linked descriptor startup counted unreferenced resources");
                            for(unsigned i=0;i<6;++i){if(test.bindingMode==L"resource-partial" && !i)require(o.srvResults[i]!=S_OK && !o.srvs[i].resourceId,"unsupported view guessed");
                                else require(o.srvResults[i]==S_OK && o.srvs[i].canonicalIdentity==resources.inputIdentities[i],"resource SRV identity mismatch");}
                            require(o.rtvResults[0]==S_OK && o.rtvs[0].canonicalIdentity==resources.outputIdentity,"resource output identity mismatch");
                            if(test.resourceProbeBytes)require(o.cbvResult==S_OK && o.cbv.candidateOnly==1 && o.cbv.canonicalIdentity==resources.bufferIdentity,"resource CBV candidate mismatch");
                            else require(o.cbvResult==S_FALSE && !o.cbv.bytes,"default probe invented CBV candidate");
                        }
                        if(test.resourceDescriptorsOnly){const BeamRTBufferCandidate zero{};require(!o.cbvProbeBytes && o.cbvResult==S_FALSE
                            && !std::memcmp(&o.cbv,&zero,sizeof(zero)),"descriptor startup invented buffer metadata");}
                    }else require(!fs::exists(bindingOutput.wstring()+L".resources.bin") && !resources.receipt.bytes,"no-draw resource receipt invented");
                }else require(!resources.disabled && !resources.receipt.bytes && !fs::exists(bindingOutput.wstring()+L".resources.bin")
                    && !fs::exists(bindingOutput.wstring()+L".resources-start.bin"),"default-off resources activated");
                if(data.pixelOK)require(resources.pixelAfterOff==1,"resource OFF changed GPU output");
            }
            if(test.bindingMode!=L"no-draw" && test.bindingMode!=L"thread-no-draw" && test.bindingMode!=L"resource-no-draw")require(data.pixelOK==1,"automatic observer changed GPU output");
            if(test.bindingMode==L"worker")require(data.targetWorkerThread && data.targetWorkerThread!=result.status.attachThread && data.status.targetReady,"worker-thread verified target setup failed");
        }else if(test.pipeline){
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
    if(test.existingBinding){std::ifstream sentinel(bindingOutput,std::ios::binary);const std::string content((std::istreambuf_iterator<char>(sentinel)),std::istreambuf_iterator<char>());
        require(content=="preserve binding artifact","existing binding output was overwritten");}
    if(test.existingThreadEvidence){std::ifstream sentinel(bindingOutput.wstring()+L".threads.bin",std::ios::binary);const std::string content((std::istreambuf_iterator<char>(sentinel)),std::istreambuf_iterator<char>());
        require(content=="preserve thread evidence" && !fs::exists(bindingOutput),"existing thread sidecar was overwritten or child wrote a recording");}
    if(test.existingResource){std::ifstream sentinel(bindingOutput.wstring()+L".resources.bin",std::ios::binary);const std::string content((std::istreambuf_iterator<char>(sentinel)),std::istreambuf_iterator<char>());
        require(content=="preserve resource evidence" && !fs::exists(bindingOutput),"existing resource sidecar was overwritten or child created");}
    std::cout<<"PASS: "<<test.name<<"; hostExit="<<exit<<"; totalProcesses="<<stats.TotalProcesses<<"; active=0\n"<<std::flush;
}
int wmain(int argc,wchar_t** argv) {
    try {
        require(argc==2 || (argc==3 && (std::wstring(argv[2])==L"--device" || std::wstring(argv[2])==L"--entry" || std::wstring(argv[2])==L"--import" || std::wstring(argv[2])==L"--pipeline" || std::wstring(argv[2])==L"--bindings" || std::wstring(argv[2])==L"--loader" || std::wstring(argv[2])==L"--resources" || std::wstring(argv[2])==L"--resources-warp" || std::wstring(argv[2])==L"--resource-objects" || std::wstring(argv[2])==L"--resource-objects-warp")),"usage: process_test <owned native-startup artifact directory> [--device|--entry|--import|--pipeline|--bindings|--loader|--resources|--resources-warp|--resource-objects|--resource-objects-warp]");const auto root=fs::canonical(argv[1]);
        const bool devices=argc==3 && std::wstring(argv[2])==L"--device",entries=argc==3 && std::wstring(argv[2])==L"--entry",imports=argc==3 && std::wstring(argv[2])==L"--import",pipelines=argc==3 && std::wstring(argv[2])==L"--pipeline";
        const bool bindings=argc==3 && std::wstring(argv[2])==L"--bindings";
        const bool loader=argc==3 && std::wstring(argv[2])==L"--loader";
        const bool resourceObjectsOnly=argc==3 && (std::wstring(argv[2])==L"--resource-objects" || std::wstring(argv[2])==L"--resource-objects-warp");
        const bool resourcesWarpOnly=argc==3 && (std::wstring(argv[2])==L"--resources-warp" || std::wstring(argv[2])==L"--resource-objects-warp");
        const bool resources=argc==3 && (std::wstring(argv[2])==L"--resources" || resourcesWarpOnly || resourceObjectsOnly);
        const auto folder=root.filename().wstring();const std::wstring prefix=L"native-startup-resource-";
        const bool fresh=folder.size()==prefix.size()+32 && folder.rfind(prefix,0)==0 && folder.find_first_not_of(L"0123456789abcdef",prefix.size())==std::wstring::npos;
        require((root.filename()==L"native-startup" || fresh) && root.parent_path().filename()==L".beamrt-validation","fixture confined to native-startup artifacts");
        for(const wchar_t* name:{L"beamrt_startup_fixture.exe",L"beamrt_startup_host.exe",L"beamrt_startup_fault_host.exe",
            L"beamrt_startup_bootstrap.dll",L"beamrt_startup_no_receipt.dll"})require(fs::is_regular_file(root/name),"required owned fixture artifact missing");
        if(devices)require(fs::is_regular_file(root/L"beamrt_device_fixture.exe"),"device fixture missing");
        if(pipelines)require(fs::is_regular_file(root/L"beamrt_pipeline_startup_fixture.exe") && fs::is_regular_file(root/L"fixture.alt.ps.cso"),"pipeline startup fixtures missing");
        if(bindings || resources)require(fs::is_regular_file(root/L"beamrt_binding_startup_fixture.exe"),"binding startup fixture missing");
        if(imports)for(const wchar_t* name:{L"beamrt_import_fixture.exe",L"beamrt_import_ordinal_fixture.exe"})require(fs::is_regular_file(root/name),"import fixture missing");
        if(loader){require(fs::is_regular_file(root/L"beamrt_loader_missing_fixture.exe") && fs::is_regular_file(root/L"beamrt_import_fixture.exe"),"loader control fixture missing");
            require(!fs::exists(root/L"beamrt_deliberately_absent_fixture_dependency.dll"),"deliberately absent fixture DLL unexpectedly supplied");}
        if(entries)for(const wchar_t* name:{L"beamrt_entry_fixture.exe",L"beamrt_entry_passive_fixture.dll",L"beamrt_entry_auto_fixture.dll",L"beamrt_entry_fail_fixture.dll"})
            require(fs::is_regular_file(root/name),"entry fixture missing");
        // No dialogs/windows on expected loader/test failures; children inherit.
        SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
        const auto directory=root/(L"process-tests-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
        require(fs::create_directory(directory),"fresh fixture report directory unavailable");
        preserveInputs(root,directory);
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
        if(loader){
            Case baseline{"loader-normal-import-control"};baseline.imports=true;baseline.hold=1000;run(root,directory,baseline);
            Case missing{"loader-known-missing-dependency"};missing.loaderMissingDependency=true;missing.hostExit=2;missing.expectEntry=false;
            run(root,directory,missing);
        }else if(resources){
            for(bool warp:{false,true}){if(resourcesWarpOnly && !warp)continue;Case objects{warp?"resource-object-pressure-warp":"resource-object-pressure-hardware"};objects.pipeline=true;objects.bindingFixture=true;objects.bindingObserve=true;objects.resourceFixture=true;objects.resourceObserve=true;
                objects.bindingMode=L"resource-objects";objects.warp=warp;objects.hold=1000;run(root,directory,objects);}
            if(!resourceObjectsOnly){
            for(bool warp:{false,true}){if(resourcesWarpOnly && !warp)continue;Case descriptor{warp?"resource-descriptors-warp":"resource-descriptors-hardware"};descriptor.pipeline=true;descriptor.bindingFixture=true;descriptor.bindingObserve=true;descriptor.resourceFixture=true;descriptor.resourceObserve=true;
                descriptor.bindingMode=L"resource-descriptors";descriptor.resourceDescriptorsOnly=true;descriptor.resourceProbeBytes=0;descriptor.warp=warp;descriptor.hold=1000;run(root,directory,descriptor);}
            for(bool warp:{false,true}){if(resourcesWarpOnly && !warp)continue;Case descriptor{warp?"resource-descriptor-pressure-warp":"resource-descriptor-pressure-hardware"};descriptor.pipeline=true;descriptor.bindingFixture=true;descriptor.bindingObserve=true;descriptor.resourceFixture=true;descriptor.resourceObserve=true;
                descriptor.bindingMode=L"resource-descriptor-pressure";descriptor.resourceDescriptorsOnly=true;descriptor.resourceProbeBytes=0;descriptor.warp=warp;descriptor.hold=1000;run(root,directory,descriptor);}
            for(bool warp:{false,true}){if(resourcesWarpOnly && !warp)continue;Case copy{warp?"resource-copy-pressure-warp":"resource-copy-pressure-hardware"};copy.pipeline=true;copy.bindingFixture=true;copy.bindingObserve=true;copy.resourceFixture=true;copy.resourceObserve=true;
                copy.bindingMode=L"resource-copy-pressure";copy.resourceDescriptorsOnly=true;copy.resourceProbeBytes=0;copy.warp=warp;copy.hold=1000;run(root,directory,copy);}
            for(bool warp:{false,true}){if(resourcesWarpOnly && !warp)continue;
                for(unsigned compactCase=0;compactCase<4;++compactCase){
                    const char* hardware[]={"resource-compact-hardware","resource-compact-locations-hardware","resource-compact-payloads-hardware","resource-compact-bytes-hardware"};
                    const char* software[]={"resource-compact-warp","resource-compact-locations-warp","resource-compact-payloads-warp","resource-compact-bytes-warp"};
                    const wchar_t* modes[]={L"resource-compact",L"resource-compact-locations",L"resource-compact-payloads",L"resource-compact-bytes"};
                    Case compact{warp?software[compactCase]:hardware[compactCase]};compact.pipeline=true;compact.bindingFixture=true;compact.bindingObserve=true;
                    compact.resourceFixture=true;compact.resourceObserve=true;compact.resourceDescriptorsOnly=true;compact.resourceCompactStorage=true;
                    compact.resourceProbeBytes=0;compact.bindingMode=modes[compactCase];compact.warp=warp;compact.hold=1000;run(root,directory,compact);
                }
            }
            for(bool warp:{false,true}){if(resourcesWarpOnly && !warp)continue;
                for(unsigned internedCase=0;internedCase<3;++internedCase){
                    const char* hardware[]={"resource-interned-hardware","resource-interned-payloads-hardware","resource-interned-bytes-hardware"};
                    const char* software[]={"resource-interned-warp","resource-interned-payloads-warp","resource-interned-bytes-warp"};
                    const wchar_t* modes[]={L"resource-interned",L"resource-interned-payloads",L"resource-interned-bytes"};
                    Case interned{warp?software[internedCase]:hardware[internedCase]};interned.pipeline=true;interned.bindingFixture=true;interned.bindingObserve=true;
                    interned.resourceFixture=true;interned.resourceObserve=true;interned.resourceDescriptorsOnly=true;interned.resourceInternedStorage=true;
                    interned.resourceProbeBytes=0;interned.bindingMode=modes[internedCase];interned.warp=warp;interned.hold=1000;run(root,directory,interned);
                }
            }
            for(bool warp:{false,true}){if(resourcesWarpOnly && !warp)continue;Case test{warp?"resource-startup-warp":"resource-startup-hardware"};test.pipeline=true;test.bindingFixture=true;test.bindingObserve=true;test.resourceFixture=true;test.resourceObserve=true;
                test.bindingMode=L"resource-normal";test.warp=warp;test.hold=1000;run(root,directory,test);}
            Case probeOff{"resource-probe-default-off"};probeOff.pipeline=true;probeOff.bindingFixture=true;probeOff.bindingObserve=true;probeOff.resourceFixture=true;probeOff.resourceObserve=true;
            probeOff.resourceProbeBytes=0;probeOff.bindingMode=L"resource-normal";probeOff.warp=true;probeOff.hold=1000;run(root,directory,probeOff);
            Case partial{"resource-partial-view"};partial.pipeline=true;partial.bindingFixture=true;partial.bindingObserve=true;partial.resourceFixture=true;partial.resourceObserve=true;
            partial.bindingMode=L"resource-partial";partial.warp=true;partial.hold=1000;run(root,directory,partial);
            Case pressure{"resource-capacity-refusal"};pressure.pipeline=true;pressure.bindingFixture=true;pressure.bindingObserve=true;pressure.resourceFixture=true;pressure.resourceObserve=true;
            pressure.bindingMode=L"resource-pressure";pressure.warp=true;pressure.hold=1000;run(root,directory,pressure);
            Case outputWrite{"resource-output-reused-after-binding"};outputWrite.pipeline=true;outputWrite.bindingFixture=true;outputWrite.bindingObserve=true;outputWrite.resourceFixture=true;outputWrite.resourceObserve=true;
            outputWrite.bindingMode=L"resource-output-write";outputWrite.warp=true;outputWrite.hold=1000;run(root,directory,outputWrite);
            Case noDraw{"resource-without-draw"};noDraw.pipeline=true;noDraw.bindingFixture=true;noDraw.bindingObserve=true;noDraw.resourceFixture=true;noDraw.resourceObserve=true;
            noDraw.bindingMode=L"resource-no-draw";noDraw.warp=true;noDraw.hostExit=10;noDraw.hold=2500;noDraw.expectAliveAfterHost=true;run(root,directory,noDraw);
            Case passive{"resource-default-off"};passive.pipeline=true;passive.bindingFixture=true;passive.bindingObserve=true;passive.resourceFixture=true;
            passive.bindingMode=L"resource-default-off";passive.warp=true;passive.hold=1000;run(root,directory,passive);
            Case exists{"resource-output-preserved"};exists.pipeline=true;exists.bindingFixture=true;exists.bindingObserve=true;exists.resourceObserve=true;exists.existingResource=true;
            exists.hostExit=1;exists.totalProcesses=1;exists.expectEntry=false;run(root,directory,exists);
            }
        }else if(bindings){
            for(bool warp:{false,true}){Case test{warp?"binding-startup-warp":"binding-startup-hardware"};test.pipeline=true;test.bindingFixture=true;test.bindingObserve=true;test.warp=warp;test.hold=1000;run(root,directory,test);}
            Case worker{"binding-target-worker-thread"};worker.pipeline=true;worker.bindingFixture=true;worker.bindingObserve=true;worker.bindingMode=L"worker";worker.hold=1000;run(root,directory,worker);
            for(bool warp:{false,true}){Case test{warp?"binding-thread-attribution-warp":"binding-thread-attribution-hardware"};test.pipeline=true;test.bindingFixture=true;test.bindingObserve=true;
                test.bindingMode=L"thread-rejections";test.warp=warp;test.hold=1000;run(root,directory,test);}
            Case threadTimeout{"binding-thread-evidence-without-draw"};threadTimeout.pipeline=true;threadTimeout.bindingFixture=true;threadTimeout.bindingObserve=true;
            threadTimeout.bindingMode=L"thread-no-draw";threadTimeout.hostExit=10;threadTimeout.hold=2500;threadTimeout.expectAliveAfterHost=true;run(root,directory,threadTimeout);
            Case noDraw{"binding-installed-no-draw"};noDraw.pipeline=true;noDraw.bindingFixture=true;noDraw.bindingObserve=true;noDraw.bindingMode=L"no-draw";noDraw.hostExit=10;noDraw.hold=2500;noDraw.expectAliveAfterHost=true;run(root,directory,noDraw);
            Case unsupported{"binding-unsupported-root"};unsupported.pipeline=true;unsupported.bindingFixture=true;unsupported.bindingObserve=true;unsupported.bindingMode=L"unsupported-root";unsupported.hostExit=10;unsupported.hold=2500;unsupported.expectAliveAfterHost=true;run(root,directory,unsupported);
            Case passive{"binding-default-off"};passive.pipeline=true;passive.bindingFixture=true;passive.bindingMode=L"observer-off";passive.hold=1000;run(root,directory,passive);
            Case exists{"binding-output-preserved"};exists.pipeline=true;exists.bindingFixture=true;exists.bindingObserve=true;exists.existingBinding=true;exists.hostExit=1;exists.totalProcesses=1;exists.expectEntry=false;run(root,directory,exists);
            Case threadsExist{"binding-thread-output-preserved"};threadsExist.pipeline=true;threadsExist.bindingFixture=true;threadsExist.bindingObserve=true;
            threadsExist.existingThreadEvidence=true;threadsExist.hostExit=1;threadsExist.totalProcesses=1;threadsExist.expectEntry=false;run(root,directory,threadsExist);
        }else if(pipelines){
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
        std::wcout<<L"PASS: "<<(loader?2:resources?(resourceObjectsOnly?(resourcesWarpOnly?1:2):(resourcesWarpOnly?19:31)):bindings?11:pipelines?8:imports?5:entries?4:devices?2:9)<<L" disposable "<<(loader?L"loader evidence":resources?L"startup-connected resources":bindings?L"startup-connected bindings":pipelines?L"startup-connected pipeline":imports?L"import-observer":entries?L"entry-rendezvous":devices?L"device-observer":L"startup")<<L" cases; all private jobs drained. Reports: "<<directory.wstring()
            <<L"\nNo game executable selected or started; no capture/GI renderer loaded.\n";return 0;
    }catch(const std::exception& error){std::cerr<<"Startup process fixture failed: "<<error.what()<<'\n';return 1;}
}
