#define BEAMRT_PIPELINE_AUDIT_BUILD
#include "pipeline_audit.h"
#include <wrl/client.h>
#include <vector>
#include "pipeline_root_metadata.h"
#include <memory>
#include <cstring>
#include <new>
#ifdef BEAMRT_BINDING_EMBEDDED
#include "binding_handoff.h"
#endif
// Optional startup transport is absent from the standalone fixture DLL.
#ifdef BEAMRT_PIPELINE_HANDOFF
#include "pipeline_handoff.h"
#endif
using Microsoft::WRL::ComPtr;
extern "C" PVOID* beamrtPipelineSDKSlot(void*,void*,unsigned);
using RootCall=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,UINT,const void*,SIZE_T,REFIID,void**);
using GraphicsCall=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,const D3D12_GRAPHICS_PIPELINE_STATE_DESC*,REFIID,void**);
using StreamCall=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device2*,const D3D12_PIPELINE_STATE_STREAM_DESC*,REFIID,void**);
struct Slot {
    PVOID* address=nullptr;PVOID original=nullptr,replacement=nullptr;HMODULE tableModule=nullptr,codeModule=nullptr;bool attached=false;
    ~Slot(){if(codeModule)FreeLibrary(codeModule);if(tableModule)FreeLibrary(tableModule);}
};
struct Audit {
    Slot slots[3]; // Pending-only destruction releases leases AFTER COM members.
    ComPtr<ID3D12Device> device;ComPtr<ID3D12Device2> device2;ComPtr<IUnknown> identity;
    std::vector<uint8_t> vertex,pixel,matchedRootBytes;
    RootMetadata roots;
    ComPtr<ID3D12RootSignature> matchedRoot;ComPtr<ID3D12PipelineState> matchedPipeline;
    BeamRTPipelineAuditInfo info{};
};
static PVOID volatile published=nullptr;
static SRWLOCK auditLock=SRWLOCK_INIT;
struct Lock {Lock(){AcquireSRWLockExclusive(&auditLock);}~Lock(){ReleaseSRWLockExclusive(&auditLock);}};
struct RestoreError {DWORD value;~RestoreError(){SetLastError(value);}};
static Audit* audit(){return static_cast<Audit*>(InterlockedCompareExchangePointer(&published,nullptr,nullptr));}
static bool owns(Audit& a,IUnknown* object){ComPtr<IUnknown> identity;return object && SUCCEEDED(object->QueryInterface(IID_PPV_ARGS(&identity))) && identity.Get()==a.identity.Get();}
static bool child(Audit& a,ID3D12DeviceChild* object){ComPtr<ID3D12Device> owner;return object && SUCCEEDED(object->GetDevice(IID_PPV_ARGS(&owner))) && owns(a,owner.Get());}
static bool same(const D3D12_SHADER_BYTECODE& code,const std::vector<uint8_t>& expected){return code.BytecodeLength==expected.size()
    && code.pShaderBytecode && std::memcmp(code.pShaderBytecode,expected.data(),expected.size())==0;}
static void poison(Audit& a,BeamRTPipelineFailure reason,HRESULT result){
    if(!a.info.failureReason){a.info.failureReason=static_cast<uint32_t>(reason);a.info.failureResult=result;}
    a.info.healthy=0;a.info.creationMatchAvailable=0;
}
static void refresh(Audit& a){
    a.roots.prune();
    a.info.cachedLayouts=static_cast<uint32_t>(a.roots.cache.size());
    a.info.liveLayouts=a.roots.budget.layouts.load();a.info.liveRootTags=a.roots.budget.tags.load();
    a.info.metadataBytes=a.roots.budget.bytes.load();a.info.peakMetadataBytes=a.roots.budget.peak.load();
}
static void increment(uint64_t& value,Audit& a){if(value==UINT64_MAX)poison(a,BeamRTPipelineFailure::counterOverflow,E_FAIL);else ++value;}
template<class F>static void observe(Audit& a,IUnknown* device,F action){
    try{Lock lock;if(a.info.enabled && a.info.healthy && owns(a,device)){action();refresh(a);
#ifdef BEAMRT_PIPELINE_HANDOFF
        BeamRT_PipelinePublishProgress(a.info);
#endif
    }}
    catch(const std::bad_alloc&){Lock lock;poison(a,BeamRTPipelineFailure::allocation,E_OUTOFMEMORY);refresh(a);
#ifdef BEAMRT_PIPELINE_HANDOFF
        BeamRT_PipelinePublishProgress(a.info);
#endif
    }
    catch(...){Lock lock;poison(a,BeamRTPipelineFailure::metadataException,E_FAIL);refresh(a);
#ifdef BEAMRT_PIPELINE_HANDOFF
        BeamRT_PipelinePublishProgress(a.info);
#endif
    } // Original native result never replaced.
}
static HRESULT STDMETHODCALLTYPE rootCall(ID3D12Device* self,UINT node,const void* bytes,SIZE_T count,REFIID iid,void** output){
    auto a=audit();const HRESULT result=reinterpret_cast<RootCall>(a->slots[0].original)(self,node,bytes,count,iid,output);
    RestoreError error{GetLastError()};
    observe(*a,self,[&]{increment(a->info.rootsObserved,*a);if(FAILED(result) || !output || !*output)return;
        if(!a->info.healthy)return;
        if(!bytes || !count || count>65536){poison(*a,BeamRTPipelineFailure::invalidRootBytes,E_INVALIDARG);return;}
        ComPtr<ID3D12RootSignature> root;const auto queried=static_cast<IUnknown*>(*output)->QueryInterface(IID_PPV_ARGS(&root));
        if(FAILED(queried)){poison(*a,BeamRTPipelineFailure::rootInterface,queried);return;}
        if(!child(*a,root.Get())){poison(*a,BeamRTPipelineFailure::rootOwner,E_INVALIDARG);return;}
        ComPtr<RootEvidenceInterface> existing;const auto read=rootEvidence(a->roots.budget,root.Get(),existing);
        if(FAILED(read)){poison(*a,BeamRTPipelineFailure::rootEvidenceConflict,read);return;}
        const auto attached=a->roots.attach(root.Get(),a,bytes,static_cast<uint32_t>(count),a->info.cacheEvictions);
        if(attached==S_FALSE){increment(a->info.budgetSkipped,*a);return;}
        if(FAILED(attached)){poison(*a,BeamRTPipelineFailure::rootEvidenceWrite,attached);return;}
        increment(a->info.rootsTagged,*a);
    });return result;
}
static HRESULT STDMETHODCALLTYPE graphicsCall(ID3D12Device* self,const D3D12_GRAPHICS_PIPELINE_STATE_DESC* desc,REFIID iid,void** output){
    auto a=audit();const HRESULT result=reinterpret_cast<GraphicsCall>(a->slots[1].original)(self,desc,iid,output);
    RestoreError error{GetLastError()};
    bool firstMatch=false;
    observe(*a,self,[&]{increment(a->info.graphicsObserved,*a);
        if(!a->info.healthy || FAILED(result) || !desc || !output || !*output || !same(desc->VS,a->vertex) || !same(desc->PS,a->pixel))return;
        increment(a->info.shaderMatches,*a);
        if(!a->info.healthy)return;
        if(!desc->pRootSignature){increment(a->info.unknownRootMatches,*a);return;}
        if(!child(*a,desc->pRootSignature)){poison(*a,BeamRTPipelineFailure::rootOwner,E_INVALIDARG);return;}
        ComPtr<RootEvidenceInterface> root;const auto evidence=rootEvidence(a->roots.budget,desc->pRootSignature,root);
        if(evidence==S_FALSE){increment(a->info.unknownRootMatches,*a);return;}
        if(FAILED(evidence)){poison(*a,BeamRTPipelineFailure::rootEvidenceConflict,evidence);return;}
        const uint8_t* data=nullptr;uint32_t size=0;const auto read=root->read(a,&data,&size);
        if(FAILED(read) || !data || !size || size>65536){poison(*a,BeamRTPipelineFailure::rootEvidenceConflict,FAILED(read)?read:E_INVALIDARG);return;}
        if(a->matchedPipeline)return;
        if(desc->GS.BytecodeLength || desc->HS.BytecodeLength || desc->DS.BytecodeLength || desc->NumRenderTargets>8){poison(*a,BeamRTPipelineFailure::pipelineShape,E_INVALIDARG);return;}
        ComPtr<ID3D12PipelineState> pipeline;
        const auto queried=static_cast<IUnknown*>(*output)->QueryInterface(IID_PPV_ARGS(&pipeline));
        if(FAILED(queried)){poison(*a,BeamRTPipelineFailure::pipelineInterface,queried);return;}
        if(!child(*a,pipeline.Get())){poison(*a,BeamRTPipelineFailure::pipelineOwner,E_INVALIDARG);return;}
        a->matchedRootBytes.assign(data,data+size);a->matchedRoot=desc->pRootSignature;a->matchedPipeline=std::move(pipeline);
        a->info.rootBytes=static_cast<uint32_t>(a->matchedRootBytes.size());a->info.renderTargetCount=desc->NumRenderTargets;
        a->info.sampleCount=desc->SampleDesc.Count;std::memcpy(a->info.renderTargetFormats,desc->RTVFormats,sizeof(desc->RTVFormats));
        a->info.creationMatchAvailable=1;firstMatch=true;refresh(*a);
#ifdef BEAMRT_PIPELINE_HANDOFF
        BeamRT_PipelinePublishMatch(a->info,a->matchedRootBytes.data(),static_cast<uint32_t>(a->matchedRootBytes.size()));
#endif
    });
#ifdef BEAMRT_BINDING_EMBEDDED
    if(firstMatch)BeamRT_BindingBridgeAuditMatch();
#else
    (void)firstMatch;
#endif
    return result;
}
static HRESULT STDMETHODCALLTYPE streamCall(ID3D12Device2* self,const D3D12_PIPELINE_STATE_STREAM_DESC* desc,REFIID iid,void** output){
    auto a=audit();const HRESULT result=reinterpret_cast<StreamCall>(a->slots[2].original)(self,desc,iid,output);
    RestoreError error{GetLastError()};
    // Count explicitly; never interpret opaque streams as the legacy descriptor
    // or invent a root/bytecode match. Legacy creation matches remain scoped.
    observe(*a,self,[&]{increment(a->info.unsupportedStreams,*a);});return result;
}
static HRESULT exchange(Slot& slot,PVOID expected,PVOID replacement,bool& changed){
    changed=false;MEMORY_BASIC_INFORMATION memory{};
    if(!VirtualQuery(slot.address,&memory,sizeof(memory)) || memory.AllocationBase!=slot.tableModule || memory.State!=MEM_COMMIT || memory.Type!=MEM_IMAGE
        || (memory.Protect!=PAGE_READONLY && memory.Protect!=PAGE_READWRITE && memory.Protect!=PAGE_WRITECOPY))return E_ACCESSDENIED;
    DWORD old=0;if(!VirtualProtect(slot.address,sizeof(PVOID),PAGE_READWRITE,&old))return HRESULT_FROM_WIN32(GetLastError());
    changed=InterlockedCompareExchangePointer(slot.address,replacement,expected)==expected;
    DWORD ignored=0;const BOOL restored=VirtualProtect(slot.address,sizeof(PVOID),old,&ignored);
    if(!restored)return HRESULT_FROM_WIN32(GetLastError());return changed?S_OK:HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
}
extern "C" HRESULT WINAPI BeamRT_PipelineAuditStart(ID3D12Device* device,const BeamRTPipelineAuditConfig* config){
    if(!device || !config || config->bytes!=sizeof(*config) || config->abi!=1 || config->reserved[0] || config->reserved[1]
        || !config->vertex || !config->pixel || !config->vertexBytes || !config->pixelBytes
        || config->vertexBytes>16*1024*1024 || config->pixelBytes>16*1024*1024)return E_INVALIDARG;
    Lock lock;if(audit())return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
    std::unique_ptr<Audit> pending(new(std::nothrow) Audit());if(!pending)return E_OUTOFMEMORY;
    try{
        auto& a=*pending;a.device=device;if(FAILED(device->GetDeviceRemovedReason()) || FAILED(a.device.As(&a.identity)))return DXGI_ERROR_DEVICE_REMOVED;
        a.device.As(&a.device2);
        a.vertex.assign(static_cast<const uint8_t*>(config->vertex),static_cast<const uint8_t*>(config->vertex)+config->vertexBytes);
        a.pixel.assign(static_cast<const uint8_t*>(config->pixel),static_cast<const uint8_t*>(config->pixel)+config->pixelBytes);
        a.info.bytes=sizeof(a.info);a.info.abi=beamrtPipelineAuditInfoABI;a.info.healthy=1;a.info.ownerThread=GetCurrentThreadId();
        PVOID replacements[]={reinterpret_cast<PVOID>(rootCall),reinterpret_cast<PVOID>(graphicsCall),reinterpret_cast<PVOID>(streamCall)};
        const unsigned count=a.device2?3u:2u;
        for(unsigned i=0;i<count;++i){auto& slot=a.slots[i];slot.address=beamrtPipelineSDKSlot(device,a.device2.Get(),i);
            if(!slot.address || reinterpret_cast<ULONG_PTR>(slot.address)%alignof(PVOID))return E_INVALIDARG;
            slot.original=*slot.address;slot.replacement=replacements[i];
            if(!slot.original || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(slot.address),&slot.tableModule)
                || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(slot.original),&slot.codeModule))return E_ACCESSDENIED;
            for(unsigned prior=0;prior<i;++prior)if(slot.address==a.slots[prior].address)return E_INVALIDARG;
        }
        // Publish immutable originals before any exposure. A partially installed
        // session remains disabled and resident; no late callback loses its code.
        auto resident=pending.release();InterlockedExchangePointer(&published,resident);
        for(unsigned i=0;i<count;++i){bool changed=false;auto& slot=resident->slots[i];
            const HRESULT result=exchange(slot,slot.original,slot.replacement,changed);slot.attached=changed;
            if(changed)++resident->info.attachedSlots;
            if(FAILED(result)){poison(*resident,BeamRTPipelineFailure::slotInstall,result);return result;}
        }
        resident->info.enabled=1;return S_OK;
    }catch(...){if(auto resident=audit())poison(*resident,BeamRTPipelineFailure::allocation,E_OUTOFMEMORY);return E_OUTOFMEMORY;}
}
extern "C" HRESULT WINAPI BeamRT_PipelineAuditQuery(BeamRTPipelineAuditInfo* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};Lock lock;auto a=audit();
    if(!a)return HRESULT_FROM_WIN32(ERROR_NOT_READY);refresh(*a);*out=a->info;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_PipelineAuditReadMatch(void* bytes,uint32_t capacity,uint32_t* actual,ID3D12RootSignature** root,ID3D12PipelineState** pipeline){
    if(actual)*actual=0;if(root)*root=nullptr;if(pipeline)*pipeline=nullptr;
    if(!bytes || !actual || !root || !pipeline)return E_INVALIDARG;Lock lock;auto a=audit();
    if(!a || !a->info.enabled || !a->info.healthy || !a->info.creationMatchAvailable)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    const auto removed=a->device->GetDeviceRemovedReason();
    if(FAILED(removed)){poison(*a,BeamRTPipelineFailure::deviceRemoved,removed);return removed;}
    if(capacity<a->matchedRootBytes.size())return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    std::memcpy(bytes,a->matchedRootBytes.data(),a->matchedRootBytes.size());*actual=static_cast<uint32_t>(a->matchedRootBytes.size());
    *root=a->matchedRoot.Get();(*root)->AddRef();*pipeline=a->matchedPipeline.Get();(*pipeline)->AddRef();return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_PipelineAuditDisable(){
    Lock lock;auto a=audit();if(!a)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    if(a->info.ownerThread!=GetCurrentThreadId())return HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED);
    a->info.enabled=0;a->info.creationMatchAvailable=0;HRESULT first=S_OK;
    for(auto& slot:a->slots)if(slot.attached){bool changed=false;const HRESULT result=exchange(slot,slot.replacement,slot.original,changed);
        if(changed){slot.attached=false;--a->info.attachedSlots;++a->info.restoredSlots;}
        if(FAILED(result)){poison(*a,BeamRTPipelineFailure::slotRestore,result);if(SUCCEEDED(first))first=result;}}
    // Originals, modules, shader copies and matched candidate stay resident.
    // Other roots own their tags; late tag destruction needs no audit lock.
    return first;
}
