// OFFLINE: compare the real bilinear sampler with production source rejection;
// run actual v042/v043 traces to check disable equivalence and hit metadata.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>
static bool sameBits(float a,float b){uint32_t x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);return x==y;}
static bool close(float a,float b){return std::isfinite(a) && std::abs(a-b)<.0001f;}
// Unlike the generic point-only fixture, source slot 2 must really be LINEAR:
// otherwise the old cross-surface colour leakage would not be reproduced.
static ComPtr<ID3D12Resource> drawSource(Host& host,const std::vector<uint8_t>& vs,const FixtureShader& ps,UINT width,UINT height,
    const std::vector<std::pair<UINT,ID3D12Resource*>>& inputs){
    auto device=host.device.Get();D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=15;
    D3D12_ROOT_PARAMETER params[2]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
    params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[1].DescriptorTable={1,&range};
    D3D12_STATIC_SAMPLER_DESC samplers[15]{};
    for(UINT i=0;i<15;++i){auto& s=samplers[i];s.ShaderRegister=i;
        s.Filter=i==2?D3D12_FILTER_MIN_MAG_MIP_LINEAR:D3D12_FILTER_MIN_MAG_MIP_POINT;
        s.AddressU=s.AddressV=s.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;s.MaxLOD=D3D12_FLOAT32_MAX;
        s.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;s.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;}
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=2;desc.pParameters=params;desc.NumStaticSamplers=15;desc.pStaticSamplers=samplers;
    ComPtr<ID3DBlob> encoded,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors));
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,encoded->GetBufferPointer(),encoded->GetBufferSize(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root.Get();p.VS={vs.data(),vs.size()};p.PS={ps.bytes.data(),ps.bytes.size()};
    p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;p.RasterizerState.DepthClipEnable=TRUE;
    p.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;p.SampleMask=UINT_MAX;
    p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;p.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&pipeline)),"source shader pipeline");
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=width;targetDesc.Height=height;
    targetDesc.DepthOrArraySize=targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;targetDesc.Format=p.RTVFormats[0];targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=make(device,targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    auto cb=make(device,buffer(ps.constants.size()),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);fill(cb.Get(),ps.constants.data(),ps.constants.size());
    D3D12_DESCRIPTOR_HEAP_DESC heap{};heap.NumDescriptors=1;heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    ComPtr<ID3D12DescriptorHeap> rtv;hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&rtv)));device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
    heap.NumDescriptors=15;heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    ComPtr<ID3D12DescriptorHeap> srvs;hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&srvs)));
    const auto stride=device->GetDescriptorHandleIncrementSize(heap.Type);
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{};srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;srv.Texture2D.MipLevels=1;
    srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;srv.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    for(UINT i=0;i<15;++i){auto cpu=srvs->GetCPUDescriptorHandleForHeapStart();cpu.ptr+=i*stride;device->CreateShaderResourceView(nullptr,&srv,cpu);}
    for(const auto& entry:inputs){require(entry.first<15,"source fixture SRV slot overflow");auto cpu=srvs->GetCPUDescriptorHandleForHeapStart();cpu.ptr+=entry.first*stride;
        srv.Format=entry.second->GetDesc().Format;device->CreateShaderResourceView(entry.second,&srv,cpu);}
    host.begin();host.list->SetPipelineState(pipeline.Get());host.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={srvs.Get()};host.list->SetDescriptorHeaps(1,heaps);
    host.list->SetGraphicsRootConstantBufferView(0,cb->GetGPUVirtualAddress());host.list->SetGraphicsRootDescriptorTable(1,srvs->GetGPUDescriptorHandleForHeapStart());
    const D3D12_VIEWPORT viewport{0,0,float(width),float(height),0,1};const D3D12_RECT scissor{0,0,LONG(width),LONG(height)};
    host.list->RSSetViewports(1,&viewport);host.list->RSSetScissorRects(1,&scissor);auto cpu=rtv->GetCPUDescriptorHandleForHeapStart();
    host.list->OMSetRenderTargets(1,&cpu,FALSE,nullptr);host.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);host.list->DrawInstanced(3,1,0,0);
    transition(host.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);host.execute();host.wait();return target;
}
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: source artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);const bool warp=argc==3;
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP reflection source fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Reflection source fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"source.vs.cso").c_str());
        FixtureShader helper(folder/L"source.ps.cso"),oldTrace(folder/L"trace042.ps.cso"),trace(folder/L"trace043.ps.cso");
        unsigned checks=0,failures=0;auto check=[&](bool value,const char* message){++checks;if(!value){++failures;std::cerr<<"FAIL: "<<message<<'\n';}};
        auto upload=[&](UINT width,UINT height,const std::vector<Pixel>& pixels){host.begin();auto texture=host.texture(width,height,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return texture;};
        auto uniform=[&](UINT width,UINT height,Pixel value){return upload(width,height,std::vector<Pixel>(size_t(width)*height,value));};
        const std::array<float,4> full{0,0,1,1};helper.vector("projParams",std::array<float,4>{.1f,10,0,1});
        helper.vector("rtParams0",full);helper.vector("rtParams2",full);helper.vector("acceptedUv",std::array<float,2>{3.75f/8,1.5f/4});helper.scalar("acceptedEyeDepth",.2f);
        auto run=[&](const std::vector<Pixel>& colors,const std::vector<Pixel>& depths,bool enabled,UINT dw=8,UINT dh=4){
            auto color=upload(8,4,colors),depth=upload(dw,dh,depths);helper.scalar("reconstructEnabled",enabled?1.f:0.f);
            return readPixels(host,drawSource(host,vertex,helper,1,1,{{1,depth.Get()},{2,color.Get()}}).Get())[0];};
        std::vector<Pixel> color(32,Pixel{0,0,0,0}),depth(32,Pixel{.5f,0,0,0});
        for(UINT y=0;y<4;++y)for(UINT x=4;x<8;++x){color[y*8+x]={100,20,5,0};depth[y*8+x]={1,0,0,0};}
        const auto leaking=run(color,depth,false),rejected=run(color,depth,true);
        std::cout<<"Cross-depth raw/new red: "<<leaking[0]<<'/'<<rejected[0]<<"; surviving coverage "<<rejected[3]<<'\n';
        check(leaking[0]>20,"old linear source did not reproduce bright foreground leakage");check(rejected[0]==0 && rejected[1]==0 && rejected[2]==0,"new source imported different-depth foreground colour");
        check(close(rejected[3],.75f),"reconstruction did not retain valid black source coverage");
        // A one-pixel dark feature has another layer on BOTH sides. Opposite
        // depth differences cannot establish a plane through either neighbour.
        for(UINT y=0;y<4;++y){depth[y*8+2]={1,0,0,0};color[y*8+2]={100,20,5,0};}
        const auto thin=run(color,depth,true);check(thin[0]==0 && close(thin[3],.75f),"thin-feature depth extrema manufactured a plane into another layer");
        for(UINT y=0;y<4;++y)for(UINT x=0;x<8;++x){color[y*8+x]={float(x),float(x)*.5f,.25f,0};depth[y*8+x]={.5f,0,0,0};}
        const auto detailOld=run(color,depth,false),detailNew=run(color,depth,true);
        check(close(detailNew[0],3.25f) && close(detailNew[0],detailOld[0]) && close(detailNew[1],detailOld[1]),"same-plane subpixel detail was blurred or quantized");check(close(detailNew[3],1),"same-plane coverage was lost");
        for(UINT y=0;y<4;++y)for(UINT x=0;x<8;++x)depth[y*8+x][0]=.5f+.04f*(float(x)-3);
        const auto sloped=run(color,depth,true);check(close(sloped[0],detailOld[0]) && close(sloped[3],1),"reciprocal-depth planar slope was rejected");
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity();
        depth.assign(32,Pixel{.5f,0,0,0});color.assign(32,Pixel{2,4,6,0});for(UINT y=0;y<4;++y)color[y*8+4]={nan,inf,1,0};
        const auto invalidTap=run(color,depth,true);check(close(invalidTap[0],2) && close(invalidTap[1],4) && close(invalidTap[3],.75f),"nonfinite tap contaminated remaining valid radiance");
        color.assign(32,Pixel{nan,inf,-inf,0});const auto invalidAll=run(color,depth,true);check(invalidAll==Pixel{0,0,0,0},"all-invalid source did not become finite black with zero coverage");
        color.assign(32,Pixel{0,0,0,0});const auto black=run(color,depth,true);check(black==Pixel{0,0,0,1},"valid black was mistaken for missing source support");
        depth.assign(32,Pixel{0,0,0,0});const auto sky=run(color,depth,true);check(sky==Pixel{0,0,0,0},"sky depth was accepted as a finite source surface");
        depth.assign(32,Pixel{.5f,0,0,0});for(UINT y=0;y<4;++y)for(UINT x=4;x<8;++x)color[y*8+x]={100,100,100,0};
        helper.vector("rtParams2",std::array<float,4>{0,0,.5f,1});helper.vector("acceptedUv",std::array<float,2>{.9375f,1.5f/4});
        const auto view=run(color,depth,true);check(view[0]==0 && close(view[3],.75f),"source interpolation crossed the source viewport boundary");
        helper.vector("rtParams2",full);helper.vector("acceptedUv",std::array<float,2>{3.75f/8,1.5f/4});
        std::vector<Pixel> largeDepth(128,Pixel{.5f,0,0,0});for(UINT y=0;y<8;++y)for(UINT x=8;x<16;++x)largeDepth[y*16+x]={1,0,0,0};
        const auto resized=run(color,largeDepth,true,16,8);check(resized[0]==0 && close(resized[3],.75f),"different source/depth dimensions lost surface ownership");
        // Actual production traces: same synthetic geometry used by the RGB
        // safety fixture. No real game inputs or inferred camera constants.
        constexpr UINT width=32,height=16;const size_t count=size_t(width)*height;
        auto configure=[&](FixtureShader& shader){
            shader.vector("eyePosWorld",std::array<float,3>{0,0,0});shader.vector("projParams",std::array<float,4>{.1f,10,0,1});
            for(unsigned i=0;i<4;++i)shader.vector(("rtParams"+std::to_string(i)).c_str(),full);
            shader.scalar("reflectionStepSize",.04f);shader.scalar("reflectionThickness",.3f);shader.scalar("reflectionNormalBias",.001f);shader.scalar("reflectionMaxSteps",96);
            shader.scalar("reflectionMaxDistance",3);shader.scalar("reflectionMaxRoughness",.5f);shader.scalar("reflectionSamplingMode",0);shader.scalar("reflectionSampleIndex",0);
            shader.scalar("reflectionHitAwareEnabled",0);shader.scalar("reflectionStableSmoothEnabled",0);shader.scalar("reflectionDebugMode",0);shader.scalar("reflectionColorFilterEnabled",0);
            shader.scalar("reflectionConvergenceEnabled",0);shader.scalar("reflectionSampleCellPixels",1);shader.scalar("reflectionNoiseSeed",0);shader.scalar("reflectionSourceFootprintScale",1);
            shader.vector("reflectionHalfSize",std::array<float,2>{16,8});
        };
        configure(oldTrace);configure(trace);trace.scalar("reflectionSourceReconstructionEnabled",0);
        std::vector<Pixel> surface(count),geometry(count);for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x){const size_t i=size_t(y)*width+x;const bool wall=x>=20;
            surface[i]=wall?Pixel{0,.5f,.02f,0}:Pixel{1,.75f,.02f,0};geometry[i]={wall?1.f/.99f:1.f,0,0,0};}
        auto normals=upload(width,height,surface),z=upload(width,height,geometry),f0=uniform(width,height,Pixel{1,1,1,0}),radiance=uniform(width,height,Pixel{1,.5f,.25f,0});
        auto drawTrace=[&](FixtureShader& shader,ID3D12Resource* source){return readPixels(host,drawSource(host,vertex,shader,width,height,{{0,normals.Get()},{1,z.Get()},{2,source},{3,f0.Get()}}).Get());};
        const auto legacy=drawTrace(oldTrace,radiance.Get()),disabled=drawTrace(trace,radiance.Get());
        bool exact=true;size_t hits=0;for(size_t i=0;i<count;++i){if(legacy[i][3]>0 && legacy[i][0]>0)++hits;for(unsigned c=0;c<4;++c)exact=exact && sameBits(legacy[i][c],disabled[i][c]);}
        check(hits>0,"actual production trace did not reach source sampling");check(exact,"disabled v043 differs from v042");
        trace.scalar("reflectionSourceReconstructionEnabled",1);const auto enabled=drawTrace(trace,radiance.Get());
        bool metadata=true,retained=true;for(size_t i=0;i<count;++i){metadata=metadata && sameBits(enabled[i][3],legacy[i][3]);for(unsigned c=0;c<3;++c)retained=retained && close(enabled[i][c],legacy[i][c]);}
        check(metadata,"source reconstruction changed confidence or geometry decisions");check(retained,"same-plane production trace lost ordinary radiance");
        for(auto shader:{&oldTrace,&trace}){shader->scalar("reflectionSamplingMode",1);shader->scalar("reflectionHitAwareEnabled",1);shader->scalar("reflectionStableSmoothEnabled",1);}
        const auto packedOld=drawTrace(oldTrace,radiance.Get());auto invalidSource=uniform(width,height,Pixel{nan,inf,-inf,0});const auto packedNew=drawTrace(trace,invalidSource.Get());
        bool packedExact=true,zero=true;size_t packedHits=0;for(size_t i=0;i<count;++i){packedExact=packedExact && sameBits(packedOld[i][3],packedNew[i][3]);if(packedOld[i][3]>=1)++packedHits;
            for(unsigned c=0;c<3;++c)zero=zero && packedNew[i][c]==0;}
        check(packedHits>0,"actual production GGX did not produce packed hit metadata");check(packedExact,"invalid source erased accepted packed UV metadata");check(zero,"actual source reconstruction propagated nonfinite colour");
        for(auto shader:{&oldTrace,&trace})shader->scalar("reflectionConvergenceEnabled",1);
        const auto categoryOld=drawTrace(oldTrace,radiance.Get()),categoryNew=drawTrace(trace,invalidSource.Get());bool categories=true;size_t accepted=0;
        for(size_t i=0;i<count;++i){categories=categories && sameBits(categoryOld[i][3],categoryNew[i][3]);if(categoryOld[i][3]==1)++accepted;}
        check(accepted>0 && categories,"zero source changed accepted-geometry convergence categories");
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));
            std::vector<uint8_t> bytes(size);auto message=reinterpret_cast<D3D12_MESSAGE*>(bytes.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" reflection source GPU checks passed; actual v042/v043 traces and production helper. Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<". No BeamNG execution.\n";
        require(failures==0,"reflection source regression failed");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
