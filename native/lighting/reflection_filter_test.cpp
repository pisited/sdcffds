// Actual optional reflection shaders. Synthetic receiver/estimator fields,
// not proof of the user's scene, game ordering or render cost.
#include "../gi/gpu_fixture_pass.h"
constexpr UINT filterWidth=32,filterHeight=16;
static bool nearValue(float a,float b){return std::isfinite(a) && std::abs(a-b)<1e-3f*std::max(1.f,std::abs(b));}
static std::pair<double,double> statistics(const std::vector<Pixel>& pixels){
    double mean=0,variance=0;for(const auto& p:pixels)mean+=p[0];mean/=pixels.size();
    for(const auto& p:pixels)variance+=(p[0]-mean)*(p[0]-mean);return {mean,variance/pixels.size()};
}
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: reflection_filter_test artifacts [--warp]");
        const bool warp=argc==3;const std::filesystem::path folder(argv[1]);
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP reflection filter fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Reflection filter fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());auto vertex=file((folder/L"fixture.vs.cso").c_str());
        FixtureShader filter(folder/L"beamrtReflectionAtrousP_v003.hlsl.ps.cso"),single(folder/L"beamrtReflectionAtrousP_v002.hlsl.ps.cso"),moments(folder/L"beamrtReflectionMomentsP_v001.hlsl.ps.cso");
        auto common=[&](FixtureShader& shader){shader.vector("targetSize",std::array<float,2>{float(filterWidth),float(filterHeight)});
            shader.vector("projParams",std::array<float,4>{.1f,10,0,1});for(unsigned i=0;i<4;++i)shader.vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});};
        common(filter);common(single);common(moments);
        for(auto shader:{&filter,&single}){shader->scalar("reflectionVarianceStrength",.65f);shader->scalar("reflectionVarianceScale",1);shader->scalar("reflectionMaxRoughness",.34f);}
        filter.scalar("reflectionAtrousStep",1);moments.scalar("reflectionHistoryDepthTolerance",.01f);moments.scalar("reflectionMaxRoughness",.34f);
        moments.scalar("reflectionMomentsMaxHistory",32);moments.scalar("reflectionHistoryValid",0);
        const size_t count=size_t(filterWidth)*filterHeight;unsigned checks=0,failures=0;
        auto check=[&](bool ok,const char* name){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<name<<'\n';}};
        auto upload=[&](const std::vector<Pixel>& pixels){host.begin();auto tex=host.texture(filterWidth,filterHeight,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return tex;};
        auto uniform=[&](Pixel p){return upload(std::vector<Pixel>(count,p));};
        auto surface=uniform(Pixel{.5f,.5f,.24f,0}),depth=uniform(Pixel{1,0,0,0}),f0=uniform(Pixel{.04f,.04f,.04f,0});
        auto guide=uniform(Pixel{.125f,.03125f,32,.1f}),velocity=uniform(Pixel{0,0,0,0});
        auto draw=[&](FixtureShader& shader,ID3D12Resource* input,ID3D12Resource* receiver,ID3D12Resource* z,ID3D12Resource* material,ID3D12Resource* stats){
            return drawFixture(host,vertex,shader,filterWidth,filterHeight,{{0,input},{1,receiver},{2,z},{3,stats},{4,material}},DXGI_FORMAT_R16G16B16A16_FLOAT);};
        auto chain=[&](ID3D12Resource* input,unsigned passes,ID3D12Resource* receiver=nullptr,ID3D12Resource* z=nullptr,ID3D12Resource* material=nullptr,ID3D12Resource* stats=nullptr){
            ComPtr<ID3D12Resource> result=input;for(unsigned i=0;i<passes;++i){filter.scalar("reflectionAtrousStep",float(1u<<i));
                result=draw(filter,result.Get(),receiver?receiver:surface.Get(),z?z:depth.Get(),material?material:f0.Get(),stats?stats:guide.Get());}return readPixels(host,result.Get());};
        auto equals=[&](const std::vector<Pixel>& actual,Pixel expected){bool ok=true;for(const auto& p:actual)for(unsigned c=0;c<4;++c)ok=ok && nearValue(p[c],expected[c]);return ok;};
        auto matches=[&](const std::vector<Pixel>& actual,const std::vector<Pixel>& expected){bool ok=true;for(size_t i=0;i<count;++i)for(unsigned c=0;c<4;++c)ok=ok && nearValue(actual[i][c],expected[i][c]);return ok;};
        for(float level:{0.f,.03125f,.25f,300.f}){auto input=uniform(Pixel{level,level,level,1});check(equals(chain(input.Get(),3),Pixel{level,level,level,1}),"uniform radiance/zero estimator changed by three scales");}
        for(float alpha:{0.f,-1.f}){auto input=uniform(Pixel{.25f,.125f,.0625f,alpha});check(equals(chain(input.Get(),3),Pixel{.25f,.125f,.0625f,alpha}),"invalid/grace lifetime was manufactured or filtered");}
        std::vector<Pixel> noise(count);uint32_t seed=0x51f4a7u;
        for(auto& p:noise){seed=seed*1664525u+1013904223u;const float value=(seed&0x80000000u)?.25f:0.f;p=Pixel{value,value,value,1};}
        auto noisy=upload(noise);const auto one=chain(noisy.Get(),1),three=chain(noisy.Get(),3);
        const auto rawStats=statistics(noise),oneStats=statistics(one),threeStats=statistics(three);
        std::cout<<"Controlled noise variance raw/one/three: "<<rawStats.second<<'/'<<oneStats.second<<'/'<<threeStats.second
            <<"; means: "<<rawStats.first<<'/'<<oneStats.first<<'/'<<threeStats.first<<'\n';
        check(oneStats.second<rawStats.second,"one-scale filter did not reduce controlled variance");
        check(threeStats.second<oneStats.second*.70,"three scales did not reduce controlled variance beyond one scale");
        check(std::abs(threeStats.first-rawStats.first)<rawStats.first*.06,"noise reduction darkened/brightened controlled mean excessively");
        bool sameLifetime=true;for(const auto& p:three)sameLifetime=sameLifetime && p[3]==1;check(sameLifetime,"three scales changed signed depth metadata");
        auto oldSingle=draw(single,noisy.Get(),surface.Get(),depth.Get(),f0.Get(),guide.Get());check(matches(readPixels(host,oldSingle.Get()),one),"step one changed the existing valid one-scale filter");
        filter.scalar("reflectionVarianceStrength",0);check(matches(chain(noisy.Get(),3),noise),"zero strength did not preserve original temporal color");filter.scalar("reflectionVarianceStrength",.65f);
        auto polished=uniform(Pixel{.5f,.5f,.04f,0});check(matches(chain(noisy.Get(),3,polished.Get()),chain(noisy.Get(),1,polished.Get())),"wide scales blurred near-polished reflection detail");
        // High contrast with different receiver identity. Every scale must
        // preserve the boundary, not trade silhouettes/materials for less grain.
        for(unsigned kind=0;kind<4;++kind){std::vector<Pixel> split(count),surfaces(count,Pixel{.5f,.5f,.24f,0}),depths(count,Pixel{1,0,0,0}),materials(count,Pixel{.04f,.04f,.04f,0}),guides(count,Pixel{1,2,32,.1f});
            for(UINT y=0;y<filterHeight;++y)for(UINT x=0;x<filterWidth;++x){const size_t i=size_t(y)*filterWidth+x;const bool right=x>=filterWidth/2;const float value=right?2.f:0.f;split[i]=Pixel{value,value,value,1};
                if(right){if(kind==0){depths[i][0]=2;guides[i][3]=.2f;split[i][3]=2;}if(kind==1)surfaces[i][0]=1;if(kind==2)surfaces[i][2]=.8f;if(kind==3)materials[i]=Pixel{.8f,.8f,.8f,0};}}
            auto colors=upload(split),receivers=upload(surfaces),zs=upload(depths),fs=upload(materials),gs=upload(guides);
            check(matches(chain(colors.Get(),3,receivers.Get(),zs.Get(),fs.Get(),gs.Get()),split),"filter crossed a depth/normal/roughness/F0 boundary");}
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity();
        for(float bad:{nan,inf}){auto badGuide=uniform(Pixel{bad,1,32,.1f});check(matches(chain(noisy.Get(),3,nullptr,nullptr,nullptr,badGuide.Get()),noise),"invalid moment guide poisoned temporal color");}
        auto staleGuide=uniform(Pixel{.125f,.03125f,32,.2f});check(matches(chain(noisy.Get(),3,nullptr,nullptr,nullptr,staleGuide.Get()),noise),"stale receiver moments were used as a current guide");
        const size_t center=size_t(filterHeight/2)*filterWidth+filterWidth/2;
        for(float alpha:{0.f,1.f}){std::vector<Pixel> invalid(count,Pixel{inf,inf,inf,alpha});invalid[center]=Pixel{.25f,.125f,.0625f,1};auto tex=upload(invalid);auto actual=chain(tex.Get(),3);
            bool ok=true;for(unsigned c=0;c<4;++c)ok=ok && nearValue(actual[center][c],invalid[center][c]);check(ok,"nonfinite zero/fresh neighbors poisoned a valid center");}
        std::vector<Pixel> impulse(count,Pixel{0,0,0,1});impulse[center]=Pixel{.25f,.25f,.25f,1};auto impulseTex=upload(impulse);auto impulseResult=chain(impulseTex.Get(),3);
        check(impulseResult[center][0]>0 && impulseResult[center][0]<.25f && impulseResult[center][3]==1,"valid zero neighbors were incorrectly rejected as misses");
        for(auto& p:impulse)p[3]=0;impulse[center][3]=1;auto unsupported=upload(impulse);auto unsupportedResult=chain(unsupported.Get(),3);
        check(nearValue(unsupportedResult[center][0],.25f),"invalid lifetime neighbors diluted valid reflection energy");
        // Moments use actual raw estimator samples, never filtered output.
        auto raw=uniform(Pixel{300,300,300,1}),oldGuide=uniform(Pixel{.125f,.03125f,4,.1f});
        auto momentDraw=[&](ID3D12Resource* input,ID3D12Resource* old){return drawFixture(host,vertex,moments,filterWidth,filterHeight,
            {{0,input},{1,surface.Get()},{2,depth.Get()},{3,velocity.Get()},{4,old}});};
        auto hdrMoments=momentDraw(raw.Get(),oldGuide.Get());check(equals(readPixels(host,hdrMoments.Get()),Pixel{300,90000,1,.1f}),"reflection HDR moments clipped squared luminance");
        auto zero=uniform(Pixel{0,0,0,0});check(equals(readPixels(host,momentDraw(zero.Get(),oldGuide.Get()).Get()),Pixel{0,0,1,.1f}),"zero raw GGX estimator was not counted");
        moments.scalar("reflectionHistoryValid",1);auto poison=uniform(Pixel{nan,1,4,.1f});
        check(equals(readPixels(host,momentDraw(raw.Get(),poison.Get()).Get()),Pixel{300,90000,1,.1f}),"invalid reflection moment history did not restart");
        auto invalidRaw=uniform(Pixel{nan,1,1,1});check(equals(readPixels(host,momentDraw(invalidRaw.Get(),oldGuide.Get()).Get()),Pixel{0,0,0,0}),"invalid current reflection created usable moments");
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));std::vector<uint8_t> bytes(size);auto message=reinterpret_cast<D3D12_MESSAGE*>(bytes.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" actual reflection filter GPU checks passed; R16F color, R32F moments. Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<".\n";
        require(failures==0,"reflection filter regression failed; no BeamNG execution");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
