#include "fixture_contract.h"
#include <dxgi1_6.h>
#include <shellapi.h>
#include <wrl/client.h>
#include <filesystem>
#include <string>
#include <vector>
#include <thread>
#include <cstring>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
static bool writeNew(const std::wstring& path,const void* data,DWORD bytes) {
    HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;DWORD written=0;
    const BOOL ok=WriteFile(file,data,bytes,&written,nullptr);CloseHandle(file);return ok && written==bytes;
}
static bool same(IUnknown* a,IUnknown* b) {
    if(!a || !b)return false;ComPtr<IUnknown> x,y;
    return SUCCEEDED(a->QueryInterface(IID_PPV_ARGS(&x))) && SUCCEEDED(b->QueryInterface(IID_PPV_ARGS(&y))) && x.Get()==y.Get();
}
using Start=HRESULT(WINAPI*)(uint32_t,BeamRTDeviceObserver**);
using Query=HRESULT(WINAPI*)(BeamRTDeviceObserver*,BeamRTDeviceObservation*,uint32_t);
using Acquire=HRESULT(WINAPI*)(BeamRTDeviceObserver*,uint64_t,ID3D12Device**);
using Stop=HRESULT(WINAPI*)(BeamRTDeviceObserver**,uint32_t);
struct ObserverOwner {
    BeamRTDeviceObserver* value=nullptr;Stop stop=nullptr;
    ~ObserverOwner(){if(value && stop)stop(&value,1);}
};
static void testDevice(HMODULE bootstrap,bool warp,BeamRTDeviceFixtureReport& report) {
    uint32_t step=0;
    auto verify=[&](bool ok){report.errorStep=++step;if(!ok)throw std::runtime_error("device fixture contract failed");};
    auto refused=[&](bool ok){verify(ok);++report.guardsRejected;};
    const auto start=reinterpret_cast<Start>(GetProcAddress(bootstrap,"BeamRT_DeviceObserveStart"));
    const auto query=reinterpret_cast<Query>(GetProcAddress(bootstrap,"BeamRT_DeviceObserveQuery"));
    const auto acquire=reinterpret_cast<Acquire>(GetProcAddress(bootstrap,"BeamRT_DeviceObserveAcquire"));
    const auto stop=reinterpret_cast<Stop>(GetProcAddress(bootstrap,"BeamRT_DeviceObserveStop"));verify(start && query && acquire && stop);
    ComPtr<IDXGIFactory6> factory;verify(SUCCEEDED(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory))));
    ComPtr<IDXGIAdapter> hardware,software;
    verify(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&software))));
    for(UINT i=0;!hardware;++i){ComPtr<IDXGIAdapter1> candidate;
        verify(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&candidate))));
        DXGI_ADAPTER_DESC1 description{};verify(SUCCEEDED(candidate->GetDesc1(&description)));
        if(!(description.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)
            && SUCCEEDED(D3D12CreateDevice(candidate.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)))verify(SUCCEEDED(candidate.As(&hardware)));
    }
    auto adapter=warp?software.Get():hardware.Get();auto other=warp?hardware.Get():software.Get();
    const GUID unknown={0x91dd2e7b,0x55bc,0x4d84,{0xa1,0x21,0xd3,0x7b,0xfe,0x1c,0x04,0x6f}};
    void* unsupported=nullptr;
    const HRESULT baselineFailure=D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,unknown,&unsupported);
    const HRESULT baselineProbe=D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr);
    verify(FAILED(baselineFailure) && !unsupported && baselineProbe==S_FALSE);
    const auto exportAddress=GetProcAddress(GetModuleHandleW(L"d3d12.dll"),"D3D12CreateDevice");verify(exportAddress!=nullptr);
    uint8_t before[5]{};std::memcpy(before,reinterpret_cast<const void*>(exportAddress),sizeof(before));
    ObserverOwner observer;observer.stop=stop;
    refused(FAILED(start(0,&observer.value)) && !observer.value);verify(SUCCEEDED(start(1,&observer.value)) && observer.value);
    verify(std::memcmp(before,reinterpret_cast<const void*>(exportAddress),sizeof(before))!=0);
    BeamRTDeviceObservation info{};verify(SUCCEEDED(query(observer.value,&info,sizeof(info))) && info.hookAttached && info.complete
        && info.ownerThread==GetCurrentThreadId() && info.generation>0 && !info.calls);
    ID3D12Device* empty=nullptr;refused(FAILED(acquire(observer.value,info.generation,&empty)) && !empty);
    report.testsMask|=1;
    ComPtr<ID3D12Device> created;const HRESULT createdResult=D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&created));
    verify(SUCCEEDED(createdResult) && created);verify(SUCCEEDED(query(observer.value,&info,sizeof(info))));
    ComPtr<ID3D12Device> observed;verify(SUCCEEDED(acquire(observer.value,info.generation,&observed)) && same(created.Get(),observed.Get()));
    const auto luid=created->GetAdapterLuid();verify(info.adapterLuid.LowPart==luid.LowPart && info.adapterLuid.HighPart==luid.HighPart
        && info.requestedMinimum==D3D_FEATURE_LEVEL_11_0 && info.calls==1 && info.deviceResults==1 && info.lastResult==createdResult);
    report.testsMask|=2;
    const HRESULT probe=D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr);verify(probe==baselineProbe);
    unsupported=nullptr;const HRESULT failed=D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,unknown,&unsupported);
    verify(failed==baselineFailure && !unsupported);verify(SUCCEEDED(query(observer.value,&info,sizeof(info))) && info.calls==3
        && info.probes==1 && info.failedCalls==1 && info.deviceResults==1 && info.lastResult==failed && info.complete);
    report.testsMask|=4;
    ComPtr<IUnknown> alias;verify(SUCCEEDED(D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&alias))) && same(created.Get(),alias.Get()));
    verify(SUCCEEDED(query(observer.value,&info,sizeof(info))) && info.deviceResults==2 && info.complete);report.observation=info;report.testsMask|=8;
    D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=256;desc.Height=1;desc.DepthOrArraySize=1;
    desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_UPLOAD;ComPtr<ID3D12Resource> resource;
    verify(SUCCEEDED(created->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&resource))));
    ComPtr<ID3D12Device> resourceOwner;verify(SUCCEEDED(resource->GetDevice(IID_PPV_ARGS(&resourceOwner))) && same(observed.Get(),resourceOwner.Get()));
    created.Reset();alias.Reset();resourceOwner.Reset();verify(SUCCEEDED(observed->GetDeviceRemovedReason()));report.testsMask|=16;
    BeamRTDeviceObserver* duplicate=nullptr;refused(FAILED(start(1,&duplicate)) && !duplicate);
    empty=observed.Get();refused(FAILED(acquire(observer.value,info.generation+1,&empty)) && !empty);
    refused(FAILED(stop(&observer.value,0)) && observer.value);
    HRESULT wrongStop=S_OK;bool retained=false;
    std::thread badControl([&]{auto copy=observer.value;wrongStop=stop(&copy,1);retained=copy==observer.value;});badControl.join();
    refused(wrongStop==HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) && retained);report.testsMask|=32;
    HRESULT threaded=S_OK;
    std::thread otherCaller([&]{threaded=D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr);});otherCaller.join();
    verify(threaded==baselineProbe && SUCCEEDED(query(observer.value,&info,sizeof(info))) && !info.complete);
    empty=observed.Get();refused(FAILED(acquire(observer.value,info.generation,&empty)) && !empty);report.testsMask|=64;
    const auto oldGeneration=info.generation;auto stale=observer.value;verify(SUCCEEDED(stop(&observer.value,1)) && !observer.value);
    verify(std::memcmp(before,reinterpret_cast<const void*>(exportAddress),sizeof(before))==0);
    empty=observed.Get();refused(FAILED(acquire(stale,oldGeneration,&empty)) && !empty);
    verify(D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)==baselineProbe);
    verify(SUCCEEDED(resource->GetDevice(IID_PPV_ARGS(&resourceOwner))) && same(observed.Get(),resourceOwner.Get()));report.testsMask|=256;
    verify(SUCCEEDED(start(1,&observer.value)));verify(SUCCEEDED(query(observer.value,&info,sizeof(info))) && info.generation>oldGeneration && !info.calls);
    empty=observed.Get();refused(FAILED(acquire(observer.value,oldGeneration,&empty)) && !empty);
    ComPtr<ID3D12Device> first,foreign;verify(SUCCEEDED(D3D12CreateDevice(adapter,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&first))));
    verify(SUCCEEDED(D3D12CreateDevice(other,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&foreign))) && !same(first.Get(),foreign.Get()));
    verify(SUCCEEDED(query(observer.value,&info,sizeof(info))) && !info.complete && info.deviceResults==2);
    empty=observed.Get();refused(FAILED(acquire(observer.value,info.generation,&empty)) && !empty);verify(SUCCEEDED(stop(&observer.value,1)) && !observer.value);
    verify(std::memcmp(before,reinterpret_cast<const void*>(exportAddress),sizeof(before))==0);report.testsMask|=128;
    report.errorStep=0;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,LPWSTR,int) {
    int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(!argv)return 40;
    std::vector<std::wstring> args(argv,argv+argc);LocalFree(argv);const size_t base=3;
    if(args.size()<base+8 || args[1]!=L"--device-backend" || (args[2]!=L"warp" && args[2]!=L"hardware")
        || args[base]!=L"--report" || args[base+2]!=L"--module" || args[base+4]!=L"--hold-ms" || args[base+6]!=L"--exit-code")return 41;
    const auto path=args[base+1];const int hold=_wtoi(args[base+5].c_str());if(hold<0 || hold>20000)return 42;
    BeamRTDeviceFixtureReport report{};report.warp=args[2]==L"warp"?1u:0u;auto& start=report.startup;
    start.bytes=sizeof(start);start.magic=beamrtStartupFixtureMagic;start.processId=GetCurrentProcessId();
    const auto module=GetModuleHandleW(args[base+3].c_str());using StartupQuery=BOOL(WINAPI*)(BeamRTStartupStatus*,DWORD);
    const auto query=module?reinterpret_cast<StartupQuery>(GetProcAddress(module,"BeamRT_StartupQuery")):nullptr;
    if(query)start.queryOK=query(&start.status,sizeof(start.status))?1u:0u;
    start.initialThread=start.status.attachThread==GetCurrentThreadId()?1u:0u;
    start.cwdMatches=std::filesystem::current_path()==std::filesystem::path(path).parent_path()?1u:0u;
    const std::vector<std::wstring> expected={L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"};
    const size_t tail=base+8;bool matching=args.size()==tail+1+expected.size() && args[tail]==L"--";
    for(size_t i=0;matching && i<expected.size();++i)matching=args[tail+1+i]==expected[i];start.argsMatch=matching?1u:0u;
    bool valid=start.queryOK && start.initialThread && start.cwdMatches && start.argsMatch;
    try {if(valid)testDevice(module,report.warp!=0,report);}catch(...){valid=false;}
    valid=valid && report.testsMask==511 && !report.errorStep;
    if(!writeNew(path,&report,sizeof(report)))return 43;if(hold)Sleep(static_cast<DWORD>(hold));
    const DWORD exit=valid?0u:44u;if(!writeNew(path+L".done",&exit,sizeof(exit)))return 45;return static_cast<int>(exit);
}
