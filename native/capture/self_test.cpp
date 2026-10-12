#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "beamrt_capture.h"
#include <windows.h>
#include <dxgi1_6.h>
#include <d3d12sdklayers.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using Microsoft::WRL::ComPtr;
static void require(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
static void hr(HRESULT value){if(FAILED(value))throw std::runtime_error("fixture HRESULT="+std::to_string(value));}
static void success(int value){require(value==0,BeamRT_CaptureLastError());}
static std::vector<uint8_t> file(const wchar_t* path){std::ifstream s(std::filesystem::path(path),std::ios::binary|std::ios::ate);require(bool(s),"shader file missing");auto size=s.tellg();require(size>0 && size<=16*1024*1024,"shader size invalid");std::vector<uint8_t> data(static_cast<size_t>(size));s.seekg(0);s.read(reinterpret_cast<char*>(data.data()),static_cast<std::streamsize>(data.size()));require(bool(s),"shader truncated");return data;}
static D3D12_RESOURCE_DESC buffer(UINT64 bytes){D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;return d;}
static ComPtr<ID3D12Resource> make(ID3D12Device* device,D3D12_RESOURCE_DESC desc,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state){D3D12_HEAP_PROPERTIES heap{};heap.Type=type;ComPtr<ID3D12Resource> result;hr(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,IID_PPV_ARGS(&result)));return result;}
static void transition(ID3D12GraphicsCommandList* list,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};list->ResourceBarrier(1,&b);}
struct Renderer {
    ComPtr<ID3D12Device> device;ComPtr<ID3D12CommandQueue> queue;ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList> list;
    UINT64 sequence=0;std::vector<ComPtr<ID3D12Resource>> uploads;
    explicit Renderer(ID3D12Device* d):device(d){D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;hr(d->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));hr(d->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));hr(d->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)));hr(d->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&list)));hr(list->Close());}
    void begin(){hr(allocator->Reset());hr(list->Reset(allocator.Get(),nullptr));}
    void submit(){hr(list->Close());ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists);hr(queue->Signal(fence.Get(),++sequence));HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);require(event!=nullptr,"event failed");hr(fence->SetEventOnCompletion(sequence,event));DWORD result=WaitForSingleObject(event,10000);CloseHandle(event);require(result==WAIT_OBJECT_0,"fixture GPU timeout");hr(device->GetDeviceRemovedReason());uploads.clear();}
    ComPtr<ID3D12Resource> texture(float value){D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=1;d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;d.SampleDesc.Count=1;auto texture=make(device.Get(),d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;device->GetCopyableFootprints(&d,0,1,0,&footprint,&rows,&rowBytes,&total);auto upload=make(device.Get(),buffer(total),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);float color[]={value,value,value,value};void* mapped;D3D12_RANGE none{0,0};hr(upload->Map(0,&none,&mapped));std::memcpy(static_cast<uint8_t*>(mapped)+footprint.Offset,color,sizeof(color));upload->Unmap(0,nullptr);D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=texture.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;src.pResource=upload.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=footprint;list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(list.Get(),texture.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);uploads.push_back(upload);return texture;}
};
#include "thread_fixture.h"
int wmain(int argc,wchar_t** argv){BeamRTCapture* host=nullptr;BeamRTCaptureSnapshot* snapshot=nullptr;
    try{
        require(argc==4 || argc==5,"usage: capture_test fixture.vs.cso fixture.ps.cso fixture.cs.cso [--warp]");const bool warp=argc==5 && std::wstring(argv[4])==L"--warp";require(argc!=5 || warp,"unknown option");
        ComPtr<ID3D12Debug> debug;bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"Isolated interception host: WARP\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware device unavailable");DXGI_ADAPTER_DESC1 d{};hr(adapter->GetDesc1(&d));if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Isolated interception host: "<<d.Description<<L'\n';}
        const auto vs=file(argv[1]),ps=file(argv[2]),cs=file(argv[3]);D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=3;
        D3D12_ROOT_PARAMETER parameter{};parameter.ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;parameter.DescriptorTable={1,&range};D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=1;desc.pParameters=&parameter;
        ComPtr<ID3DBlob> encoded,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors));
        BeamRTCaptureConfig config{};config.shader=ps.data();config.shaderBytes=ps.size();config.rootSignature=encoded->GetBufferPointer();config.rootSignatureBytes=encoded->GetBufferSize();config.kind=1;config.inputCount=3;
        for(UINT i=0;i<3;++i){config.offsets[i]=i;config.formats[i]=i==2?DXGI_FORMAT_UNKNOWN:DXGI_FORMAT_R32G32B32A32_FLOAT;config.dimensions[i]=i==2?D3D12_SRV_DIMENSION_BUFFER:D3D12_SRV_DIMENSION_TEXTURE2D;}
        require(BeamRT_CaptureAbiVersion()==2,"capture ABI mismatch");require(BeamRT_CaptureStart(device.Get(),&config,0,&host)!=0 && !host,"unapproved API quiescence accepted");
        auto invalid=config;invalid.offsets[2]=3;require(BeamRT_CaptureStart(device.Get(),&invalid,1,&host)!=0 && !host,"out-of-range root binding accepted");
        invalid=config;invalid.threadMode=2;require(BeamRT_CaptureStart(device.Get(),&invalid,1,&host)!=0 && !host,"unsupported thread mode accepted");
        success(BeamRT_CaptureStart(device.Get(),&config,1,&host));
        Renderer render(device.Get());render.begin();auto first=render.texture(1),second=render.texture(2),alternate=render.texture(4);render.submit();
        auto lights=make(device.Get(),buffer(16),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);float light[]={3,3,3,3};void* mapped;D3D12_RANGE none{0,0};hr(lights->Map(0,&none,&mapped));std::memcpy(mapped,light,16);lights->Unmap(0,nullptr);
        D3D12_DESCRIPTOR_HEAP_DESC heapDesc{};heapDesc.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heapDesc.NumDescriptors=4;ComPtr<ID3D12DescriptorHeap> cpu,gpu;hr(device->CreateDescriptorHeap(&heapDesc,IID_PPV_ARGS(&cpu)));heapDesc.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;hr(device->CreateDescriptorHeap(&heapDesc,IID_PPV_ARGS(&gpu)));
        const UINT stride=device->GetDescriptorHandleIncrementSize(heapDesc.Type);auto address=[&](ID3D12DescriptorHeap* h,UINT offset){auto result=h->GetCPUDescriptorHandleForHeapStart();result.ptr+=SIZE_T(offset)*stride;return result;};
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2D.MipLevels=1;
        device->CreateShaderResourceView(first.Get(),&view,address(cpu.Get(),0));device->CreateShaderResourceView(second.Get(),&view,address(cpu.Get(),1));device->CreateShaderResourceView(alternate.Get(),&view,address(cpu.Get(),3));
        view={};view.Format=DXGI_FORMAT_UNKNOWN;view.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Buffer.NumElements=1;view.Buffer.StructureByteStride=16;device->CreateShaderResourceView(lights.Get(),&view,address(cpu.Get(),2));
        device->CopyDescriptorsSimple(3,address(gpu.Get(),0),address(cpu.Get(),0),heapDesc.Type);
        ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,encoded->GetBufferPointer(),encoded->GetBufferSize(),IID_PPV_ARGS(&root)));
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pipelineDesc{};pipelineDesc.pRootSignature=root.Get();pipelineDesc.VS={vs.data(),vs.size()};pipelineDesc.PS={ps.data(),ps.size()};pipelineDesc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pipelineDesc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pipelineDesc.RasterizerState.DepthClipEnable=TRUE;pipelineDesc.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;pipelineDesc.SampleMask=UINT_MAX;pipelineDesc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;pipelineDesc.NumRenderTargets=1;pipelineDesc.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;pipelineDesc.SampleDesc.Count=1;ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&pipelineDesc,IID_PPV_ARGS(&pipeline)));
        D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=1;targetDesc.Height=1;targetDesc.DepthOrArraySize=1;targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;targetDesc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;auto target=make(device.Get(),targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        D3D12_DESCRIPTOR_HEAP_DESC rtvDesc{};rtvDesc.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;rtvDesc.NumDescriptors=1;ComPtr<ID3D12DescriptorHeap> rtv;hr(device->CreateDescriptorHeap(&rtvDesc,IID_PPV_ARGS(&rtv)));device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;device->GetCopyableFootprints(&targetDesc,0,1,0,&footprint,&rows,&rowBytes,&total);auto readback=make(device.Get(),buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        ComPtr<ID3D12CommandAllocator> bundleAllocator;ComPtr<ID3D12GraphicsCommandList> bundle;hr(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_BUNDLE,IID_PPV_ARGS(&bundleAllocator)));hr(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_BUNDLE,bundleAllocator.Get(),pipeline.Get(),IID_PPV_ARGS(&bundle)));hr(bundle->Close());
        auto draw=[&](bool changeBeforeSubmit,float expected,bool useBundle=false){render.begin();render.list->SetPipelineState(pipeline.Get());render.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={gpu.Get()};render.list->SetDescriptorHeaps(1,heaps);render.list->SetGraphicsRootDescriptorTable(0,gpu->GetGPUDescriptorHandleForHeapStart());const D3D12_VIEWPORT viewport{0,0,1,1,0,1};const D3D12_RECT scissor{0,0,1,1};render.list->RSSetViewports(1,&viewport);render.list->RSSetScissorRects(1,&scissor);auto handle=rtv->GetCPUDescriptorHandleForHeapStart();render.list->OMSetRenderTargets(1,&handle,FALSE,nullptr);render.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);render.list->DrawInstanced(3,1,0,0);
            if(useBundle)render.list->ExecuteBundle(bundle.Get());
            if(changeBeforeSubmit)device->CopyDescriptorsSimple(1,address(gpu.Get(),0),address(cpu.Get(),3),heapDesc.Type);
            transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;render.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);render.submit();D3D12_RANGE read{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&read,&mapped));const auto pixel=reinterpret_cast<const float*>(static_cast<const uint8_t*>(mapped)+footprint.Offset);require(std::abs(pixel[0]-expected)<.00001f,"read-only hooks changed normal GPU output");readback->Unmap(0,&none);};
        draw(false,3.75f);success(BeamRT_CaptureGetSnapshot(host,&snapshot));BeamRTCaptureInfo info{};success(BeamRT_CaptureReadSnapshot(snapshot,&info));require(info.count==3 && info.resources[0]==first.Get() && info.resources[1]==second.Get() && info.resources[2]==lights.Get(),"real descriptor/resource capture mismatch");require(!info.cameraVerified && !info.gpuOrderingVerified && !info.lightingConsumed,"capture incorrectly certified lighting integration");const auto firstGeneration=info.recordingGeneration;BeamRT_CaptureReleaseSnapshot(&snapshot);
        draw(true,6.75f);success(BeamRT_CaptureGetSnapshot(host,&snapshot));success(BeamRT_CaptureReadSnapshot(snapshot,&info));require(info.resources[0]==alternate.Get() && info.recordingGeneration>firstGeneration,"submission-time copy/reset provenance lost");BeamRT_CaptureReleaseSnapshot(&snapshot);
        // Exercise the general range-copy API, not only CopyDescriptorsSimple.
        auto destination=address(gpu.Get(),0);D3D12_CPU_DESCRIPTOR_HANDLE sources[]={address(cpu.Get(),0),address(cpu.Get(),1),address(cpu.Get(),2)};UINT size=3;
        device->CopyDescriptors(1,&destination,&size,3,sources,nullptr,heapDesc.Type);draw(false,3.75f);success(BeamRT_CaptureGetSnapshot(host,&snapshot));success(BeamRT_CaptureReadSnapshot(snapshot,&info));require(info.resources[0]==first.Get(),"general copy ranges not captured");BeamRT_CaptureReleaseSnapshot(&snapshot);
        draw(false,3.75f,true);require(BeamRT_CaptureGetSnapshot(host,&snapshot)!=0 && !snapshot,"unsupported bundle certified a capture");
        // A null/unknown SRV must clear previous provenance, not reuse old input.
        view={};view.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2D.MipLevels=1;device->CreateShaderResourceView(nullptr,&view,address(cpu.Get(),1));device->CopyDescriptorsSimple(1,address(gpu.Get(),1),address(cpu.Get(),1),heapDesc.Type);draw(false,1.75f);require(BeamRT_CaptureGetSnapshot(host,&snapshot)!=0 && !snapshot,"unknown descriptor reused stale resource provenance");
        device->CreateShaderResourceView(second.Get(),&view,address(cpu.Get(),1));device->CopyDescriptorsSimple(1,address(gpu.Get(),1),address(cpu.Get(),1),heapDesc.Type);draw(false,3.75f);success(BeamRT_CaptureGetSnapshot(host,&snapshot));
        require(BeamRT_CaptureStop(&host,0)!=0 && host,"unsafe detach accepted");success(BeamRT_CaptureStop(&host,1));require(!host,"host not detached");success(BeamRT_CaptureReadSnapshot(snapshot,&info));require(info.resources[0]->GetDesc().Width==1,"snapshot lifetime tied incorrectly to detached host");BeamRT_CaptureReleaseSnapshot(&snapshot);draw(false,3.75f);
        // Reattach explicitly; another API-calling thread poisons capture but
        // forwards valid renderer calls rather than changing their results.
        success(BeamRT_CaptureStart(device.Get(),&config,1,&host));std::thread other([&]{ComPtr<ID3D12DescriptorHeap> temporary;hr(device->CreateDescriptorHeap(&heapDesc,IID_PPV_ARGS(&temporary)));});other.join();BeamRTCaptureStatus status{};success(BeamRT_CaptureGetStatus(host,&status));require(!status.captureHealthy && !status.snapshotAvailable,"unsupported multi-thread scope certified");success(BeamRT_CaptureStop(&host,1));
        // Separate compute scope with the same live texture/structured inputs.
        // Extra output UAV is intentionally NOT claimed as a captured lighting target.
        D3D12_ROOT_PARAMETER cp[2]{};cp[0]=parameter;cp[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;
        D3D12_ROOT_SIGNATURE_DESC cd{};cd.NumParameters=2;cd.pParameters=cp;ComPtr<ID3DBlob> computeEncoded;hr(D3D12SerializeRootSignature(&cd,D3D_ROOT_SIGNATURE_VERSION_1,&computeEncoded,&errors));
        auto computeConfig=config;computeConfig.kind=2;computeConfig.shader=cs.data();computeConfig.shaderBytes=cs.size();computeConfig.rootSignature=computeEncoded->GetBufferPointer();computeConfig.rootSignatureBytes=computeEncoded->GetBufferSize();
        success(BeamRT_CaptureStart(device.Get(),&computeConfig,1,&host));
        ComPtr<ID3D12RootSignature> computeRoot;hr(device->CreateRootSignature(0,computeEncoded->GetBufferPointer(),computeEncoded->GetBufferSize(),IID_PPV_ARGS(&computeRoot)));
        D3D12_COMPUTE_PIPELINE_STATE_DESC computeDesc{};computeDesc.pRootSignature=computeRoot.Get();computeDesc.CS={cs.data(),cs.size()};ComPtr<ID3D12PipelineState> compute;hr(device->CreateComputePipelineState(&computeDesc,IID_PPV_ARGS(&compute)));
        ComPtr<ID3D12DescriptorHeap> computeCpu,computeGpu;heapDesc.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_NONE;hr(device->CreateDescriptorHeap(&heapDesc,IID_PPV_ARGS(&computeCpu)));heapDesc.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;hr(device->CreateDescriptorHeap(&heapDesc,IID_PPV_ARGS(&computeGpu)));
        device->CreateShaderResourceView(first.Get(),&view,address(computeCpu.Get(),0));device->CreateShaderResourceView(second.Get(),&view,address(computeCpu.Get(),1));
        auto structured=view;structured.Format=DXGI_FORMAT_UNKNOWN;structured.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;structured.Buffer={0,1,16,D3D12_BUFFER_SRV_FLAG_NONE};device->CreateShaderResourceView(lights.Get(),&structured,address(computeCpu.Get(),2));device->CopyDescriptorsSimple(3,address(computeGpu.Get(),0),address(computeCpu.Get(),0),heapDesc.Type);
        auto outputDesc=buffer(16);outputDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;auto output=make(device.Get(),outputDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);auto outputRead=make(device.Get(),buffer(16),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        Renderer computeRenderer(device.Get());computeRenderer.begin();
        // These inputs came from the graphics fixture. Compute texture reads
        // need NON_PIXEL_SHADER_RESOURCE, even if a driver tolerates omission.
        transition(computeRenderer.list.Get(),first.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        transition(computeRenderer.list.Get(),second.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        computeRenderer.list->SetPipelineState(compute.Get());
        computeRenderer.list->SetComputeRootSignature(computeRoot.Get());
        ID3D12DescriptorHeap* computeHeaps[]={computeGpu.Get()};
        computeRenderer.list->SetDescriptorHeaps(1,computeHeaps);
        computeRenderer.list->SetComputeRootDescriptorTable(0,computeGpu->GetGPUDescriptorHandleForHeapStart());
        computeRenderer.list->SetComputeRootUnorderedAccessView(1,output->GetGPUVirtualAddress());
        computeRenderer.list->Dispatch(1,1,1);
        transition(computeRenderer.list.Get(),output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        computeRenderer.list->CopyBufferRegion(outputRead.Get(),0,output.Get(),0,16);
        transition(computeRenderer.list.Get(),first.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        transition(computeRenderer.list.Get(),second.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        computeRenderer.submit();
        success(BeamRT_CaptureGetSnapshot(host,&snapshot));success(BeamRT_CaptureReadSnapshot(snapshot,&info));
        require(info.kind==2 && info.resources[2]==lights.Get(),"compute bindings not intercepted");
        D3D12_RANGE outputRange{0,16};hr(outputRead->Map(0,&outputRange,&mapped));
        require(std::abs(*static_cast<float*>(mapped)-3.75f)<.00001f,"compute interception changed GPU output");
        outputRead->Unmap(0,&none);BeamRT_CaptureReleaseSnapshot(&snapshot);success(BeamRT_CaptureStop(&host,1));
        testMultithreadCapture(host,device.Get(),config,vs,first.Get(),second.Get(),alternate.Get(),lights.Get());
        // Exceed a capture budget with otherwise valid, GPU-idle API calls.
        // The callback error must not turn a successful renderer call into failure.
        success(BeamRT_CaptureStart(device.Get(),&config,1,&host));
        {
            std::vector<ComPtr<ID3D12DescriptorHeap>> held(65);
            D3D12_DESCRIPTOR_HEAP_DESC heapDescSmall{};heapDescSmall.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
            heapDescSmall.NumDescriptors=1;
            for(auto& heap:held)hr(device->CreateDescriptorHeap(&heapDescSmall,IID_PPV_ARGS(&heap)));
            success(BeamRT_CaptureGetStatus(host,&status));
            require(!status.captureHealthy && !status.snapshotAvailable,"capture budget error did not invalidate metadata");
            require(BeamRT_CaptureGetSnapshot(host,&snapshot)!=0 && !snapshot,
                    "poisoned capture returned a snapshot");
            draw(false,3.75f);
            success(BeamRT_CaptureStop(&host,1));
        }
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T bytes=0;hr(messages->GetMessage(i,nullptr,&bytes));std::vector<uint8_t> storage(bytes);auto message=reinterpret_cast<D3D12_MESSAGE*>(storage.data());hr(messages->GetMessage(i,message,&bytes));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<"PASS: actual public-API interception, exact pass/root match, live texture+structured-buffer capture, descriptor copies, reset generations, invalidation, quiescent detach, unchanged GPU output\n";
        std::cout<<"Debug layer "<<(debugEnabled?"enabled":"unavailable; not debug-clean proof")<<". No BeamNG attachment or lighting correction.\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(snapshot)BeamRT_CaptureReleaseSnapshot(&snapshot);if(host && BeamRT_CaptureStop(&host,1)!=0)std::cerr<<"Host retained; do not unload DLL: "<<BeamRT_CaptureLastError()<<'\n';return 1;}
}
