#include "test_support.h"
int wmain(int argc,wchar_t** argv) {
    try {
        require(argc>=7 && argc<=10,"usage: self_test fixture.bin visibility.cso consumer.vs.cso consumer.ps.cso handoff.vs.cso handoff.ps.cso [--warp] [--pixel-producer path]");
        bool warp=false;std::vector<uint8_t> pixelShader;
        for(int i=7;i<argc;++i) { if(std::wstring(argv[i])==L"--warp") warp=true;
            else if(std::wstring(argv[i])==L"--pixel-producer") { require(i+1<argc,"pixel producer path missing");pixelShader=file(argv[++i]); }
            else require(false,"unknown option"); }
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled) debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp) { ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP offline GI resource host\n"; }
        else for(UINT i=0;!device;++i) { ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware device unavailable");DXGI_ADAPTER_DESC1 d{};hr(adapter->GetDesc1(&d));if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)))) std::wcout<<L"Offline GI host: "<<d.Description<<L'\n'; }
        Host host(device.Get());auto cs=file(argv[2]),vs=file(argv[3]),ps=file(argv[4]);
        auto handoffVS=file(argv[5]),handoffPS=file(argv[6]);
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
        if(!pixelShader.empty()) {
            auto output=pixelProducer(host,inputs,vs,pixelShader);
            const uint64_t handle=output.copySource->GetCPUDescriptorHandleForHeapStart().ptr;
            draw(host,frame,vs,ps,c,true,handle);c.enabled=0;draw(host,frame,vs,ps,c,false,handle);c.enabled=1;
            std::cout<<"Actual game pixel producer -> exact GI consumer GPU fixture passed\n";
        }
        c.enabled=0;draw(host,frame,vs,ps,c,false);c.enabled=1;draw(host,frame,vs,ps,c,true);c.enabled=0;draw(host,frame,vs,ps,c,false);c.enabled=1;
        c.enabled=std::numeric_limits<float>::quiet_NaN();draw(host,frame,vs,ps,c,false);c.enabled=1;
        for(int i=0;i<3;++i) { c.key[i]+=1;draw(host,frame,vs,ps,c,false);c.key[i]-=1; }
        c.size[0]=3;draw(host,frame,vs,ps,c,false);c.size[0]=2;c.index=32;draw(host,frame,vs,ps,c,false);c.index=31;
        const float invalidViewports[][4]={
            {0,0,-1,1},{0,0,1,-1},{0,0,0,1},{0,0,1,0},
            {-.25f,0,1,1},{0,-.25f,1,1},{0,0,1.25f,1},{0,0,1,1.25f},
            {.75f,0,.5f,1},{0,.75f,1,.5f},
            {std::numeric_limits<float>::quiet_NaN(),0,1,1},
            {0,0,std::numeric_limits<float>::infinity(),1}
        };
        for(unsigned viewportCase=0;viewportCase<12;++viewportCase){
            std::memcpy(c.viewport,invalidViewports[viewportCase],sizeof(c.viewport));
            try{draw(host,frame,vs,ps,c,false);}
            catch(const std::exception& error){throw std::runtime_error("invalid GI viewport case "+std::to_string(viewportCase)+": "+error.what());}
        }
        std::cout<<"PASS: invalid GI viewport metadata preserves baseline contribution (12 cases).\n";
        c.viewport[0]=c.viewport[1]=.25f;c.viewport[2]=c.viewport[3]=.5f;draw(host,frame,vs,ps,c,true);
        c.index=-1;draw(host,frame,vs,ps,c,false);c.index=31;c.key[0]=std::numeric_limits<float>::quiet_NaN();draw(host,frame,vs,ps,c,false);c.key[0]=inputs.key[0];
        require(BeamRT_GIDestroyFrame(&frame)!=0 && frame,"compute completion incorrectly retired a consumer-live frame");
        hr(host.queue->Signal(lifetime.Get(),1));host.wait(); // AFTER the LAST consumer
        success(BeamRT_GIDestroyFrame(&frame));
        float expectedBase[3];for(int i=0;i<3;++i)expectedBase[i]=receivers[0][i]+static_cast<float>(pixels[i])/255.0f;
        testCaptureToGIHandoff(device.Get(),cs,inputs,handoffVS,handoffPS,vs,ps,expectedBase);
        UINT64 completion=1;
        auto fallback=[&](bool inspectUnknown=false) {
            success(create(inputs));host.begin();success(BeamRT_GIRecord(frame,host.list.Get()));success(BeamRT_GIMarkSubmitted(frame,lifetime.Get(),++completion));host.execute();host.wait();
            if(inspectUnknown){expectInvalidVisibility(host,frame);
                if(!pixelShader.empty()){
                    auto invalidPixel=pixelProducer(host,inputs,vs,pixelShader);
                    expectInvalidVisibilityTexture(host,invalidPixel.resource.Get());
                    draw(host,frame,vs,ps,c,false,invalidPixel.copySource->GetCPUDescriptorHandleForHeapStart().ptr);
                }
            }
            draw(host,frame,vs,ps,c,false);hr(host.queue->Signal(lifetime.Get(),completion));host.wait();success(BeamRT_GIDestroyFrame(&frame));
        };
        for(uint32_t mode:{0u,2u,3u}) { for(auto& policy:inputs.scene.materials) policy=mode;fallback(); }
        for(auto& mode:inputs.scene.materials) mode=1;
        receivers[0][3]=0;host.begin();auto invalidReceiver=host.texture(2,1,DXGI_FORMAT_R32G32B32A32_FLOAT,receivers,16);host.execute();host.wait();inputs.receivers=invalidReceiver.Get();fallback();inputs.receivers=receiver.Get();
        auto invalidPixels=pixels;invalidPixels[0]=0;host.begin();auto invalidMesh=host.texture(inputs.scene.atlas[0],inputs.scene.atlas[1],DXGI_FORMAT_R8G8B8A8_UNORM,invalidPixels.data(),4);host.execute();host.wait();inputs.mesh=invalidMesh.Get();fallback();inputs.mesh=mesh.Get();
        // Inspect real GPU texels AND the original-GI fallback for the shared
        // traversal's index-overflow and preorder-link regressions.
        for(unsigned corruption=0;corruption<4;++corruption){
            if(corruption==1 && pixels[(2+5)*4]!=0)continue; // Single-leaf synthetic assets have no internal root.
            invalidPixels=pixels;
            for(uint32_t node=0;node<inputs.scene.counts[0];++node){const size_t base=size_t(2+node*6)*4;
                if(corruption==0 && invalidPixels[base+5*4])for(unsigned byte=0;byte<4;++byte)invalidPixels[base+4*4+byte]=255;
                if(corruption==2 && invalidPixels[base+5*4]){const uint32_t escape=node+2;invalidPixels[base+5*4+1]=static_cast<uint8_t>(escape);
                    invalidPixels[base+5*4+2]=static_cast<uint8_t>(escape>>8);invalidPixels[base+5*4+3]=static_cast<uint8_t>(escape>>16);}
            }
            if(corruption==1){invalidPixels[(2+5)*4+1]=1;invalidPixels[(2+5)*4+2]=invalidPixels[(2+5)*4+3]=0;}
            if(corruption==3)for(uint32_t triangle=0;triangle<inputs.scene.counts[1];++triangle){const size_t at=size_t(inputs.scene.counts[2]+triangle*7)*4;
                std::memcpy(invalidPixels.data()+at+8,invalidPixels.data()+at,8);
                std::memcpy(invalidPixels.data()+at+16,invalidPixels.data()+at,8);}
            host.begin();invalidMesh=host.texture(inputs.scene.atlas[0],inputs.scene.atlas[1],DXGI_FORMAT_R8G8B8A8_UNORM,invalidPixels.data(),4);
            host.execute();host.wait();inputs.mesh=invalidMesh.Get();fallback(true);inputs.mesh=mesh.Get();
        }
        std::cout<<"PASS: malformed BVH GPU mask remains unknown; exact GI consumer preserves baseline lighting.\n";
        success(create(inputs));host.begin();success(BeamRT_GIRecord(frame,host.list.Get()));hr(host.list->Close());host.begin();hr(host.list->Close());
        require(BeamRT_GIDiscardRecorded(frame,0)!=0,"unconfirmed discard accepted");success(BeamRT_GIDiscardRecorded(frame,1));success(BeamRT_GIDestroyFrame(&frame));
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages))) for(UINT64 i=0;i<messages->GetNumStoredMessages();++i) { SIZE_T bytes=0;hr(messages->GetMessage(i,nullptr,&bytes));std::vector<uint8_t> storage(bytes);auto message=reinterpret_cast<D3D12_MESSAGE*>(storage.data());hr(messages->GetMessage(i,message,&bytes));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription); }
        std::cout<<"PASS: GPU producer -> exact GI visibility predicate; opaque-only, 32 bits, OFF/ON/OFF, stale keys/dimensions, viewport mapping, lifetime/discard guards\n";
        std::cout<<"Debug layer: "<<(debugEnabled?"enabled":"unavailable; not debug-clean proof")<<". No BeamNG resources or game attachment.\n";return 0;
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n';return 1; }
}
