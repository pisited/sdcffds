#define BEAMRT_ENTRY_BUILD
#define BEAMRT_DEVICE_OBSERVER_BUILD
#include "entry_contract.h"
#include "import_observer.h"
#include <detours.h>
#include <cstring>
extern "C" { PVOID beamrtOriginalEntry=nullptr;void BeamRT_EntryThunk(); }
static SRWLOCK entryLock=SRWLOCK_INIT;
static BeamRTEntryStatus info{};
static HANDLE receipt=nullptr;
static HANDLE statusMapping=nullptr;
static PVOID originalAddress=nullptr;
static uint8_t originalBytes[5]{};
static BeamRTDeviceObserver* fixtureDevice=nullptr;
static void closeEntryHandles(){if(receipt)CloseHandle(receipt);if(statusMapping)CloseHandle(statusMapping);receipt=statusMapping=nullptr;}
#ifdef BEAMRT_ENTRY_TEST_FRAME
static BeamRTEntryTestFrame savedFrame{};
#endif
struct EntryLock {
    EntryLock(){AcquireSRWLockExclusive(&entryLock);}
    ~EntryLock(){ReleaseSRWLockExclusive(&entryLock);}
};
static HRESULT entryTransaction(bool arm) {
    LONG result=DetourTransactionBegin();if(result!=NO_ERROR)return HRESULT_FROM_WIN32(result);
    result=DetourUpdateThread(GetCurrentThread());
    if(result==NO_ERROR)result=arm?DetourAttach(&beamrtOriginalEntry,reinterpret_cast<PVOID>(BeamRT_EntryThunk))
        :DetourDetach(&beamrtOriginalEntry,reinterpret_cast<PVOID>(BeamRT_EntryThunk));
    if(result!=NO_ERROR){DetourTransactionAbort();return HRESULT_FROM_WIN32(result);}
    result=DetourTransactionCommit();return result==NO_ERROR?S_OK:HRESULT_FROM_WIN32(result);
}
HRESULT BeamRT_EntryArmFromPayload() {
    DWORD bytes=0;const auto p=static_cast<const BeamRTEntryPayload*>(DetourFindPayloadEx(beamrtEntryGuid,&bytes));
    if(!p)return S_FALSE;EntryLock lock;
    info.bytes=sizeof(info);info.abi=1;info.ownerThread=GetCurrentThreadId();info.result=E_INVALIDARG;info.deviceResult=E_NOTIMPL;
    if(!beamrtEntryPayloadValid(p,bytes,GetCurrentProcessId(),GetCurrentThreadId()))return info.result;
    receipt=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->receiptEvent));
    statusMapping=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->statusMapping));
    const auto exe=GetModuleHandleW(nullptr);const auto base=reinterpret_cast<const uint8_t*>(exe);
    const auto dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
    // Known mapped main-image headers, not private engine offsets. CLR routes
    // are rejected before DetourGetEntryPoint can resolve their runtime stub.
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE || nt->Signature!=IMAGE_NT_SIGNATURE
        || nt->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64 || nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC
        || nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].VirtualAddress
        || nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].Size
        || nt->OptionalHeader.AddressOfEntryPoint!=p->expectedEntryRva
        || uint64_t(p->expectedEntryRva)+5>nt->OptionalHeader.SizeOfImage){closeEntryHandles();return info.result;}
    originalAddress=DetourGetEntryPoint(exe);
    if(!originalAddress || originalAddress!=base+p->expectedEntryRva || DetourGetContainingModule(originalAddress)!=exe){
        closeEntryHandles();return info.result;
    }
    MEMORY_BASIC_INFORMATION memory{};
    const auto address=reinterpret_cast<ULONG_PTR>(originalAddress);
    if(!VirtualQuery(originalAddress,&memory,sizeof(memory)) || memory.AllocationBase!=exe || memory.State!=MEM_COMMIT
        || memory.Type!=MEM_IMAGE || (memory.Protect&(PAGE_GUARD|PAGE_NOACCESS))
        || !(memory.Protect&(PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))
        || address-reinterpret_cast<ULONG_PTR>(memory.BaseAddress)+5>memory.RegionSize){
        closeEntryHandles();return info.result;
    }
    std::memcpy(originalBytes,originalAddress,sizeof(originalBytes));beamrtOriginalEntry=originalAddress;
    info.result=entryTransaction(true);
    if(FAILED(info.result)){closeEntryHandles();return info.result;}
    info.armed=info.hookAttached=1;return S_OK;
}
extern "C" void BeamRT_EntryInitialize(const void* raw) noexcept {
    EntryLock lock;if(info.reached)return;info.reached=1;
#ifdef BEAMRT_ENTRY_TEST_FRAME
    const auto frame=static_cast<const uint8_t*>(raw);
    std::memcpy(savedFrame.registers,frame+0x20,sizeof(savedFrame.registers));
    std::memcpy(&savedFrame.flags,frame+0xc0,sizeof(savedFrame.flags));std::memcpy(savedFrame.xmm,frame+0x60,sizeof(savedFrame.xmm));
#else
    (void)raw;
#endif
    if(GetCurrentThreadId()!=info.ownerThread)info.result=HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED);
    else {
        // One-shot hook removed while execution is in this DLL's thunk, not the
        // trampoline. Failure preserves the trampoline; imports keep DLL alive.
        info.result=entryTransaction(false);
        if(SUCCEEDED(info.result)){
            info.hookAttached=0;info.entryBytesRestored=std::memcmp(originalAddress,originalBytes,sizeof(originalBytes))==0?1u:0u;
        }
        // Separate runtime payload opt-in. Import-slot observation has its own
        // receipt; never asserts graphics-caller quiescence or activates GI.
        if(SUCCEEDED(info.result) && info.entryBytesRestored)BeamRT_ImportStartFromPayload();
#ifdef BEAMRT_ENTRY_FIXTURE_AUTOSTART
        // This trusted lifecycle assertion is ONLY for the owned fixture. An
        // EXE entry point alone does not certify arbitrary game-thread quiescence.
        wchar_t path[32768]{};const DWORD count=GetModuleFileNameW(nullptr,path,32768);
        const wchar_t* name=path;for(DWORD i=0;i<count;++i)if(path[i]==L'\\' || path[i]==L'/')name=path+i+1;
        if(SUCCEEDED(info.result) && count && count<32768 && lstrcmpW(name,L"beamrt_entry_fixture.exe")==0){
#ifdef BEAMRT_ENTRY_FIXTURE_INIT_FAIL
            info.deviceResult=E_FAIL;
#else
            info.deviceResult=BeamRT_DeviceObserveStart(1,&fixtureDevice);info.deviceStarted=SUCCEEDED(info.deviceResult)?1u:0u;
#endif
        }else info.deviceResult=E_ACCESSDENIED;
#endif
    }
    info.released=1;
    // One-time typed CPU startup status, not rendering memory or a GPU fence.
    // Mapping is deliberately outside DllMain/loader-lock arming.
    if(statusMapping){
        auto shared=static_cast<BeamRTEntryStatus*>(MapViewOfFile(statusMapping,FILE_MAP_WRITE,0,0,sizeof(info)));
        if(shared){*shared=info;UnmapViewOfFile(shared);}
    }
    if(receipt)SetEvent(receipt);closeEntryHandles();
}
extern "C" HRESULT WINAPI BeamRT_EntryQuery(BeamRTEntryStatus* out,uint32_t bytes) {
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;EntryLock lock;*out=info;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_EntryGetDeviceObserver(BeamRTDeviceObserver** out) {
    if(!out)return E_INVALIDARG;*out=nullptr;EntryLock lock;
    if(!info.released || !fixtureDevice)return HRESULT_FROM_WIN32(ERROR_NOT_READY);*out=fixtureDevice;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_EntryStopDeviceObserver(uint32_t quiet) {
    EntryLock lock;if(!fixtureDevice)return S_FALSE;const HRESULT result=BeamRT_DeviceObserveStop(&fixtureDevice,quiet);
    if(SUCCEEDED(result))info.deviceStopped=1;return result;
}
#ifdef BEAMRT_ENTRY_TEST_FRAME
extern "C" __declspec(dllexport) HRESULT WINAPI BeamRT_EntryTestQueryFrame(BeamRTEntryTestFrame* out,uint32_t bytes) {
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};EntryLock lock;
    if(!info.reached)return HRESULT_FROM_WIN32(ERROR_NOT_READY);*out=savedFrame;return S_OK;
}
#endif
