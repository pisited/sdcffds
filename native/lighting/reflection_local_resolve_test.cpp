// OFFLINE display-only resolve tests. Owned synthetic resources only.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>
#include <cstdint>
constexpr UINT localWidth=5,localHeight=5;
constexpr size_t localCount=size_t(localWidth)*localHeight,centerIndex=12;
static bool exact(float a,float b){uint32_t x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);return x==y;}
static bool sampleNear(float a,float b){return std::isfinite(a)&&std::abs(a-b)<.0001f;}
static bool samePixel(const Pixel& a,const Pixel& b){bool same=true;for(unsigned c=0;c<4;++c)same=same&&exact(a[c],b[c]);return same;}
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: local artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);const bool warp=argc==3;
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP reflection local resolve fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Reflection local resolve fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"local.vs.cso").c_str());
        FixtureShader helper(folder/L"local.ps.cso"),oldCompose(folder/L"compose033.ps.cso"),compose(folder/L"compose034.ps.cso");
        unsigned checks=0,failures=0;auto check=[&](bool value,const char* message){++checks;if(!value){++failures;std::cerr<<"FAIL: "<<message<<'\n';}};
        auto upload=[&](UINT w,UINT h,const std::vector<Pixel>& pixels){require(pixels.size()==size_t(w)*h,"bad local fixture extent");host.begin();auto out=host.texture(w,h,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return out;};
        auto uniform=[&](Pixel pixel){return upload(localWidth,localHeight,std::vector<Pixel>(localCount,pixel));};
        const Pixel normal{.5f,.5f,.25f,0},material{.04f,.04f,.04f,0},z{1,0,0,0};
        const std::array<float,4> full{0,0,1,1};
        auto configure=[&](FixtureShader& shader){shader.vector("projParams",std::array<float,4>{.1f,10,0,1});for(unsigned i=0;i<4;++i)shader.vector(("rtParams"+std::to_string(i)).c_str(),full);
            shader.scalar("reflectionStrength",.7f);shader.scalar("reflectionMaxRoughness",.5f);shader.scalar("reflectionSamplingMode",1);shader.scalar("reflectionDebugMode",0);};
        for(auto shader:{&helper,&oldCompose,&compose})configure(*shader);
        for(auto shader:{&helper,&compose}){shader->scalar("reflectionLocalResolveEnabled",1);shader->scalar("reflectionLocalResolveStrength",1);}
        const auto helperDefaults=helper.constants,composeDefaults=compose.constants,oldDefaults=oldCompose.constants;
        auto base=uniform(Pixel{.2f,.3f,.4f,.37f});
        auto run=[&](FixtureShader& shader,const std::vector<Pixel>& reflection,const std::vector<Pixel>& surface,
            const std::vector<Pixel>& f0,const std::vector<Pixel>& depths,UINT dw=localWidth,UINT dh=localHeight){
            auto input=upload(localWidth,localHeight,reflection),prepass=upload(localWidth,localHeight,surface),specular=upload(localWidth,localHeight,f0),depth=upload(dw,dh,depths);
            return readPixels(host,drawFixture(host,vertex,shader,localWidth,localHeight,{{0,base.Get()},{1,input.Get()},{2,prepass.Get()},{3,specular.Get()},{4,depth.Get()}}).Get());};
        std::vector<Pixel> reflection(localCount,Pixel{1,2,3,1}),surface(localCount,normal),f0(localCount,material),depth(localCount,z);
        const auto constant=run(helper,reflection,surface,f0,depth);bool constantPreserved=true;for(size_t i=0;i<localCount;++i){for(unsigned c=0;c<3;++c)constantPreserved=constantPreserved&&sampleNear(constant[i][c],reflection[i][c]);constantPreserved=constantPreserved&&exact(constant[i][3],reflection[i][3]);}
        check(constantPreserved,"uniform HDR field or exact lifetime changed");
        reflection.assign(localCount,Pixel{0,0,0,1});reflection[centerIndex]={1,2,3,1};const auto withZeros=run(helper,reflection,surface,f0,depth);
        check(sampleNear(withZeros[centerIndex][0],.5f)&&sampleNear(withZeros[centerIndex][1],1)&&sampleNear(withZeros[centerIndex][2],1.5f),"valid GGX zero neighbors were omitted from normalized mean");
        reflection.assign(localCount,Pixel{1,2,3,1});reflection[centerIndex]={0,0,0,1};const auto blackCenter=run(helper,reflection,surface,f0,depth);
        check(sampleNear(blackCenter[centerIndex][0],.5f)&&sampleNear(blackCenter[centerIndex][1],1)&&exact(blackCenter[centerIndex][3],1),"valid black estimator center was treated as missing support");
        reflection.assign(localCount,Pixel{0,0,0,1});reflection[centerIndex+1]={100,0,0,1};const auto rareBright=run(helper,reflection,surface,f0,depth);
        check(sampleNear(rareBright[centerIndex][0],12.5f),"rare bright sample was selectively excluded from normalized mean");
        reflection.assign(localCount,Pixel{100,100,100,1});reflection[centerIndex]={1,2,3,0};const auto invalidCenter=run(helper,reflection,surface,f0,depth);
        check(samePixel(invalidCenter[centerIndex],reflection[centerIndex]),"resolve invented lifetime or filled an invalid center");
        reflection[centerIndex]={1,2,3,-1};const auto grace=run(helper,reflection,surface,f0,depth);check(samePixel(grace[centerIndex],reflection[centerIndex]),"resolve filtered a categorical grace-frame lifetime");
        reflection[centerIndex]={1,2,3,1};for(auto& pixel:surface)pixel[2]=.08f;const auto polished=run(helper,reflection,surface,f0,depth);
        check(samePixel(polished[centerIndex],reflection[centerIndex]),"polished reflection detail was filtered");surface.assign(localCount,normal);
        helper.scalar("reflectionSamplingMode",0);const auto mirror=run(helper,reflection,surface,f0,depth);check(samePixel(mirror[centerIndex],reflection[centerIndex]),"mirror mode was filtered");helper.constants=helperDefaults;
        helper.scalar("reflectionDebugMode",6);const auto diagnostic=run(helper,reflection,surface,f0,depth);check(samePixel(diagnostic[centerIndex],reflection[centerIndex]),"diagnostic contribution was filtered");helper.constants=helperDefaults;
        auto ensureCenterOnly=[&](const char* message){check(samePixel(run(helper,reflection,surface,f0,depth)[centerIndex],reflection[centerIndex]),message);};
        f0.assign(localCount,Pixel{.8f,.8f,.8f,0});f0[centerIndex]=material;ensureCenterOnly("thin material island borrowed neighboring reflection");f0.assign(localCount,material);
        surface.assign(localCount,Pixel{1,.5f,.25f,0});surface[centerIndex]=normal;ensureCenterOnly("normal boundary borrowed neighboring reflection");surface.assign(localCount,normal);
        surface.assign(localCount,Pixel{.5f,.5f,.4f,0});surface[centerIndex]=normal;ensureCenterOnly("roughness boundary borrowed neighboring reflection");surface.assign(localCount,normal);
        depth.assign(localCount,Pixel{.5f,0,0,0});depth[centerIndex]=z;for(auto& p:reflection)p[3]=2;reflection[centerIndex][3]=1;
        ensureCenterOnly("foreground depth boundary borrowed neighboring reflection");depth.assign(localCount,z);for(auto& p:reflection)p[3]=1;
        for(size_t i=0;i<localCount;++i)if(i!=centerIndex)reflection[i][3]=0;ensureCenterOnly("invalid neighbor lifetime was treated as valid support");
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity();
        for(size_t i=0;i<localCount;++i)if(i!=centerIndex)reflection[i]={nan,inf,-inf,1};ensureCenterOnly("nonfinite neighbor contaminated a finite center");
        reflection[centerIndex]={nan,1,2,1};const auto poisoned=run(helper,reflection,surface,f0,depth);
        check(poisoned[centerIndex]==Pixel{0,0,0,0},"nonfinite active center did not fail closed to no contribution");
        reflection.assign(localCount,Pixel{0,0,0,1});for(UINT y=0;y<localHeight;++y)reflection[size_t(y)*localWidth]={100,100,100,1};
        helper.vector("rtParams1",std::array<float,4>{.2f,0,.6f,1});const auto cropped=run(helper,reflection,surface,f0,depth);
        check(cropped[11][0]==0&&exact(cropped[11][3],1),"local footprint crossed reflection viewport ownership");helper.constants=helperDefaults;
        reflection.assign(localCount,Pixel{1,2,3,1});reflection[centerIndex]={0,0,0,1};const auto resized=run(helper,reflection,surface,f0,std::vector<Pixel>(100,z),10,10);
        check(sampleNear(resized[centerIndex][0],.5f)&&sampleNear(resized[centerIndex][1],1),"different depth/reflection extents changed receiver ownership");
        // OFF compares the actual versioned composers, not a hand-built formula.
        for(float sampling:{0.f,1.f})for(float diagnosticMode:{0.f,2.f,6.f})for(float strength:{0.f,.7f}){
            oldCompose.constants=oldDefaults;compose.constants=composeDefaults;
            for(auto shader:{&oldCompose,&compose}){shader->scalar("reflectionSamplingMode",sampling);shader->scalar("reflectionDebugMode",diagnosticMode);shader->scalar("reflectionStrength",strength);}
            compose.scalar("reflectionLocalResolveEnabled",0);const auto before=run(oldCompose,reflection,surface,f0,depth),after=run(compose,reflection,surface,f0,depth);bool exactOff=true;
            for(size_t i=0;i<localCount;++i)exactOff=exactOff&&samePixel(before[i],after[i]);check(exactOff,"v034 OFF differs from production v033 composer");}
        compose.constants=composeDefaults;const auto actual=run(compose,reflection,surface,f0,depth);check(sampleNear(actual[centerIndex][0],.55f)&&sampleNear(actual[centerIndex][1],1)&&sampleNear(actual[centerIndex][2],1.45f),"actual composer did not consume local resolve RGB once");
        bool baseAlpha=true;for(const auto& pixel:actual)baseAlpha=baseAlpha&&exact(pixel[3],.37f);check(baseAlpha,"actual composer altered original scene alpha");
        reflection[centerIndex]={nan,inf,-inf,1};const auto invalidComposed=run(compose,reflection,surface,f0,depth);check(samePixel(invalidComposed[centerIndex],Pixel{.2f,.3f,.4f,.37f}),"invalid active reflection did not restore unchanged scene color/alpha");
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));
            std::vector<uint8_t> bytes(size);auto message=reinterpret_cast<D3D12_MESSAGE*>(bytes.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" reflection local resolve GPU checks passed; actual v033/v034 composers and production helper. Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<". No BeamNG execution.\n";
        require(failures==0,"reflection local resolve regression failed");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
