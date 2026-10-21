// OFFLINE four-tap helper experiment, not production native SSSR execution.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>
#include <cstdint>
using Footprint=std::array<Pixel,4>;
static bool closeValue(float a,float b){return std::isfinite(a)&&std::abs(a-b)<=0.0001f*std::max(1.f,std::abs(b));}
static bool closePixel(const Pixel& a,const Pixel& b){for(unsigned c=0;c<4;++c)if(!closeValue(a[c],b[c]))return false;return true;}
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: native_ssr_history_test artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);const bool warp=argc==3;
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP native-history helper fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Native-history helper: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"history.vs.cso").c_str());FixtureShader shader(folder/L"history.ps.cso");
        unsigned checks=0,failures=0;auto check=[&](bool ok,const char* name){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<name<<'\n';}};
        auto upload=[&](const Footprint& pixels){host.begin();auto out=host.texture(4,1,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return out;};
        auto uniform=[](Pixel value){Footprint result;result.fill(value);return result;};
        const Footprint geometry=uniform(Pixel{0,0,1,0}),depthMask=uniform(Pixel{1,1,0,0}),black=uniform(Pixel{0,0,0,1});
        shader.vector("currentNormal",std::array<float,3>{0,0,1});shader.scalar("currentDepth",1);shader.scalar("currentClass",0);
        shader.vector("phase",std::array<float,2>{.5f,.5f});shader.scalar("fixtureMode",0);
        shader.scalar("fixtureDecodeNative",1);shader.scalar("fixtureMinimumConfidence",-1);const auto defaults=shader.constants;
        auto run=[&](const Footprint& radiance,const Footprint& normalClass,const Footprint& depth,float mode=0.f){
            shader.scalar("fixtureMode",mode);auto r=upload(radiance),g=upload(normalClass),d=upload(depth);
            return readPixels(host,drawFixture(host,vertex,shader,1,1,{{0,r.Get()},{1,g.Get()},{2,d.Get()}}).Get())[0];};
        Footprint ordinary{{Pixel{.25f,.5f,.75f,.25f},Pixel{1,2,3,1},Pixel{0,0,0,0},Pixel{2,1,.5f,.5f}}};
        for(const auto phase:{std::array<float,2>{0,0},std::array<float,2>{.25f,.75f},std::array<float,2>{.5f,.5f},std::array<float,2>{1,1}}){
            shader.vector("phase",phase);check(closePixel(run(ordinary,geometry,depthMask),run(ordinary,geometry,depthMask,1)),"homogeneous footprint changed ordinary premultiplied RGBA bilinear interpolation");}
        shader.constants=defaults;
        auto edgeGeometry=geometry;edgeGeometry[3]=Pixel{1,0,0,0};auto edgeRadiance=black;edgeRadiance[3]=Pixel{100,100,100,1};
        const auto baseline=run(edgeRadiance,edgeGeometry,depthMask,1),diagnostic=run(edgeRadiance,edgeGeometry,depthMask,2),guarded=run(edgeRadiance,edgeGeometry,depthMask);
        std::cout<<"Mixed-normal model: aggregate confidence="<<diagnostic[0]<<", native fast acceptance="<<diagnostic[1]
            <<", baseline RGB="<<baseline[0]<<", guarded RGB="<<guarded[0]<<", compatible weight="<<diagnostic[3]<<'\n';
        check(diagnostic[0]>.9f && diagnostic[1]==1 && closeValue(baseline[0],25),"fixture did not reproduce native aggregate-acceptance bright-edge counterexample");
        check(closePixel(guarded,Pixel{0,0,0,1}) && closeValue(diagnostic[3],.75f),"orthogonal bright history tap contaminated geometry-compatible black samples");
        auto depthEdge=depthMask;depthEdge[3][0]=10;
        check(closePixel(run(edgeRadiance,geometry,depthEdge),Pixel{0,0,0,1}),"depth-incompatible bright tap contaminated history");
        auto classEdge=geometry;classEdge[3][3]=3;
        check(closePixel(run(edgeRadiance,classEdge,depthMask),Pixel{0,0,0,1}),"water/opaque class mismatch contaminated history");
        auto rejectedGeometry=uniform(Pixel{1,0,0,0});
        check(closePixel(run(edgeRadiance,rejectedGeometry,depthMask),Pixel{0,0,0,0})
            && run(edgeRadiance,rejectedGeometry,depthMask,2)[2]==0,"all-incompatible taps did not return invalid zero history");
        check(closePixel(run(black,geometry,depthMask),Pixel{0,0,0,1}),"valid black reflection lost full coverage");
        const Footprint coveredZero{{Pixel{1,1,1,1},Pixel{0,0,0,1},Pixel{0,0,0,1},Pixel{0,0,0,1}}};
        check(closePixel(run(coveredZero,geometry,depthMask),Pixel{.25f,.25f,.25f,1}),"valid zero estimates were dropped from radiance denominator");
        const Footprint uncovered{{Pixel{1,1,1,1},Pixel{0,0,0,0},Pixel{0,0,0,0},Pixel{0,0,0,0}}};
        check(closePixel(run(uncovered,geometry,depthMask),Pixel{.25f,.25f,.25f,.25f}),"coverage misses renormalized only successful rays");
        const auto brightUniform=uniform(Pixel{65504,65504,65504,.5f});
        check(closePixel(run(brightUniform,geometry,depthMask),brightUniform[0]),"uniform HDR footprint suffered radiance-dependent rejection");
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity();
        const auto one=uniform(Pixel{1,1,1,1});
        for(const Pixel invalid:{Pixel{nan,1,1,1},Pixel{inf,1,1,1},Pixel{1e30f,1,1,1},Pixel{-1,1,1,1},Pixel{1,1,1,nan},Pixel{1,1,1,2},Pixel{1,1,1,0}}){
            auto bad=one;bad[3]=invalid;check(closePixel(run(bad,geometry,depthMask),one[0])
                && closeValue(run(bad,geometry,depthMask,2)[3],.75f),"invalid radiance/coverage tap was used or poisoned compatible history");}
        for(const Pixel invalid:{Pixel{0,0,0,0},Pixel{1e30f,0,1e30f,0},Pixel{nan,0,1,0},Pixel{0,0,1,nan},Pixel{0,0,1,.5f},Pixel{0,0,1,4}}){
            auto bad=geometry;bad[3]=invalid;check(closePixel(run(one,bad,depthMask),one[0])
                && closeValue(run(one,bad,depthMask,2)[3],.75f),"invalid normal/class tap was used or poisoned compatible history");}
        for(const Pixel invalid:{Pixel{0,1,0,0},Pixel{inf,1,0,0},Pixel{1,nan,0,0},Pixel{1,.5f,0,0},Pixel{1,0,0,0}}){
            auto bad=depthMask;bad[3]=invalid;check(closePixel(run(one,geometry,bad),one[0])
                && closeValue(run(one,geometry,bad,2)[3],.75f),"invalid depth/mask tap was used or poisoned compatible history");}
        for(const std::array<float,2> phase:{std::array<float,2>{nan,.5f},std::array<float,2>{-.1f,.5f},std::array<float,2>{.5f,1.1f}}){
            shader.vector("phase",phase);check(closePixel(run(one,geometry,depthMask),Pixel{0,0,0,0}),"invalid footprint phase retained history");}
        shader.constants=defaults;shader.scalar("currentDepth",0);check(closePixel(run(one,geometry,depthMask),Pixel{0,0,0,0}),"invalid current depth retained history");
        shader.constants=defaults;shader.vector("currentNormal",std::array<float,3>{0,0,0});check(closePixel(run(one,geometry,depthMask),Pixel{0,0,0,0}),"invalid current normal retained history");
        shader.constants=defaults;shader.scalar("currentClass",.5f);check(closePixel(run(one,geometry,depthMask),Pixel{0,0,0,0}),"invalid current class retained history");
        // Direct helper inputs skip native packing here. A deliberately lower
        // acceptance threshold must not rehabilitate overflowed finite normals.
        shader.constants=defaults;shader.scalar("fixtureDecodeNative",0);shader.scalar("fixtureMinimumConfidence",.1f);
        auto hugeNormal=geometry;hugeNormal[3]=Pixel{1e30f,0,1e30f,0};
        check(closePixel(run(one,hugeNormal,depthMask),one[0])
            && closeValue(run(one,hugeNormal,depthMask,2)[3],.75f),"direct helper accepted a finite normal whose squared length overflowed");
        shader.vector("currentNormal",std::array<float,3>{1e30f,0,1e30f});
        check(closePixel(run(one,geometry,depthMask),Pixel{0,0,0,0}),"direct helper retained history for overflowed finite current normal");
        std::cout<<checks-failures<<'/'<<checks<<" native-history helper GPU checks passed. Native packing/config included; aggregate acceptance is a model, not full native pass. Debug layer: "
            <<(debugEnabled?"enabled":"unavailable")<<". Not deployed; no BeamNG execution.\n";
        require(failures==0,"native-history helper regression failed");return 0;
    }catch(const std::exception& e){std::cerr<<"Native-history helper failed: "<<e.what()<<'\n';return 1;}
}
