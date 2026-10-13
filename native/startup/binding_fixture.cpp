#include "gi_bindings.h"
#include "pipeline_audit.h"
#include "gi_root_layout.h"
#include "binding_validation.h"
#include <dxgi1_6.h>
#include <d3d12sdklayers.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <cstring>
#include <cmath>
#include <thread>
#include <atomic>
using Microsoft::WRL::ComPtr;
extern "C" void** beamrtBindingSDKSlot(void*,unsigned);
static void need(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
static void hr(HRESULT h){if(FAILED(h))throw std::runtime_error("binding fixture HRESULT="+std::to_string(h));}
static std::vector<uint8_t> file(const wchar_t* name){std::ifstream s(std::filesystem::path(name),std::ios::binary|std::ios::ate);
    need(bool(s) && s.tellg()>0 && s.tellg()<=16*1024*1024,"fixture input missing/oversized");std::vector<uint8_t> b(static_cast<size_t>(s.tellg()));
    s.seekg(0);s.read(reinterpret_cast<char*>(b.data()),b.size());need(bool(s),"fixture input truncated");return b;}
static D3D12_RESOURCE_DESC buffer(UINT64 n){D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=n;d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;return d;}
static ComPtr<ID3D12Resource> resource(ID3D12Device* device,D3D12_RESOURCE_DESC d,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state){D3D12_HEAP_PROPERTIES h{};h.Type=type;
    ComPtr<ID3D12Resource> r;hr(device->CreateCommittedResource(&h,D3D12_HEAP_FLAG_NONE,&d,state,nullptr,IID_PPV_ARGS(&r)));return r;}
static void transition(ID3D12GraphicsCommandList* l,ID3D12Resource* r,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};l->ResourceBarrier(1,&b);}
struct Renderer {
    ComPtr<ID3D12Device> device;ComPtr<ID3D12CommandQueue> queue;ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList> list;ComPtr<ID3D12Fence> fence;
    uint64_t sequence=0;std::vector<ComPtr<ID3D12Resource>> uploads;
    Renderer(ID3D12Device* d):device(d){D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
        hr(d->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));hr(d->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)));
        hr(d->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&list)));hr(list->Close());hr(d->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));}
    void begin(){hr(allocator->Reset());hr(list->Reset(allocator.Get(),nullptr));}
    void submit(){hr(list->Close());ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists);hr(queue->Signal(fence.Get(),++sequence));
        HANDLE done=CreateEventW(nullptr,FALSE,FALSE,nullptr);need(done!=nullptr,"fixture fence event");const auto set=fence->SetEventOnCompletion(sequence,done);
        const auto wait=SUCCEEDED(set)?WaitForSingleObject(done,10000):WAIT_FAILED;CloseHandle(done);hr(set);need(wait==WAIT_OBJECT_0,"fixture GPU timeout");hr(device->GetDeviceRemovedReason());uploads.clear();}
    ComPtr<ID3D12Resource> texture(float value){D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;d.SampleDesc.Count=1;
        auto r=resource(device.Get(),d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);D3D12_PLACED_SUBRESOURCE_FOOTPRINT f{};UINT rows;UINT64 row,total;device->GetCopyableFootprints(&d,0,1,0,&f,&rows,&row,&total);
        auto u=resource(device.Get(),buffer(total),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* p;D3D12_RANGE none{0,0};hr(u->Map(0,&none,&p));const float color[]={value,value,value,value};std::memcpy(static_cast<uint8_t*>(p)+f.Offset,color,sizeof(color));u->Unmap(0,nullptr);
        D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=r.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;src.pResource=u.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=f;list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(list.Get(),r.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);uploads.push_back(u);return r;}
};
static void unavailableAt(int line){BeamRTBindingSnapshot s{};s.recordedDraw=99;const auto result=BeamRT_BindingsRead(&s,sizeof(s));
    if(SUCCEEDED(result) || s.recordedDraw || s.bytes)throw std::runtime_error("unavailable snapshot at line "+std::to_string(line)+", HRESULT="+std::to_string(result)+", serial="+std::to_string(s.serial));}
#define unavailable() unavailableAt(__LINE__)
int wmain(int argc,wchar_t** argv){try{
    need(argc==4 || argc==5,"bindings_test <vs> <ps> <actual-root> [--warp]");const bool warp=argc==5;need(!warp || std::wstring(argv[4])==L"--warp","unknown flag");
    uint64_t cpu[6]{};BeamRTBindingHeap h{1,100,200,8,4,0,1};need(beamrtBindingTable(208,h,cpu) && cpu[5]==128,"table bounds valid range");
    for(uint64_t bad:{199ull,201ull,212ull,UINT64_MAX})need(!beamrtBindingTable(bad,h,cpu),"out-of-range/misaligned table accepted");
    h.cpu=UINT64_MAX-4;need(!beamrtBindingTable(208,h,cpu),"CPU handle overflow accepted");
    auto vs=file(argv[1]),ps=file(argv[2]),rootBytes=file(argv[3]);BeamRTGIRootLayout layout;hr(beamrtDecodeGIRoot(rootBytes.data(),rootBytes.size(),layout));
    auto badRoot=rootBytes;badRoot[0]=0;need(FAILED(beamrtDecodeGIRoot(badRoot.data(),badRoot.size(),layout)) && layout.cbv==UINT32_MAX,"malformed root accepted or output not cleared");hr(beamrtDecodeGIRoot(rootBytes.data(),rootBytes.size(),layout));
    ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
    ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
    if(warp){ComPtr<IDXGIAdapter> a;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&a)));hr(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));}
    else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> a;hr(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&a)));DXGI_ADAPTER_DESC1 d{};hr(a->GetDesc1(&d));if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
        if(SUCCEEDED(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Fixture GPU: "<<d.Description<<L'\n';}
    Renderer old(device.Get());BeamRTPipelineAuditConfig config{sizeof(config),1,vs.data(),vs.size(),ps.data(),ps.size(),{0,0}};
    hr(BeamRT_PipelineAuditStart(device.Get(),&config));hr(BeamRT_BindingsStart(device.Get()));need(FAILED(BeamRT_BindingsTargetFromAudit()),"unmatched target accepted");unavailable();
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,rootBytes.data(),rootBytes.size(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d{};d.pRootSignature=root.Get();d.VS={vs.data(),vs.size()};d.PS={ps.data(),ps.size()};d.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;d.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;d.RasterizerState.DepthClipEnable=TRUE;
    d.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;d.SampleMask=UINT_MAX;d.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;d.NumRenderTargets=1;d.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;d.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pso;hr(device->CreateGraphicsPipelineState(&d,IID_PPV_ARGS(&pso)));hr(BeamRT_BindingsTargetFromAudit());need(FAILED(BeamRT_BindingsTargetFromAudit()),"target replacement accepted");
    Renderer render(device.Get());render.begin();std::vector<ComPtr<ID3D12Resource>> textures;for(int i=1;i<=6;++i)textures.push_back(render.texture(static_cast<float>(i)));render.submit();
    auto constants=resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* mapped;D3D12_RANGE none{0,0};hr(constants->Map(0,&none,&mapped));float bias[]={2,2,2,2};std::memcpy(mapped,bias,sizeof(bias));constants->Unmap(0,nullptr);
    D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;hd.NumDescriptors=6;hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;ComPtr<ID3D12DescriptorHeap> srvHeap,alternate,samplerHeap,rtv;
    hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&srvHeap)));hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&alternate)));hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&samplerHeap)));
    const auto srvStride=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV),samplerStride=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2D.MipLevels=1;
    D3D12_SAMPLER_DESC sampler{};sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_POINT;sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;sampler.MaxLOD=D3D12_FLOAT32_MAX;sampler.MaxAnisotropy=1;sampler.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    for(UINT i=0;i<6;++i){auto s=srvHeap->GetCPUDescriptorHandleForHeapStart();s.ptr+=i*srvStride;device->CreateShaderResourceView(textures[i].Get(),&view,s);auto a=alternate->GetCPUDescriptorHandleForHeapStart();a.ptr+=i*srvStride;device->CreateShaderResourceView(textures[i].Get(),&view,a);auto f=samplerHeap->GetCPUDescriptorHandleForHeapStart();f.ptr+=i*samplerStride;device->CreateSampler(&sampler,f);}
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=targetDesc.Height=1;targetDesc.DepthOrArraySize=1;targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;targetDesc.Format=d.RTVFormats[0];targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=resource(device.Get(),targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_NONE;hd.NumDescriptors=1;hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtv)));device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 row,total;device->GetCopyableFootprints(&targetDesc,0,1,0,&footprint,&rows,&row,&total);auto readback=resource(device.Get(),buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    auto bind=[&](ID3D12GraphicsCommandList* l,ID3D12RootSignature* r,ID3D12DescriptorHeap* heap){l->SetPipelineState(pso.Get());l->SetGraphicsRootSignature(r);ID3D12DescriptorHeap* heaps[]={heap,samplerHeap.Get()};l->SetDescriptorHeaps(2,heaps);
        l->SetGraphicsRootConstantBufferView(layout.cbv,constants->GetGPUVirtualAddress());l->SetGraphicsRootDescriptorTable(layout.srv,heap->GetGPUDescriptorHandleForHeapStart());l->SetGraphicsRootDescriptorTable(layout.sampler,samplerHeap->GetGPUDescriptorHandleForHeapStart());
        D3D12_VIEWPORT v{0,0,1,1,0,1};D3D12_RECT s{0,0,1,1};l->RSSetViewports(1,&v);l->RSSetScissorRects(1,&s);const auto output=rtv->GetCPUDescriptorHandleForHeapStart();l->OMSetRenderTargets(1,&output,FALSE,nullptr);l->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);};
    auto pixel=[&]{transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
        render.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);render.submit();D3D12_RANGE read{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&read,&mapped));need(std::abs(*reinterpret_cast<float*>(static_cast<uint8_t*>(mapped)+footprint.Offset)-23)<.00001f,"observer changed native GPU output");readback->Unmap(0,&none);};
    render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());render.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* sameHeaps[]={srvHeap.Get(),samplerHeap.Get()};render.list->SetDescriptorHeaps(2,sameHeaps);render.list->DrawInstanced(3,1,0,0);
    BeamRTBindingSnapshot snapshot{};hr(BeamRT_BindingsRead(&snapshot,sizeof(snapshot)));need(snapshot.recordedDraw && snapshot.cbv==constants->GetGPUVirtualAddress() && snapshot.viewportCount==1 && snapshot.viewports[0].Width==1
        && snapshot.renderTargets[0]==rtv->GetCPUDescriptorHandleForHeapStart().ptr && snapshot.srvCpu[5]==srvHeap->GetCPUDescriptorHandleForHeapStart().ptr+5*srvStride
        && snapshot.samplerCpu[5]==samplerHeap->GetCPUDescriptorHandleForHeapStart().ptr+5*samplerStride,"actual binding snapshot mismatch");
    need(!snapshot.descriptorProvenanceVerified && !snapshot.cbvContentsVerified && !snapshot.cameraVerified && !snapshot.gpuOrderingVerified && !snapshot.lightingConsumed,"recorded handles promoted to GPU/resource proof");pixel();const auto generation=snapshot.generation;
    render.begin();unavailable();bind(render.list.Get(),root.Get(),alternate.Get());render.list->DrawInstanced(3,1,0,0);hr(BeamRT_BindingsRead(&snapshot,sizeof(snapshot)));need(snapshot.generation>generation && snapshot.srvCpu[0]==alternate->GetCPUDescriptorHandleForHeapStart().ptr,"reset/heap rebind generation lost");pixel();
    auto indices=resource(device.Get(),buffer(16),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);hr(indices->Map(0,&none,&mapped));const UINT indexData[]={0,1,2};std::memcpy(mapped,indexData,sizeof(indexData));indices->Unmap(0,nullptr);
    render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());D3D12_INDEX_BUFFER_VIEW ib{indices->GetGPUVirtualAddress(),sizeof(indexData),DXGI_FORMAT_R32_UINT};render.list->IASetIndexBuffer(&ib);render.list->DrawIndexedInstanced(3,1,0,0,0);
    hr(BeamRT_BindingsRead(&snapshot,sizeof(snapshot)));need(snapshot.drawKind==2 && snapshot.count==3,"indexed draw signature/receipt mismatch");pixel();
    old.begin();bind(old.list.Get(),root.Get(),srvHeap.Get());render.begin();unavailable();old.list->DrawInstanced(3,1,0,0);unavailable();hr(old.list->Close());hr(render.list->Close());
    // Drivers may intern byte-identical roots. Use a genuinely different,
    // valid serialized layout for this record-only negative (never submitted).
    ComPtr<ID3D12VersionedRootSignatureDeserializer> decoder;hr(D3D12CreateVersionedRootSignatureDeserializer(rootBytes.data(),rootBytes.size(),IID_PPV_ARGS(&decoder)));
    auto changedDesc=decoder->GetUnconvertedRootSignatureDesc()->Desc_1_0;changedDesc.Flags|=D3D12_ROOT_SIGNATURE_FLAG_DENY_HULL_SHADER_ROOT_ACCESS;
    ComPtr<ID3DBlob> changedBlob,error;hr(D3D12SerializeRootSignature(&changedDesc,D3D_ROOT_SIGNATURE_VERSION_1,&changedBlob,&error));
    BeamRTGIRootLayout rejected;need(FAILED(beamrtDecodeGIRoot(changedBlob->GetBufferPointer(),changedBlob->GetBufferSize(),rejected)),"unsupported root flags accepted");
    ComPtr<ID3D12RootSignature> differentRoot;hr(device->CreateRootSignature(0,changedBlob->GetBufferPointer(),changedBlob->GetBufferSize(),IID_PPV_ARGS(&differentRoot)));
    need(differentRoot.Get()!=root.Get(),"negative root unexpectedly interned");render.begin();bind(render.list.Get(),differentRoot.Get(),srvHeap.Get());render.list->DrawInstanced(3,1,0,0);unavailable();hr(render.list->Close());
    ComPtr<ID3D12CommandAllocator> ba;ComPtr<ID3D12GraphicsCommandList> bundle;hr(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_BUNDLE,IID_PPV_ARGS(&ba)));hr(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_BUNDLE,ba.Get(),pso.Get(),IID_PPV_ARGS(&bundle)));hr(bundle->Close());
    render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());render.list->ExecuteBundle(bundle.Get());render.list->DrawInstanced(3,1,0,0);unavailable();hr(render.list->Close());
    render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());render.list->ExecuteBundle(bundle.Get());render.list->ClearState(pso.Get());bind(render.list.Get(),root.Get(),srvHeap.Get());
    render.list->DrawInstanced(3,1,0,0);hr(BeamRT_BindingsRead(&snapshot,sizeof(snapshot)));pixel();
    D3D12_INDIRECT_ARGUMENT_DESC argument{};argument.Type=D3D12_INDIRECT_ARGUMENT_TYPE_DRAW;D3D12_COMMAND_SIGNATURE_DESC signatureDesc{sizeof(D3D12_DRAW_ARGUMENTS),1,&argument,0};ComPtr<ID3D12CommandSignature> signature;
    hr(device->CreateCommandSignature(&signatureDesc,nullptr,IID_PPV_ARGS(&signature)));auto args=resource(device.Get(),buffer(16),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    hr(args->Map(0,&none,&mapped));const D3D12_DRAW_ARGUMENTS arguments{3,1,0,0};std::memcpy(mapped,&arguments,sizeof(arguments));args->Unmap(0,nullptr);
    render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());render.list->ExecuteIndirect(signature.Get(),1,args.Get(),0,nullptr,0);render.list->DrawInstanced(3,1,0,0);unavailable();hr(render.list->Close());
    ComPtr<ID3D12GraphicsCommandList4> list4;hr(render.list.As(&list4));render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());
    D3D12_RENDER_PASS_RENDER_TARGET_DESC pass{};pass.cpuDescriptor=rtv->GetCPUDescriptorHandleForHeapStart();pass.BeginningAccess.Type=D3D12_RENDER_PASS_BEGINNING_ACCESS_TYPE_PRESERVE;pass.EndingAccess.Type=D3D12_RENDER_PASS_ENDING_ACCESS_TYPE_PRESERVE;
    list4->BeginRenderPass(1,&pass,nullptr,D3D12_RENDER_PASS_FLAG_NONE);render.list->DrawInstanced(3,1,0,0);unavailable();list4->EndRenderPass();hr(render.list->Close());
    render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());std::thread foreign([&]{D3D12_VIEWPORT v{0,0,1,1,0,1};render.list->RSSetViewports(1,&v);});foreign.join();render.list->DrawInstanced(3,1,0,0);unavailable();hr(render.list->Close());
    ComPtr<ID3D12Device4> device4;hr(device.As(&device4));std::vector<ComPtr<ID3D12GraphicsCommandList>> pressure(65);for(auto& l:pressure)hr(device4->CreateCommandList1(0,D3D12_COMMAND_LIST_TYPE_DIRECT,D3D12_COMMAND_LIST_FLAG_NONE,IID_PPV_ARGS(&l)));
    BeamRTBindingStatus status{};hr(BeamRT_BindingsStatus(&status,sizeof(status)));need(status.healthy && status.liveCommands==64 && status.pressureSkipped>=2,"command pressure poisoned audit or exceeded budget");pressure.clear();hr(BeamRT_BindingsStatus(&status,sizeof(status)));need(status.liveCommands==1,"ordinary command lists retained by observer");
    HRESULT wrong=S_OK;std::thread wrongThread([&]{wrong=BeamRT_BindingsDisable();});wrongThread.join();need(wrong==E_ACCESSDENIED,"wrong-thread OFF accepted");
    render.begin();bind(render.list.Get(),root.Get(),srvHeap.Get());using Draw=void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,UINT,UINT,UINT);auto cached=reinterpret_cast<Draw>(*beamrtBindingSDKSlot(render.list.Get(),13));
    std::atomic<bool> running{true},entered{false},good{true};std::thread concurrent([&]{do{ComPtr<ID3D12GraphicsCommandList> l;if(FAILED(device4->CreateCommandList1(0,D3D12_COMMAND_LIST_TYPE_DIRECT,D3D12_COMMAND_LIST_FLAG_NONE,IID_PPV_ARGS(&l))))good=false;entered=true;}while(running.load());});while(!entered.load())SwitchToThread();
    hr(BeamRT_BindingsDisable());running=false;concurrent.join();need(good,"OFF changed concurrent native creation");hr(BeamRT_BindingsStatus(&status,sizeof(status)));const auto frozen=status.serial;cached(render.list.Get(),3,1,0,0);pixel();unavailable();hr(BeamRT_BindingsStatus(&status,sizeof(status)));
    need(!status.enabled && !status.attachedSlots && status.serial==frozen && status.threadRejected && status.untracked && status.rejectedDraws,"late callback/restoration/refusal evidence failed");hr(BeamRT_BindingsDisable());need(FAILED(BeamRT_BindingsStart(device.Get())),"resident restart accepted");hr(BeamRT_PipelineAuditDisable());
    std::cout<<"PASS: decoded three-slot root layout; real CBV/tables/viewport/output and indexed recording; reset/rebind, untracked/root/bundle/indirect/render-pass/thread rejection, 64-command pressure/retirement, concurrent OFF/late forwarding; unchanged GPU pixel=23; "<<(warp?"WARP":"hardware")<<"; debug layer="<<(debugEnabled?"enabled":"unavailable")<<". No game launch or GPU-integration proof.\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';BeamRT_BindingsDisable();BeamRT_PipelineAuditDisable();return 1;}}
