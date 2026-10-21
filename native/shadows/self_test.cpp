// Isolated sunlight shader regression. All devices, queues, textures, camera
// constants and geometry belong to this executable; no game resource access.
#include "../gi/gpu_fixture_pass.h"
using Shader=FixtureShader;
constexpr UINT width=4,height=2;
static ComPtr<ID3D12Resource> render(Host& host,const std::vector<uint8_t>& vs,const Shader& ps,
    const std::vector<std::pair<UINT,ID3D12Resource*>>& inputs){
    return drawFixture(host,vs,ps,width,height,inputs);
}
// Exactly the existing v1 byte layout, with two opaque, zero-thickness faces.
// The receiver-only prepass contains no caster depth; blockers are mesh data.
static std::vector<uint8_t> meshPixels(float z,float lo=0,float hi=2){
    std::vector<uint8_t> data(256*4);auto word=[&](size_t at,uint32_t value){for(unsigned i=0;i<4;++i)data[at*4+i]=static_cast<uint8_t>(value>>(8*i));};
    auto point=[&](size_t at,float x,float y,float pz){const float c[]={x,y,pz},extent[]={4,2,4};
        for(unsigned a=0;a<3;++a){auto v=static_cast<uint16_t>(std::round(c[a]/extent[a]*65535));data[at*4+a*2]=static_cast<uint8_t>(v);data[at*4+a*2+1]=static_cast<uint8_t>(v>>8);}};
    data[0]=64;data[1]=128;data[2]=192;data[3]=255;data[4]=23;data[5]=101;data[6]=211;data[7]=37;
    point(2,lo,0,z);point(4,hi,2,z);word(6,0);word(7,(1u<<8)|2u);
    point(8,lo,0,z);point(10,hi,0,z);point(12,hi,2,z);data[14*4]=1;
    point(15,lo,0,z);point(17,hi,2,z);point(19,lo,2,z);data[21*4]=1;return data;
}
int wmain(int argc,wchar_t** argv){
    try {
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: sun_shader_test artifact-directory [--warp]");
        const bool warp=argc==3;const std::filesystem::path folder(argv[1]);
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP sunlight shader fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Sunlight shader fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"fixture.vs.cso").c_str());Shader producer(folder/L"producer.ps.cso");
        std::vector<Shader> consumers;for(unsigned i=0;i<4;++i)consumers.emplace_back(folder/(L"consumer"+std::to_wstring(i)+L".ps.cso"));
        producer.vector("eyePosWorld",std::array<float,3>{0,0,0});producer.vector("sunDirection",std::array<float,3>{0,0,1});producer.scalar("meshSunSign",1);
        producer.vector("meshOrigin",std::array<float,3>{0,0,0});producer.vector("meshInvX",std::array<float,3>{1,0,0});
        producer.vector("meshInvY",std::array<float,3>{0,1,0});producer.vector("meshInvZ",std::array<float,3>{0,0,1});
        producer.vector("meshQuantMin",std::array<float,3>{0,0,0});producer.vector("meshQuantExtent",std::array<float,3>{4,2,4});
        producer.scalar("meshNodeCount",1);producer.scalar("meshTriangleCount",2);producer.scalar("meshTriangleOffset",8);
        producer.vector("meshAtlasSize",std::array<float,2>{256,1});producer.scalar("meshMaterialPolicyEnabled",1);producer.scalar("meshVisibilityEnabled",1);
        for(unsigned i=0;i<4;++i)producer.vector(("meshMaterialModes"+std::to_string(i)).c_str(),std::array<float,4>{1,1,1,1});
        producer.vector("projParams",std::array<float,4>{.1f,10,0,1});
        const auto baselineConstants=producer.constants;
        std::vector<Pixel> prepass(width*height,Pixel{.5f,.5f,.5f,0}),positions(width*height);
        std::vector<float> depths(width*height,1);
        for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x)positions[y*width+x]=Pixel{float(x)+.5f,float(y)+.5f,1,1};
        auto upload=[&](UINT w,UINT h,DXGI_FORMAT format,const void* data,UINT bytes){host.begin();auto texture=host.texture(w,h,format,data,bytes);host.execute();host.wait();return texture;};
        auto color=upload(width,height,DXGI_FORMAT_R32G32B32A32_FLOAT,prepass.data(),16);
        auto depth=upload(width,height,DXGI_FORMAT_R32_FLOAT,depths.data(),4);
        auto receivers=upload(width,height,DXGI_FORMAT_R32G32B32A32_FLOAT,positions.data(),16);
        unsigned checks=0,failures=0;
        auto check=[&](bool ok,const char* why){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<why<<'\n';}};
        auto produce=[&](const std::vector<uint8_t>& pixels,ID3D12Resource* receiverDepth=nullptr,ID3D12Resource* receiverColor=nullptr){
            auto mesh=upload(256,1,DXGI_FORMAT_R8G8B8A8_UNORM,pixels.data(),4);
            return render(host,vertex,producer,{{0,receiverColor?receiverColor:color.Get()},{1,receiverDepth?receiverDepth:depth.Get()},{2,mesh.Get()}});
        };
        auto expectMask=[&](ID3D12Resource* mask,float left,float right,const char* why){auto values=readPixels(host,mask);bool ok=true;
            for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x)ok=ok && values[y*width+x][3]==(x<2?left:right);check(ok,why);};
        auto consume=[&](ID3D12Resource* mask,unsigned mode,const std::vector<float>& expected,const char* why,
                        std::array<float,3> offset=std::array<float,3>{0,0,0},ID3D12Resource* receiverDepth=nullptr){
            auto& shader=consumers[mode];shader.vector("receiverOffset",offset);shader.scalar("nativeVisibility",.6f);shader.scalar("cloudVisibility",.8f);
            shader.vector("pixelOffset",std::array<float,2>{0,0});
            auto target=render(host,vertex,shader,{{0,receivers.Get()},{1,receiverDepth?receiverDepth:depth.Get()},{14,mask}});
            auto values=readPixels(host,target.Get());bool ok=true;
            for(size_t i=0;i<values.size();++i){ok=ok && std::isfinite(values[i][3]) && std::abs(values[i][3]-expected[i])<1e-5f;
                for(unsigned c=0;c<3;++c)ok=ok && std::isfinite(values[i][c]) && std::abs(values[i][c]-(.2f+.1f*float(c)+(1+float(c))*expected[i]))<1e-5f;}
            check(ok,why);
        };
        std::vector<float> native(width*height,.6f),cloud(width*height,.8f),hybrid=native,beamrt=cloud,split=native;
        for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x){if(x<2){hybrid[y*width+x]=beamrt[y*width+x]=0;}else split[y*width+x]=.8f;}
        const auto packed=meshPixels(2);auto mask=produce(packed);expectMask(mask.Get(),2,1,"opaque mesh blocker not traced by actual producer");
        auto output=readPixels(host,mask.Get());bool identity=true;for(size_t i=0;i<output.size();++i)for(unsigned c=0;c<3;++c)identity=identity && std::abs(output[i][c]-positions[i][c])<1e-5f;
        check(identity,"producer receiver coordinates differ from independent fixture positions");
        consume(mask.Get(),0,hybrid,"hybrid sunlight changed wrong pixels or ambient term");consume(mask.Get(),1,beamrt,"BeamRT-only sunlight lost cloud visibility");
        consume(mask.Get(),2,cloud,"explicit unshadowed sunlight control incorrect");consume(mask.Get(),3,split,"same-frame sunlight split incorrect");
        auto fullMask=produce(meshPixels(2,0,4));for(UINT y=0;y<height;++y)for(UINT x=2;x<width;++x)split[y*width+x]=0;
        consume(fullMask.Get(),3,split,"split right side did not consume real blocker output");
        consume(mask.Get(),0,native,"stale receiver-position mismatch did not retain native sunlight",{.02f,0,0});
        consume(mask.Get(),0,hybrid,"valid receiver tolerance rejected fresh producer output",{.005f,0,0});
        auto wrongDepth=upload(3,height,DXGI_FORMAT_R32_FLOAT,depths.data(),4);consume(mask.Get(),0,native,"resolution mismatch did not retain native sunlight",{0,0,0},wrongDepth.Get());
        for(float z:{1.0f,1.06f,.5f}){auto close=produce(meshPixels(z));expectMask(close.Get(),1,1,"self/behind/bias-excluded face falsely blocked sun");consume(close.Get(),0,native,"bias-excluded face changed native sunlight");}
        auto close=produce(meshPixels(1.2f));expectMask(close.Get(),2,1,"near face beyond current bias was missed");
        producer.vector("meshInvX",std::array<float,3>{.5f,0,0});auto scaled=produce(packed);expectMask(scaled.Get(),2,2,"nonuniformly scaled sun blocker misplaced");
        producer.constants=baselineConstants;producer.vector("meshOrigin",std::array<float,3>{4,0,0});producer.vector("meshInvX",std::array<float,3>{-1,0,0});
        auto mirrored=produce(packed);expectMask(mirrored.Get(),1,2,"mirrored sun blocker misplaced");producer.constants=baselineConstants;
        auto thin=produce(meshPixels(2,.49f,.51f));auto thinValues=readPixels(host,thin.Get());bool thinOK=true;
        for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x)thinOK=thinOK && thinValues[y*width+x][3]==(x==0?2:1);check(thinOK,"thin zero-thickness mesh blocker missed");
        for(float mode:{0.f,2.f,3.f}){producer.vector("meshMaterialModes0",std::array<float,4>{mode,mode,mode,mode});auto uncertain=produce(packed);
            expectMask(uncertain.Get(),1,1,"uncertain material manufactured opaque sunlight blocker");consume(uncertain.Get(),0,native,"uncertain material changed native sunlight");}
        producer.constants=baselineConstants;producer.scalar("meshVisibilityEnabled",0);auto disabled=produce(packed);expectMask(disabled.Get(),0,0,"OFF producer output not invalid");
        consume(disabled.Get(),0,native,"OFF did not restore native sunlight");consume(disabled.Get(),2,cloud,"unshadowed control depended on mesh relay");
        producer.constants=baselineConstants;auto recovered=produce(packed);consume(recovered.Get(),0,hybrid,"ON after OFF failed to recover");
        auto damaged=packed;damaged[0]=0;auto invalidMesh=produce(damaged);expectMask(invalidMesh.Get(),0,0,"bad mesh header certified sunlight");consume(invalidMesh.Get(),0,native,"bad mesh failed fallback");
        auto unknown=output;for(auto& pixel:unknown)pixel[3]=0;auto empty=upload(width,height,DXGI_FORMAT_R32G32B32A32_FLOAT,unknown.data(),16);
        consume(empty.Get(),0,native,"invalid sentinel failed native fallback");
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity();
        // Red regressions: invalid receiver identity must never certify a dark
        // shadow, and invalid producer inputs must never certify sun visibility.
        auto poisoned=output;for(auto& pixel:poisoned){pixel[0]=nan;pixel[3]=2;}
        auto poison=upload(width,height,DXGI_FORMAT_R32G32B32A32_FLOAT,poisoned.data(),16);
        consume(poison.Get(),0,native,"NaN relay receiver accepted as opaque shadow");
        consume(mask.Get(),0,native,"NaN lighting receiver accepted as matching relay",{nan,0,0});
        for(float bad:{nan,inf}){producer.constants=baselineConstants;producer.vector("sunDirection",std::array<float,3>{0,0,bad});auto invalidSun=produce(packed);
            expectMask(invalidSun.Get(),0,0,"nonfinite sun direction certified sunlight");consume(invalidSun.Get(),0,native,"invalid sun direction changed native lighting");}
        producer.constants=baselineConstants;producer.scalar("meshSunSign",nan);auto invalidSign=produce(packed);expectMask(invalidSign.Get(),0,0,"NaN sun sign certified sunlight");
        producer.constants=baselineConstants;producer.scalar("meshVisibilityEnabled",nan);auto invalidToggle=produce(packed);expectMask(invalidToggle.Get(),0,0,"NaN visibility toggle certified shadow");
        for(float bad:{nan,-1.f}){std::vector<float> invalidDepths(width*height,bad);auto invalidDepth=upload(width,height,DXGI_FORMAT_R32_FLOAT,invalidDepths.data(),4);
            producer.constants=baselineConstants;auto invalidReceiver=produce(packed,invalidDepth.Get());expectMask(invalidReceiver.Get(),0,0,"invalid receiver depth certified sunlight");}
        producer.constants=baselineConstants;producer.vector("eyePosWorld",std::array<float,3>{nan,0,0});auto invalidEye=produce(packed);expectMask(invalidEye.Get(),0,0,"nonfinite camera origin certified sunlight");
        producer.constants=baselineConstants;auto finalMask=produce(packed);consume(finalMask.Get(),0,hybrid,"valid sunlight failed recovery after rejected inputs");
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));std::vector<uint8_t> storage(size);
            auto message=reinterpret_cast<D3D12_MESSAGE*>(storage.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" sunlight producer/consumer GPU checks passed. Debug layer: "<<(debugEnabled?"enabled":"unavailable; not debug-clean proof")<<".\n";
        require(failures==0,"sunlight shader regression failed; no BeamNG execution or installation");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
