#define BEAMRT_IMPORT_OBSERVER_BUILD
#include "import_observer.h"
#include <detours.h>
#include <wrl/client.h>
#include <new>
#include <intrin.h>
#include "pipeline_handoff.h"
using Microsoft::WRL::ComPtr;
struct ImportContext {
    HMODULE runtime=nullptr;
    PFN_D3D12_CREATE_DEVICE original=nullptr;
    PVOID* slot=nullptr;
    HANDLE receipt=nullptr,mapping=nullptr;
    ComPtr<ID3D12Device> device;
    ComPtr<IUnknown> identity;
    BeamRTImportObservation info{};
};
// Process-lifetime publication: never delete a published context or invalidate
// its original function, including after disable. An already-fetched callback
// can still execute after the atomic IAT restoration. No counter-based retirement.
static PVOID volatile currentImport=nullptr;
static SRWLOCK importLock=SRWLOCK_INIT;
struct ImportLock {ImportLock(){AcquireSRWLockExclusive(&importLock);}~ImportLock(){ReleaseSRWLockExclusive(&importLock);}};
struct LastErrorRestore {DWORD value;~LastErrorRestore(){SetLastError(value);}};
static ImportContext* context(){return static_cast<ImportContext*>(InterlockedCompareExchangePointer(&currentImport,nullptr,nullptr));}
static void closeReceipt(ImportContext& c) {
    if(c.receipt)CloseHandle(c.receipt);if(c.mapping)CloseHandle(c.mapping);c.receipt=c.mapping=nullptr;
}
static void publishOnce(ImportContext& c) {
    if(!c.receipt)return;
    // Immutable first-candidate/failure receipt, not live metadata or a fence.
    auto view=static_cast<BeamRTImportObservation*>(MapViewOfFile(c.mapping,FILE_MAP_WRITE,0,0,sizeof(c.info)));
    if(view){*view=c.info;UnmapViewOfFile(view);SetEvent(c.receipt);}closeReceipt(c);
}
static void count(uint64_t& n,BeamRTImportObservation& info){if(n==UINT64_MAX)info.complete=0;else ++n;}
static HRESULT WINAPI observeImport(IUnknown* adapter,D3D_FEATURE_LEVEL minimum,REFIID iid,void** output) {
    // currentImport is immutable once exposed to callers; Start publishes it
    // before the IAT exchange. Original pointer/module are never retired.
    auto c=context();const HRESULT result=c->original(adapter,minimum,iid,output);
    LastErrorRestore error{GetLastError()};
    ComPtr<ID3D12Device> device;ComPtr<IUnknown> identity;bool valid=true;
    if(SUCCEEDED(result) && output && *output){
        valid=SUCCEEDED(static_cast<IUnknown*>(*output)->QueryInterface(IID_PPV_ARGS(&device)))
            && SUCCEEDED(device.As(&identity)) && SUCCEEDED(device->GetDeviceRemovedReason());
    }
    ComPtr<ID3D12Device> firstCandidate;
    {
        ImportLock lock;auto& info=c->info;if(info.disabled)return result;
        count(info.calls,info);info.lastResult=result;info.lastCallerThread=GetCurrentThreadId();
        if(FAILED(result))count(info.failedCalls,info);
        else if(!output)count(info.probes,info);
        else if(*output)count(info.deviceResults,info);
        else valid=false;
        if(!valid)info.complete=0;
        if(device && valid){
            if(!c->device){firstCandidate=device;info.adapterLuid=device->GetAdapterLuid();info.requestedMinimum=minimum;
                c->device=std::move(device);c->identity=std::move(identity);info.candidateReady=1;}
            else if(c->identity.Get()!=identity.Get()){info.ambiguous=1;info.complete=0;}
        }
        if(info.candidateReady || !info.complete)publishOnce(*c);
    }
    // Do not hold the import lock while installing/querying another observer.
    // First-candidate handoff is explicit payload-gated and submits no work.
    if(firstCandidate)BeamRT_PipelineStartFromPayload(firstCandidate.Get(),_ReturnAddress());
    return result;
}
struct Search {
    HMODULE runtime;PVOID expected;bool inRuntime=false;PVOID* slot=nullptr;uint32_t matches=0;bool conflict=false;
};
static BOOL CALLBACK importFile(PVOID data,HMODULE module,LPCSTR name) {
    auto& search=*static_cast<Search*>(data);
    search.inRuntime=name && _stricmp(name,"d3d12.dll")==0 && module==search.runtime;return TRUE;
}
static BOOL CALLBACK importFunction(PVOID data,DWORD ordinal,LPCSTR name,PVOID* slot) {
    auto& search=*static_cast<Search*>(data);if(!search.inRuntime || !slot)return TRUE;
    // Resolve ordinal imports against the loaded public export by NAME. No
    // numeric ordinal or engine offset is guessed, including BeamNG's import.
    const auto declared=name?GetProcAddress(search.runtime,name):GetProcAddress(search.runtime,MAKEINTRESOURCEA(ordinal));
    if(reinterpret_cast<PVOID>(declared)!=search.expected)return TRUE;
    ++search.matches;search.slot=slot;if(*slot!=search.expected)search.conflict=true;return TRUE;
}
static HRESULT exchangeSlot(ImportContext& c,PVOID expected,PVOID replacement,bool& changed) {
    changed=false;MEMORY_BASIC_INFORMATION memory{};
    if(!VirtualQuery(c.slot,&memory,sizeof(memory)) || memory.AllocationBase!=GetModuleHandleW(nullptr)
        || memory.State!=MEM_COMMIT || memory.Type!=MEM_IMAGE
        || (memory.Protect!=PAGE_READONLY && memory.Protect!=PAGE_READWRITE && memory.Protect!=PAGE_WRITECOPY))return E_ACCESSDENIED;
    DWORD old=0;if(!VirtualProtect(c.slot,sizeof(PVOID),PAGE_READWRITE,&old))return HRESULT_FROM_WIN32(GetLastError());
    changed=InterlockedCompareExchangePointer(c.slot,replacement,expected)==expected;
    DWORD ignored=0;const BOOL restored=VirtualProtect(c.slot,sizeof(PVOID),old,&ignored);
    c.info.protectionRestored=restored?1u:0u;
    if(!restored)return HRESULT_FROM_WIN32(GetLastError());
    return changed?S_OK:HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
}
HRESULT BeamRT_ImportStartFromPayload() {
    DWORD bytes=0;const auto p=static_cast<const BeamRTImportPayload*>(DetourFindPayloadEx(beamrtImportGuid,&bytes));
    if(!p)return S_FALSE;
    if(!beamrtImportPayloadValid(p,bytes,GetCurrentProcessId(),GetCurrentThreadId()))return E_INVALIDARG;
    ImportLock lock;if(context())return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
    auto c=new(std::nothrow) ImportContext();if(!c)return E_OUTOFMEMORY;
    c->receipt=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->receiptEvent));
    c->mapping=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->statusMapping));
    auto& info=c->info;info.bytes=sizeof(info);info.abi=1;info.processId=GetCurrentProcessId();info.ownerThread=GetCurrentThreadId();
    info.installResult=HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    if(GetModuleHandleExW(0,L"d3d12.dll",&c->runtime)){
        c->original=reinterpret_cast<PFN_D3D12_CREATE_DEVICE>(GetProcAddress(c->runtime,"D3D12CreateDevice"));
        if(c->original){
            Search search{c->runtime,reinterpret_cast<PVOID>(c->original)};
            if(DetourEnumerateImportsEx(GetModuleHandleW(nullptr),&search,importFile,importFunction)
                && search.matches==1 && !search.conflict && search.slot
                && reinterpret_cast<ULONG_PTR>(search.slot)%alignof(PVOID)==0){
                const auto base=reinterpret_cast<const uint8_t*>(GetModuleHandleW(nullptr));
                const auto dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
                const auto nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
                const auto rva=reinterpret_cast<const uint8_t*>(search.slot)-base;
                if(rva>=0 && uint64_t(rva)+sizeof(PVOID)<=nt->OptionalHeader.SizeOfImage){
                    c->slot=search.slot;info.slotRva=static_cast<uint32_t>(rva);info.complete=1;
                    // Publication precedes exposure. No device function or
                    // trampoline code is patched; no thread is suspended.
                    InterlockedExchangePointer(&currentImport,c);
                    bool changed=false;info.installResult=exchangeSlot(*c,reinterpret_cast<PVOID>(c->original),reinterpret_cast<PVOID>(observeImport),changed);
                    info.hookAttached=changed?1u:0u;
                }
            }
        }
    }
    if(FAILED(info.installResult)){
        info.complete=0;publishOnce(*c);
        const HRESULT result=info.installResult;
        if(context()!=c){if(c->runtime)FreeLibrary(c->runtime);delete c;}
        return result;
    }
    return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ImportObserveQuery(BeamRTImportObservation* out,uint32_t bytes) {
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};ImportLock lock;auto c=context();
    if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);*out=c->info;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ImportObserveAcquire(uint32_t pid,ID3D12Device** out) {
    if(!out)return E_INVALIDARG;*out=nullptr;ImportLock lock;auto c=context();
    if(!c || !pid || pid!=GetCurrentProcessId())return E_INVALIDARG;
    if(!c->info.complete || c->info.disabled || !c->info.hookAttached || !c->device)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    if(FAILED(c->device->GetDeviceRemovedReason())){c->info.complete=0;return DXGI_ERROR_DEVICE_REMOVED;}
    *out=c->device.Get();(*out)->AddRef();return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ImportObserveDisable() {
    ImportLock lock;auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    if(GetCurrentThreadId()!=c->info.ownerThread)return HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED);
    if(c->info.disabled)return S_OK;
    bool changed=false;const HRESULT result=exchangeSlot(*c,reinterpret_cast<PVOID>(observeImport),reinterpret_cast<PVOID>(c->original),changed);
    if(changed){c->info.hookAttached=0;c->info.slotRestored=1;c->info.disabled=1;}
    if(FAILED(result))c->info.complete=0;
    // Keep all context and leases; late/prefetched callbacks still forward.
    return result;
}
