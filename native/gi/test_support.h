#pragma once
// Shared OFFLINE test helpers, not renderer or game integration code.
#include "gpu_fixture_host.h"
#include "beamrt_gi.h"
#include "../capture/beamrt_capture.h"
#include "handoff_validation.h"
static void success(int value) { require(value==0,BeamRT_GILastError()); }
struct TestConstants { float key[4],size[2],enabled;int32_t index;float viewport[4]; };
static_assert(sizeof(TestConstants)==48,"consumer test ABI");
// Inspect the actual compute result, not just the consumer's baseline color:
// a corrupt traversal must emit invalid (-1), never a certified clear mask (0).
inline void expectInvalidVisibilityTexture(Host& host,ID3D12Resource* texture){
    const auto desc=texture->GetDesc();
    require(desc.Height>=2 && desc.Format==DXGI_FORMAT_R32G32B32A32_FLOAT,"fixture visibility extent/format");
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;
    host.device->GetCopyableFootprints(&desc,0,1,0,&footprint,&rows,&rowBytes,&total);
    auto readback=make(host.device.Get(),buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    host.begin();transition(host.list.Get(),texture,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION source{},destination{};source.pResource=texture;source.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    destination.pResource=readback.Get();destination.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;destination.PlacedFootprint=footprint;
    host.list->CopyTextureRegion(&destination,0,0,0,&source,nullptr);
    transition(host.list.Get(),texture,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);host.execute();host.wait();
    void* mapped=nullptr;D3D12_RANGE range{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&range,&mapped));
    const auto result=reinterpret_cast<const float*>(static_cast<const uint8_t*>(mapped)+footprint.Offset+footprint.Footprint.RowPitch);
    bool invalid=true;for(unsigned channel=0;channel<4;++channel)invalid=invalid && result[channel]==-1.0f;
    D3D12_RANGE none{0,0};readback->Unmap(0,&none);
    require(invalid,"corrupt BVH produced a certified clear/blocked GI mask instead of unknown");
}
inline void expectInvalidVisibility(Host& host,BeamRTGIFrame* frame){
    void* raw=nullptr;uint64_t srv=0;success(BeamRT_GIGetOutput(frame,&raw,&srv));
    expectInvalidVisibilityTexture(host,static_cast<ID3D12Resource*>(raw));
}
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
    const beamrt_fixture::ShaderContract layout(ps,encoded->GetBufferPointer(),encoded->GetBufferSize(),beamrt_fixture::PassRole::Consumer);
    auto bytes=layout.constants();
    layout.put(bytes,"nativeGIVisibilityKey",constants.key,sizeof(constants.key));
    layout.put(bytes,"nativeGIVisibilitySize",constants.size,sizeof(constants.size));
    layout.put(bytes,"nativeGIVisibilityEnabled",&constants.enabled,sizeof(constants.enabled));
    layout.put(bytes,"surfelIndex",&constants.index,sizeof(constants.index));
    layout.put(bytes,"rtParams0",constants.viewport,sizeof(constants.viewport));
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,layout.root().data(),layout.root().size(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root.Get();p.VS={vs.data(),vs.size()};p.PS={layout.shader().data(),layout.shader().size()};
    p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;p.RasterizerState.DepthClipEnable=TRUE;
    p.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;p.SampleMask=UINT_MAX;
    p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;p.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&pipeline)));
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=2;targetDesc.Height=1;targetDesc.DepthOrArraySize=1;targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;
    targetDesc.Format=p.RTVFormats[0];targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=make(device,targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    auto cb=make(device,buffer(layout.cbvSpan()),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);fill(cb.Get(),bytes.data(),bytes.size());
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
    D3D12_ROOT_PARAMETER parameters[2]{};parameters[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameters[0].DescriptorTable={1,&range};parameters[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=2;desc.pParameters=parameters;
    ComPtr<ID3DBlob> encoded,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors));return encoded;
}
static void testShaderContracts(const beamrt_fixture::ShaderContract& layout,const std::vector<uint8_t>& vertex,
    const std::vector<uint8_t>& consumer) {
    UINT rejected=0;
    auto reject=[&](const std::vector<uint8_t>& shader,const void* root,size_t size,beamrt_fixture::PassRole role){
        bool refused=false;
        try { const beamrt_fixture::ShaderContract invalid(shader,root,size,role); }
        catch(const std::exception&) {refused=true;}
        require(refused,"unsupported shader/root manifest accepted");++rejected;
    };
    reject(vertex,layout.root().data(),layout.root().size(),beamrt_fixture::PassRole::Producer);
    reject(consumer,layout.root().data(),layout.root().size(),beamrt_fixture::PassRole::Producer);
    reject(layout.shader(),layout.root().data(),layout.root().size(),beamrt_fixture::PassRole::Consumer);
    reject(layout.shader(),nullptr,0,beamrt_fixture::PassRole::Producer);
    const std::vector<uint8_t> invalidShader{0,1,2,3};
    reject(invalidShader,layout.root().data(),layout.root().size(),beamrt_fixture::PassRole::Producer);
    const uint32_t invalidRoot=0;
    reject(layout.shader(),&invalidRoot,sizeof(invalidRoot),beamrt_fixture::PassRole::Producer);
    for(int variant=0;variant<6;++variant){
        D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=2;
        D3D12_ROOT_PARAMETER parameters[2]{};parameters[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        parameters[0].DescriptorTable={1,&range};parameters[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
        if(variant==0)parameters[1].Descriptor.ShaderRegister=1;
        if(variant==1)parameters[1].Descriptor.RegisterSpace=1;
        if(variant==2)range.NumDescriptors=1;
        if(variant==3)range.BaseShaderRegister=1;
        if(variant==4)range.OffsetInDescriptorsFromTableStart=1;
        if(variant==5)parameters[1].ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=2;desc.pParameters=parameters;
        ComPtr<ID3DBlob> root,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&root,&errors));
        reject(layout.shader(),root->GetBufferPointer(),root->GetBufferSize(),beamrt_fixture::PassRole::Producer);
    }
    auto bytes=layout.constants();float value=0;
    for(const char* name:{"fixtureControl","unknownCamera"}){
        bool refused=false;
        try {layout.put(bytes,name,&value,sizeof(value));}catch(const std::exception&){refused=true;}
        require(refused,"wrong field name/extent accepted");++rejected;
    }
    std::cout<<"PASS: "<<rejected<<" unsupported shader/root/field contracts rejected\n";
}
static ComPtr<ID3D12Resource> drawHandoffProducer(Host& host,const BeamRTGIInputs& inputs,
    const std::vector<uint8_t>& vs,const beamrt_fixture::ShaderContract& layout,
    ID3D12Resource* constants,UINT64 offset,bool splitBarrier=false) {
    auto device=host.device.Get();
    ComPtr<ID3D12RootSignature> root;
    hr(device->CreateRootSignature(0,layout.root().data(),layout.root().size(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipelineDesc{};pipelineDesc.pRootSignature=root.Get();
    pipelineDesc.VS={vs.data(),vs.size()};pipelineDesc.PS={layout.shader().data(),layout.shader().size()};
    pipelineDesc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pipelineDesc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;
    pipelineDesc.RasterizerState.DepthClipEnable=TRUE;pipelineDesc.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    pipelineDesc.SampleMask=UINT_MAX;pipelineDesc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pipelineDesc.NumRenderTargets=1;pipelineDesc.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;pipelineDesc.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&pipelineDesc,IID_PPV_ARGS(&pipeline)));
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=inputs.width;targetDesc.Height=inputs.height;
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
    // Real, explicit pre-draw transitions for the validator's narrow state
    // chain. The fixture records no state-changing work after this draw.
    auto receiver=static_cast<ID3D12Resource*>(inputs.receivers);
    auto mesh=static_cast<ID3D12Resource*>(inputs.mesh);
    if(splitBarrier){
        D3D12_RESOURCE_BARRIER pair{};pair.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        pair.Transition={receiver,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE};
        pair.Flags=D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY;list->ResourceBarrier(1,&pair);
        pair.Flags=D3D12_RESOURCE_BARRIER_FLAG_END_ONLY;list->ResourceBarrier(1,&pair);
    } else transition(list,receiver,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition(list,receiver,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    transition(list,mesh,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition(list,mesh,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    transition(list,target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition(list,target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12DescriptorHeap* heaps[]={gpu.Get()};list->SetDescriptorHeaps(1,heaps);
    list->SetGraphicsRootDescriptorTable(layout.tableParameter(),gpu->GetGPUDescriptorHandleForHeapStart());
    list->SetGraphicsRootConstantBufferView(layout.cbvParameter(),constants->GetGPUVirtualAddress()+offset);
    const D3D12_VIEWPORT viewport{0,0,static_cast<float>(inputs.width),static_cast<float>(inputs.height),0,1};
    const D3D12_RECT scissor{0,0,static_cast<LONG>(inputs.width),static_cast<LONG>(inputs.height)};
    list->RSSetViewports(1,&viewport);list->RSSetScissorRects(1,&scissor);
    auto renderTarget=rtv->GetCPUDescriptorHandleForHeapStart();list->OMSetRenderTargets(1,&renderTarget,FALSE,nullptr);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);list->DrawInstanced(3,1,0,0);
    host.execute();host.wait();return target;
}
// Called only AFTER capture detaches and the final GI consumer retires. This
// diagnostic readback is not part of constant resolution or capture evidence.
static void verifyProducerConstants(Host& host,ID3D12Resource* target,const float* expected) {
    const auto desc=target->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;
    host.device->GetCopyableFootprints(&desc,0,1,0,&footprint,&rows,&rowBytes,&total);
    require(desc.Width==2 && desc.Height==1 && rows==1 && rowBytes==32,"producer readback dimensions");
    auto readback=make(host.device.Get(),buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    host.begin();transition(host.list.Get(),target,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
    src.pResource=target;src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;host.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    transition(host.list.Get(),target,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);host.execute();host.wait();
    void* mapped=nullptr;D3D12_RANGE range{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&range,&mapped));
    const auto values=reinterpret_cast<const float*>(static_cast<const uint8_t*>(mapped)+footprint.Offset);
    bool matched=true;
    for(int pixel=0;pixel<2;++pixel)for(int channel=0;channel<4;++channel)
        matched=matched && std::isfinite(values[pixel*4+channel]) && std::abs(values[pixel*4+channel]-expected[channel])<.0001f;
    D3D12_RANGE noWrite{0,0};readback->Unmap(0,&noWrite);
    require(matched,"nonzero-offset CBV contents did not reach GPU producer output");
}
static void testCaptureToGIHandoff(ID3D12Device* device,const std::vector<uint8_t>& computeShader,
    const BeamRTGIInputs& sidecar,const std::vector<uint8_t>& handoffVS,
    const std::vector<uint8_t>& handoffPS,const std::vector<uint8_t>& consumerVS,
    const std::vector<uint8_t>& consumerPS,const float* expectedBase) {
    auto rootBytes=handoffRootSignature();BeamRTCaptureConfig config{};
    const beamrt_fixture::ShaderContract producerLayout(handoffPS,rootBytes->GetBufferPointer(),rootBytes->GetBufferSize(),beamrt_fixture::PassRole::Producer);
    testShaderContracts(producerLayout,handoffVS,consumerPS);
    const float control[4]={7,11,13,17};const UINT64 constantOffset=256;
    auto payload=producerLayout.constants();producerLayout.put(payload,"fixtureControl",control,sizeof(control));
    beamrt_fixture::KnownConstantBuffer constantBuffer;
    constantBuffer.resource=make(device,buffer(512),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    constantBuffer.uploadMirror.assign(512,0xCD); // wrong base bytes differ from the valid nonzero-offset payload
    std::memcpy(constantBuffer.uploadMirror.data()+constantOffset,payload.data(),payload.size());
    fill(constantBuffer.resource.Get(),constantBuffer.uploadMirror.data(),constantBuffer.uploadMirror.size());
    std::memcpy(constantBuffer.key,sidecar.key,sizeof(constantBuffer.key));
    constantBuffer.contentsCurrent=constantBuffer.unchangedThroughConsumer=1;
    const std::vector<beamrt_fixture::KnownConstantBuffer> constantBuffers{constantBuffer};
    config.shader=producerLayout.shader().data();config.shaderBytes=producerLayout.shader().size();
    config.rootSignature=producerLayout.root().data();config.rootSignatureBytes=producerLayout.root().size();
    config.kind=1;config.tableParameter=producerLayout.tableParameter();config.inputCount=2;
    config.offsets[0]=0;config.offsets[1]=1;
    config.formats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;config.formats[1]=DXGI_FORMAT_R8G8B8A8_UNORM;
    config.dimensions[0]=config.dimensions[1]=D3D12_SRV_DIMENSION_TEXTURE2D;
    CaptureSession capture;captureSuccess(BeamRT_CaptureStart(device,&config,1,&capture.value));
    Host handoffHost(device);
    auto producerOutput=drawHandoffProducer(handoffHost,sidecar,handoffVS,producerLayout,constantBuffer.resource.Get(),constantOffset);
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

    // Independent evidence for this known fixture program. The captured
    // bookkeeping numbers are compared with this schedule, NOT used as keys
    // or inferred GPU state/completion. Only this thread owns the DIRECT queue.
    beamrt_fixture::HandoffEvidence evidence{};
    evidence.device=device;evidence.queue=handoffHost.queue.Get();evidence.fence=handoffHost.fence.Get();
    evidence.output=producerOutput.Get();evidence.ownerThread=GetCurrentThreadId();
    evidence.fixtureSidecarProvided=1;evidence.exclusiveSerializedQueue=1;evidence.unchangedAfterProducerDraw=1;
    evidence.submission=1;evidence.recordingGeneration=2;evidence.executionSerial=1;evidence.eventSerial=2;
    evidence.producerValue=1;evidence.computeValue=2;evidence.consumerValue=3;
    evidence.sidecar=sidecar;std::memcpy(evidence.expectedKey,sidecar.key,sizeof(evidence.expectedKey));
    evidence.layout=&producerLayout;evidence.constantBuffers=&constantBuffers;
    std::memcpy(evidence.expectedControl,control,sizeof(control));
    evidence.initial[0]={static_cast<ID3D12Resource*>(sidecar.receivers),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,1};
    evidence.initial[1]={static_cast<ID3D12Resource*>(sidecar.mesh),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,1};
    evidence.initial[2]={producerOutput.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,1};
    beamrt_fixture::ResolvedConstants resolved;std::string constantReason;
    const bool resolvedOK=beamrt_fixture::resolveConstants(device,info,producerLayout,constantBuffers,sidecar.key,resolved,constantReason);
    require(resolvedOK,constantReason.c_str());
    require(resolved.resource.Get()==constantBuffer.resource.Get() && resolved.offset==constantOffset
        && resolved.span==256 && resolved.contents==payload,"CBV resolved to the wrong owned buffer range/contents");
    BeamRTGIInputs frameInputs{};std::string validationReason;
    const bool inputAccepted=beamrt_fixture::validateInputs(info,evidence,frameInputs,validationReason);
    require(inputAccepted,validationReason.c_str());
    // Adversarial copies of observed metadata, not invalid GPU API calls.
    // Rejection must clear a previously valid output, never leak stale inputs.
    UINT rejected=0;
    auto reject=[&](const BeamRTCaptureInfo& observed,const beamrt_fixture::HandoffEvidence& supplied,const char* label){
        BeamRTGIInputs candidate=frameInputs;std::string reason;
        if(beamrt_fixture::validateInputs(observed,supplied,candidate,reason))throw std::runtime_error(std::string("handoff accepted ")+label);
        require(!candidate.mesh && !candidate.receivers && !reason.empty(),"failed handoff leaked stale inputs");++rejected;
    };
    auto bad=info;
    bad.contextComplete=0;reject(bad,evidence,"incomplete capture");
    bad=info;bad.count=3;reject(bad,evidence,"unsupported SRV count");
    bad=info;bad.viewportCount=0;reject(bad,evidence,"missing viewport");
    bad=info;bad.viewports[0].Width+=1;reject(bad,evidence,"mismatched viewport");
    bad=info;bad.viewports[0].MinDepth=std::numeric_limits<float>::quiet_NaN();reject(bad,evidence,"nonfinite viewport");
    bad=info;bad.scissors[0].right-=1;reject(bad,evidence,"partial scissor coverage");
    bad=info;bad.renderTargets[0]=nullptr;reject(bad,evidence,"missing producer output");
    bad=info;bad.renderTargetFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM;reject(bad,evidence,"wrong RTV format");
    bad=info;bad.rootCbvCount=1;bad.rootCbvs[0]={0,0,256};reject(bad,evidence,"unresolved CBV address");
    bad=info;bad.rootUavCount=1;reject(bad,evidence,"unresolved UAV address");
    bad=info;bad.rootValueCount=1;reject(bad,evidence,"unknown root constant layout");
    bad=info;bad.recordingGeneration+=1;reject(bad,evidence,"stale recording generation");
    bad=info;bad.submission+=1;reject(bad,evidence,"unexpected CPU submission");
    bad=info;bad.queueExecutionSerial+=1;reject(bad,evidence,"unexpected queue execution");
    bad=info;bad.cameraVerified=1;reject(bad,evidence,"unearned camera certification");
    bad=info;bad.resources[0]=info.resources[1];reject(bad,evidence,"swapped resource roles");
    bad=info;bad.views[0].Texture2D.MipLevels=2;reject(bad,evidence,"partial/unsupported SRV view");
    bad=info;bad.queue=nullptr;reject(bad,evidence,"missing queue ownership");
    bad=info;bad.queueSignalValue+=1;reject(bad,evidence,"unrelated producer signal");
    bad=info;bad.queueWaitFence=evidence.fence;bad.queueWaitValue=1;reject(bad,evidence,"unsupported queue wait");
    bad=info;bad.transitionCount=0;reject(bad,evidence,"missing transition evidence");
    bad=info;bad.transitionCount=BEAMRT_CAPTURE_MAX_TRANSITIONS+1;reject(bad,evidence,"transition overflow");
    bad=info;bad.transitions[0].before=D3D12_RESOURCE_STATE_COPY_SOURCE;reject(bad,evidence,"broken transition chain");
    bad=info;bad.transitions[0].subresource=0;reject(bad,evidence,"partial-subresource transition");
    bad=info;bad.transitions[1].after=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;reject(bad,evidence,"wrong terminal state");
    bad=info;bad.transitions[0].after=D3D12_RESOURCE_STATE_RENDER_TARGET;reject(bad,evidence,"illegal input write state");
    auto missing=evidence;
    missing.initial[0].known=0;reject(info,missing,"unknown starting state");
    missing=evidence;missing.initial[0].state=D3D12_RESOURCE_STATE_COMMON;reject(info,missing,"implicit state promotion");
    missing=evidence;missing.fixtureSidecarProvided=0;reject(info,missing,"missing fixture sidecar");
    missing=evidence;missing.exclusiveSerializedQueue=0;reject(info,missing,"unserialized queue context");
    missing=evidence;missing.unchangedAfterProducerDraw=0;reject(info,missing,"unknown post-draw states");
    missing=evidence;missing.ownerThread=0;reject(info,missing,"unknown queue owner thread");
    missing=evidence;missing.sidecar.width+=1;reject(info,missing,"wrong receiver dimensions");
    missing=evidence;missing.sidecar.key[0]+=1;reject(info,missing,"stale positive generation key");
    missing=evidence;missing.sidecar.surfelCount=33;reject(info,missing,"surfel overflow");
    missing=evidence;missing.sidecar.surfels[0][3]=std::numeric_limits<float>::quiet_NaN();reject(info,missing,"invalid surfel data");
    missing=evidence;missing.sidecar.scene.materials[0]=4;reject(info,missing,"invalid material data");
    missing=evidence;missing.sidecar.meshState=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;reject(info,missing,"disagreeing sidecar state");
    missing=evidence;missing.device=nullptr;reject(info,missing,"missing device provenance");
    ComPtr<ID3D12Fence> uncompleted;hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&uncompleted)));
    missing=evidence;missing.fence=uncompleted.Get();bad=info;bad.queueSignalFence=uncompleted.Get();
    reject(bad,missing,"uncompleted producer fence");
    missing=evidence;missing.consumerValue=missing.computeValue;reject(info,missing,"compute-only completion schedule");
    missing=evidence;missing.layout=nullptr;reject(info,missing,"missing shader manifest");
    missing=evidence;missing.constantBuffers=nullptr;reject(info,missing,"missing buffer registry");
    bad=info;bad.rootCbvCount=0;reject(bad,evidence,"missing CBV");
    bad=info;bad.rootCbvCount=2;reject(bad,evidence,"extra CBV");
    bad=info;bad.rootCbvs[0].reserved=1;reject(bad,evidence,"unknown CBV metadata");
    bad=info;bad.rootCbvs[0].parameter=0;reject(bad,evidence,"wrong CBV root parameter");
    bad=info;bad.rootCbvs[0].address=256;reject(bad,evidence,"unowned CBV address");
    bad=info;bad.rootCbvs[0].address=0;reject(bad,evidence,"zero CBV address");
    bad=info;bad.rootCbvs[0].address+=1;reject(bad,evidence,"misaligned CBV address");
    bad=info;bad.rootCbvs[0].address=UINT64_MAX & ~UINT64(255);reject(bad,evidence,"near-overflow CBV address");
    bad=info;bad.rootCbvs[0].address=constantBuffer.resource->GetGPUVirtualAddress();
    reject(bad,evidence,"wrong in-range constant offset");
    bad=info;bad.rootCbvs[0].address=constantBuffer.resource->GetGPUVirtualAddress()+512;
    reject(bad,evidence,"CBV outside actual allocation");
    // Only fixture metadata is corrupted; no bad address is submitted to GPU.
    auto badRegistry=constantBuffers;
    auto rejectRegistry=[&](const BeamRTCaptureInfo& observed,const char* label){
        auto supplied=evidence;supplied.constantBuffers=&badRegistry;reject(observed,supplied,label);
        beamrt_fixture::ResolvedConstants candidate=resolved;std::string reason;
        const bool accepted=beamrt_fixture::resolveConstants(device,observed,producerLayout,badRegistry,sidecar.key,candidate,reason);
        require(!accepted && !candidate.resource && candidate.contents.empty() && !candidate.offset && !candidate.span
            && !reason.empty(),"failed CBV resolution leaked stale ownership/contents");
    };
    badRegistry.clear();rejectRegistry(info,"empty buffer registry");
    badRegistry.assign(17,constantBuffer);rejectRegistry(info,"overflowed buffer registry");
    badRegistry=constantBuffers;badRegistry[0].resource.Reset();rejectRegistry(info,"unowned buffer resource");
    badRegistry=constantBuffers;badRegistry[0].resource=static_cast<ID3D12Resource*>(sidecar.receivers);
    rejectRegistry(info,"texture used as CBV buffer");
    badRegistry=constantBuffers;badRegistry[0].uploadMirror.clear();rejectRegistry(info,"missing upload contents");
    badRegistry=constantBuffers;badRegistry[0].uploadMirror.resize(256+payload.size()-1);rejectRegistry(info,"truncated upload contents");
    badRegistry=constantBuffers;badRegistry[0].contentsCurrent=0;rejectRegistry(info,"unverified upload contents");
    badRegistry=constantBuffers;badRegistry[0].unchangedThroughConsumer=0;rejectRegistry(info,"unproven upload lifetime");
    badRegistry=constantBuffers;badRegistry[0].key[0]+=1;rejectRegistry(info,"stale constant generation");
    badRegistry=constantBuffers;badRegistry.push_back(constantBuffer);rejectRegistry(info,"ambiguous buffer ownership");
    auto shortBuffer=make(device,buffer(272),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    badRegistry=constantBuffers;badRegistry[0].resource=shortBuffer;bad=info;bad.rootCbvs[0].address=shortBuffer->GetGPUVirtualAddress()+256;
    rejectRegistry(bad,"CBV padded span exceeds actual allocation");
    auto inaccessible=make(device,buffer(512),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COMMON);
    badRegistry=constantBuffers;badRegistry[0].resource=inaccessible;bad=info;bad.rootCbvs[0].address=inaccessible->GetGPUVirtualAddress()+256;
    rejectRegistry(bad,"GPU-only CBV contents unavailable");
    badRegistry=constantBuffers;float wrong=99;
    std::memcpy(badRegistry[0].uploadMirror.data()+constantOffset,&wrong,sizeof(wrong));
    missing=evidence;missing.constantBuffers=&badRegistry;reject(info,missing,"constant content mismatch");
    wrong=std::numeric_limits<float>::quiet_NaN();
    std::memcpy(badRegistry[0].uploadMirror.data()+constantOffset,&wrong,sizeof(wrong));
    reject(info,missing,"nonfinite constant content");
    capture.stop();

    GIFrameOwner frame;success(BeamRT_GICreateFrame(device,computeShader.data(),computeShader.size(),&frameInputs,&frame.value));
    BeamRT_CaptureReleaseSnapshot(&snapshot.value);
    {
        handoffHost.begin();
        success(BeamRT_GIRecord(frame.value,handoffHost.list.Get()));
        const UINT64 completion=evidence.consumerValue;
        success(BeamRT_GIMarkSubmitted(frame.value,handoffHost.fence.Get(),completion));
        handoffHost.execute();handoffHost.wait();
        beamrt_fixture::ConsumerReceipt receipt{};receipt.queue=handoffHost.queue.Get();receipt.fence=handoffHost.fence.Get();
        receipt.computeValue=handoffHost.sequence;receipt.consumerValue=completion;
        receipt.submission=info.submission;receipt.recordingGeneration=info.recordingGeneration;
        std::memcpy(receipt.key,frameInputs.key,sizeof(receipt.key));
        auto prematureReceipt=receipt;prematureReceipt.finalConsumerSubmitted=1;
        require(!beamrt_fixture::validateConsumerCompletion(evidence,prematureReceipt,validationReason),
                "validator accepted an incomplete final-consumer fence");
        require(BeamRT_GIDestroyFrame(&frame.value)!=0 && frame.value,
                "GI frame retired before the consumer completion fence");
        TestConstants constants{};std::memcpy(constants.key,frameInputs.key,sizeof(constants.key));
        constants.size[0]=static_cast<float>(frameInputs.width);constants.size[1]=static_cast<float>(frameInputs.height);
        constants.enabled=1;constants.index=static_cast<int32_t>(frameInputs.surfelCount-1);
        constants.viewport[2]=constants.viewport[3]=1;
        draw(handoffHost,frame.value,consumerVS,consumerPS,constants,true);
        require(handoffHost.sequence==completion,"completion fence was not placed after the final consumer");
        receipt.consumerValue=handoffHost.sequence;receipt.finalConsumerSubmitted=1;
        const bool completed=beamrt_fixture::validateConsumerCompletion(evidence,receipt,validationReason);
        require(completed,validationReason.c_str());
        auto invalidReceipt=receipt;invalidReceipt.finalConsumerSubmitted=0;
        require(!beamrt_fixture::validateConsumerCompletion(evidence,invalidReceipt,validationReason),"missing consumer receipt accepted");
        invalidReceipt=receipt;invalidReceipt.fence=uncompleted.Get();
        require(!beamrt_fixture::validateConsumerCompletion(evidence,invalidReceipt,validationReason),"unrelated consumer fence accepted");
        invalidReceipt=receipt;invalidReceipt.consumerValue=invalidReceipt.computeValue;
        require(!beamrt_fixture::validateConsumerCompletion(evidence,invalidReceipt,validationReason),"compute-only fence accepted for retirement");
        invalidReceipt=receipt;invalidReceipt.recordingGeneration+=1;
        require(!beamrt_fixture::validateConsumerCompletion(evidence,invalidReceipt,validationReason),"stale consumer recording accepted");
        invalidReceipt=receipt;invalidReceipt.key[0]+=1;
        require(!beamrt_fixture::validateConsumerCompletion(evidence,invalidReceipt,validationReason),"stale consumer generation accepted");
        success(BeamRT_GIDestroyFrame(&frame.value));
    }
    float expectedOutput[4]={0,0,0,control[3]};
    for(int i=0;i<3;++i)expectedOutput[i]=expectedBase[i]+control[i];
    verifyProducerConstants(handoffHost,producerOutput.Get(),expectedOutput);
    // A legal split barrier pair still falls outside this observer's supported
    // full-transition contract. Original GPU calls run; validation must reject.
    captureSuccess(BeamRT_CaptureStart(device,&config,1,&capture.value));
    Host splitHost(device);
    auto splitOutput=drawHandoffProducer(splitHost,sidecar,handoffVS,producerLayout,constantBuffer.resource.Get(),constantOffset,true);
    CaptureSnapshotOwner splitSnapshot;
    captureSuccess(BeamRT_CaptureGetSnapshotForQueue(capture.value,splitHost.queue.Get(),&splitSnapshot.value));
    BeamRTCaptureInfo splitInfo{};captureSuccess(BeamRT_CaptureReadSnapshot(splitSnapshot.value,&splitInfo));
    require(!splitInfo.contextComplete,"split barriers incorrectly certified as full transitions");
    reject(splitInfo,evidence,"split-barrier context");capture.stop();
    std::cout<<"PASS: fail-closed fixture handoff validator; "<<rejected<<" rejected input cases and consumer-fence guards\n";
    std::cout<<"PASS: captured mesh/receiver SRVs -> explicit GI frame -> consumer -> post-consumer fence\n";
    std::cout<<"PASS: reflected producer/consumer layouts; owned CBV at offset 256 changes actual GPU pixels\n";
}
