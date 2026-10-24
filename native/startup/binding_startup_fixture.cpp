#include "fixture_contract.h"
#include "binding_handoff.h"
#include "binding_test_support.h"
#include "resource_copy_validation.h"
#include <array>
#include <shellapi.h>
#include <dxgi1_6.h>
#include <thread>
#include <iostream>
#include <cmath>
#include <utility>
using Query=HRESULT(WINAPI*)(BeamRTBindingStatus*,uint32_t);
using Read=HRESULT(WINAPI*)(BeamRTBindingSnapshot*,uint32_t);
using ThreadQuery=HRESULT(WINAPI*)(BeamRTBindingThreadDiagnostics*,uint32_t);
using Disable=HRESULT(WINAPI*)();
static bool writeNew(const std::wstring& path,const void* data,DWORD size){HANDLE h=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(h==INVALID_HANDLE_VALUE)return false;DWORD written=0;const auto ok=WriteFile(h,data,size,&written,nullptr);CloseHandle(h);return ok && written==size;}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,LPWSTR,int){try{
    int n=0;auto values=CommandLineToArgvW(GetCommandLineW(),&n);need(values!=nullptr,"fixture args unavailable");std::vector<std::wstring> args(values,values+n);LocalFree(values);
    need(args.size()==24 && args[1]==L"--device-backend" && args[3]==L"--vs" && args[5]==L"--ps" && args[7]==L"--binding-case","startup binding fixture shape");
    auto mode=args[8];const bool resourceFixture=mode.rfind(L"resource-",0)==0;const auto resourceMode=resourceFixture?mode.substr(9):L"";
    const bool compactStorage=resourceMode==L"compact" || resourceMode==L"compact-locations" || resourceMode==L"compact-payloads" || resourceMode==L"compact-bytes";
    const bool compactPressure=compactStorage && resourceMode!=L"compact";
    const bool internedStorage=resourceMode==L"interned" || resourceMode==L"interned-payloads" || resourceMode==L"interned-bytes";
    const bool internedPressure=internedStorage && resourceMode!=L"interned";
    const bool copyCapacityCase=resourceMode==L"copy-pressure" || resourceMode==L"compact-locations" || resourceMode==L"compact-bytes" || resourceMode==L"interned-bytes";
    const bool descriptorScoped=resourceMode==L"descriptors" || resourceMode==L"descriptor-pressure" || resourceMode==L"copy-pressure" || compactStorage || internedStorage;
    if(resourceFixture){need(resourceMode==L"normal" || resourceMode==L"default-off" || resourceMode==L"no-draw" || resourceMode==L"pressure" || resourceMode==L"objects" || resourceMode==L"partial" || resourceMode==L"output-write" || descriptorScoped,"unknown resource startup case");
        mode=resourceMode==L"no-draw"?L"no-draw":L"normal";}
    args.erase(args.begin()+7,args.begin()+9);
    need(mode==L"normal" || mode==L"worker" || mode==L"no-draw" || mode==L"unsupported-root" || mode==L"observer-off"
        || mode==L"thread-rejections" || mode==L"thread-no-draw","unknown fixture case");
    need(args[7]==L"--report" && args[9]==L"--module" && args[11]==L"--hold-ms" && args[13]==L"--exit-code" && args[15]==L"--","fixture options mismatch");
    const auto vs=file(args[4].c_str()),ps=file(args[6].c_str());HMODULE module=GetModuleHandleW(args[10].c_str());need(module!=nullptr,"inserted bootstrap missing");
    const auto query=reinterpret_cast<Query>(GetProcAddress(module,"BeamRT_BindingsStatus"));const auto read=reinterpret_cast<Read>(GetProcAddress(module,"BeamRT_BindingsRead"));
    const auto disable=reinterpret_cast<Disable>(GetProcAddress(module,"BeamRT_BindingsDisable"));need(query && read && disable,"binding exports missing");
    const auto threadQuery=reinterpret_cast<ThreadQuery>(GetProcAddress(module,"BeamRT_BindingsThreadDiagnostics"));need(threadQuery!=nullptr,"thread diagnostic export missing");
    using ResourcesQuery=HRESULT(WINAPI*)(BeamRTResourceStatus*,uint32_t);using ResourcesRead=HRESULT(WINAPI*)(BeamRTResourceRecordReceipt*,uint32_t);
    const auto resourceQuery=reinterpret_cast<ResourcesQuery>(GetProcAddress(module,"BeamRT_ResourcesStatus"));
    const auto resourceRead=reinterpret_cast<ResourcesRead>(GetProcAddress(module,"BeamRT_ResourceRecordRead"));
    const auto resourceDisable=reinterpret_cast<Disable>(GetProcAddress(module,"BeamRT_ResourcesDisable"));
    using ResourcesDiagnostics=HRESULT(WINAPI*)(BeamRTResourceDiagnostics*,uint32_t);
    const auto resourceDiagnostics=reinterpret_cast<ResourcesDiagnostics>(GetProcAddress(module,"BeamRT_ResourcesDiagnostics"));
    using ResourcesProfileDiagnostics=HRESULT(WINAPI*)(BeamRTResourceProfileDiagnostics*,uint32_t);
    const auto resourceProfileDiagnostics=reinterpret_cast<ResourcesProfileDiagnostics>(GetProcAddress(module,"BeamRT_ResourcesDiagnosticsProfiled"));
    using ResourcesCandidate=HRESULT(WINAPI*)(uint64_t,uint64_t,BeamRTBufferCandidate*,uint32_t);
    const auto resourceCandidate=reinterpret_cast<ResourcesCandidate>(GetProcAddress(module,"BeamRT_ResourcesBufferCandidate"));
    using ResourcesDescriptor=HRESULT(WINAPI*)(D3D12_CPU_DESCRIPTOR_HANDLE,D3D12_DESCRIPTOR_HEAP_TYPE,BeamRTResourceView*,uint32_t);
    const auto resourceDescriptor=reinterpret_cast<ResourcesDescriptor>(GetProcAddress(module,"BeamRT_ResourcesDescriptor"));
    using ResourcesCopy=HRESULT(WINAPI*)(BeamRTResourceCopyFailure*,uint32_t);
    const auto resourceCopy=reinterpret_cast<ResourcesCopy>(GetProcAddress(module,"BeamRT_ResourcesCopyFailure"));
    BeamRTResourceFixtureReport resources{};resources.bytes=sizeof(resources);resources.abi=3;
    resources.mode=descriptorScoped?beamrtResourceDescriptorTextures:beamrtResourceAllAllocations;
    resources.profile=internedStorage?beamrtResourceStorageInterned:compactStorage?beamrtResourceStorageCompact:beamrtResourceStorageLegacy;
    need(!resourceFixture || (resourceQuery && resourceRead && resourceDisable && resourceDiagnostics && resourceProfileDiagnostics && resourceCopy),"resource exports missing");
    BeamRTResourceCopyFailure observedCopy{},emptyCopy{};emptyCopy.bytes=sizeof(emptyCopy);emptyCopy.abi=beamrtResourceCopyFailureABI;
    if(resourceFixture){std::memset(&observedCopy,0xa5,sizeof(observedCopy));const BeamRTResourceCopyFailure zero{};
        need(resourceCopy(&observedCopy,sizeof(observedCopy))==HRESULT_FROM_WIN32(ERROR_NOT_READY) && !std::memcmp(&observedCopy,&zero,sizeof(zero)),"startup copy diagnostics began before device observation");}
    ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<IDXGIAdapter> adapter;
    if(args[2]==L"warp")hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
    else {need(args[2]==L"hardware","backend invalid");for(UINT i=0;!adapter;++i){ComPtr<IDXGIAdapter1> a;hr(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&a)));
        DXGI_ADAPTER_DESC1 d{};hr(a->GetDesc1(&d));if(!(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) && SUCCEEDED(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)))hr(a.As(&adapter));}}
    // The actual imported output automatically installs the opted-in observer
    // before the fixture sees it. No explicit Start/Target call is made here.
    ComPtr<ID3D12Device> device;hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));BeamRTBindingFixtureReport report{};
    const auto initial=query(&report.status,sizeof(report.status));
    if(resourceFixture){const auto ready=resourceQuery(&resources.before,sizeof(resources.before));resources.enabled=SUCCEEDED(ready) && resources.before.enabled?1u:0u;
        need(resources.enabled==(resourceMode==L"default-off"?0u:1u),"automatic resource start/default OFF mismatch");
        if(resources.enabled){BeamRTResourceProfileDiagnostics initialResources{};hr(resourceProfileDiagnostics(&initialResources,sizeof(initialResources)));
            resources.storageBefore=initialResources.storage;
            need(beamrtResourceStorageEvidenceValid(initialResources.storage,initialResources.storageFailure,initialResources.firstFailure,initialResources.status,resources.profile),
                "startup storage profile or empty diagnostics mismatch");
            need(resourceCopy(&observedCopy,sizeof(observedCopy))==S_FALSE && !std::memcmp(&observedCopy,&emptyCopy,sizeof(emptyCopy))
                && beamrtResourceCopyFailureValid(observedCopy,initialResources.firstFailure,initialResources.status,resources.mode,resources.profile),"healthy startup invented a copy failure companion");}}
    if(mode==L"observer-off")need(initial==HRESULT_FROM_WIN32(ERROR_NOT_READY) && !report.status.enabled,"missing payload started bindings");
    else need(SUCCEEDED(initial) && report.status.enabled && report.status.healthy && !report.status.targetReady,"automatic early start failed");
    Renderer render(device.Get());
    if(mode==L"thread-rejections"){
        Renderer unrelated(device.Get());unrelated.begin();
        std::thread worker([&]{D3D12_VIEWPORT v{0,0,1,1,0,1};unrelated.list->RSSetViewports(1,&v);});worker.join();hr(unrelated.list->Close());
    }
    D3D12_DESCRIPTOR_RANGE ranges[2]={{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,6,0,0,0},{D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,6,0,0,0}};
    D3D12_ROOT_PARAMETER params[3]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;params[0].Descriptor={0,0};
    for(UINT i=1;i<3;++i){params[i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[i].DescriptorTable={1,&ranges[i-1]};}
    D3D12_ROOT_SIGNATURE_DESC rs{3,params,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
    if(mode==L"unsupported-root")rs.Flags|=D3D12_ROOT_SIGNATURE_FLAG_DENY_HULL_SHADER_ROOT_ACCESS;
    ComPtr<ID3DBlob> blob,error;hr(D3D12SerializeRootSignature(&rs,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error));ComPtr<ID3D12RootSignature> root;
    hr(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d{};d.pRootSignature=root.Get();d.VS={vs.data(),vs.size()};d.PS={ps.data(),ps.size()};d.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;d.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;d.RasterizerState.DepthClipEnable=TRUE;
    d.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;d.SampleMask=UINT_MAX;d.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;d.NumRenderTargets=1;d.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;d.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pso;HRESULT made=S_OK;
    if(mode==L"worker"){std::thread worker([&]{report.targetWorkerThread=GetCurrentThreadId();made=device->CreateGraphicsPipelineState(&d,IID_PPV_ARGS(&pso));});worker.join();}
    else made=device->CreateGraphicsPipelineState(&d,IID_PPV_ARGS(&pso));hr(made);
    // Keep more than 128 unrelated resources alive before any GI texture exists.
    // Neither upload buffers nor even supported textures consume admission rows
    // until a supported SRV/RTV is written in descriptor-scoped mode.
    std::vector<ComPtr<ID3D12Resource>> irrelevantResources;
    if(descriptorScoped){
        need(resourceDiagnostics && resourceCandidate,"descriptor diagnostics exports missing");
        D3D12_RESOURCE_DESC unused{};unused.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;unused.Width=unused.Height=1;
        unused.DepthOrArraySize=unused.MipLevels=1;unused.SampleDesc.Count=1;unused.Format=d.RTVFormats[0];
        for(unsigned i=0;i<beamrtResourceObjectLimit+1;++i){
            irrelevantResources.push_back(resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ));
            irrelevantResources.push_back(resource(device.Get(),unused,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COMMON));
            BeamRTResourceDiagnostics empty{};hr(resourceDiagnostics(&empty,sizeof(empty)));
            need(empty.status.enabled && empty.status.healthy && !empty.status.liveResources && !empty.status.pressure && !empty.status.overlaps
                && beamrtResourceFailureValid(empty.firstFailure,empty.status,resources.profile) && !empty.firstFailure.kind,"unreferenced creation consumed descriptor admission budget");
        }
        need(irrelevantResources.size()>beamrtResourceObjectLimit,"descriptor startup did not retain irrelevant allocation pressure");
    }
    render.begin();std::vector<ComPtr<ID3D12Resource>> textures;for(int i=1;i<=6;++i)textures.push_back(render.texture(static_cast<float>(i)));
    render.submit();
    if(resourceMode==L"partial"){
        render.begin();
        // A legal typed float texture sampled by the same shader; unsupported
        // by the narrow metadata tracker, so it must remain explicitly unknown.
        auto desc=textures[0]->GetDesc();desc.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;
        auto partial=resource(device.Get(),desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT f{};UINT r;UINT64 rowBytes,totalBytes;device->GetCopyableFootprints(&desc,0,1,0,&f,&r,&rowBytes,&totalBytes);
        auto upload=resource(device.Get(),buffer(totalBytes),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* data;D3D12_RANGE noRead{0,0};hr(upload->Map(0,&noRead,&data));
        const uint16_t one[4]={0x3c00,0x3c00,0x3c00,0x3c00};std::memcpy(static_cast<uint8_t*>(data)+f.Offset,one,sizeof(one));upload->Unmap(0,nullptr);
        D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=upload.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=f;
        dst.pResource=partial.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;render.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        transition(render.list.Get(),partial.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        render.uploads.push_back(upload);render.submit();textures[0]=std::move(partial);
    }
    auto constants=resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* mapped;D3D12_RANGE none{0,0};hr(constants->Map(0,&none,&mapped));float bias[]={2,2,2,2};std::memcpy(mapped,bias,sizeof(bias));constants->Unmap(0,nullptr);
    D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,6,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};ComPtr<ID3D12DescriptorHeap> srv,sampler,rtv;
    hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&srv)));hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&sampler)));
    const auto ss=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV),fs=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=d.RTVFormats[0];view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2D.MipLevels=1;
    D3D12_SAMPLER_DESC filter{};filter.Filter=D3D12_FILTER_MIN_MAG_MIP_POINT;filter.AddressU=filter.AddressV=filter.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;filter.MaxLOD=D3D12_FLOAT32_MAX;filter.MaxAnisotropy=1;filter.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    for(UINT i=0;i<6;++i){auto s=srv->GetCPUDescriptorHandleForHeapStart();s.ptr+=i*ss;auto actualView=view;actualView.Format=textures[i]->GetDesc().Format;device->CreateShaderResourceView(textures[i].Get(),&actualView,s);auto f=sampler->GetCPUDescriptorHandleForHeapStart();f.ptr+=i*fs;device->CreateSampler(&filter,f);}
    D3D12_RESOURCE_DESC td{};td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;td.Width=td.Height=1;td.DepthOrArraySize=1;td.MipLevels=1;td.SampleDesc.Count=1;td.Format=d.RTVFormats[0];td.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=resource(device.Get(),td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);hd={D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtv)));device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 row,total;device->GetCopyableFootprints(&td,0,1,0,&footprint,&rows,&row,&total);auto readback=resource(device.Get(),buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    std::vector<ComPtr<ID3D12Resource>> descriptorPressure;BeamRTResourceFailure descriptorFailure{};
    ComPtr<ID3D12DescriptorHeap> descriptorPressureHeap;
    ComPtr<ID3D12DescriptorHeap> copyPressureHeap;BeamRTResourceFailure copyPublicationFailure{};std::array<BeamRTResourceView,3> publicationSources{};
    ComPtr<ID3D12DescriptorHeap> compactHeap;BeamRTResourceProfileDiagnostics compactAtDraw{};
    ComPtr<ID3D12DescriptorHeap> internedHeap;BeamRTResourceProfileDiagnostics internedAtDraw{};
    if(descriptorScoped){
        BeamRTResourceDiagnostics observed{};hr(resourceDiagnostics(&observed,sizeof(observed)));
        need(observed.status.enabled && observed.status.healthy && observed.status.liveResources==7 && observed.status.views==7
            && !observed.status.pressure && !observed.status.overlaps && !observed.firstFailure.kind,"descriptor startup did not admit exactly six inputs and one output");
        for(const auto address:{constants->GetGPUVirtualAddress(),readback->GetGPUVirtualAddress(),irrelevantResources[0]->GetGPUVirtualAddress()}){
            BeamRTBufferCandidate candidate;std::memset(&candidate,0xa5,sizeof(candidate));const BeamRTBufferCandidate zero{};
            need(FAILED(resourceCandidate(address,16,&candidate,sizeof(candidate))) && !std::memcmp(&candidate,&zero,sizeof(candidate)),"descriptor mode guessed an unindexed CBV buffer");
        }
        if(resourceMode==L"descriptors"){
            need(resourceDescriptor!=nullptr,"descriptor copy lookup export missing");
            D3D12_DESCRIPTOR_HEAP_DESC copyDesc{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,beamrtResourceViewLimit+1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
            ComPtr<ID3D12DescriptorHeap> copyHeap;hr(device->CreateDescriptorHeap(&copyDesc,IID_PPV_ARGS(&copyHeap)));
            const auto copySlot=[&](unsigned index){auto handle=copyHeap->GetCPUDescriptorHandleForHeapStart();handle.ptr+=uint64_t(index)*ss;return handle;};
            const unsigned knownCount=beamrtResourceViewLimit-7;
            for(unsigned i=0;i<knownCount;++i)device->CreateShaderResourceView(textures[0].Get(),&view,copySlot(i));
            const auto knownSource=copySlot(0),nullSource=copySlot(knownCount),oldDestination=copySlot(knownCount-1),newDestination=copySlot(knownCount+1);
            // A real native null descriptor, not an uninitialized source slot.
            device->CreateShaderResourceView(nullptr,&view,nullSource);
            BeamRTResourceView sourceView{};hr(resourceDescriptor(knownSource,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,&sourceView,sizeof(sourceView)));
            for(unsigned ordering=0;ordering<2;++ordering){
                if(ordering){
                    device->CreateShaderResourceView(nullptr,&view,newDestination);
                    device->CreateShaderResourceView(textures[0].Get(),&view,oldDestination);
                }
                hr(resourceDiagnostics(&observed,sizeof(observed)));
                need(observed.status.enabled && observed.status.healthy && observed.status.liveResources==7 && observed.status.views==beamrtResourceViewLimit
                    && !observed.status.pressure && !observed.status.overlaps && !observed.firstFailure.kind,"mixed descriptor copy did not start at full 256-view capacity");
                const auto unknownBefore=observed.status.unknownCopies;
                D3D12_CPU_DESCRIPTOR_HANDLE destinations[2]={newDestination,oldDestination},sources[2]={knownSource,nullSource};
                if(ordering){std::swap(destinations[0],destinations[1]);std::swap(sources[0],sources[1]);}
                // Native semantics snapshot both sources; final metadata is still
                // 256 views after one clear and one new known destination.
                device->CopyDescriptors(2,destinations,nullptr,2,sources,nullptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
                hr(resourceDiagnostics(&observed,sizeof(observed)));
                need(observed.status.enabled && observed.status.healthy && observed.status.liveResources==7 && observed.status.views==beamrtResourceViewLimit
                    && observed.status.unknownCopies==unknownBefore+1 && !observed.status.pressure && !observed.status.overlaps && !observed.firstFailure.kind,
                    ordering?"mixed descriptor null-first copy falsely exhausted full view table":"mixed descriptor known-first copy falsely exhausted full view table");
                BeamRTResourceView copied{},cleared;std::memset(&cleared,0xa5,sizeof(cleared));const BeamRTResourceView zero{};
                const auto copiedResult=resourceDescriptor(newDestination,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,&copied,sizeof(copied));
                const auto clearedResult=resourceDescriptor(oldDestination,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,&cleared,sizeof(cleared));
                need(SUCCEEDED(copiedResult) && copied.resourceId==sourceView.resourceId && copied.canonicalIdentity==sourceView.canonicalIdentity
                    && copied.heapId==sourceView.heapId && FAILED(clearedResult) && !std::memcmp(&cleared,&zero,sizeof(zero)),
                    ordering?"mixed descriptor null-first copy lost known/null provenance":"mixed descriptor known-first copy lost known/null provenance");
            }
            // These CPU-only temporary descriptors are never submitted. Retire
            // their heap before the real GI draw and preserve its exact baseline.
            copyHeap.Reset();hr(resourceDiagnostics(&observed,sizeof(observed)));
            need(observed.status.enabled && observed.status.healthy && observed.status.liveHeaps==2 && observed.status.liveResources==7 && observed.status.views==7
                && !observed.status.pressure && !observed.status.overlaps && !observed.firstFailure.kind,"mixed descriptor copy temporary heap did not retire to seven-view GI baseline");
        }
        if(resourceMode==L"descriptor-pressure"){
            D3D12_DESCRIPTOR_HEAP_DESC more{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
            hr(device->CreateDescriptorHeap(&more,IID_PPV_ARGS(&descriptorPressureHeap)));auto liveCount=observed.status.liveResources;
            while(liveCount<beamrtResourceObjectLimit){
                descriptorPressure.push_back(resource(device.Get(),td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COMMON));
                hr(resourceDiagnostics(&observed,sizeof(observed)));
                need(observed.status.healthy && observed.status.liveResources==liveCount && !observed.status.pressure && !observed.firstFailure.kind,"descriptor allocation admitted before its SRV");
                device->CreateShaderResourceView(descriptorPressure.back().Get(),&view,descriptorPressureHeap->GetCPUDescriptorHandleForHeapStart());
                hr(resourceDiagnostics(&observed,sizeof(observed)));++liveCount;
                need(observed.status.healthy && observed.status.liveResources==liveCount && !observed.status.pressure && !observed.status.overlaps
                    && !observed.firstFailure.kind,"descriptor table became invalid before exact capacity");
            }
            descriptorPressure.push_back(resource(device.Get(),td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COMMON));
            hr(resourceDiagnostics(&observed,sizeof(observed)));
            need(observed.status.healthy && observed.status.liveResources==beamrtResourceObjectLimit && !observed.firstFailure.kind,"descriptor capacity refused native allocation rather than admission");
            device->CreateShaderResourceView(descriptorPressure.back().Get(),&view,descriptorPressureHeap->GetCPUDescriptorHandleForHeapStart());
            hr(resourceDiagnostics(&observed,sizeof(observed)));descriptorFailure=observed.firstFailure;
            need(observed.status.enabled && !observed.status.healthy && observed.status.pressure==1 && !observed.status.overlaps
                && observed.status.liveResources==beamrtResourceObjectLimit && beamrtResourceFailureValid(descriptorFailure,observed.status)
                && descriptorFailure.kind==BeamRTResourceFailureObjectCapacity && descriptorFailure.method==BeamRTResourceMethodCreateSRV
                && descriptorFailure.capacityLimit==beamrtResourceObjectLimit && descriptorFailure.attemptedCount==beamrtResourceObjectLimit+1
                && descriptorFailure.liveResources==beamrtResourceObjectLimit && descriptorFailure.callerThread==GetCurrentThreadId(),"descriptor resource capacity did not fail closed precisely at SRV admission");
        }
        if(resourceMode==L"copy-pressure"){
            need(resourceDescriptor!=nullptr,"copy fixture descriptor query missing");
            D3D12_DESCRIPTOR_HEAP_DESC more{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,beamrtResourceViewLimit+3,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
            hr(device->CreateDescriptorHeap(&more,IID_PPV_ARGS(&copyPressureHeap)));
            auto copySlot=[&](UINT index){auto handle=copyPressureHeap->GetCPUDescriptorHandleForHeapStart();handle.ptr+=uint64_t(index)*ss;return handle;};
            device->CreateShaderResourceView(textures[0].Get(),&view,copySlot(0));const UINT fill=beamrtResourceViewLimit-7;
            for(UINT i=1;i<fill;++i)device->CopyDescriptorsSimple(1,copySlot(i),copySlot(0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            hr(resourceDiagnostics(&observed,sizeof(observed)));
            need(observed.status.healthy && observed.status.views==256 && observed.status.liveResources==7 && !observed.status.pressure && !observed.firstFailure.kind,"co-linked copy fixture did not reach exact view capacity");
            for(UINT i=0;i<3;++i)hr(resourceDescriptor(copySlot(i),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,&publicationSources[i],sizeof(publicationSources[i])));
            std::array<D3D12_CPU_DESCRIPTOR_HANDLE,3> copySources={copySlot(0),copySlot(1),copySlot(2)},copyDestinations={copySlot(fill),copySlot(fill+1),copySlot(fill+2)};
            device->CopyDescriptors(3,copyDestinations.data(),nullptr,3,copySources.data(),nullptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            hr(resourceDiagnostics(&observed,sizeof(observed)));copyPublicationFailure=observed.firstFailure;
            need(!observed.status.healthy && observed.status.pressure==1 && !observed.status.overlaps && observed.status.views==256
                && copyPublicationFailure.kind==BeamRTResourceFailureViewCapacity && copyPublicationFailure.method==BeamRTResourceMethodCopyRanges
                && copyPublicationFailure.capacityLimit==256 && copyPublicationFailure.attemptedCount==257
                && observed.status.serial==copyPublicationFailure.serial,"co-linked copy capacity failure was not precise and fail-stop");
        }
    }
    if(compactStorage){
        need(resourceDescriptor!=nullptr,"compact fixture descriptor query missing");
        BeamRTResourceProfileDiagnostics observed{};hr(resourceProfileDiagnostics(&observed,sizeof(observed)));
        need(beamrtResourceStorageEvidenceValid(observed.storage,observed.storageFailure,observed.firstFailure,observed.status,resources.profile)
            && observed.status.healthy && observed.status.liveResources==7 && observed.storage.locations==7
            && observed.storage.payloads==7 && observed.storage.usedBytes==1288 && observed.storage.locationLimit==1024
            && observed.storage.payloadLimit==256 && observed.storage.byteLimit==47104,"compact storage initial seven-view baseline mismatch");
        D3D12_DESCRIPTOR_HEAP_DESC more{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1025,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
        hr(device->CreateDescriptorHeap(&more,IID_PPV_ARGS(&compactHeap)));
        const auto compactSlot=[&](UINT index){auto handle=compactHeap->GetCPUDescriptorHandleForHeapStart();handle.ptr+=uint64_t(index)*ss;return handle;};
        const bool uniquePayloads=resourceMode==L"compact-payloads" || resourceMode==L"compact-bytes";
        const UINT fill=uniquePayloads?249u:resourceMode==L"compact-locations"?1017u:300u;
        for(UINT i=0;i<fill;++i){
            if(uniquePayloads){auto distinct=view;distinct.Texture2D.ResourceMinLODClamp=static_cast<float>(i+1)/512.0f;
                // Metadata-only legal native views: never bind/sample these LOD
                // variants. GPU verification continues to use the original GI SRVs.
                device->CreateShaderResourceView(textures[0].Get(),&distinct,compactSlot(i));
            }else if(!i)device->CreateShaderResourceView(textures[0].Get(),&view,compactSlot(0));
            else device->CopyDescriptorsSimple(1,compactSlot(i),compactSlot(0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        }
        hr(resourceProfileDiagnostics(&observed,sizeof(observed)));
        const uint32_t locations=7+fill,payloads=uniquePayloads?256u:7u;
        need(beamrtResourceStorageEvidenceValid(observed.storage,observed.storageFailure,observed.firstFailure,observed.status,resources.profile)
            && observed.status.healthy && !observed.firstFailure.kind && observed.status.liveResources==7
            && observed.storage.locations==locations && observed.storage.payloads==payloads
            && observed.storage.usedBytes==locations*24+payloads*160,"compact fixture storage fill did not preserve exact locations/payloads/bytes");
        if(compactPressure){
            if(resourceMode==L"compact-payloads"){auto distinct=view;distinct.Texture2D.ResourceMinLODClamp=250.0f/512.0f;
                device->CreateShaderResourceView(textures[0].Get(),&distinct,compactSlot(fill));
            }else{const auto source=compactSlot(0),destination=compactSlot(fill);
                device->CopyDescriptors(1,&destination,nullptr,1,&source,nullptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);}
            hr(resourceProfileDiagnostics(&compactAtDraw,sizeof(compactAtDraw)));
            const auto& f=compactAtDraw.firstFailure;const auto& s=compactAtDraw.storage;const auto& e=compactAtDraw.storageFailure;
            const uint32_t cause=resourceMode==L"compact-locations"?beamrtResourceStorageFailureLocations:
                resourceMode==L"compact-payloads"?beamrtResourceStorageFailurePayloads:beamrtResourceStorageFailureBytes;
            const uint32_t kind=resourceMode==L"compact-locations"?BeamRTResourceFailureViewCapacity:
                resourceMode==L"compact-payloads"?BeamRTResourceFailureViewPayloadCapacity:BeamRTResourceFailureViewByteCapacity;
            const uint32_t limit=resourceMode==L"compact-locations"?1024u:resourceMode==L"compact-payloads"?256u:47104u;
            const uint32_t attempted=resourceMode==L"compact-locations"?1025u:resourceMode==L"compact-payloads"?257u:47128u;
            need(beamrtResourceStorageEvidenceValid(s,e,f,compactAtDraw.status,resources.profile)
                && !compactAtDraw.status.healthy && compactAtDraw.status.pressure==1 && !compactAtDraw.status.overlaps
                && compactAtDraw.status.liveResources==7 && s.locations==locations && s.payloads==payloads
                && f.kind==kind && f.method==(resourceMode==L"compact-payloads"?BeamRTResourceMethodCreateSRV:BeamRTResourceMethodCopyRanges)
                && f.capacityLimit==limit && f.attemptedCount==attempted && f.serial==compactAtDraw.status.serial
                && e.present==1 && e.cause==cause && e.attemptedLocations==locations+1
                && e.attemptedPayloads==payloads+(uniquePayloads && resourceMode==L"compact-payloads"?1u:0u)
                && e.requiredBytes==s.usedBytes+24+(resourceMode==L"compact-payloads"?160u:0u),"compact capacity cause, ordering or exact demand mismatch");
        }else{compactAtDraw=observed;need(observed.storage.locations==307 && observed.storage.payloads==7 && observed.storage.usedBytes==8488,
            "compact shared fanout did not exceed legacy capacity within unchanged byte budget");}
    }
    if(internedStorage){
        need(resourceDescriptor!=nullptr,"interned fixture descriptor query missing");
        BeamRTResourceProfileDiagnostics observed{};hr(resourceProfileDiagnostics(&observed,sizeof(observed)));
        need(beamrtResourceStorageEvidenceValid(observed.storage,observed.storageFailure,observed.firstFailure,observed.status,resources.profile)
            && observed.status.healthy && observed.status.liveResources==7 && observed.storage.locations==7 && observed.storage.payloads==7
            && observed.storage.usedBytes==1730 && observed.storage.locationLimit==4096 && observed.storage.payloadLimit==256
            && observed.storage.byteLimit==47104 && observed.storage.directoryBytes==512 && observed.storage.locationBytes==14
            && observed.storage.heaps==2 && observed.storage.heapLimit==32,"interned storage initial seven-view baseline mismatch");
        D3D12_DESCRIPTOR_HEAP_DESC more{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,3249,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
        hr(device->CreateDescriptorHeap(&more,IID_PPV_ARGS(&internedHeap)));
        const auto internedSlot=[&](UINT index){auto handle=internedHeap->GetCPUDescriptorHandleForHeapStart();handle.ptr+=uint64_t(index)*ss;return handle;};
        const bool payloadPressure=resourceMode==L"interned-payloads";
        const UINT fill=payloadPressure?249u:resourceMode==L"interned-bytes"?3241u:1993u;
        for(UINT i=0;i<fill;++i){
            if(payloadPressure){auto distinct=view;distinct.Texture2D.ResourceMinLODClamp=static_cast<float>(i+1)/512.0f;
                // Metadata-only exact descriptions, never submitted to the GPU.
                device->CreateShaderResourceView(textures[0].Get(),&distinct,internedSlot(i));
            }else if(!i)device->CreateShaderResourceView(textures[0].Get(),&view,internedSlot(0));
            else device->CopyDescriptorsSimple(1,internedSlot(i),internedSlot(0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        }
        hr(resourceProfileDiagnostics(&observed,sizeof(observed)));
        const uint32_t locations=7+fill,payloads=payloadPressure?256u:7u;
        need(beamrtResourceStorageEvidenceValid(observed.storage,observed.storageFailure,observed.firstFailure,observed.status,resources.profile)
            && observed.status.healthy && !observed.firstFailure.kind && observed.status.liveResources==7
            && observed.storage.locations==locations && observed.storage.payloads==payloads && observed.storage.heaps==3
            && observed.storage.usedBytes==512+locations*14+payloads*160,"interned fixture exact location/payload/heap/byte fill mismatch");
        if(internedPressure){
            if(payloadPressure){auto distinct=view;distinct.Texture2D.ResourceMinLODClamp=250.0f/512.0f;
                device->CreateShaderResourceView(textures[0].Get(),&distinct,internedSlot(fill));
            }else{const auto source=internedSlot(0),destination=internedSlot(fill);
                device->CopyDescriptors(1,&destination,nullptr,1,&source,nullptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);}
            hr(resourceProfileDiagnostics(&internedAtDraw,sizeof(internedAtDraw)));
            const auto& f=internedAtDraw.firstFailure;const auto& s=internedAtDraw.storage;const auto& e=internedAtDraw.storageFailure;
            need(beamrtResourceStorageEvidenceValid(s,e,f,internedAtDraw.status,resources.profile)
                && !internedAtDraw.status.healthy && internedAtDraw.status.pressure==1 && !internedAtDraw.status.overlaps
                && internedAtDraw.status.liveResources==7 && s.locations==locations && s.payloads==payloads && s.heaps==3
                && f.kind==(payloadPressure?BeamRTResourceFailureViewPayloadCapacity:BeamRTResourceFailureViewByteCapacity)
                && f.method==(payloadPressure?BeamRTResourceMethodCreateSRV:BeamRTResourceMethodCopyRanges)
                && f.capacityLimit==(payloadPressure?256u:47104u) && f.attemptedCount==(payloadPressure?257u:47118u)
                && f.serial==internedAtDraw.status.serial && e.present==1
                && e.cause==(payloadPressure?beamrtResourceStorageFailurePayloads:beamrtResourceStorageFailureBytes)
                && e.attemptedLocations==locations+1 && e.attemptedPayloads==payloads+(payloadPressure?1u:0u)
                && e.attemptedHeaps==3 && e.requiredBytes==s.usedBytes+14+(payloadPressure?160u:0u),"interned capacity cause or exact demand mismatch");
        }else{internedAtDraw=observed;need(observed.storage.locations==2000 && observed.storage.payloads==7 && observed.storage.usedBytes==29632,
            "interned exact-location fanout did not exceed compact count within fixed arena");}
    }
    std::vector<ComPtr<ID3D12DescriptorHeap>> pressure;
    if(resourceMode==L"pressure")for(unsigned i=0;i<beamrtResourceHeapLimit+1;++i){D3D12_DESCRIPTOR_HEAP_DESC more{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
        ComPtr<ID3D12DescriptorHeap> h;hr(device->CreateDescriptorHeap(&more,IID_PPV_ARGS(&h)));pressure.push_back(std::move(h));}
    // Exercise the production co-linked bootstrap, not the standalone tracker.
    // Retain every native allocation so table slot 58 and then all 128 object
    // slots must be traversed while healthy, before the 129th metadata entry is
    // refused. Native allocation and both GPU draws must still succeed.
    std::vector<ComPtr<ID3D12Resource>> objectPressure;BeamRTResourceFailure objectFailure{};
    if(resourceMode==L"objects"){
        need(resourceDiagnostics!=nullptr,"resource diagnostics export missing");BeamRTResourceDiagnostics observed{};
        hr(resourceDiagnostics(&observed,sizeof(observed)));
        // Exactly six textures plus constants, target and readback remain live;
        // submit() retired all six uploads. A phantom table entry must not be
        // normalized into the pressure loop's starting count.
        need(observed.status.enabled && observed.status.healthy && !observed.firstFailure.kind && !observed.status.overlaps
            && observed.status.liveResources==9,"resource pressure baseline invalid");
        auto liveCount=observed.status.liveResources;bool crossedCorruptSlot=false;
        while(liveCount<beamrtResourceObjectLimit){
            objectPressure.push_back(resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ));
            hr(resourceDiagnostics(&observed,sizeof(observed)));++liveCount;
            need(observed.status.enabled && observed.status.healthy && !observed.status.pressure && !observed.status.overlaps
                && observed.status.liveResources==liveCount && beamrtResourceFailureValid(observed.firstFailure,observed.status)
                && !observed.firstFailure.kind,"co-linked object table became invalid before capacity");
            if(liveCount==60)crossedCorruptSlot=true;
        }
        need(crossedCorruptSlot && liveCount==beamrtResourceObjectLimit,"co-linked resource slot 58 was not crossed");
        objectPressure.push_back(resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ));
        hr(resourceDiagnostics(&observed,sizeof(observed)));objectFailure=observed.firstFailure;
        need(observed.status.enabled && !observed.status.healthy && observed.status.pressure==1 && !observed.status.overlaps
            && observed.status.liveResources==beamrtResourceObjectLimit && beamrtResourceFailureValid(objectFailure,observed.status)
            && objectFailure.kind==BeamRTResourceFailureObjectCapacity && objectFailure.method==BeamRTResourceMethodCommitted
            && objectFailure.capacityLimit==beamrtResourceObjectLimit && objectFailure.attemptedCount==beamrtResourceObjectLimit+1
            && objectFailure.liveResources==beamrtResourceObjectLimit && objectFailure.callerThread==GetCurrentThreadId(),
            "co-linked resource capacity did not fail closed precisely");
    }
    render.begin();render.list->SetPipelineState(pso.Get());render.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={srv.Get(),sampler.Get()};render.list->SetDescriptorHeaps(2,heaps);
    render.list->SetGraphicsRootConstantBufferView(0,constants->GetGPUVirtualAddress());render.list->SetGraphicsRootDescriptorTable(1,srv->GetGPUDescriptorHandleForHeapStart());render.list->SetGraphicsRootDescriptorTable(2,sampler->GetGPUDescriptorHandleForHeapStart());
    D3D12_VIEWPORT viewport{0,0,1,1,0,1};D3D12_RECT scissor{0,0,1,1};render.list->RSSetViewports(1,&viewport);render.list->RSSetScissorRects(1,&scissor);auto output=rtv->GetCPUDescriptorHandleForHeapStart();render.list->OMSetRenderTargets(1,&output,FALSE,nullptr);render.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ComPtr<ID3D12Resource> alternateOutput;
    if(resourceMode==L"output-write"){alternateOutput=resource(device.Get(),td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        device->CreateRenderTargetView(alternateOutput.Get(),nullptr,output);}
    if(mode==L"thread-no-draw"){
        std::thread worker([&]{D3D12_VIEWPORT v{0,0,1,1,0,1};render.list->RSSetViewports(1,&v);});worker.join();
    }
    if(mode!=L"no-draw" && mode!=L"thread-no-draw")render.list->DrawInstanced(3,1,0,0);const auto observed=read(&report.snapshot,sizeof(report.snapshot));
    report.captured=SUCCEEDED(observed)?1u:0u;need(bool(report.captured)==(mode==L"normal" || mode==L"worker" || mode==L"thread-rejections"),"recording expectation failed");
    if(report.captured){need(beamrtBindingSnapshotValid(report.snapshot) && report.snapshot.cbv==constants->GetGPUVirtualAddress()
        && report.snapshot.srvCpu[5]==srv->GetCPUDescriptorHandleForHeapStart().ptr+5*ss && report.snapshot.samplerCpu[5]==sampler->GetCPUDescriptorHandleForHeapStart().ptr+5*fs
        && report.snapshot.renderTargets[0]==output.ptr,"captured real binding values mismatch");}
    else need(!report.snapshot.bytes && !report.snapshot.recordedDraw,"unavailable observation not cleared");
    if(resourceFixture){
        const auto got=resourceRead(&resources.receipt,sizeof(resources.receipt));
        if(resources.enabled && report.captured){need(SUCCEEDED(got) && beamrtResourceObservationValid(resources.receipt.observation,report.snapshot,GetCurrentThreadId(),resources.profile),"resource fixture receipt invalid");
            need(resources.receipt.mode==resources.mode && !resources.receipt.reserved && resources.receipt.profile==resources.profile && !resources.receipt.reserved2,
                "resource fixture admission/storage profile differs from receipt");
            if(resourceMode==L"objects")need(!resources.receipt.observation.intervalAccepted && FAILED(resources.receipt.observation.result)
                && !std::memcmp(&resources.receipt.observation.firstFailure,&objectFailure,sizeof(objectFailure)),"object capacity receipt lost first failure");
            if(resourceMode==L"descriptor-pressure")need(!resources.receipt.observation.intervalAccepted && FAILED(resources.receipt.observation.result)
                && !std::memcmp(&resources.receipt.observation.firstFailure,&descriptorFailure,sizeof(descriptorFailure)),"descriptor capacity receipt lost first failure");
            const auto copied=resourceCopy(&observedCopy,sizeof(observedCopy));const auto& observedFrame=resources.receipt.observation;
            need(copied==(copyCapacityCase?S_OK:S_FALSE)
                && !std::memcmp(&observedCopy,&resources.receipt.copyFailure,sizeof(observedCopy))
                && beamrtResourceCopyFailureValid(observedCopy,observedFrame.firstFailure,observedFrame.status,resources.mode,resources.profile),"startup published copy companion differs from the native tracker");
            if(resourceMode==L"copy-pressure"){
                need(!observedFrame.intervalAccepted && FAILED(observedFrame.result) && !std::memcmp(&observedFrame.firstFailure,&copyPublicationFailure,sizeof(copyPublicationFailure))
                    && observedCopy.present==1 && observedCopy.laneCount==3 && !observedCopy.failedLane && !observedCopy.appliedLanes
                    && observedCopy.entryViews==256 && observedCopy.afterClearViews==256,"co-linked copy companion omitted exact failure phases");
                for(UINT i=0;i<3;++i)need(!std::memcmp(&observedCopy.lanes[i].source,&publicationSources[i],sizeof(publicationSources[i])),"co-linked copy companion lost exact source snapshots");
            }else if(compactStorage){
                need(!std::memcmp(&observedFrame.storage,&compactAtDraw.storage,sizeof(observedFrame.storage))
                    && !std::memcmp(&observedFrame.storageFailure,&compactAtDraw.storageFailure,sizeof(observedFrame.storageFailure))
                    && !std::memcmp(&observedFrame.firstFailure,&compactAtDraw.firstFailure,sizeof(observedFrame.firstFailure)),
                    "compact draw receipt changed selected profile metrics or first failure");
                if(compactPressure)need(!observedFrame.intervalAccepted && FAILED(observedFrame.result),"compact capacity receipt falsely accepted metadata");
                else need(observedFrame.intervalAccepted && observedFrame.result==S_OK && observedFrame.storage.locations>256,"compact fanout was not accepted through the real draw receipt");
                if(copyCapacityCase)need(observedCopy.present==1 && observedCopy.profile==resources.profile && observedCopy.laneCount==1
                    && !observedCopy.failedLane && !observedCopy.appliedLanes && observedCopy.entryViews==compactAtDraw.status.views
                    && observedCopy.afterClearViews==compactAtDraw.status.views
                    && !std::memcmp(&observedCopy.storageFailure,&observedFrame.storageFailure,sizeof(observedCopy.storageFailure)),
                    "compact copy receipt lost exact profile/capacity topology");
                else need(!std::memcmp(&observedCopy,&emptyCopy,sizeof(emptyCopy)),"non-copy compact result invented copy topology");
            }else if(internedStorage){
                need(!std::memcmp(&observedFrame.storage,&internedAtDraw.storage,sizeof(observedFrame.storage))
                    && !std::memcmp(&observedFrame.storageFailure,&internedAtDraw.storageFailure,sizeof(observedFrame.storageFailure))
                    && !std::memcmp(&observedFrame.firstFailure,&internedAtDraw.firstFailure,sizeof(observedFrame.firstFailure)),"interned draw receipt changed exact storage/first failure");
                if(internedPressure)need(!observedFrame.intervalAccepted && FAILED(observedFrame.result),"interned pressure falsely accepted metadata");
                else need(observedFrame.intervalAccepted && observedFrame.result==S_OK && observedFrame.storage.locations==2000,"interned fanout absent from actual draw receipt");
                if(copyCapacityCase)need(observedCopy.present==1 && observedCopy.profile==resources.profile && observedCopy.laneCount==1
                    && !observedCopy.failedLane && !observedCopy.appliedLanes && observedCopy.entryViews==3248 && observedCopy.afterClearViews==3248
                    && !std::memcmp(&observedCopy.storageFailure,&observedFrame.storageFailure,sizeof(observedCopy.storageFailure)),"interned byte-capacity copy topology mismatch");
                else need(!std::memcmp(&observedCopy,&emptyCopy,sizeof(emptyCopy)),"non-copy interned result invented copy topology");
            }else need(!std::memcmp(&observedCopy,&emptyCopy,sizeof(emptyCopy)),"non-copy startup failure invented copy topology");
            if(descriptorScoped){const auto& o=resources.receipt.observation;const BeamRTBufferCandidate zero{};
                need(!o.cbvProbeBytes && o.cbvResult==S_FALSE && !std::memcmp(&o.cbv,&zero,sizeof(zero)),"descriptor startup reported an invented CBV candidate");}
            auto canonical=[](IUnknown* object){ComPtr<IUnknown> id;hr(object->QueryInterface(IID_PPV_ARGS(&id)));return reinterpret_cast<uint64_t>(id.Get());};
            for(unsigned i=0;i<6;++i)resources.inputIdentities[i]=canonical(textures[i].Get());resources.outputIdentity=canonical(target.Get());resources.bufferIdentity=canonical(constants.Get());}
        else need(FAILED(got) && !resources.receipt.bytes,"default-off/no-draw resource receipt invented");
    }
    if(mode!=L"no-draw" && mode!=L"thread-no-draw"){
        transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
        render.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);render.submit();D3D12_RANGE range{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&range,&mapped));report.pixelOK=std::abs(*reinterpret_cast<float*>(static_cast<uint8_t*>(mapped)+footprint.Offset)-23)<.00001f?1u:0u;readback->Unmap(0,&none);need(report.pixelOK,"automatic observer changed GPU output");
    }else hr(render.list->Close());
    if(mode!=L"observer-off"){hr(threadQuery(&report.diagnostics,sizeof(report.diagnostics)));need(beamrtBindingThreadDiagnosticsValid(report.diagnostics),"invalid fixture diagnostic ledger");
        if(mode==L"thread-rejections" || mode==L"thread-no-draw")need(report.diagnostics.threadRejected==1 && report.diagnostics.sampleCount==1
            && report.diagnostics.samples[0].method==10 && report.diagnostics.samples[0].resetThread==GetCurrentThreadId(),"fixture diagnostic attribution mismatch");
        hr(query(&report.status,sizeof(report.status)));need(report.status.targetReady==(mode==L"unsupported-root"?0u:1u),"target setup mismatch");hr(disable());report.disabled=1;}
    using Startup=BOOL(WINAPI*)(BeamRTStartupStatus*,DWORD);const auto status=reinterpret_cast<Startup>(GetProcAddress(module,"BeamRT_StartupQuery"));auto& s=report.startup;s.bytes=sizeof(s);s.magic=beamrtStartupFixtureMagic;s.processId=GetCurrentProcessId();s.queryOK=status && status(&s.status,sizeof(s.status));s.initialThread=s.status.attachThread==GetCurrentThreadId();s.cwdMatches=std::filesystem::current_path()==std::filesystem::path(args[8]).parent_path();
    const std::vector<std::wstring> expected={L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"};bool equal=true;for(size_t i=0;i<expected.size();++i)equal=equal && args[16+i]==expected[i];s.argsMatch=equal?1u:0u;
    if(resourceFixture){
        if(resourceMode==L"compact")compactHeap.Reset();
        if(resourceMode==L"interned")internedHeap.Reset();
        if(resources.enabled){hr(resourceDisable());resources.disabled=1;BeamRTResourceProfileDiagnostics after{};hr(resourceProfileDiagnostics(&after,sizeof(after)));
            resources.after=after.status;resources.storageAfter=after.storage;resources.storageFailureAfter=after.storageFailure;
            need(!resources.after.enabled && !resources.after.attachedSlots && resources.after.restoredSlots==10,"resource OFF slots not restored");
            need(beamrtResourceStorageEvidenceValid(after.storage,after.storageFailure,after.firstFailure,after.status,resources.profile),"resource OFF storage evidence invalid");
            if(compactStorage){need(!std::memcmp(&after.firstFailure,&compactAtDraw.firstFailure,sizeof(after.firstFailure))
                    && !std::memcmp(&after.storageFailure,&compactAtDraw.storageFailure,sizeof(after.storageFailure)),"resource OFF changed compact first failure");
                if(compactPressure)need(!std::memcmp(&after.storage,&compactAtDraw.storage,sizeof(after.storage)),"compact poisoned OFF changed retained occupancy");
                else need(after.status.healthy && after.status.liveHeaps==2 && after.status.liveResources==7
                    && after.storage.locations==7 && after.storage.payloads==7 && after.storage.usedBytes==1288,"compact healthy heap retirement/OFF did not restore GI baseline");}
            if(internedStorage){need(!std::memcmp(&after.firstFailure,&internedAtDraw.firstFailure,sizeof(after.firstFailure))
                    && !std::memcmp(&after.storageFailure,&internedAtDraw.storageFailure,sizeof(after.storageFailure)),"resource OFF changed interned first failure");
                if(internedPressure)need(!std::memcmp(&after.storage,&internedAtDraw.storage,sizeof(after.storage)),"interned poisoned OFF changed retained occupancy");
                else need(after.status.healthy && after.status.liveHeaps==2 && after.status.liveResources==7
                    && after.storage.locations==7 && after.storage.payloads==7 && after.storage.usedBytes==1730 && after.storage.heaps==2,
                    "interned healthy heap retirement/OFF did not restore GI baseline");}}
        if(resourceMode==L"objects"){BeamRTResourceDiagnostics after{};hr(resourceDiagnostics(&after,sizeof(after)));
            need(!std::memcmp(&after.firstFailure,&objectFailure,sizeof(objectFailure)),"resource OFF changed object capacity first failure");}
        if(resourceMode==L"descriptor-pressure"){BeamRTResourceDiagnostics after{};hr(resourceDiagnostics(&after,sizeof(after)));
            need(!std::memcmp(&after.firstFailure,&descriptorFailure,sizeof(descriptorFailure)),"resource OFF changed descriptor capacity first failure");}
        if(resources.enabled){BeamRTResourceCopyFailure after{};
            need(resourceCopy(&after,sizeof(after))==(copyCapacityCase?S_OK:S_FALSE)
                && !std::memcmp(&after,&observedCopy,sizeof(after)),"resource OFF changed published copy diagnostics");}
        if(resourceMode==L"output-write")device->CreateRenderTargetView(target.Get(),nullptr,output);
        if(report.pixelOK){
            render.begin();transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
            render.list->SetPipelineState(pso.Get());render.list->SetGraphicsRootSignature(root.Get());render.list->SetDescriptorHeaps(2,heaps);
            render.list->SetGraphicsRootConstantBufferView(0,constants->GetGPUVirtualAddress());render.list->SetGraphicsRootDescriptorTable(1,srv->GetGPUDescriptorHandleForHeapStart());render.list->SetGraphicsRootDescriptorTable(2,sampler->GetGPUDescriptorHandleForHeapStart());
            render.list->RSSetViewports(1,&viewport);render.list->RSSetScissorRects(1,&scissor);render.list->OMSetRenderTargets(1,&output,FALSE,nullptr);render.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);render.list->DrawInstanced(3,1,0,0);
            transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
            D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
            render.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);render.submit();D3D12_RANGE range{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&range,&mapped));
            resources.pixelAfterOff=std::abs(*reinterpret_cast<float*>(static_cast<uint8_t*>(mapped)+footprint.Offset)-23)<.00001f?1u:0u;readback->Unmap(0,&none);need(resources.pixelAfterOff,"resource OFF changed GPU pixel");
        }
        need(writeNew(args[8]+L".resource-report",&resources,sizeof(resources)),"resource fixture report write");
    }
    need(writeNew(args[8],&report,sizeof(report)),"fixture report write");const auto hold=_wtoi(args[12].c_str());if(hold>0 && hold<=20000)Sleep(hold);const DWORD code=0;need(writeNew(args[8]+L".done",&code,sizeof(code)),"fixture done write");return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 95;}}
