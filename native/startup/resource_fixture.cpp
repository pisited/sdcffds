#include "resource_tracker.h"
#include "resource_handoff.h"
#include "resource_copy_diagnostics.h"
#include "resource_copy_validation.h"
#include "resource_profile.h"
#include "resource_storage_validation.h"
#include "gi_bindings.h"
#include "pipeline_audit.h"
#include "gi_root_layout.h"
#include <dxgi1_6.h>
#include <d3d12sdklayers.h>
#include <iostream>
#include <thread>
#include <array>
#include <atomic>
#include <utility>
#include "binding_test_support.h"
extern "C" void** beamrtResourceSDKSlot(void*,unsigned);
using FixtureSRV=void(STDMETHODCALLTYPE*)(ID3D12Device*,ID3D12Resource*,const D3D12_SHADER_RESOURCE_VIEW_DESC*,D3D12_CPU_DESCRIPTOR_HANDLE);
// Fixture-only original: the real device still performs both descriptor writes.
// Its bounded gate makes tracker callback overlap deterministic without relying
// on scheduling, invalid native arguments or concurrent writes to one slot.
struct SRVGate {
    inline static SRVGate* active=nullptr;
    void** address=nullptr;FixtureSRV native=nullptr;HANDLE entered=nullptr,release=nullptr;
    std::atomic<bool> armed{false},waited{false};std::atomic<DWORD> nativeError{0};
    std::thread worker;DWORD returnedError=0;
    static void STDMETHODCALLTYPE forward(ID3D12Device* d,ID3D12Resource* r,const D3D12_SHADER_RESOURCE_VIEW_DESC* v,D3D12_CPU_DESCRIPTOR_HANDLE dst){
        const auto incoming=GetLastError();auto& gate=*active;const bool blocked=gate.armed.exchange(false);
        if(blocked){SetEvent(gate.entered);gate.waited.store(WaitForSingleObject(gate.release,10000)==WAIT_OBJECT_0);}
        SetLastError(incoming);gate.native(d,r,v,dst);const auto result=GetLastError();
        if(blocked)gate.nativeError.store(result);SetLastError(result);
    }
    static bool exchange(void** slot,void* before,void* after){
        DWORD old=0;if(!VirtualProtect(slot,sizeof(void*),PAGE_READWRITE,&old))return false;
        const bool changed=InterlockedCompareExchangePointer(slot,after,before)==before;DWORD unused=0;
        const bool restored=VirtualProtect(slot,sizeof(void*),old,&unused)!=FALSE;return changed && restored;
    }
    explicit SRVGate(ID3D12Device* device){
        entered=CreateEventW(nullptr,TRUE,FALSE,nullptr);release=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        need(entered && release,"fixture overlap events unavailable");address=beamrtResourceSDKSlot(device,1);native=reinterpret_cast<FixtureSRV>(*address);active=this;
        need(exchange(address,reinterpret_cast<void*>(native),reinterpret_cast<void*>(forward)),"fixture native SRV shim install failed");
    }
    void join()noexcept{if(worker.joinable()){SetEvent(release);worker.join();}}
    void begin(ID3D12Device* device,ID3D12Resource* resource,const D3D12_SHADER_RESOURCE_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE destination){
        need(!worker.joinable(),"fixture overlap worker already pending");ResetEvent(entered);ResetEvent(release);waited.store(false);armed.store(true);
        worker=std::thread([=]{SetLastError(0x6b6f0001);device->CreateShaderResourceView(resource,desc,destination);returnedError=GetLastError();});
        const bool reached=WaitForSingleObject(entered,10000)==WAIT_OBJECT_0;if(!reached)join();
        need(reached,"fixture overlap worker did not enter native shim");
    }
    void finish(){join();need(waited.load() && returnedError==nativeError.load(),"overlap gate timed out or native LastError changed");}
    void restore(){join();need(exchange(address,reinterpret_cast<void*>(forward),reinterpret_cast<void*>(native)),"fixture native SRV shim restoration failed");}
    ~SRVGate(){join();if(address && *address==reinterpret_cast<void*>(forward))exchange(address,reinterpret_cast<void*>(forward),reinterpret_cast<void*>(native));
        active=nullptr;if(entered)CloseHandle(entered);if(release)CloseHandle(release);}
};
static uint64_t identity(IUnknown* object){ComPtr<IUnknown> id;hr(object->QueryInterface(IID_PPV_ARGS(&id)));return reinterpret_cast<uint64_t>(id.Get());}
static void missing(D3D12_CPU_DESCRIPTOR_HANDLE handle,D3D12_DESCRIPTOR_HEAP_TYPE type){
    BeamRTResourceView value;std::memset(&value,0xa5,sizeof(value));const auto result=BeamRT_ResourcesDescriptor(handle,type,&value,sizeof(value));
    BeamRTResourceView zero{};need(FAILED(result) && !std::memcmp(&value,&zero,sizeof(value)),"refused descriptor output not cleared");
}
static BeamRTResourceView view(D3D12_CPU_DESCRIPTOR_HANDLE handle,D3D12_DESCRIPTOR_HEAP_TYPE type){
    BeamRTResourceView value{};hr(BeamRT_ResourcesDescriptor(handle,type,&value,sizeof(value)));need(value.bytes==sizeof(value) && value.abi==1,"view ABI mismatch");return value;
}
// Explicit isolated storage-profile paths. The legacy 256-location fixture
// below and all four compact scenarios retain their original selections.
static int profiledFixture(ID3D12Device* device,const std::vector<uint8_t>& vs,const std::vector<uint8_t>& ps,
    const std::vector<uint8_t>& bytes,const BeamRTGIRootLayout& layout,unsigned pressureKind,bool debugEnabled,uint32_t profile){
    const bool interned=profile==beamrtResourceStorageInterned;unsigned groups=0;
    const auto prefix=interned?"interned":"compact";
    const auto expectedBytes=[&](uint32_t locations,uint32_t payloads){return beamrtResourceDirectoryBytes(profile)+locations*beamrtResourceLocationBytes(profile)+payloads*160;};
    auto pass=[&](const char* label){++groups;std::cout<<"PASS "<<prefix<<' '<<label<<'\n';};
    BeamRTResourceProfileDiagnostics cold;std::memset(&cold,0xa5,sizeof(cold));const BeamRTResourceProfileDiagnostics zero{};
    need(BeamRT_ResourcesDiagnosticsProfiled(&cold,sizeof(cold))==HRESULT_FROM_WIN32(ERROR_NOT_READY)
        && !std::memcmp(&cold,&zero,sizeof(cold)),"compact cold diagnostics did not clear output");
    const BeamRTResourceProfileConfig selected{sizeof(selected),interned?beamrtResourceInternedConfigABI:beamrtResourceProfileConfigABI,beamrtResourceDescriptorTextures,profile,{0,0}};
    const auto start=[&](const BeamRTResourceProfileConfig* config){return interned?BeamRT_ResourcesStartInterned(device,config):BeamRT_ResourcesStartProfiled(device,config);};
    need(start(nullptr)==E_INVALIDARG,"profile null configuration accepted");
    for(unsigned field=0;field<7;++field){auto invalid=selected;
        if(field==0)--invalid.bytes;if(field==1)++invalid.bytes;if(field==2)invalid.abi=1;if(field==3)invalid.mode=2;
        if(field==4)invalid.profile=interned?beamrtResourceStorageCompact:beamrtResourceStorageInterned;if(field==5)invalid.reserved[0]=1;if(field==6)invalid.reserved[1]=1;
        need(start(&invalid)==E_INVALIDARG,"malformed storage profile configuration accepted");
    }
    if(interned){auto old=selected;old.abi=beamrtResourceProfileConfigABI;
        need(BeamRT_ResourcesStartProfiled(device,&old)==E_INVALIDARG && start(&old)==E_INVALIDARG
            && BeamRT_ResourcesStartProfiled(device,&selected)==E_INVALIDARG,"interned profile accepted by old configuration API or ABI");}
    const BeamRTResourceConfig wrongLegacy{sizeof(wrongLegacy),2,beamrtResourceDescriptorTextures,0};
    need(BeamRT_ResourcesStartConfigured(device,&wrongLegacy)==E_INVALIDARG,"profile ABI accepted through legacy configuration");
    void* originals[10]{};for(unsigned i=0;i<10;++i)originals[i]=*beamrtResourceSDKSlot(device,i);
    hr(start(&selected));need(FAILED(BeamRT_ResourcesStart(device)),"profile session restarted through legacy start");
    BeamRTResourceProfileDiagnostics current{};
    const auto diagnostics=[&]{BeamRTResourceProfileDiagnostics value{};hr(BeamRT_ResourcesDiagnosticsProfiled(&value,sizeof(value)));
        need(value.status.abi==beamrtResourceStatusABI(profile) && value.firstFailure.abi==beamrtResourceStatusABI(profile)
            && beamrtResourceStorageEvidenceValid(value.storage,value.storageFailure,value.firstFailure,value.status,profile),"compact paired diagnostics invalid");return value;};
    const auto printStorage=[&](const char* stage,const BeamRTResourceProfileDiagnostics& value){const auto& s=value.storage;
        std::cout<<prefix<<" storage "<<stage<<": L="<<s.locations<<", P="<<s.payloads<<", H="<<s.heaps<<", bytes="<<s.usedBytes
            <<", directory="<<s.directoryBytes<<", locationBytes="<<s.locationBytes<<", failure="<<value.firstFailure.kind<<'\n';};
    current=diagnostics();need(!current.status.views && !current.storage.payloads && !current.storage.heaps
        && current.storage.usedBytes==beamrtResourceDirectoryBytes(profile),"profile start invented descriptor storage or omitted fixed directory bytes");
    BeamRTResourceProfileDiagnostics sentinel;std::memset(&sentinel,0xa5,sizeof(sentinel));const auto preserved=sentinel;
    need(BeamRT_ResourcesDiagnosticsProfiled(nullptr,sizeof(sentinel))==E_INVALIDARG,"compact null diagnostics accepted");
    for(const auto size:std::array<uint32_t,3>{0,static_cast<uint32_t>(sizeof(sentinel)-1),static_cast<uint32_t>(sizeof(sentinel)+1)})
        need(BeamRT_ResourcesDiagnosticsProfiled(&sentinel,size)==E_INVALIDARG && !std::memcmp(&sentinel,&preserved,sizeof(sentinel)),"compact wrong-sized diagnostics modified output");
    need(!beamrtResourceFailureValid(current.firstFailure,current.status)
        && !beamrtResourceStorageEvidenceValid(current.storage,current.storageFailure,current.firstFailure,current.status,beamrtResourceStorageLegacy),
        "legacy validators accepted compact ABI2 at empty population");
    if(interned)need(!beamrtResourceFailureValid(current.firstFailure,current.status,beamrtResourceStorageCompact)
        && !beamrtResourceStorageEvidenceValid(current.storage,current.storageFailure,current.firstFailure,current.status,beamrtResourceStorageCompact),
        "compact validators accepted interned ABI3 at empty population");
    pass("explicit configuration, cold/wrong-size guards and legacy ABI refusal");
    BeamRTPipelineAuditConfig audit{sizeof(audit),1,vs.data(),vs.size(),ps.data(),ps.size(),{0,0}};
    hr(BeamRT_PipelineAuditStart(device,&audit));hr(BeamRT_BindingsStart(device));
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,bytes.data(),bytes.size(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipelineDesc{};pipelineDesc.pRootSignature=root.Get();pipelineDesc.VS={vs.data(),vs.size()};pipelineDesc.PS={ps.data(),ps.size()};
    pipelineDesc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pipelineDesc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pipelineDesc.RasterizerState.DepthClipEnable=TRUE;
    pipelineDesc.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;pipelineDesc.SampleMask=UINT_MAX;
    pipelineDesc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;pipelineDesc.NumRenderTargets=1;
    pipelineDesc.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;pipelineDesc.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&pipelineDesc,IID_PPV_ARGS(&pipeline)));hr(BeamRT_BindingsTargetFromAudit());
    Renderer render(device);render.begin();std::vector<ComPtr<ID3D12Resource>> textures;
    for(unsigned i=1;i<=6;++i)textures.push_back(render.texture(static_cast<float>(i)));render.submit();
    auto constants=resource(device,buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* mapped=nullptr;D3D12_RANGE none{0,0};
    hr(constants->Map(0,&none,&mapped));const float bias[]={2,2,2,2};std::memcpy(mapped,bias,sizeof(bias));constants->Unmap(0,nullptr);
    const auto heap=[&](D3D12_DESCRIPTOR_HEAP_TYPE type,UINT count,bool visible){D3D12_DESCRIPTOR_HEAP_DESC d{type,count,visible?D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE:D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
        ComPtr<ID3D12DescriptorHeap> result;hr(device->CreateDescriptorHeap(&d,IID_PPV_ARGS(&result)));return result;};
    auto storage=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,interned?4100u:1100u,false),gpu=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,6,true);
    auto samplers=heap(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,6,true),rtv=heap(D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,false);
    const auto slot=[&](ID3D12DescriptorHeap* h,UINT index){auto result=h->GetCPUDescriptorHandleForHeapStart();
        result.ptr+=uint64_t(index)*device->GetDescriptorHandleIncrementSize(h->GetDesc().Type);return result;};
    D3D12_SHADER_RESOURCE_VIEW_DESC desc{};desc.Format=pipelineDesc.RTVFormats[0];desc.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
    desc.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;desc.Texture2D.MipLevels=1;
    D3D12_SAMPLER_DESC filter{};filter.Filter=D3D12_FILTER_MIN_MAG_MIP_POINT;filter.AddressU=filter.AddressV=filter.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    filter.MaxLOD=D3D12_FLOAT32_MAX;filter.MaxAnisotropy=1;filter.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    for(UINT i=0;i<6;++i){device->CreateShaderResourceView(textures[i].Get(),&desc,slot(storage.Get(),i));device->CreateSampler(&filter,slot(samplers.Get(),i));}
    D3D12_RESOURCE_DESC td{};td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;td.Width=td.Height=1;td.DepthOrArraySize=td.MipLevels=1;
    td.SampleDesc.Count=1;td.Format=desc.Format;td.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=resource(device,td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);device->CreateRenderTargetView(target.Get(),nullptr,slot(rtv.Get(),0));
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows=0;UINT64 row=0,total=0;device->GetCopyableFootprints(&td,0,1,0,&footprint,&rows,&row,&total);
    auto readback=resource(device,buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    BeamRTBufferCandidate candidate;std::memset(&candidate,0xa5,sizeof(candidate));const BeamRTBufferCandidate emptyCandidate{};
    need(BeamRT_ResourcesBufferCandidate(constants->GetGPUVirtualAddress(),16,&candidate,sizeof(candidate))==HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)
        && !std::memcmp(&candidate,&emptyCandidate,sizeof(candidate)),"compact profile invented CBV inference");
    current=diagnostics();need(current.status.liveResources==7 && current.storage.locations==7 && current.storage.payloads==7
        && current.storage.usedBytes==expectedBytes(7,7) && current.storage.heaps==(interned?2u:0u),"profile seven-input/output baseline invalid");
    need(!beamrtResourceFailureValid(current.firstFailure,current.status),"legacy validator accepted compact below 256 views");
    for(unsigned field=0;field<16;++field){auto invalid=current.storage;
        if(field==0)--invalid.bytes;if(field==1)invalid.abi=1;if(field==2)invalid.profile=0;if(field==3)++invalid.locationLimit;
        if(field==4)++invalid.payloadLimit;if(field==5)++invalid.byteLimit;if(field==6)invalid.locations=beamrtResourceLocationLimit(profile)+1;if(field==7)invalid.payloads=257;
        if(field==8)++invalid.usedBytes;if(field==9)invalid.reserved[0]=1;if(field==10)invalid.reserved[1]=1;if(field==11)invalid.reserved[2]=1;
        if(field==12)invalid.directoryBytes=interned?0u:512u;if(field==13)++invalid.locationBytes;
        if(field==14)invalid.heaps=interned?0u:1u;if(field==15)++invalid.heapLimit;
        need(!beamrtResourceStorageSnapshotValid(invalid,profile),"malformed compact storage snapshot accepted");
    }
    pass("exact seven admissions, shared budget math and malformed snapshot refusal");
    const auto fillGpu=[&]{device->CopyDescriptorsSimple(6,slot(gpu.Get(),0),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);};
    const auto draw=[&](bool healthy){
        BeamRTResourceCheckpoint checkpoint{};const auto checkpointResult=BeamRT_ResourcesCheckpoint(&checkpoint,sizeof(checkpoint));
        need(healthy?SUCCEEDED(checkpointResult):FAILED(checkpointResult),"compact checkpoint health mismatch");
        render.begin();render.list->SetPipelineState(pipeline.Get());render.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={gpu.Get(),samplers.Get()};render.list->SetDescriptorHeaps(2,heaps);
        render.list->SetGraphicsRootConstantBufferView(layout.cbv,constants->GetGPUVirtualAddress());render.list->SetGraphicsRootDescriptorTable(layout.srv,gpu->GetGPUDescriptorHandleForHeapStart());
        render.list->SetGraphicsRootDescriptorTable(layout.sampler,samplers->GetGPUDescriptorHandleForHeapStart());D3D12_VIEWPORT viewport{0,0,1,1,0,1};D3D12_RECT scissor{0,0,1,1};
        render.list->RSSetViewports(1,&viewport);render.list->RSSetScissorRects(1,&scissor);auto output=slot(rtv.Get(),0);render.list->OMSetRenderTargets(1,&output,FALSE,nullptr);render.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        BeamRTResourceDrawToken token{};const auto begun=BeamRT_ResourcesBeginDraw(&token,sizeof(token));need(healthy?SUCCEEDED(begun):FAILED(begun),"compact draw interval health mismatch");
        render.list->DrawInstanced(3,1,0,0);BeamRTBindingSnapshot binding{};hr(BeamRT_BindingsRead(&binding,sizeof(binding)));BeamRTResourceDrawObservation observation{};
        const auto finished=BeamRT_ResourcesFinishDraw(&token,sizeof(token),&checkpoint,sizeof(checkpoint),&binding,sizeof(binding),0,&observation,sizeof(observation));
        need((healthy?SUCCEEDED(finished):FAILED(finished)) && beamrtResourceObservationValid(observation,binding,GetCurrentThreadId(),profile)
            && bool(observation.intervalAccepted)==healthy,"compact actual-draw observation invalid");
        need(!beamrtResourceObservationValid(observation,binding,GetCurrentThreadId()),"legacy draw validator accepted compact profile");
        need(observation.storage.profile==profile && observation.status.abi==beamrtResourceStatusABI(profile) && !observation.cbvProbeBytes && observation.cbvResult==S_FALSE
            && !std::memcmp(&observation.cbv,&emptyCandidate,sizeof(emptyCandidate)),"compact draw lost profile or invented CBV contents");
        if(healthy){for(unsigned i=0;i<6;++i)need(observation.srvResults[i]==S_OK && observation.srvs[i].canonicalIdentity==identity(textures[i].Get()),"compact actual SRV identity mismatch");
            need(observation.rtvResults[0]==S_OK && observation.rtvs[0].canonicalIdentity==identity(target.Get()),"compact actual output identity mismatch");}
        transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);D3D12_TEXTURE_COPY_LOCATION src{},dst{};
        src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
        render.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);render.submit();
        D3D12_RANGE range{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&range,&mapped));const auto pixel=*reinterpret_cast<float*>(static_cast<uint8_t*>(mapped)+footprint.Offset);readback->Unmap(0,&none);
        need(std::abs(pixel-23)<.00001f,"compact profile changed real GPU pixel 23");return observation;
    };
    fillGpu();draw(true);pass("healthy profile-aware real draw and native GPU pixel 23");
    if(pressureKind){for(unsigned i=0;i<6;++i)device->CreateShaderResourceView(nullptr,&desc,slot(gpu.Get(),i));current=diagnostics();
        need(current.storage.locations==7 && current.storage.payloads==7,"compact pressure baseline retained GPU-copy locations");}
    unsigned next=6;
    if(!pressureKind){const auto fanout=interned?2000u:400u;for(unsigned i=0;i<fanout;++i)device->CopyDescriptorsSimple(1,slot(storage.Get(),next++),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        current=diagnostics();need(current.status.healthy && current.storage.locations==fanout+13 && current.storage.payloads==7 && current.storage.locations>256
            && current.storage.usedBytes==expectedBytes(fanout+13,7) && current.storage.heaps==(interned?3u:0u),
            "compact fanout did not retain more than legacy 256 locations");
        const auto observation=draw(true);need(observation.storage.locations==fanout+13 && observation.storage.usedBytes==expectedBytes(fanout+13,7),"profile fanout disappeared before the actual draw");
        printStorage("healthy draw",current);
        pass(interned?"2013 fanout locations / 7 payloads / 3 heaps / 29814 bytes persist through the real GPU draw":"413 fanout locations persist through the real GPU draw");
    }else{
        const bool locations=pressureKind==1;
        const bool sharedBytePressure=interned && pressureKind==3;
        while((current=diagnostics(),locations?current.storage.locations<1024:sharedBytePressure?current.storage.locations<3248:current.storage.payloads<256)){
            auto variation=desc;if(!locations && !sharedBytePressure)variation.Texture2D.ResourceMinLODClamp=static_cast<float>(current.storage.payloads)/1024.0f;
            // Alternate LOD descriptions are legal metadata-only views. They
            // are never copied into the GPU-visible six-input descriptor table.
            device->CreateShaderResourceView(textures[0].Get(),&variation,slot(storage.Get(),next++));
            const auto after=diagnostics();need(after.status.healthy && !after.firstFailure.kind && !after.status.pressure,"compact storage failed before exact capacity");
        }
        current=diagnostics();const auto beforeFailure=current;
        need(locations?(current.storage.locations==1024 && current.storage.payloads==7):sharedBytePressure?
            (current.storage.locations==3248 && current.storage.payloads==7 && current.storage.usedBytes==47104):
            (current.storage.locations==256 && current.storage.payloads==256 && current.storage.usedBytes==expectedBytes(256,256)),
            "compact exact capacity baseline mismatch");
        auto overflow=desc;if(pressureKind==2)overflow.Texture2D.ResourceMinLODClamp=static_cast<float>(current.storage.payloads)/1024.0f;
        device->CreateShaderResourceView(textures[0].Get(),&overflow,slot(storage.Get(),next));current=diagnostics();
        const uint32_t kinds[]={0,BeamRTResourceFailureViewCapacity,BeamRTResourceFailureViewPayloadCapacity,BeamRTResourceFailureViewByteCapacity};
        const uint32_t causes[]={0,beamrtResourceStorageFailureLocations,beamrtResourceStorageFailurePayloads,beamrtResourceStorageFailureBytes};
        const uint32_t limits[]={0,1024,256,47104},attempts[]={0,1025,257,interned?47118u:47128u};
        need(!current.status.healthy && current.status.pressure==1 && current.firstFailure.kind==kinds[pressureKind]
            && current.firstFailure.method==BeamRTResourceMethodCreateSRV && current.firstFailure.capacityLimit==limits[pressureKind]
            && current.firstFailure.attemptedCount==attempts[pressureKind] && current.storageFailure.present==1 && current.storageFailure.cause==causes[pressureKind]
            && !std::memcmp(&current.storage,&beforeFailure.storage,sizeof(current.storage)),"compact capacity first cause or occupancy was not exact");
        if(pressureKind==3)need(current.storageFailure.requiredBytes==attempts[3] && current.storageFailure.atFailure.usedBytes==47104,"profile byte pressure original demand invalid");
        if(interned)need(current.storageFailure.atFailure.heaps==2 && current.storageFailure.attemptedHeaps==2
            && current.storageFailure.requiredBytes==(pressureKind==2?45230u:47118u),"interned original heap count or required byte units invalid");
        printStorage("first capacity refusal",current);std::cout<<prefix<<" demand: L="<<current.storageFailure.attemptedLocations
            <<", P="<<current.storageFailure.attemptedPayloads<<", H="<<current.storageFailure.attemptedHeaps<<", bytes="<<current.storageFailure.requiredBytes<<'\n';
        for(unsigned field=0;field<13;++field){auto invalid=current.storageFailure;
            if(field==0)--invalid.bytes;if(field==1)invalid.abi=1;if(field==2)invalid.present=0;if(field==3)invalid.cause=99;
            if(field==4)++invalid.atFailure.locations;if(field==5)++invalid.atFailure.usedBytes;if(field==6)++invalid.attemptedLocations;
            if(field==7)invalid.attemptedPayloads+=2;if(field==8)++invalid.requiredBytes;if(field==9)invalid.reserved=1;if(field==10)invalid.atFailure.profile=0;
            if(field==11)invalid.attemptedHeaps+=2;if(field==12)invalid.reserved2=1;
            need(!beamrtResourceStorageEvidenceValid(current.storage,invalid,current.firstFailure,current.status,profile),"malformed compact storage failure accepted");
        }
        fillGpu();const auto refused=draw(false);need(!std::memcmp(&refused.firstFailure,&current.firstFailure,sizeof(current.firstFailure))
            && !std::memcmp(&refused.storageFailure,&current.storageFailure,sizeof(current.storageFailure)),"compact refused draw lost immutable storage first cause");
        pass("exact location/payload/byte capacity, malformed failure refusals and unchanged GPU output");
    }
    current=diagnostics();const auto first=current.firstFailure;const auto storageFailure=current.storageFailure;
    storage.Reset();current=diagnostics();need(current.storage.locations==(pressureKind?1u:7u) && current.storage.payloads==(pressureKind?1u:7u)
        && current.storage.heaps==(interned?(pressureKind?1u:2u):0u) && current.storage.usedBytes==expectedBytes(pressureKind?1u:7u,pressureKind?1u:7u)
        && !std::memcmp(&current.firstFailure,&first,sizeof(first)) && !std::memcmp(&current.storageFailure,&storageFailure,sizeof(storageFailure)),"compact dead-heap reaping changed immutable cause or kept dead locations");
    printStorage("dead heap reaped",current);
    if(pressureKind){for(unsigned field=0;field<4;++field){auto invalid=current.storage;
        if(field==0)invalid.locations=storageFailure.atFailure.locations+1;if(field==1)invalid.payloads=storageFailure.atFailure.payloads+1;
        if(field==2)invalid.heaps=storageFailure.atFailure.heaps+1;if(field==3)invalid.usedBytes=storageFailure.atFailure.usedBytes+1;
        need(!beamrtResourceStorageEvidenceValid(invalid,storageFailure,first,current.status,profile),"post-failure storage growth accepted");}}
    if(pressureKind){need(!current.status.healthy,"compact dead-heap reaping recovered health");missing(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        device->CreateShaderResourceView(textures[0].Get(),&desc,slot(gpu.Get(),0));const auto later=diagnostics();
        need(!later.status.healthy && later.storage.locations==1 && !std::memcmp(&later.firstFailure,&first,sizeof(first)),"compact native write recovered failed metadata");}
    else need(view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).canonicalIdentity==identity(textures[0].Get()),"compact reaping changed independent GPU-copy lifetime");
    draw(!pressureKind);pass("dead-heap reaping preserves lifetime, first cause and no-recovery semantics");
    const auto cached=reinterpret_cast<FixtureSRV>(*beamrtResourceSDKSlot(device,1));hr(BeamRT_ResourcesDisable());current=diagnostics();
    need(!current.status.enabled && !current.status.attachedSlots && current.status.restoredSlots==10,"compact OFF did not restore all ten native slots");
    for(unsigned i=0;i<10;++i)need(*beamrtResourceSDKSlot(device,i)==originals[i],"compact OFF changed a native slot");
    const auto callbacks=current.status.callbacks;cached(device,textures[0].Get(),&desc,slot(gpu.Get(),0));const auto afterOff=diagnostics();
    need(afterOff.status.callbacks==callbacks && !std::memcmp(&afterOff.firstFailure,&first,sizeof(first))
        && !std::memcmp(&afterOff.storageFailure,&storageFailure,sizeof(storageFailure)),"compact late cached callback or OFF changed diagnostics");
    // The binding observer remains active for one final native GPU check. Its
    // failed resource interval is diagnostic only, not disabled GPU execution.
    draw(false);hr(BeamRT_BindingsDisable());hr(BeamRT_PipelineAuditDisable());
    need(FAILED(start(&selected)),"profile OFF session restarted");pass("OFF10, late native forward and post-OFF GPU pixel 23");
    std::cout<<(interned?"Interned":"Compact")<<" resource fixture PASS "<<groups<<'/'<<groups<<"; variant="<<pressureKind<<"; arena=47104, locations="<<beamrtResourceLocationLimit(profile)<<", payloads=256; debug-layer="
        <<(debugEnabled?"enabled":"unavailable")<<"; offline only, no game proof\n";return 0;
}
int wmain(int argc,wchar_t** argv){try{
    need(argc>=4 && argc<=8,"resource_fixture <vs> <ps> <fixture-root> [--warp] [--descriptor-mode] [--compact-storage|--interned-storage] [--compact-location-pressure|--compact-payload-pressure|--compact-byte-pressure|--interned-payload-pressure|--interned-byte-pressure|--resource-pressure|--view-pressure|--draw-pressure|--overlap-first|--copy-pressure|--copy-prefix-pressure|--copy-boundary-pressure|--copy-simple-pressure|--copy-explicit-pressure]");
    bool warp=false,descriptorMode=false,compactStorage=false,internedStorage=false;unsigned pressureKind=0,compactPressure=0,internedPressure=0;
    for(int i=4;i<argc;++i){const std::wstring arg=argv[i];
        if(arg==L"--warp"){need(!warp,"duplicate WARP flag");warp=true;}
        else if(arg==L"--descriptor-mode"){need(!descriptorMode,"duplicate descriptor-mode flag");descriptorMode=true;}
        else if(arg==L"--compact-storage"){need(!compactStorage,"duplicate compact-storage flag");compactStorage=true;}
        else if(arg==L"--interned-storage"){need(!internedStorage,"duplicate interned-storage flag");internedStorage=true;}
        else if(arg==L"--compact-location-pressure"){need(!compactPressure,"duplicate compact pressure flag");compactPressure=1;}
        else if(arg==L"--compact-payload-pressure"){need(!compactPressure,"duplicate compact pressure flag");compactPressure=2;}
        else if(arg==L"--compact-byte-pressure"){need(!compactPressure,"duplicate compact pressure flag");compactPressure=3;}
        else if(arg==L"--interned-payload-pressure"){need(!internedPressure,"duplicate interned pressure flag");internedPressure=2;}
        else if(arg==L"--interned-byte-pressure"){need(!internedPressure,"duplicate interned pressure flag");internedPressure=3;}
        else if(arg==L"--resource-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=1;}
        else if(arg==L"--view-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=2;}
        else if(arg==L"--draw-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=3;}
        else if(arg==L"--overlap-first"){need(!pressureKind,"duplicate pressure flag");pressureKind=4;}
        else if(arg==L"--copy-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=5;}
        else if(arg==L"--copy-prefix-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=6;}
        else if(arg==L"--copy-boundary-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=7;}
        else if(arg==L"--copy-simple-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=8;}
        else if(arg==L"--copy-explicit-pressure"){need(!pressureKind,"duplicate pressure flag");pressureKind=9;}
        else need(false,"unknown resource fixture flag");
    }
    need(!compactStorage || (descriptorMode && !pressureKind),"compact-storage requires descriptor mode and its isolated pressure scenarios");
    need(!compactPressure || compactStorage,"compact pressure requires explicit compact-storage selection");
    need(!(compactStorage && internedStorage),"compact-storage and interned-storage are mutually exclusive");
    need(!internedStorage || (descriptorMode && !pressureKind && !compactPressure),"interned-storage requires descriptor mode and its isolated pressure scenarios");
    need(!internedPressure || internedStorage,"interned pressure requires explicit interned-storage selection");
    unsigned groups=0;auto pass=[&](const char* label){++groups;std::cout<<"PASS "<<label<<'\n';};
    missing({1},D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    BeamRTResourceCopyFailure copyFailure{};std::memset(&copyFailure,0xa5,sizeof(copyFailure));const BeamRTResourceCopyFailure zeroCopy{};
    need(BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure))==HRESULT_FROM_WIN32(ERROR_NOT_READY)
        && !std::memcmp(&copyFailure,&zeroCopy,sizeof(copyFailure)),"cold copy failure query did not clear output");
    BeamRTResourceCopyFailure copySentinel;std::memset(&copySentinel,0xa5,sizeof(copySentinel));const auto copyPreserved=copySentinel;
    need(BeamRT_ResourcesCopyFailure(nullptr,sizeof(copyFailure))==E_INVALIDARG,"null copy failure output accepted");
    for(const auto badSize:std::array<uint32_t,3>{0,static_cast<uint32_t>(sizeof(copyFailure)-1),static_cast<uint32_t>(sizeof(copyFailure)+1)})
        need(BeamRT_ResourcesCopyFailure(&copySentinel,badSize)==E_INVALIDARG && !std::memcmp(&copySentinel,&copyPreserved,sizeof(copySentinel)),"wrong-sized copy failure buffer modified");
    auto vs=file(argv[1]),ps=file(argv[2]),bytes=file(argv[3]);BeamRTGIRootLayout layout;hr(beamrtDecodeGIRoot(bytes.data(),bytes.size(),layout));
    ComPtr<ID3D12Debug> debug;const bool debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
    ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));ComPtr<ID3D12Device> device;
    if(warp){ComPtr<IDXGIAdapter> a;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&a)));hr(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));}
    else for(UINT i=0;!device;++i){ComPtr<IDXGIAdapter1> a;hr(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&a)));DXGI_ADAPTER_DESC1 d{};hr(a->GetDesc1(&d));if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
        if(SUCCEEDED(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))std::wcout<<L"Fixture GPU: "<<d.Description<<L'\n';}
    if(compactStorage || internedStorage)return profiledFixture(device.Get(),vs,ps,bytes,layout,internedStorage?internedPressure:compactPressure,debugEnabled,
        internedStorage?beamrtResourceStorageInterned:beamrtResourceStorageCompact);
    auto preexisting=resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    const auto preexistingAddress=preexisting->GetGPUVirtualAddress();
    ComPtr<ID3D12DescriptorHeap> untrackedHeap,untrackedRTVHeap;
    if(descriptorMode){D3D12_DESCRIPTOR_HEAP_DESC d{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
        hr(device->CreateDescriptorHeap(&d,IID_PPV_ARGS(&untrackedHeap)));d.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        hr(device->CreateDescriptorHeap(&d,IID_PPV_ARGS(&untrackedRTVHeap)));}
    SRVGate gate(device.Get());
    void* originals[10]{};for(unsigned i=0;i<10;++i)originals[i]=*beamrtResourceSDKSlot(device.Get(),i);
    if(descriptorMode){const BeamRTResourceConfig selected{sizeof(selected),beamrtResourceConfigABI,beamrtResourceDescriptorTextures,0};
        hr(BeamRT_ResourcesStartConfigured(device.Get(),&selected));}
    else hr(BeamRT_ResourcesStart(device.Get()));
    need(FAILED(BeamRT_ResourcesStart(device.Get())),"resource observer restarted");
    BeamRTResourceFailure failure{};need(BeamRT_ResourcesFirstFailure(&failure,sizeof(failure))==S_FALSE && failure.bytes==sizeof(failure) && failure.abi==1 && !failure.kind,"healthy first failure was invented");
    BeamRTResourceStatus healthy{};hr(BeamRT_ResourcesStatus(&healthy,sizeof(healthy)));need(beamrtResourceFailureValid(failure,healthy),"healthy first failure shape invalid");
    const auto selectedMode=descriptorMode?beamrtResourceDescriptorTextures:beamrtResourceAllAllocations;
    BeamRTResourceCopyFailure emptyCopy{};emptyCopy.bytes=sizeof(emptyCopy);emptyCopy.abi=beamrtResourceCopyFailureABI;
    need(BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure))==S_FALSE && !std::memcmp(&copyFailure,&emptyCopy,sizeof(emptyCopy))
        && beamrtResourceCopyFailureValid(copyFailure,failure,healthy,selectedMode),"healthy copy failure query invented topology");
    BeamRTResourceFailure sentinel;std::memset(&sentinel,0xa5,sizeof(sentinel));const auto preserved=sentinel;
    need(BeamRT_ResourcesFirstFailure(nullptr,sizeof(failure))==E_INVALIDARG,"null first failure buffer accepted");
    for(const auto badSize:std::array<uint32_t,3>{0,static_cast<uint32_t>(sizeof(failure)-1),static_cast<uint32_t>(sizeof(failure)+1)})
        need(BeamRT_ResourcesFirstFailure(&sentinel,badSize)==E_INVALIDARG && !std::memcmp(&sentinel,&preserved,sizeof(sentinel)),"wrong-sized first failure buffer modified");
    HRESULT wrongOff=S_OK;std::thread controlThread([&]{wrongOff=BeamRT_ResourcesDisable();});controlThread.join();need(wrongOff==E_ACCESSDENIED,"foreign control thread disabled tracker");
    BeamRTBufferCandidate candidate{};need(FAILED(BeamRT_ResourcesBufferCandidate(preexistingAddress,16,&candidate,sizeof(candidate))) && !candidate.bytes,"preexisting buffer guessed");
    pass("cold/default/start/owner controls");
    auto unsupportedCandidate=[&](uint64_t address,uint64_t span){std::memset(&candidate,0xa5,sizeof(candidate));
        const auto result=BeamRT_ResourcesBufferCandidate(address,span,&candidate,sizeof(candidate));const BeamRTBufferCandidate zero{};
        need(result==HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED) && !std::memcmp(&candidate,&zero,sizeof(candidate)),"descriptor-only mode guessed a buffer candidate");};
    std::vector<ComPtr<ID3D12Resource>> unrelatedResources;
    if(descriptorMode){D3D12_RESOURCE_DESC texture{};texture.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;texture.Width=texture.Height=1;
        texture.DepthOrArraySize=1;texture.MipLevels=1;texture.SampleDesc.Count=1;texture.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
        for(unsigned i=0;i<beamrtResourceObjectLimit+17;++i){
            unrelatedResources.push_back(resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ));
            unrelatedResources.push_back(resource(device.Get(),texture,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE));}
        hr(BeamRT_ResourcesStatus(&healthy,sizeof(healthy)));need(healthy.healthy && !healthy.pressure && !healthy.overlaps && !healthy.liveResources,
            "unrelated live buffers/textures consumed descriptor-mode admissions");
        unsupportedCandidate(unrelatedResources.front()->GetGPUVirtualAddress(),16);
        pass("descriptor mode retains more than 128 unrelated buffers and textures without admission");}
    BeamRTPipelineAuditConfig config{sizeof(config),1,vs.data(),vs.size(),ps.data(),ps.size(),{0,0}};
    hr(BeamRT_PipelineAuditStart(device.Get(),&config));hr(BeamRT_BindingsStart(device.Get()));
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,bytes.data(),bytes.size(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root.Get();p.VS={vs.data(),vs.size()};p.PS={ps.data(),ps.size()};
    p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;p.RasterizerState.DepthClipEnable=TRUE;
    p.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;p.SampleMask=UINT_MAX;p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;p.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&pipeline)));hr(BeamRT_BindingsTargetFromAudit());
    Renderer render(device.Get());render.begin();std::vector<ComPtr<ID3D12Resource>> textures;for(unsigned i=1;i<=6;++i)textures.push_back(render.texture(static_cast<float>(i)));render.submit();
    auto constants=resource(device.Get(),buffer(512),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* mapped=nullptr;D3D12_RANGE none{0,0};hr(constants->Map(0,&none,&mapped));
    const float bias[]={2,2,2,2};std::memcpy(static_cast<uint8_t*>(mapped)+256,bias,sizeof(bias));constants->Unmap(0,nullptr);
    const auto cbvAddress=constants->GetGPUVirtualAddress()+256;
    if(descriptorMode)unsupportedCandidate(cbvAddress,16);
    else {hr(BeamRT_ResourcesBufferCandidate(cbvAddress,16,&candidate,sizeof(candidate)));
        need(candidate.candidateOnly && candidate.offset==256 && candidate.availableBytes==256 && candidate.canonicalIdentity==identity(constants.Get()),"root CBV candidate/suballocation mismatch");}
    if(descriptorMode)for(const auto invalid:std::array<std::array<uint64_t,2>,4>{{{{0,16}},{{cbvAddress+1,16}},{{cbvAddress,0}},{{UINT64_MAX-255,512}}}}){
        std::memset(&candidate,0xa5,sizeof(candidate));need(BeamRT_ResourcesBufferCandidate(invalid[0],invalid[1],&candidate,sizeof(candidate))==E_INVALIDARG && !candidate.bytes,
            "descriptor-mode CBV diagnostic bypassed address/span guards");}
    for(const auto bad:std::array<uint64_t,3>{cbvAddress+1,constants->GetGPUVirtualAddress()+512,UINT64_MAX-255}){
        std::memset(&candidate,0xa5,sizeof(candidate));need(FAILED(BeamRT_ResourcesBufferCandidate(bad,16,&candidate,sizeof(candidate))) && !candidate.bytes,"invalid CBV candidate accepted");}
    need(FAILED(BeamRT_ResourcesBufferCandidate(cbvAddress,257,&candidate,sizeof(candidate))),"CBV candidate exceeded buffer");
    pass("observed buffer candidate; offset/span/alignment guards");
    // Known placed-buffer aliases are ambiguous even when both objects live.
    {
        const auto bd=buffer(512);const auto allocation=device->GetResourceAllocationInfo(0,1,&bd);
        D3D12_HEAP_DESC hd{};hd.SizeInBytes=allocation.SizeInBytes;hd.Alignment=allocation.Alignment;hd.Properties.Type=D3D12_HEAP_TYPE_UPLOAD;hd.Flags=D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS;
        ComPtr<ID3D12Heap> backing;hr(device->CreateHeap(&hd,IID_PPV_ARGS(&backing)));
        ComPtr<ID3D12Resource> first,second;
        hr(device->CreatePlacedResource(backing.Get(),0,&bd,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&first)));
        hr(device->CreatePlacedResource(backing.Get(),0,&bd,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&second)));
        const auto a=first->GetGPUVirtualAddress(),b=second->GetGPUVirtualAddress();
        if(descriptorMode){unsupportedCandidate(a,16);unsupportedCandidate(b,16);}
        else if(a==b){need(FAILED(BeamRT_ResourcesBufferCandidate(a,16,&candidate,sizeof(candidate))) && !candidate.bytes,"known aliased address not refused");std::cout<<"Known equal-VA alias refusal exercised\n";}
        else {hr(BeamRT_ResourcesBufferCandidate(a,16,&candidate,sizeof(candidate)));need(candidate.canonicalIdentity==identity(first.Get()),"placed buffer candidate mismatch");std::cout<<"Placed aliases have distinct VAs; equal-VA refusal not exercised\n";}
    }
    pass("placed-buffer observation and driver-specific alias handling");
    auto heap=[&](D3D12_DESCRIPTOR_HEAP_TYPE type,UINT count,bool visible){
        D3D12_DESCRIPTOR_HEAP_DESC d{};d.Type=type;d.NumDescriptors=count;d.Flags=visible?D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE:D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        ComPtr<ID3D12DescriptorHeap> h;hr(device->CreateDescriptorHeap(&d,IID_PPV_ARGS(&h)));return h;};
    auto storage=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,16,false);
    auto gpu=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,6,true);
    auto samplerHeap=heap(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,6,true);
    auto rt=heap(D3D12_DESCRIPTOR_HEAP_TYPE_RTV,2,false);
    const auto stride=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto slot=[&](ID3D12DescriptorHeap* h,UINT i){auto handle=h->GetCPUDescriptorHandleForHeapStart();handle.ptr+=uint64_t(i)*device->GetDescriptorHandleIncrementSize(h->GetDesc().Type);return handle;};
    D3D12_SHADER_RESOURCE_VIEW_DESC desc{};desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;desc.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;desc.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;desc.Texture2D.MipLevels=1;
    if(descriptorMode){const auto supported=unrelatedResources[1].Get();
        device->CreateShaderResourceView(supported,&desc,untrackedHeap->GetCPUDescriptorHandleForHeapStart());
        missing(untrackedHeap->GetCPUDescriptorHandleForHeapStart(),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        auto unsupported=desc;unsupported.Shader4ComponentMapping=D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING(0,0,0,0);
        device->CreateShaderResourceView(supported,&unsupported,slot(storage.Get(),8));missing(slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        auto unsupportedDesc=textures[0]->GetDesc();unsupportedDesc.Format=DXGI_FORMAT_R16_FLOAT;
        auto unsupportedTexture=resource(device.Get(),unsupportedDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        unsupported=desc;unsupported.Format=unsupportedDesc.Format;device->CreateShaderResourceView(unsupportedTexture.Get(),&unsupported,slot(storage.Get(),8));
        missing(slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        auto outputDesc=textures[0]->GetDesc();outputDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        auto unknownOutput=resource(device.Get(),outputDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        device->CreateRenderTargetView(unknownOutput.Get(),nullptr,untrackedRTVHeap->GetCPUDescriptorHandleForHeapStart());
        missing(untrackedRTVHeap->GetCPUDescriptorHandleForHeapStart(),D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        outputDesc.Format=DXGI_FORMAT_R16_FLOAT;auto unsupportedOutput=resource(device.Get(),outputDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        device->CreateRenderTargetView(unsupportedOutput.Get(),nullptr,slot(rt.Get(),1));missing(slot(rt.Get(),1),D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        hr(BeamRT_ResourcesStatus(&healthy,sizeof(healthy)));need(healthy.healthy && !healthy.liveResources && !healthy.pressure,
            "unknown heap/unsupported SRV or RTV shape admitted a texture");
        pass("unknown heap and unsupported format/mapping remain unadmitted");}
    D3D12_SAMPLER_DESC sampler{};sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_POINT;sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;sampler.MaxLOD=D3D12_FLOAT32_MAX;sampler.MaxAnisotropy=1;sampler.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    std::array<uint64_t,6> admittedIds{};
    for(UINT i=0;i<6;++i){device->CreateShaderResourceView(textures[i].Get(),i?&desc:nullptr,slot(storage.Get(),i));device->CreateSampler(&sampler,slot(samplerHeap.Get(),i));
        const auto v=view(slot(storage.Get(),i),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);need(v.kind==1 && v.canonicalIdentity==identity(textures[i].Get()) && v.resource.Width==1 && v.resource.Height==1 && v.resource.Format==desc.Format,"actual SRV identity/description mismatch");admittedIds[i]=v.resourceId;}
    need(view(slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).defaultView==1,"default SRV not distinguished");
    pass("explicit/default SRV identities and dimensions");
    device->CopyDescriptorsSimple(6,slot(gpu.Get(),0),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    for(UINT i=0;i<6;++i)need(view(slot(gpu.Get(),i),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId==view(slot(storage.Get(),i),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId,"simple copy lost provenance");
    pass("CPU storage to shader-visible descriptor copies");
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=targetDesc.Height=1;targetDesc.DepthOrArraySize=1;targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;targetDesc.Format=p.RTVFormats[0];targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=resource(device.Get(),targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    device->CreateRenderTargetView(target.Get(),nullptr,slot(rt.Get(),0));device->CopyDescriptorsSimple(1,slot(rt.Get(),1),slot(rt.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    need(view(slot(rt.Get(),1),D3D12_DESCRIPTOR_HEAP_TYPE_RTV).canonicalIdentity==identity(target.Get()),"RTV copy identity mismatch");pass("default output and RTV copies");
    if(descriptorMode){hr(BeamRT_ResourcesStatus(&healthy,sizeof(healthy)));need(healthy.healthy && healthy.liveResources==7 && !healthy.pressure,
        "descriptor mode did not admit exactly six input textures plus one output");pass("exact seven relevant live admissions despite unrelated retained allocations");}
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows=0;UINT64 row=0,total=0;device->GetCopyableFootprints(&targetDesc,0,1,0,&footprint,&rows,&row,&total);
    auto readback=resource(device.Get(),buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    auto bind=[&]{render.list->SetPipelineState(pipeline.Get());render.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* bound[]={gpu.Get(),samplerHeap.Get()};render.list->SetDescriptorHeaps(2,bound);
        render.list->SetGraphicsRootConstantBufferView(layout.cbv,cbvAddress);render.list->SetGraphicsRootDescriptorTable(layout.srv,gpu->GetGPUDescriptorHandleForHeapStart());render.list->SetGraphicsRootDescriptorTable(layout.sampler,samplerHeap->GetGPUDescriptorHandleForHeapStart());
        D3D12_VIEWPORT viewport{0,0,1,1,0,1};D3D12_RECT scissor{0,0,1,1};render.list->RSSetViewports(1,&viewport);render.list->RSSetScissorRects(1,&scissor);const auto out=slot(rt.Get(),1);render.list->OMSetRenderTargets(1,&out,FALSE,nullptr);render.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);};
    unsigned pixelChecks=0;
    auto pixel=[&](float expected=23){++pixelChecks;transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
        render.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(render.list.Get(),target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);render.submit();
        D3D12_RANGE read{0,static_cast<SIZE_T>(total)};hr(readback->Map(0,&read,&mapped));const auto color=*reinterpret_cast<float*>(static_cast<uint8_t*>(mapped)+footprint.Offset);readback->Unmap(0,&none);
        const bool matches=std::abs(color-expected)<.00001f;
        if(!matches)std::cerr<<"Fixture GPU pixel check "<<pixelChecks<<": expected="<<expected<<", actual="<<color<<std::endl;
        need(matches,expected==23?"resource tracker changed native pixel 23":"copied descriptor GPU value mismatch");};
    BeamRTResourceCheckpoint outputCheckpoint{};hr(BeamRT_ResourcesCheckpoint(&outputCheckpoint,sizeof(outputCheckpoint)));
    render.begin();bind();BeamRTResourceDrawToken interval{};hr(BeamRT_ResourcesBeginDraw(&interval,sizeof(interval)));
    render.list->DrawInstanced(3,1,0,0);BeamRTBindingSnapshot snapshot{};hr(BeamRT_BindingsRead(&snapshot,sizeof(snapshot)));
    const auto consumed=interval;BeamRTResourceDrawObservation observation{};const uint32_t probeBytes=descriptorMode?0u:16u;
    hr(BeamRT_ResourcesFinishDraw(&interval,sizeof(interval),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),probeBytes,&observation,sizeof(observation)));
    need(!interval.ticket && beamrtResourceObservationValid(observation,snapshot,GetCurrentThreadId()) && observation.intervalAccepted,"real draw bracket receipt invalid");
    if(descriptorMode){const BeamRTBufferCandidate zero{};need(observation.cbvResult==S_FALSE && !std::memcmp(&observation.cbv,&zero,sizeof(zero)),"disabled descriptor-mode draw CBV probe invented metadata");
        BeamRTResourceDrawToken probeInterval{};hr(BeamRT_ResourcesBeginDraw(&probeInterval,sizeof(probeInterval)));BeamRTResourceDrawObservation probed{};
        hr(BeamRT_ResourcesFinishDraw(&probeInterval,sizeof(probeInterval),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),16,&probed,sizeof(probed)));
        need(probed.intervalAccepted && probed.cbvResult==HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED) && !std::memcmp(&probed.cbv,&zero,sizeof(zero))
            && beamrtResourceObservationValid(probed,snapshot,GetCurrentThreadId()),"descriptor-only draw probe inferred an unindexed buffer");
        pass("descriptor-only draw keeps default CBV probe off and refuses explicit buffer inference");}
    for(int field=0;field<27;++field){auto invalid=observation;
        if(field==0)--invalid.bytes;if(field==1)invalid.abi=1;if(field==2)invalid.attempted=0;if(field==3)invalid.intervalAccepted=2;
        if(field==4)++invalid.recordThread;if(field==5)invalid.srvCount=5;if(field==6)invalid.rtvCount=9;if(field==7)invalid.cbvProbeBytes=65537;
        if(field==8)++invalid.snapshotSerial;if(field==9)++invalid.commandId;if(field==10)++invalid.generation;if(field==11)++invalid.callbacksEnd;
        if(field==12)invalid.status.healthy=2;if(field==13)invalid.descriptorProvenanceVerified=1;if(field==14)invalid.cbvContentsVerified=1;
        if(field==15)invalid.cameraVerified=1;if(field==16)invalid.gpuOrderingVerified=1;if(field==17)invalid.lightingConsumed=1;
        if(field==18)invalid.srvs[0].kind=2;if(field==19)invalid.rtvs[0].resource.Width=0;if(field==20)invalid.cbv.candidateOnly=2;
        if(field==21)++invalid.cbv.address;if(field==22)invalid.reserved=1;if(field==23)invalid.outputCheckpointValid=0;
        if(field==24)++invalid.outputCallbacks;if(field==25)++invalid.outputThread;
        if(field==26)invalid.abi=2;
        need(!beamrtResourceObservationValid(invalid,snapshot,GetCurrentThreadId()),"malformed resource observation accepted");
    }
    std::cout<<"27 malformed resource observations rejected\n";
    auto replay=consumed;need(FAILED(BeamRT_ResourcesFinishDraw(&replay,sizeof(replay),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),probeBytes,&observation,sizeof(observation))) && !observation.intervalAccepted && !observation.srvs[0].resourceId,"consumed draw token replay accepted");
    for(UINT i=0;i<6;++i){const auto v=view({snapshot.srvCpu[i]},D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);need(v.canonicalIdentity==identity(textures[i].Get()),"GI recording descriptor resolved to wrong resource");}
    need(view({snapshot.renderTargets[0]},D3D12_DESCRIPTOR_HEAP_TYPE_RTV).canonicalIdentity==identity(target.Get()),"GI output resolved to wrong resource");
    if(descriptorMode)unsupportedCandidate(snapshot.cbv,16);
    else {hr(BeamRT_ResourcesBufferCandidate(snapshot.cbv,16,&candidate,sizeof(candidate)));need(candidate.canonicalIdentity==identity(constants.Get()) && candidate.offset==256,"GI CBV candidate mismatch");}
    need(!snapshot.descriptorProvenanceVerified && !snapshot.cbvContentsVerified && !snapshot.cameraVerified && !snapshot.gpuOrderingVerified && !snapshot.lightingConsumed,"GI recording proof flags changed");
    pixel();pass("actual recording-to-resource fixture join; unchanged GPU pixel 23");
    // A CPU descriptor copy snapshots the view; it is not a live link to the
    // source slot. Every submitted draw completes before a GPU descriptor edit.
    const auto copiedBeforeOverwrite=view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    device->CreateShaderResourceView(textures[1].Get(),&desc,slot(storage.Get(),0));
    const auto copiedAfterSourceWrite=view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(!std::memcmp(&copiedBeforeOverwrite,&copiedAfterSourceWrite,sizeof(copiedBeforeOverwrite)),"source overwrite changed previously copied view metadata");
    render.begin();bind();render.list->DrawInstanced(3,1,0,0);pixel();
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const auto recopied=view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(recopied.resourceId==admittedIds[1] && recopied.revision>copiedBeforeOverwrite.revision,"recopy did not snapshot the replacement source view");
    render.begin();bind();render.list->DrawInstanced(3,1,0,0);pixel(24);
    const auto sourceBeforeDestinationWrite=view(slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    device->CreateShaderResourceView(textures[2].Get(),&desc,slot(gpu.Get(),0));
    const auto sourceAfterDestinationWrite=view(slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(!std::memcmp(&sourceBeforeDestinationWrite,&sourceAfterDestinationWrite,sizeof(sourceBeforeDestinationWrite)),"destination overwrite changed independent source view metadata");
    render.begin();bind();render.list->DrawInstanced(3,1,0,0);pixel(25);
    device->CreateShaderResourceView(textures[0].Get(),&desc,slot(storage.Get(),0));
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const auto beforeDifferentView=view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);auto clampedView=desc;clampedView.Texture2D.ResourceMinLODClamp=.25f;
    device->CreateShaderResourceView(textures[0].Get(),&clampedView,slot(storage.Get(),0));
    const auto unchangedDifferentView=view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(!std::memcmp(&beforeDifferentView,&unchangedDifferentView,sizeof(beforeDifferentView)),"same-resource view change leaked through an earlier copy");
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const auto copiedDifferentView=view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(copiedDifferentView.resourceId==beforeDifferentView.resourceId && copiedDifferentView.srv.Texture2D.ResourceMinLODClamp==.25f
        && copiedDifferentView.revision>beforeDifferentView.revision,"copy conflated distinct views of one resource");
    // The alternate LOD-clamp view tests copied metadata only. Restore the
    // original view before drawing; do not assume its one-mip sample semantics.
    device->CreateShaderResourceView(textures[0].Get(),&desc,slot(storage.Get(),0));
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).srv.Texture2D.ResourceMinLODClamp==0,"metadata-only alternate view remained bound for GPU verification");
    render.begin();bind();render.list->DrawInstanced(3,1,0,0);pixel();
    std::cout<<"Copy regression: independent source/destination snapshots, distinct same-resource views; GPU pixels 23/24/25\n";
    hr(BeamRT_ResourcesBeginDraw(&interval,sizeof(interval)));const auto ownerToken=interval;auto forged=interval;++forged.ticket;
    need(FAILED(BeamRT_ResourcesFinishDraw(&forged,sizeof(forged),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),probeBytes,&observation,sizeof(observation))) && !observation.intervalAccepted,"forged interval accepted");
    HRESULT wrongFinish=S_OK;std::thread wrongCaller([&]{auto foreign=ownerToken;BeamRTResourceDrawObservation refused{};
        wrongFinish=BeamRT_ResourcesFinishDraw(&foreign,sizeof(foreign),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),probeBytes,&refused,sizeof(refused));});wrongCaller.join();
    need(FAILED(wrongFinish),"foreign caller consumed interval");hr(BeamRT_ResourcesCancelDraw(&interval,sizeof(interval)));
    need(BeamRT_ResourcesCancelDraw(&interval,sizeof(interval))==S_FALSE,"empty interval cancellation not idempotent");
    pass("forged/replayed/wrong-thread tokens refuse without freeing owner token");
    hr(BeamRT_ResourcesBeginDraw(&interval,sizeof(interval)));device->CreateShaderResourceView(textures[0].Get(),&desc,slot(storage.Get(),0));
    need(FAILED(BeamRT_ResourcesFinishDraw(&interval,sizeof(interval),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),probeBytes,&observation,sizeof(observation))) && !interval.ticket
        && !observation.intervalAccepted && observation.callbacksEnd>observation.callbacksBegin && !observation.srvs[0].resourceId,"resource write during interval accepted");
    pass("observed descriptor write during interval clears resource evidence");
    hr(BeamRT_ResourcesCheckpoint(&outputCheckpoint,sizeof(outputCheckpoint)));
    device->CreateShaderResourceView(textures[0].Get(),&desc,slot(storage.Get(),0));
    hr(BeamRT_ResourcesBeginDraw(&interval,sizeof(interval)));
    need(FAILED(BeamRT_ResourcesFinishDraw(&interval,sizeof(interval),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),probeBytes,&observation,sizeof(observation)))
        && !observation.intervalAccepted && observation.outputCallbacks<observation.callbacksBegin && observation.callbacksBegin==observation.callbacksEnd,
        "pre-draw descriptor mutation escaped output checkpoint");
    pass("output checkpoint rejects earlier writes despite stable draw bracket");
    // Valid native calls exercise lost provenance without ever submitting stale/null views.
    device->CreateShaderResourceView(nullptr,&desc,slot(storage.Get(),0));missing(slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    D3D12_CONSTANT_BUFFER_VIEW_DESC cbv{cbvAddress,256};device->CreateConstantBufferView(&cbv,slot(storage.Get(),1));missing(slot(storage.Get(),1),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),1),slot(storage.Get(),1),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing(slot(gpu.Get(),1),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto uavDesc=textures[0]->GetDesc();uavDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    auto uavResource=resource(device.Get(),uavDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav{};uav.Format=uavDesc.Format;uav.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2D;
    device->CreateUnorderedAccessView(uavResource.Get(),nullptr,&uav,slot(storage.Get(),2));missing(slot(storage.Get(),2),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),2),slot(storage.Get(),2),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing(slot(gpu.Get(),2),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    pass("null/CBV/UAV overwrites and unknown-copy destinations clear");
    for(UINT i=0;i<6;++i){device->CreateShaderResourceView(textures[i].Get(),&desc,slot(storage.Get(),i));
        need(view(slot(storage.Get(),i),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId==admittedIds[i],"live admitted resource identity changed after descriptor overwrites");}
    // Sparse sources -> contiguous destination; omitted sizes mean one per source range.
    std::array<D3D12_CPU_DESCRIPTOR_HANDLE,6> sources{};for(UINT i=0;i<6;++i)sources[i]=slot(storage.Get(),5-i);
    const auto destination=slot(gpu.Get(),0);const UINT six=6;device->CopyDescriptors(1,&destination,&six,6,sources.data(),nullptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    for(UINT i=0;i<6;++i)need(view(slot(gpu.Get(),i),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).canonicalIdentity==identity(textures[5-i].Get()),"sparse range flatten mismatch");
    device->CopyDescriptorsSimple(6,destination,slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    pass("sparse/default-size range flatten and overwrite revisions");
    missing({destination.ptr+1},D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing({destination.ptr+uint64_t(6)*stride},D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing(destination,D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    pass("descriptor alignment/extent/type guards");
    render.begin();auto transient=render.texture(10);render.submit();device->CreateShaderResourceView(transient.Get(),&desc,slot(storage.Get(),8));
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);const auto deadId=view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId;
    transient.Reset();missing(slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    render.begin();auto replacementTexture=render.texture(12);render.submit();device->CreateShaderResourceView(replacementTexture.Get(),&desc,slot(storage.Get(),8));
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId>deadId,"retired resource identity reused on readmission");
    replacementTexture.Reset();missing(slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto temporaryHeap=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,false);const auto retiredHandle=slot(temporaryHeap.Get(),0);device->CreateShaderResourceView(textures[0].Get(),&desc,retiredHandle);
    const auto retiredHeapId=view(retiredHandle,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).heapId;temporaryHeap.Reset();missing(retiredHandle,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto replacementHeap=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,false);device->CreateShaderResourceView(textures[0].Get(),&desc,slot(replacementHeap.Get(),0));
    need(view(slot(replacementHeap.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).heapId!=retiredHeapId && deadId,"retired heap identity reused");
    auto transientBuffer=resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);const auto deadAddress=transientBuffer->GetGPUVirtualAddress();
    if(descriptorMode)unsupportedCandidate(deadAddress,16);else hr(BeamRT_ResourcesBufferCandidate(deadAddress,16,&candidate,sizeof(candidate)));transientBuffer.Reset();
    need(FAILED(BeamRT_ResourcesBufferCandidate(deadAddress,16,&candidate,sizeof(candidate))) && !candidate.bytes,"retired buffer candidate remained available");
    pass("resource/heap/buffer lifetime invalidation without retention");
    // These textures are never submitted to the GPU. Force a new admission
    // immediately after destruction, before Status/lookup can reap old IDs: a
    // reused dead object-table slot must not orphan its old descriptor copies.
    BeamRTResourceStatus reuseBaseline{};hr(BeamRT_ResourcesStatus(&reuseBaseline,sizeof(reuseBaseline)));
    auto reuseSource=resource(device.Get(),textures[0]->GetDesc(),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    device->CreateShaderResourceView(reuseSource.Get(),&desc,slot(storage.Get(),8));
    device->CopyDescriptorsSimple(1,slot(gpu.Get(),0),slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const auto reuseSourceId=view(slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId;
    need(view(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId==reuseSourceId,"lifetime-slot reuse source copy mismatch");
    reuseSource.Reset();
    auto reuseReplacement=resource(device.Get(),textures[0]->GetDesc(),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    device->CreateShaderResourceView(reuseReplacement.Get(),&desc,slot(storage.Get(),10));
    BeamRTResourceStatus reuseAfter{};hr(BeamRT_ResourcesStatus(&reuseAfter,sizeof(reuseAfter)));
    need(reuseAfter.healthy && reuseAfter.views==reuseBaseline.views+1 && reuseAfter.liveResources==reuseBaseline.liveResources+1,
        "dead object-slot reuse left orphaned original or copied descriptor occupancy");
    const auto reused=view(slot(storage.Get(),10),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(reused.resourceId>reuseSourceId && reused.canonicalIdentity==identity(reuseReplacement.Get()),"new admission reused retired resource metadata");
    missing(slot(storage.Get(),8),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);missing(slot(gpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    reuseReplacement.Reset();missing(slot(storage.Get(),10),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    pass("new admission reaps old numeric lifetime before dead object-slot reuse");
    device->CopyDescriptorsSimple(6,destination,slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    // Capacity pressure poisons observation, not original forwarding or native GPU work.
    std::vector<ComPtr<ID3D12DescriptorHeap>> pressureHeaps;
    std::vector<ComPtr<ID3D12Resource>> pressureResources;
    const bool copyPressure=pressureKind>=5;
    // Retain one unused resource in the already-counted replacement heap. This
    // keeps the exact fifteen-view baseline while allowing resource death to
    // remove a remaining association AFTER metadata has become poisoned.
    ComPtr<ID3D12Resource> retainedReapResource;
    if(pressureKind==2 || copyPressure){
        retainedReapResource=resource(device.Get(),textures[0]->GetDesc(),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        device->CreateShaderResourceView(retainedReapResource.Get(),&desc,slot(replacementHeap.Get(),0));
        need(view(slot(replacementHeap.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).canonicalIdentity==identity(retainedReapResource.Get()),
            "post-failure retirement fixture resource was not admitted");
    }
    const bool simpleCopyCase=pressureKind==8,explicitCopyCase=pressureKind==9;
    const UINT copyLanes=pressureKind==7?beamrtResourceCopyLimit:3u;
    std::array<D3D12_CPU_DESCRIPTOR_HANDLE,beamrtResourceCopyLimit> failedSources{},failedDestinations{};
    std::array<BeamRTResourceView,beamrtResourceCopyLimit> expectedSources{},expectedPrevious{};
    uint64_t copyDestinationHeapId=0;UINT copyFill=0;
    // At a full table, a mixed copy can free a destination later in its range
    // order. Net-zero occupancy must not fail due to transient insertion order.
    if(!pressureKind || copyPressure){
        BeamRTResourceStatus before{};hr(BeamRT_ResourcesStatus(&before,sizeof(before)));
        need(before.healthy && before.views==15 && !before.pressure,"copy capacity baseline must contain exactly fifteen known views");
        auto copyHeap=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,beamrtResourceViewLimit+3,false);
        const auto nullSource=slot(storage.Get(),9);device->CreateShaderResourceView(nullptr,&desc,nullSource);
        const UINT targetEntry=pressureKind==7?194u:beamrtResourceViewLimit;
        const auto fill=targetEntry-before.views;
        for(UINT i=0;i<fill;++i)device->CopyDescriptorsSimple(1,slot(copyHeap.Get(),i),slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        hr(BeamRT_ResourcesStatus(&before,sizeof(before)));need(before.healthy && before.views==targetEntry && !before.pressure,"copy fixture did not reach its exact planned entry occupancy");
        if(!copyPressure)for(bool nullFirst:{false,true}){
            const auto knownDestination=slot(copyHeap.Get(),nullFirst?0:fill),clearedDestination=slot(copyHeap.Get(),nullFirst?fill:0);
            std::array<D3D12_CPU_DESCRIPTOR_HANDLE,2> copyDestinations={knownDestination,clearedDestination},copySources={slot(storage.Get(),0),nullSource};
            if(nullFirst){std::swap(copyDestinations[0],copyDestinations[1]);std::swap(copySources[0],copySources[1]);}
            const auto serialBefore=before.serial,unknownBefore=before.unknownCopies;
            device->CopyDescriptors(2,copyDestinations.data(),nullptr,2,copySources.data(),nullptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            hr(BeamRT_ResourcesStatus(&before,sizeof(before)));
            need(before.healthy && before.views==beamrtResourceViewLimit && !before.pressure && !before.overlaps
                && before.serial==serialBefore+2 && before.unknownCopies==unknownBefore+1,"mixed copy falsely exhausted capacity despite net-zero final occupancy");
            need(view(knownDestination,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resourceId==admittedIds[0],"mixed copy lost known source provenance");
            missing(clearedDestination,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        }
        render.begin();bind();render.list->DrawInstanced(3,1,0,0);pixel();
        need(BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure))==S_FALSE && !std::memcmp(&copyFailure,&emptyCopy,sizeof(emptyCopy))
            && beamrtResourceCopyFailureValid(copyFailure,failure,before,selectedMode),"successful full-table copy invented a failure companion");
        if(!copyPressure)std::cout<<"Copy regression: full 256-view mixed known/null copies fit in both range orders; native GPU 23\n";
        if(copyPressure){
            // All three native writes are legal and forwarded. Only the first
            // metadata insertion can be attempted after the 257th view refuses.
            for(UINT i=0;i<copyLanes;++i){
                const bool previous=(pressureKind==6 || pressureKind==7) && i==copyLanes-1;
                failedDestinations[i]=slot(copyHeap.Get(),previous?0:fill+i);
                failedSources[i]=slot(storage.Get(),pressureKind==7?0:i);
                expectedSources[i]=view(failedSources[i],D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
                if(previous)expectedPrevious[i]=view(failedDestinations[i],D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            }
            copyFill=fill;
            copyDestinationHeapId=view(slot(copyHeap.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).heapId;
            if(simpleCopyCase)device->CopyDescriptorsSimple(copyLanes,failedDestinations[0],failedSources[0],D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            else if(explicitCopyCase)device->CopyDescriptors(1,failedDestinations.data(),&copyLanes,1,failedSources.data(),&copyLanes,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            else device->CopyDescriptors(copyLanes,failedDestinations.data(),nullptr,copyLanes,failedSources.data(),nullptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            pressureHeaps.push_back(std::move(copyHeap));
        }else {copyHeap.Reset();BeamRTResourceStatus restored{};hr(BeamRT_ResourcesStatus(&restored,sizeof(restored)));
            need(restored.healthy && restored.views==15 && !restored.pressure,"temporary copy heap retirement did not recover the fifteen-view baseline");}
    }
    auto overlap=[&]{gate.begin(device.Get(),textures[0].Get(),&desc,slot(storage.Get(),0));
        device->CreateShaderResourceView(textures[1].Get(),&desc,slot(storage.Get(),1));gate.finish();};
    if(pressureKind==0)for(unsigned i=0;i<beamrtResourceHeapLimit+1;++i)pressureHeaps.push_back(heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,false));
    else if(pressureKind==1){
        if(descriptorMode){BeamRTResourceStatus before{};hr(BeamRT_ResourcesStatus(&before,sizeof(before)));
            need(before.healthy && before.liveResources==7,"descriptor admission baseline changed before relevant pressure");
            for(unsigned count=before.liveResources;count<=beamrtResourceObjectLimit;++count){
                auto relevant=resource(device.Get(),textures[0]->GetDesc(),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
                BeamRTResourceStatus allocated{};hr(BeamRT_ResourcesStatus(&allocated,sizeof(allocated)));
                need(allocated.healthy && allocated.liveResources==count,"viewless relevant allocation consumed an admission");
                device->CreateShaderResourceView(relevant.Get(),&desc,slot(storage.Get(),8));pressureResources.push_back(std::move(relevant));
                if(count<beamrtResourceObjectLimit){hr(BeamRT_ResourcesStatus(&allocated,sizeof(allocated)));
                    need(allocated.healthy && allocated.liveResources==count+1 && !allocated.pressure,"live admitted resource was evicted or duplicated before capacity");}
            }
        }else for(unsigned i=0;i<beamrtResourceObjectLimit+1;++i)pressureResources.push_back(resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ));
    }
    else if(pressureKind==2){
        auto pressureViews=heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,beamrtResourceViewLimit+1,false);
        for(unsigned i=0;i<beamrtResourceViewLimit+1;++i)device->CreateShaderResourceView(textures[0].Get(),&desc,slot(pressureViews.Get(),i));
        pressureHeaps.push_back(std::move(pressureViews));
    }
    std::array<BeamRTResourceDrawToken,beamrtResourceDrawLimit> outstanding{};
    if(pressureKind==3){for(auto& token:outstanding)hr(BeamRT_ResourcesBeginDraw(&token,sizeof(token)));
        need(FAILED(BeamRT_ResourcesBeginDraw(&interval,sizeof(interval))) && !interval.ticket,"draw token capacity bypassed");}
    if(pressureKind==4)overlap();
    BeamRTResourceStatus status{};hr(BeamRT_ResourcesStatus(&status,sizeof(status)));
    const uint32_t kinds[]={BeamRTResourceFailureHeapCapacity,BeamRTResourceFailureObjectCapacity,BeamRTResourceFailureViewCapacity,BeamRTResourceFailureDrawCapacity,BeamRTResourceFailureOverlap,BeamRTResourceFailureViewCapacity,BeamRTResourceFailureViewCapacity,BeamRTResourceFailureViewCapacity,BeamRTResourceFailureViewCapacity,BeamRTResourceFailureViewCapacity};
    const uint32_t methods[]={BeamRTResourceMethodCreateHeap,descriptorMode?BeamRTResourceMethodCreateSRV:BeamRTResourceMethodCommitted,BeamRTResourceMethodCreateSRV,BeamRTResourceMethodBeginDraw,BeamRTResourceMethodCreateSRV,BeamRTResourceMethodCopyRanges,BeamRTResourceMethodCopyRanges,BeamRTResourceMethodCopyRanges,BeamRTResourceMethodCopySimple,BeamRTResourceMethodCopyRanges};
    const uint32_t limits[]={beamrtResourceHeapLimit,beamrtResourceObjectLimit,beamrtResourceViewLimit,beamrtResourceDrawLimit,0,beamrtResourceViewLimit,beamrtResourceViewLimit,beamrtResourceViewLimit,beamrtResourceViewLimit,beamrtResourceViewLimit};
    if(copyPressure){
        need(BeamRT_ResourcesFirstFailure(&failure,sizeof(failure))==S_OK,"copy capacity did not preserve its first failure");
        std::cout<<"Copy pressure diagnostic: pressure="<<status.pressure<<", serial="<<status.serial<<", firstFailure.serial="<<failure.serial<<std::endl;
        need(status.serial==failure.serial,"copy capacity failure advanced trailing descriptor revisions after first refusal");
    }
    need(!status.healthy && status.attachedSlots==10 && (pressureKind==4?status.overlaps==1:status.pressure==1),"first failure did not refuse observations");
    need(BeamRT_ResourcesFirstFailure(&failure,sizeof(failure))==S_OK && beamrtResourceFailureValid(failure,status)
        && failure.kind==kinds[pressureKind] && failure.method==methods[pressureKind] && failure.callerThread==GetCurrentThreadId()
        && failure.capacityLimit==limits[pressureKind] && failure.attemptedCount==(limits[pressureKind]?limits[pressureKind]+1:0),"precise first failure event mismatch");
    need((pressureKind==3?!failure.activeCallbacks:failure.activeCallbacks==(pressureKind==4?2u:1u))
        && failure.callbackOrdinal && failure.callbackOrdinal==failure.observedCallbacks,"first failure callback provenance mismatch");
    if(pressureKind==0)need(failure.liveHeaps==beamrtResourceHeapLimit,"heap capacity first failure count mismatch");
    if(pressureKind==1)need(failure.liveResources==beamrtResourceObjectLimit,"resource capacity first failure count mismatch");
    if(pressureKind==2 || copyPressure)need(failure.views==beamrtResourceViewLimit,"view capacity first failure count mismatch");
    if(pressureKind==3)need(failure.drawTokens==beamrtResourceDrawLimit,"draw capacity first failure count mismatch");
    const auto firstFailure=failure;
    const auto copyResult=BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure));
    need(copyResult==(copyPressure?S_OK:S_FALSE) && beamrtResourceCopyFailureValid(copyFailure,failure,status,selectedMode),"first copy companion did not match the applicable first failure");
    if(copyPressure){
        const auto completed=pressureKind==7?63u:pressureKind==6?1u:0u;
        const auto cleared=pressureKind==6 || pressureKind==7?1u:0u;
        const auto entry=pressureKind==7?194u:256u;
        const auto rangeCount=simpleCopyCase || explicitCopyCase?1u:copyLanes;
        need(copyFailure.present==1 && copyFailure.mode==selectedMode && copyFailure.method==(simpleCopyCase?BeamRTResourceMethodCopySimple:BeamRTResourceMethodCopyRanges)
            && copyFailure.callerThread==GetCurrentThreadId() && copyFailure.descriptorType==D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV
            && copyFailure.laneCount==copyLanes && copyFailure.failedLane==completed && copyFailure.appliedLanes==completed
            && copyFailure.destinationRanges==rangeCount && copyFailure.sourceRanges==rangeCount
            && copyFailure.destinationSizesExplicit==(explicitCopyCase?1u:0u) && copyFailure.sourceSizesExplicit==(explicitCopyCase?1u:0u)
            && copyFailure.entryViews==entry && copyFailure.afterClearViews==entry-cleared && copyFailure.descriptorStride==stride
            && !std::memcmp(&copyFailure.firstFailure,&firstFailure,sizeof(firstFailure)),"copy companion phase or first-failure join mismatch");
        for(UINT i=0;i<rangeCount;++i)need(copyFailure.sources[i].start==failedSources[i].ptr && copyFailure.sources[i].count==(rangeCount==1?copyLanes:1u) && !copyFailure.sources[i].reserved
            && copyFailure.destinations[i].start==failedDestinations[i].ptr && copyFailure.destinations[i].count==(rangeCount==1?copyLanes:1u) && !copyFailure.destinations[i].reserved,"copy companion lost normalized range starts or effective sizes");
        for(UINT i=0;i<copyLanes;++i){const auto& lane=copyFailure.lanes[i];
            need(lane.sourceCpu==failedSources[i].ptr && lane.destinationCpu==failedDestinations[i].ptr
                && lane.sourceHeapKnown==1 && !lane.sourceVisible && lane.destinationHeapKnown==1 && !lane.destinationVisible
                && lane.sourceHeapId==expectedSources[i].heapId && lane.sourceIndex==(pressureKind==7?0u:i)
                && lane.destinationHeapId==copyDestinationHeapId && lane.destinationIndex==(cleared && i==copyLanes-1?0u:copyFill+i)
                && !std::memcmp(&lane.source,&expectedSources[i],sizeof(lane.source))
                && !std::memcmp(&lane.previousDestination,&expectedPrevious[i],sizeof(lane.previousDestination)),"copy companion lane lost exact pre-copy descriptor snapshots");
        }
        bool sourceHeap=false,destinationHeap=false;
        for(UINT i=0;i<copyFailure.heapCount;++i){const auto& h=copyFailure.heaps[i];
            if(h.heapId==expectedSources[0].heapId){sourceHeap=true;need(h.descriptorCount==16 && h.stride==stride && !h.visible && h.aliveAtEntry
                && h.entryViews==6 && h.afterClearViews==6 && h.failureViews==6,"copy source heap phase counts mismatch");}
            if(h.heapId==copyDestinationHeapId){destinationHeap=true;need(h.descriptorCount==beamrtResourceViewLimit+3 && h.stride==stride && !h.visible && h.aliveAtEntry
                && h.entryViews==copyFill && h.afterClearViews==copyFill-cleared && h.failureViews==copyFill-cleared+completed,"copy destination heap phase counts mismatch");}
        }
        need(sourceHeap && destinationHeap && copyFailure.heapCount<beamrtResourceHeapLimit,"copy companion omitted known heap summaries");
        for(unsigned field=0;field<67;++field){auto invalid=copyFailure;
            switch(field){
            case 0:--invalid.bytes;break;case 1:++invalid.abi;break;case 2:invalid.present=2;break;case 3:invalid.mode=selectedMode?0u:1u;break;
            case 4:invalid.method=BeamRTResourceMethodCommitted;break;case 5:invalid.descriptorType=D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;break;
            case 6:invalid.callerThread=0;break;case 7:invalid.laneCount=0;break;case 8:invalid.laneCount=beamrtResourceCopyLimit+1;break;
            case 9:invalid.failedLane=invalid.laneCount;break;case 10:invalid.appliedLanes=invalid.failedLane+1;break;
            case 11:invalid.destinationRanges=0;break;case 12:invalid.sourceRanges=beamrtResourceCopyLimit+1;break;
            case 13:invalid.destinationSizesExplicit=2;break;case 14:invalid.sourceSizesExplicit=2;break;
            case 15:invalid.entryViews=beamrtResourceViewLimit+1;break;case 16:invalid.afterClearViews=beamrtResourceViewLimit+1;break;
            case 17:invalid.heapCount=beamrtResourceHeapLimit+1;break;case 18:invalid.descriptorStride=0;break;
            case 19:invalid.reserved[0]=1;break;case 20:invalid.reserved[1]=1;break;
            case 21:invalid.firstFailure.kind=BeamRTResourceFailureHeapCapacity;break;case 22:invalid.firstFailure.method=firstFailure.method==BeamRTResourceMethodCopySimple?BeamRTResourceMethodCopyRanges:BeamRTResourceMethodCopySimple;break;
            case 23:++invalid.firstFailure.callerThread;break;case 24:++invalid.firstFailure.callbackOrdinal;break;case 25:++invalid.firstFailure.serial;break;
            case 26:invalid.firstFailure.reserved=1;break;case 27:invalid.heaps[0].heapId=0;break;case 28:invalid.heaps[0].cpuBase=0;break;
            case 29:invalid.heaps[0].descriptorCount=0;break;case 30:invalid.heaps[0].stride=0;break;case 31:invalid.heaps[0].type=D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;break;
            case 32:invalid.heaps[0].visible=2;break;case 33:invalid.heaps[0].entryViews=beamrtResourceViewLimit+1;break;
            case 34:invalid.heaps[0].afterClearViews=invalid.heaps[0].entryViews+1;break;case 35:invalid.heaps[0].failureViews=beamrtResourceViewLimit+1;break;
            case 36:invalid.heaps[0].aliveAtEntry=2;break;case 37:invalid.heaps[0].reserved[0]=1;break;
            case 38:invalid.destinations[0].start=0;break;case 39:invalid.destinations[0].count=0;break;
            case 40:if(invalid.destinationRanges<beamrtResourceCopyLimit)invalid.destinations[invalid.destinationRanges].start=1;else invalid.destinations[beamrtResourceCopyLimit-1].reserved=1;break;case 41:invalid.sources[0].reserved=1;break;
            case 42:if(invalid.sourceRanges<beamrtResourceCopyLimit)invalid.sources[invalid.sourceRanges].start=1;else invalid.sources[beamrtResourceCopyLimit-1].reserved=1;break;case 43:++invalid.lanes[0].sourceCpu;break;
            case 44:++invalid.lanes[0].destinationCpu;break;case 45:invalid.lanes[0].sourceHeapId=0;break;
            case 46:invalid.lanes[0].sourceIndex=UINT64_MAX;break;case 47:invalid.lanes[0].destinationHeapId=0;break;
            case 48:invalid.lanes[0].destinationIndex=UINT64_MAX;break;case 49:invalid.lanes[0].sourceHeapKnown=0;break;
            case 50:invalid.lanes[0].sourceVisible=1;break;case 51:invalid.lanes[0].destinationHeapKnown=0;break;
            case 52:invalid.lanes[0].destinationVisible=2;break;case 53:invalid.lanes[0].source.bytes=0;break;
            case 54:invalid.lanes[0].source.abi=2;break;case 55:invalid.lanes[0].source.kind=2;break;
            case 56:++invalid.lanes[0].source.heapId;break;case 57:invalid.lanes[0].source.resourceId=0;break;
            case 58:invalid.lanes[0].source.canonicalIdentity=0;break;case 59:invalid.lanes[0].source.revision=firstFailure.serial+1;break;
            case 60:invalid.lanes[0].source.resource.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;break;
            case 61:invalid.lanes[0].source.resource.Format=DXGI_FORMAT_UNKNOWN;break;case 62:invalid.lanes[0].source.srv.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;break;
            case 63:invalid.lanes[0].source.defaultView=2;break;case 64:if(invalid.laneCount<beamrtResourceCopyLimit)invalid.lanes[invalid.laneCount].sourceCpu=1;else invalid.lanes[0].source.rtv.Format=DXGI_FORMAT_R32_FLOAT;break;
            case 65:invalid.lanes[0].previousDestination.bytes=1;break;case 66:invalid.heaps[invalid.heapCount].heapId=1;break;
            }
            if(beamrtResourceCopyFailureValid(invalid,firstFailure,status,selectedMode))std::cerr<<"Accepted malformed copy companion field "<<field<<std::endl;
            need(!beamrtResourceCopyFailureValid(invalid,firstFailure,status,selectedMode),"malformed copy failure companion accepted");
        }
        std::cout<<"67 malformed copy failure companions rejected; failedLane="<<copyFailure.failedLane<<", completedPrefix="<<copyFailure.appliedLanes<<'\n';
    }else need(!std::memcmp(&copyFailure,&emptyCopy,sizeof(emptyCopy)),"non-copy first failure invented a copy companion");
    const auto immutableCopy=copyFailure;
    if(pressureKind==2 || copyPressure){
        const auto beforeReap=status;
        need(beforeReap.views==beamrtResourceViewLimit && pressureHeaps.size()==1 && retainedReapResource && replacementHeap,
            "post-failure retirement baseline changed");
        const auto unchangedDiagnostics=[&]{
            need(!status.healthy && status.enabled && status.attachedSlots==10 && status.pressure==beforeReap.pressure
                && status.serial==beforeReap.serial && status.callbacks==beforeReap.callbacks,
                "diagnostic lifetime reaping resumed recording or changed failure counters");
            need(BeamRT_ResourcesFirstFailure(&failure,sizeof(failure))==S_OK && !std::memcmp(&failure,&firstFailure,sizeof(failure))
                && beamrtResourceFailureValid(failure,status),"diagnostic lifetime reaping changed immutable first failure");
            need(BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure))==copyResult
                && !std::memcmp(&copyFailure,&immutableCopy,sizeof(copyFailure))
                && beamrtResourceCopyFailureValid(copyFailure,failure,status,selectedMode),"diagnostic lifetime reaping changed immutable copy companion");
            missing(destination,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        };
        pressureHeaps.clear();hr(BeamRT_ResourcesStatus(&status,sizeof(status)));
        need(status.liveHeaps+1==beforeReap.liveHeaps && status.liveResources==beforeReap.liveResources && status.views==15,
            "Status did not reap dead capacity heap locations after poison");unchangedDiagnostics();
        retainedReapResource.Reset();hr(BeamRT_ResourcesStatus(&status,sizeof(status)));
        need(status.liveHeaps+1==beforeReap.liveHeaps && status.liveResources+1==beforeReap.liveResources && status.views==14,
            "Status did not reap dead resource associations after poison");unchangedDiagnostics();
        replacementHeap.Reset();hr(BeamRT_ResourcesStatus(&status,sizeof(status)));
        need(status.liveHeaps+2==beforeReap.liveHeaps && status.liveResources+1==beforeReap.liveResources && status.views==14,
            "Status did not reap final dead heap after its resource was removed");unchangedDiagnostics();
        hr(BeamRT_ResourcesStatus(&status,sizeof(status)));unchangedDiagnostics();
        pass("poisoned Status reaps real heap/resource deaths; original failure and copy topology remain immutable");
    }
    if(pressureKind==4){
        // Later native pressure calls are forwarded; poisoned metadata deliberately
        // does not resume recording them or claim a later pressure observation.
        for(unsigned i=0;i<beamrtResourceHeapLimit+1;++i)pressureHeaps.push_back(heap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,false));
        for(unsigned i=0;i<beamrtResourceObjectLimit+1;++i)pressureResources.push_back(resource(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ));
    }else overlap();
    hr(BeamRT_ResourcesStatus(&status,sizeof(status)));need(BeamRT_ResourcesFirstFailure(&failure,sizeof(failure))==S_OK
        && !std::memcmp(&failure,&firstFailure,sizeof(failure)) && status.overlaps==1
        && (pressureKind==4?!status.pressure:status.pressure==1),"later overlap or native pressure replaced first failure");
    device->CopyDescriptorsSimple(6,destination,slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure))==copyResult && !std::memcmp(&copyFailure,&immutableCopy,sizeof(copyFailure))
        && beamrtResourceCopyFailureValid(copyFailure,failure,status,selectedMode),"later forwarded copy replaced or invented first copy topology");
    pass("immutable first failure survives later overlap/native pressure forwarding");
    auto refusedToken=consumed;const auto refusedResult=BeamRT_ResourcesFinishDraw(&refusedToken,sizeof(refusedToken),&outputCheckpoint,sizeof(outputCheckpoint),&snapshot,sizeof(snapshot),probeBytes,&observation,sizeof(observation));
    need(refusedResult==E_INVALIDARG,"poisoned draw replay was not refused");
    need(!observation.intervalAccepted && beamrtResourceObservationValid(observation,snapshot,GetCurrentThreadId())
        && !std::memcmp(&observation.firstFailure,&firstFailure,sizeof(firstFailure)),"refused draw omitted immutable first failure");
    for(int field=0;field<17;++field){auto invalid=observation;auto& event=invalid.firstFailure;
        if(field==0)--event.bytes;if(field==1)event.abi=2;if(field==2)event.kind=BeamRTResourceFailureKindCount;
        if(field==3)event.method=BeamRTResourceMethodCount;if(field==4)event.callerThread=0;
        if(field==5)event.callbackOrdinal=event.observedCallbacks+1;if(field==6)event.observedCallbacks=invalid.status.callbacks+1;
        if(field==7)event.overlaps=invalid.status.overlaps+1;if(field==8)event.pressure=invalid.status.pressure+1;if(field==9)event.serial=invalid.status.serial+1;
        if(field==10)event.liveHeaps=beamrtResourceHeapLimit+1;if(field==11)event.liveResources=beamrtResourceObjectLimit+1;if(field==12)event.views=beamrtResourceViewLimit+1;
        if(field==13)event.drawTokens=beamrtResourceDrawLimit+1;if(field==14)event.reserved=1;if(field==15)event.reserved2=1;if(field==16)++event.capacityLimit;
        need(!beamrtResourceObservationValid(invalid,snapshot,GetCurrentThreadId()),"malformed first failure receipt accepted");
    }
    std::cout<<"17 malformed first failure receipts rejected\n";
    missing(destination,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);std::cout<<"Pressure kind: "<<pressureKind<<'\n';pass("fixed capacities/overlap fail-closed; originals forwarded");
    using CachedSRV=void(STDMETHODCALLTYPE*)(ID3D12Device*,ID3D12Resource*,const D3D12_SHADER_RESOURCE_VIEW_DESC*,D3D12_CPU_DESCRIPTOR_HANDLE);
    const auto cached=reinterpret_cast<CachedSRV>(*beamrtResourceSDKSlot(device.Get(),1));
    hr(BeamRT_ResourcesDisable());hr(BeamRT_ResourcesStatus(&status,sizeof(status)));
    for(auto& token:outstanding)if(token.ticket)hr(BeamRT_ResourcesCancelDraw(&token,sizeof(token)));
    need(!status.enabled && !status.attachedSlots && status.restoredSlots==10,"OFF did not restore all ten native slots");
    for(unsigned i=0;i<10;++i)need(*beamrtResourceSDKSlot(device.Get(),i)==originals[i],"OFF slot differs from saved original");
    const auto frozen=status.callbacks;cached(device.Get(),textures[0].Get(),&desc,slot(storage.Get(),0));
    hr(BeamRT_ResourcesStatus(&status,sizeof(status)));need(status.callbacks==frozen,"late cached callback recorded after OFF");missing(destination,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    need(BeamRT_ResourcesFirstFailure(&failure,sizeof(failure))==S_OK && !std::memcmp(&failure,&firstFailure,sizeof(failure)),"OFF or cached native forwarding replaced first failure");
    need(BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure))==copyResult && !std::memcmp(&copyFailure,&immutableCopy,sizeof(copyFailure))
        && beamrtResourceCopyFailureValid(copyFailure,failure,status,selectedMode),"OFF or cached forwarding changed first copy topology");
    gate.restore();
    device->CopyDescriptorsSimple(6,destination,slot(storage.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    render.begin();bind();render.list->DrawInstanced(3,1,0,0);pixel();hr(BeamRT_BindingsDisable());hr(BeamRT_PipelineAuditDisable());
    need(FAILED(BeamRT_ResourcesStart(device.Get())),"OFF session restarted");
    pass("OFF/restored native slots/late cached forward; GPU pixel 23");
    std::cout<<"Resource provenance fixture PASS "<<groups<<"/"<<groups<<"; six SRVs, one RTV, "<<(descriptorMode?"descriptor-only admissions, CBV unavailable":"CBV candidate")
        <<"; debug-layer="<<(debugEnabled?"enabled":"unavailable")<<"; no game proof\n";
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
