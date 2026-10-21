// Actual selected PostFX history shaders, fixture-owned inputs only.
#include "../gi/gpu_fixture_pass.h"
constexpr UINT width=4,height=2;
static bool sampleNear(float value,float expected,float tolerance=1e-4f){return std::isfinite(value) && std::abs(value-expected)<=tolerance*std::max(1.f,std::abs(expected));}
int wmain(int argc,wchar_t** argv){
    try{
        require((argc==3 || (argc==4 && std::wstring(argv[3])==L"--warp")) && (std::wstring(argv[2])==L"16" || std::wstring(argv[2])==L"32"),"usage: history_shader_test artifacts Lua-moments-format-16-or-32 [--warp]");
        const bool warp=argc==4;const bool halfMoments=std::wstring(argv[2])==L"16";const std::filesystem::path folder(argv[1]);
        const auto momentFormat=halfMoments?DXGI_FORMAT_R16G16B16A16_FLOAT:DXGI_FORMAT_R32G32B32A32_FLOAT;
        ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
        if(warp){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP lighting-history fixture\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware adapter unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Lighting-history fixture: "<<desc.Description<<L'\n';}
        Host host(device.Get());auto vertex=file((folder/L"fixture.vs.cso").c_str());
        FixtureShader moments(folder/L"beamrtMomentsP_v001.hlsl.ps.cso"),gi(folder/L"beamrtTemporalP_v071.hlsl.ps.cso"),reflection(folder/L"beamrtReflectionTemporalP_v038.hlsl.ps.cso");
        auto common=[&](FixtureShader& shader){shader.vector("targetSize",std::array<float,2>{float(width),float(height)});
            shader.vector("projParams",std::array<float,4>{.1f,10,0,1});for(unsigned i=0;i<4;++i)shader.vector(("rtParams"+std::to_string(i)).c_str(),std::array<float,4>{0,0,1,1});};
        common(moments);common(gi);common(reflection);
        moments.scalar("historyValid",0);moments.scalar("historyDepthTolerance",.01f);moments.scalar("momentsMaxHistory",32);
        gi.vector("oneOverTargetSize",std::array<float,2>{1.f/width,1.f/height});gi.scalar("temporalBlend",.5f);gi.scalar("historyDepthTolerance",.01f);
        gi.scalar("historyValid",1);gi.scalar("progressivePathCount",16);gi.scalar("svgfVarianceScale",4);
        reflection.vector("oneOverTargetSize",std::array<float,2>{1.f/width,1.f/height});reflection.scalar("reflectionTemporalBlend",.25f);
        reflection.scalar("reflectionHistoryDepthTolerance",.01f);reflection.scalar("reflectionHistoryValid",1);
        reflection.scalar("reflectionMaxRoughness",.34f);reflection.scalar("reflectionSamplingMode",1);reflection.scalar("reflectionReconstructionMode",1);
        reflection.scalar("reflectionFrameDelta",1.f/60);reflection.scalar("reflectionFilterRadiusScale",1);
        const auto giDefaults=gi.constants,reflectionDefaults=reflection.constants;
        auto uploadPixels=[&](const std::vector<Pixel>& pixels){host.begin();auto result=host.texture(width,height,DXGI_FORMAT_R32G32B32A32_FLOAT,pixels.data(),16);host.execute();host.wait();return result;};
        auto uniform=[&](Pixel pixel){return uploadPixels(std::vector<Pixel>(width*height,pixel));};
        auto prepass=uniform(Pixel{.5f,.5f,.08f,0}),depth=uniform(Pixel{1,0,0,0}),velocity=uniform(Pixel{0,0,0,0}),specular=uniform(Pixel{.04f,.04f,.04f,0});
        const Pixel current{.25f,.5f,.75f,1},history{.75f,1.5f,2.25f,1},historyGI{.75f,1.5f,2.25f,1};
        auto currentTex=uniform(current);const float luminance=.25f*.2126f+.5f*.7152f+.75f*.0722f;
        auto validMoments=uniform(Pixel{luminance,luminance*luminance,4,.1f});unsigned checks=0,failures=0;
        auto check=[&](bool ok,const char* name,const std::vector<Pixel>& values){++checks;if(!ok){++failures;std::cerr<<"FAIL: "<<name<<"; pixel0=";
                for(float c:values[0])std::cerr<<c<<' ';std::cerr<<'\n';}};
        auto expect=[&](ID3D12Resource* target,Pixel expected,const char* name,int only=-1,float tolerance=1e-4f){auto pixels=readPixels(host,target);bool ok=true;
            for(size_t i=0;i<pixels.size();++i){if(only>=0 && i!=size_t(only))continue;for(unsigned c=0;c<4;++c)ok=ok && sampleNear(pixels[i][c],expected[c],tolerance);}check(ok,name,pixels);};
        // Finite values 256, 300 and 65504 are representable in the existing
        // R16F GI color target. Squaring them is NOT representable in R16F.
        for(float level:{0.f,1.f,40.f,256.f,300.f,65504.f}){auto input=uniform(Pixel{level,level,level,1});
            auto target=drawFixture(host,vertex,moments,width,height,{{0,input.Get()},{1,prepass.Get()},{2,depth.Get()},{3,velocity.Get()},{4,validMoments.Get()}},momentFormat);
            expect(target.Get(),Pixel{level,level*level,1,.1f},"finite HDR GI moments lost precision/overflowed",-1,halfMoments?1e-3f:1e-4f);}
        require(fixtureHalf(0x3c00)==1 && fixtureHalf(0x0001)==std::ldexp(1.f,-24) && std::isinf(fixtureHalf(0x7c00)),"half readback decoder control failed");
        auto bright=uniform(Pixel{300,300,300,1}),dark=uniform(Pixel{0,0,0,1});
        auto brightMoments=drawFixture(host,vertex,moments,width,height,{{0,bright.Get()},{1,prepass.Get()},{2,depth.Get()},{3,velocity.Get()},{4,validMoments.Get()}},momentFormat);
        moments.scalar("historyValid",1);auto secondFrame=drawFixture(host,vertex,moments,width,height,
            {{0,dark.Get()},{1,prepass.Get()},{2,depth.Get()},{3,velocity.Get()},{4,brightMoments.Get()}},momentFormat);
        expect(secondFrame.Get(),Pixel{150,45000,2,.1f},"finite bright/dark moment history lost expected variance",-1,halfMoments?1e-3f:1e-4f);moments.scalar("historyValid",0);
        auto runGI=[&](ID3D12Resource* old,ID3D12Resource* motion=nullptr,ID3D12Resource* input=nullptr,ID3D12Resource* receiverDepth=nullptr){
            return drawFixture(host,vertex,gi,width,height,{{0,input?input:currentTex.Get()},{1,prepass.Get()},{2,receiverDepth?receiverDepth:depth.Get()},
                {3,motion?motion:velocity.Get()},{4,old},{5,validMoments.Get()}});};
        auto runReflection=[&](ID3D12Resource* old,ID3D12Resource* motion=nullptr,ID3D12Resource* input=nullptr,ID3D12Resource* receiver=nullptr){
            return drawFixture(host,vertex,reflection,width,height,{{0,input?input:currentTex.Get()},{1,receiver?receiver:prepass.Get()},{2,depth.Get()},
                {3,motion?motion:velocity.Get()},{4,old},{5,specular.Get()}});};
        auto oldGI=uniform(historyGI),oldReflection=uniform(history);auto giGood=runGI(oldGI.Get());expect(giGood.Get(),Pixel{.5f,1,1.5f,1},"valid GI history blend changed");
        auto reflectionGood=runReflection(oldReflection.Get());expect(reflectionGood.Get(),Pixel{.6875f,1.375f,2.0625f,1},"valid playable GGX history blend changed");
        gi.scalar("historyValid",0);auto giOff=runGI(oldGI.Get());expect(giOff.Get(),current,"GI OFF history changed current sample");gi.constants=giDefaults;
        reflection.scalar("reflectionHistoryValid",0);auto reflectionOff=runReflection(oldReflection.Get());expect(reflectionOff.Get(),current,"reflection OFF history changed current sample");reflection.constants=reflectionDefaults;
        auto zero=uniform(Pixel{0,0,0,1});auto zeroGGX=runReflection(oldReflection.Get(),nullptr,zero.Get());
        expect(zeroGGX.Get(),Pixel{.65625f,1.3125f,1.96875f,1},"valid zero GGX estimator sample erased history");
        reflection.scalar("reflectionHistoryValid",0);reflection.scalar("reflectionSamplingMode",0);auto blackMirror=runReflection(oldReflection.Get(),nullptr,zero.Get());
        expect(blackMirror.Get(),Pixel{0,0,0,1},"valid black mirror hit lost geometric lifetime");reflection.constants=reflectionDefaults;
        const float nan=std::numeric_limits<float>::quiet_NaN(),inf=std::numeric_limits<float>::infinity();
        auto invalidCurrent=uniform(Pixel{nan,nan,nan,1});auto invalidCurrentGI=runGI(oldGI.Get(),nullptr,invalidCurrent.Get());
        expect(invalidCurrentGI.Get(),Pixel{0,0,0,0},"invalid current GI retained false hit support");
        auto invalidCurrentReflection=runReflection(oldReflection.Get(),nullptr,invalidCurrent.Get());
        expect(invalidCurrentReflection.Get(),Pixel{0,0,0,0},"invalid current reflection retained false history lifetime");
        for(float bad:{nan,inf})for(float alpha:{0.f,1.f,2.f}){auto poison=uniform(Pixel{bad,bad,bad,alpha});
            auto rejectedGI=runGI(poison.Get());expect(rejectedGI.Get(),current,"rejected nonfinite GI history contaminated current lighting");
            auto rejectedReflection=runReflection(poison.Get());expect(rejectedReflection.Get(),current,"rejected nonfinite reflection history contaminated current color");}
        auto invalidMotion=uniform(Pixel{nan,0,0,0});auto badMotionGI=runGI(oldGI.Get(),invalidMotion.Get());
        expect(badMotionGI.Get(),current,"invalid motion poisoned current GI");auto badMotionReflection=runReflection(oldReflection.Get(),invalidMotion.Get());
        expect(badMotionReflection.Get(),current,"invalid motion poisoned current reflection");
        moments.scalar("historyValid",1);auto poisonedMoments=uniform(Pixel{nan,1,4,.1f});auto momentRecovery=drawFixture(host,vertex,moments,width,height,
            {{0,currentTex.Get()},{1,prepass.Get()},{2,depth.Get()},{3,velocity.Get()},{4,poisonedMoments.Get()}},momentFormat);
        expect(momentRecovery.Get(),Pixel{luminance,luminance*luminance,1,.1f},"invalid moment history was accumulated instead of restarted",-1,halfMoments?1e-3f:1e-4f);
        std::vector<Pixel> badNeighbors(width*height,current);badNeighbors[0]=Pixel{inf,inf,inf,1};auto badInput=uploadPixels(badNeighbors);
        std::vector<Pixel> skyDepth(width*height,Pixel{1,0,0,0});skyDepth[0]=Pixel{.001f,0,0,0};auto neighborDepth=uploadPixels(skyDepth);
        gi.constants=giDefaults;gi.scalar("historyValid",0);gi.scalar("denoiseStrength",.35f);auto spatialGI=runGI(oldGI.Get(),nullptr,badInput.Get(),neighborDepth.Get());
        expect(spatialGI.Get(),current,"zero-weight invalid GI neighbor poisoned spatial reconstruction",1);gi.constants=giDefaults;
        std::vector<Pixel> roughNeighbor(width*height,Pixel{.5f,.5f,.08f,0});roughNeighbor[0][2]=1;auto neighborSurface=uploadPixels(roughNeighbor);
        reflection.scalar("reflectionHistoryValid",0);reflection.scalar("reflectionDenoiseStrength",.5f);auto spatialReflection=runReflection(oldReflection.Get(),nullptr,badInput.Get(),neighborSurface.Get());
        expect(spatialReflection.Get(),current,"zero-weight invalid reflection neighbor poisoned spatial reconstruction",1);reflection.constants=reflectionDefaults;
        std::vector<Pixel> badFilteredHistory(width*height,history);badFilteredHistory[0]=Pixel{inf,inf,inf,0};auto filteredHistory=uploadPixels(badFilteredHistory);
        auto subpixelMotion=uniform(Pixel{-.02f,0,0,0});reflection.scalar("reflectionColorFilterEnabled",1);
        auto colorFiltered=runReflection(filteredHistory.Get(),subpixelMotion.Get());
        expect(colorFiltered.Get(),Pixel{.6875f,1.375f,2.0625f,1},"invalid zero-weight history tap poisoned reflection color filter",1);reflection.constants=reflectionDefaults;
        auto finalGI=runGI(oldGI.Get());expect(finalGI.Get(),Pixel{.5f,1,1.5f,1},"GI did not recover after bad inputs");
        auto finalReflection=runReflection(oldReflection.Get());expect(finalReflection.Get(),Pixel{.6875f,1.375f,2.0625f,1},"reflection did not recover after bad inputs");
        ComPtr<ID3D12InfoQueue> messages;if(SUCCEEDED(device.As(&messages)))for(UINT64 i=0;i<messages->GetNumStoredMessages();++i){SIZE_T size=0;hr(messages->GetMessage(i,nullptr,&size));std::vector<uint8_t> storage(size);
            auto message=reinterpret_cast<D3D12_MESSAGE*>(storage.data());hr(messages->GetMessage(i,message,&size));require(message->Severity>D3D12_MESSAGE_SEVERITY_ERROR,message->pDescription);}
        std::cout<<checks-failures<<'/'<<checks<<" actual lighting-history shader GPU checks passed; Lua moments format="<<(halfMoments?16:32)<<". Debug layer: "<<(debugEnabled?"enabled":"unavailable")<<".\n";
        require(failures==0,"lighting-history GPU regression failed; no BeamNG execution");return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
