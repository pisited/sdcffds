// Actual production temporal/atlas pixel shaders with synthetic GPU resources.
// This verifies data ownership and rejection, not live-game visual quality.
#include "../gi/gpu_fixture_pass.h"
#include <algorithm>
#include <cstdint>
constexpr UINT receiverWidth=4,receiverHeight=2;
constexpr size_t receiverCount=size_t(receiverWidth)*receiverHeight;
static bool exact(float a,float b){uint32_t x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);return x==y;}
static bool sampleNear(float a,float b,float epsilon=0.0001f){return std::isfinite(a)&&std::abs(a-b)<=epsilon*std::max(1.f,std::abs(b));}
static float packF0(Pixel p){const auto q=[](float v){return uint32_t(std::round(std::clamp(v,0.f,1.f)*255.f));};return float(q(p[0])|(q(p[1])<<8)|(q(p[2])<<16))+1.f;}
static float packUV(float u,float v){return float(uint32_t(std::round(u*4095))|(uint32_t(std::round(v*4095))<<12))+1.f;}
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: receiver_history_test artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);const bool warp=argc==3;
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP receiver-history fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Receiver-history fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vertex=file((folder/L"receiver.vs.cso").c_str());
        FixtureShader old(folder/L"beamrtReflectionTemporalP_v038.hlsl.ps.cso"),temporal(folder/L"beamrtReflectionTemporalP_v039.hlsl.ps.cso"),
            hitInputs(folder/L"beamrtReflectionHitInputsP_v002.hlsl.ps.cso"),hitCopy(folder/L"beamrtReflectionHitCopyP_v002.hlsl.ps.cso");
        unsigned checks=0,failures=0;auto check=[&](bool ok,const char* name){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<name<<'\n';}};
        auto upload=[&](UINT w,UINT h,const std::vector<Pixel>& pixels){require(pixels.size()==size_t(w)*h,"bad fixture upload extent");host.begin();auto out=host.texture(w,h,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return out;};
        auto uniform=[&](Pixel p){return upload(receiverWidth,receiverHeight,std::vector<Pixel>(receiverCount,p));};
        const Pixel material{.04f,.04f,.04f,0},surface{.5f,.5f,.08f,0},descriptor{.5f,.5f,.08f,packF0(material)},current{.25f,.5f,.75f,0},history{.75f,1.5f,2.25f,1};
        auto currentTex=uniform(current),surfaceTex=uniform(surface),depth=uniform(Pixel{1,0,0,0}),specular=uniform(material),historyTex=uniform(history),zero=uniform(Pixel{0,0,0,0});
        auto atlasPixels=[&](Pixel motion,Pixel receiver){std::vector<Pixel> data(receiverCount*2,motion);std::fill(data.begin()+receiverCount,data.end(),receiver);return data;};
        auto atlas=[&](Pixel motion,Pixel receiver){return upload(receiverWidth,receiverHeight*2,atlasPixels(motion,receiver));};
        auto inputsTex=atlas(Pixel{0,0,0,0},descriptor);
        auto common=[&](FixtureShader& shader){shader.vector("projParams",std::array<float,4>{.1f,10,0,1});for(unsigned i=0;i<4;++i)shader.vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});};
        for(auto shader:{&old,&temporal}){common(*shader);shader->vector("targetSize",std::array<float,2>{float(receiverWidth),float(receiverHeight)});
            shader->vector("oneOverTargetSize",std::array<float,2>{1.f/receiverWidth,1.f/receiverHeight});shader->scalar("reflectionTemporalBlend",.25f);
            shader->scalar("reflectionHistoryDepthTolerance",.01f);shader->scalar("reflectionHistoryValid",1);shader->scalar("reflectionMaxRoughness",.34f);
            shader->scalar("reflectionSamplingMode",1);shader->scalar("reflectionReconstructionMode",1);shader->scalar("reflectionFrameDelta",1.f/60);
            shader->scalar("reflectionFilterRadiusScale",1);shader->scalar("reflectionHitAwareEnabled",1);shader->scalar("reflectionColorFilterEnabled",1);}
        temporal.scalar("reflectionReceiverHistoryEnabled",1);
        for(auto shader:{&hitInputs,&hitCopy}){common(*shader);shader->vector("reflectionReceiverSize",std::array<float,2>{float(receiverWidth),float(receiverHeight)});
            shader->scalar("reflectionHistoryValid",1);shader->scalar("reflectionHitAwareEnabled",1);}
        const auto temporalDefaults=temporal.constants,oldDefaults=old.constants,inputsDefaults=hitInputs.constants,copyDefaults=hitCopy.constants;
        auto run=[&](FixtureShader& shader,ID3D12Resource* motion,ID3D12Resource* oldColor=nullptr,ID3D12Resource* fresh=nullptr){return readPixels(host,drawFixture(host,vertex,shader,receiverWidth,receiverHeight,
            {{0,fresh?fresh:currentTex.Get()},{1,surfaceTex.Get()},{2,depth.Get()},{3,motion},{4,oldColor?oldColor:historyTex.Get()},{5,specular.Get()}}).Get());};
        auto allNear=[&](const std::vector<Pixel>& pixels,Pixel expected){bool ok=true;for(const auto& p:pixels)for(unsigned c=0;c<4;++c)ok=ok&&sampleNear(p[c],expected[c]);return ok;};
        auto same=[&](const std::vector<Pixel>& a,const std::vector<Pixel>& b){bool ok=a.size()==b.size();for(size_t i=0;i<a.size()&&i<b.size();++i)for(unsigned c=0;c<4;++c)ok=ok&&exact(a[i][c],b[i][c]);return ok;};
        // OFF is a real production-v038 comparison using equivalent plane-zero
        // motion data, not an expected-value approximation of its formulas.
        for(float sampling:{0.f,1.f})for(float filter:{0.f,1.f})for(Pixel motion:{Pixel{0,0,0,0},Pixel{.02f,0,0,0},Pixel{2,0,0,0}}){
            temporal.constants=temporalDefaults;old.constants=oldDefaults;for(auto shader:{&old,&temporal}){shader->scalar("reflectionSamplingMode",sampling);shader->scalar("reflectionColorFilterEnabled",filter);}
            temporal.scalar("reflectionReceiverHistoryEnabled",0);auto oldMotion=uniform(motion),newMotion=atlas(motion,descriptor);
            check(same(run(old,oldMotion.Get()),run(temporal,newMotion.Get())),"v039 OFF differs from v038 color/lifetime math");}
        temporal.constants=temporalDefaults;old.constants=oldDefaults;
        auto reference=run(temporal,inputsTex.Get());check(allNear(reference,Pixel{.6875f,1.375f,2.0625f,1}),"matching receiver unexpectedly rejects valid GGX history");
        auto oldMotion=uniform(Pixel{0,0,0,0});check(same(reference,run(old,oldMotion.Get())),"matching descriptors change v038 stationary history");
        const float nan=std::numeric_limits<float>::quiet_NaN();
        for(Pixel bad:{Pixel{1,.5f,.08f,descriptor[3]},Pixel{.5f,.5f,.5f,descriptor[3]},Pixel{.5f,.5f,.08f,packF0(Pixel{.8f,.8f,.8f,0})},
            Pixel{.5f,.5f,.08f,0},Pixel{.5f,.5f,.08f,16777218.f},Pixel{nan,.5f,.08f,descriptor[3]}}){auto rejected=atlas(Pixel{0,0,0,0},bad);
            check(allNear(run(temporal,rejected.Get()),Pixel{current[0],current[1],current[2],1}),"same-depth incompatible/invalid receiver retained history");}
        // Reprojected bilinear history lies between x=1 and x=2. The nearest
        // lifetime owner x=2 is compatible; x=1 has bright incompatible color.
        auto mixedData=atlasPixels(Pixel{.125f,0,0,0},descriptor);mixedData[receiverCount+1][0]=1;
        std::vector<Pixel> mixedColors(receiverCount,Pixel{2,2,2,1});mixedColors[1]=Pixel{100,100,100,1};
        auto mixedInput=upload(receiverWidth,receiverHeight*2,mixedData),mixedHistory=upload(receiverWidth,receiverHeight,mixedColors),
            pureInput=atlas(Pixel{.125f,0,0,0},descriptor),pureHistory=uniform(Pixel{2,2,2,1});
        const auto mixed=run(temporal,mixedInput.Get(),mixedHistory.Get()),pure=run(temporal,pureInput.Get(),pureHistory.Get());
        bool tapSame=true;for(unsigned c=0;c<4;++c)tapSame=tapSame&&sampleNear(mixed[1][c],pure[1][c]);check(tapSame,"bilinear color mixed an incompatible receiver tap");
        temporal.scalar("reflectionReceiverHistoryEnabled",0);const auto ungated=run(temporal,mixedInput.Get(),mixedHistory.Get());
        check(ungated[1][0]>mixed[1][0]+1,"tap fixture failed to reproduce old bright leakage");temporal.constants=temporalDefaults;
        auto black=uniform(Pixel{0,0,0,0});check(allNear(run(temporal,inputsTex.Get(),nullptr,black.Get()),Pixel{.65625f,1.3125f,1.96875f,1}),"valid GGX zero estimator lost fresh history support");
        temporal.scalar("reflectionSamplingMode",0);temporal.scalar("reflectionHistoryValid",0);auto blackHit=uniform(Pixel{0,0,0,1});
        check(allNear(run(temporal,inputsTex.Get(),nullptr,blackHit.Get()),Pixel{0,0,0,1}),"valid black mirror hit lost positive exact lifetime");temporal.constants=temporalDefaults;
        temporal.scalar("reflectionHistoryValid",0);check(allNear(run(temporal,inputsTex.Get()),Pixel{current[0],current[1],current[2],1}),"history reset did not restore current sample");temporal.constants=temporalDefaults;
        auto outMotion=atlas(Pixel{2,0,0,0},descriptor);check(allNear(run(temporal,outMotion.Get()),Pixel{current[0],current[1],current[2],1}),"out-of-bounds reprojection retained history");
        check(allNear(run(temporal,oldMotion.Get()),Pixel{current[0],current[1],current[2],1}),"stale single-plane atlas dimensions retained history");
        auto wrongWidth=upload(receiverWidth+1,receiverHeight*2,std::vector<Pixel>(size_t(receiverWidth+1)*receiverHeight*2,descriptor));
        check(allNear(run(temporal,wrongWidth.Get()),Pixel{current[0],current[1],current[2],1}),"stale atlas width retained history");
        temporal.scalar("reflectionReceiverHistoryEnabled",0);
        check(allNear(run(temporal,oldMotion.Get()),Pixel{current[0],current[1],current[2],1}),"receiver gate OFF accepted stale single-plane atlas history");
        check(allNear(run(temporal,wrongWidth.Get()),Pixel{current[0],current[1],current[2],1}),"receiver gate OFF accepted stale atlas width history");
        temporal.constants=temporalDefaults;
        bool lifetimeExact=true;for(const auto& p:reference)lifetimeExact=lifetimeExact&&exact(p[3],1);check(lifetimeExact,"receiver gate interpolated categorical lifetime alpha");
        // Snapshot producer: hit metadata reprojects, receiver descriptors do
        // not. Each bilinear consumer later chooses its own previous-grid tap.
        std::vector<Pixel> previous(receiverCount*2);for(size_t i=0;i<receiverCount;++i){previous[i]=Pixel{float(i%receiverWidth)/3.f,.25f,1,.5f};previous[receiverCount+i]=descriptor;previous[receiverCount+i][2]=.02f+float(i)*.01f;}
        auto priorAtlas=upload(receiverWidth,receiverHeight*2,previous),velocity=uniform(Pixel{.25f,0,0,0});
        auto snapshot=[&](ID3D12Resource* prior,UINT w=receiverWidth,UINT h=receiverHeight*2){return readPixels(host,drawFixture(host,vertex,hitInputs,w,h,{{0,velocity.Get()},{1,prior}}).Get());};
        const auto snapshotPixels=snapshot(priorAtlas.Get());bool descriptorGrid=true,hitReproject=true;
        for(UINT y=0;y<receiverHeight;++y)for(UINT x=0;x<receiverWidth;++x){const size_t i=size_t(y)*receiverWidth+x;for(unsigned c=0;c<4;++c)descriptorGrid=descriptorGrid&&exact(snapshotPixels[receiverCount+i][c],previous[receiverCount+i][c]);
            const bool valid=x+1<receiverWidth;hitReproject=hitReproject&&exact(snapshotPixels[i][0],.25f)&&exact(snapshotPixels[i][1],0);
            hitReproject=hitReproject&&exact(snapshotPixels[i][2],valid?packUV(float(x+1)/3.f,.25f):0)&&exact(snapshotPixels[i][3],valid?1.f:0.f);}
        check(descriptorGrid,"HitInputs descriptor plane was reprojected or filtered");check(hitReproject,"HitInputs plane-zero motion/hit reprojection changed packed metadata");
        hitInputs.scalar("reflectionHistoryValid",0);const auto resetSnapshot=snapshot(priorAtlas.Get());bool resetValid=true;for(size_t i=0;i<receiverCount;++i){resetValid=resetValid&&exact(resetSnapshot[i][0],.25f)&&exact(resetSnapshot[i][2],0);for(float c:resetSnapshot[receiverCount+i])resetValid=resetValid&&exact(c,0);}check(resetValid,"HitInputs reset did not clear descriptors while retaining velocity");hitInputs.constants=inputsDefaults;
        const auto staleSnapshot=snapshot(oldMotion.Get());bool staleValid=true;for(size_t i=0;i<receiverCount;++i){staleValid=staleValid&&exact(staleSnapshot[i][0],.25f)&&exact(staleSnapshot[i][2],0);for(float c:staleSnapshot[receiverCount+i])staleValid=staleValid&&exact(c,0);}check(staleValid,"HitInputs stale layout retained old descriptors/hit metadata");
        auto snapshotPadding=snapshot(priorAtlas.Get(),receiverWidth+1,receiverHeight*2+1);bool padded=true;for(UINT y=0;y<receiverHeight*2+1;++y)for(UINT x=0;x<receiverWidth+1;++x)if(x>=receiverWidth||y>=receiverHeight*2)for(float c:snapshotPadding[size_t(y)*(receiverWidth+1)+x])padded=padded&&exact(c,0);check(padded,"HitInputs wrote data outside logical atlas bounds");
        auto copy=[&](ID3D12Resource* fresh,ID3D12Resource* oldInput,ID3D12Resource* color,UINT w=receiverWidth,UINT h=receiverHeight*2){return readPixels(host,drawFixture(host,vertex,hitCopy,w,h,
            {{0,fresh},{1,depth.Get()},{2,oldInput},{3,color},{4,surfaceTex.Get()},{5,specular.Get()}}).Get());};
        auto copyMiss=copy(zero.Get(),inputsTex.Get(),zero.Get());bool missDescriptor=true,missHit=true;
        for(size_t i=0;i<receiverCount;++i){for(unsigned c=0;c<4;++c)missDescriptor=missDescriptor&&exact(copyMiss[receiverCount+i][c],descriptor[c]);for(float c:copyMiss[i])missHit=missHit&&exact(c,0);}
        check(missDescriptor,"HitCopy ray miss erased valid receiver descriptor");check(missHit,"HitCopy invented hit support for a ray miss");
        auto copyBlack=copy(blackHit.Get(),inputsTex.Get(),black.Get());bool blackDescriptor=true;for(size_t i=receiverCount;i<receiverCount*2;++i)for(unsigned c=0;c<4;++c)blackDescriptor=blackDescriptor&&exact(copyBlack[i][c],descriptor[c]);check(blackDescriptor,"black radiance changed receiver descriptor validity");
        for(Pixel f0:{Pixel{0,0,0,0},Pixel{1,1,1,0},Pixel{1,0,.5f,0}}){auto materialTex=uniform(f0);
            const auto packedCopy=readPixels(host,drawFixture(host,vertex,hitCopy,receiverWidth,receiverHeight*2,
                {{0,zero.Get()},{1,depth.Get()},{2,inputsTex.Get()},{3,zero.Get()},{4,surfaceTex.Get()},{5,materialTex.Get()}}).Get());
            bool exactF0=true;for(size_t i=receiverCount;i<receiverCount*2;++i)exactF0=exactF0&&exact(packedCopy[i][3],packF0(f0));
            check(exactF0,"HitCopy lost exact RGB8 F0 integer endpoint/channel packing");}
        auto poisonedSurface=uniform(Pixel{nan,.5f,.08f,0}),poisonedMaterial=uniform(Pixel{.04f,nan,.04f,0});
        for(auto badBindings:{std::pair<ID3D12Resource*,ID3D12Resource*>{poisonedSurface.Get(),specular.Get()},
            std::pair<ID3D12Resource*,ID3D12Resource*>{surfaceTex.Get(),poisonedMaterial.Get()}}){
            const auto invalidCopy=readPixels(host,drawFixture(host,vertex,hitCopy,receiverWidth,receiverHeight*2,
                {{0,zero.Get()},{1,depth.Get()},{2,inputsTex.Get()},{3,zero.Get()},{4,badBindings.first},{5,badBindings.second}}).Get());
            bool invalidClear=true;for(size_t i=receiverCount;i<receiverCount*2;++i)for(float c:invalidCopy[i])invalidClear=invalidClear&&exact(c,0);
            check(invalidClear,"HitCopy published invalid normal/material receiver descriptor");}
        const float packed=packUV(.75f,.75f),hitU=float(uint32_t(packed-1)&4095u)/4095.f,hitV=float((uint32_t(packed-1)>>12)&4095u)/4095.f;
        auto accepted=uniform(Pixel{.5f,.5f,.5f,packed});const auto hitAtlas=copy(accepted.Get(),inputsTex.Get(),zero.Get());bool hitExact=true,eyeCorrect=true;
        for(UINT y=0;y<receiverHeight;++y)for(UINT x=0;x<receiverWidth;++x){const auto& p=hitAtlas[size_t(y)*receiverWidth+x];hitExact=hitExact&&exact(p[0],hitU)&&exact(p[1],hitV)&&exact(p[2],1);
            const float dx=.4f*(hitU-(float(x)+.5f)/receiverWidth),dy=.6f*(hitV-(float(y)+.5f)/receiverHeight);eyeCorrect=eyeCorrect&&sampleNear(p[3],std::sqrt(dx*dx+dy*dy));}
        check(hitExact,"HitCopy changed exact hit UV/depth metadata");check(eyeCorrect,"HitCopy doubled-height output used wrong logical eye ray");
        auto copyPadded=copy(accepted.Get(),inputsTex.Get(),zero.Get(),receiverWidth+1,receiverHeight*2+1);bool copyBounds=true;
        for(UINT y=0;y<receiverHeight*2+1;++y)for(UINT x=0;x<receiverWidth+1;++x)if(x>=receiverWidth||y>=receiverHeight*2)for(float c:copyPadded[size_t(y)*(receiverWidth+1)+x])copyBounds=copyBounds&&exact(c,0);check(copyBounds,"HitCopy wrote outside logical atlas bounds");
        hitCopy.scalar("reflectionHitAwareEnabled",0);bool disabled=true;for(const auto& p:copy(accepted.Get(),inputsTex.Get(),zero.Get()))for(float c:p)disabled=disabled&&exact(c,0);check(disabled,"HitCopy disabled state retained atlas data");hitCopy.constants=copyDefaults;
        auto retainedInputs=atlas(Pixel{0,0,packed,1},descriptor);const auto staleCopy=copy(zero.Get(),oldMotion.Get(),historyTex.Get());bool staleCopyClear=true;for(size_t i=0;i<receiverCount;++i)for(float c:staleCopy[i])staleCopyClear=staleCopyClear&&exact(c,0);check(staleCopyClear,"HitCopy stale input dimensions retained old hit metadata");
        const auto retained=copy(zero.Get(),retainedInputs.Get(),historyTex.Get());bool retainedExact=true;for(size_t i=0;i<receiverCount;++i)retainedExact=retainedExact&&exact(retained[i][0],hitU)&&exact(retained[i][1],hitV)&&exact(retained[i][2],1);check(retainedExact,"HitCopy valid stationary grace metadata was lost");
        for(bool cameraCut:{false,true}){hitCopy.constants=copyDefaults;hitCopy.scalar(cameraCut?"reflectionCameraMotion":"reflectionHistoryValid",cameraCut?1.f:0.f);
            const auto resetCopy=copy(zero.Get(),retainedInputs.Get(),historyTex.Get());bool hitClear=true,receiverRetained=true;
            for(size_t i=0;i<receiverCount;++i){for(float c:resetCopy[i])hitClear=hitClear&&exact(c,0);for(unsigned c=0;c<4;++c)receiverRetained=receiverRetained&&exact(resetCopy[receiverCount+i][c],descriptor[c]);}
            check(hitClear,"HitCopy reset/camera cut retained old hit metadata");check(receiverRetained,"HitCopy reset/camera cut erased current valid receiver descriptor");}
        hitCopy.constants=copyDefaults;
        for(const auto logicalSize:{std::array<float,2>{0,float(receiverHeight)},std::array<float,2>{float(receiverWidth),0},std::array<float,2>{0,0},
            std::array<float,2>{-1,float(receiverHeight)},std::array<float,2>{float(receiverWidth),.5f},std::array<float,2>{nan,float(receiverHeight)},
            std::array<float,2>{std::numeric_limits<float>::infinity(),float(receiverHeight)},std::array<float,2>{16385,float(receiverHeight)},std::array<float,2>{float(receiverWidth),8193}}){
            hitInputs.constants=inputsDefaults;hitInputs.vector("reflectionReceiverSize",logicalSize);
            bool inputClear=true;for(const auto& p:snapshot(priorAtlas.Get()))for(float c:p)inputClear=inputClear&&exact(c,0);
            check(inputClear,"HitInputs invalid logical receiver size did not fail closed across both planes");
            hitCopy.constants=copyDefaults;hitCopy.vector("reflectionReceiverSize",logicalSize);
            bool copyClear=true;for(const auto& p:copy(accepted.Get(),inputsTex.Get(),historyTex.Get()))for(float c:p)copyClear=copyClear&&exact(c,0);
            check(copyClear,"HitCopy invalid logical receiver size did not fail closed across both planes");
        }
        hitInputs.constants=inputsDefaults;hitCopy.constants=copyDefaults;
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));std::vector<uint8_t> bytes(size);auto message=reinterpret_cast<D3D12_MESSAGE*>(bytes.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" receiver-history GPU checks passed; actual v038/v039/HitInputs-v002/HitCopy-v002; RGBA32F atlases. Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<". No BeamNG execution.\n";
        require(failures==0,"receiver-history GPU regression failed");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
