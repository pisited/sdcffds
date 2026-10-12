#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "beamrt_gi.h"
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
using Microsoft::WRL::ComPtr;
static void require(bool ok,const char* why) { if(!ok) throw std::runtime_error(why); }
static void hr(HRESULT value) { require(SUCCEEDED(value),"D3D12 fixture operation failed"); }
static void success(int value) { require(value==0,BeamRT_GILastError()); }
static void read(std::ifstream& stream,void* output,size_t bytes) { stream.read(static_cast<char*>(output),static_cast<std::streamsize>(bytes));require(bool(stream),"truncated fixture"); }
static std::vector<uint8_t> file(const wchar_t* path) {
    std::ifstream stream(std::filesystem::path(path),std::ios::binary|std::ios::ate);require(bool(stream),"file missing");
    auto size=stream.tellg();require(size>0 && size<=16*1024*1024,"file size invalid");
    std::vector<uint8_t> data(static_cast<size_t>(size));stream.seekg(0);read(stream,data.data(),data.size());return data;
}
static void transition(ID3D12GraphicsCommandList* list,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};list->ResourceBarrier(1,&b);
}
static ComPtr<ID3D12Resource> make(ID3D12Device* device,D3D12_RESOURCE_DESC desc,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES props{};props.Type=type;ComPtr<ID3D12Resource> result;
    hr(device->CreateCommittedResource(&props,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,IID_PPV_ARGS(&result)));return result;
}
static D3D12_RESOURCE_DESC buffer(UINT64 bytes) {
    D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;return d;
}
static void fill(ID3D12Resource* resource,const void* data,size_t bytes) {
    void* mapped=nullptr;D3D12_RANGE noRead{0,0};hr(resource->Map(0,&noRead,&mapped));std::memcpy(mapped,data,bytes);resource->Unmap(0,nullptr);
}
struct Host {
    ComPtr<ID3D12Device> device;ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;UINT64 sequence=0;
    std::vector<ComPtr<ID3D12Resource>> staging;
    explicit Host(ID3D12Device* native):device(native) {
        D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;hr(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));
        hr(device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)));hr(device->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&list)));
        hr(list->Close());hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));
    }
    void begin() { hr(allocator->Reset());hr(list->Reset(allocator.Get(),nullptr)); }
    void execute() { hr(list->Close());ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists); }
    void wait() {
        hr(queue->Signal(fence.Get(),++sequence));HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);require(event!=nullptr,"event creation failed");
        hr(fence->SetEventOnCompletion(sequence,event));const DWORD result=WaitForSingleObject(event,10000);CloseHandle(event);
        require(result==WAIT_OBJECT_0,"GPU test timeout; stop test process, not frame retirement proof");hr(device->GetDeviceRemovedReason());staging.clear();
    }
    ComPtr<ID3D12Resource> texture(UINT width,UINT height,DXGI_FORMAT format,const void* pixels,UINT pixelBytes) {
        D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=width;d.Height=height;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Format=format;
        auto result=make(device.Get(),d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;
        device->GetCopyableFootprints(&d,0,1,0,&footprint,&rows,&rowBytes,&total);
        require(rowBytes==uint64_t(width)*pixelBytes,"fixture pixel format mismatch");
        auto upload=make(device.Get(),buffer(total),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        void* mapped;D3D12_RANGE noRead{0,0};hr(upload->Map(0,&noRead,&mapped));
        for(UINT y=0;y<rows;++y) std::memcpy(static_cast<uint8_t*>(mapped)+footprint.Offset+uint64_t(y)*footprint.Footprint.RowPitch,static_cast<const uint8_t*>(pixels)+uint64_t(y)*rowBytes,static_cast<size_t>(rowBytes));
        upload->Unmap(0,nullptr);D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=result.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src.pResource=upload.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=footprint;
        list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(list.Get(),result.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        staging.push_back(upload);return result;
    }
};
struct TestConstants { float key[4],size[2],enabled;int32_t index;float viewport[4]; };
static_assert(sizeof(TestConstants)==48,"consumer test ABI");
static void draw(Host& host,BeamRTGIFrame* frame,const std::vector<uint8_t>& vs,const std::vector<uint8_t>& ps,
                 TestConstants constants,bool blocked) {
    void* nativeOutput=nullptr;uint64_t outputSrv=0;success(BeamRT_GIGetOutput(frame,&nativeOutput,&outputSrv));
    auto device=host.device.Get();D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=1;range.BaseShaderRegister=5;
    D3D12_ROOT_PARAMETER params[2]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[1].DescriptorTable={1,&range};
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=2;desc.pParameters=params;
    ComPtr<ID3DBlob> encoded,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors));
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,encoded->GetBufferPointer(),encoded->GetBufferSize(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root.Get();p.VS={vs.data(),vs.size()};p.PS={ps.data(),ps.size()};
    p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;p.RasterizerState.DepthClipEnable=TRUE;
    p.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;p.SampleMask=UINT_MAX;
    p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;p.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&pipeline)));
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=2;targetDesc.Height=1;targetDesc.DepthOrArraySize=1;targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;
    targetDesc.Format=p.RTVFormats[0];targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=make(device,targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    auto cb=make(device,buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);fill(cb.Get(),&constants,sizeof(constants));
    D3D12_DESCRIPTOR_HEAP_DESC h{};h.NumDescriptors=1;h.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;ComPtr<ID3D12DescriptorHeap> rtv;hr(device->CreateDescriptorHeap(&h,IID_PPV_ARGS(&rtv)));
    device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
    h.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;h.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;ComPtr<ID3D12DescriptorHeap> srv;hr(device->CreateDescriptorHeap(&h,IID_PPV_ARGS(&srv)));
    device->CopyDescriptorsSimple(1,srv->GetCPUDescriptorHandleForHeapStart(),D3D12_CPU_DESCRIPTOR_HANDLE{outputSrv},h.Type);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;device->GetCopyableFootprints(&targetDesc,0,1,0,&footprint,&rows,&rowBytes,&total);
    auto readback=make(device,buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    host.begin();host.list->SetPipelineState(pipeline.Get());host.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={srv.Get()};host.list->SetDescriptorHeaps(1,heaps);
    host.list->SetGraphicsRootConstantBufferView(0,cb->GetGPUVirtualAddress());host.list->SetGraphicsRootDescriptorTable(1,srv->GetGPUDescriptorHandleForHeapStart());
    const D3D12_VIEWPORT viewport{0,0,2,1,0,1};const D3D12_RECT scissor{0,0,2,1};host.list->RSSetViewports(1,&viewport);host.list->RSSetScissorRects(1,&scissor);
    auto cpu=rtv->GetCPUDescriptorHandleForHeapStart();host.list->OMSetRenderTargets(1,&cpu,FALSE,nullptr);host.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);host.list->DrawInstanced(3,1,0,0);
    transition(host.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
    src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;host.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);host.execute();host.wait();
    void* mapped=nullptr;D3D12_RANGE readRange{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&readRange,&mapped));
    const auto values=reinterpret_cast<const float*>(static_cast<const uint8_t*>(mapped)+footprint.Offset);
    for(int pixel=0;pixel<2;++pixel) for(int channel=0;channel<3;++channel) {
        const float expected=.2f+.1f*static_cast<float>(channel)+((pixel==0 && blocked)?0.0f:1.0f+static_cast<float>(channel));
        require(std::abs(values[pixel*4+channel]-expected)<.00001f,"native visibility consumer changed wrong GI contribution or failed fallback");
    }
    D3D12_RANGE noWrite{0,0};readback->Unmap(0,&noWrite);
}
int wmain(int argc,wchar_t** argv) {
    try {
        require(argc==5 || argc==6,"usage: self_test fixture.bin visibility.cso consumer.vs.cso consumer.ps.cso [--warp]");
        const bool warp=argc==6 && std::wstring(argv[5])==L"--warp";require(argc!=6 || warp,"unknown option");
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled) debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp) { ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP offline GI resource host\n"; }
        else for(UINT i=0;!device;++i) { ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware device unavailable");DXGI_ADAPTER_DESC1 d{};hr(adapter->GetDesc1(&d));if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)))) std::wcout<<L"Offline GI host: "<<d.Description<<L'\n'; }
        Host host(device.Get());auto cs=file(argv[2]),vs=file(argv[3]),ps=file(argv[4]);
        std::ifstream stream(std::filesystem::path(argv[1]),std::ios::binary);require(bool(stream),"fixture missing");uint32_t header[4];read(stream,header,sizeof(header));
        require(header[0]==0x42525431 && header[1]>0 && header[1]<=16*1024*1024 && header[2]>0 && header[2]<=8192,"invalid fixture header");
        BeamRTGIInputs inputs{};read(stream,&inputs.scene,sizeof(inputs.scene));std::vector<uint8_t> pixels(header[1]);read(stream,pixels.data(),pixels.size());
        std::vector<BeamRTRay> rays(header[2]);read(stream,rays.data(),rays.size()*sizeof(BeamRTRay));std::vector<int32_t> expected(rays.size());read(stream,expected.data(),expected.size()*sizeof(int32_t));
        size_t hit=0;while(hit<expected.size() && expected[hit]!=2) ++hit;require(hit<rays.size(),"fixture needs opaque hit");
        float receivers[2][4]{};for(int a=0;a<3;++a) { receivers[0][a]=rays[hit].origin[a];receivers[1][a]=rays[hit].origin[a]+rays[hit].direction[a]*rays[hit].reach; }
        receivers[0][3]=receivers[1][3]=1;
        inputs.width=2;inputs.height=1;inputs.surfelCount=32;inputs.meshState=inputs.receiverState=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
        inputs.key[0]=17;inputs.key[1]=23;inputs.key[2]=31;inputs.key[3]=1;
        for(auto& surfel:inputs.surfels) { for(int a=0;a<3;++a) surfel[a]=receivers[1][a];surfel[3]=1; }
        for(auto& mode:inputs.scene.materials) mode=1;
        host.begin();auto mesh=host.texture(inputs.scene.atlas[0],inputs.scene.atlas[1],DXGI_FORMAT_R8G8B8A8_UNORM,pixels.data(),4);
        auto receiver=host.texture(2,1,DXGI_FORMAT_R32G32B32A32_FLOAT,receivers,16);host.execute();host.wait();inputs.mesh=mesh.Get();inputs.receivers=receiver.Get();
        require(BeamRT_GIAbiVersion()==1,"GI ABI mismatch");
        BeamRTGIFrame* frame=nullptr;auto create=[&](const BeamRTGIInputs& p) { return BeamRT_GICreateFrame(device.Get(),cs.data(),cs.size(),&p,&frame); };
        auto bad=inputs;bad.key[0]=0;require(create(bad)!=0 && !frame,"zero generation accepted");bad=inputs;bad.key[2]=.5f;require(create(bad)!=0 && !frame,"fractional generation accepted");
        bad=inputs;bad.width=3;require(create(bad)!=0 && !frame,"wrong view dimensions accepted");bad=inputs;bad.receiverState=0;require(create(bad)!=0 && !frame,"unknown state accepted");
        bad=inputs;bad.surfelCount=33;require(create(bad)!=0 && !frame,"surfel overflow accepted");bad=inputs;bad.scene.inverseX[0]=0;require(create(bad)!=0 && !frame,"singular transform accepted");
        bad=inputs;bad.surfels[0][0]=std::numeric_limits<float>::quiet_NaN();require(create(bad)!=0 && !frame,"nonfinite surfel accepted");
        if(!warp) {
            ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));ComPtr<ID3D12Device> foreign;hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&foreign)));
            D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=2;d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
            auto foreignReceiver=make(foreign.Get(),d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            bad=inputs;bad.receivers=foreignReceiver.Get();require(create(bad)!=0 && !frame,"foreign resource accepted");
        }
        success(create(inputs));void* resource=nullptr;uint64_t srv=0;require(BeamRT_GIGetOutput(frame,&resource,&srv)!=0 && !resource && !srv,"unrecorded output published");
        ComPtr<ID3D12CommandAllocator> computeAllocator;ComPtr<ID3D12GraphicsCommandList> computeList;
        hr(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_COMPUTE,IID_PPV_ARGS(&computeAllocator)));
        hr(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_COMPUTE,computeAllocator.Get(),nullptr,IID_PPV_ARGS(&computeList)));
        require(BeamRT_GIRecord(frame,computeList.Get())!=0,"non-DIRECT list accepted");hr(computeList->Close());
        host.begin();success(BeamRT_GIRecord(frame,host.list.Get()));require(BeamRT_GIRecord(frame,host.list.Get())!=0,"frame recorded twice");require(BeamRT_GIDestroyFrame(&frame)!=0 && frame,"unmarked work freed");
        ComPtr<ID3D12Fence> lifetime;hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&lifetime)));
        success(BeamRT_GIMarkSubmitted(frame,lifetime.Get(),1));require(BeamRT_GIDestroyFrame(&frame)!=0 && frame,"in-flight frame freed");host.execute();host.wait();
        TestConstants c{};std::memcpy(c.key,inputs.key,sizeof(c.key));c.size[0]=2;c.size[1]=1;c.enabled=1;c.index=31;c.viewport[2]=c.viewport[3]=1;
        for(int index:{0,7,8,15,16,23,24,31}) { c.index=index;draw(host,frame,vs,ps,c,true); }
        c.enabled=0;draw(host,frame,vs,ps,c,false);c.enabled=1;draw(host,frame,vs,ps,c,true);c.enabled=0;draw(host,frame,vs,ps,c,false);c.enabled=1;
        c.enabled=std::numeric_limits<float>::quiet_NaN();draw(host,frame,vs,ps,c,false);c.enabled=1;
        for(int i=0;i<3;++i) { c.key[i]+=1;draw(host,frame,vs,ps,c,false);c.key[i]-=1; }
        c.size[0]=3;draw(host,frame,vs,ps,c,false);c.size[0]=2;c.index=32;draw(host,frame,vs,ps,c,false);c.index=31;
        c.viewport[0]=c.viewport[1]=.25f;c.viewport[2]=c.viewport[3]=.5f;draw(host,frame,vs,ps,c,true);
        c.index=-1;draw(host,frame,vs,ps,c,false);c.index=31;c.key[0]=std::numeric_limits<float>::quiet_NaN();draw(host,frame,vs,ps,c,false);c.key[0]=inputs.key[0];
        require(BeamRT_GIDestroyFrame(&frame)!=0 && frame,"compute completion incorrectly retired a consumer-live frame");
        hr(host.queue->Signal(lifetime.Get(),1));host.wait(); // AFTER the LAST consumer
        success(BeamRT_GIDestroyFrame(&frame));
        UINT64 completion=1;
        auto fallback=[&]() {
            success(create(inputs));host.begin();success(BeamRT_GIRecord(frame,host.list.Get()));success(BeamRT_GIMarkSubmitted(frame,lifetime.Get(),++completion));host.execute();host.wait();
            draw(host,frame,vs,ps,c,false);hr(host.queue->Signal(lifetime.Get(),completion));host.wait();success(BeamRT_GIDestroyFrame(&frame));
        };
        for(uint32_t mode:{0u,2u,3u}) { for(auto& policy:inputs.scene.materials) policy=mode;fallback(); }
        for(auto& mode:inputs.scene.materials) mode=1;
        receivers[0][3]=0;host.begin();auto invalidReceiver=host.texture(2,1,DXGI_FORMAT_R32G32B32A32_FLOAT,receivers,16);host.execute();host.wait();inputs.receivers=invalidReceiver.Get();fallback();inputs.receivers=receiver.Get();
        auto invalidPixels=pixels;invalidPixels[0]=0;host.begin();auto invalidMesh=host.texture(inputs.scene.atlas[0],inputs.scene.atlas[1],DXGI_FORMAT_R8G8B8A8_UNORM,invalidPixels.data(),4);host.execute();host.wait();inputs.mesh=invalidMesh.Get();fallback();inputs.mesh=mesh.Get();
        success(create(inputs));host.begin();success(BeamRT_GIRecord(frame,host.list.Get()));hr(host.list->Close());host.begin();hr(host.list->Close());
        require(BeamRT_GIDiscardRecorded(frame,0)!=0,"unconfirmed discard accepted");success(BeamRT_GIDiscardRecorded(frame,1));success(BeamRT_GIDestroyFrame(&frame));
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages))) for(UINT64 i=0;i<messages->GetNumStoredMessages();++i) { SIZE_T bytes=0;hr(messages->GetMessage(i,nullptr,&bytes));std::vector<uint8_t> storage(bytes);auto message=reinterpret_cast<D3D12_MESSAGE*>(storage.data());hr(messages->GetMessage(i,message,&bytes));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription); }
        std::cout<<"PASS: GPU producer -> exact GI visibility predicate; opaque-only, 32 bits, OFF/ON/OFF, stale keys/dimensions, viewport mapping, lifetime/discard guards\n";
        std::cout<<"Debug layer: "<<(debugEnabled?"enabled":"unavailable; not debug-clean proof")<<". No BeamNG resources or game attachment.\n";return 0;
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n';return 1; }
}
