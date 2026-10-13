#include "fixture_contract.h"
#include <shellapi.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <filesystem>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <cstring>
using Microsoft::WRL::ComPtr;
using Query=HRESULT(WINAPI*)(BeamRTImportObservation*,uint32_t);
using Acquire=HRESULT(WINAPI*)(uint32_t,ID3D12Device**);
using Disable=HRESULT(WINAPI*)();
static bool same(IUnknown* a,IUnknown* b){ComPtr<IUnknown> x,y;return a && b && SUCCEEDED(a->QueryInterface(IID_PPV_ARGS(&x)))
    && SUCCEEDED(b->QueryInterface(IID_PPV_ARGS(&y))) && x.Get()==y.Get();}
struct BeforeMain {
    std::vector<std::wstring> args;
    ComPtr<IDXGIFactory6> factory;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<ID3D12Device> device;
    HMODULE module=nullptr;
    PFN_D3D12_CREATE_DEVICE direct=nullptr;
    uint8_t exportBytes[5]{};
    bool valid=false,warp=false;
    BeforeMain(){
        int count=0;auto values=CommandLineToArgvW(GetCommandLineW(),&count);if(!values)return;
        args.assign(values,values+count);LocalFree(values);
        if(args.size()<11 || args[1]!=L"--device-backend" || (args[2]!=L"hardware" && args[2]!=L"warp")
            || args[3]!=L"--report" || args[5]!=L"--module" || args[7]!=L"--hold-ms" || args[9]!=L"--exit-code")return;
        warp=args[2]==L"warp";module=GetModuleHandleW(args[6].c_str());if(!module)return;
        direct=reinterpret_cast<PFN_D3D12_CREATE_DEVICE>(GetProcAddress(GetModuleHandleW(L"d3d12.dll"),"D3D12CreateDevice"));
#ifdef BEAMRT_IMPORT_ORDINAL_FIXTURE
        // Refuse an unsupported test import library rather than forwarding an
        // invented signature. This constant never appears in production lookup.
        if(reinterpret_cast<FARPROC>(direct)!=GetProcAddress(GetModuleHandleW(L"d3d12.dll"),MAKEINTRESOURCEA(101)))return;
#endif
        if(!direct || FAILED(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory))))return;
        std::memcpy(exportBytes,reinterpret_cast<PVOID>(direct),sizeof(exportBytes));
        if(warp){if(FAILED(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter))))return;}
        else for(UINT i=0;!adapter;++i){ComPtr<IDXGIAdapter1> candidate;
            if(FAILED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&candidate))))return;
            DXGI_ADAPTER_DESC1 desc{};if(FAILED(candidate->GetDesc1(&desc)))return;
            if(!(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)
                && SUCCEEDED(D3D12CreateDevice(candidate.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)))candidate.As(&adapter);
        }
        // First actual imported device output before wWinMain; no fixture Start call.
        valid=SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));
    }
};
static BeforeMain fixture;
static bool writeNew(const std::wstring& path,const void* data,DWORD bytes){
    HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;DWORD written=0;const BOOL ok=WriteFile(file,data,bytes,&written,nullptr);CloseHandle(file);return ok && written==bytes;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,LPWSTR,int){
    auto& f=fixture;if(!f.valid)return 60;BeamRTImportFixtureReport report{};
    const auto query=reinterpret_cast<Query>(GetProcAddress(f.module,"BeamRT_ImportObserveQuery"));
    const auto acquire=reinterpret_cast<Acquire>(GetProcAddress(f.module,"BeamRT_ImportObserveAcquire"));
    const auto disable=reinterpret_cast<Disable>(GetProcAddress(f.module,"BeamRT_ImportObserveDisable"));
    if(!query || !acquire || !disable)return 61;
    BeamRTImportObservation initial{};ComPtr<ID3D12Device> observed;
    if(FAILED(query(&initial,sizeof(initial))) || !initial.complete || !initial.candidateReady || !initial.hookAttached
        || !initial.protectionRestored || initial.deviceResults!=1 || FAILED(acquire(GetCurrentProcessId(),&observed)) || !same(observed.Get(),f.device.Get()))return 62;
    report.testsMask|=1;
    D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=256;desc.Height=1;desc.DepthOrArraySize=1;
    desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_UPLOAD;ComPtr<ID3D12Resource> resource;ComPtr<ID3D12Device> owner;
    if(FAILED(f.device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&resource)))
        || FAILED(resource->GetDevice(IID_PPV_ARGS(&owner))) || !same(owner.Get(),observed.Get()))return 63;
    report.testsMask|=2;
    ID3D12Device* rejected=reinterpret_cast<ID3D12Device*>(1);
    if(SUCCEEDED(acquire(GetCurrentProcessId()+1,&rejected)) || rejected)return 64;++report.guardsRejected;
    if(SUCCEEDED(query(&initial,sizeof(initial)-1)) || SUCCEEDED(acquire(GetCurrentProcessId(),nullptr)))return 64;report.guardsRejected+=2;
    report.testsMask|=4;
    const GUID unsupported={0xdecafe12,0x371c,0x4179,{1,2,3,4,5,6,7,8}};void* directOut=nullptr;void* hookedOut=nullptr;
    const HRESULT directFailure=f.direct(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,unsupported,&directOut);
    const HRESULT hookedFailure=D3D12CreateDevice(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,unsupported,&hookedOut);
    if(SUCCEEDED(directFailure) || directFailure!=hookedFailure || directOut || hookedOut)return 65;
    const HRESULT directProbe=f.direct(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr);
    const HRESULT hookedProbe=D3D12CreateDevice(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr);
    SetLastError(0x4242);f.direct(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr);const DWORD directError=GetLastError();
    SetLastError(0x4242);D3D12CreateDevice(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr);const DWORD importedError=GetLastError();
    if(directProbe!=hookedProbe || FAILED(hookedProbe) || directError!=importedError)return 65;report.testsMask|=8;
    HRESULT wrongStop=S_OK;std::atomic<bool> good{true};
    std::thread caller([&]{wrongStop=disable();for(int i=0;i<32;++i)
        if(D3D12CreateDevice(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)!=directProbe)good=false;});caller.join();
    if(wrongStop!=HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) || !good || FAILED(query(&initial,sizeof(initial))) || !initial.complete)return 66;
    ++report.guardsRejected;report.testsMask|=16;
    const auto base=reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));const auto slot=reinterpret_cast<PVOID*>(base+initial.slotRva);
    const auto cached=reinterpret_cast<PFN_D3D12_CREATE_DEVICE>(*slot);
    if(!cached || cached==f.direct || std::memcmp(f.exportBytes,reinterpret_cast<PVOID>(f.direct),sizeof(f.exportBytes)))return 67;
    report.testsMask|=32;
    ComPtr<IDXGIAdapter> other;ComPtr<ID3D12Device> foreign;
    if(!f.warp){if(FAILED(f.factory->EnumWarpAdapter(IID_PPV_ARGS(&other))))return 68;}
    else for(UINT i=0;!other;++i){ComPtr<IDXGIAdapter1> candidate;
        if(FAILED(f.factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&candidate))))return 68;
        DXGI_ADAPTER_DESC1 description{};if(FAILED(candidate->GetDesc1(&description)))return 68;
        if(!(description.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) && SUCCEEDED(f.direct(candidate.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)))candidate.As(&other);
    }
    if(FAILED(D3D12CreateDevice(other.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&foreign))) || same(foreign.Get(),f.device.Get())
        || FAILED(query(&initial,sizeof(initial))) || initial.complete || !initial.ambiguous)return 68;
    rejected=reinterpret_cast<ID3D12Device*>(1);if(SUCCEEDED(acquire(GetCurrentProcessId(),&rejected)) || rejected)return 68;
    ++report.guardsRejected;report.testsMask|=64;
    // Another owner replaced our slot. Disable must not overwrite it. Restore
    // the saved slot only inside this owned fixture, then exercise normal OFF.
    DWORD old=0,ignored=0;if(!VirtualProtect(slot,sizeof(PVOID),PAGE_READWRITE,&old))return 74;
    const auto prior=InterlockedCompareExchangePointer(slot,reinterpret_cast<PVOID>(f.direct),reinterpret_cast<PVOID>(cached));
    if(!VirtualProtect(slot,sizeof(PVOID),old,&ignored) || prior!=reinterpret_cast<PVOID>(cached))return 74;
    const HRESULT conflict=disable();
    if(conflict!=HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS) || *slot!=reinterpret_cast<PVOID>(f.direct))return 74;
    if(!VirtualProtect(slot,sizeof(PVOID),PAGE_READWRITE,&old))return 74;
    const auto restored=InterlockedCompareExchangePointer(slot,reinterpret_cast<PVOID>(cached),reinterpret_cast<PVOID>(f.direct));
    if(!VirtualProtect(slot,sizeof(PVOID),old,&ignored) || restored!=reinterpret_cast<PVOID>(f.direct))return 74;
    ++report.guardsRejected;report.testsMask|=1024;
    // A real concurrent caller continues through the pointer swap. No resource
    // retirement or thread suspension is inferred from callback counters.
    std::atomic<bool> running{true},entered{false};
    std::thread concurrent([&]{do {
        if(D3D12CreateDevice(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)!=directProbe)good=false;
        entered=true;
    }while(running.load());});
    while(!entered.load())SwitchToThread();query(&report.beforeDisable,sizeof(report.beforeDisable));
    const HRESULT stopped=disable();running=false;concurrent.join();
    if(FAILED(stopped) || !good || FAILED(query(&report.afterDisable,sizeof(report.afterDisable)))
        || report.afterDisable.hookAttached || !report.afterDisable.slotRestored || !report.afterDisable.disabled || !report.afterDisable.protectionRestored
        || *slot!=reinterpret_cast<PVOID>(f.direct))return 69;report.testsMask|=128;
    // Execute a prefetched OLD callback after disable; it must remain safe and
    // forward, without changing observation counters or republishing a device.
    if(cached(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)!=directProbe
        || D3D12CreateDevice(f.adapter.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)!=directProbe
        || FAILED(query(&initial,sizeof(initial))) || initial.calls!=report.afterDisable.calls || FAILED(disable()))return 70;
    rejected=reinterpret_cast<ID3D12Device*>(1);if(SUCCEEDED(acquire(GetCurrentProcessId(),&rejected)) || rejected)return 70;
    ++report.guardsRejected;report.testsMask|=256;
    if(std::memcmp(f.exportBytes,reinterpret_cast<PVOID>(f.direct),sizeof(f.exportBytes)) || !same(owner.Get(),observed.Get()))return 71;report.testsMask|=512;
    auto& startup=report.startup;startup.bytes=sizeof(startup);startup.magic=beamrtStartupFixtureMagic;startup.processId=GetCurrentProcessId();
    using StartupQuery=BOOL(WINAPI*)(BeamRTStartupStatus*,DWORD);const auto status=reinterpret_cast<StartupQuery>(GetProcAddress(f.module,"BeamRT_StartupQuery"));
    startup.queryOK=status && status(&startup.status,sizeof(startup.status));startup.initialThread=startup.status.attachThread==GetCurrentThreadId();
    const auto path=f.args[4];startup.cwdMatches=std::filesystem::current_path()==std::filesystem::path(path).parent_path();
    const std::vector<std::wstring> expected={L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"};
    bool match=f.args.size()==12+expected.size() && f.args[11]==L"--";
    for(size_t i=0;match && i<expected.size();++i)match=f.args[12+i]==expected[i];startup.argsMatch=match?1u:0u;
    report.warp=f.warp?1u:0u;if(!writeNew(path,&report,sizeof(report)))return 72;
    const int hold=_wtoi(f.args[8].c_str());if(hold>0 && hold<=20000)Sleep(static_cast<DWORD>(hold));
    const DWORD code=0;if(!writeNew(path+L".done",&code,sizeof(code)))return 73;return 0;
}
