#define BEAMRT_GI_BUILD
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "beamrt_gi.h"
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
static thread_local std::string lastError;
static void require(bool ok,const char* why) { if(!ok) throw std::runtime_error(why); }
static void check(HRESULT hr,const char* why) {
    if(FAILED(hr)) { std::ostringstream message;message<<why<<" (0x"<<std::hex<<hr<<')';throw std::runtime_error(message.str()); }
}
static void owner(ID3D12Device* device,ID3D12DeviceChild* object) {
    require(object!=nullptr,"valid native interface required");
    ComPtr<ID3D12Device> actual;check(object->GetDevice(IID_PPV_ARGS(&actual)),"GetDevice");
    ComPtr<IUnknown> a,b;check(device->QueryInterface(IID_PPV_ARGS(&a)),"Device identity");
    check(actual.As(&b),"Owner identity");require(a.Get()==b.Get(),"foreign-device interface rejected");
}
static ComPtr<ID3D12Resource> make(ID3D12Device* device,D3D12_RESOURCE_DESC desc,
    D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES props{};props.Type=type;ComPtr<ID3D12Resource> resource;
    check(device->CreateCommittedResource(&props,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,IID_PPV_ARGS(&resource)),"CreateCommittedResource");
    return resource;
}
static ComPtr<ID3D12Resource> constant(ID3D12Device* device,const void* data,size_t bytes) {
    D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=(bytes+255)&~uint64_t(255);
    d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    auto result=make(device,d,D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    void* mapped=nullptr;D3D12_RANGE noRead{0,0};check(result->Map(0,&noRead,&mapped),"Constant Map");
    std::memcpy(mapped,data,bytes);D3D12_RANGE written{0,bytes};result->Unmap(0,&written);return result;
}
static void barrier(ID3D12GraphicsCommandList* list,ID3D12Resource* resource,
                    D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after) {
    if(before==after) return;
    D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};list->ResourceBarrier(1,&b);
}
struct FrameConstants { uint32_t dimensions[4];float key[4];float surfels[32][4]; };
static_assert(sizeof(FrameConstants)==544 && sizeof(BeamRTScene)==192,"GI compute ABI");
struct BeamRTGIFrame {
    std::mutex mutex;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12Resource> mesh,receivers,output,scene,frame;
    ComPtr<ID3D12DescriptorHeap> descriptors;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12Fence> fence;
    UINT stride=0,width=0,height=0;
    D3D12_RESOURCE_STATES meshState{},receiverState{};
    uint64_t completion=0;
    bool recorded=false,submitted=false,discarded=false;
};
static void texture(ID3D12Device* device,ID3D12Resource* resource,DXGI_FORMAT format,UINT width,UINT height) {
    owner(device,resource);const auto d=resource->GetDesc();
    require(d.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D && d.Format==format
        && d.Width==width && d.Height==height && d.DepthOrArraySize==1 && d.MipLevels==1
        && d.SampleDesc.Count==1 && d.SampleDesc.Quality==0 && !(d.Flags&D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE)
        && !(d.Flags&D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS),"unsupported full texture/view contract");
    D3D12_HEAP_PROPERTIES props{};D3D12_HEAP_FLAGS flags{};check(resource->GetHeapProperties(&props,&flags),"Texture heap");
    require(props.Type==D3D12_HEAP_TYPE_DEFAULT,"GPU default texture required");
}
static void sceneContract(const BeamRTScene& s) {
    require(s.atlas[0]>0 && s.atlas[0]<=16384 && s.atlas[1]>0 && s.atlas[1]<=16384,"mesh dimensions invalid");
    require(s.counts[0]>0 && s.counts[0]<=4096 && s.counts[1]>0 && s.counts[1]<=200000,"mesh traversal budget invalid");
    require(s.counts[2]==2+6*s.counts[0] && uint64_t(s.counts[2])+uint64_t(s.counts[1])*7<=uint64_t(s.atlas[0])*s.atlas[1],"packed layout invalid");
    require(s.counts[3]==0 && s.atlas[2]==0 && s.atlas[3]==0,"unsupported scene fields");
    const float* vectors[]={s.origin,s.inverseX,s.inverseY,s.inverseZ,s.quantMin,s.quantExtent};
    for(auto v:vectors) for(int i=0;i<4;++i) require(std::isfinite(v[i]),"nonfinite mesh transform");
    for(int i=0;i<3;++i) require(s.quantExtent[i]>0,"invalid quantization extent");
    const auto& x=s.inverseX;const auto& y=s.inverseY;const auto& z=s.inverseZ;
    const float det=x[0]*(y[1]*z[2]-y[2]*z[1])-x[1]*(y[0]*z[2]-y[2]*z[0])+x[2]*(y[0]*z[1]-y[1]*z[0]);
    require(std::isfinite(det) && std::abs(det)>1e-10f,"singular mesh transform");
    for(auto mode:s.materials) require(mode<=3,"unsupported material policy");
}
extern "C" uint32_t BeamRT_GIAbiVersion() { return 1; }
extern "C" const char* BeamRT_GILastError() { return lastError.c_str(); }
extern "C" int BeamRT_GICreateFrame(void* nativeDevice,const void* shader,uint64_t bytes,
    const BeamRTGIInputs* inputs,BeamRTGIFrame** output) {
    try {
        lastError.clear();require(output && !*output,"null frame output required");
        require(nativeDevice && shader && bytes>=4 && bytes<=16*1024*1024 && inputs,"verified host/device/shader/inputs required");
        const auto& p=*inputs;sceneContract(p.scene);
        require(p.width>0 && p.height>0 && p.width<=2048 && p.height<2048 && p.surfelCount<=32 && p.reserved==0,"invalid frame dimensions/count");
        // Bounded first integration only; no partial-coverage darkening on overflow.
        require(uint64_t(p.width)*p.height*(p.surfelCount?p.surfelCount:1)<=1048576,"first-integration pixel/surfel budget exceeded");
        for(int i=0;i<4;++i) require(std::isfinite(p.key[i]) && p.key[i]>=1 && p.key[i]<=16777215 && std::floor(p.key[i])==p.key[i],"invalid generation key");
        require(p.key[3]==1,"visibility layout version mismatch");
        for(UINT i=0;i<p.surfelCount;++i) {
            for(float value:p.surfels[i]) require(std::isfinite(value),"nonfinite surfel");
            require(p.surfels[i][3]>0,"surfel radius must be positive");
        }
        const UINT readBits=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
        require(p.meshState!=0 && !(p.meshState&~readBits),"mesh state must be a known shader-read state");
        require(p.receiverState==D3D12_RESOURCE_STATE_RENDER_TARGET
            || (p.receiverState!=0 && !(p.receiverState&~readBits)),"receiver state unsupported/unknown");
        auto f=std::make_unique<BeamRTGIFrame>();f->device=static_cast<ID3D12Device*>(nativeDevice);
        check(f->device->GetDeviceRemovedReason(),"DeviceRemovedReason");
        f->mesh=static_cast<ID3D12Resource*>(p.mesh);f->receivers=static_cast<ID3D12Resource*>(p.receivers);
        texture(f->device.Get(),f->mesh.Get(),DXGI_FORMAT_R8G8B8A8_UNORM,p.scene.atlas[0],p.scene.atlas[1]);
        texture(f->device.Get(),f->receivers.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT,p.width,p.height);
        f->width=p.width;f->height=p.height;f->meshState=static_cast<D3D12_RESOURCE_STATES>(p.meshState);
        f->receiverState=static_cast<D3D12_RESOURCE_STATES>(p.receiverState);
        D3D12_FEATURE_DATA_FORMAT_SUPPORT support{DXGI_FORMAT_R32G32B32A32_FLOAT};
        check(f->device->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&support,sizeof(support)),"Format support");
        require((support.Support1&D3D12_FORMAT_SUPPORT1_TEXTURE2D) && (support.Support1&D3D12_FORMAT_SUPPORT1_SHADER_LOAD)
            && (support.Support2&D3D12_FORMAT_SUPPORT2_UAV_TYPED_STORE),"float visibility format unsupported");
        auto d=f->receivers->GetDesc();d.Height+=1;d.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        f->output=make(f->device.Get(),d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        f->scene=constant(f->device.Get(),&p.scene,sizeof(p.scene));
        FrameConstants constants{};constants.dimensions[0]=p.width;constants.dimensions[1]=p.height;constants.dimensions[2]=p.surfelCount;
        std::memcpy(constants.key,p.key,sizeof(p.key));std::memcpy(constants.surfels,p.surfels,sizeof(p.surfels));
        f->frame=constant(f->device.Get(),&constants,sizeof(constants));
        D3D12_DESCRIPTOR_RANGE ranges[2]{};ranges[0].RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;ranges[0].NumDescriptors=2;
        ranges[1].RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_UAV;ranges[1].NumDescriptors=1;
        D3D12_ROOT_PARAMETER params[4]{};
        for(UINT i=0;i<2;++i) { params[i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;params[i].Descriptor.ShaderRegister=i; }
        for(UINT i=0;i<2;++i) { params[i+2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[i+2].DescriptorTable={1,&ranges[i]}; }
        D3D12_ROOT_SIGNATURE_DESC signature{};signature.NumParameters=4;signature.pParameters=params;
        ComPtr<ID3DBlob> encoded,errors;check(D3D12SerializeRootSignature(&signature,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors),"SerializeRootSignature");
        check(f->device->CreateRootSignature(0,encoded->GetBufferPointer(),encoded->GetBufferSize(),IID_PPV_ARGS(&f->root)),"CreateRootSignature");
        D3D12_COMPUTE_PIPELINE_STATE_DESC pipeline{};pipeline.pRootSignature=f->root.Get();pipeline.CS={shader,static_cast<SIZE_T>(bytes)};
        check(f->device->CreateComputePipelineState(&pipeline,IID_PPV_ARGS(&f->pipeline)),"CreateComputePipelineState");
        D3D12_DESCRIPTOR_HEAP_DESC heap{};heap.NumDescriptors=4;heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        check(f->device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&f->descriptors)),"CreateDescriptorHeap");
        f->stride=f->device->GetDescriptorHandleIncrementSize(heap.Type);
        auto cpu=f->descriptors->GetCPUDescriptorHandleForHeapStart();
        D3D12_SHADER_RESOURCE_VIEW_DESC srv{};srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;srv.Texture2D.MipLevels=1;
        srv.Format=DXGI_FORMAT_R8G8B8A8_UNORM;f->device->CreateShaderResourceView(f->mesh.Get(),&srv,cpu);cpu.ptr+=f->stride;
        srv.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;f->device->CreateShaderResourceView(f->receivers.Get(),&srv,cpu);cpu.ptr+=f->stride;
        D3D12_UNORDERED_ACCESS_VIEW_DESC uav{};uav.Format=srv.Format;uav.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2D;
        f->device->CreateUnorderedAccessView(f->output.Get(),nullptr,&uav,cpu);cpu.ptr+=f->stride;
        f->device->CreateShaderResourceView(f->output.Get(),&srv,cpu);
        *output=f.release();return 0;
    } catch(const std::exception& e) { lastError=e.what();return -1; }
}
extern "C" int BeamRT_GIRecord(BeamRTGIFrame* f,void* commands) {
    try {
        lastError.clear();require(f && commands,"frame and dedicated native command list required");std::lock_guard<std::mutex> lock(f->mutex);
        require(!f->recorded && !f->discarded,"frame already recorded/discarded");check(f->device->GetDeviceRemovedReason(),"DeviceRemovedReason");
        auto list=static_cast<ID3D12GraphicsCommandList*>(commands);owner(f->device.Get(),list);
        require(list->GetType()==D3D12_COMMAND_LIST_TYPE_DIRECT,"dedicated DIRECT command list required");
        // All failure-prone validation precedes any modification of the list.
        f->recorded=true;
        barrier(list,f->mesh.Get(),f->meshState,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        barrier(list,f->receivers.Get(),f->receiverState,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        ID3D12DescriptorHeap* heaps[]={f->descriptors.Get()};list->SetDescriptorHeaps(1,heaps);
        list->SetPipelineState(f->pipeline.Get());list->SetComputeRootSignature(f->root.Get());
        list->SetComputeRootConstantBufferView(0,f->scene->GetGPUVirtualAddress());list->SetComputeRootConstantBufferView(1,f->frame->GetGPUVirtualAddress());
        auto gpu=f->descriptors->GetGPUDescriptorHandleForHeapStart();list->SetComputeRootDescriptorTable(2,gpu);gpu.ptr+=2*f->stride;
        list->SetComputeRootDescriptorTable(3,gpu);list->Dispatch((f->width+7)/8,(f->height+8)/8,1);
        barrier(list,f->output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        barrier(list,f->receivers.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,f->receiverState);
        barrier(list,f->mesh.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,f->meshState);return 0;
    } catch(const std::exception& e) { lastError=e.what();return -1; }
}
extern "C" int BeamRT_GIGetOutput(BeamRTGIFrame* f,void** resource,uint64_t* cpuSrv) {
    try {
        lastError.clear();require(resource && cpuSrv,"resource and descriptor outputs required");*resource=nullptr;*cpuSrv=0;
        require(f,"frame required");std::lock_guard<std::mutex> lock(f->mutex);require(f->recorded && !f->discarded,"output not recorded/was discarded");
        check(f->device->GetDeviceRemovedReason(),"DeviceRemovedReason");
        *resource=f->output.Get();*cpuSrv=f->descriptors->GetCPUDescriptorHandleForHeapStart().ptr+3*uint64_t(f->stride);return 0;
    } catch(const std::exception& e) { lastError=e.what();return -1; }
}
extern "C" int BeamRT_GIMarkSubmitted(BeamRTGIFrame* f,void* nativeFence,uint64_t value) {
    try {
        lastError.clear();require(f && nativeFence && value>0 && value!=UINT64_MAX,"valid post-consumer fence/value required");
        std::lock_guard<std::mutex> lock(f->mutex);require(f->recorded && !f->submitted && !f->discarded,"submission state invalid");
        check(f->device->GetDeviceRemovedReason(),"DeviceRemovedReason");auto fence=static_cast<ID3D12Fence*>(nativeFence);owner(f->device.Get(),fence);
        f->fence=fence;f->completion=value;f->submitted=true;return 0;
    } catch(const std::exception& e) { lastError=e.what();return -1; }
}
extern "C" int BeamRT_GIDiscardRecorded(BeamRTGIFrame* f,uint32_t confirmed) {
    try {
        lastError.clear();require(f && confirmed==1,"explicit unexecuted-list discard confirmation required");
        std::lock_guard<std::mutex> lock(f->mutex);require(f->recorded && !f->submitted && !f->discarded,"cannot discard submitted/unused frame");
        f->discarded=true;return 0;
    } catch(const std::exception& e) { lastError=e.what();return -1; }
}
extern "C" int BeamRT_GIDestroyFrame(BeamRTGIFrame** frame) {
    try {
        lastError.clear();require(frame,"frame pointer required");if(!*frame) return 0;auto f=*frame;
        { std::lock_guard<std::mutex> lock(f->mutex);
          if(SUCCEEDED(f->device->GetDeviceRemovedReason()) && f->recorded && !f->discarded) {
              require(f->submitted,"unmarked recorded work retained until submission fence or proven discard");
              const UINT64 done=f->fence->GetCompletedValue();require(done!=UINT64_MAX && done>=f->completion,"GPU frame still in flight; retained");
          } }
        delete f;*frame=nullptr;return 0;
    } catch(const std::exception& e) { lastError=e.what();return -1; }
}
