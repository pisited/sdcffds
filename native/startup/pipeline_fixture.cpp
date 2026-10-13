#include "pipeline_audit.h"
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <cstring>
using Microsoft::WRL::ComPtr;
extern "C" void** beamrtPipelineSDKSlot(void*,void*,unsigned);
using RootCall=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,UINT,const void*,SIZE_T,REFIID,void**);
static void need(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
static void checked(HRESULT result,int line){if(FAILED(result))throw std::runtime_error("native pipeline fixture API failed at line "+std::to_string(line)+" HRESULT="+std::to_string(result));}
#define check(value) checked((value),__LINE__)
static std::vector<uint8_t> file(const wchar_t* path){std::ifstream s(std::filesystem::path(path),std::ios::binary|std::ios::ate);
    need(bool(s),"fixture shader missing");const auto size=s.tellg();need(size>0 && size<=16*1024*1024,"fixture shader size");
    std::vector<uint8_t> data(static_cast<size_t>(size));s.seekg(0);s.read(reinterpret_cast<char*>(data.data()),size);need(bool(s),"fixture shader truncated");return data;}
#pragma warning(push)
#pragma warning(disable:4324) // Public stream ABI deliberately pads blocks to pointer alignment.
template<class T>struct alignas(void*) Block {D3D12_PIPELINE_STATE_SUBOBJECT_TYPE type;T value;};
#pragma warning(pop)
int wmain(int argc,wchar_t** argv){
    try{
        need(argc>=4 && argc<=7,"pipeline fixture <vs> <ps> <alternate-vs> [--warp] [--cached-game] [--conflict]");
        bool warp=false,cachedGame=false,conflict=false;for(int i=4;i<argc;++i){const std::wstring flag=argv[i];
            if(flag==L"--warp"){need(!warp,"duplicate warp flag");warp=true;}
            else if(flag==L"--cached-game"){need(!cachedGame,"duplicate cached-game flag");cachedGame=true;}
            else if(flag==L"--conflict"){need(!conflict,"duplicate conflict flag");conflict=true;}
            else need(false,"unknown fixture option");}
        auto vs=file(argv[1]),ps=file(argv[2]),alternate=file(argv[3]);need(cachedGame || vs!=alternate,"alternate fixture bytes identical");
        ComPtr<IDXGIFactory6> factory;check(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<IDXGIAdapter> adapter;
        if(warp)check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
        else for(UINT i=0;!adapter;++i){ComPtr<IDXGIAdapter1> candidate;check(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&candidate)));
            DXGI_ADAPTER_DESC1 desc{};check(candidate->GetDesc1(&desc));if(!(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)
                && SUCCEEDED(D3D12CreateDevice(candidate.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)))candidate.As(&adapter);}
        ComPtr<ID3D12Device> device;check(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));
        D3D12_DESCRIPTOR_RANGE range{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,3,0,0,0};D3D12_ROOT_PARAMETER parameters[2]{};
        parameters[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;parameters[0].DescriptorTable={1,&range};
        parameters[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;parameters[1].Constants={0,0,1};
        D3D12_ROOT_SIGNATURE_DESC rootDesc{2,parameters,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_NONE};ComPtr<ID3DBlob> blob,error;
        D3D12_STATIC_SAMPLER_DESC samplers[6]{};
        if(cachedGame){
            // FIXTURE-owned layout compatible with reflected cached v082
            // registers, NOT a root signature captured from BeamNG.
            range.NumDescriptors=6;parameters[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;parameters[1].Descriptor={0,0};
            for(UINT i=0;i<6;++i){auto& sampler=samplers[i];sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;
                sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
                sampler.MaxAnisotropy=1;sampler.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;
                sampler.MaxLOD=D3D12_FLOAT32_MAX;sampler.ShaderRegister=i;}
            rootDesc.NumStaticSamplers=6;rootDesc.pStaticSamplers=samplers;rootDesc.Flags=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        }
        check(D3D12SerializeRootSignature(&rootDesc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error));
        std::vector<uint8_t> rootBytes(static_cast<const uint8_t*>(blob->GetBufferPointer()),static_cast<const uint8_t*>(blob->GetBufferPointer())+blob->GetBufferSize());
        ComPtr<ID3D12RootSignature> oldRoot;check(device->CreateRootSignature(0,rootBytes.data(),rootBytes.size(),IID_PPV_ARGS(&oldRoot)));
        auto originalRoot=reinterpret_cast<RootCall>(*beamrtPipelineSDKSlot(device.Get(),nullptr,0));
        BeamRTPipelineAuditConfig cfg{sizeof(cfg),1,vs.data(),vs.size(),ps.data(),ps.size(),{0,0}};
        auto bad=cfg;bad.reserved[1]=1;need(FAILED(BeamRT_PipelineAuditStart(device.Get(),&bad)),"reserved audit configuration accepted");
        check(BeamRT_PipelineAuditStart(device.Get(),&cfg));need(FAILED(BeamRT_PipelineAuditStart(device.Get(),&cfg)),"audit restart accepted");
        // Configuration bytes are copied; do not depend on caller buffer lifetime.
        const auto vsCopy=vs;vs[0]^=1;
        D3D12_GRAPHICS_PIPELINE_STATE_DESC desc{};desc.pRootSignature=oldRoot.Get();desc.VS={vsCopy.data(),vsCopy.size()};desc.PS={ps.data(),ps.size()};
        desc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;desc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;desc.RasterizerState.DepthClipEnable=TRUE;
        desc.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;desc.SampleMask=UINT_MAX;
        desc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;desc.NumRenderTargets=1;desc.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;desc.SampleDesc.Count=1;
        const D3D12_INPUT_ELEMENT_DESC inputs[]={
            {"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0},
            {"TEXCOORD",0,DXGI_FORMAT_R32G32_FLOAT,0,12,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0},
            {"TEXCOORD",1,DXGI_FORMAT_R32G32B32_FLOAT,0,20,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0}};
        if(cachedGame)desc.InputLayout={inputs,3};
        ComPtr<ID3D12PipelineState> unknown;check(device->CreateGraphicsPipelineState(&desc,IID_PPV_ARGS(&unknown)));
        BeamRTPipelineAuditInfo info{};check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
        need(info.unknownRootMatches==1 && !info.creationMatchAvailable,"unobserved root promoted to a contract");
        ComPtr<ID3D12RootSignature> root;check(device->CreateRootSignature(0,rootBytes.data(),rootBytes.size(),IID_PPV_ARGS(&root)));
        std::vector<ComPtr<ID3D12RootSignature>> duplicates(16);
        for(auto& duplicate:duplicates)check(device->CreateRootSignature(0,rootBytes.data(),rootBytes.size(),IID_PPV_ARGS(&duplicate)));
        check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
        need(info.abi==beamrtPipelineAuditInfoABI && info.healthy && info.liveLayouts==1 && info.liveRootTags>=1,
            "identical layouts not shared or new audit ABI missing");
        duplicates.clear();
        // More than the old 32-object/50-call failure boundary, with the target
        // kept alive while 96 distinct layouts evict it from the weak cache.
        std::vector<ComPtr<ID3D12RootSignature>> pressure(96);
        for(UINT i=0;i<pressure.size();++i){
            if(cachedGame)parameters[1].Descriptor.RegisterSpace=i+1;else parameters[1].Constants.RegisterSpace=i+1;
            ComPtr<ID3DBlob> varied;check(D3D12SerializeRootSignature(&rootDesc,D3D_ROOT_SIGNATURE_VERSION_1,&varied,&error));
            check(device->CreateRootSignature(0,varied->GetBufferPointer(),varied->GetBufferSize(),IID_PPV_ARGS(&pressure[i])));
        }
        if(cachedGame)parameters[1].Descriptor.RegisterSpace=0;else parameters[1].Constants.RegisterSpace=0;
        check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
        need(info.rootsObserved>50 && info.healthy && !info.failureReason && info.cacheEvictions>0
            && info.cachedLayouts<=beamrtPipelineLayoutCacheLimit && info.liveLayouts>32
            && info.metadataBytes<=beamrtPipelineMetadataBudget,"ordinary root pressure invalidated audit or exceeded bounds");
        const auto busyBytes=info.metadataBytes;pressure.clear();check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
        need(info.liveLayouts==1 && info.liveRootTags==1 && info.metadataBytes<busyBytes,"audit retained ordinary root objects after native release");
        uint64_t expectedMatches=2;
        if(!cachedGame){
            // Valid 64-DWORD layouts with many unused descriptor ranges. Their
            // serialized sizes exercise the real 2 MiB budget, not a test-only
            // lower limit or invalid/trailing bytes appended to a root blob.
            D3D12_ROOT_PARAMETER bulkParams[64]{};bulkParams[0]=parameters[0];bulkParams[1]=parameters[1];
            D3D12_DESCRIPTOR_RANGE bulkRanges[62][40]{};
            for(UINT table=0;table<62;++table){auto& param=bulkParams[table+2];param.ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
                param.DescriptorTable={40,bulkRanges[table]};
                for(UINT rangeIndex=0;rangeIndex<40;++rangeIndex)bulkRanges[table][rangeIndex]={D3D12_DESCRIPTOR_RANGE_TYPE_SRV,1,100+rangeIndex,table+1,D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
            }
            D3D12_ROOT_SIGNATURE_DESC bulkDesc{64,bulkParams,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_NONE};
            std::vector<ComPtr<ID3D12RootSignature>> bulkRoots;ComPtr<ID3D12RootSignature> skipped;
            const auto before=info.budgetSkipped;
            for(UINT i=0;i<96 && !skipped;++i){bulkRanges[0][0].RegisterSpace=10000+i;
                ComPtr<ID3DBlob> bulk;check(D3D12SerializeRootSignature(&bulkDesc,D3D_ROOT_SIGNATURE_VERSION_1,&bulk,&error));
                need(bulk->GetBufferSize()>16384 && bulk->GetBufferSize()<=65536,"budget fixture blob not large/valid enough");
                ComPtr<ID3D12RootSignature> other;check(device->CreateRootSignature(0,bulk->GetBufferPointer(),bulk->GetBufferSize(),IID_PPV_ARGS(&other)));
                check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
                if(info.budgetSkipped>before)skipped=std::move(other);else bulkRoots.emplace_back(std::move(other));
            }
            need(skipped && info.healthy && !info.failureReason && info.peakMetadataBytes<=beamrtPipelineMetadataBudget,
                "metadata budget not reached conservatively");
            desc.pRootSignature=skipped.Get();ComPtr<ID3D12PipelineState> unclassified;
            check(device->CreateGraphicsPipelineState(&desc,IID_PPV_ARGS(&unclassified)));++expectedMatches;
            check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
            need(info.healthy && !info.creationMatchAvailable && info.unknownRootMatches==2,"budget-skipped layout falsely promoted to a match");
            bulkRoots.clear();check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
            need(info.liveLayouts==1 && info.liveRootTags==1 && info.metadataBytes<busyBytes,"budget records did not retire with native roots");
        }
        const auto retainedRootBytes=rootBytes;rootBytes[0]^=1;desc.pRootSignature=root.Get();
        ComPtr<ID3D12PipelineState> pipeline;check(device->CreateGraphicsPipelineState(&desc,IID_PPV_ARGS(&pipeline)));
        if(!cachedGame){desc.VS={alternate.data(),alternate.size()};ComPtr<ID3D12PipelineState> different;
            check(device->CreateGraphicsPipelineState(&desc,IID_PPV_ARGS(&different)));desc.VS={vsCopy.data(),vsCopy.size()};}
        check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));need(info.shaderMatches==expectedMatches && info.creationMatchAvailable,"different valid VS falsely matched");
        std::vector<uint8_t> received(65536);uint32_t actual=99;ID3D12RootSignature* returnedRoot=reinterpret_cast<ID3D12RootSignature*>(1);
        ID3D12PipelineState* returnedPipeline=reinterpret_cast<ID3D12PipelineState*>(1);
        need(FAILED(BeamRT_PipelineAuditReadMatch(received.data(),1,&actual,&returnedRoot,&returnedPipeline)) && !actual && !returnedRoot && !returnedPipeline,
            "short output did not clear all results");
        check(BeamRT_PipelineAuditReadMatch(received.data(),static_cast<uint32_t>(received.size()),&actual,&returnedRoot,&returnedPipeline));
        ComPtr<ID3D12RootSignature> seenRoot;seenRoot.Attach(returnedRoot);ComPtr<ID3D12PipelineState> seenPipeline;seenPipeline.Attach(returnedPipeline);
        need(actual==retainedRootBytes.size() && std::memcmp(received.data(),retainedRootBytes.data(),actual)==0 && seenRoot.Get()==root.Get()
            && seenPipeline.Get()==pipeline.Get(),"exact native root/pipeline ownership or copied bytes mismatch");
        ComPtr<ID3D12Device> owner;check(seenPipeline->GetDevice(IID_PPV_ARGS(&owner)));need(owner.Get()==device.Get(),"pipeline owner mismatch");
        ComPtr<ID3D12Device2> device2;device.As(&device2);
        if(device2){
            struct Stream {
                Block<ID3D12RootSignature*> root;Block<D3D12_SHADER_BYTECODE> vs,ps;Block<D3D12_RT_FORMAT_ARRAY> rts;
                Block<D3D12_RASTERIZER_DESC> raster;Block<D3D12_BLEND_DESC> blend;Block<DXGI_SAMPLE_DESC> sample;
                Block<D3D12_PRIMITIVE_TOPOLOGY_TYPE> topology;Block<D3D12_INPUT_LAYOUT_DESC> input;
            } stream{{D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE,root.Get()},
                {D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS,desc.VS},{D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS,desc.PS},
                {D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS,{{DXGI_FORMAT_R32G32B32A32_FLOAT},1}},
                {D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER,desc.RasterizerState},{D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND,desc.BlendState},
                {D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_DESC,desc.SampleDesc},{D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PRIMITIVE_TOPOLOGY,desc.PrimitiveTopologyType},
                {D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_INPUT_LAYOUT,desc.InputLayout}};
            D3D12_PIPELINE_STATE_STREAM_DESC sd{sizeof(stream),&stream};ComPtr<ID3D12PipelineState> streamed;
            check(device2->CreatePipelineState(&sd,IID_PPV_ARGS(&streamed)));
            check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));need(info.unsupportedStreams==1,"pipeline stream misclassified as a legacy match");
        }
        if(conflict){
            // Same-size raw data is NOT an owned interface. Never dereference
            // the foreign address or overwrite it with guessed metadata.
            const ULONG_PTR foreign=1;check(root->SetPrivateData(beamrtPipelineRootEvidenceGuid,sizeof(foreign),&foreign));
            ComPtr<ID3D12PipelineState> stillNative;check(device->CreateGraphicsPipelineState(&desc,IID_PPV_ARGS(&stillNative)));
            check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
            need(!info.healthy && !info.creationMatchAvailable
                && info.failureReason==static_cast<uint32_t>(BeamRTPipelineFailure::rootEvidenceConflict)
                && info.failureResult==E_INVALIDARG,"conflicting root tag not reported exactly");
            actual=99;returnedRoot=reinterpret_cast<ID3D12RootSignature*>(1);returnedPipeline=reinterpret_cast<ID3D12PipelineState*>(1);
            need(FAILED(BeamRT_PipelineAuditReadMatch(received.data(),static_cast<uint32_t>(received.size()),&actual,&returnedRoot,&returnedPipeline))
                && !actual && !returnedRoot && !returnedPipeline,"invalidated match still readable");
        }
        const auto firstReason=info.failureReason;const auto firstResult=info.failureResult;
        HRESULT wrongThread=S_OK;std::thread wrong([&]{wrongThread=BeamRT_PipelineAuditDisable();});wrong.join();
        need(wrongThread==HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED),"wrong-thread disable accepted");
        auto cachedRoot=reinterpret_cast<RootCall>(*beamrtPipelineSDKSlot(device.Get(),nullptr,0));
        rootBytes=retainedRootBytes;std::atomic<bool> running{true},entered{false},good{true};
        std::thread concurrent([&]{do {ComPtr<ID3D12RootSignature> other;
            if(FAILED(device->CreateRootSignature(0,rootBytes.data(),rootBytes.size(),IID_PPV_ARGS(&other))))good=false;entered=true;
        }while(running.load());});while(!entered.load())SwitchToThread();
        check(BeamRT_PipelineAuditDisable());running=false;concurrent.join();need(good,"concurrent native root creation changed");
        check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));const auto frozen=info.rootsObserved;
        need(!info.enabled && !info.attachedSlots && info.restoredSlots==(device2?3u:2u) && !info.creationMatchAvailable
            && !info.drawBindingsVerified && !info.cameraVerified && !info.gpuOrderingVerified && !info.lightingConsumed,"audit falsely certified GI or failed restoration");
        ComPtr<ID3D12RootSignature> late;check(cachedRoot(device.Get(),0,rootBytes.data(),rootBytes.size(),IID_PPV_ARGS(&late)));
        check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));need(info.rootsObserved==frozen
            && *beamrtPipelineSDKSlot(device.Get(),nullptr,0)==reinterpret_cast<void*>(originalRoot),"late callback invalid or counters changed after OFF");
        check(BeamRT_PipelineAuditDisable());need(FAILED(BeamRT_PipelineAuditStart(device.Get(),&cfg)),"resident session unexpectedly restarted");
        check(BeamRT_PipelineAuditQuery(&info,sizeof(info)));
        need(info.failureReason==firstReason && info.failureResult==firstResult,"first failure changed through OFF/late forwarding");
        std::cout<<"PASS: exact VS+PS creation audit, unknown-root rejection, retained root/pipeline ownership, stream marked unsupported, concurrent atomic OFF and prefetched late callback; "
            <<"96-layout pressure, deduplication and object-owned metadata retirement; "<<(cachedGame?"cached shader":"2 MiB budget refusal")
            <<(conflict?", exact conflict reason/cleared match":"")<<"; "<<(warp?"WARP":"hardware")<<". No draw/resource/GI verification or BeamNG launch.\n";return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';BeamRT_PipelineAuditDisable();return 1;}
}
