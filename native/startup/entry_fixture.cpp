#include "fixture_contract.h"
#include <shellapi.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <filesystem>
#include <string>
#include <vector>
#include <cstring>
using Microsoft::WRL::ComPtr;
static BeamRTEntryTestFrame deliveredFrame{};
static bool frameRecorded=false;
extern "C" void BeamRT_EntryFixtureRecord(const void* raw) noexcept {
    // Called before EXE CRT initialization: only POD copies, no runtime calls.
    const auto bytes=static_cast<const uint8_t*>(raw);
    for(int i=0;i<7;++i)deliveredFrame.registers[i]=reinterpret_cast<const uint64_t*>(bytes+0x20)[i];
    deliveredFrame.flags=*reinterpret_cast<const uint64_t*>(bytes+0xc0);
    for(int i=0;i<96;++i)deliveredFrame.xmm[i]=bytes[0x60+i];frameRecorded=true;
}
using EntryQuery=HRESULT(WINAPI*)(BeamRTEntryStatus*,uint32_t);
using EntryObserver=HRESULT(WINAPI*)(BeamRTDeviceObserver**);
using EntryStop=HRESULT(WINAPI*)(uint32_t);
using FrameQuery=HRESULT(WINAPI*)(BeamRTEntryTestFrame*,uint32_t);
using DeviceQuery=HRESULT(WINAPI*)(BeamRTDeviceObserver*,BeamRTDeviceObservation*,uint32_t);
using DeviceAcquire=HRESULT(WINAPI*)(BeamRTDeviceObserver*,uint64_t,ID3D12Device**);
static bool same(IUnknown* a,IUnknown* b) {
    ComPtr<IUnknown> x,y;return a && b && SUCCEEDED(a->QueryInterface(IID_PPV_ARGS(&x)))
        && SUCCEEDED(b->QueryInterface(IID_PPV_ARGS(&y))) && x.Get()==y.Get();
}
struct BeforeMain {
    std::vector<std::wstring> args;
    BeamRTEntryFixtureReport report{};
    ComPtr<ID3D12Device> device;
    bool valid=false;
    HMODULE module=nullptr;
    EntryQuery entryQuery=nullptr;EntryObserver observer=nullptr;EntryStop stop=nullptr;
    BeforeMain() {
        int count=0;auto values=CommandLineToArgvW(GetCommandLineW(),&count);if(!values)return;
        args.assign(values,values+count);LocalFree(values);
        if(args.size()<13 || args[1]!=L"--entry-mode" || (args[2]!=L"passive" && args[2]!=L"auto" && args[2]!=L"init-failure")
            || args[3]!=L"--device-backend" || (args[4]!=L"hardware" && args[4]!=L"warp") || args[5]!=L"--report" || args[7]!=L"--module"
            || args[9]!=L"--hold-ms" || args[11]!=L"--exit-code")return;
        report.mode=args[2]==L"auto"?1u:args[2]==L"init-failure"?2u:0u;report.warp=args[4]==L"warp"?1u:0u;
        module=GetModuleHandleW(args[8].c_str());if(!module)return;
        entryQuery=reinterpret_cast<EntryQuery>(GetProcAddress(module,"BeamRT_EntryQuery"));
        observer=reinterpret_cast<EntryObserver>(GetProcAddress(module,"BeamRT_EntryGetDeviceObserver"));
        stop=reinterpret_cast<EntryStop>(GetProcAddress(module,"BeamRT_EntryStopDeviceObserver"));
        const auto frameQuery=reinterpret_cast<FrameQuery>(GetProcAddress(module,"BeamRT_EntryTestQueryFrame"));
        if(!entryQuery || !observer || !stop || !frameQuery || FAILED(entryQuery(&report.entry,sizeof(report.entry))))return;
        BeamRTEntryTestFrame before{};
        report.frameMatches=frameRecorded && SUCCEEDED(frameQuery(&before,sizeof(before))) && std::memcmp(&before,&deliveredFrame,sizeof(before))==0?1u:0u;
        report.preMainReached=report.entry.reached && report.entry.released && report.entry.entryBytesRestored && !report.entry.hookAttached?1u:0u;
        if(!report.frameMatches || !report.preMainReached || report.entry.ownerThread!=GetCurrentThreadId())return;
        BeamRTDeviceObserver* handle=nullptr;const HRESULT acquired=observer(&handle);
        if(report.mode==1){if(FAILED(acquired) || !handle || !report.entry.deviceStarted || FAILED(report.entry.deviceResult))return;}
        else if(SUCCEEDED(acquired) || handle || report.entry.deviceStarted || (report.mode==2 && SUCCEEDED(report.entry.deviceResult)))return;
        ComPtr<IDXGIFactory6> factory;if(FAILED(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory))))return;
        ComPtr<IDXGIAdapter> adapter;
        if(report.warp){if(FAILED(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter))))return;}
        else for(UINT i=0;!adapter;++i){ComPtr<IDXGIAdapter1> candidate;
            if(FAILED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&candidate))))return;
            DXGI_ADAPTER_DESC1 description{};if(FAILED(candidate->GetDesc1(&description)))return;
            if(!(description.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)
                && SUCCEEDED(D3D12CreateDevice(candidate.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)))candidate.As(&adapter);
        }
        // Real device creation from an EXE static constructor, before wWinMain.
        if(FAILED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))return;
        if(report.mode==1){
            const auto query=reinterpret_cast<DeviceQuery>(GetProcAddress(module,"BeamRT_DeviceObserveQuery"));
            const auto acquire=reinterpret_cast<DeviceAcquire>(GetProcAddress(module,"BeamRT_DeviceObserveAcquire"));
            if(!query || !acquire || FAILED(query(handle,&report.device,sizeof(report.device))) || !report.device.complete || report.device.deviceResults!=1)return;
            ComPtr<ID3D12Device> seen;if(FAILED(acquire(handle,report.device.generation,&seen)) || !same(seen.Get(),device.Get()))return;
            D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=256;desc.Height=1;desc.DepthOrArraySize=1;
            desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
            D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_UPLOAD;ComPtr<ID3D12Resource> resource;ComPtr<ID3D12Device> owner;
            if(FAILED(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&resource)))
                || FAILED(resource->GetDevice(IID_PPV_ARGS(&owner))) || !same(owner.Get(),seen.Get()))return;
        }
        valid=true;
    }
};
static BeforeMain beforeMain;
static bool writeNew(const std::wstring& path,const void* data,DWORD bytes) {
    HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;DWORD written=0;const BOOL ok=WriteFile(file,data,bytes,&written,nullptr);CloseHandle(file);return ok && written==bytes;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,LPWSTR,int) {
    auto& fixture=beforeMain;if(fixture.args.size()<13)return 41;auto& report=fixture.report;const auto path=fixture.args[6];
    auto& startup=report.startup;startup.bytes=sizeof(startup);startup.magic=beamrtStartupFixtureMagic;startup.processId=GetCurrentProcessId();
    using StartupQuery=BOOL(WINAPI*)(BeamRTStartupStatus*,DWORD);
    const auto query=reinterpret_cast<StartupQuery>(GetProcAddress(fixture.module,"BeamRT_StartupQuery"));
    if(query)startup.queryOK=query(&startup.status,sizeof(startup.status))?1u:0u;
    startup.initialThread=startup.status.attachThread==GetCurrentThreadId()?1u:0u;
    startup.cwdMatches=std::filesystem::current_path()==std::filesystem::path(path).parent_path()?1u:0u;
    const std::vector<std::wstring> expected={L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"};
    const size_t tail=13;bool match=fixture.args.size()==tail+1+expected.size() && fixture.args[tail]==L"--";
    for(size_t i=0;match && i<expected.size();++i)match=fixture.args[tail+1+i]==expected[i];startup.argsMatch=match?1u:0u;
    bool valid=fixture.valid && startup.queryOK && startup.initialThread && startup.cwdMatches && startup.argsMatch;
    if(report.mode==1){valid=valid && SUCCEEDED(fixture.stop(1));fixture.entryQuery(&report.entry,sizeof(report.entry));valid=valid && report.entry.deviceStopped==1;}
    const DWORD code=valid?0u:44u;if(!writeNew(path,&report,sizeof(report)))return 43;
    const int hold=_wtoi(fixture.args[10].c_str());if(hold>0 && hold<=20000)Sleep(static_cast<DWORD>(hold));
    if(!writeNew(path+L".done",&code,sizeof(code)))return 45;return static_cast<int>(code);
}
