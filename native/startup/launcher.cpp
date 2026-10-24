#include "startup_contract.h"
#include "entry_contract.h"
#include "import_observer.h"
#include "pipeline_handoff.h"
#include "binding_handoff.h"
#include "resource_handoff.h"
#include "unattended/startup_owned_session.h"
#include "unattended/outer_child_session.h"
#include "unattended/startup_stop_channel.h"
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
#include <memory>
#include <sstream>
#ifdef BEAMRT_STARTUP_TEST_FAULTS
#include <psapi.h>
static void inspectOwnedImports(HANDLE process,const std::wstring& target){
    const auto name=std::filesystem::path(target).filename().wstring();
    if(name!=L"beamrt_import_fixture.exe")return;
    uintptr_t address=0;MEMORY_BASIC_INFORMATION memory{};
    while(VirtualQueryEx(process,reinterpret_cast<void*>(address),&memory,sizeof(memory))){
        const auto next=reinterpret_cast<uintptr_t>(memory.BaseAddress)+memory.RegionSize;if(next<=address)break;address=next;
        if(memory.Type!=MEM_IMAGE || memory.AllocationBase!=memory.BaseAddress)continue;
        wchar_t path[32768]{};const auto count=GetMappedFileNameW(process,memory.AllocationBase,path,32768);
        if(!count || std::filesystem::path(path).filename().wstring()!=name)continue;
        const auto base=reinterpret_cast<uintptr_t>(memory.AllocationBase);SIZE_T read=0;IMAGE_DOS_HEADER dos{};IMAGE_NT_HEADERS64 nt{};
        if(!ReadProcessMemory(process,reinterpret_cast<void*>(base),&dos,sizeof(dos),&read) || read!=sizeof(dos) || dos.e_magic!=IMAGE_DOS_SIGNATURE || dos.e_lfanew<=0 || dos.e_lfanew>1024*1024)return;
        if(!ReadProcessMemory(process,reinterpret_cast<void*>(base+dos.e_lfanew),&nt,sizeof(nt),&read) || read!=sizeof(nt) || nt.Signature!=IMAGE_NT_SIGNATURE)return;
        const auto directory=nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
        for(unsigned i=0;i<32;++i){IMAGE_IMPORT_DESCRIPTOR imported{};
            if(!ReadProcessMemory(process,reinterpret_cast<void*>(base+directory.VirtualAddress+i*sizeof(imported)),&imported,sizeof(imported),&read) || read!=sizeof(imported) || !imported.Name)break;
            char text[512]{};ReadProcessMemory(process,reinterpret_cast<void*>(base+imported.Name),text,sizeof(text)-1,&read);
            std::cout<<"Owned suspended fixture import["<<i<<"]="<<text<<"; name RVA="<<std::hex<<imported.Name<<std::dec<<'\n';
        }
        return;
    }
}
#endif

static void demand(bool ok,const char* reason){if(!ok)throw std::runtime_error(reason);}
static void win(BOOL ok,const char* reason){if(!ok)throw std::runtime_error(std::string(reason)+" Win32="+std::to_string(GetLastError()));}
static void crypto(NTSTATUS status){demand(status>=0,"SHA-256 provider operation failed");}
struct Handle {
    HANDLE value=INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE h):value(h){}
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
    Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;
};
struct MappingView {
    void* value=nullptr;
    ~MappingView(){if(value)UnmapViewOfFile(value);}
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
            && !nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].Size
            && nt.OptionalHeader.AddressOfEntryPoint && uint64_t(nt.OptionalHeader.AddressOfEntryPoint)+5<=nt.OptionalHeader.SizeOfImage,
            "native entry rendezvous does not support CLR/missing/out-of-image entry points");
        return nt.OptionalHeader.AddressOfEntryPoint;
    }
    std::vector<uint8_t> shaderBytes(uint32_t expectedStage) const {
        LARGE_INTEGER size{};win(GetFileSizeEx(file.value,&size),"shader file size");
        demand(size.QuadPart>=32 && size.QuadPart<=16*1024*1024,"shader file size unsupported");
        std::vector<uint8_t> result(static_cast<size_t>(size.QuadPart));at(0,result.data(),static_cast<DWORD>(result.size()));
        demand(std::memcmp(result.data(),"DXBC",4)==0,"compiled DXBC/DXIL container required, not shader source");
        auto word=[&](size_t offset){demand(offset<=result.size()-4,"shader header truncated");uint32_t value=0;std::memcpy(&value,result.data()+offset,4);return value;};
        demand(word(20)==1 && word(24)==result.size() && word(28)>0 && word(28)<=64 && 32+4*word(28)<=result.size(),"invalid shader container bounds");
        unsigned stages=0;for(uint32_t i=0;i<word(28);++i){const size_t offset=word(32+4*i);
            demand(offset>=32+4*word(28) && offset<=result.size()-8 && word(offset+4)<=result.size()-offset-8,"shader chunk bounds invalid");
            const auto tag=result.data()+offset;
            if(std::memcmp(tag,"SHDR",4)==0 || std::memcmp(tag,"SHEX",4)==0 || std::memcmp(tag,"DXIL",4)==0){
                demand(word(offset+4)>=8 && word(offset+8)>>16==expectedStage,"shader stage does not match vertex/pixel role");++stages;}}
        demand(stages==1,"missing/ambiguous shader stage");return result;
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
    bool owned=false;DWORD ownedOverall=0,ownedGrace=0,ownedReceiptWait=0;
    std::wstring ownedDirectory,ownedToken,ownedAck;
    uint64_t outerChannel=0;std::wstring outerDigest;
    bool entry=false;
    bool imports=false;
    bool pipeline=false;
    bool bindings=false;DWORD bindingWait=30;std::wstring bindingOutput;
    bool resources=false;uint32_t resourceProbeBytes=0,resourceMode=beamrtResourceAllAllocations,resourceProfile=beamrtResourceStorageLegacy;
    DWORD pipelineWait=30;
    std::wstring target,dll,workdir,targetHash,dllHash,ack;
    std::wstring vertex,pixel,vertexHash,pixelHash,rootOutput;
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
        if(flag==L"--observe-device-import"){out.imports=true;continue;}
        if(flag==L"--observe-gi-creation"){out.pipeline=true;continue;}
        if(flag==L"--observe-gi-bindings"){out.bindings=true;continue;}
        if(flag==L"--observe-gi-resources"){out.resources=true;continue;}
        if(flag==L"--resource-descriptors-only"){out.resourceMode=beamrtResourceDescriptorTextures;continue;}
        if(flag==L"--resource-compact-storage"){out.resourceProfile=beamrtResourceStorageCompact;continue;}
        if(flag==L"--resource-interned-storage"){out.resourceProfile=beamrtResourceStorageInterned;continue;}
        if(flag==L"--review")continue;
        demand(i+1<args.size(),"startup option missing value");const auto value=args[++i];
        if(flag==L"--target")out.target=localPath(value);
        else if(flag==L"--dll")out.dll=localPath(value);
        else if(flag==L"--workdir")out.workdir=localPath(value);
        else if(flag==L"--expected-target-sha256")out.targetHash=digest(value);
        else if(flag==L"--expected-dll-sha256")out.dllHash=digest(value);
        else if(flag==L"--acknowledge-native-insertion")out.ack=value;
        else if(flag==L"--owned-run-directory")out.ownedDirectory=localPath(value);
        else if(flag==L"--owned-run-token")out.ownedToken=value;
        else if(flag==L"--acknowledge-owned-force-close")out.ownedAck=value;
        else if(flag==L"--outer-config-sha256")out.outerDigest=digest(value);
        else if(flag==L"--outer-owned-channel"){
            demand(!value.empty() && value.size()<=20 && value.find_first_not_of(L"0123456789")==std::wstring::npos,"invalid inherited outer channel");
            out.outerChannel=std::stoull(value);
            demand(out.outerChannel>0 && out.outerChannel<UINT64_MAX-1,"invalid inherited outer channel value");
        }
        else if(flag==L"--owned-overall-seconds" || flag==L"--owned-normal-grace-seconds" || flag==L"--owned-receipt-wait-seconds"){
            demand(!value.empty() && value.size()<=3 && value.find_first_not_of(L"0123456789")==std::wstring::npos,"invalid owned-session duration");
            const DWORD seconds=static_cast<DWORD>(std::stoul(value));
            demand(seconds>=1 && seconds<=(flag==L"--owned-overall-seconds"?480u:30u),"owned-session duration outside bounded contract");
            if(flag==L"--owned-overall-seconds")out.ownedOverall=seconds;
            else if(flag==L"--owned-normal-grace-seconds")out.ownedGrace=seconds;
            else out.ownedReceiptWait=seconds;
        }
        else if(flag==L"--gi-vertex")out.vertex=localPath(value);
        else if(flag==L"--gi-pixel")out.pixel=localPath(value);
        else if(flag==L"--expected-gi-vertex-sha256")out.vertexHash=digest(value);
        else if(flag==L"--expected-gi-pixel-sha256")out.pixelHash=digest(value);
        else if(flag==L"--pipeline-root-out")out.rootOutput=localPath(value);
        else if(flag==L"--bindings-out")out.bindingOutput=localPath(value);
        else if(flag==L"--resource-cbv-probe-bytes"){
            demand(!value.empty() && value.size()<=5 && value.find_first_not_of(L"0123456789")==std::wstring::npos,"invalid resource CBV probe");
            out.resourceProbeBytes=static_cast<uint32_t>(std::stoul(value));demand(out.resourceProbeBytes>=1 && out.resourceProbeBytes<=65536,"resource CBV probe must be 1-65536 bytes");}
        else if(flag==L"--bindings-wait-seconds"){
            demand(!value.empty() && value.size()<=3 && value.find_first_not_of(L"0123456789")==std::wstring::npos,"invalid binding wait");
            out.bindingWait=static_cast<DWORD>(std::stoul(value));demand(out.bindingWait>=1 && out.bindingWait<=300,"binding wait must be 1-300 seconds");}
        else if(flag==L"--pipeline-wait-seconds"){
            demand(!value.empty() && value.size()<=3 && value.find_first_not_of(L"0123456789")==std::wstring::npos,"invalid pipeline wait");
            out.pipelineWait=static_cast<DWORD>(std::stoul(value));demand(out.pipelineWait>=1 && out.pipelineWait<=300,"pipeline wait must be 1-300 seconds");}
        else demand(false,"unknown startup option");
    }
    demand(!out.target.empty() && !out.dll.empty(),"explicit target EXE and bootstrap DLL required");
    demand(!(seen[L"--review"] && out.launch),"review and launch modes are mutually exclusive");
    const wchar_t* ownedFlags[]={L"--owned-run-directory",L"--owned-run-token",L"--owned-overall-seconds",L"--owned-normal-grace-seconds",L"--acknowledge-owned-force-close"};
    unsigned ownedFields=0;for(const auto flag:ownedFlags)if(seen[flag])++ownedFields;
    out.owned=ownedFields!=0;
    if(out.owned){
        demand(ownedFields==5,"owned session requires all five explicit options");
        demand(out.ownedToken.size()==32 && out.ownedToken.find_first_not_of(L"0123456789abcdef")==std::wstring::npos,"owned session requires a lowercase 32-hex token");
        demand(out.ownedAck==L"exact-created-child-after-normal-quit","owned session requires explicit exact-child force acknowledgement");
    }
    demand(!out.imports || out.entry,"import observation requires explicit entry rendezvous");
    demand(!out.pipeline || (out.entry && out.imports && !out.vertex.empty() && !out.pixel.empty()
        && !out.vertexHash.empty() && !out.pixelHash.empty() && !out.rootOutput.empty()),"GI creation audit requires entry/import, two shader files/hashes and a new root-output path");
    demand(out.pipeline || (out.vertex.empty() && out.pixel.empty() && out.vertexHash.empty() && out.pixelHash.empty() && out.rootOutput.empty()
        && !seen[L"--pipeline-wait-seconds"]),"pipeline options require explicit GI creation audit");
    demand(!out.bindings || (out.pipeline && !out.bindingOutput.empty()),"binding observation requires explicit creation audit and a new output path");
    demand(out.bindings || (out.bindingOutput.empty() && !seen[L"--bindings-wait-seconds"]),"binding options require explicit observation");
    demand(!out.bindings || _wcsicmp(out.bindingOutput.c_str(),out.rootOutput.c_str())!=0,"binding and root output paths must differ");
    demand(!out.resources || out.bindings,"resource observation requires explicit binding observation");
    demand(out.resources || !seen[L"--resource-cbv-probe-bytes"],"resource probe requires explicit resource observation");
    demand(out.resources || out.resourceMode==beamrtResourceAllAllocations,"resource descriptors-only mode requires explicit resource observation");
    demand(out.resourceMode!=beamrtResourceDescriptorTextures || !out.resourceProbeBytes,"descriptor-only resource observation does not support a CBV probe");
    demand(out.resourceProfile!=beamrtResourceStorageCompact || (out.resources && out.resourceMode==beamrtResourceDescriptorTextures && !out.resourceProbeBytes),
        "compact resource storage requires explicit descriptor-only resource observation without CBV probing");
    demand(!(seen[L"--resource-compact-storage"] && seen[L"--resource-interned-storage"]),"compact and interned resource storage options are mutually exclusive");
    demand(out.resourceProfile!=beamrtResourceStorageInterned || (out.resources && out.resourceMode==beamrtResourceDescriptorTextures && !out.resourceProbeBytes),
        "interned resource storage requires explicit descriptor-only resource observation without CBV probing");
    if(out.ownedReceiptWait){
        demand(out.owned && out.resources && out.resourceMode==beamrtResourceDescriptorTextures &&
            out.resourceProfile==beamrtResourceStorageInterned && !out.resourceProbeBytes,
            "receipt wait requires exact-owned interned descriptor observation without CBV probing");
        const auto expected=(std::filesystem::path(out.ownedDirectory)/L"recorded-draw.bin").wstring();
        demand(_wcsicmp(expected.c_str(),out.bindingOutput.c_str())==0,
            "receipt wait requires recorded-draw.bin inside the owned directory");
    }
    demand((out.outerChannel!=0)==!out.outerDigest.empty(),"outer mode requires inherited channel and explicit configuration digest together");
    if(out.outerChannel){
        demand(out.owned && !out.ownedReceiptWait,"outer mode requires all five ownership options without host-owned receipt wait");
        const auto leaf=std::filesystem::path(out.target).filename().wstring();
        demand(leaf==L"beamrt_startup_fixture.exe" || leaf==L"beamrt_binding_startup_fixture.exe",
            "outer-created mode is limited to named disposable fixtures; game execution is unavailable");
        if(out.resources && out.resourceMode==beamrtResourceDescriptorTextures && out.resourceProfile==beamrtResourceStorageInterned){
            const auto expected=(std::filesystem::path(out.ownedDirectory)/L"recorded-draw.bin").wstring();
            demand(_wcsicmp(expected.c_str(),out.bindingOutput.c_str())==0,
                "outer receipt readiness requires recorded-draw.bin inside the owned directory");
        }
    }
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
    demand(std::filesystem::path(target).filename()==L"beamrt_startup_fixture.exe" || std::filesystem::path(target).filename()==L"beamrt_import_fixture.exe","fault host accepts only the disposable fixtures");
    if(options.arguments.size()>=2 && options.arguments[0]==L"--fixture-host-fault" && options.arguments[1]==stage)
        throw std::runtime_error("fixture-injected startup failure");
    if(options.arguments.size()>=2 && options.arguments[0]==L"--fixture-host-fault"){
        const auto& fault=options.arguments[1];
        // Unclean exits bypass stack unwinding. Bounded hangs let the independent
        // outer owner demonstrate child cleanup while this host is still alive.
        // Both exist only in the fault build and only for named disposable EXEs.
        if(fault==std::wstring(L"crash-")+stage)ExitProcess(77);
        if(fault==std::wstring(L"hang-")+stage)Sleep(6000);
    }
#else
    (void)options;(void)target;(void)stage;
#endif
}
static void saveThreadEvidence(const std::wstring& path,const void* data,DWORD bytes){
    Handle file(CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr));
    win(file.value!=INVALID_HANDLE_VALUE,"new thread evidence artifact");DWORD written=0;
    win(WriteFile(file.value,data,bytes,&written,nullptr),"save thread evidence");demand(written==bytes,"incomplete thread evidence retained");
}
static void saveThreadPrefix(const std::wstring& path,const BeamRTBindingThreadPrefix& source,DWORD pid){
    const LONG count=source.count;MemoryBarrier();
    demand(source.bytes==sizeof(source) && source.abi==beamrtBindingThreadABI && source.processId==pid
        && count>=0 && count<=static_cast<LONG>(beamrtBindingThreadSampleLimit),"malformed thread sample prefix");
    BeamRTBindingThreadPrefix copy{};copy.bytes=sizeof(copy);copy.abi=beamrtBindingThreadABI;copy.processId=pid;copy.count=count;
    for(LONG i=0;i<count;++i){copy.samples[i]=source.samples[i];demand(beamrtBindingThreadSampleValid(copy.samples[i]),"invalid thread conflict sample");
        for(LONG j=0;j<i;++j)demand(copy.samples[i].commandId!=copy.samples[j].commandId || copy.samples[i].generation!=copy.samples[j].generation,"duplicate thread conflict epoch");}
    saveThreadEvidence(path,&copy,sizeof(copy));
    std::cout<<"Saved "<<count<<" first thread-conflict samples. CPU metadata only, not concurrent-call or GPU evidence.\n";
    for(LONG i=0;i<count;++i){const auto& s=copy.samples[i];std::cout<<"  conflict: list="<<s.commandId<<", generation="<<s.generation
        <<", method="<<beamrtBindingMethodName(s.method)<<", expected thread="<<s.expectedThread<<", caller="<<s.callerThread
        <<", Reset thread="<<s.resetThread<<", first accepted observed thread="<<s.firstRecordingThread
        <<", target ready="<<s.targetReady<<", prior observed target PSO="<<s.previouslyObservedTargetPipeline
        <<", metadata complete before rejection="<<s.metadataWasComplete<<", was available snapshot source="<<s.sourceWasSnapshot<<'\n';}
}
static int launchReviewedCore(const Options& options,const LockedFile& exe,const LockedFile& dll,const std::wstring& workdir,
    const std::vector<uint8_t>& vertex,const std::vector<uint8_t>& pixel,
    beamrt::unattended::StartupOwnedSession* ownedSession=nullptr,
    beamrt::unattended::StartupStopChannel* stopChannel=nullptr,
    beamrt::unattended::OuterChildSession* outerSession=nullptr) {
    // Called only by the explicit reviewed-launch branch, never by review/self-test.
    if(ownedSession)std::wcout<<L"Exact-owned shutdown ACTIVE: legacy core 'retained' diagnostics do not disable the concurrent owner watcher. Its final owned-exit.json, not an insertion message, records child exit/force status.\n";
    SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};Handle event(CreateEventW(&security,TRUE,FALSE,nullptr));
    win(event.value!=nullptr,"startup receipt event");Handle entryEvent(options.entry?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr);
    if(options.entry)win(entryEvent.value!=nullptr,"entry receipt event");
    Handle mapping(options.entry?CreateFileMappingW(INVALID_HANDLE_VALUE,&security,PAGE_READWRITE,0,sizeof(BeamRTEntryStatus),nullptr):nullptr);
    MappingView view;
    if(options.entry){win(mapping.value!=nullptr,"entry status mapping");view.value=MapViewOfFile(mapping.value,FILE_MAP_READ,0,0,sizeof(BeamRTEntryStatus));win(view.value!=nullptr,"read entry status mapping");}
    Handle importEvent(options.imports?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr);
    Handle importMapping(options.imports?CreateFileMappingW(INVALID_HANDLE_VALUE,&security,PAGE_READWRITE,0,sizeof(BeamRTImportObservation),nullptr):nullptr);
    MappingView importView;
    if(options.imports){win(importEvent.value && importMapping.value,"import receipt handles");
        importView.value=MapViewOfFile(importMapping.value,FILE_MAP_READ,0,0,sizeof(BeamRTImportObservation));win(importView.value!=nullptr,"read import receipt mapping");}
    const DWORD pipelineInputSize=static_cast<DWORD>(sizeof(BeamRTPipelineInput)+vertex.size()+pixel.size());
    Handle pipelineInput(options.pipeline?CreateFileMappingW(INVALID_HANDLE_VALUE,&security,PAGE_READWRITE,0,pipelineInputSize,nullptr):nullptr);
    Handle pipelineOutput(options.pipeline?CreateFileMappingW(INVALID_HANDLE_VALUE,&security,PAGE_READWRITE,0,sizeof(BeamRTPipelineReply),nullptr):nullptr);
    Handle pipelineStart(options.pipeline?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr);
    Handle pipelineMatch(options.pipeline?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr);
    MappingView pipelineView;
    if(options.pipeline){
        win(pipelineInput.value && pipelineOutput.value && pipelineStart.value && pipelineMatch.value,"pipeline handoff handles");
        MappingView input;input.value=MapViewOfFile(pipelineInput.value,FILE_MAP_WRITE,0,0,pipelineInputSize);win(input.value!=nullptr,"pipeline input mapping");
        const BeamRTPipelineInput header{sizeof(header),1,static_cast<uint32_t>(vertex.size()),static_cast<uint32_t>(pixel.size())};
        std::memcpy(input.value,&header,sizeof(header));auto data=static_cast<uint8_t*>(input.value)+sizeof(header);
        std::memcpy(data,vertex.data(),vertex.size());std::memcpy(data+vertex.size(),pixel.data(),pixel.size());
        pipelineView.value=MapViewOfFile(pipelineOutput.value,FILE_MAP_READ,0,0,sizeof(BeamRTPipelineReply));win(pipelineView.value!=nullptr,"pipeline receipt mapping");
    }
    Handle bindingOutput(options.bindings?CreateFileMappingW(INVALID_HANDLE_VALUE,&security,PAGE_READWRITE,0,sizeof(BeamRTBindingReply),nullptr):nullptr);
    Handle bindingStart(options.bindings?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr),bindingRecord(options.bindings?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr);MappingView bindingView;
    if(options.bindings){win(bindingOutput.value && bindingStart.value && bindingRecord.value,"binding handoff handles");
        bindingView.value=MapViewOfFile(bindingOutput.value,FILE_MAP_READ,0,0,sizeof(BeamRTBindingReply));win(bindingView.value!=nullptr,"binding receipt mapping");}
    Handle resourceOutput(options.resources?CreateFileMappingW(INVALID_HANDLE_VALUE,&security,PAGE_READWRITE,0,sizeof(BeamRTResourceReply),nullptr):nullptr);
    Handle resourceStart(options.resources?CreateEventW(&security,TRUE,FALSE,nullptr):nullptr);MappingView resourceView;
    if(options.resources){win(resourceOutput.value && resourceStart.value,"resource handoff handles");
        resourceView.value=MapViewOfFile(resourceOutput.value,FILE_MAP_READ,0,0,sizeof(BeamRTResourceReply));win(resourceView.value!=nullptr,"read resource receipt mapping");}
    HANDLE events[]={event.value,entryEvent.value,mapping.value,importEvent.value,importMapping.value,
        pipelineInput.value,pipelineOutput.value,pipelineStart.value,pipelineMatch.value,bindingOutput.value,bindingStart.value,bindingRecord.value,resourceOutput.value,resourceStart.value};
    Attributes attributes(events,options.resources?14:options.bindings?12:options.pipeline?9:options.imports?5:options.entry?3:1);
    STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);startup.lpAttributeList=attributes.list;
    auto command=commandLine(options,exe.path);std::vector<wchar_t> mutableCommand(command.begin(),command.end());mutableCommand.push_back(0);
    PROCESS_INFORMATION process{};
    if(outerSession)process=outerSession->Setup();
    else if(ownedSession)process=ownedSession->Create(exe.path,mutableCommand,workdir,startup,TRUE,CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT);
    else win(CreateProcessW(exe.path.c_str(),mutableCommand.data(),nullptr,nullptr,TRUE,
        CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,nullptr,workdir.c_str(),&startup.StartupInfo,&process),"create new suspended reviewed child");
    Handle processHandle(process.hProcess),threadHandle(process.hThread);bool resumeAttempted=false;
    std::wcout<<(outerSession?L"Using outer-created suspended fixture PID ":L"Created reviewed child PID ")<<process.dwProcessId<<L"; no PID lookup or existing-process attachment.\n";
    try {
        if(stopChannel)demand(stopChannel->PublishContext(process.dwProcessId),"owned process context publication refused before resume");
        if(outerSession)outerSession->RelayIPC(events,options.resources?14:options.bindings?12:options.pipeline?9:options.imports?5:options.entry?3:1);
        const auto childHandle=[&](HANDLE local)->uint64_t{return outerSession?outerSession->ChildValue(local):static_cast<uint64_t>(reinterpret_cast<ULONG_PTR>(local));};
        fixtureFault(options,exe.path,L"before-insert");
        const auto dllName=asciiDll(dll.path);const char* insert=dllName.c_str();
        // x64 only: no Detours automatic rundll32/helper fallback.
        win(DetourUpdateProcessWithDll(process.hProcess,&insert,1),"insert startup bootstrap into owned suspended child");
#ifdef BEAMRT_STARTUP_TEST_FAULTS
        inspectOwnedImports(process.hProcess,exe.path);
#endif
        fixtureFault(options,exe.path,L"before-payload");
        BeamRTStartupPayload payload{sizeof(payload),1,beamrtStartupMagic,process.dwProcessId,beamrtStartupObservationOnly,
            childHandle(event.value),{0,0}};
        win(DetourCopyPayloadToProcess(process.hProcess,beamrtStartupGuid,&payload,sizeof(payload)),"copy startup receipt payload");
        if(options.entry){
            BeamRTEntryPayload entry{sizeof(entry),1,beamrtEntryMagic,process.dwProcessId,process.dwThreadId,
                childHandle(entryEvent.value),childHandle(mapping.value),exe.nativeEntryRva(),0};
            win(DetourCopyPayloadToProcess(process.hProcess,beamrtEntryGuid,&entry,sizeof(entry)),"copy entry rendezvous payload");
        }
        if(options.imports){
            BeamRTImportPayload imports{sizeof(imports),1,beamrtImportMagic,process.dwProcessId,process.dwThreadId,
                childHandle(importEvent.value),childHandle(importMapping.value),{0,0}};
            win(DetourCopyPayloadToProcess(process.hProcess,beamrtImportGuid,&imports,sizeof(imports)),"copy separate import-observation payload");
        }
        if(options.pipeline){
            BeamRTPipelinePayload request{sizeof(request),beamrtPipelineHandoffABI,beamrtPipelineMagic,process.dwProcessId,process.dwThreadId,
                childHandle(pipelineInput.value),childHandle(pipelineOutput.value),
                childHandle(pipelineStart.value),childHandle(pipelineMatch.value),
                static_cast<uint32_t>(vertex.size()),static_cast<uint32_t>(pixel.size()),{0,0}};
            win(DetourCopyPayloadToProcess(process.hProcess,beamrtPipelineGuid,&request,sizeof(request)),"copy separate pipeline audit payload");
        }
        if(options.bindings){BeamRTBindingPayload request{sizeof(request),beamrtBindingHandoffABI,beamrtBindingMagic,process.dwProcessId,process.dwThreadId,
            childHandle(bindingOutput.value),childHandle(bindingStart.value),
            childHandle(bindingRecord.value),{0,0}};
            win(DetourCopyPayloadToProcess(process.hProcess,beamrtBindingGuid,&request,sizeof(request)),"copy separate binding-observation payload");}
        if(options.resources){BeamRTResourcePayload request{sizeof(request),beamrtResourceHandoffABI,beamrtResourceMagic,process.dwProcessId,process.dwThreadId,
            childHandle(resourceOutput.value),childHandle(resourceStart.value),options.resourceProbeBytes,options.resourceMode,options.resourceProfile,0};
            win(DetourCopyPayloadToProcess(process.hProcess,beamrtResourceGuid,&request,sizeof(request)),"copy separate resource-observation payload");}
        fixtureFault(options,exe.path,L"before-resume");
        const DWORD previous=outerSession?outerSession->Resume():ownedSession?ownedSession->Resume():ResumeThread(process.hThread);
        if(previous!=DWORD(-1))resumeAttempted=true;
        demand(previous==1,"unexpected initial suspension count; child retained after resume attempt");
        fixtureFault(options,exe.path,L"after-resume");
        HANDLE waits[]={event.value,process.hProcess};const DWORD result=WaitForMultipleObjects(2,waits,FALSE,15000);
        if(result!=WAIT_OBJECT_0){std::wcerr<<L"No startup receipt (wait="<<result<<L"). Child PID "<<process.dwProcessId
            <<((ownedSession || outerSession)?L" remains managed by its exact owner after resume. No renderer activation attempted.\n":L" is NOT terminated after resume. No renderer activation attempted.\n");
            DWORD code=STILL_ACTIVE;if(GetExitCodeProcess(process.hProcess,&code))std::wcerr<<L"Observed child exit/status: 0x"<<std::hex<<code<<std::dec<<L".\n";return 2;}
        std::wcout<<L"Startup bootstrap receipt received. BeamRT capture=OFF; BeamRT GPU work=OFF; lighting=UNCHANGED.\n"
            <<L"This proves DLL attach only, not game pass/resource access or stable rendering.\n";
        if(options.entry){
            HANDLE entryWaits[]={entryEvent.value,process.hProcess};const DWORD entryResult=WaitForMultipleObjects(2,entryWaits,FALSE,15000);
            if(entryResult!=WAIT_OBJECT_0){std::wcerr<<L"No native-entry receipt (wait="<<entryResult<<L"); resumed child is retained.\n";return 3;}
            const auto& status=*static_cast<const BeamRTEntryStatus*>(view.value);
            if(status.bytes!=sizeof(status) || status.abi!=1 || !status.armed || !status.reached || !status.released || status.hookAttached
                || !status.entryBytesRestored || FAILED(status.result) || status.ownerThread!=process.dwThreadId
                || status.graphicsQuiescenceVerified || status.cameraVerified || status.gpuOrderingVerified || status.lightingConsumed){
                std::wcerr<<L"Native-entry status incomplete/incompatible; no graphics activation. Resumed child retained.\n";return 4;
            }
            std::wcout<<L"Native-entry reached; one-shot entry hook restored. Fixture deviceStarted="<<status.deviceStarted
                <<L". Graphics quiescence and GI access remain unverified.\n";
        }
        if(options.imports){
            HANDLE importWaits[]={importEvent.value,process.hProcess};const DWORD importResult=WaitForMultipleObjects(2,importWaits,FALSE,15000);
            if(importResult!=WAIT_OBJECT_0){std::wcerr<<L"No imported-device receipt (wait="<<importResult<<L"); resumed child is retained.\n";return 5;}
            const auto& observed=*static_cast<const BeamRTImportObservation*>(importView.value);
            if(observed.bytes!=sizeof(observed) || observed.abi!=1 || observed.processId!=process.dwProcessId
                || observed.ownerThread!=process.dwThreadId || FAILED(observed.installResult) || !observed.hookAttached
                || !observed.complete || !observed.protectionRestored || !observed.candidateReady || !observed.deviceResults
                || !observed.slotRva || observed.disabled || observed.ambiguous || observed.slotRestored
                || observed.cameraVerified || observed.resourceStateChainVerified || observed.gpuOrderingVerified || observed.lightingConsumed){
                std::wcerr<<L"Imported-device observation absent/incomplete; install HRESULT="<<std::hex<<static_cast<uint32_t>(observed.installResult)
                    <<L". Child retained, capture/GI OFF.\n";return 5;
            }
            std::wcout<<L"First imported D3D12 creation observed: slot RVA="<<std::hex<<observed.slotRva<<std::dec
                <<L", caller thread="<<observed.lastCallerThread<<L", results="<<observed.deviceResults<<L".\n"
                <<L"Candidate only: later ambiguity, render-device selection, camera, resources and GI are unverified.\n";
        }
        if(options.pipeline){
            HANDLE startWaits[]={pipelineStart.value,process.hProcess};
            if(WaitForMultipleObjects(2,startWaits,FALSE,15000)!=WAIT_OBJECT_0){std::wcerr<<L"No pipeline start receipt; resumed child retained.\n";return 6;}
            const auto& reply=*static_cast<const BeamRTPipelineReply*>(pipelineView.value);const auto& start=reply.start;
            if(start.bytes!=sizeof(start) || start.abi!=beamrtPipelineHandoffABI || start.processId!=process.dwProcessId || start.initialThread!=process.dwThreadId
                || start.callerThread!=process.dwThreadId || FAILED(start.result) || start.info.bytes!=sizeof(start.info) || start.info.abi!=beamrtPipelineAuditInfoABI
                || !start.info.enabled || !start.info.healthy || start.info.ownerThread!=process.dwThreadId || start.info.attachedSlots<2 || start.info.attachedSlots>3
                || start.info.drawBindingsVerified || start.info.cameraVerified || start.info.gpuOrderingVerified || start.info.lightingConsumed){
                std::wcerr<<L"Pipeline installation refused/incomplete; resumed child retained, no capture/GI. Reason="
                    <<beamrtPipelineFailureName(start.info.failureReason)<<L", HRESULT="<<start.info.failureResult<<L".\n";return 6;
            }
            std::wcout<<L"Creation audit installed; waiting up to "<<options.pipelineWait<<L" seconds for exact VS+PS/root creation. No draw or GI proof.\n"<<std::flush;
            const auto deadline=GetTickCount64()+uint64_t(options.pipelineWait)*1000;HANDLE matchWaits[]={pipelineMatch.value,process.hProcess};DWORD matchResult=WAIT_TIMEOUT;
            do {const auto now=GetTickCount64();if(now>=deadline)break;
                const DWORD remaining=static_cast<DWORD>(deadline-now);matchResult=WaitForMultipleObjects(2,matchWaits,FALSE,remaining>10000?10000:remaining);
                if(matchResult==WAIT_TIMEOUT && GetTickCount64()<deadline)std::wcout<<L"Waiting for a matching creation; graphics/resource/GI flags remain unverified.\n"<<std::flush;
            }while(matchResult==WAIT_TIMEOUT);
            if(matchResult!=WAIT_OBJECT_0){const auto& progress=reply.progress;
                std::wcerr<<L"No exact pipeline creation receipt (wait="<<matchResult<<L"); child retained, no lighting activation.\n"
                    <<L"Approximate diagnostics only: roots="<<progress.roots<<L", legacy PSOs="<<progress.graphics<<L", unsupported streams="<<progress.streams
                    <<L", shader matches="<<progress.shaderMatches<<L", unknown-root matches="<<progress.unknownRoots<<L", healthy="<<progress.healthy
                    <<L", first failure="<<beamrtPipelineFailureName(static_cast<uint32_t>(progress.failureReason))<<L", HRESULT="<<progress.failureResult
                    <<L", tagged roots="<<progress.rootsTagged<<L", live tags="<<progress.liveRootTags<<L", live layouts="<<progress.liveLayouts
                    <<L", cached layouts="<<progress.cachedLayouts<<L", cache evictions="<<progress.cacheEvictions<<L", budget skipped="<<progress.budgetSkipped
                    <<L", metadata bytes="<<progress.metadataBytes<<L", peak bytes="<<progress.peakMetadataBytes<<L". Not frame/GPU proof.\n";return 7;}
            const auto& match=reply.match;const auto& info=match.info;
            if(match.bytes!=sizeof(match) || match.abi!=beamrtPipelineHandoffABI || match.processId!=process.dwProcessId || !match.rootBytes || match.rootBytes>sizeof(match.root)
                || info.bytes!=sizeof(info) || info.abi!=beamrtPipelineAuditInfoABI || !info.enabled || !info.healthy || !info.creationMatchAvailable || !info.shaderMatches || info.failureReason
                || info.rootBytes!=match.rootBytes || info.ownerThread!=process.dwThreadId || info.reserved || info.drawBindingsVerified
                || info.cameraVerified || info.gpuOrderingVerified || info.lightingConsumed){std::wcerr<<L"Creation receipt incomplete; child retained.\n";return 8;}
            Handle output(CreateFileW(options.rootOutput.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr));
            win(output.value!=INVALID_HANDLE_VALUE,"create new observed-root artifact");DWORD written=0;
            win(WriteFile(output.value,match.root,match.rootBytes,&written,nullptr),"save observed root");demand(written==match.rootBytes,"root artifact incomplete; retained for inspection");
            std::wcout<<L"PASS: exact VS+PS creation with observed root; root bytes="<<match.rootBytes<<L", unsupported streams="<<info.unsupportedStreams
                <<L". Draw bindings, camera, GPU ordering and GI remain unverified.\n";
            if(options.bindings){HANDLE readyWaits[]={bindingStart.value,process.hProcess};
                if(WaitForMultipleObjects(2,readyWaits,FALSE,15000)!=WAIT_OBJECT_0){std::wcerr<<L"No binding start receipt; resumed child retained.\n";return 9;}
                const auto& binding=*static_cast<const BeamRTBindingReply*>(bindingView.value);const auto& ready=binding.start;const auto& status=ready.status;
                if(ready.bytes!=sizeof(ready) || ready.abi!=1 || ready.processId!=process.dwProcessId || ready.initialThread!=process.dwThreadId || ready.callerThread!=process.dwThreadId
                    || FAILED(ready.result) || status.bytes!=sizeof(status) || status.abi!=1 || !status.enabled || !status.healthy || status.ownerThread!=process.dwThreadId
                    || status.attachedSlots<1 || status.attachedSlots>2 || status.targetReady || status.snapshotAvailable){std::wcerr<<L"Binding installation refused/incomplete; child retained.\n";return 9;}
                if(options.resources){
                    HANDLE resourceWaits[]={resourceStart.value,process.hProcess};
                    if(WaitForMultipleObjects(2,resourceWaits,FALSE,15000)!=WAIT_OBJECT_0){std::wcerr<<L"No resource start receipt; child retained.\n";return 13;}
                    const auto& resourceReady=static_cast<const BeamRTResourceReply*>(resourceView.value)->start;
                    if(!beamrtResourceStartReceiptValid(resourceReady,process.dwProcessId,process.dwThreadId,options.resourceMode,options.resourceProfile)){
                        std::wcerr<<L"Resource startup metadata malformed; child retained.\n";return 13;}
                    // Preserve coherent first-failure evidence even if startup
                    // became unhealthy before this parent's event read.
                    saveThreadEvidence(options.bindingOutput+L".resources-start.bin",&resourceReady,sizeof(resourceReady));
                    if(FAILED(resourceReady.result) || !resourceReady.status.enabled || !resourceReady.status.healthy || resourceReady.status.attachedSlots!=10){
                        std::wcerr<<L"Resource startup refused; metadata saved, child retained.\n";return 13;}
                }
                const auto bindingDeadline=GetTickCount64()+uint64_t(options.bindingWait)*1000;HANDLE recordWaits[]={bindingRecord.value,process.hProcess};DWORD observed=WAIT_TIMEOUT;
                do{const auto now=GetTickCount64();if(now>=bindingDeadline)break;const auto left=static_cast<DWORD>(bindingDeadline-now);observed=WaitForMultipleObjects(2,recordWaits,FALSE,left>10000?10000:left);
                    if(observed==WAIT_TIMEOUT && GetTickCount64()<bindingDeadline)std::wcout<<L"Waiting for matching recorded draw; no GPU/resource/camera proof.\n"<<std::flush;
                }while(observed==WAIT_TIMEOUT);
                if(observed!=WAIT_OBJECT_0){saveThreadPrefix(options.bindingOutput+L".thread-samples.bin",binding.threadSamples,process.dwProcessId);
                    const auto& p=binding.progress;std::wcerr<<L"No matching recorded-draw receipt; child retained. Approximate diagnostics only: targetReady="<<p.targetReady
                    <<L", target HRESULT="<<p.targetResult<<L", target attempts="<<p.targetAttempts<<L", target thread="<<p.targetThread<<L", healthy="<<p.healthy
                    <<L", failure="<<p.failureReason<<L", HRESULT="<<p.failureResult<<L", creations="<<p.creations<<L", tagged="<<p.tagged<<L", untracked="<<p.untracked
                    <<L", matched="<<p.matchedDraws<<L", rejected="<<p.rejectedDraws<<L", unsupported="<<p.unsupported<<L", thread rejects="<<p.threadRejected<<L", pressure skipped="<<p.pressureSkipped<<L".\n";return 10;}
                const auto& record=binding.record;const auto& state=record.status;
                if(record.bytes!=sizeof(record) || record.abi!=1 || record.processId!=process.dwProcessId || !record.recordThread || state.bytes!=sizeof(state) || state.abi!=1
                    || !state.enabled || !state.healthy || !state.targetReady || !state.snapshotAvailable || state.ownerThread!=process.dwThreadId || state.failureReason
                    || state.serial!=record.snapshot.serial || !beamrtBindingSnapshotValid(record.snapshot)){std::wcerr<<L"Recording receipt malformed/incomplete; child retained.\n";return 11;}
                const auto& threads=binding.threads;
                if(threads.bytes!=sizeof(threads) || threads.abi!=beamrtBindingThreadABI || threads.processId!=process.dwProcessId || threads.recordThread!=record.recordThread
                    || threads.snapshotSerial!=record.snapshot.serial || !threads.diagnostics.enabled || !beamrtBindingThreadDiagnosticsValid(threads.diagnostics)
                    || threads.diagnostics.threadRejected!=state.threadRejected){std::wcerr<<L"Thread diagnostic receipt malformed/incomplete; child retained.\n";return 12;}
                saveThreadEvidence(options.bindingOutput+L".threads.bin",&threads,sizeof(threads));
                saveThreadPrefix(options.bindingOutput+L".thread-samples.bin",binding.threadSamples,process.dwProcessId);
                if(options.resources){
                    const auto& resources=*static_cast<const BeamRTResourceReply*>(resourceView.value);
                    const auto& receipt=resources.record;const auto& observation=receipt.observation;
                    if(receipt.bytes!=sizeof(receipt) || receipt.abi!=beamrtResourceHandoffABI || receipt.processId!=process.dwProcessId || receipt.recordThread!=record.recordThread
                        || receipt.snapshotSerial!=record.snapshot.serial || receipt.mode!=options.resourceMode || receipt.reserved
                        || receipt.profile!=options.resourceProfile || receipt.reserved2
                        || observation.cbvProbeBytes!=options.resourceProbeBytes || observation.status.ownerThread!=state.ownerThread
                        || !beamrtResourceObservationValid(observation,record.snapshot,record.recordThread,options.resourceProfile)
                        || !beamrtResourceCopyFailureValid(receipt.copyFailure,observation.firstFailure,observation.status,receipt.mode,options.resourceProfile)
                        || (beamrtResourceCopyFailureExpected(observation.firstFailure)
                            && std::memcmp(&receipt.copyFailure.storageFailure,&observation.storageFailure,sizeof(observation.storageFailure)))){
                        std::wcerr<<L"Resource receipt malformed/mismatched; child retained.\n";return 13;}
                    saveThreadEvidence(options.bindingOutput+L".resources.bin",&receipt,sizeof(receipt));
                    unsigned inputs=0,outputs=0;for(unsigned i=0;i<6;++i)if(observation.srvResults[i]==S_OK)++inputs;
                    for(unsigned i=0;i<observation.rtvCount;++i)if(observation.rtvResults[i]==S_OK)++outputs;
                    std::cout<<"CPU resource observation: mode="<<receipt.mode<<", storage profile="<<receipt.profile<<", interval="<<observation.intervalAccepted<<", HRESULT="<<observation.result
                        <<", SRVs="<<inputs<<"/6, outputs="<<outputs<<"/"<<observation.rtvCount<<", CBV candidate HRESULT="<<observation.cbvResult
                        <<", healthy="<<observation.status.healthy<<", pressure="<<observation.status.pressure<<", overlaps="<<observation.status.overlaps
                        <<". Partial/refused observations are not resource/camera/GPU proof.\n";
                    const auto& storage=observation.storage;
                    std::cout<<"Descriptor storage: locations="<<storage.locations<<'/'<<storage.locationLimit<<", payloads="<<storage.payloads<<'/'<<storage.payloadLimit
                        <<", bytes="<<storage.usedBytes<<'/'<<storage.byteLimit<<", failure cause="<<observation.storageFailure.cause
                        <<", directory bytes="<<storage.directoryBytes<<", location bytes="<<storage.locationBytes<<", heap slots="<<storage.heaps<<'/'<<storage.heapLimit
                        <<". Exact numeric view sharing only; no resource lease or lighting proof.\n";
                    const auto& failure=observation.firstFailure;
                    std::cout<<"First tracker invalidation: kind="<<failure.kind<<", method="<<failure.method<<", thread="<<failure.callerThread
                        <<", callback="<<failure.callbackOrdinal<<", observed callbacks="<<failure.observedCallbacks
                        <<", active callbacks="<<failure.activeCallbacks<<", limit="<<failure.capacityLimit<<", attempted="<<failure.attemptedCount
                        <<", heaps="<<failure.liveHeaps<<", resources="<<failure.liveResources<<", occupied views="<<failure.views<<", draw tokens="<<failure.drawTokens
                        <<". First recorded under metadata lock; not absolute API-entry/GPU chronology.\n";
                    const auto& copy=receipt.copyFailure;
                    std::cout<<"First copy-capacity companion: present="<<copy.present<<", lanes="<<copy.laneCount
                        <<", failed lane="<<copy.failedLane<<", applied="<<copy.appliedLanes<<", views at entry="<<copy.entryViews
                        <<", after clear="<<copy.afterClearViews<<". Bounded CPU associations only; no independent failure/GPU proof.\n";
                }
                std::cout<<"Thread guard: total="<<threads.diagnostics.threadRejected<<", first epochs="<<threads.diagnostics.firstEpochConflicts
                    <<", repeat calls="<<threads.diagnostics.repeatedCalls<<", before target="<<threads.diagnostics.beforeTarget
                    <<", after target="<<threads.diagnostics.afterTarget<<", Reset-pinned/no accepted command="<<threads.diagnostics.resetOwnerOnlyConflicts<<".\n";
                for(unsigned i=0;i<beamrtBindingMethodCount;++i)if(threads.diagnostics.byMethod[i])
                    std::cout<<"  "<<beamrtBindingMethodName(i)<<": "<<threads.diagnostics.byMethod[i]<<'\n';
                Handle artifact(CreateFileW(options.bindingOutput.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr));win(artifact.value!=INVALID_HANDLE_VALUE,"create new binding artifact");
                DWORD bindingWritten=0;win(WriteFile(artifact.value,&record,sizeof(record),&bindingWritten,nullptr),"save CPU binding receipt");demand(bindingWritten==sizeof(record),"binding artifact incomplete");
                std::wcout<<L"PASS: matching recorded draw; kind="<<record.snapshot.drawKind<<L", count="<<record.snapshot.count<<L", viewport="<<record.snapshot.viewports[0].Width<<L"x"<<record.snapshot.viewports[0].Height
                    <<L", outputs="<<record.snapshot.renderTargetCount<<L". CPU recording only: descriptors, CBV contents, camera, queue/GPU completion and GI remain unverified.\n";
            }
            return 0;
        }
        return 0;
    }catch(...){
        // Only the new child, still suspended and never allowed to execute user work.
        if(outerSession){outerSession->Fail(ERROR_GEN_FAILURE);std::wcerr<<L"Outer process retains exact child cleanup; setup handles cannot terminate or resume it.\n";}
        else if(ownedSession){std::wcerr<<L"Owned session will finish exact-child shutdown and verify exit; setup handles cannot terminate.\n";}
        else if(!resumeAttempted){
            if(!TerminateProcess(process.hProcess,1))std::wcerr<<L"Cleanup failed for owned suspended child PID "<<process.dwProcessId<<L" (Win32="<<GetLastError()<<L").\n";
            else if(WaitForSingleObject(process.hProcess,5000)!=WAIT_OBJECT_0)std::wcerr<<L"Termination not yet confirmed for owned suspended child PID "<<process.dwProcessId<<L".\n";
        }
        else std::wcerr<<L"Child PID "<<process.dwProcessId<<L" retained after resume attempt; no forced live-game termination.\n";
        throw;
    }
}
static void saveOwnedExit(const Options& options,int coreResult,
    const beamrt::unattended::OwnedProcessReport& report,bool beforeResumeTimedOut,
    const beamrt::unattended::StartupStopChannelReport& channel) {
    std::string token;for(const wchar_t value:options.ownedToken)token+=static_cast<char>(value);
    std::ostringstream json;json<<std::boolalpha;
    json<<"{\"token\":\""<<token<<"\",\"expectedPid\":"<<report.processId
        <<",\"coreResult\":"<<coreResult<<",\"processExitVerified\":"<<report.processExitVerified
        <<",\"exitCode\":"<<report.exitCode<<",\"resumeAttempted\":"<<report.resumeAttempted<<",\"resumed\":"<<report.resumed
        <<",\"normalRequested\":"<<report.normalRequested<<",\"normalCallReturned\":"<<report.normalCallReturned
        <<",\"normalCallSucceeded\":"<<report.normalCallSucceeded<<",\"normalCallThrew\":"<<report.normalCallThrew
        <<",\"forceAttempted\":"<<report.forceAttempted<<",\"forceCallSucceeded\":"<<report.forceCallSucceeded
        <<",\"forceError\":"<<report.forceError<<",\"neverExecutedCleanupAttempted\":"<<report.neverExecutedCleanupAttempted
        <<",\"neverExecutedCleanupCallSucceeded\":"<<report.neverExecutedCleanupCallSucceeded
        <<",\"neverExecutedCleanupError\":"<<report.neverExecutedCleanupError<<",\"observationError\":"<<report.observationError
        <<",\"elapsedMilliseconds\":"<<report.elapsedMilliseconds<<",\"normalRequestMilliseconds\":"<<report.normalRequestMilliseconds
        <<",\"forceAttemptMilliseconds\":"<<report.forceAttemptMilliseconds<<",\"beforeResumeTimedOut\":"<<beforeResumeTimedOut
        <<",\"stopQueued\":"<<channel.requestAccepted<<",\"stopCompleted\":"<<channel.publicationCompleted
        <<",\"stopSucceeded\":"<<channel.publicationSucceeded<<",\"stopError\":"<<channel.publicationError
        <<",\"stopRequestedAtMilliseconds\":"<<channel.requestedAtMilliseconds
        <<",\"stopCompletedAtMilliseconds\":"<<channel.completedAtMilliseconds<<"}\n";
    const auto bytes=json.str();demand(bytes.size()<=8192,"owned exit report too large");
    const auto path=(std::filesystem::path(options.ownedDirectory)/L"owned-exit.json").wstring();
    const auto physicalReportPath=std::wstring(L"\\\\?\\")+path;
    Handle file(CreateFileW(physicalReportPath.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr));
    win(file.value!=INVALID_HANDLE_VALUE,"new owned exit report");DWORD written=0;
    win(WriteFile(file.value,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr),"write owned exit report");
    demand(written==bytes.size(),"incomplete owned exit report");win(FlushFileBuffers(file.value),"flush owned exit report");
}
static int launchReviewed(const Options& options,const LockedFile& exe,const LockedFile& dll,const std::wstring& workdir,
    const std::vector<uint8_t>& vertex,const std::vector<uint8_t>& pixel) {
    // The old manual branch deliberately retains its original lifecycle.
    if(!options.owned)return launchReviewedCore(options,exe,dll,workdir,vertex,pixel);
    using namespace beamrt::unattended;
    std::string token;for(const wchar_t value:options.ownedToken)token+=static_cast<char>(value);
    if(options.outerChannel){
        OuterChildSession outer(reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(options.outerChannel)),options.ownedToken,
            options.outerDigest,exe.path,options.ownedOverall,options.ownedGrace,
            options.resources?14:options.bindings?12:options.pipeline?9:options.imports?5:options.entry?3:1);
        auto externalChannel=StartupStopChannel::Create(options.ownedDirectory,token);
        try {
            const int core=launchReviewedCore(options,exe,dll,workdir,vertex,pixel,nullptr,externalChannel.get(),&outer);
            if(!core && options.resources && options.resourceMode==beamrtResourceDescriptorTextures && options.resourceProfile==beamrtResourceStorageInterned && !options.resourceProbeBytes)
                demand(externalChannel->PublishReceiptReady(outer.ProcessId()),"outer CPU receipt-ready publication refused");
            outer.Complete(core);return core;
        } catch(...){outer.Fail(ERROR_GEN_FAILURE);throw;}
    }
    auto channel=StartupStopChannel::Create(options.ownedDirectory,token);
    const WatchdogConfig config{uint64_t(options.ownedOverall)*1000,uint64_t(options.ownedGrace)*1000,5000,true};
    StartupOwnedSession session(config,[&](DWORD pid){return channel->RequestNormal(pid);});
    int result=1;
    try {
        result=launchReviewedCore(options,exe,dll,workdir,vertex,pixel,&session,channel.get());
        if(!result && options.ownedReceiptWait){
            const auto current=session.Report();
            demand(channel->PublishReceiptReady(current.processId),"CPU receipt-ready publication refused");
            const auto deadline=GetTickCount64()+uint64_t(options.ownedReceiptWait)*1000;
            // Do not Finish just because an ACK was published: Lua polls the
            // owner-stop channel before ACK. Only actual exit completes this
            // rendezvous; the independent original overall deadline stays live.
            for(;;){
                const auto state=session.Report();
                if(state.processExitVerified)break;
                if(state.normalRequested || state.observationError || GetTickCount64()>=deadline){result=17;break;}
                Sleep(10);
            }
        }
    }
    catch(...){const auto report=session.Finish();saveOwnedExit(options,1,report,session.BeforeResumeTimedOut(),channel->Report());throw;}
    const auto report=session.Finish();
    saveOwnedExit(options,result,report,session.BeforeResumeTimedOut(),channel->Report());
    if(result)return result;
    if(!report.processExitVerified)return 14;
    if(report.forceAttempted)return 15;
    if(report.exitCode)return 16;
    return 0;
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
    demand(!parse(baseline).owned,"owned shutdown activated by default");
    demand(!parse(baseline).entry,"native-entry rendezvous activated by default");
    demand(!parse(baseline).imports,"device-import observation activated by default");
    demand(!parse(baseline).pipeline,"pipeline audit activated by default");
    demand(!parse(baseline).bindings,"binding observer activated by default");
    demand(!parse(baseline).resources && !parse(baseline).resourceProbeBytes,"resource observer/probe activated by default");
    demand(parse(baseline).resourceMode==beamrtResourceAllAllocations,"descriptor-only resource mode activated by default");
    demand(parse(baseline).resourceProfile==beamrtResourceStorageLegacy,"compact resource storage activated by default");
    auto rejects=[&](std::vector<std::wstring> args){bool rejected=false;try{const auto invalid=parse(args);}catch(const std::exception&){rejected=true;}
        demand(rejected,"unsafe startup arguments accepted");++refused;};
    auto bad=baseline;bad.push_back(L"--launch-reviewed");rejects(bad);
    const std::vector<std::wstring> ownedArguments={L"--owned-run-directory",drive+L"owned-fixture",L"--owned-run-token",L"0123456789abcdef0123456789abcdef",
        L"--owned-overall-seconds",L"2",L"--owned-normal-grace-seconds",L"1",L"--acknowledge-owned-force-close",L"exact-created-child-after-normal-quit"};
    auto validOwned=baseline;validOwned.insert(validOwned.end(),ownedArguments.begin(),ownedArguments.end());
    demand(parse(validOwned).owned && !parse(validOwned).launch,"owned review did not remain inert");
    auto outerArgs=validOwned;outerArgs[1]=drive+L"beamrt_startup_fixture.exe";
    outerArgs.insert(outerArgs.end(),{L"--outer-owned-channel",L"64",L"--outer-config-sha256",std::wstring(64,L'a')});
    demand(parse(outerArgs).outerChannel==64 && !parse(outerArgs).launch,"outer review did not remain inert");
    bad=outerArgs;bad[1]=drive+L"BeamNG.drive.x64.exe";rejects(bad);
    bad=outerArgs;bad.insert(bad.end(),{L"--owned-receipt-wait-seconds",L"1"});rejects(bad);
    for(const auto value:{L"0",L"-1",L"18446744073709551615",L"64x"}){
        bad=outerArgs;bad[validOwned.size()+1]=value;rejects(bad);
    }
    bad=validOwned;bad.insert(bad.end(),{L"--outer-owned-channel",L"64"});rejects(bad);
    bad=validOwned;bad.insert(bad.end(),{L"--outer-config-sha256",std::wstring(64,L'a')});rejects(bad);
    bad=baseline;bad[1]=drive+L"beamrt_startup_fixture.exe";
    bad.insert(bad.end(),{L"--outer-owned-channel",L"64",L"--outer-config-sha256",std::wstring(64,L'a')});rejects(bad);
    for(size_t omitted=0;omitted<ownedArguments.size();omitted+=2){
        auto partial=baseline;for(size_t i=0;i<ownedArguments.size();i+=2)if(i!=omitted)partial.insert(partial.end(),{ownedArguments[i],ownedArguments[i+1]});rejects(partial);
    }
    for(const auto index:{3u,5u,7u,9u}){auto invalid=validOwned;invalid[baseline.size()+index]=L"invalid";rejects(invalid);}
    for(const auto duration:{L"0",L"481",L"-1",L"1.5"}){auto invalid=validOwned;invalid[baseline.size()+5]=duration;rejects(invalid);}
    for(const auto duration:{L"0",L"31"}){auto invalid=validOwned;invalid[baseline.size()+7]=duration;rejects(invalid);}
    bad=validOwned;bad.insert(bad.end(),{L"--owned-run-token",L"0123456789abcdef0123456789abcdef"});rejects(bad);
    bad=baseline;bad.push_back(L"--observe-device-import");rejects(bad);
    bad=baseline;bad.push_back(L"--observe-gi-creation");rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--pipeline-wait-seconds",L"301"});rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--gi-pixel",drive+L"shader.cso"});rejects(bad);
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
    BeamRTImportPayload imported{sizeof(imported),1,beamrtImportMagic,123,456,64,72,{0,0}};
    demand(beamrtImportPayloadValid(&imported,sizeof(imported),123,456),"valid import payload rejected");
    for(int field=0;field<9;++field){auto invalid=imported;
        if(field==0)invalid.bytes-=1;if(field==1)invalid.abi+=1;if(field==2)invalid.magic=0;if(field==3)invalid.processId+=1;
        if(field==4)invalid.initialThread+=1;if(field==5)invalid.receiptEvent=0;if(field==6)invalid.statusMapping=UINT64_MAX;
        if(field==7)invalid.reserved[0]=1;if(field==8)invalid.reserved[1]=1;
        demand(!beamrtImportPayloadValid(&invalid,sizeof(invalid),123,456),"unsupported import payload accepted");++refused;}
    BeamRTPipelinePayload pipeline{sizeof(pipeline),beamrtPipelineHandoffABI,beamrtPipelineMagic,123,456,64,72,80,88,32,32,{0,0}};
    demand(beamrtPipelinePayloadValid(&pipeline,sizeof(pipeline),123),"valid pipeline payload rejected");
    auto legacyPipeline=pipeline;legacyPipeline.abi=1;
    demand(!beamrtPipelinePayloadValid(&legacyPipeline,sizeof(legacyPipeline),123),"legacy pipeline transport accepted");++refused;
    for(int field=0;field<10;++field){auto invalid=pipeline;
        if(field==0)invalid.bytes-=1;if(field==1)invalid.abi+=1;if(field==2)invalid.magic=0;if(field==3)invalid.processId+=1;
        if(field==4)invalid.initialThread=0;if(field==5)invalid.vertexBytes=0;if(field==6)invalid.pixelBytes=16*1024*1024+1;
        if(field==7)invalid.inputMapping=0;if(field==8)invalid.matchEvent=UINT64_MAX;if(field==9)invalid.reserved[1]=1;
        demand(!beamrtPipelinePayloadValid(&invalid,sizeof(invalid),123),"unsupported pipeline payload accepted");++refused;}
    bad=baseline;bad.push_back(L"--observe-gi-bindings");rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--bindings-out",L"C:\\fixture\\record.bin"});rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--bindings-wait-seconds",L"301"});rejects(bad);
    bad=baseline;bad.push_back(L"--observe-gi-resources");rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--resource-cbv-probe-bytes",L"16"});rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--resource-cbv-probe-bytes",L"0"});rejects(bad);
    bad=baseline;bad.insert(bad.end(),{L"--resource-cbv-probe-bytes",L"65537"});rejects(bad);
    bad=baseline;bad.push_back(L"--resource-descriptors-only");rejects(bad);
    bad=baseline;bad.push_back(L"--resource-compact-storage");rejects(bad);
    bad=baseline;bad.push_back(L"--resource-interned-storage");rejects(bad);
    auto descriptorArgs=baseline;descriptorArgs.insert(descriptorArgs.end(),{L"--entry-rendezvous",L"--observe-device-import",L"--observe-gi-creation",
        L"--gi-vertex",drive+L"fixture.vs.cso",L"--gi-pixel",drive+L"fixture.ps.cso",L"--expected-gi-vertex-sha256",std::wstring(64,L'0'),
        L"--expected-gi-pixel-sha256",std::wstring(64,L'0'),L"--pipeline-root-out",drive+L"root.bin",L"--observe-gi-bindings",
        L"--bindings-out",drive+L"draw.bin",L"--observe-gi-resources",L"--resource-descriptors-only"});
    const auto descriptorOptions=parse(descriptorArgs);
    demand(descriptorOptions.resources && descriptorOptions.resourceMode==beamrtResourceDescriptorTextures && !descriptorOptions.resourceProbeBytes,
        "explicit descriptor-only resource mode refused");
    bad=descriptorArgs;bad.insert(bad.end(),{L"--resource-cbv-probe-bytes",L"16"});rejects(bad);
    bad=descriptorArgs;bad.push_back(L"--resource-descriptors-only");rejects(bad);
    auto compactArgs=descriptorArgs;compactArgs.push_back(L"--resource-compact-storage");const auto compactOptions=parse(compactArgs);
    demand(compactOptions.resources && compactOptions.resourceMode==beamrtResourceDescriptorTextures
        && compactOptions.resourceProfile==beamrtResourceStorageCompact && !compactOptions.resourceProbeBytes,"explicit compact storage profile refused");
    bad=descriptorArgs;bad.pop_back();bad.push_back(L"--resource-compact-storage");rejects(bad);
    bad=compactArgs;bad.push_back(L"--resource-compact-storage");rejects(bad);
    bad=compactArgs;bad.insert(bad.end(),{L"--resource-cbv-probe-bytes",L"16"});rejects(bad);
    auto internedArgs=descriptorArgs;internedArgs.push_back(L"--resource-interned-storage");const auto internedOptions=parse(internedArgs);
    auto receiptArgs=internedArgs;receiptArgs.insert(receiptArgs.end(),ownedArguments.begin(),ownedArguments.end());
    receiptArgs.insert(receiptArgs.end(),{L"--owned-receipt-wait-seconds",L"30"});
    for(size_t i=0;i<receiptArgs.size();++i)if(receiptArgs[i]==L"--bindings-out")receiptArgs[i+1]=drive+L"owned-fixture\\recorded-draw.bin";
    demand(parse(receiptArgs).ownedReceiptWait==30 && !parse(receiptArgs).launch,"receipt wait review did not remain inert");
    for(const auto duration:{L"0",L"31",L"-1",L"1.5"}){auto invalid=receiptArgs;invalid.back()=duration;rejects(invalid);}
    bad=baseline;bad.insert(bad.end(),{L"--owned-receipt-wait-seconds",L"1"});rejects(bad);
    bad=validOwned;bad.insert(bad.end(),{L"--owned-receipt-wait-seconds",L"1"});rejects(bad);
    bad=receiptArgs;bad.push_back(L"--owned-receipt-wait-seconds");bad.push_back(L"1");rejects(bad);
    bad=receiptArgs;for(size_t i=0;i<bad.size();++i)if(bad[i]==L"--bindings-out")bad[i+1]=drive+L"draw.bin";rejects(bad);
    bad=receiptArgs;for(auto& value:bad)if(value==L"--resource-interned-storage")value=L"--resource-compact-storage";rejects(bad);
    demand(internedOptions.resources && internedOptions.resourceMode==beamrtResourceDescriptorTextures
        && internedOptions.resourceProfile==beamrtResourceStorageInterned && !internedOptions.resourceProbeBytes,"explicit interned storage profile refused");
    bad=descriptorArgs;bad.pop_back();bad.push_back(L"--resource-interned-storage");rejects(bad);
    bad=internedArgs;bad.push_back(L"--resource-interned-storage");rejects(bad);
    bad=internedArgs;bad.insert(bad.end(),{L"--resource-cbv-probe-bytes",L"16"});rejects(bad);
    bad=internedArgs;bad.push_back(L"--resource-compact-storage");rejects(bad);
    bad=compactArgs;bad.push_back(L"--resource-interned-storage");rejects(bad);
    BeamRTResourcePayload resourcePayload{sizeof(resourcePayload),beamrtResourceHandoffABI,beamrtResourceMagic,123,456,64,72,16,beamrtResourceAllAllocations,beamrtResourceStorageLegacy,0};
    demand(beamrtResourcePayloadValid(&resourcePayload,sizeof(resourcePayload),123,456),"valid resource payload rejected");
    auto descriptorPayload=resourcePayload;descriptorPayload.mode=beamrtResourceDescriptorTextures;descriptorPayload.cbvProbeBytes=0;
    demand(beamrtResourcePayloadValid(&descriptorPayload,sizeof(descriptorPayload),123,456),"valid descriptor-only resource payload rejected");
    auto probedDescriptorPayload=descriptorPayload;probedDescriptorPayload.cbvProbeBytes=16;
    demand(!beamrtResourcePayloadValid(&probedDescriptorPayload,sizeof(probedDescriptorPayload),123,456),"descriptor-only CBV probe payload accepted");++refused;
    auto compactPayload=descriptorPayload;compactPayload.profile=beamrtResourceStorageCompact;
    demand(beamrtResourcePayloadValid(&compactPayload,sizeof(compactPayload),123,456),"valid compact resource payload rejected");
    auto compactAllAllocations=compactPayload;compactAllAllocations.mode=beamrtResourceAllAllocations;
    demand(!beamrtResourcePayloadValid(&compactAllAllocations,sizeof(compactAllAllocations),123,456),"compact all-allocation payload accepted");++refused;
    auto internedPayload=descriptorPayload;internedPayload.profile=beamrtResourceStorageInterned;
    demand(beamrtResourcePayloadValid(&internedPayload,sizeof(internedPayload),123,456),"valid interned resource payload rejected");
    auto internedAllAllocations=internedPayload;internedAllAllocations.mode=beamrtResourceAllAllocations;
    demand(!beamrtResourcePayloadValid(&internedAllAllocations,sizeof(internedAllAllocations),123,456),"interned all-allocation payload accepted");++refused;
    auto probedInterned=internedPayload;probedInterned.cbvProbeBytes=16;
    demand(!beamrtResourcePayloadValid(&probedInterned,sizeof(probedInterned),123,456),"interned CBV probe payload accepted");++refused;
    for(const auto prior:{1u,2u,3u,4u,5u,6u}){auto invalid=resourcePayload;invalid.abi=prior;
        demand(!beamrtResourcePayloadValid(&invalid,sizeof(invalid),123,456),"prior resource ABI accepted");++refused;}
    BeamRTResourceStartReceipt refusedStart{};refusedStart.bytes=sizeof(refusedStart);refusedStart.abi=beamrtResourceHandoffABI;
    refusedStart.processId=123;refusedStart.initialThread=refusedStart.callerThread=456;
    auto& rs=refusedStart.status;rs.bytes=sizeof(rs);rs.abi=1;rs.enabled=1;rs.ownerThread=456;rs.attachedSlots=10;rs.callbacks=rs.overlaps=1;
    auto& rf=refusedStart.firstFailure;rf.bytes=sizeof(rf);rf.abi=1;rf.kind=BeamRTResourceFailureOverlap;rf.method=BeamRTResourceMethodCreateSRV;
    rf.callerThread=456;rf.activeCallbacks=2;rf.callbackOrdinal=rf.observedCallbacks=rf.overlaps=1;
    auto& storage=refusedStart.storage;storage.bytes=sizeof(storage);storage.abi=2;storage.profile=beamrtResourceStorageLegacy;
    storage.locationLimit=256;storage.payloadLimit=256;storage.byteLimit=47104;storage.locationBytes=24;
    auto& storageFailure=refusedStart.storageFailure;storageFailure.bytes=sizeof(storageFailure);storageFailure.abi=2;
    storageFailure.present=1;storageFailure.atFailure=storage;
    demand(beamrtResourceStartReceiptValid(refusedStart,123,456),"coherent unhealthy startup evidence lost");
    auto descriptorStart=refusedStart;descriptorStart.mode=beamrtResourceDescriptorTextures;
    demand(beamrtResourceStartReceiptValid(descriptorStart,123,456,beamrtResourceDescriptorTextures),"descriptor-only startup mode echo refused");
    demand(!beamrtResourceStartReceiptValid(descriptorStart,123,456),"mismatched startup resource mode accepted");++refused;
    auto compactStart=descriptorStart;compactStart.profile=beamrtResourceStorageCompact;
    compactStart.status.abi=compactStart.firstFailure.abi=beamrtResourceStatusABI(beamrtResourceStorageCompact);
    compactStart.storage.profile=beamrtResourceStorageCompact;compactStart.storage.locationLimit=1024;compactStart.storageFailure.atFailure=compactStart.storage;
    demand(beamrtResourceStartReceiptValid(compactStart,123,456,beamrtResourceDescriptorTextures,beamrtResourceStorageCompact),"compact startup profile echo refused");
    demand(!beamrtResourceStartReceiptValid(compactStart,123,456,beamrtResourceDescriptorTextures),"legacy validator silently accepted compact startup");++refused;
    demand(!beamrtResourceFailureValid(compactStart.firstFailure,compactStart.status),"legacy validator silently accepted compact status/failure ABI");++refused;
    auto internedStart=descriptorStart;internedStart.profile=beamrtResourceStorageInterned;
    internedStart.status.abi=internedStart.firstFailure.abi=beamrtResourceStatusABI(beamrtResourceStorageInterned);
    internedStart.storage.profile=beamrtResourceStorageInterned;internedStart.storage.locationLimit=4096;
    internedStart.storage.directoryBytes=internedStart.storage.usedBytes=512;internedStart.storage.locationBytes=14;internedStart.storage.heapLimit=32;
    internedStart.storageFailure.atFailure=internedStart.storage;
    demand(beamrtResourceStartReceiptValid(internedStart,123,456,beamrtResourceDescriptorTextures,beamrtResourceStorageInterned),"interned startup profile/empty directory refused");
    demand(!beamrtResourceStartReceiptValid(internedStart,123,456,beamrtResourceDescriptorTextures),"legacy validator silently accepted interned zero-view startup");++refused;
    demand(!beamrtResourceStartReceiptValid(internedStart,123,456,beamrtResourceDescriptorTextures,beamrtResourceStorageCompact),"compact validator silently accepted interned zero-view startup");++refused;
    demand(!beamrtResourceFailureValid(internedStart.firstFailure,internedStart.status),"legacy validator silently accepted interned status/failure ABI");++refused;
    for(int field=0;field<12;++field){auto invalid=internedStart;
        if(field==0)invalid.storage.abi=1;if(field==1)invalid.storage.directoryBytes=0;if(field==2)invalid.storage.locationBytes=24;
        if(field==3)invalid.storage.heaps=1;if(field==4)invalid.storage.heapLimit=0;if(field==5)invalid.storage.usedBytes=0;
        if(field==6)invalid.storageFailure.abi=1;if(field==7)invalid.storageFailure.attemptedHeaps=1;if(field==8)invalid.storageFailure.reserved2=1;
        if(field==9)invalid.status.abi=2;if(field==10)invalid.firstFailure.abi=2;if(field==11)invalid.storageFailure.atFailure.directoryBytes=0;
        demand(!beamrtResourceStartReceiptValid(invalid,123,456,beamrtResourceDescriptorTextures,beamrtResourceStorageInterned),"malformed interned cold-empty/failure sample accepted");++refused;}
    for(int field=0;field<14;++field){auto invalid=refusedStart;
        if(field==0)invalid.abi=2;if(field==1)invalid.firstFailure.method=BeamRTResourceMethodNone;if(field==2)invalid.status.healthy=1;
        if(field==3)invalid.mode=beamrtResourceDescriptorTextures+1;if(field==4)invalid.reserved=1;if(field==5)invalid.abi=3;
        if(field==6)invalid.profile=beamrtResourceStorageCompact;if(field==7)invalid.reserved2=1;
        if(field==8)invalid.storage.profile=beamrtResourceStorageCompact;if(field==9)++invalid.storage.locationLimit;
        if(field==10)++invalid.storage.payloadLimit;if(field==11)++invalid.storage.byteLimit;
        if(field==12)invalid.storageFailure.present=0;if(field==13)invalid.storageFailure.atFailure.usedBytes=1;
        demand(!beamrtResourceStartReceiptValid(invalid,123,456),"malformed startup first failure accepted");++refused;}
    BeamRTResourceCopyFailure emptyCopy{};emptyCopy.bytes=sizeof(emptyCopy);emptyCopy.abi=beamrtResourceCopyFailureABI;
    demand(!beamrtResourceCopyFailureExpected(rf) && beamrtResourceCopyFailureValid(emptyCopy,rf,rs,beamrtResourceAllAllocations),
        "canonical empty copy companion refused for a non-copy first cause");
    for(int field=0;field<8;++field){auto invalid=emptyCopy;
        if(field==0)--invalid.bytes;if(field==1)++invalid.abi;if(field==2)invalid.present=1;if(field==3)invalid.mode=beamrtResourceDescriptorTextures;
        if(field==4)invalid.reserved[0]=1;if(field==5)invalid.lanes[0].sourceCpu=8;if(field==6)invalid.firstFailure=rf;if(field==7)invalid.heaps[0].heapId=1;
        demand(!beamrtResourceCopyFailureValid(invalid,rf,rs,beamrtResourceAllAllocations),"malformed empty copy companion accepted");++refused;}
    auto copyCause=rf;copyCause.kind=BeamRTResourceFailureViewCapacity;copyCause.method=BeamRTResourceMethodCopyRanges;
    copyCause.capacityLimit=beamrtResourceViewLimit;copyCause.attemptedCount=beamrtResourceViewLimit+1;copyCause.pressure=1;
    auto copyStatus=rs;copyStatus.pressure=1;
    demand(beamrtResourceCopyFailureExpected(copyCause) && !beamrtResourceCopyFailureValid(emptyCopy,copyCause,copyStatus,beamrtResourceAllAllocations),
        "copy-capacity first cause accepted without its companion");++refused;
    for(int field=0;field<12;++field){auto invalid=resourcePayload;
        if(field==0)--invalid.bytes;if(field==1)++invalid.abi;if(field==2)invalid.magic=0;if(field==3)++invalid.processId;if(field==4)++invalid.initialThread;
        if(field==5)invalid.outputMapping=0;if(field==6)invalid.startEvent=UINT64_MAX;if(field==7)invalid.startEvent=invalid.outputMapping;
        if(field==8)invalid.cbvProbeBytes=65537;if(field==9)invalid.mode=beamrtResourceDescriptorTextures+1;
        if(field==10)invalid.profile=beamrtResourceStorageInterned+1;if(field==11)invalid.reserved=1;
        demand(!beamrtResourcePayloadValid(&invalid,sizeof(invalid),123,456),"invalid resource payload accepted");++refused;}
    BeamRTBindingPayload binding{sizeof(binding),beamrtBindingHandoffABI,beamrtBindingMagic,123,456,64,72,80,{0,0}};
    demand(beamrtBindingPayloadValid(&binding,sizeof(binding),123,456),"valid binding payload rejected");
    auto legacyBinding=binding;legacyBinding.abi=1;
    demand(!beamrtBindingPayloadValid(&legacyBinding,sizeof(legacyBinding),123,456),"legacy binding transport accepted");++refused;
    for(int field=0;field<10;++field){auto invalid=binding;
        if(field==0)--invalid.bytes;if(field==1)++invalid.abi;if(field==2)invalid.magic=0;if(field==3)++invalid.processId;if(field==4)++invalid.initialThread;
        if(field==5)invalid.outputMapping=0;if(field==6)invalid.startEvent=UINT64_MAX;if(field==7)invalid.recordEvent=invalid.startEvent;
        if(field==8)invalid.reserved[0]=1;if(field==9)invalid.reserved[1]=1;
        demand(!beamrtBindingPayloadValid(&invalid,sizeof(invalid),123,456),"invalid binding payload accepted");++refused;}
    BeamRTBindingSnapshot recording{};recording.bytes=sizeof(recording);recording.abi=1;recording.recordedDraw=1;recording.drawKind=1;
    recording.commandId=recording.generation=recording.serial=1;recording.cbv=256;recording.count=3;recording.instances=1;
    recording.viewportCount=recording.scissorCount=recording.renderTargetCount=1;recording.viewports[0]={0,0,1,1,0,1};recording.scissors[0]={0,0,1,1};recording.renderTargets[0]=5000;
    recording.srvHeap={1,1000,2000,6,32,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};recording.samplerHeap={2,3000,4000,6,16,D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};
    recording.srvTable=2000;recording.samplerTable=4000;for(unsigned i=0;i<6;++i){recording.srvCpu[i]=1000+i*32;recording.samplerCpu[i]=3000+i*16;}
    demand(beamrtBindingSnapshotValid(recording),"valid CPU recording shape rejected");
    for(int field=0;field<37;++field){auto invalid=recording;
        if(field==0)--invalid.bytes;if(field==1)++invalid.abi;if(field==2)invalid.recordedDraw=0;if(field==3)invalid.drawKind=3;if(field==4)invalid.commandId=0;
        if(field==5)invalid.generation=0;if(field==6)invalid.serial=0;if(field==7)invalid.cbv=0;if(field==8)++invalid.cbv;if(field==9)invalid.count=0;
        if(field==10)invalid.instances=0;if(field==11)invalid.viewportCount=0;if(field==12)invalid.viewportCount=17;if(field==13)invalid.scissorCount=0;
        if(field==14)invalid.scissorCount=17;if(field==15)invalid.renderTargetCount=0;if(field==16)invalid.renderTargetCount=9;
        if(field==17)invalid.descriptorProvenanceVerified=1;if(field==18)invalid.cbvContentsVerified=1;if(field==19)invalid.cameraVerified=1;
        if(field==20)invalid.gpuOrderingVerified=1;if(field==21)invalid.lightingConsumed=1;if(field==22)invalid.srvHeap.count=5;if(field==23)invalid.samplerHeap.type=0;
        if(field==24)invalid.srvHeap.flags=0;if(field==25)++invalid.samplerCpu[0];if(field==26)++invalid.srvTable;if(field==27)invalid.samplerHeap.cpu=UINT64_MAX;
        if(field==28)invalid.viewports[0].Width=std::nanf("");if(field==29)invalid.scissors[0].right=0;if(field==30)invalid.renderTargets[0]=0;
        if(field==31)invalid.srvHeap.identity=0;if(field==32)invalid.samplerHeap.identity=0;if(field==33)invalid.viewports[0].MaxDepth=2;
        if(field==34)invalid.srvHeap.gpu=0;if(field==35)invalid.samplerHeap.stride=0;if(field==36)++invalid.srvCpu[5];
        demand(!beamrtBindingSnapshotValid(invalid),"invalid CPU recording shape accepted");++refused;}
    BeamRTBindingThreadDiagnostics diagnostic{};diagnostic.bytes=sizeof(diagnostic);diagnostic.abi=beamrtBindingThreadABI;diagnostic.enabled=1;
    diagnostic.sampleCount=1;diagnostic.threadRejected=3;diagnostic.firstEpochConflicts=1;diagnostic.repeatedCalls=2;
    diagnostic.beforeTarget=1;diagnostic.afterTarget=2;diagnostic.resetOwnerOnlyConflicts=1;diagnostic.byMethod[10]=3;
    diagnostic.samples[0]={1,1,10,123,456,123,0,0,0,1,0,0};
    demand(beamrtBindingThreadDiagnosticsValid(diagnostic),"valid CPU thread evidence rejected");
    for(int field=0;field<24;++field){auto invalid=diagnostic;
        if(field==0)--invalid.bytes;if(field==1)++invalid.abi;if(field==2)invalid.enabled=2;if(field==3)invalid.sampleCount=17;
        if(field==4)++invalid.threadRejected;if(field==5)invalid.firstEpochConflicts=4;if(field==6)++invalid.repeatedCalls;
        if(field==7)invalid.beforeTarget=4;if(field==8)++invalid.afterTarget;if(field==9)invalid.resetOwnerOnlyConflicts=2;
        if(field==10)++invalid.droppedEpochSamples;if(field==11)++invalid.byMethod[10];if(field==12){invalid.byMethod[0]=1;--invalid.byMethod[10];}
        if(field==13)invalid.samples[0].method=24;if(field==14)invalid.samples[0].expectedThread=456;if(field==15)invalid.samples[0].resetThread=789;
        if(field==16)invalid.samples[0].firstRecordingThread=789;if(field==17)invalid.samples[0].targetReady=2;
        if(field==18)invalid.samples[0].previouslyObservedTargetPipeline=1;if(field==19)invalid.samples[0].metadataWasComplete=2;
        if(field==20)invalid.samples[0].sourceWasSnapshot=2;if(field==21)invalid.samples[0].reserved=1;
        if(field==22){invalid.sampleCount=2;invalid.firstEpochConflicts=2;invalid.repeatedCalls=1;invalid.samples[1]=invalid.samples[0];}
        if(field==23){invalid.threadRejected=UINT64_MAX;invalid.repeatedCalls=UINT64_MAX-1;invalid.afterTarget=UINT64_MAX-1;
            invalid.byMethod[10]=UINT64_MAX;invalid.byMethod[11]=1;}
        demand(!beamrtBindingThreadDiagnosticsValid(invalid),"invalid thread diagnostic evidence accepted");++refused;
    }
    std::cout<<"PASS: startup review defaults, exact Windows argument roundtrip, "<<refused<<" rejected option/payload cases. No child launched or DLL loaded.\n";
}
int wmain(int argc,wchar_t** argv) {
    try {
        if(argc==2 && std::wstring(argv[1])==L"--self-test"){selfTest();return 0;}
        if(argc==1 || (argc==2 && std::wstring(argv[1])==L"--help")){
            std::cout<<"Review only by default: --review --target <absolute x64 EXE> --dll <absolute bootstrap DLL> [--workdir <directory>] [-- <exact application arguments>]\n"
                <<"Optional --entry-rendezvous arms a native-entry hook; passive unless the separate import observer is requested.\n"
                <<"Separate --observe-device-import enables image-scoped creation observation only; requires --entry-rendezvous. No capture or GPU work.\n"
                <<"Separate --observe-gi-creation additionally requires --gi-vertex/--gi-pixel, both --expected-gi-*-sha256 hashes and --pipeline-root-out; optional --pipeline-wait-seconds 1-300.\n"
                <<"Separate --observe-gi-bindings requires creation observation and a new --bindings-out; optional --bindings-wait-seconds 1-300. CPU recording only, not resources or GI.\n"
                <<"Separate --observe-gi-resources requires binding observation; writes CPU-only .resources-start.bin/.resources.bin sidecars. Optional --resource-cbv-probe-bytes 1-65536; absent means no CBV probe, never a guessed camera size.\n"
                <<"Optional --resource-descriptors-only requires --observe-gi-resources, admits supported descriptor textures only, and forbids CBV probing. Legacy all-allocation admission remains the default.\n"
                <<"Optional --resource-compact-storage additionally requires descriptor-only observation and no CBV probe; its fixed 47104-byte budget has separate 1024-location and 256-payload limits. Legacy 256-location storage remains the default.\n"
                <<"Optional --resource-interned-storage selects the separate exact 14-byte-location representation (4096 logical work bound, 256 payloads, 32 heap slots, 512-byte in-arena directory); the same 47104-byte arena can stop first. Requires descriptor-only/no CBV and is mutually exclusive with compact storage.\n"
                <<"ABI7 resource draw receipts append bounded first-copy-capacity metadata only when joined to the original first failure; no matching draw means no later companion artifact.\n"
                <<"Optional exact-owned shutdown requires all five --owned-run-directory, --owned-run-token, --owned-overall-seconds 1-480, --owned-normal-grace-seconds 1-30, and --acknowledge-owned-force-close exact-created-child-after-normal-quit options. Review remains inert; launch keeps the created child's private master handle and may force only that child after a normal-request attempt and full grace. No Lua shim or GI activation is added.\n"
                <<"Separate --owned-receipt-wait-seconds 1-30 requires owned interned descriptor observation, no CBV probe and recorded-draw.bin in that directory. After CPU receipt-ready publication it waits for actual child exit before normal shutdown; original overall deadline stays active. It does not decode/ACK receipts or prove engine/GPU behavior.\n"
                <<"Separate --outer-owned-channel and --outer-config-sha256 join an inherited outer-created disposable child. The host receives setup rights only; IPC relay, resume and shutdown remain in the independent outer runner. Requires all ownership options, forbids host receipt wait, and is unavailable for game targets. Review never opens the channel.\n"
                <<"Launching requires --launch-reviewed, both --expected-*-sha256 hashes and --acknowledge-native-insertion startup-observation-only. Deployment is not approved by this build.\n";return 0;}
        std::vector<std::wstring> arguments(argv+1,argv+argc);const auto options=parse(arguments);
        LockedFile exe(options.target),dll(options.dll);exe.pe(false);dll.pe(true);asciiDll(dll.path);
        if(options.entry)exe.nativeEntryRva();
        const auto targetHash=exe.sha256(),dllHash=dll.sha256();
        demand(options.targetHash.empty() || options.targetHash==targetHash,"target hash differs from reviewed binary");
        demand(options.dllHash.empty() || options.dllHash==dllHash,"bootstrap hash differs from reviewed binary");
        std::unique_ptr<LockedFile> vertexFile,pixelFile;std::vector<uint8_t> vertex,pixel;
        if(options.pipeline){vertexFile=std::make_unique<LockedFile>(options.vertex);pixelFile=std::make_unique<LockedFile>(options.pixel);
            demand(vertexFile->sha256()==options.vertexHash && pixelFile->sha256()==options.pixelHash,"shader bytecode differs from reviewed hashes");
            vertex=vertexFile->shaderBytes(1);pixel=pixelFile->shaderBytes(0);
            demand(GetFileAttributesW(options.rootOutput.c_str())==INVALID_FILE_ATTRIBUTES,"root output already exists; no overwrite allowed");
            demand(std::filesystem::is_directory(std::filesystem::path(options.rootOutput).parent_path()),"root output parent directory required");}
        if(options.bindings){demand(GetFileAttributesW(options.bindingOutput.c_str())==INVALID_FILE_ATTRIBUTES,"binding output already exists; no overwrite allowed");
            for(const wchar_t* suffix:{L".threads.bin",L".thread-samples.bin",L".resources.bin",L".resources-start.bin"}){
                const auto sidecar=options.bindingOutput+suffix;
                demand(_wcsicmp(sidecar.c_str(),options.rootOutput.c_str())!=0,"thread evidence aliases root output");
                demand(GetFileAttributesW(sidecar.c_str())==INVALID_FILE_ATTRIBUTES,"thread evidence output already exists; no overwrite allowed");}
            demand(std::filesystem::is_directory(std::filesystem::path(options.bindingOutput).parent_path()),"binding output parent directory required");}
        const auto requested=options.workdir.empty()?std::filesystem::path(exe.path).parent_path().wstring():options.workdir;
        Handle directory(CreateFileW(requested.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,
            OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr));win(directory.value!=INVALID_HANDLE_VALUE,"review working directory");
        BY_HANDLE_FILE_INFORMATION directoryInfo{};win(GetFileInformationByHandle(directory.value,&directoryInfo),"working-directory identity");
        demand((directoryInfo.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)!=0,"working directory is not a directory");const auto workdir=physicalPath(directory.value);
        std::wcout<<L"Mode: "<<(options.launch?L"explicit reviewed startup insertion":L"REVIEW ONLY - no process creation")
            <<L"\nTarget: "<<printable(exe.path)<<L"\nTarget SHA-256: "<<targetHash<<L"\nBootstrap: "<<printable(dll.path)<<L"\nBootstrap SHA-256: "<<dllHash
            <<L"\nWorking directory: "<<printable(workdir)<<L"\nCommand line (escaped display): "<<printable(commandLine(options,exe.path))
            <<L"\nBeamRT capture=OFF; BeamRT GPU work=NONE; lighting=UNCHANGED; no game-file installation.\n";
        std::wcout<<L"Opt-in native-entry rendezvous: "<<(options.entry?(options.imports?L"ON (separate import observer requested)":L"ON (passive)"):L"OFF")<<L'\n';
        std::wcout<<L"Separate imported-device observer: "<<(options.imports?L"ON (observation only)":L"OFF")<<L'\n';
        std::wcout<<L"Separate GI creation audit: "<<(options.pipeline?L"ON (creation only; no draw/lighting change)":L"OFF")<<L'\n';
        std::wcout<<L"Separate GI recording observer: "<<(options.bindings?L"ON (CPU recording only; no resource/GI activation)":L"OFF")<<L'\n';
        std::wcout<<L"Separate GI resource observer: "<<(options.resources?L"ON (CPU metadata; native GI OFF)":L"OFF")
            <<L"; admission="<<(options.resourceMode==beamrtResourceDescriptorTextures?L"descriptor textures only (CBV unavailable)":L"all observed allocations")
            <<L"; storage="<<(options.resourceProfile==beamrtResourceStorageInterned?L"interned (4096 logical locations / 256 payloads / 32 heap slots / 47104 bytes including 512-byte directory)":options.resourceProfile==beamrtResourceStorageCompact?L"compact (1024 locations / 256 payloads / 47104 bytes)":L"legacy (256 locations / 256 payloads / 47104 bytes)")
            <<L"; CBV diagnostic probe bytes="<<options.resourceProbeBytes<<L'\n';
        if(options.pipeline)std::wcout<<L"Reviewed VS SHA-256: "<<options.vertexHash<<L"\nReviewed PS SHA-256: "<<options.pixelHash<<L'\n';
        if(!options.launch)return 0;
        return launchReviewed(options,exe,dll,workdir,vertex,pixel);
    }catch(const std::exception& error){std::cerr<<"Startup host refused: "<<error.what()<<'\n';return 1;}
}
