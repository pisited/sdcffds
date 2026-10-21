// GPU validation of the independent geometry candidate and actual preview pass.
// Synthetic fixtures do not establish real water ownership, waves or appearance.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>
#include <cstdint>
constexpr UINT waterWidth=8,waterHeight=4;
static bool bitEqual(float a,float b){uint32_t x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);return x==y;}
static bool sampleNear(float a,float b){return std::isfinite(a)&&std::abs(a-b)<0.0001f*std::max(1.f,std::abs(b));}
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: water_receiver_test artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);const bool warp=argc==3;
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP water receiver fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Water receiver fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"water.vs.cso").c_str());FixtureShader helper(folder/L"water-helper.ps.cso"),preview(folder/L"water-preview.ps.cso");
        unsigned checks=0,failures=0;auto check=[&](bool ok,const char* name){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<name<<'\n';}};
        auto allNear=[&](const std::vector<Pixel>& pixels,Pixel expected){bool ok=true;for(const auto& p:pixels)for(unsigned c=0;c<4;++c)ok=ok&&sampleNear(p[c],expected[c]);return ok;};
        auto constants=[&](FixtureShader& shader){shader.vector("waterReceiverPlane",std::array<float,4>{0,1,0,0});shader.vector("waterReceiverBlockMin",std::array<float,4>{-2,-2,0,0});
            shader.vector("waterReceiverBlockMax",std::array<float,4>{2,2,0,0});shader.scalar("waterReceiverMaxDistance",250);};
        constants(helper);helper.vector("fixtureEye",std::array<float,3>{0,0,2});helper.vector("fixtureRay",std::array<float,3>{0,0,-1});
        helper.vector("fixtureOpaque",std::array<float,3>{0,0,-3});helper.scalar("fixtureOpaqueValid",1);helper.scalar("fixtureOutput",0);const auto helperDefaults=helper.constants;
        auto runHelper=[&](){return readPixels(host,drawFixture(host,vertex,helper,waterWidth,waterHeight,{}).Get());};
        check(allNear(runHelper(),Pixel{0,0,0,1}),"plane intersection used submerged opaque floor instead of actual plane height");
        helper.scalar("fixtureOutput",1);check(allNear(runHelper(),Pixel{0,0,1,2}),"flat preview normal or geometric distance incorrect");helper.constants=helperDefaults;
        helper.vector("fixtureRay",std::array<float,3>{0,0,-17});check(allNear(runHelper(),Pixel{0,0,0,1}),"view-ray scale changed water surface intersection");helper.constants=helperDefaults;
        for(float z:{3.f,2.f,1.f,.01f,0.f}){helper.vector("fixtureOpaque",std::array<float,3>{0,0,z});check(allNear(runHelper(),Pixel{0,0,0,0}),"opaque foreground/equal-depth surface failed to occlude water candidate");}helper.constants=helperDefaults;
        for(float z:{0.f,-1.f}){helper.vector("fixtureEye",std::array<float,3>{0,0,z});check(allNear(runHelper(),Pixel{0,0,0,0}),"underwater/on-surface camera fabricated above-water receiver");}helper.constants=helperDefaults;
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity();
        for(auto ray:{std::array<float,3>{0,0,1},std::array<float,3>{1,0,0},std::array<float,3>{1,0,-.000001f},std::array<float,3>{0,0,0},std::array<float,3>{nan,0,-1},std::array<float,3>{0,0,-inf}}){
            helper.vector("fixtureRay",ray);check(allNear(runHelper(),Pixel{0,0,0,0}),"invalid/upward/horizon ray generated water candidate");}helper.constants=helperDefaults;
        for(float limit:{0.f,-1.f,1001.f,nan,inf}){helper.scalar("waterReceiverMaxDistance",limit);check(allNear(runHelper(),Pixel{0,0,0,0}),"invalid maximum distance accepted water candidate");}helper.constants=helperDefaults;
        helper.scalar("waterReceiverMaxDistance",1);check(allNear(runHelper(),Pixel{0,0,0,0}),"water beyond trace distance accepted");helper.constants=helperDefaults;
        helper.vector("fixtureOpaque",std::array<float,3>{nan,0,-3});check(allNear(runHelper(),Pixel{0,0,0,0}),"nonfinite opaque occluder silently certified clear water");helper.constants=helperDefaults;
        helper.vector("waterReceiverPlane",std::array<float,4>{0,0,0,0});helper.vector("waterReceiverBlockMin",std::array<float,4>{-2,-2,0,1});const auto blockDefaults=helper.constants;
        check(allNear(runHelper(),Pixel{0,0,0,2}),"finite WaterBlock interior not identified independently of plane");
        for(float x:{-3.f,-2.f,-1.99f,1.99f,2.f,3.f}){helper.vector("fixtureEye",std::array<float,3>{x,0,2});helper.vector("fixtureOpaque",std::array<float,3>{x,0,-3});check(allNear(runHelper(),Pixel{0,0,0,0}),"finite WaterBlock leaked beyond uncertain shoreline/XY bounds");}helper.constants=blockDefaults;
        helper.vector("waterReceiverBlockMax",std::array<float,4>{-2,2,0,0});check(allNear(runHelper(),Pixel{0,0,0,0}),"degenerate block bounds accepted");helper.constants=blockDefaults;
        helper.vector("waterReceiverPlane",std::array<float,4>{-1,1,0,0});check(allNear(runHelper(),Pixel{0,0,0,2}),"farther ocean plane replaced nearer finite water block");
        helper.vector("waterReceiverPlane",std::array<float,4>{1,1,0,0});check(allNear(runHelper(),Pixel{0,0,1,1}),"nearer ocean plane not selected");helper.constants=helperDefaults;
        helper.scalar("fixtureOpaqueValid",0);helper.vector("fixtureOpaque",std::array<float,3>{0,0,1});check(allNear(runHelper(),Pixel{0,0,0,1}),"explicit absent opaque geometry was treated as a foreground surface");
        auto uniform=[&](Pixel p){std::vector<Pixel> data(size_t(waterWidth)*waterHeight,p);host.begin();auto out=host.texture(waterWidth,waterHeight,DXGI_FORMAT_R32G32B32A32_FLOAT,data.data(),16);host.execute();host.wait();return out;};
        const Pixel source{.2f,.3f,.4f,-7.25f};auto scene=uniform(source),depth=uniform(Pixel{.5f,0,0,0});
        constants(preview);preview.scalar("waterReceiverPreviewEnabled",0);preview.vector("eyePosWorld",std::array<float,3>{0,0,1});preview.vector("projParams",std::array<float,4>{.1f,10,0,1});
        for(unsigned i=0;i<4;++i)preview.vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});
        const auto previewDefaults=preview.constants;
        auto runPreview=[&](ID3D12Resource* receiverDepth=nullptr){return readPixels(host,drawFixture(host,vertex,preview,waterWidth,waterHeight,{{0,scene.Get()},{1,receiverDepth?receiverDepth:depth.Get()}}).Get());};
        bool offExact=true;for(const auto& p:runPreview())for(unsigned c=0;c<4;++c)offExact=offExact&&bitEqual(p[c],source[c]);check(offExact,"preview OFF changed source color or exact alpha");
        preview.scalar("waterReceiverPreviewEnabled",1);check(allNear(runPreview(),Pixel{.07f,.625f,.66f,source[3]}),"actual preview did not tint plane candidates while retaining alpha");
        auto foreground=uniform(Pixel{2,0,0,0});check(allNear(runPreview(foreground.Get()),source),"actual preview drew over opaque geometry in front of water");
        auto invalidDepth=uniform(Pixel{nan,0,0,0});check(allNear(runPreview(invalidDepth.Get()),source),"actual preview treated invalid depth as certified water");
        preview.vector("waterReceiverPlane",std::array<float,4>{0,0,0,0});check(allNear(runPreview(),source),"actual preview tinted view without selected water metadata");
        preview.constants=previewDefaults;preview.scalar("waterReceiverPreviewEnabled",1);preview.vector("projParams",std::array<float,4>{.1f,10,nan,1});check(allNear(runPreview(),source),"invalid camera projection enabled water preview");
        preview.constants=previewDefaults;preview.scalar("waterReceiverPreviewEnabled",1);preview.vector("waterReceiverPlane",std::array<float,4>{0,0,0,0});
        preview.vector("waterReceiverBlockMin",std::array<float,4>{-.2f,-.2f,0,1});preview.vector("waterReceiverBlockMax",std::array<float,4>{.2f,.2f,0,0});
        check(allNear(runPreview(),Pixel{.135f,.365f,.79f,source[3]}),"actual preview failed bounded-block tint/alpha contract");
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));std::vector<uint8_t> bytes(size);auto message=reinterpret_cast<D3D12_MESSAGE*>(bytes.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" water receiver GPU checks passed; geometry helper + actual preview; no wave/ownership/lighting claim. Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<". No BeamNG execution.\n";
        require(failures==0,"water receiver regression failed");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
