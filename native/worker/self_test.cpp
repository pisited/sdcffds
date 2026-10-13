#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "beamrt_worker.h"
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
using Microsoft::WRL::ComPtr;
static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static void success(int result) { require(result==0,BeamRT_WorkerLastError()); }
static void read(std::ifstream& stream, void* data, size_t bytes) {
    stream.read(static_cast<char*>(data),static_cast<std::streamsize>(bytes)); require(bool(stream),"truncated fixture");
}
static std::vector<uint8_t> file(const wchar_t* path) {
    std::ifstream stream(std::filesystem::path(path),std::ios::binary|std::ios::ate);
    require(bool(stream),"shader file missing"); auto size=stream.tellg();
    require(size>0 && size<=16*1024*1024,"shader bytecode size invalid");
    std::vector<uint8_t> data(static_cast<size_t>(size)); stream.seekg(0); read(stream,data.data(),data.size()); return data;
}
static ComPtr<ID3D12Resource> ownerResource(ID3D12Device* device) {
    D3D12_HEAP_PROPERTIES heap{}; heap.Type=D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC desc{}; desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width=256; desc.Height=1; desc.DepthOrArraySize=1; desc.MipLevels=1;
    desc.SampleDesc.Count=1; desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D12Resource> resource;
    require(SUCCEEDED(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,
        D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&resource))),"host ownership resource creation failed");
    return resource;
}
int wmain(int argc, wchar_t** argv) {
    BeamRTWorker* worker=nullptr;
    try {
        require(argc==3 || argc==4,"usage: self_test fixture.bin trace.cso [--warp]");
        const bool warp=argc==4 && std::wstring(argv[3])==L"--warp";
        require(argc!=4 || warp,"unknown test option");
        ComPtr<ID3D12Debug> debug; const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));
        if (debugEnabled) debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory; require(SUCCEEDED(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory))),"DXGI factory creation failed");
        ComPtr<ID3D12Device> device;
        if (warp) {
            ComPtr<IDXGIAdapter> adapter; require(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter))),"WARP unavailable");
            require(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))),"WARP device creation failed");
            std::cout << "Backend: WARP software device (not hardware performance proof)\n";
        } else {
            for (UINT i=0;;++i) {
                ComPtr<IDXGIAdapter1> adapter;
                if (FAILED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter)))) break;
                DXGI_ADAPTER_DESC1 desc{}; adapter->GetDesc1(&desc); if (desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) continue;
                if (SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)))) {
                    std::wcout << L"Backend: " << desc.Description << L"\n"; break;
                }
            }
            require(bool(device),"no D3D12 hardware device; use explicit --warp for software testing");
        }
        ComPtr<ID3D12InfoQueue> messages; device.As(&messages); if (messages) messages->ClearStoredMessages();
        std::ifstream stream(std::filesystem::path(argv[1]),std::ios::binary);
        require(bool(stream),"fixture missing"); uint32_t header[4]; read(stream,header,sizeof(header));
        require(header[0]==0x42525431 && header[1]<=16*1024*1024 && header[2]>0 && header[2]<=8192 && header[3]==0,"invalid fixture header");
        BeamRTScene scene{}; read(stream,&scene,sizeof(scene));
        std::vector<uint8_t> pixels(header[1]); read(stream,pixels.data(),pixels.size());
        std::vector<BeamRTRay> rays(header[2]); read(stream,rays.data(),rays.size()*sizeof(BeamRTRay));
        std::vector<int32_t> expected(rays.size()); read(stream,expected.data(),expected.size()*sizeof(int32_t));
        require(stream.peek()==std::char_traits<char>::eof(),"unexpected fixture bytes");
        auto shader=file(argv[2]); std::vector<BeamRTHit> actual(rays.size());
        require(BeamRT_WorkerAbiVersion()==2,"worker ABI mismatch");
        require(BeamRT_WorkerCreate(nullptr,shader.data(),shader.size(),&worker)!=0 && !worker,"missing device must not fabricate an engine attachment");
        const LUID hostLuid=device->GetAdapterLuid();
        require(BeamRT_WorkerCreateOnAdapter(hostLuid.LowPart,hostLuid.HighPart,0,shader.data(),shader.size(),&worker)!=0 && !worker,"candidate created without explicit permission");
        require(BeamRT_WorkerCreateOnAdapter(UINT32_MAX,INT32_MAX,1,shader.data(),shader.size(),&worker)!=0 && !worker,"unknown adapter fell back silently");
        success(BeamRT_WorkerCreateOnAdapter(hostLuid.LowPart,hostLuid.HighPart,1,shader.data(),shader.size(),&worker));
        BeamRTDeviceInfo info{}; success(BeamRT_WorkerGetDeviceInfo(worker,&info));
        require(info.luidLow==hostLuid.LowPart && info.luidHigh==hostLuid.HighPart && info.acquisition==2 && info.reserved==0,"candidate identity/provenance mismatch");
        auto hostResource=ownerResource(device.Get()); uint32_t matches=0;
        success(BeamRT_WorkerDeviceMatchesResource(worker,hostResource.Get(),&matches));
        require(matches==1,"candidate did not reuse the existing offline host device");
        require(BeamRT_WorkerDeviceMatchesResource(worker,nullptr,&matches)!=0 && matches==0,"null native resource accepted");
        require(BeamRT_WorkerDeviceMatchesResource(worker,hostResource.Get(),nullptr)!=0,"null ownership output accepted");
        if (!warp) {
            ComPtr<IDXGIAdapter> foreignAdapter; require(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&foreignAdapter))),"foreign WARP adapter unavailable");
            ComPtr<ID3D12Device> foreignDevice;
            require(SUCCEEDED(D3D12CreateDevice(foreignAdapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&foreignDevice))),"foreign device unavailable");
            auto foreignResource=ownerResource(foreignDevice.Get());
            success(BeamRT_WorkerDeviceMatchesResource(worker,foreignResource.Get(),&matches));
            require(matches==0,"foreign-device resource accepted as ours");
        }
        std::cout << "Adapter candidate reuses offline host device; resource owner identity verified\n";
        require(BeamRT_WorkerTrace(worker,rays.data(),static_cast<uint32_t>(rays.size()),actual.data())!=0,"unprepared scene accepted");
        for (int pass=0;pass<3;++pass) {
            BeamRTScene params=scene; auto query=rays;
            if (pass==1) for (auto& mode:params.materials) mode=0; // unresolved coverage is NOT opaque
            if (pass==2) {
                const float scale[]={2,3,4}, origin[]={12,-8,5};
                for (int axis=0;axis<3;++axis) {
                    params.origin[axis]=origin[axis]; params.inverseX[axis]=axis==0?1/scale[axis]:0;
                    params.inverseY[axis]=axis==1?1/scale[axis]:0; params.inverseZ[axis]=axis==2?1/scale[axis]:0;
                }
                for (auto& ray:query) {
                    float len=0; for (int axis=0;axis<3;++axis) {
                        ray.origin[axis]=ray.origin[axis]*scale[axis]+origin[axis];
                        ray.direction[axis]*=scale[axis]; len+=ray.direction[axis]*ray.direction[axis];
                    }
                    len=std::sqrt(len); for (auto& value:ray.direction) value/=len;
                    ray.reach*=len; ray.startBias*=len;
                }
            }
            success(BeamRT_WorkerUpload(worker,&params,pixels.data(),pixels.size()));
            success(BeamRT_WorkerTrace(worker,query.data(),static_cast<uint32_t>(query.size()),actual.data()));
            for (size_t i=0;i<actual.size();++i) {
                int wanted=pass==1 && expected[i]==2?1:expected[i];
                if (actual[i].category!=wanted) {
                    std::cerr << "pass " << pass << " ray " << i << " expected " << wanted << " got " << actual[i].category << '\n';
                    throw std::runtime_error("GPU result differs from CPU brute force");
                }
                require(actual[i].visits>0 && actual[i].visits<=4096,"invalid traversal visit count");
            }
            std::cout << "GPU batch " << pass << ": " << query.size() << " rays agree with CPU reference\n";
        }
        // Invalid replacements are rejected without losing the previous scene.
        auto badScene=scene; badScene.counts[2]++;
        require(BeamRT_WorkerUpload(worker,&badScene,pixels.data(),pixels.size())!=0,"invalid layout accepted");
        badScene=scene; badScene.inverseX[0]=std::numeric_limits<float>::quiet_NaN();
        require(BeamRT_WorkerUpload(worker,&badScene,pixels.data(),pixels.size())!=0,"NaN transform accepted");
        auto badPixels=pixels; badPixels[0]=0;
        require(BeamRT_WorkerUpload(worker,&scene,badPixels.data(),badPixels.size())!=0,"bad atlas header accepted");
        auto badRay=rays[0]; badRay.direction[0]=badRay.direction[1]=badRay.direction[2]=0;
        require(BeamRT_WorkerTrace(worker,&badRay,1,actual.data())!=0,"invalid ray accepted");
        badRay=rays[0]; badRay.reach=badRay.startBias;
        require(BeamRT_WorkerTrace(worker,&badRay,1,actual.data())!=0,"empty ray segment accepted");
        badRay=rays[0]; badRay.origin[0]=std::numeric_limits<float>::quiet_NaN();
        require(BeamRT_WorkerTrace(worker,&badRay,1,actual.data())!=0,"NaN ray accepted");
        require(BeamRT_WorkerTrace(worker,rays.data(),0,actual.data())!=0,"zero ray count accepted");
        // Valid atlas headers are not sufficient to prove valid node topology.
        // Corrupt the root escape link; the GPU must return invalid, never opaque.
        badPixels=pixels; for (size_t i=0;i<4;++i) badPixels[(2+5)*4+i]=0;
        success(BeamRT_WorkerUpload(worker,&scene,badPixels.data(),badPixels.size()));
        success(BeamRT_WorkerTrace(worker,rays.data(),static_cast<uint32_t>(rays.size()),actual.data()));
        for (const auto& hit:actual) require(hit.category==-1,"corrupt node certified a hit/miss");
        // Explicit identity upload verifies recovery after all failed replacements.
        success(BeamRT_WorkerUpload(worker,&scene,pixels.data(),pixels.size()));
        success(BeamRT_WorkerTrace(worker,rays.data(),static_cast<uint32_t>(rays.size()),actual.data()));
        for (size_t i=0;i<actual.size();++i) require(actual[i].category==expected[i],"worker did not recover");
        success(BeamRT_WorkerDestroy(&worker)); require(!worker,"worker not cleared"); success(BeamRT_WorkerDestroy(&worker));
        success(BeamRT_WorkerCreate(device.Get(),shader.data(),shader.size(),&worker));
        success(BeamRT_WorkerGetDeviceInfo(worker,&info)); require(info.acquisition==1,"legacy caller-device provenance changed");
        success(BeamRT_WorkerUpload(worker,&scene,pixels.data(),pixels.size()));
        success(BeamRT_WorkerTrace(worker,rays.data(),static_cast<uint32_t>(rays.size()),actual.data()));
        for (size_t i=0;i<actual.size();++i) require(actual[i].category==expected[i],"recreated worker mismatch");
        success(BeamRT_WorkerDestroy(&worker));
        if (messages) for (UINT64 i=0;i<messages->GetNumStoredMessagesAllowedByRetrievalFilter();++i) {
            SIZE_T bytes=0; messages->GetMessage(i,nullptr,&bytes); std::vector<uint8_t> data(bytes);
            auto message=reinterpret_cast<D3D12_MESSAGE*>(data.data()); messages->GetMessage(i,message,&bytes);
            if (message->Severity<=D3D12_MESSAGE_SEVERITY_ERROR) {
                std::cerr << message->pDescription << '\n'; throw std::runtime_error("D3D12 debug-layer error");
            }
        }
        std::cout << "Validation passed; debug layer " << (debugEnabled?"enabled":"unavailable")
                  << ". No BeamNG device, camera, depth or composition was used.\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL: " << e.what() << '\n'; if (worker) BeamRT_WorkerDestroy(&worker); return 1;
    }
}
