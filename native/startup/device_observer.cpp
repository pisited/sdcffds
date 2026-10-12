#define BEAMRT_DEVICE_OBSERVER_BUILD
#include "device_observer.h"
#include <detours.h>
#include <wrl/client.h>
#include <memory>
#include <new>
using Microsoft::WRL::ComPtr;
struct ModuleLease {
    HMODULE value=nullptr;
    ~ModuleLease(){if(value)FreeLibrary(value);}
};
struct BeamRTDeviceObserver {
    ModuleLease runtime; // destroyed AFTER retained COM interfaces
    ComPtr<ID3D12Device> device;
    ComPtr<IUnknown> identity;
    BeamRTDeviceObservation info{};
};
// Only compile-time/POD globals. Nothing initializes graphics under loader lock.
static SRWLOCK metadataLock=SRWLOCK_INIT;
static BeamRTDeviceObserver* current=nullptr;
static PFN_D3D12_CREATE_DEVICE originalCreateDevice=nullptr;
static volatile LONG activeCallbacks=0;
static uint64_t nextGeneration=0;
struct Exclusive {
    Exclusive(){AcquireSRWLockExclusive(&metadataLock);}
    ~Exclusive(){ReleaseSRWLockExclusive(&metadataLock);}
};
struct Callback {
    Callback(){InterlockedIncrement(&activeCallbacks);}
    ~Callback(){InterlockedDecrement(&activeCallbacks);}
};
static void count(uint64_t& value,BeamRTDeviceObservation& info){if(value==UINT64_MAX)info.complete=0;else ++value;}
static HRESULT WINAPI observeCreateDevice(IUnknown* adapter,D3D_FEATURE_LEVEL minimum,REFIID iid,void** output) {
    Callback callback;
    const HRESULT result=originalCreateDevice(adapter,minimum,iid,output);
    // Resolve real returned interfaces before taking the metadata lock. Never
    // rewrite the host's output/HRESULT or invent a device for a capability probe.
    ComPtr<ID3D12Device> device;ComPtr<IUnknown> identity;LUID luid{};bool valid=true;
    if(SUCCEEDED(result) && output && *output){
        valid=SUCCEEDED(static_cast<IUnknown*>(*output)->QueryInterface(IID_PPV_ARGS(&device)))
            && SUCCEEDED(device.As(&identity)) && SUCCEEDED(device->GetDeviceRemovedReason());
        if(valid)luid=device->GetAdapterLuid();
    }
    {
        Exclusive lock;auto h=current;if(!h)return result;
        auto& info=h->info;count(info.calls,info);info.lastResult=result;info.lastCallerThread=GetCurrentThreadId();
        if(FAILED(result))count(info.failedCalls,info);
        else if(!output)count(info.probes,info);
        else if(*output)count(info.deviceResults,info);
        else valid=false;
        if(info.lastCallerThread!=info.ownerThread || !valid){info.complete=0;return result;}
        if(device){
            if(!h->device){h->device=std::move(device);h->identity=std::move(identity);info.adapterLuid=luid;info.requestedMinimum=minimum;}
            else if(h->identity.Get()!=identity.Get())info.complete=0; // ambiguous device, preserve native call
        }
    }
    return result;
}
static HRESULT transaction(bool attach) {
    LONG status=DetourTransactionBegin();if(status!=NO_ERROR)return HRESULT_FROM_WIN32(status);
    status=DetourUpdateThread(GetCurrentThread());
    if(status==NO_ERROR)status=attach?DetourAttach(reinterpret_cast<PVOID*>(&originalCreateDevice),reinterpret_cast<PVOID>(observeCreateDevice))
        :DetourDetach(reinterpret_cast<PVOID*>(&originalCreateDevice),reinterpret_cast<PVOID>(observeCreateDevice));
    if(status!=NO_ERROR){DetourTransactionAbort();return HRESULT_FROM_WIN32(status);}
    status=DetourTransactionCommit();return status==NO_ERROR?S_OK:HRESULT_FROM_WIN32(status);
}
extern "C" HRESULT WINAPI BeamRT_DeviceObserveStart(uint32_t quiet,BeamRTDeviceObserver** out) {
    if(!out || *out || quiet!=1)return E_INVALIDARG;
    std::unique_ptr<BeamRTDeviceObserver> pending(new(std::nothrow) BeamRTDeviceObserver());if(!pending)return E_OUTOFMEMORY;
    {
        Exclusive lock;
        if(current || InterlockedCompareExchange(&activeCallbacks,0,0)!=0)return HRESULT_FROM_WIN32(ERROR_BUSY);
        if(nextGeneration==UINT64_MAX)return E_UNEXPECTED;
        // Acquire a lifetime reference to an ALREADY loaded host module. This
        // does not load a graphics runtime, create a device or start any thread.
        if(!GetModuleHandleExW(0,L"d3d12.dll",&pending->runtime.value))return HRESULT_FROM_WIN32(GetLastError());
        const auto address=GetProcAddress(pending->runtime.value,"D3D12CreateDevice");if(!address)return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
        originalCreateDevice=reinterpret_cast<PFN_D3D12_CREATE_DEVICE>(address);
        pending->info.bytes=sizeof(pending->info);pending->info.abi=1;pending->info.hookAttached=1;pending->info.complete=1;
        pending->info.ownerThread=GetCurrentThreadId();pending->info.generation=++nextGeneration;
        current=pending.get();const HRESULT result=transaction(true);
        if(FAILED(result)){current=nullptr;originalCreateDevice=nullptr;return result;}
        *out=pending.release();return S_OK;
    }
}
extern "C" HRESULT WINAPI BeamRT_DeviceObserveQuery(BeamRTDeviceObserver* h,BeamRTDeviceObservation* out,uint32_t bytes) {
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};
    Exclusive lock;if(!h || h!=current)return E_HANDLE;*out=h->info;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_DeviceObserveAcquire(BeamRTDeviceObserver* h,uint64_t generation,ID3D12Device** out) {
    if(!out)return E_INVALIDARG;*out=nullptr;
    Exclusive lock;if(!h || h!=current)return E_HANDLE;
    if(!generation || generation!=h->info.generation)return E_INVALIDARG;
    if(!h->info.complete || !h->device)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    if(FAILED(h->device->GetDeviceRemovedReason())){h->info.complete=0;return DXGI_ERROR_DEVICE_REMOVED;}
    *out=h->device.Get();(*out)->AddRef();return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_DeviceObserveStop(BeamRTDeviceObserver** out,uint32_t quiet) {
    if(!out || quiet!=1)return E_INVALIDARG;BeamRTDeviceObserver* retired=nullptr;
    {
        Exclusive lock;if(!*out)return S_OK;auto h=*out;if(h!=current)return E_HANDLE;
        if(GetCurrentThreadId()!=h->info.ownerThread)return HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED);
        if(InterlockedCompareExchange(&activeCallbacks,0,0)!=0)return HRESULT_FROM_WIN32(ERROR_BUSY);
        const HRESULT result=transaction(false);if(FAILED(result))return result;
        current=nullptr;originalCreateDevice=nullptr;retired=h;*out=nullptr;
    }
    // Release runtime/device ownership only after detachment, outside the lock.
    delete retired;return S_OK;
}
