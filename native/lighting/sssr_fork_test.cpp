// Offline execution of owned native-derived traversal and production adapter.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>
int wmain(int argc,wchar_t** argv) {
  try {
    require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: sssr_fork_test artifacts [--warp]");
    const std::filesystem::path folder(argv[1]); const bool warp=argc==3;
    ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
    ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
    if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP SSSR fork\n";}
    else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware unavailable");DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<desc.Description<<L'\n';}
    Host host(device.Get()); const UINT w=32,h=16;const size_t count=size_t(w)*h;
    auto vertex=file((folder/L"fork.vs.cso").c_str()),coreVertex=file((folder/L"core.vs.cso").c_str());
    auto composeVertex=file((folder/L"compose.vs.cso").c_str());
    auto temporalVertex=file((folder/L"temporal.vs.cso").c_str());
    FixtureShader core(folder/L"core.ps.cso"),trace(folder/L"fork.ps.cso");
    unsigned checks=0,failures=0;auto check=[&](bool ok,const char* message){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<message<<'\n';}};
    auto upload=[&](const std::vector<Pixel>& pixels){host.begin();auto out=host.texture(w,h,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return out;};
    auto uniform=[&](Pixel pixel){return upload(std::vector<Pixel>(count,pixel));};
    auto runCore=[&](float depth){auto d=uniform(Pixel{depth,0,0,0});return readPixels(host,drawFixture(host,coreVertex,core,1,1,{{0,d.Get()}}).Get())[0];};
    core.vector("origin",std::array<float,3>{.1f,.5f,.1f});core.vector("direction",std::array<float,3>{.6f,0,.4f});core.scalar("budget",100);
    auto hit=runCore(.3f);check(hit[3]==1 && std::abs(hit[0]-.4f)<.001f && std::abs(hit[2]-.3f)<.001f,"owned pixel-plane traversal missed known plane");
    core.scalar("budget",0);check(runCore(.3f)[3]==0,"budget exhaustion became a hit");core.scalar("budget",100);
    check(runCore(1)[3]==0,"sky became opaque geometry");
    core.vector("direction",std::array<float,3>{.6f,0,0});check(runCore(.3f)[3]==0,"parallel ray became a hit");
    core.vector("origin",std::array<float,3>{.9f,.5f,.1f});core.vector("direction",std::array<float,3>{-.6f,0,.4f});
    hit=runCore(.3f);check(hit[3]==1 && std::abs(hit[0]-.6f)<.001f,"negative-axis traversal missed known plane");
    auto configure=[&](bool reverse){
      trace.vector("eyePosWorld",std::array<float,3>{0,0,0});
      trace.vector("projParams",std::array<float,4>{.1f,10,reverse?-.01010101f:1.01010101f,reverse?.1010101f:-.1010101f});
      for(unsigned i=0;i<4;++i)trace.vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});
      trace.scalar("reflectionStepSize",.04f);trace.scalar("reflectionThickness",.3f);trace.scalar("reflectionNormalBias",.001f);
      trace.scalar("reflectionMaxSteps",96);trace.scalar("reflectionMaxDistance",3);trace.scalar("reflectionMaxRoughness",.5f);
      trace.scalar("reflectionSamplingMode",0);trace.scalar("reflectionSampleIndex",0);trace.scalar("reflectionHitAwareEnabled",0);trace.scalar("reflectionStableSmoothEnabled",0);
      trace.scalar("reflectionDebugMode",0);trace.scalar("reflectionColorFilterEnabled",0);trace.scalar("reflectionConvergenceEnabled",0);
      trace.scalar("reflectionSampleCellPixels",1);trace.scalar("reflectionNoiseSeed",0);trace.scalar("reflectionSourceFootprintScale",1);
      trace.scalar("reflectionSourceReconstructionEnabled",0);trace.vector("reflectionHalfSize",std::array<float,2>{16,8});
      trace.vector("reflectionForkWork",std::array<float,2>{0,0});
    };
    auto f0=uniform(Pixel{1,1,1,0}),source=uniform(Pixel{1,.5f,.25f,0});
    for(bool reverse:{false,true}) {
      configure(reverse);std::vector<Pixel> normals(count),depths(count);
      for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x){const size_t i=size_t(y)*w+x;const bool wall=x>=22;const bool gap=x==21;
        const float uv=(float(x)+.5f)/float(w),z=wall?.35f/(uv-.5f):1.f;
        float ndc=1.01010101f-.1010101f/z;if(gap)ndc=1;if(reverse)ndc=1-ndc;
        normals[i]=wall?Pixel{0,.5f,.02f,0}:Pixel{1,.75f,.02f,0};depths[i]=Pixel{ndc,0,0,0};}
      auto n=upload(normals),d=upload(depths);
      auto run=[&](ID3D12Resource* color){return readPixels(host,drawFixture(host,vertex,trace,w,h,{{0,n.Get()},{1,d.Get()},{2,color},{3,f0.Get()}}).Get());};
      auto pixels=run(source.Get());size_t hits=0;bool finite=true;for(const auto& p:pixels){if(p[3]>0 && p[0]>0)++hits;for(float v:p)finite=finite&&std::isfinite(v);}
      std::cout<<"Production fork hits (reverse="<<reverse<<"): "<<hits<<'\n';
      check(hits>0,"production fork adapter did not reach reflected source");check(finite,"production adapter emitted nonfinite values");
      trace.scalar("reflectionDebugMode",1);auto receivers=run(source.Get());
      trace.scalar("reflectionDebugMode",2);auto validity=run(source.Get());bool classified=true;
      for(size_t i=0;i<count;++i)if(receivers[i][1]==1 && receivers[i][0]==0)
        classified=classified&&(validity[i][0]!=0 || validity[i][1]!=0 || validity[i][2]!=0);
      check(classified,"eligible fork failure remained unclassified black in validity view");
      trace.scalar("reflectionDebugMode",8);trace.vector("reflectionForkWork",std::array<float,2>{5,64});
      auto reasons=run(source.Get());bool budgetReason=false;
      for(const auto& p:reasons)budgetReason=budgetReason||(p[0]==1&&p[1]==0&&p[2]==1);
      check(budgetReason,"bounded work exhaustion did not report budget reason");
      trace.scalar("reflectionDebugMode",0);trace.vector("reflectionForkWork",std::array<float,2>{2048,64});
      auto extended=run(source.Get());size_t extendedHits=0;bool extendedFinite=true;
      for(const auto& p:extended){if(p[3]>0&&p[0]>0)++extendedHits;for(float v:p)extendedFinite=extendedFinite&&std::isfinite(v);}
      check(extendedHits>=hits&&extendedFinite,"extended work lost known local hits or emitted invalid values");
      trace.vector("reflectionForkWork",std::array<float,2>{0,0});
      // Scale the same coherent scene 8x; default physical reach cannot reach
      // distant wall hits. The lab may extend reach, not bypass validation.
      auto originalDepth=d;std::vector<Pixel> distantDepths(count);
      for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x){const float uv=(float(x)+.5f)/float(w);
        const float z=x>=22?2.8f/(uv-.5f):8.f;float ndc=1.001001f-.1001001f/z;
        if(x==21)ndc=1;if(reverse)ndc=1-ndc;distantDepths[size_t(y)*w+x]=Pixel{ndc,0,0,0};}
      trace.vector("projParams",std::array<float,4>{.1f,100,reverse?-.001001f:1.001001f,reverse?.1001001f:-.1001001f});
      d=upload(distantDepths);auto shortReach=run(source.Get());
      trace.vector("reflectionForkWork",std::array<float,2>{2048,64});auto longReach=run(source.Get());
      size_t shortHits=0,longHits=0;
      for(UINT y=0;y<h;++y)for(UINT x=0;x<21;++x){const size_t i=size_t(y)*w+x;
        if(shortReach[i][3]>0&&shortReach[i][0]>0)++shortHits;if(longReach[i][3]>0&&longReach[i][0]>0)++longHits;}
      check(longHits>shortHits,"lab extended reach did not recover a known distant reflection");
      std::cout<<"Distant receiver hits (reverse="<<reverse<<"): normal="<<shortHits<<", extended="<<longHits<<'\n';
      d=originalDepth;configure(reverse);
      auto black=uniform(Pixel{0,0,0,0});auto dark=run(black.Get());bool validZero=true;for(size_t i=0;i<count;++i)validZero=validZero&&dark[i][0]==0&&dark[i][1]==0&&dark[i][2]==0&&dark[i][3]==pixels[i][3];
      check(validZero,"valid black source changed geometric confidence");
      auto invalid=uniform(Pixel{std::numeric_limits<float>::infinity(),1,2,0});auto rejected=run(invalid.Get());bool safe=true;for(size_t i=0;i<count;++i)safe=safe&&rejected[i][0]==0&&rejected[i][1]==0&&rejected[i][2]==0&&rejected[i][3]==pixels[i][3];
      check(safe,"invalid source was rehabilitated or erased geometric confidence");
      auto validDepth=d;
      d=uniform(Pixel{std::numeric_limits<float>::quiet_NaN(),0,0,0});
      auto unknown=run(source.Get());bool empty=true;for(const auto& p:unknown)for(float v:p)empty=empty&&v==0;
      check(empty,"unknown depth evidence became a reflection");d=validDepth;
      trace.scalar("reflectionSamplingMode",1);trace.scalar("reflectionHitAwareEnabled",1);trace.scalar("reflectionStableSmoothEnabled",1);
      auto packed=run(source.Get());size_t packedHits=0;for(const auto& p:packed)if(p[3]>=1)++packedHits;
      check(packedHits>0,"fork did not preserve existing packed-hit output contract");
      trace.scalar("reflectionHitAwareEnabled",0);trace.scalar("reflectionStableSmoothEnabled",0);trace.scalar("reflectionDebugMode",9);
      normals.assign(count,Pixel{1,.75f,.2f,0});n=upload(normals);trace.scalar("reflectionSampleIndex",1);auto first=run(source.Get());trace.scalar("reflectionSampleIndex",2);auto second=run(source.Get());bool changes=false;
      for(size_t i=0;i<count;++i)changes=changes||first[i][0]!=second[i][0]||first[i][1]!=second[i][1]||first[i][2]!=second[i][2];
      check(changes,"fork GGX sample index did not change reflected directions");
    }
    // Exercise actual composers: gain is display-only, not a validity repair.
    FixtureShader oldCompose(folder/L"compose034.ps.cso"),compose(folder/L"compose035.ps.cso");
    for(auto shader:{&oldCompose,&compose}){
      for(unsigned i=0;i<4;++i)shader->vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});
      shader->vector("projParams",std::array<float,4>{.1f,10,0,1});
      shader->scalar("reflectionStrength",.75f);shader->scalar("reflectionMaxRoughness",.65f);
      shader->scalar("reflectionSamplingMode",1);shader->scalar("reflectionDebugMode",0);
      shader->scalar("reflectionLocalResolveEnabled",0);shader->scalar("reflectionLocalResolveStrength",.35f);
    }
    auto base=uniform(Pixel{.2f,.3f,.4f,.37f}),reflected=uniform(Pixel{.1f,.2f,.3f,1});
    auto material=uniform(Pixel{.04f,.04f,.04f,0}),surface=uniform(Pixel{.5f,.5f,.2f,0}),depth=uniform(Pixel{.5f,0,0,0});
    auto composeRun=[&](FixtureShader& shader){return readPixels(host,drawFixture(host,composeVertex,shader,w,h,
      {{0,base.Get()},{1,reflected.Get()},{2,surface.Get()},{3,material.Get()},{4,depth.Get()}}).Get());};
    auto reference=composeRun(oldCompose);compose.scalar("reflectionLabGain",1);auto normal=composeRun(compose);
    check(reference==normal,"Normal lab profile changed the production composer");
    compose.scalar("reflectionLabGain",8);auto punch=composeRun(compose);bool eightfold=true,alphaPreserved=true;
    const Pixel basePixel{.2f,.3f,.4f,.37f};
    for(size_t i=0;i<count;++i){for(unsigned c=0;c<3;++c)eightfold=eightfold&&std::abs((punch[i][c]-basePixel[c])-8*(normal[i][c]-basePixel[c]))<.0001f;
      alphaPreserved=alphaPreserved&&punch[i][3]==basePixel[3];}
    check(eightfold&&alphaPreserved,"8x lab gain altered base lighting/alpha or was applied more than once");
    for(float invalidGain:{std::numeric_limits<float>::quiet_NaN(),std::numeric_limits<float>::infinity(),0.f}){
      compose.scalar("reflectionLabGain",invalidGain);check(composeRun(compose)==normal,"invalid/unset lab gain did not preserve normal output");}
    compose.scalar("reflectionLabGain",8);reflected=uniform(Pixel{1,1,1,0});auto misses=composeRun(compose);
    bool unchangedMiss=true;for(const auto& p:misses)unchangedMiss=unchangedMiss&&p==basePixel;
    check(unchangedMiss,"display gain invented a reflection from an invalid hit");
    FixtureShader oldTemporal(folder/L"temporal039.ps.cso"),temporal(folder/L"temporal040.ps.cso");
    for(auto shader:{&oldTemporal,&temporal}){
      for(unsigned i=0;i<4;++i)shader->vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});
      shader->vector("projParams",std::array<float,4>{.1f,10,0,1});
      shader->vector("targetSize",std::array<float,2>{float(w),float(h)});
      shader->vector("oneOverTargetSize",std::array<float,2>{1.f/w,1.f/h});
      shader->scalar("reflectionTemporalBlend",.25f);shader->scalar("reflectionHistoryDepthTolerance",.01f);
      shader->scalar("reflectionDenoiseStrength",0);shader->scalar("reflectionHistoryValid",1);
      shader->scalar("reflectionCameraMotion",0);shader->scalar("reflectionMaxRoughness",.65f);
      shader->scalar("reflectionColorFilterEnabled",0);shader->scalar("reflectionSamplingMode",1);
      shader->scalar("reflectionReconstructionMode",1);shader->scalar("reflectionFrameDelta",1.f/60);
      shader->scalar("reflectionHitAwareEnabled",0);shader->scalar("reflectionReceiverHistoryEnabled",0);
      shader->scalar("reflectionFilterRadiusScale",1);
    }
    auto current=uniform(Pixel{.25f,.5f,.75f,1}),history=uniform(Pixel{.75f,1.5f,2.25f,1});
    auto velocity=uniform(Pixel{0,0,0,0});surface=uniform(Pixel{.5f,.5f,.08f,0});depth=uniform(Pixel{1,0,0,0});
    auto temporalRun=[&](FixtureShader& shader){return readPixels(host,drawFixture(host,temporalVertex,shader,w,h,
      {{0,current.Get()},{1,surface.Get()},{2,depth.Get()},{3,velocity.Get()},{4,history.Get()},{5,material.Get()}}).Get());};
    auto oldHistory=temporalRun(oldTemporal);temporal.scalar("reflectionLabCurrentWeight",0);auto normalHistory=temporalRun(temporal);
    check(oldHistory==normalHistory,"Normal lab profile changed production temporal reconstruction");
    temporal.scalar("reflectionLabCurrentWeight",.04f);auto settled=temporalRun(temporal);bool trueWeight=true;
    for(const auto& p:settled)trueWeight=trueWeight&&std::abs(p[0]-.73f)<.0001f&&std::abs(p[1]-1.46f)<.0001f&&p[3]==1;
    if(!trueWeight){std::cerr<<"Settled pixel0: ";for(float v:settled[0])std::cerr<<v<<' ';std::cerr<<'\n';}
    check(trueWeight,"Settled weight was still clamped by the production 0.10 floor");
    current=uniform(Pixel{0,0,0,1});auto zeroSample=temporalRun(temporal);bool retainedZero=true;
    for(const auto& p:zeroSample)retainedZero=retainedZero&&std::abs(p[0]-.72f)<.0001f&&p[3]==1;
    if(!retainedZero){std::cerr<<"Zero sample pixel0: ";for(float v:zeroSample[0])std::cerr<<v<<' ';std::cerr<<'\n';}
    check(retainedZero,"Settled EMA discarded a valid zero estimator sample");
    temporal.scalar("reflectionHistoryValid",0);auto noHistory=temporalRun(temporal);bool currentOnly=true;
    for(const auto& p:noHistory)currentOnly=currentOnly&&p[0]==0&&p[1]==0&&p[2]==0&&p[3]==1;
    if(!currentOnly){std::cerr<<"Invalid history pixel0: ";for(float v:noHistory[0])std::cerr<<v<<' ';std::cerr<<'\n';}
    check(currentOnly,"Settled weight authorized invalid history");
    std::cout<<checks-failures<<'/'<<checks<<" owned SSSR fork checks passed. Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<". Synthetic inputs; not native parity or game verification.\n";
    require(failures==0,"SSSR fork fixture failed");return 0;
  } catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
