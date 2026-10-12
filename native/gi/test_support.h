#pragma once
// Shared OFFLINE test helpers, not renderer or game integration code.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "beamrt_gi.h"
#include "../capture/beamrt_capture.h"
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <d3dcompiler.h>
#include <d3d11shader.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
static void require(bool ok,const char* why) { if(!ok) throw std::runtime_error(why); }
static void hr(HRESULT value,const char* operation="D3D12 fixture operation") {
    if(FAILED(value)) throw std::runtime_error(std::string(operation)+" failed HRESULT="+std::to_string(value));
}
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
// Execute the actual game pixel producer, using reflection rather than guessed
// engine constant offsets. Only offline fixture inputs, never game resources.
struct PixelOutput { ComPtr<ID3D12Resource> resource;ComPtr<ID3D12DescriptorHeap> srv,copySource; };
inline PixelOutput pixelProducer(Host& host,const BeamRTGIInputs& input,
    const std::vector<uint8_t>& vs,const std::vector<uint8_t>& ps) {
    ComPtr<ID3D11ShaderReflection> reflection;hr(D3DReflect(ps.data(),ps.size(),IID_PPV_ARGS(&reflection)),"pixel producer reflection");
    auto fields=reflection->GetConstantBufferByName("perDraw");D3D11_SHADER_BUFFER_DESC cbDesc{};hr(fields->GetDesc(&cbDesc),"pixel producer perDraw");
    std::vector<uint8_t> constants((cbDesc.Size+255)&~size_t(255));
    auto set=[&](const char* name,const void* data,size_t bytes) { D3D11_SHADER_VARIABLE_DESC v{};hr(fields->GetVariableByName(name)->GetDesc(&v),name);
        require(bytes<=v.Size && uint64_t(v.StartOffset)+bytes<=constants.size(),"pixel constant layout mismatch");std::memcpy(constants.data()+v.StartOffset,data,bytes); };
    const auto& scene=input.scene;
    set("meshOrigin",scene.origin,12);set("meshInvX",scene.inverseX,12);set("meshInvY",scene.inverseY,12);set("meshInvZ",scene.inverseZ,12);
    set("meshQuantMin",scene.quantMin,12);set("meshQuantExtent",scene.quantExtent,12);
    auto scalar=[&](const char* name,float value) { set(name,&value,4); };
    scalar("meshNodeCount",static_cast<float>(scene.counts[0]));scalar("meshTriangleCount",static_cast<float>(scene.counts[1]));scalar("meshTriangleOffset",static_cast<float>(scene.counts[2]));scalar("meshMaterialPolicyEnabled",1);
    float atlas[]={static_cast<float>(scene.atlas[0]),static_cast<float>(scene.atlas[1])};set("meshAtlasSize",atlas,sizeof(atlas));
    float modes[16];for(int i=0;i<16;++i) modes[i]=static_cast<float>(scene.materials[i]);
    for(int bank=0;bank<4;++bank) { const auto name="meshMaterialModes"+std::to_string(bank);set(name.c_str(),modes+bank*4,16); }
    float size[]={static_cast<float>(input.width),static_cast<float>(input.height)};set("visibilitySize",size,sizeof(size));set("nativeGIVisibilityKey",input.key,sizeof(input.key));scalar("surfelCount",static_cast<float>(input.surfelCount));
    for(int i=0;i<32;++i) { const auto name="surfelPositionRadius"+std::to_string(i);set(name.c_str(),input.surfels[i],16); }
    auto device=host.device.Get();auto cb=make(device,buffer(constants.size()),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);fill(cb.Get(),constants.data(),constants.size());
    D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=2;
    D3D12_ROOT_PARAMETER params[2]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[1].DescriptorTable={1,&range};
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=2;desc.pParameters=params;ComPtr<ID3DBlob> encoded,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors));
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,encoded->GetBufferPointer(),encoded->GetBufferSize(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root.Get();p.VS={vs.data(),vs.size()};p.PS={ps.data(),ps.size()};p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;p.RasterizerState.DepthClipEnable=TRUE;
    p.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;p.SampleMask=UINT_MAX;p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;p.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&pipeline)),"pixel producer pipeline");
    auto targetDesc=static_cast<ID3D12Resource*>(input.receivers)->GetDesc();targetDesc.Height+=1;targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    PixelOutput output;output.resource=make(device,targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    D3D12_DESCRIPTOR_HEAP_DESC heap{};heap.NumDescriptors=1;heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;ComPtr<ID3D12DescriptorHeap> rtv;hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&rtv)));device->CreateRenderTargetView(output.resource.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
    heap.NumDescriptors=3;heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&output.srv)));
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{};srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;srv.Texture2D.MipLevels=1;srv.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    auto cpu=output.srv->GetCPUDescriptorHandleForHeapStart();const auto stride=device->GetDescriptorHandleIncrementSize(heap.Type);
    device->CreateShaderResourceView(static_cast<ID3D12Resource*>(input.receivers),&srv,cpu);cpu.ptr+=stride;srv.Format=DXGI_FORMAT_R8G8B8A8_UNORM;device->CreateShaderResourceView(static_cast<ID3D12Resource*>(input.mesh),&srv,cpu);
    heap.NumDescriptors=1;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&output.copySource)));
    srv.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    device->CreateShaderResourceView(output.resource.Get(),&srv,output.copySource->GetCPUDescriptorHandleForHeapStart());
    host.begin();host.list->SetPipelineState(pipeline.Get());host.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={output.srv.Get()};host.list->SetDescriptorHeaps(1,heaps);host.list->SetGraphicsRootConstantBufferView(0,cb->GetGPUVirtualAddress());host.list->SetGraphicsRootDescriptorTable(1,output.srv->GetGPUDescriptorHandleForHeapStart());
    const D3D12_VIEWPORT viewport{0,0,static_cast<float>(input.width),static_cast<float>(input.height+1),0,1};const D3D12_RECT scissor{0,0,static_cast<LONG>(input.width),static_cast<LONG>(input.height+1)};
    host.list->RSSetViewports(1,&viewport);host.list->RSSetScissorRects(1,&scissor);cpu=rtv->GetCPUDescriptorHandleForHeapStart();host.list->OMSetRenderTargets(1,&cpu,FALSE,nullptr);host.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);host.list->DrawInstanced(3,1,0,0);
    transition(host.list.Get(),output.resource.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);host.execute();host.wait();return output;
}
static void draw(Host& host,BeamRTGIFrame* frame,const std::vector<uint8_t>& vs,const std::vector<uint8_t>& ps,
                 TestConstants constants,bool blocked,uint64_t outputSrv=0) {
    void* nativeOutput=nullptr;if(!outputSrv) success(BeamRT_GIGetOutput(frame,&nativeOutput,&outputSrv));
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
static void captureSuccess(int result) {
    // The API call must finish before retrieving its thread-local error text.
    // Inline require(API(...), LastError()) has unspecified argument order.
    require(result==0,BeamRT_CaptureLastError());
}
struct CaptureSession {
    BeamRTCapture* value=nullptr;
    ~CaptureSession() { if(value && BeamRT_CaptureStop(&value,1)!=0) std::cerr<<"Capture host retained: "<<BeamRT_CaptureLastError()<<'\n'; }
    void stop() { const int result=BeamRT_CaptureStop(&value,1);require(result==0,BeamRT_CaptureLastError()); }
};
struct CaptureSnapshotOwner {
    BeamRTCaptureSnapshot* value=nullptr;
    ~CaptureSnapshotOwner() { BeamRT_CaptureReleaseSnapshot(&value); }
};
struct GIFrameOwner {
    BeamRTGIFrame* value=nullptr;
    ~GIFrameOwner() { if(value && BeamRT_GIDestroyFrame(&value)!=0) std::cerr<<"GI frame retained: "<<BeamRT_GILastError()<<'\n'; }
};
static ComPtr<ID3DBlob> handoffRootSignature() {
    D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=2;
    D3D12_ROOT_PARAMETER parameter{};parameter.ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameter.DescriptorTable={1,&range};D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=1;desc.pParameters=&parameter;
    ComPtr<ID3DBlob> encoded,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors));return encoded;
}
static void drawHandoffProducer(Host& host,const BeamRTGIInputs& inputs,
    const std::vector<uint8_t>& vs,const std::vector<uint8_t>& ps,ID3DBlob* rootBytes) {
    auto device=host.device.Get();
    ComPtr<ID3D12RootSignature> root;
    hr(device->CreateRootSignature(0,rootBytes->GetBufferPointer(),rootBytes->GetBufferSize(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipelineDesc{};pipelineDesc.pRootSignature=root.Get();
    pipelineDesc.VS={vs.data(),vs.size()};pipelineDesc.PS={ps.data(),ps.size()};
    pipelineDesc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pipelineDesc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;
    pipelineDesc.RasterizerState.DepthClipEnable=TRUE;pipelineDesc.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    pipelineDesc.SampleMask=UINT_MAX;pipelineDesc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pipelineDesc.NumRenderTargets=1;pipelineDesc.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;pipelineDesc.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&pipelineDesc,IID_PPV_ARGS(&pipeline)));
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=1;targetDesc.Height=1;
    targetDesc.DepthOrArraySize=1;targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;targetDesc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=make(device,targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    D3D12_DESCRIPTOR_HEAP_DESC rtvDesc{};rtvDesc.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;rtvDesc.NumDescriptors=1;
    ComPtr<ID3D12DescriptorHeap> rtv;hr(device->CreateDescriptorHeap(&rtvDesc,IID_PPV_ARGS(&rtv)));
    device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
    D3D12_DESCRIPTOR_HEAP_DESC heapDesc{};heapDesc.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heapDesc.NumDescriptors=2;
    ComPtr<ID3D12DescriptorHeap> cpu,gpu;hr(device->CreateDescriptorHeap(&heapDesc,IID_PPV_ARGS(&cpu)));
    heapDesc.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;hr(device->CreateDescriptorHeap(&heapDesc,IID_PPV_ARGS(&gpu)));
    const UINT stride=device->GetDescriptorHandleIncrementSize(heapDesc.Type);
    auto receiverHandle=cpu->GetCPUDescriptorHandleForHeapStart();
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{};srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;srv.Texture2D.MipLevels=1;
    srv.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;device->CreateShaderResourceView(static_cast<ID3D12Resource*>(inputs.receivers),&srv,receiverHandle);
    auto meshHandle=receiverHandle;meshHandle.ptr+=stride;srv.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
    device->CreateShaderResourceView(static_cast<ID3D12Resource*>(inputs.mesh),&srv,meshHandle);
    device->CopyDescriptorsSimple(2,gpu->GetCPUDescriptorHandleForHeapStart(),receiverHandle,heapDesc.Type);
    host.begin();auto list=host.list.Get();list->SetPipelineState(pipeline.Get());list->SetGraphicsRootSignature(root.Get());
    ID3D12DescriptorHeap* heaps[]={gpu.Get()};list->SetDescriptorHeaps(1,heaps);
    list->SetGraphicsRootDescriptorTable(0,gpu->GetGPUDescriptorHandleForHeapStart());
    const D3D12_VIEWPORT viewport{0,0,1,1,0,1};const D3D12_RECT scissor{0,0,1,1};
    list->RSSetViewports(1,&viewport);list->RSSetScissorRects(1,&scissor);
    auto renderTarget=rtv->GetCPUDescriptorHandleForHeapStart();list->OMSetRenderTargets(1,&renderTarget,FALSE,nullptr);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);list->DrawInstanced(3,1,0,0);
    host.execute();host.wait();
}
static void testCaptureToGIHandoff(ID3D12Device* device,const std::vector<uint8_t>& computeShader,
    const BeamRTGIInputs& sidecar,const std::vector<uint8_t>& handoffVS,
    const std::vector<uint8_t>& handoffPS,const std::vector<uint8_t>& consumerVS,
    const std::vector<uint8_t>& consumerPS) {
    auto rootBytes=handoffRootSignature();BeamRTCaptureConfig config{};
    config.shader=handoffPS.data();config.shaderBytes=handoffPS.size();
    config.rootSignature=rootBytes->GetBufferPointer();config.rootSignatureBytes=rootBytes->GetBufferSize();
    config.kind=1;config.tableParameter=0;config.inputCount=2;
    config.offsets[0]=0;config.offsets[1]=1;
    config.formats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;config.formats[1]=DXGI_FORMAT_R8G8B8A8_UNORM;
    config.dimensions[0]=config.dimensions[1]=D3D12_SRV_DIMENSION_TEXTURE2D;
    CaptureSession capture;captureSuccess(BeamRT_CaptureStart(device,&config,1,&capture.value));
    Host handoffHost(device);
    drawHandoffProducer(handoffHost,sidecar,handoffVS,handoffPS,rootBytes.Get());
    CaptureSnapshotOwner snapshot;const int captured=BeamRT_CaptureGetSnapshotForQueue(capture.value,handoffHost.queue.Get(),&snapshot.value);
    require(captured==0,BeamRT_CaptureLastError());BeamRTCaptureInfo info{};
    captureSuccess(BeamRT_CaptureReadSnapshot(snapshot.value,&info));
    require(info.kind==1 && info.count==2 && info.submission>0 && info.queue==handoffHost.queue.Get(),
            "handoff captured the wrong producer queue/submission");
    require(info.resources[0]==sidecar.receivers && info.resources[1]==sidecar.mesh
        && info.views[0].Format==config.formats[0] && info.views[1].Format==config.formats[1],
        "captured producer SRVs do not match receiver/mesh resources");
    require(!info.cameraVerified && !info.gpuOrderingVerified && !info.lightingConsumed,
            "fixture handoff incorrectly certified game-resource coverage");

    // These values are explicitly supplied by the offline fixture, not inferred
    // from the SRV capture: states, dimensions, scene, generations and surfels.
    BeamRTGIInputs frameInputs{};frameInputs.receivers=info.resources[0];frameInputs.mesh=info.resources[1];
    frameInputs.receiverState=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    frameInputs.meshState=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    frameInputs.scene=sidecar.scene;frameInputs.width=sidecar.width;frameInputs.height=sidecar.height;
    frameInputs.surfelCount=sidecar.surfelCount;std::memcpy(frameInputs.key,sidecar.key,sizeof(frameInputs.key));
    std::memcpy(frameInputs.surfels,sidecar.surfels,sizeof(frameInputs.surfels));
    capture.stop();

    GIFrameOwner frame;success(BeamRT_GICreateFrame(device,computeShader.data(),computeShader.size(),&frameInputs,&frame.value));
    BeamRT_CaptureReleaseSnapshot(&snapshot.value);
    {
        handoffHost.begin();
        success(BeamRT_GIRecord(frame.value,handoffHost.list.Get()));
        const UINT64 completion=handoffHost.sequence+2;
        success(BeamRT_GIMarkSubmitted(frame.value,handoffHost.fence.Get(),completion));
        handoffHost.execute();handoffHost.wait();
        require(BeamRT_GIDestroyFrame(&frame.value)!=0 && frame.value,
                "GI frame retired before the consumer completion fence");
        TestConstants constants{};std::memcpy(constants.key,frameInputs.key,sizeof(constants.key));
        constants.size[0]=static_cast<float>(frameInputs.width);constants.size[1]=static_cast<float>(frameInputs.height);
        constants.enabled=1;constants.index=static_cast<int32_t>(frameInputs.surfelCount-1);
        constants.viewport[2]=constants.viewport[3]=1;
        draw(handoffHost,frame.value,consumerVS,consumerPS,constants,true);
        require(handoffHost.sequence==completion,"completion fence was not placed after the final consumer");
        success(BeamRT_GIDestroyFrame(&frame.value));
    }
    std::cout<<"PASS: captured mesh/receiver SRVs -> explicit GI frame -> consumer -> post-consumer fence\n";
}
