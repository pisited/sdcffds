#include "startup_contract.h"
#include "entry_contract.h"
#include <detours.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <filesystem>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
#include <cstring>
#include <cwctype>

static void demand(bool ok,const char* reason){if(!ok)throw std::runtime_error(reason);}
static void win(BOOL ok,const char* reason){if(!ok)throw std::runtime_error(std::string(reason)+" Win32="+std::to_string(GetLastError()));}
static void crypto(NTSTATUS status){demand(status>=0,"SHA-256 provider operation failed");}
struct Handle {
    HANDLE value=INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE h):value(h){}
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
    Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;
};
static std::wstring localPath(const std::wstring& path) {
    demand(path.size()>3 && path[1]==L':' && (path[2]==L'\\' || path[2]==L'/')
        && std::iswalpha(path[0]) && path.find(L'\0')==std::wstring::npos,"absolute local drive path required");
    std::vector<wchar_t> full(32768);const DWORD size=GetFullPathNameW(path.c_str(),static_cast<DWORD>(full.size()),full.data(),nullptr);
    demand(size>0 && size<full.size(),"path normalization failed");
    const std::wstring result(full.data(),size);
    demand(GetDriveTypeW(result.substr(0,3).c_str())==DRIVE_FIXED,"network/removable startup paths unsupported");
    return result;
}
static std::wstring physicalPath(HANDLE file) {
    std::vector<wchar_t> name(32768);const DWORD size=GetFinalPathNameByHandleW(file,name.data(),static_cast<DWORD>(name.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    demand(size>0 && size<name.size(),"physical path unavailable");std::wstring result(name.data(),size);
    demand(result.rfind(L"\\\\?\\",0)==0,"unexpected physical path form");result.erase(0,4);
    return localPath(result);
}
struct LockedFile {
    Handle file;std::wstring path;
    explicit LockedFile(const std::wstring& requested):file(CreateFileW(localPath(requested).c_str(),GENERIC_READ,
        FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr)) {
        win(file.value!=INVALID_HANDLE_VALUE,"open reviewed file");path=physicalPath(file.value);
        BY_HANDLE_FILE_INFORMATION info{};win(GetFileInformationByHandle(file.value,&info),"reviewed file identity");
        demand(!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY),"file required, not a directory");
    }
    void at(uint64_t offset,void* out,DWORD bytes) const {
        LARGE_INTEGER pos{};pos.QuadPart=static_cast<LONGLONG>(offset);win(SetFilePointerEx(file.value,pos,nullptr,FILE_BEGIN),"seek PE header");
        DWORD got=0;win(ReadFile(file.value,out,bytes,&got,nullptr),"read PE header");demand(got==bytes,"truncated PE header");
    }
    void pe(bool dll) const {
        LARGE_INTEGER length{};win(GetFileSizeEx(file.value,&length),"PE file size");
        IMAGE_DOS_HEADER dos{};at(0,&dos,sizeof(dos));
        demand(dos.e_magic==IMAGE_DOS_SIGNATURE && dos.e_lfanew>=static_cast<LONG>(sizeof(dos))
            && static_cast<uint64_t>(dos.e_lfanew)+sizeof(IMAGE_NT_HEADERS64)<=static_cast<uint64_t>(length.QuadPart),"invalid PE bounds");
        IMAGE_NT_HEADERS64 nt{};at(static_cast<uint32_t>(dos.e_lfanew),&nt,sizeof(nt));
        demand(nt.Signature==IMAGE_NT_SIGNATURE && nt.FileHeader.Machine==IMAGE_FILE_MACHINE_AMD64
            && nt.OptionalHeader.Magic==IMAGE_NT_OPTIONAL_HDR64_MAGIC
            && nt.FileHeader.SizeOfOptionalHeader==sizeof(IMAGE_OPTIONAL_HEADER64)
            && (nt.FileHeader.Characteristics&IMAGE_FILE_EXECUTABLE_IMAGE)
            && bool(nt.FileHeader.Characteristics&IMAGE_FILE_DLL)==dll,"review host requires an x64 EXE and x64 DLL");
    }
    uint32_t nativeEntryRva() const {
        IMAGE_DOS_HEADER dos{};at(0,&dos,sizeof(dos));IMAGE_NT_HEADERS64 nt{};at(static_cast<uint32_t>(dos.e_lfanew),&nt,sizeof(nt));
        demand(!nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].VirtualAddress
            && nt.OptionalHeader.AddressOfEntryPoint && nt.OptionalHeader.AddressOfEntryPoint<nt.OptionalHeader.SizeOfImage,
            "native entry rendezvous does not support CLR/missing/out-of-image entry points");
        return nt.OptionalHeader.AddressOfEntryPoint;
    }
    std::wstring sha256() const {
        struct HashOwner {
            BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
            std::vector<uint8_t> object;
            ~HashOwner(){if(hash)BCryptDestroyHash(hash);if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);}
        } owner;
        crypto(BCryptOpenAlgorithmProvider(&owner.algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0));
        DWORD objectBytes=0,got=0;crypto(BCryptGetProperty(owner.algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&objectBytes),sizeof(objectBytes),&got,0));
        demand(got==sizeof(objectBytes) && objectBytes>0 && objectBytes<=1024*1024,"unexpected hash object size");
        owner.object.resize(objectBytes);std::vector<uint8_t> chunk(65536);
        crypto(BCryptCreateHash(owner.algorithm,&owner.hash,owner.object.data(),objectBytes,nullptr,0,0));
        LARGE_INTEGER zero{};win(SetFilePointerEx(file.value,zero,nullptr,FILE_BEGIN),"seek reviewed file");
        for(;;){DWORD count=0;win(ReadFile(file.value,chunk.data(),static_cast<DWORD>(chunk.size()),&count,nullptr),"hash reviewed file");
            if(!count)break;crypto(BCryptHashData(owner.hash,chunk.data(),count,0));}
        uint8_t digest[32]{};crypto(BCryptFinishHash(owner.hash,digest,sizeof(digest),0));
        const wchar_t* hex=L"0123456789abcdef";std::wstring result;
        for(uint8_t byte:digest){result+=hex[byte>>4];result+=hex[byte&15];}return result;
    }
};
static std::wstring quote(const std::wstring& argument) {
    demand(argument.find(L'\0')==std::wstring::npos,"embedded NUL in argument");
    std::wstring out=L"\"";size_t slashes=0;
    for(wchar_t c:argument){if(c==L'\\'){++slashes;continue;}
        if(c==L'\"'){out.append(slashes*2+1,L'\\');out+=c;}
        else {out.append(slashes,L'\\');out+=c;}slashes=0;}
    out.append(slashes*2,L'\\');out+=L'\"';return out;
}
static std::wstring printable(const std::wstring& text) {
    // Display only: preserve the original UTF-16 argument vector for CreateProcess.
    // Non-ASCII/control input must not poison the locale-dependent console stream.
    std::wstring result;const wchar_t* hex=L"0123456789abcdef";
    for(wchar_t c:text){if(c>=32 && c<127)result+=c;
        else {result+=L"\\u";for(int shift:{12,8,4,0})result+=hex[(static_cast<uint16_t>(c)>>shift)&15];}}
    return result;
}
struct Options {
    bool launch=false;
    bool entry=false;
    std::wstring target,dll,workdir,targetHash,dllHash,ack;
    std::vector<std::wstring> arguments;
};
static std::wstring digest(const std::wstring& value) {
    demand(value.size()==64,"expected SHA-256 must contain 64 hex digits");std::wstring result;
    for(wchar_t c:value){demand((c>=L'0' && c<=L'9') || (c>=L'a' && c<=L'f') || (c>=L'A' && c<=L'F'),"invalid expected SHA-256");result+=static_cast<wchar_t>(std::towlower(c));}
    return result;
}
static Options parse(const std::vector<std::wstring>& args) {
    Options out;std::map<std::wstring,bool> seen;
    for(size_t i=0;i<args.size();++i){const auto& flag=args[i];
        if(flag==L"--"){out.arguments.assign(args.begin()+i+1,args.end());break;}
        demand(!seen[flag],"duplicate startup option");seen[flag]=true;
        if(flag==L"--launch-reviewed"){out.launch=true;continue;}
        if(flag==L"--entry-rendezvous"){out.entry=true;continue;}
        if(flag==L"--review")continue;
        demand(i+1<args.size(),"startup option missing value");const auto value=args[++i];
        if(flag==L"--target")out.target=localPath(value);
        else if(flag==L"--dll")out.dll=localPath(value);
        else if(flag==L"--workdir")out.workdir=localPath(value);
        else if(flag==L"--expected-target-sha256")out.targetHash=digest(value);
        else if(flag==L"--expected-dll-sha256")out.dllHash=digest(value);
        else if(flag==L"--acknowledge-native-insertion")out.ack=value;
        else demand(false,"unknown startup option");
    }
    demand(!out.target.empty() && !out.dll.empty(),"explicit target EXE and bootstrap DLL required");
    demand(!(seen[L"--review"] && out.launch),"review and launch modes are mutually exclusive");
    if(out.launch)demand(!out.targetHash.empty() && !out.dllHash.empty()
        && out.ack==L"startup-observation-only","launch requires both reviewed hashes and explicit native-insertion acknowledgement");
    return out;
}
static std::wstring commandLine(const Options& options,const std::wstring& target) {
    auto result=quote(target);for(const auto& arg:options.arguments){result+=L' ';result+=quote(arg);}
    demand(result.size()<32767,"Windows command-line limit exceeded");return result;
}
static std::string asciiDll(const std::wstring& path) {
    demand(path.size()<MAX_PATH,"bootstrap DLL path must fit the reviewed Detours import-name limit");std::string out;
    for(wchar_t c:path){demand(c>0 && c<128,"bootstrap DLL physical path must be ASCII for unambiguous import loading");out+=static_cast<char>(c);}return out;
}
struct Attributes {
    std::vector<uint8_t> storage;LPPROC_THREAD_ATTRIBUTE_LIST list=nullptr;
    explicit Attributes(HANDLE* events,SIZE_T count){SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
        demand(bytes>0,"startup attribute size unavailable");storage.resize(bytes);list=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
        win(InitializeProcThreadAttributeList(list,1,0,&bytes),"initialize startup attributes");
        if(!UpdateProcThreadAttribute(list,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,events,count*sizeof(*events),nullptr,nullptr)){
            const DWORD error=GetLastError();DeleteProcThreadAttributeList(list);list=nullptr;SetLastError(error);win(FALSE,"restrict inherited handles");}
    }
    ~Attributes(){if(list)DeleteProcThreadAttributeList(list);}
};
static void fixtureFault(const Options& options,const std::wstring& target,const wchar_t* stage) {
#ifdef BEAMRT_STARTUP_TEST_FAULTS
    // Compiled ONLY in the named disposable-fixture host, never production.
    demand(std::filesystem::path(target).filename()==L"beamrt_startup_fixture.exe","fault host accepts only the disposable fixture");
    if(options.arguments.size()>=2 && options.arguments[0]==L"--fixture-host-fault" && options.arguments[1]==stage)
        throw std::runtime_error("fixture-injected startup failure");
#else
    (void)options;(void)target;(void)stage;
#endif
}
static int launchReviewed(const Options& options,const LockedFile& exe,const LockedFile& dll,const std::wstring& workdir) {
    // Called only by the explicit reviewed-launch branch, never by review/self-test.
    SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};Handle event(CreateEventW(&security,TRUE,FALSE,nullptr));
    win(event.value!=nullptr,"startup receipt event");Handle entryEvent(options.entry?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr);
    if(options.entry)win(entryEvent.value!=nullptr,"entry receipt event");HANDLE events[]={event.value,entryEvent.value};Attributes attributes(events,options.entry?2:1);
    STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);startup.lpAttributeList=attributes.list;
    auto command=commandLine(options,exe.path);std::vector<wchar_t> mutableCommand(command.begin(),command.end());mutableCommand.push_back(0);
    PROCESS_INFORMATION process{};
    win(CreateProcessW(exe.path.c_str(),mutableCommand.data(),nullptr,nullptr,TRUE,
        CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,nullptr,workdir.c_str(),&startup.StartupInfo,&process),"create new suspended reviewed child");
    Handle processHandle(process.hProcess),threadHandle(process.hThread);bool resumeAttempted=false;
    std::wcout<<L"Created reviewed child PID "<<process.dwProcessId<<L"; no existing process is attached.\n";
    try {
        fixtureFault(options,exe.path,L"before-insert");
        const auto dllName=asciiDll(dll.path);const char* insert=dllName.c_str();
        // x64 only: no Detours automatic rundll32/helper fallback.
        win(DetourUpdateProcessWithDll(process.hProcess,&insert,1),"insert startup bootstrap into owned suspended child");
        fixtureFault(options,exe.path,L"before-payload");
        BeamRTStartupPayload payload{sizeof(payload),1,beamrtStartupMagic,process.dwProcessId,beamrtStartupObservationOnly,
            static_cast<uint64_t>(reinterpret_cast<ULONG_PTR>(event.value)),{0,0}};
        win(DetourCopyPayloadToProcess(process.hProcess,beamrtStartupGuid,&payload,sizeof(payload)),"copy startup receipt payload");
        if(options.entry){
            BeamRTEntryPayload entry{sizeof(entry),1,beamrtEntryMagic,process.dwProcessId,process.dwThreadId,
                static_cast<uint64_t>(reinterpret_cast<ULONG_PTR>(entryEvent.value)),exe.nativeEntryRva(),0};
            win(DetourCopyPayloadToProcess(process.hProcess,beamrtEntryGuid,&entry,sizeof(entry)),"copy entry rendezvous payload");
        }
        fixtureFault(options,exe.path,L"before-resume");
        const DWORD previous=ResumeThread(process.hThread);
        if(previous!=DWORD(-1))resumeAttempted=true;
        demand(previous==1,"unexpected initial suspension count; child retained after resume attempt");
        fixtureFault(options,exe.path,L"after-resume");
        HANDLE waits[]={event.value,process.hProcess};const DWORD result=WaitForMultipleObjects(2,waits,FALSE,15000);
        if(result!=WAIT_OBJECT_0){std::wcerr<<L"No startup receipt (wait="<<result<<L"). Child PID "<<process.dwProcessId
            <<L" is NOT terminated after resume. No renderer activation attempted.\n";return 2;}
        std::wcout<<L"Startup bootstrap receipt received. BeamRT capture=OFF; BeamRT GPU work=OFF; lighting=UNCHANGED.\n"
            <<L"This proves DLL attach only, not game pass/resource access or stable rendering.\n";
        if(options.entry){
            HANDLE entryWaits[]={entryEvent.value,process.hProcess};const DWORD entryResult=WaitForMultipleObjects(2,entryWaits,FALSE,15000);
            if(entryResult!=WAIT_OBJECT_0){std::wcerr<<L"No native-entry receipt (wait="<<entryResult<<L"); resumed child is retained.\n";return 3;}
            std::wcout<<L"Native-entry rendezvous receipt received. This is not graphics quiescence or GI proof.\n";
        }
        return 0;
    }catch(...){
        // Only the new child, still suspended and never allowed to execute user work.
        if(!resumeAttempted){
            if(!TerminateProcess(process.hProcess,1))std::wcerr<<L"Cleanup failed for owned suspended child PID "<<process.dwProcessId<<L" (Win32="<<GetLastError()<<L").\n";
            else if(WaitForSingleObject(process.hProcess,5000)!=WAIT_OBJECT_0)std::wcerr<<L"Termination not yet confirmed for owned suspended child PID "<<process.dwProcessId<<L".\n";
        }
        else std::wcerr<<L"Child PID "<<process.dwProcessId<<L" retained after resume attempt; no forced live-game termination.\n";
        throw;
    }
}
static void selfTest() {
    const std::vector<std::wstring> arguments={L"",L"plain",L"with spaces",L"trailing\\",L"a\\\"b",L"\"",L"\u96ea"};
    std::wstring line=quote(L"fixture.exe");for(const auto& a:arguments)line+=L" "+quote(a);
    int argc=0;auto argv=CommandLineToArgvW(line.c_str(),&argc);demand(argv!=nullptr,"argument test parse");
    bool same=argc==static_cast<int>(arguments.size()+1);
    for(size_t i=0;same && i<arguments.size();++i)same=arguments[i]==argv[i+1];LocalFree(argv);
    demand(same,"Windows argument quoting changed arguments");
    demand(printable(L"\u96ea\n")==L"\\u96ea\\u000a","escaped display altered Unicode/control logging");
    const std::wstring drive=std::filesystem::current_path().root_path().wstring();
    const std::vector<std::wstring> baseline={L"--target",drive+L"fixture.exe",L"--dll",drive+L"fixture.dll"};
    demand(!parse(baseline).launch,"startup default is not review-only");UINT refused=0;
    auto rejects=[&](std::vector<std::wstring> args){bool rejected=false;try{const auto invalid=parse(args);}catch(const std::exception&){rejected=true;}
        demand(rejected,"unsafe startup arguments accepted");++refused;};
    auto bad=baseline;bad.push_back(L"--launch-reviewed");rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--review",L"--launch-reviewed"});rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--dll",drive+L"other.dll"});rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--unexpected",L"value"});rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--expected-dll-sha256",L"bad"});rejects(bad);
    bad=baseline;bad[1]=L"relative.exe";rejects(bad);
    bad=baseline;bad[1]=L"\\\\server\\share\\fixture.exe";rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--expected-target-sha256",std::wstring(64,L'0'),L"--expected-dll-sha256",std::wstring(64,L'0'),
        L"--launch-reviewed",L"--acknowledge-native-insertion",L"wrong"});rejects(bad);
    auto valid=bad;valid.back()=L"startup-observation-only";demand(parse(valid).launch,"explicit launch contract rejected");
    BeamRTStartupPayload p{sizeof(p),1,beamrtStartupMagic,123,beamrtStartupObservationOnly,64,{0,0}};
    demand(beamrtStartupPayloadValid(&p,sizeof(p),123),"valid presence payload rejected");
    for(int field=0;field<8;++field){auto invalid=p;
        if(field==0)invalid.bytes-=1;if(field==1)invalid.abi+=1;if(field==2)invalid.magic=0;if(field==3)invalid.processId+=1;
        if(field==4)invalid.mode=2;if(field==5)invalid.receiptEvent=0;if(field==6)invalid.receiptEvent=UINT64_MAX;if(field==7)invalid.reserved[1]=1;
        demand(!beamrtStartupPayloadValid(&invalid,sizeof(invalid),123),"unsupported startup payload accepted");++refused;}
    std::cout<<"PASS: startup review defaults, exact Windows argument roundtrip, "<<refused<<" rejected option/payload cases. No child launched or DLL loaded.\n";
}
int wmain(int argc,wchar_t** argv) {
    try {
        if(argc==2 && std::wstring(argv[1])==L"--self-test"){selfTest();return 0;}
        if(argc==1 || (argc==2 && std::wstring(argv[1])==L"--help")){
            std::cout<<"Review only by default: --review --target <absolute x64 EXE> --dll <absolute bootstrap DLL> [--workdir <directory>] [-- <exact application arguments>]\n"
                <<"Launching requires --launch-reviewed, both --expected-*-sha256 hashes and --acknowledge-native-insertion startup-observation-only. Deployment is not approved by this build.\n";return 0;}
        std::vector<std::wstring> arguments(argv+1,argv+argc);const auto options=parse(arguments);
        LockedFile exe(options.target),dll(options.dll);exe.pe(false);dll.pe(true);asciiDll(dll.path);
        if(options.entry)exe.nativeEntryRva();
        const auto targetHash=exe.sha256(),dllHash=dll.sha256();
        demand(options.targetHash.empty() || options.targetHash==targetHash,"target hash differs from reviewed binary");
        demand(options.dllHash.empty() || options.dllHash==dllHash,"bootstrap hash differs from reviewed binary");
        const auto requested=options.workdir.empty()?std::filesystem::path(exe.path).parent_path().wstring():options.workdir;
        Handle directory(CreateFileW(requested.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,
            OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr));win(directory.value!=INVALID_HANDLE_VALUE,"review working directory");
        BY_HANDLE_FILE_INFORMATION directoryInfo{};win(GetFileInformationByHandle(directory.value,&directoryInfo),"working-directory identity");
        demand((directoryInfo.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)!=0,"working directory is not a directory");const auto workdir=physicalPath(directory.value);
        std::wcout<<L"Mode: "<<(options.launch?L"explicit reviewed startup insertion":L"REVIEW ONLY - no process creation")
            <<L"\nTarget: "<<printable(exe.path)<<L"\nTarget SHA-256: "<<targetHash<<L"\nBootstrap: "<<printable(dll.path)<<L"\nBootstrap SHA-256: "<<dllHash
            <<L"\nWorking directory: "<<printable(workdir)<<L"\nCommand line (escaped display): "<<printable(commandLine(options,exe.path))
            <<L"\nBeamRT capture=OFF; BeamRT graphics initialization=NONE; lighting=UNCHANGED; no game-file installation.\n";
        std::wcout<<L"Opt-in native-entry rendezvous: "<<(options.entry?L"ON (passive in production)":L"OFF")<<L'\n';
        if(!options.launch)return 0;
        return launchReviewed(options,exe,dll,workdir);
    }catch(const std::exception& error){std::cerr<<"Startup host refused: "<<error.what()<<'\n';return 1;}
}
