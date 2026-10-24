// Offline tests of production helpers/passes. Not an in-game visual comparison.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>

static bool sampleNear(float a, float b, float tolerance=.0002f) {
    return std::isfinite(a) && std::abs(a-b) <= tolerance*std::max(1.f,std::abs(b));
}
int wmain(int argc,wchar_t** argv) {
    try {
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: coherent_test artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));
        if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));
        ComPtr<ID3D12Device> device;
        if(argc==3){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
            hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP Coherent SSR fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;
            require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Coherent fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"coherent.vs.cso").c_str());
        FixtureShader helper(folder/L"coherent-helper.ps.cso"),camera(folder/L"pass9.ps.cso"),reduce(folder/L"coherent-helper.ps.cso"),reduceRange(folder/L"coherent-helper.ps.cso");
        // These pure reduction passes have no live constant buffer after FXC
        // optimization. The host may bind an unused zero CBV; use their real PS.
        reduce.bytes=file((folder/L"pass15.ps.cso").c_str());
        reduceRange.bytes=file((folder/L"pass7.ps.cso").c_str());
        unsigned checks=0,failures=0;
        auto check=[&](bool ok,const char* label){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<label<<'\n';}};
        auto texture=[&](UINT w,UINT h,const std::vector<Pixel>& pixels){host.begin();auto t=host.texture(w,h,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return t;};
        const Pixel color{3.25f,.5f,8,.7f};auto source=texture(8,4,std::vector<Pixel>(32,color));
        helper.scalar("uIntensity",257);helper.scalar("uTraceQuality",17);
        auto run=[&](int mode){helper.scalar("uDebugView",float(mode));return readPixels(host,drawFixture(host,vertex,helper,8,4,{{0,source.Get()}}).Get());};
        auto uniform=[&](const std::vector<Pixel>& pixels,Pixel expected,float tolerance=.0002f){bool ok=true;
            for(const auto& p:pixels)for(unsigned c=0;c<4;++c)ok=ok&&sampleNear(p[c],expected[c],tolerance);return ok;};
        check(uniform(run(0),color,.003f),"packed history changed radiance/coverage beyond quantization");
        for(float hit:{0.f,1.f,63.f,64.f,127.f,128.f,255.f,256.f,511.f,512.f,1022.f,1023.f}){
            helper.scalar("uIntensity",hit);check(uniform(run(1),Pixel{.375f,17,hit,16.f/49}),"history distance/sign-bit metadata corrupted");}
        check(uniform(run(5),Pixel{5,0,1,17}),"history geometry/class/miss metadata corrupted");
        helper.scalar("uIntensity",257);helper.scalar("uDebugView",7);
        auto packed=drawFixture(host,vertex,helper,8,4,{{0,source.Get()}});
        helper.scalar("uDebugView",8);
        check(uniform(readPixels(host,drawFixture(host,vertex,helper,8,4,{{0,packed.Get()}}).Get()),color,.003f),"RGBA32F history target did not preserve packed words");
        for(float cosine:{1.f,.5f,.258819f,.1f,0.f}){
            helper.scalar("uIntensity",cosine);const double eta=1.333;
            const double ct=std::sqrt(1-(1-double(cosine)*cosine)/(eta*eta));
            const double rs=(cosine-eta*ct)/(cosine+eta*ct),rp=(eta*cosine-ct)/(eta*cosine+ct);
            const float f=float(.5*(rs*rs+rp*rp));check(uniform(run(2),Pixel{f,f,f,1}),"water dielectric Fresnel differs from independent reference");}
        helper.scalar("uRoughnessEnd",16.f/49);helper.scalar("uIntensity",0);helper.scalar("uWaterSSR",0);
        check(uniform(run(3),Pixel{1,0,0,1}),"matching receiver history was rejected");
        helper.scalar("uWaterSSR",1);check(uniform(run(3),Pixel{0,0,0,1}),"water/opaque history crossed classes");helper.scalar("uWaterSSR",0);
        helper.scalar("uIntensity",.1f);check(uniform(run(3),Pixel{0,0,0,1}),"history crossed receiver plane");helper.scalar("uIntensity",0);
        helper.scalar("uRoughnessEnd",1);check(uniform(run(3),Pixel{0,0,0,1}),"history crossed roughness class");helper.scalar("uRoughnessEnd",16.f/49);
        helper.scalar("uTraceQuality",0);check(uniform(run(3),Pixel{0,0,0,1}),"invalid history age accepted");
        helper.scalar("uIntensity",2);check(uniform(run(4),Pixel{.2f,.4f,2,1}),"inverse camera projection failed");
        helper.scalar("uIntensity",-1);check(uniform(run(4),Pixel{-1,-1,0,0}),"behind-camera projection accepted");
        helper.scalar("uVirtualParallaxScale",0);check(uniform(run(6),Pixel{.3f,.4f,0,1}),"surface reprojection comparison wrong");
        helper.scalar("uVirtualParallaxScale",1);check(uniform(run(6),Pixel{.8f,.9f,0,1}),"mirror reprojection comparison wrong");
        helper.scalar("uFrame",1);helper.scalar("uStochasticTemporalRate",1);const auto noise1=run(9);
        helper.scalar("uFrame",2);const auto noise2=run(9);bool changed=false;
        for(size_t i=0;i<noise1.size();++i)changed=changed||!sampleNear(noise1[i][0],noise2[i][0]);
        check(changed,"stochastic sample pattern froze across frames");
        auto samplingImage=[&](){helper.scalar("uDebugView",9);
            return readPixels(host,drawFixture(host,vertex,helper,32,24,{{0,source.Get()}}).Get());};
        helper.scalar("uSamplingMode",0);const auto ordered=samplingImage();
        helper.scalar("uSamplingMode",1);const auto scrambled=samplingImage();
        unsigned legacyRepeats=0,newRepeats=0;bool bounded=true;
        for(UINT y=0;y<24;++y)for(UINT x=0;x<24;++x){const size_t i=y*32+x;
            legacyRepeats+=sampleNear(ordered[i][0],ordered[i+8][0],.000001f)?1u:0u;
            newRepeats+=sampleNear(scrambled[i][0],scrambled[i+8][0],.000001f)?1u:0u;
            bounded=bounded&&scrambled[i][0]>=0&&scrambled[i][0]<1&&scrambled[i][1]>=0&&scrambled[i][1]<1;}
        check(legacyRepeats==576,"ordered-pattern A/B no longer demonstrates its eight-pixel repeat");
        check(newRepeats<6&&bounded,"non-tiled sample phase repeats every eight pixels or leaves unit square");
        const auto repeated=samplingImage();check(repeated==scrambled,"fixed pixel/frame sampling is not reproducible");
        helper.scalar("uStochasticRayCount",16);helper.scalar("uDebugView",21);
        auto strataImage=[&](){return readPixels(host,drawFixture(host,vertex,helper,16,64,{{0,source.Get()}}).Get());};
        const auto strata=strataImage();bool allStrata=true;
        for(UINT y=0;y<64;++y){unsigned occupied=0;
            for(UINT x=0;x<16;++x){const auto& p=strata[y*16+x];
                if(p[0]<0 || p[0]>=1 || p[1]<0 || p[1]>=1){allStrata=false;continue;}
                occupied|=1u<<(unsigned(p[0]*4)+4*unsigned(p[1]*4));}
            allStrata=allStrata&&occupied==65535u;}
        check(allStrata,"16-ray sampling left gaps/duplicates in the 4x4 sample-domain strata");
        check(strataImage()==strata,"16-ray sample batch was not reproducible");
        helper.scalar("uFrame",3);const auto nextStrata=strataImage();
        check(nextStrata!=strata,"16-ray sequence did not advance between frames");
        helper.scalar("uStochasticTemporalRate",0);const auto frozenStrata=strataImage();
        helper.scalar("uFrame",10);check(strataImage()==frozenStrata,"disabled temporal sampling did not freeze 16-ray samples");
        helper.scalar("uStochasticTemporalRate",1);helper.scalar("uDebugView",22);
        auto integralError=[&](float count){helper.scalar("uStochasticRayCount",count);
            const auto values=readPixels(host,drawFixture(host,vertex,helper,128,64,{{0,source.Get()}}).Get());
            double mse=0,mean=0;for(const auto& p:values){mean+=p[0];mse+=(p[0]-1)*(p[0]-1);}
            return std::array<double,2>{mse/values.size(),mean/values.size()};};
        const auto oneIntegral=integralError(1),fourIntegral=integralError(4),sixteenIntegral=integralError(16);
        check(sixteenIntegral[0]<oneIntegral[0]*.03 && sixteenIntegral[0]<fourIntegral[0]*.25,
            "heavy stratified sequence did not lower smooth sample-domain integration error");
        check(std::abs(sixteenIntegral[1]-1)<.005,"16-ray sampling biased the known sample-domain mean");
        std::cout<<"Sample-domain integral MSE (not scene noise): 1 ray="<<oneIntegral[0]
            <<", 4="<<fourIntegral[0]<<", 16="<<sixteenIntegral[0]<<'\n';
        helper.scalar("uStochasticRayCount",16);helper.scalar("uStochasticSSR",1);
        check(uniform(run(23),Pixel{16,0,0,1}),"production trace budget still capped the requested 16 rays");
        helper.scalar("uStochasticRayCount",32);
        check(uniform(run(23),Pixel{16,0,0,1}),"trace budget allowed out-of-bounds ray storage");
        for(float count:{6.f,8.f}){
            helper.scalar("uStochasticRayCount",count);
            check(uniform(run(23),Pixel{count,0,0,1}),"intermediate ray request was silently capped or rounded to another tier");}
        helper.scalar("uStochasticSSR",0);
        check(uniform(run(23),Pixel{1,0,0,1}),"non-stochastic mirror tracing repeated identical rays");
        helper.scalar("uStochasticRayCount",1);
        helper.scalar("uReferenceTrace",0);helper.scalar("uTraceQuality",1);
        check(uniform(run(12),Pixel{128,0,0,1}),"normal trace work budget changed unexpectedly");
        helper.scalar("uReferenceTrace",1);check(uniform(run(12),Pixel{256,0,0,1}),"leaf reference work budget not applied");
        helper.scalar("uReferenceTrace",0);
        helper.vector("eyePosWorld",std::array<float,3>{0,0,0});helper.vector("uCameraRight",std::array<float,3>{1,0,0});
        helper.vector("uCameraForward",std::array<float,3>{0,1,0});helper.vector("uCameraUp",std::array<float,3>{0,0,1});
        helper.scalar("uProjectionValid",1);helper.scalar("uScreenMappingFromEngine",1);
        helper.scalar("uTanHalfFovXCur",1);helper.scalar("uTanHalfFovYCur",1);
        helper.vector("uResolution",std::array<float,2>{64,64});helper.scalar("uThicknessResolutionY",64);
        helper.vector("projParams",std::array<float,4>{.1f,10,0,1});
        auto planeDepth=texture(64,64,std::vector<Pixel>(4096,Pixel{.5f,0,0,0}));
        auto planeNormal=texture(64,64,std::vector<Pixel>(4096,Pixel{.5f,0,.2f,0}));
        auto planePacked=texture(64,64,std::vector<Pixel>(4096,Pixel{.5f,.5f,.5f,.5f}));
        helper.scalar("uDebugView",11);
        for(float level:{0.f,1.f,4.f}){
            helper.scalar("uHiZMaxLevel",level);
            const auto hits=readPixels(host,drawFixture(host,vertex,helper,8,4,
                {{0,source.Get()},{1,planeNormal.Get()},{2,planeDepth.Get()},{4,planePacked.Get()}}).Get());
            bool valid=true;for(const auto& hit:hits)valid=valid&&hit[3]==1&&sampleNear(hit[0],.5f,.0001f)&&sampleNear(hit[1],.41f,.016f)&&std::abs(hit[2]-3.13209f)<.3f;
            check(valid,"production marcher missed/projected a known flat target incorrectly");
        }
        auto emptyDepth=texture(64,64,std::vector<Pixel>(4096,Pixel{1,0,0,0}));
        auto emptyPacked=texture(64,64,std::vector<Pixel>(4096,Pixel{1,0,1,1}));
        const auto misses=readPixels(host,drawFixture(host,vertex,helper,8,4,
            {{0,source.Get()},{1,planeNormal.Get()},{2,emptyDepth.Get()},{4,emptyPacked.Get()}}).Get());
        bool noHits=true;for(const auto& hit:misses)noHits=noHits&&hit[3]==0;
        check(noHits,"marcher manufactured target geometry in an empty depth view");
        std::vector<Pixel> sparse(32);for(UINT y=0;y<4;++y)for(UINT x=0;x<8;++x)
            sparse[y*8+x]=((x+y)&1)?Pixel{1,.5f,.25f,1}:Pixel{0,0,0,0};
        auto sparseSource=texture(8,4,sparse);helper.scalar("uDebugView",13);helper.scalar("uStochasticSSR",1);
        auto spatial=[&](ID3D12Resource* depth){return readPixels(host,drawFixture(host,vertex,helper,8,4,
            {{0,sparseSource.Get()},{1,planeNormal.Get()},{2,depth},{4,planePacked.Get()}}).Get());};
        helper.scalar("uStochasticReuse",0);const auto rawSparse=spatial(planeDepth.Get());
        helper.scalar("uStochasticReuse",1);const auto smoothSparse=spatial(planeDepth.Get());
        auto variance=[](const std::vector<Pixel>& values){double m=0,s=0;for(const auto& p:values){m+=p[0];s+=p[0]*p[0];}m/=values.size();return s/values.size()-m*m;};
        check(variance(smoothSparse)<variance(rawSparse)*.5,"geometry-gated spatial filter failed to reduce synthetic sparse variance");
        std::vector<Pixel> waterClass(4096,Pixel{.5f,0,0,0});
        for(UINT y=0;y<64;++y)for(UINT x=32;x<64;++x)waterClass[y*64+x][2]=1;
        for(UINT y=0;y<4;++y)for(UINT x=0;x<8;++x)sparse[y*8+x]=x<4?Pixel{0,0,0,0}:Pixel{1,.5f,.25f,1};
        sparseSource=texture(8,4,sparse);auto classifiedDepth=texture(64,64,waterClass);const auto classResult=spatial(classifiedDepth.Get());
        bool classSafe=true;for(UINT y=0;y<4;++y)for(UINT x=0;x<4;++x)classSafe=classSafe&&classResult[y*8+x][3]==0;
        check(classSafe,"spatial filter bled water reflection into dry receiver class");
        // Reuse must transport a representative VALID seed with filled radiance,
        // not leave the original zero-coverage pixel marked as a miss.
        for(UINT y=0;y<4;++y)for(UINT x=0;x<8;++x)
            sparse[y*8+x]=((x+y)&1)?Pixel{1,.5f,.25f,1}:Pixel{0,0,0,0};
        sparseSource=texture(8,4,sparse);
        helper.scalar("uDebugView",15);helper.scalar("uIntensity",23);
        auto coded=drawFixture(host,vertex,helper,8,4,{{0,sparseSource.Get()}});
        auto seedResult=[&](ID3D12Resource* depth){helper.scalar("uDebugView",14);
            return readPixels(host,drawFixture(host,vertex,helper,8,4,
                {{0,coded.Get()},{1,planeNormal.Get()},{2,depth}}).Get());};
        helper.scalar("uRoughStability",0);helper.scalar("uStochasticReuse",0);
        const auto rawCodes=seedResult(planeDepth.Get());
        check(rawCodes[2*8+2][0]==63 && rawCodes[2*8+2][1]==0,"raw miss manufactured a finite metadata seed");
        helper.scalar("uStochasticReuse",1);const auto filledCodes=seedResult(planeDepth.Get());
        check(filledCodes[2*8+2][0]==23 && filledCodes[2*8+2][1]>.1f,"reused radiance kept a center miss code instead of the accepted neighbor seed");
        auto emptySource=texture(8,4,std::vector<Pixel>(32,Pixel{0,0,0,0}));
        helper.scalar("uDebugView",15);coded=drawFixture(host,vertex,helper,8,4,{{0,emptySource.Get()}});
        const auto emptyCodes=seedResult(planeDepth.Get());
        check(emptyCodes[2*8+2][0]==63 && emptyCodes[2*8+2][1]==0,"empty neighborhood manufactured reflection coverage or a finite seed");
        for(UINT y=0;y<4;++y)for(UINT x=0;x<8;++x)
            sparse[y*8+x]=(x%2 && y%2)?Pixel{1,.5f,.25f,1}:Pixel{0,0,0,0};
        sparseSource=texture(8,4,sparse);helper.scalar("uDebugView",15);
        coded=drawFixture(host,vertex,helper,8,4,{{0,sparseSource.Get()}});
        helper.scalar("uRoughStability",0);const auto crossOnly=seedResult(planeDepth.Get());
        helper.scalar("uRoughStability",1);const auto diagonals=seedResult(planeDepth.Get());
        check(crossOnly[2*8+2][1]==0 && diagonals[2*8+2][1]>0 && diagonals[2*8+2][0]==23,
            "rough diagonal reconstruction failed to fill an axis-isolated sample or lost its seed");
        FixtureShader reuseNative(folder/L"pass10.ps.cso");
        reuseNative.scalar("uStochasticSSR",1);reuseNative.scalar("uStochasticReuse",1);reuseNative.scalar("uRoughStability",1);
        reuseNative.scalar("uProjectionValid",1);reuseNative.scalar("uScreenMappingFromEngine",1);
        reuseNative.vector("uCameraForward",std::array<float,3>{0,1,0});reuseNative.vector("uCameraRight",std::array<float,3>{1,0,0});
        reuseNative.vector("uCameraUp",std::array<float,3>{0,0,1});reuseNative.scalar("uTanHalfFovXCur",1);reuseNative.scalar("uTanHalfFovYCur",1);
        reuseNative.vector("projParams",std::array<float,4>{.1f,10,0,1});
        auto nativeReused=drawFixture(host,vertex,reuseNative,16,4,{{0,coded.Get()},{1,planeNormal.Get()},{2,planeDepth.Get()}},DXGI_FORMAT_R16G16B16A16_FLOAT);
        helper.scalar("uDebugView",20);
        const auto nativeCodes=readPixels(host,drawFixture(host,vertex,helper,16,4,{{0,nativeReused.Get()}}).Get());
        check(nativeCodes[2*16+2][0]==23 && nativeCodes[2*16+2][1]>0,
            "production RGBA16F reuse pass failed to embed its reconstructed signal's representative seed");
        helper.scalar("uDebugView",17);helper.vector("uRoughTraceJitterUV",std::array<float,2>{0,0});
        const auto roughCodes=readPixels(host,drawFixture(host,vertex,helper,8,4,{{3,coded.Get()}}).Get());
        check(roughCodes[1*8+1][0]==23 && roughCodes[1*8+1][1]>.99f && roughCodes[2*8+2][0]==63,
            "adaptive rough trace reconstruction failed to carry finite/missing metadata with coverage");
        auto allWater=texture(64,64,std::vector<Pixel>(4096,Pixel{.5f,0,1,0}));
        helper.scalar("uRoughStability",0);const auto oldWater=seedResult(allWater.Get());
        helper.scalar("uRoughStability",1);const auto newWater=seedResult(allWater.Get());
        check(oldWater==newWater,"rough diagonal experiment changed the water filter kernel");
        for(UINT y=0;y<4;++y)for(UINT x=0;x<8;++x)sparse[y*8+x]=x<4?Pixel{0,0,0,0}:Pixel{1,.5f,.25f,1};
        sparseSource=texture(8,4,sparse);helper.scalar("uDebugView",15);helper.scalar("uIntensity",23);
        coded=drawFixture(host,vertex,helper,8,4,{{0,sparseSource.Get()}});
        const auto diagonalClasses=seedResult(classifiedDepth.Get());
        bool diagonalSafe=true;for(UINT y=0;y<4;++y)for(UINT x=0;x<4;++x)
            diagonalSafe=diagonalSafe&&diagonalClasses[y*8+x][0]==63&&diagonalClasses[y*8+x][1]==0;
        check(diagonalSafe,"diagonal reuse crossed the water/opaque receiver boundary");
        helper.scalar("uIntensity",.25f);helper.scalar("uRoughnessEnd",.5f);helper.scalar("uWaterSSR",0);
        const auto roughRadius=run(16);
        check(roughRadius[0][0]>.025f && roughRadius[0][1]==1,"rough sparse-history floor did not engage");
        helper.scalar("uWaterSSR",1);check(uniform(run(16),Pixel{.025f,0,0,1}),"rough stability changed water policy");
        helper.scalar("uWaterSSR",0);helper.scalar("uRoughnessEnd",.05f);
        check(uniform(run(16),Pixel{.025f,0,0,1}),"rough stability changed mirror-like policy");
        helper.scalar("uRoughnessEnd",.5f);helper.scalar("uRoughStability",0);
        check(uniform(run(16),Pixel{.025f,0,0,1}),"rough stability comparison toggle was ignored");

        // Exercise the real native-history shader, not only its clamp helper.
        FixtureShader temporal(folder/L"pass2.ps.cso");
        helper.scalar("uDebugView",18);helper.scalar("uThicknessTexels",.375f);helper.scalar("uTraceQuality",16);
        helper.scalar("uIntensity",1023);helper.scalar("uFresnelStrength",3);
        auto currentMiss=drawFixture(host,vertex,helper,8,4,{{0,emptySource.Get()}});
        auto historicalColor=texture(8,4,std::vector<Pixel>(32,Pixel{.5f,.25f,.1f,.25f}));
        helper.scalar("uIntensity",100);helper.scalar("uFresnelStrength",0);
        auto previous=drawFixture(host,vertex,helper,8,4,{{0,historicalColor.Get()}});
        helper.scalar("uThicknessTexels",.8f);
        auto wrongPlane=drawFixture(host,vertex,helper,8,4,{{0,historicalColor.Get()}});
        camera.vector("eyePosWorld",std::array<float,3>{0,0,0});
        auto previousCamera=drawFixture(host,vertex,camera,2,2,{});
        temporal.scalar("uUnifiedTemporal",1);temporal.scalar("uTemporalHistoryValid",1);
        temporal.scalar("uCameraHistoryValid",1);temporal.scalar("uTemporalStrength",.96f);
        temporal.scalar("uStochasticSSR",1);temporal.vector("projParams",std::array<float,4>{.1f,10,0,1});
        temporal.vector("eyePosWorld",std::array<float,3>{0,0,0});
        auto accumulate=[&](ID3D12Resource* history){return drawFixture(host,vertex,temporal,8,4,
            {{0,planeDepth.Get()},{2,currentMiss.Get()},{3,history},{4,previousCamera.Get()}});};
        auto decoded=[&](ID3D12Resource* data,int mode){helper.scalar("uDebugView",float(mode));
            return readPixels(host,drawFixture(host,vertex,helper,8,4,{{0,data}}).Get());};
        temporal.scalar("uRoughStability",0);auto clippedMiss=accumulate(previous.Get());
        temporal.scalar("uRoughStability",1);auto stableMiss=accumulate(previous.Get());
        const auto clippedEnergy=decoded(clippedMiss.Get(),8),stableEnergy=decoded(stableMiss.Get(),8);
        check(stableEnergy[0][3]>clippedEnergy[0][3]*1.5f && stableEnergy[0][3]<.25f,
            "production temporal pass erased sparse rough history or invented coverage");
        check(decoded(stableMiss.Get(),19)[0][0]>16,"absence of hit colors falsely invalidated mature history age");
        auto rejectedPlane=accumulate(wrongPlane.Get());
        check(uniform(decoded(rejectedPlane.Get(),8),Pixel{0,0,0,0}),"rough stability bypassed receiver-plane rejection");
        helper.scalar("uTemporalStrength",.98f);helper.scalar("uIntensity",0);
        check(uniform(run(24),Pixel{1,1,1,1}),"new history failed to start entirely fresh");
        helper.scalar("uIntensity",7);
        check(uniform(run(24),Pixel{.125f,.125f,.125f,1}),"immature history skipped its warmup average");
        helper.scalar("uIntensity",31);
        check(uniform(run(24),Pixel{.02f,.02f,.02f,1}),"packed age cap still overrides requested .98 retention");
        helper.scalar("uTemporalStrength",.5f);
        check(uniform(run(24),Pixel{.5f,.5f,.5f,1}),"mature history ignored a lower user retention setting");
        helper.scalar("uDebugView",18);helper.scalar("uTraceQuality",31);helper.scalar("uIntensity",100);
        helper.scalar("uFresnelStrength",1);helper.scalar("uRoughnessEnd",.5f);helper.scalar("uThicknessTexels",.375f);
        auto currentColor=texture(8,4,std::vector<Pixel>(32,Pixel{.5f,.25f,.1f,.2f}));
        auto previousColor=texture(8,4,std::vector<Pixel>(32,Pixel{.5f,.25f,.1f,.5f}));
        currentMiss=drawFixture(host,vertex,helper,8,4,{{0,currentColor.Get()}});
        auto maturePrevious=drawFixture(host,vertex,helper,8,4,{{0,previousColor.Get()}});
        const float currentAlpha=decoded(currentMiss.Get(),8)[0][3],previousAlpha=decoded(maturePrevious.Get(),8)[0][3];
        temporal.scalar("uTemporalStrength",.98f);
        auto matureResult=accumulate(maturePrevious.Get());
        const float matureAlpha=decoded(matureResult.Get(),8)[0][3];
        check(std::abs(matureAlpha-(.98f*previousAlpha+.02f*currentAlpha))<1.1f/1023,
            "production native temporal pass did not apply requested retention after age saturation");
        auto matureRejected=accumulate(wrongPlane.Get());
        check(std::abs(decoded(matureRejected.Get(),8)[0][3]-currentAlpha)<1.1f/1023,
            "mature retention resurrected history across a receiver-plane rejection");
        temporal.vector("uMotionOptions",std::array<float,4>{1,0,0,0});
        temporal.vector("uVehicleHalf",std::array<float,4>{4,1,4,1});
        temporal.vector("uVehicleCenter",std::array<float,4>{0,3.75f,0,0});
        temporal.vector("uVehiclePrevCenter",std::array<float,4>{0,3.75f,0,0});
        for(auto name:{"uVehicleAxisX","uVehiclePrevAxisX"})temporal.vector(name,std::array<float,4>{1,0,0,0});
        for(auto name:{"uVehicleAxisY","uVehiclePrevAxisY"})temporal.vector(name,std::array<float,4>{0,1,0,0});
        for(auto name:{"uVehicleAxisZ","uVehiclePrevAxisZ"})temporal.vector(name,std::array<float,4>{0,0,1,0});
        auto parkedResult=accumulate(maturePrevious.Get());
        const float parkedAlpha=decoded(parkedResult.Get(),8)[2*8+4][3];
        check(std::abs(parkedAlpha-matureAlpha)<1.1f/1023,
            "parked player vehicle was forced to refresh like a moving vehicle");
        temporal.vector("uVehiclePrevCenter",std::array<float,4>{.00001f,3.75f,0,0});
        auto jitterResult=accumulate(maturePrevious.Get());
        check(std::abs(decoded(jitterResult.Get(),8)[2*8+4][3]-parkedAlpha)<1.1f/1023,
            "negligible rigid-pose jitter disabled parked-vehicle convergence");
        temporal.vector("uVehiclePrevCenter",std::array<float,4>{.25f,3.75f,0,0});
        auto movingResult=accumulate(maturePrevious.Get());
        const float movingAlpha=decoded(movingResult.Get(),8)[2*8+4][3];
        check(movingAlpha<parkedAlpha-.02f && movingAlpha>=currentAlpha-1.1f/1023,
            "translated vehicle lost its motion-driven history refresh");
        temporal.vector("uVehiclePrevCenter",std::array<float,4>{0,3.75f,0,0});
        temporal.vector("uVehiclePrevAxisX",std::array<float,4>{.9800666f,0,-.1986693f,0});
        temporal.vector("uVehiclePrevAxisZ",std::array<float,4>{.1986693f,0,.9800666f,0});
        auto turningResult=accumulate(maturePrevious.Get());
        check(decoded(turningResult.Get(),8)[2*8+4][3]<parkedAlpha-.02f,
            "rotating vehicle was incorrectly treated as parked");
        temporal.vector("uVehicleHalf",std::array<float,4>{0,0,0,0});
        helper.vector("uWaterDeepColor",std::array<float,4>{.015f,.045f,.05f,1});
        helper.scalar("uWaterColorStrength",0);helper.scalar("uWaterSSR",1);
        for(float angle:{0.f,.5f,1.f}){
            helper.scalar("uIntensity",angle);
            check(uniform(run(10),color,0),"zero added tint changed stock water/reflection color");
        }
        helper.scalar("uWaterColorStrength",1);helper.scalar("uWaterSSR",0);
        check(uniform(run(10),color,0),"optional water tint altered an opaque surface");
        helper.scalar("uWaterSSR",1);helper.scalar("uIntensity",0);
        check(uniform(run(10),Pixel{.015f,.045f,.05f,.7f}),"explicit optional water tint stopped working");
        camera.vector("eyePosWorld",std::array<float,3>{5,-2,7});
        const auto basis=readPixels(host,drawFixture(host,vertex,camera,2,2,{}).Get());
        const std::array<Pixel,4> expectedBasis={Pixel{.05f,.05f,0,5},Pixel{0,.05f,-.05f,-2},Pixel{0,.1f,0,7},Pixel{0,0,0,1}};
        bool exact=true;for(size_t i=0;i<4;++i)for(unsigned c=0;c<4;++c)exact=exact&&sampleNear(basis[i][c],expectedBasis[i][c]);
        check(exact,"production camera-history pass inverse basis or world eye was wrong");
        std::vector<Pixel> data(9*7);for(UINT i=0;i<data.size();++i)data[i]={.1f+.001f*i,0,0,1};
        auto input=texture(9,7,data);const auto reduced=readPixels(host,drawFixture(host,vertex,reduce,4,3,{{0,input.Get()}}).Get());
        bool correct=true;for(UINT y=0;y<3;++y)for(UINT x=0;x<4;++x){
            const UINT endX=x==3?8:x*2+1,endY=y==2?6:y*2+1;
            correct=correct&&sampleNear(reduced[y*4+x][0],data[y*2*9+x*2][0])&&sampleNear(reduced[y*4+x][1],data[endY*9+endX][0]);}
        check(correct,"odd-sized Hi-Z lost edge depth or min/max coverage");
        const auto next=readPixels(host,drawFixture(host,vertex,reduceRange,2,1,{{0,texture(4,3,reduced).Get()}}).Get());
        check(sampleNear(next[1][1],data.back()[0]),"range pyramid lost far edge on next reduction");
        std::cout<<"Coherent SSR: "<<checks-failures<<'/'<<checks<<" checks passed; debug layer "<<(debugEnabled?"enabled":"unavailable")<<". Offline only.\n";
        return failures?2:0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
