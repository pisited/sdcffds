// Standalone D3D12: production receiver chroma helper, not game appearance proof.
#include "../gi/gpu_fixture_pass.h"
int wmain(int argc,wchar_t** argv){
    try{
        require(argc==2 || (argc==3 && std::wstring(argv[2])==L"--warp"),"usage: receiver_color_test artifacts [--warp]");
        const std::filesystem::path folder(argv[1]);
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));
        ComPtr<ID3D12Device> device;
        if(argc==3){ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
            hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));std::cout<<"WARP\n";}
        else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> adapter;
            require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))),"hardware unavailable");
            DXGI_ADAPTER_DESC1 desc{};hr(adapter->GetDesc1(&desc));if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<desc.Description<<L'\n';}
        Host host(device.Get());const auto vs=file((folder/L"receiver.vs.cso").c_str());
        FixtureShader ps(folder/L"receiver.ps.cso");ps.scalar("tint",1);
        unsigned checks=0;
        auto test=[&](Pixel scene,Pixel light,bool neutral,bool red){
            host.begin();auto a=host.texture(1,1,DXGI_FORMAT_R32G32B32A32_FLOAT,&scene,16);
            auto b=host.texture(1,1,DXGI_FORMAT_R32G32B32A32_FLOAT,&light,16);host.execute();host.wait();
            const auto output=readPixels(host,drawFixture(host,vs,ps,1,1,{{0,a.Get()},{1,b.Get()}}).Get())[0];
            for(unsigned c=0;c<3;++c)require(std::isfinite(output[c]) && output[c]>=0,"nonfinite/negative receiver color");++checks;
            const float y=output[0]*.2126f+output[1]*.7152f+output[2]*.0722f;
            require(std::abs(y-1)<.0001f,"receiver tint changed scalar luminance");++checks;
            if(neutral){for(unsigned c=0;c<3;++c)require(std::abs(output[c]-1)<.0001f,"neutral material inherited lamp color");++checks;}
            if(red){require(output[0]>output[1]*2 && output[0]>output[2]*2,"colored material was globally desaturated");++checks;}
        };
        // Same neutral material under warm, cool, saturated and weak lighting.
        for(Pixel light:{Pixel{2,.7f,.2f,0},Pixel{.2f,.7f,2,0},Pixel{4,.2f,.05f,0},Pixel{.001f,.002f,.003f,0}})
            test(Pixel{light[0]*.3f,light[1]*.3f,light[2]*.3f,0},light,true,false);
        test(Pixel{.6f,.08f,.04f,0},Pixel{1,1,1,0},false,true);
        test(Pixel{0,0,0,0},Pixel{0,0,0,0},true,false);
        test(Pixel{.2f,.05f,.01f,0},Pixel{0,0,0,0},true,false);
        ps.scalar("tint",0);test(Pixel{.6f,.08f,.04f,0},Pixel{1,1,1,0},true,false);
        std::cout<<checks<<" receiver-color GPU checks passed. No BeamNG execution.\n";return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
