// OFFLINE range tests: production v041/v042 trace plus its shared RGB helper.
// Synthetic depth/normal/source fields do not establish in-game appearance.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>
#include <cstdint>
constexpr UINT radianceWidth=32,radianceHeight=16;
static bool sameBits(float a,float b){uint32_t x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);return x==y;}
static Pixel expectedSource(Pixel source,std::array<float,3> weight){
    bool valid=true;for(unsigned c=0;c<3;++c)valid=valid && std::isfinite(source[c]);
    Pixel expected{0,0,0,source[3]};if(!valid)return expected;
    for(unsigned c=0;c<3;++c){expected[c]=std::max(source[c],0.f)*weight[c];valid=valid && std::isfinite(expected[c]);}
    for(unsigned c=0;c<3;++c)expected[c]=valid?std::clamp(expected[c],0.f,65504.f):0.f;return expected;
}
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: reflection_radiance_test artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);const bool warp=argc==3;
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP reflection radiance fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Reflection radiance fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"radiance.vs.cso").c_str());
        FixtureShader helper(folder/L"radiance-helper.ps.cso"),oldTrace(folder/L"beamrtReflectionTraceP_v041.hlsl.ps.cso"),trace(folder/L"beamrtReflectionTraceP_v042.hlsl.ps.cso");
        const size_t count=size_t(radianceWidth)*radianceHeight;unsigned checks=0,failures=0;
        auto check=[&](bool value,const char* message){++checks;if(!value){++failures;std::cerr<<"FAIL: "<<message<<'\n';}};
        auto upload=[&](const std::vector<Pixel>& pixels){host.begin();auto tex=host.texture(radianceWidth,radianceHeight,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return tex;};
        auto uniform=[&](Pixel pixel){return upload(std::vector<Pixel>(count,pixel));};
        // Helper tests include packed-UV extremes and signed lifetime/depth.
        // Output R32 preserves these exact bits; never route packed UV via R16.
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity(),maximum=std::numeric_limits<float>::max();
        const std::vector<Pixel> sources{{.125f,.5f,300.f,0},{0,0,0,1},{-3,.5f,2,-12.5f},
            {1000000,300000,65504,16777216},{65504,65504,65504,1048577},
            {nan,1,2,-1},{1,inf,2,1},{1,2,-inf,2},{maximum,2,3,4097}};
        for(auto weight:{std::array<float,3>{1,1,1},std::array<float,3>{.01f,.02f,.5f},std::array<float,3>{2,2,2}}){
            helper.vector("weighting",weight);
            for(const auto& source:sources){auto input=uniform(source);auto out=drawFixture(host,vertex,helper,radianceWidth,radianceHeight,{{0,input.Get()}});const auto pixels=readPixels(host,out.Get());const Pixel expected=expectedSource(source,weight);
                bool rgb=true,alpha=true;for(const auto& p:pixels){for(unsigned c=0;c<3;++c)rgb=rgb && sameBits(p[c],expected[c]);alpha=alpha && sameBits(p[3],source[3]);}
                check(rgb,"production RGB helper changed finite in-range math or failed invalid/overflow guard");check(alpha,"production RGB helper altered packed UV or signed lifetime bits");
                auto halfInput=uniform(Pixel{source[0],source[1],source[2],1});
                auto half=drawFixture(host,vertex,helper,radianceWidth,radianceHeight,{{0,halfInput.Get()}},DXGI_FORMAT_R16G16B16A16_FLOAT);const auto halfPixels=readPixels(host,half.Get());
                bool bounded=true;for(const auto& p:halfPixels){bounded=bounded && p[3]==1;for(unsigned c=0;c<3;++c)bounded=bounded && std::isfinite(p[c]) && p[c]>=0 && p[c]<=65504;}
                check(bounded,"safe RGB overflowed a real RGBA16F render target");
            }
        }
        auto configure=[&](FixtureShader& shader){
            shader.vector("eyePosWorld",std::array<float,3>{0,0,0});shader.vector("projParams",std::array<float,4>{.1f,10,0,1});
            for(unsigned i=0;i<4;++i)shader.vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});
            shader.scalar("reflectionStepSize",.04f);shader.scalar("reflectionThickness",.3f);shader.scalar("reflectionNormalBias",.001f);
            shader.scalar("reflectionMaxSteps",96);shader.scalar("reflectionMaxDistance",3);shader.scalar("reflectionMaxRoughness",.5f);
            shader.scalar("reflectionSamplingMode",0);shader.scalar("reflectionSampleIndex",0);shader.scalar("reflectionHitAwareEnabled",0);
            shader.scalar("reflectionStableSmoothEnabled",0);shader.scalar("reflectionDebugMode",0);shader.scalar("reflectionColorFilterEnabled",0);
            shader.scalar("reflectionConvergenceEnabled",0);shader.scalar("reflectionSampleCellPixels",1);shader.scalar("reflectionNoiseSeed",0);
            shader.scalar("reflectionSourceFootprintScale",1);shader.vector("reflectionHalfSize",std::array<float,2>{16,8});
        };
        configure(oldTrace);configure(trace);
        // A tilted receiver on the left reflects toward a distinct front-facing
        // vertical surface on the right. Depth is fixture metres, not game data.
        std::vector<Pixel> receivers(count),depths(count);for(UINT y=0;y<radianceHeight;++y)for(UINT x=0;x<radianceWidth;++x){
            const size_t index=size_t(y)*radianceWidth+x;const bool wall=x>=20;
            receivers[index]=wall?Pixel{0,.5f,.02f,0}:Pixel{1,.75f,.02f,0};depths[index]=Pixel{wall?1.f/.99f:1.f,0,0,0};}
        auto surface=upload(receivers),depth=upload(depths),f0=uniform(Pixel{1,1,1,0});
        auto drawTrace=[&](FixtureShader& shader,ID3D12Resource* source,DXGI_FORMAT format){return drawFixture(host,vertex,shader,radianceWidth,radianceHeight,
            {{0,surface.Get()},{1,depth.Get()},{2,source},{3,f0.Get()}},format);};
        auto source=uniform(Pixel{1,.5f,.25f,0});auto before=readPixels(host,drawTrace(oldTrace,source.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());
        auto after=readPixels(host,drawTrace(trace,source.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());
        size_t hits=0;bool identical=true;for(size_t i=0;i<count;++i){if(before[i][0]>0 && before[i][3]>0)++hits;for(unsigned c=0;c<4;++c)identical=identical && sameBits(before[i][c],after[i][c]);}
        std::cout<<"Actual trace synthetic accepted hits: "<<hits<<'\n';check(hits>0,"synthetic scene did not reach actual trace source sampling");check(identical,"v042 changed ordinary finite trace output or geometric metadata");
        auto bright=uniform(Pixel{1000000,1000000,1000000,0});auto oldHalf=readPixels(host,drawTrace(oldTrace,bright.Get(),DXGI_FORMAT_R16G16B16A16_FLOAT).Get());
        auto oldBright=readPixels(host,drawTrace(oldTrace,bright.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());
        auto safeHalf=readPixels(host,drawTrace(trace,bright.Get(),DXGI_FORMAT_R16G16B16A16_FLOAT).Get());
        bool oldOverflow=false,safeBounded=true,brightMetadata=true;for(size_t i=0;i<count;++i){oldOverflow=oldOverflow || !std::isfinite(oldHalf[i][0]);
            for(unsigned c=0;c<3;++c)safeBounded=safeBounded && std::isfinite(safeHalf[i][c]) && safeHalf[i][c]>=0 && safeHalf[i][c]<=65504;
            brightMetadata=brightMetadata && sameBits(oldHalf[i][3],safeHalf[i][3]);}
        float oldMaximum=0,oldHalfMaximum=0;for(size_t i=0;i<count;++i){oldMaximum=std::max(oldMaximum,oldBright[i][0]);oldHalfMaximum=std::max(oldHalfMaximum,oldHalf[i][0]);}
        std::cout<<"Old actual trace max RGB32/RGB16: "<<oldMaximum<<'/'<<oldHalfMaximum<<"; nonfinite half: "<<oldOverflow<<'\n';
        // Raster conversion may clip finite overflow on a given backend. Do
        // not claim an Inf store when the actual readback disproves it.
        auto safeBright=readPixels(host,drawTrace(trace,bright.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());bool explicitBound=true;
        for(size_t i=0;i<count;++i)for(unsigned c=0;c<3;++c)explicitBound=explicitBound && sameBits(safeBright[i][c],std::clamp(oldBright[i][c],0.f,65504.f));
        check(oldMaximum>65504,"synthetic source did not exercise above-half-range contribution");check(explicitBound,"actual v042 did not apply the RGB limit after weighting");
        check(safeBounded,"v042 actual trace still emitted nonfinite/out-of-range half-float RGB");check(brightMetadata,"range guard changed actual trace confidence");
        for(float bad:{nan,inf,-inf}){auto invalid=uniform(Pixel{1,bad,2,0});auto actual=readPixels(host,drawTrace(trace,invalid.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());bool zero=true,metadata=true;
            for(size_t i=0;i<count;++i){for(unsigned c=0;c<3;++c)zero=zero && actual[i][c]==0;metadata=metadata && sameBits(actual[i][3],before[i][3]);}
            check(zero,"actual v042 did not reject a nonfinite source as coherent zero RGB");check(metadata,"source rejection erased accepted geometric metadata");}
        auto nonfiniteSource=uniform(Pixel{1,inf,2,0});auto oldNonfinite=readPixels(host,drawTrace(oldTrace,nonfiniteSource.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());size_t nonfiniteOld=0;
        for(const auto& p:oldNonfinite)if(!std::isfinite(p[1]))++nonfiniteOld;
        std::cout<<"Old actual trace nonfinite RGB32 source results: "<<nonfiniteOld<<'\n';check(nonfiniteOld>0,"old actual trace did not reproduce invalid source propagation");
        // Stable near-polished GGX forces the same geometric direction while
        // still producing the production packed UV metadata in full float.
        for(auto shader:{&oldTrace,&trace}){shader->scalar("reflectionSamplingMode",1);shader->scalar("reflectionHitAwareEnabled",1);shader->scalar("reflectionStableSmoothEnabled",1);}
        auto oldPacked=readPixels(host,drawTrace(oldTrace,bright.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());auto newPacked=readPixels(host,drawTrace(trace,bright.Get(),DXGI_FORMAT_R32G32B32A32_FLOAT).Get());
        bool packedExact=true;size_t packedHits=0;for(size_t i=0;i<count;++i){packedExact=packedExact && sameBits(oldPacked[i][3],newPacked[i][3]);if(oldPacked[i][3]>=1)++packedHits;}
        check(packedHits>0,"synthetic GGX did not produce packed hit UV metadata");check(packedExact,"v042 altered actual packed hit UV metadata bits");
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));std::vector<uint8_t> bytes(size);auto message=reinterpret_cast<D3D12_MESSAGE*>(bytes.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" reflection radiance GPU checks passed; actual v041/v042 trace and production helper; RGBA16F/RGBA32F. Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<". No BeamNG execution.\n";
        require(failures==0,"reflection radiance regression failed");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
