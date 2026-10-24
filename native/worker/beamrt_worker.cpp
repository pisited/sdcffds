#define BEAMRT_WORKER_BUILD
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "beamrt_worker.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <vector>
using Microsoft::WRL::ComPtr;
static_assert(sizeof(BeamRTScene)==192 && sizeof(BeamRTRay)==32 && sizeof(BeamRTHit)==8, "GPU ABI");
static thread_local std::string lastError;
static void check(HRESULT value, const char* operation) {
    if (FAILED(value)) {
        std::ostringstream message; message << operation << " failed (0x" << std::hex << value << ')';
        throw std::runtime_error(message.str());
    }
}
static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static D3D12_RESOURCE_DESC bufferDesc(uint64_t size, D3D12_RESOURCE_FLAGS flags=D3D12_RESOURCE_FLAG_NONE) {
    D3D12_RESOURCE_DESC d{}; d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER; d.Width=size;
    d.Height=1; d.DepthOrArraySize=1; d.MipLevels=1; d.SampleDesc.Count=1;
    d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR; d.Flags=flags; return d;
}
static D3D12_RESOURCE_BARRIER transition(ID3D12Resource* resource, D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to) {
    D3D12_RESOURCE_BARRIER b{}; b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource=resource; b.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore=from; b.Transition.StateAfter=to; return b;
}
struct BeamRTWorker {
    std::mutex mutex;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12DescriptorHeap> descriptors;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12Resource> mesh, constants;
    std::vector<ComPtr<ID3D12Resource>> inFlight;
    HANDLE event=nullptr;
    uint64_t sequence=0;
    uint32_t acquisition=1;
    bool pending=false, signaled=false, recording=false;
    ~BeamRTWorker() { if (event) CloseHandle(event); }
    ComPtr<ID3D12Resource> resource(const D3D12_RESOURCE_DESC& desc, D3D12_HEAP_TYPE type, D3D12_RESOURCE_STATES state) {
        D3D12_HEAP_PROPERTIES props{}; props.Type=type;
        ComPtr<ID3D12Resource> result;
        check(device->CreateCommittedResource(&props,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,IID_PPV_ARGS(&result)), "CreateCommittedResource");
        return result;
    }
    void finish() {
        if (!pending) return;
        check(device->GetDeviceRemovedReason(), "DeviceRemovedReason");
        require(signaled, "submission fence unavailable; retain worker until device removal");
        if (fence->GetCompletedValue()<sequence) {
            check(fence->SetEventOnCompletion(sequence,event), "SetEventOnCompletion");
            require(WaitForSingleObject(event,10000)==WAIT_OBJECT_0, "GPU wait timed out; worker/resources retained");
        }
        check(device->GetDeviceRemovedReason(), "DeviceRemovedReason");
        inFlight.clear(); pending=false;
    }
    void begin() {
        finish(); check(allocator->Reset(), "Allocator Reset");
        check(commands->Reset(allocator.Get(),pipeline.Get()), "CommandList Reset");
        recording=true;
    }
    void submit(std::vector<ComPtr<ID3D12Resource>> resources) {
        check(commands->Close(), "CommandList Close");
        recording=false;
        inFlight=std::move(resources); pending=true; signaled=false; ++sequence;
        ID3D12CommandList* lists[]={commands.Get()}; queue->ExecuteCommandLists(1,lists);
        check(queue->Signal(fence.Get(),sequence), "Queue Signal"); signaled=true; finish();
    }
};
struct RecordingGuard {
    BeamRTWorker* worker;
    ~RecordingGuard() {
        if (worker->recording && !worker->pending) {
            worker->commands->Close(); worker->recording=false;
        }
    }
};
static void fill(ID3D12Resource* resource, const void* bytes, size_t count) {
    void* mapped=nullptr; D3D12_RANGE noRead{0,0};
    check(resource->Map(0,&noRead,&mapped), "Upload Map");
    std::memcpy(mapped,bytes,count); D3D12_RANGE written{0,count}; resource->Unmap(0,&written);
}
static void validate(const BeamRTScene& s, const uint8_t* rgba, uint64_t bytes) {
    require(rgba && s.atlas[0]>0 && s.atlas[0]<=16384 && s.atlas[1]>0 && s.atlas[1]<=16384, "invalid atlas dimensions/data");
    const uint64_t pixels=uint64_t(s.atlas[0])*s.atlas[1];
    require(bytes==pixels*4 && bytes<=16*1024*1024, "atlas bytes/budget mismatch");
    const uint8_t headers[]={64,128,192,255,23,101,211,37};
    require(bytes>=8 && std::memcmp(rgba,headers,8)==0, "packed BVH headers invalid");
    require(s.counts[0]>0 && s.counts[0]<=4096 && s.counts[1]>0 && s.counts[1]<=200000, "geometry count exceeds traversal/data budget");
    require(s.counts[2]==2+6*s.counts[0] && uint64_t(s.counts[2])+uint64_t(s.counts[1])*7<=pixels, "packed layout mismatch");
    require(s.counts[3]==0 && s.atlas[2]==0 && s.atlas[3]==0, "unsupported ABI fields");
    const float* vectors[]={s.origin,s.inverseX,s.inverseY,s.inverseZ,s.quantMin,s.quantExtent};
    for (auto v:vectors) for (int i=0;i<4;++i) require(std::isfinite(v[i]), "nonfinite scene transform");
    for (int i=0;i<3;++i) require(s.quantExtent[i]>0, "invalid quantization extent");
    const auto& x=s.inverseX; const auto& y=s.inverseY; const auto& z=s.inverseZ;
    float determinant=x[0]*(y[1]*z[2]-y[2]*z[1])-x[1]*(y[0]*z[2]-y[2]*z[0])+x[2]*(y[0]*z[1]-y[1]*z[0]);
    require(std::isfinite(determinant) && std::abs(determinant)>1e-10f, "singular scene transform");
    for (uint32_t mode:s.materials) require(mode<=3, "unsupported material policy");
}
extern "C" uint32_t BeamRT_WorkerAbiVersion() { return 2; }
extern "C" const char* BeamRT_WorkerLastError() { return lastError.c_str(); }
extern "C" int BeamRT_WorkerCreate(void* nativeDevice, const void* shader, uint64_t bytes, BeamRTWorker** output) {
    BeamRTWorker* w=nullptr;
    try {
        lastError.clear(); require(output && !*output, "output must be a null worker pointer");
        require(nativeDevice && shader && bytes>=4 && bytes<=16*1024*1024, "valid caller-owned D3D12 device/shader required");
        w=new BeamRTWorker; w->device=static_cast<ID3D12Device*>(nativeDevice);
        D3D12_COMMAND_QUEUE_DESC q{}; q.Type=D3D12_COMMAND_LIST_TYPE_COMPUTE;
        check(w->device->CreateCommandQueue(&q,IID_PPV_ARGS(&w->queue)), "CreateCommandQueue");
        check(w->device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&w->allocator)), "CreateCommandAllocator");
        check(w->device->CreateCommandList(0,q.Type,w->allocator.Get(),nullptr,IID_PPV_ARGS(&w->commands)), "CreateCommandList");
        check(w->commands->Close(), "Initial Close");
        check(w->device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&w->fence)), "CreateFence");
        w->event=CreateEventW(nullptr,FALSE,FALSE,nullptr); require(w->event!=nullptr, "CreateEvent failed");
        D3D12_DESCRIPTOR_RANGE range{}; range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV; range.NumDescriptors=1;
        D3D12_ROOT_PARAMETER params[5]{};
        params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
        params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[1].DescriptorTable.NumDescriptorRanges=1; params[1].DescriptorTable.pDescriptorRanges=&range;
        params[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV; params[2].Descriptor.ShaderRegister=1;
        params[3].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;
        params[4].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        params[4].Constants.ShaderRegister=1; params[4].Constants.Num32BitValues=1;
        D3D12_ROOT_SIGNATURE_DESC rootDesc{}; rootDesc.NumParameters=5; rootDesc.pParameters=params;
        ComPtr<ID3DBlob> encoded, errors;
        check(D3D12SerializeRootSignature(&rootDesc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors), "SerializeRootSignature");
        check(w->device->CreateRootSignature(0,encoded->GetBufferPointer(),encoded->GetBufferSize(),IID_PPV_ARGS(&w->root)), "CreateRootSignature");
        D3D12_COMPUTE_PIPELINE_STATE_DESC pso{}; pso.pRootSignature=w->root.Get(); pso.CS={shader,static_cast<SIZE_T>(bytes)};
        check(w->device->CreateComputePipelineState(&pso,IID_PPV_ARGS(&w->pipeline)), "CreateComputePipelineState");
        D3D12_DESCRIPTOR_HEAP_DESC heap{}; heap.NumDescriptors=1; heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        check(w->device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&w->descriptors)), "CreateDescriptorHeap");
        *output=w; return 0;
    } catch (const std::exception& e) { lastError=e.what(); delete w; return -1; }
}
extern "C" int BeamRT_WorkerCreateOnAdapter(uint32_t low, int32_t high,
    uint32_t candidateCreationAllowed, const void* shader, uint64_t bytes, BeamRTWorker** output) {
    try {
        lastError.clear(); require(output && !*output, "output must be a null worker pointer");
        require(candidateCreationAllowed==1, "candidate device creation requires explicit opt-in");
        require(shader && bytes>=4 && bytes<=16*1024*1024, "valid compute shader required");
        ComPtr<IDXGIFactory4> factory; check(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)), "CreateDXGIFactory2");
        const LUID wanted{low,high}; ComPtr<IDXGIAdapter1> adapter;
        check(factory->EnumAdapterByLuid(wanted,IID_PPV_ARGS(&adapter)), "EnumAdapterByLuid (no default fallback)");
        ComPtr<ID3D12Device> device;
        check(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)), "D3D12CreateDevice candidate");
        const LUID actual=device->GetAdapterLuid();
        require(actual.LowPart==low && actual.HighPart==high, "candidate adapter identity mismatch");
        const int result=BeamRT_WorkerCreate(device.Get(),shader,bytes,output);
        if (result==0) (*output)->acquisition=2;
        return result;
    } catch (const std::exception& e) { lastError=e.what(); return -1; }
}
extern "C" int BeamRT_WorkerGetDeviceInfo(BeamRTWorker* w, BeamRTDeviceInfo* output) {
    try {
        lastError.clear(); require(w && output, "worker/device-info output required");
        std::lock_guard<std::mutex> lock(w->mutex);
        check(w->device->GetDeviceRemovedReason(), "DeviceRemovedReason");
        const LUID luid=w->device->GetAdapterLuid();
        *output={luid.LowPart,luid.HighPart,w->acquisition,0}; return 0;
    } catch (const std::exception& e) { lastError=e.what(); return -1; }
}
extern "C" int BeamRT_WorkerDeviceMatchesResource(BeamRTWorker* w, void* resource, uint32_t* matches) {
    try {
        lastError.clear(); require(matches!=nullptr, "device-match output required"); *matches=0;
        require(w && resource, "worker and valid native resource required");
        std::lock_guard<std::mutex> lock(w->mutex);
        check(w->device->GetDeviceRemovedReason(), "DeviceRemovedReason");
        ComPtr<ID3D12Device> owner;
        check(static_cast<ID3D12Resource*>(resource)->GetDevice(IID_PPV_ARGS(&owner)), "Resource GetDevice");
        check(owner->GetDeviceRemovedReason(), "Resource DeviceRemovedReason");
        ComPtr<IUnknown> ours, theirs;
        check(w->device.As(&ours), "Worker device IUnknown"); check(owner.As(&theirs), "Resource device IUnknown");
        *matches=ours.Get()==theirs.Get()?1u:0u; return 0;
    } catch (const std::exception& e) { lastError=e.what(); return -1; }
}
extern "C" int BeamRT_WorkerUpload(BeamRTWorker* w, const BeamRTScene* scene, const uint8_t* rgba, uint64_t bytes) {
    try {
        lastError.clear(); require(w && scene, "worker/scene required"); std::lock_guard<std::mutex> lock(w->mutex);
        validate(*scene,rgba,bytes); w->begin(); RecordingGuard recording{w};
        D3D12_RESOURCE_DESC desc{}; desc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width=scene->atlas[0]; desc.Height=scene->atlas[1]; desc.DepthOrArraySize=1; desc.MipLevels=1;
        desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count=1;
        auto texture=w->resource(desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{}; UINT rows; UINT64 rowBytes,total;
        w->device->GetCopyableFootprints(&desc,0,1,0,&footprint,&rows,&rowBytes,&total);
        auto upload=w->resource(bufferDesc(total),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        void* mapped; D3D12_RANGE noRead{0,0}; check(upload->Map(0,&noRead,&mapped), "Atlas Map");
        for (UINT row=0;row<rows;++row) std::memcpy(static_cast<uint8_t*>(mapped)+footprint.Offset+uint64_t(row)*footprint.Footprint.RowPitch,
                                                rgba+uint64_t(row)*rowBytes,static_cast<size_t>(rowBytes));
        upload->Unmap(0,nullptr);
        auto constants=w->resource(bufferDesc(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        fill(constants.Get(),scene,sizeof(*scene));
        D3D12_TEXTURE_COPY_LOCATION dst{},src{}; dst.pResource=texture.Get(); dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src.pResource=upload.Get(); src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint=footprint;
        w->commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        auto barrier=transition(texture.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        w->commands->ResourceBarrier(1,&barrier); w->submit({texture,upload,constants});
        D3D12_SHADER_RESOURCE_VIEW_DESC view{}; view.Format=desc.Format; view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
        view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; view.Texture2D.MipLevels=1;
        w->device->CreateShaderResourceView(texture.Get(),&view,w->descriptors->GetCPUDescriptorHandleForHeapStart());
        w->mesh=texture; w->constants=constants; return 0;
    } catch (const std::exception& e) { lastError=e.what(); return -1; }
}
extern "C" int BeamRT_WorkerTrace(BeamRTWorker* w, const BeamRTRay* rays, uint32_t count, BeamRTHit* output) {
    try {
        lastError.clear(); require(w && rays && output && count>0 && count<=8192, "invalid ray batch/budget");
        std::lock_guard<std::mutex> lock(w->mutex); require(w->mesh && w->constants, "scene not uploaded");
        for (uint32_t i=0;i<count;++i) {
            for (float v:rays[i].origin) require(std::isfinite(v), "nonfinite ray origin");
            float lengthSquared=0;
            for (float v:rays[i].direction) { require(std::isfinite(v), "nonfinite ray direction"); lengthSquared+=v*v; }
            require(std::abs(lengthSquared-1)<0.001f, "world ray direction must be unit length");
            require(std::isfinite(rays[i].reach) && std::isfinite(rays[i].startBias) && rays[i].startBias>=0 && rays[i].reach>rays[i].startBias, "invalid world ray distances");
        }
        w->begin(); RecordingGuard recording{w};
        auto input=w->resource(bufferDesc(uint64_t(count)*sizeof(BeamRTRay)),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        fill(input.Get(),rays,size_t(count)*sizeof(BeamRTRay));
        const uint64_t bytes=uint64_t(count)*sizeof(BeamRTHit);
        auto result=w->resource(bufferDesc(bytes,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        auto readback=w->resource(bufferDesc(bytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        ID3D12DescriptorHeap* heaps[]={w->descriptors.Get()};
        w->commands->SetDescriptorHeaps(1,heaps); w->commands->SetComputeRootSignature(w->root.Get());
        w->commands->SetComputeRootConstantBufferView(0,w->constants->GetGPUVirtualAddress());
        w->commands->SetComputeRootDescriptorTable(1,w->descriptors->GetGPUDescriptorHandleForHeapStart());
        w->commands->SetComputeRootShaderResourceView(2,input->GetGPUVirtualAddress());
        w->commands->SetComputeRootUnorderedAccessView(3,result->GetGPUVirtualAddress());
        w->commands->SetComputeRoot32BitConstant(4,count,0); w->commands->Dispatch((count+63)/64,1,1);
        auto barrier=transition(result.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        w->commands->ResourceBarrier(1,&barrier); w->commands->CopyBufferRegion(readback.Get(),0,result.Get(),0,bytes);
        w->submit({input,result,readback,w->mesh,w->constants});
        void* mapped; D3D12_RANGE read{0,static_cast<SIZE_T>(bytes)}; check(readback->Map(0,&read,&mapped), "Readback Map");
        std::memcpy(output,mapped,static_cast<size_t>(bytes)); D3D12_RANGE noWrite{0,0}; readback->Unmap(0,&noWrite); return 0;
    } catch (const std::exception& e) { lastError=e.what(); return -1; }
}
extern "C" int BeamRT_WorkerDestroy(BeamRTWorker** worker) {
    try {
        lastError.clear(); require(worker!=nullptr, "worker pointer required"); if (!*worker) return 0;
        auto w=*worker;
        { std::lock_guard<std::mutex> lock(w->mutex);
          // Device removal stops execution; otherwise retire every owned resource.
          if (SUCCEEDED(w->device->GetDeviceRemovedReason())) w->finish(); }
        delete w; *worker=nullptr; return 0;
    } catch (const std::exception& e) { lastError=e.what(); return -1; }
}
