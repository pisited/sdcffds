#define BEAMRT_RESOURCE_BUILD
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "resource_tracker.h"
#include "resource_record.h"
#include "resource_copy_diagnostics.h"
#include "resource_view_storage.h"
#include "resource_storage_validation.h"
#include <wrl/client.h>
#include <atomic>
#include <array>
#include <memory>
#include <mutex>
#include <cstring>
#include <cmath>
using Microsoft::WRL::ComPtr;
extern "C" void** beamrtResourceSDKSlot(void*,unsigned);
// Implementation-only types must not coalesce with the binding/audit types
// when these translation units are linked into one startup DLL.
namespace {
static constexpr GUID resourceGuid={0x72fc9cf8,0xa99d,0x468b,{0xa9,0x70,0x62,0x90,0x46,0x8f,0x6b,0xa8}};
static constexpr GUID heapGuid={0x54279c18,0x7435,0x4d79,{0x8a,0xb1,0xc4,0x82,0x15,0x8e,0xb5,0xe9}};
struct Life {std::atomic<bool> alive{true};uint64_t id=0;};
class LifeTag final:public IUnknown {
    volatile LONG refs=1;std::shared_ptr<Life> life;
public:
    explicit LifeTag(std::shared_ptr<Life> value):life(std::move(value)){}
    ~LifeTag(){life->alive.store(false);}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out)override{
        if(!out)return E_POINTER;*out=nullptr;if(iid!=__uuidof(IUnknown))return E_NOINTERFACE;*out=static_cast<IUnknown*>(this);AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef()override{return static_cast<ULONG>(InterlockedIncrement(&refs));}
    ULONG STDMETHODCALLTYPE Release()override{const auto n=InterlockedDecrement(&refs);if(!n)delete this;return static_cast<ULONG>(n);}
};
struct Object {std::shared_ptr<Life> life;uint64_t identity=0,address=0;D3D12_RESOURCE_DESC desc{};};
struct Heap {std::shared_ptr<Life> life;uint64_t identity=0,cpu=0,gpu=0;uint32_t count=0,stride=0;D3D12_DESCRIPTOR_HEAP_TYPE type{};bool visible=false;};
namespace viewStore=beamrt::resource_view_storage;
static_assert(beamrtResourceViewLimit==viewStore::legacyLocationLimit,"public ABI remains at the legacy view limit");
struct Slot {void** address=nullptr;void* original=nullptr;HMODULE table=nullptr,code=nullptr;bool attached=false;};
struct Context {
    ComPtr<ID3D12Device> device;ComPtr<IUnknown> identity;
    uint32_t mode=beamrtResourceAllAllocations;
    uint32_t profile=beamrtResourceStorageLegacy;
    Slot slots[10]{};std::atomic<unsigned> slotsPublished{0},inFlight{0};
    std::mutex mutex;BeamRTResourceStatus status{};uint64_t nextId=0;
    BeamRTResourceFailure firstFailure{};
    BeamRTResourceStorageFailure storageFailure{};
    BeamRTResourceCopyFailure copyFailure{};
    // Reused only under mutex. Keep the 29 KiB diagnostic plan off native
    // descriptor-callback stacks; the separately frozen record never aliases it.
    BeamRTResourceCopyFailure pendingCopy{};
    uint32_t method=BeamRTResourceMethodNone;uint64_t callbackOrdinal=0;
    std::array<Heap,beamrtResourceHeapLimit> heaps{};
    std::array<Object,beamrtResourceObjectLimit> objects{};
    viewStore::Store views;
    std::array<BeamRTResourceDrawToken,beamrtResourceDrawLimit> draws{};uint64_t nextDrawTicket=0;
    explicit Context(uint32_t selectedProfile):profile(selectedProfile),views(selectedProfile){}
};
static PVOID volatile published=nullptr;static std::mutex control;
static Context* context(){return static_cast<Context*>(InterlockedCompareExchangePointer(&published,nullptr,nullptr));}
static bool live(const std::shared_ptr<Life>& l){return l && l->alive.load();}
static bool owns(Context& c,ID3D12Device* d){ComPtr<IUnknown> id;return d && SUCCEEDED(d->QueryInterface(IID_PPV_ARGS(&id))) && id.Get()==c.identity.Get();}
static bool child(Context& c,ID3D12DeviceChild* o){ComPtr<ID3D12Device> d;return o && SUCCEEDED(o->GetDevice(IID_PPV_ARGS(&d))) && owns(c,d.Get());}
// Every site below is inside the existing metadata mutex. Site data never spans
// native execution or requires TLS/a second lock; originals still run unlocked.
struct Site {
    Context& c;uint32_t method;uint64_t ordinal;
    Site(Context& value,uint32_t m,uint64_t o):c(value),method(c.method),ordinal(c.callbackOrdinal){c.method=m;c.callbackOrdinal=o;}
    ~Site(){c.method=method;c.callbackOrdinal=ordinal;}
};
static BeamRTResourceStorageSnapshot storageSnapshot(const Context& c){
    const auto held=c.views.stats();BeamRTResourceStorageSnapshot out{};out.bytes=sizeof(out);out.abi=2;out.profile=c.profile;
    out.locationLimit=beamrtResourceLocationLimit(c.profile);out.payloadLimit=beamrtResourceStoragePayloadLimit;out.byteLimit=beamrtResourceStorageByteLimit;
    out.locations=held.locations;out.payloads=held.payloads;out.usedBytes=held.usedBytes;
    out.directoryBytes=beamrtResourceDirectoryBytes(c.profile);out.locationBytes=beamrtResourceLocationBytes(c.profile);
    out.heaps=held.heaps;out.heapLimit=beamrtResourceStorageHeapLimit(c.profile);return out;
}
static void fail(Context& c,uint32_t kind,uint32_t limit=0,uint32_t activeAtEntry=UINT_MAX,uint32_t attempted=0){
    c.status.healthy=0;if(c.firstFailure.kind)return;
    auto& f=c.firstFailure;f={};f.bytes=sizeof(f);f.abi=beamrtResourceStatusABI(c.profile);f.kind=kind;f.method=c.method;
    f.callerThread=GetCurrentThreadId();f.activeCallbacks=activeAtEntry==UINT_MAX?c.inFlight.load():activeAtEntry;f.capacityLimit=limit;f.attemptedCount=attempted?attempted:limit?limit+1:0;
    f.callbackOrdinal=c.callbackOrdinal;f.observedCallbacks=c.status.callbacks;f.overlaps=c.status.overlaps;f.pressure=c.status.pressure;f.serial=c.status.serial;
    for(const auto& h:c.heaps)if(live(h.life))++f.liveHeaps;
    for(const auto& o:c.objects)if(live(o.life))++f.liveResources;
    f.views=c.views.occupied();
    for(const auto& d:c.draws)if(d.ticket)++f.drawTokens;
    auto& storage=c.storageFailure;storage={};storage.bytes=sizeof(storage);storage.abi=2;storage.present=1;storage.atFailure=storageSnapshot(c);
    if(beamrtResourceStorageCapacityKind(kind)){
        const auto held=c.views.failure();storage.cause=kind==BeamRTResourceFailureViewCapacity?beamrtResourceStorageFailureLocations:
            kind==BeamRTResourceFailureViewPayloadCapacity?beamrtResourceStorageFailurePayloads:beamrtResourceStorageFailureBytes;
        if(kind==BeamRTResourceFailureViewHeapCapacity)storage.cause=beamrtResourceStorageFailureHeaps;
        storage.attemptedLocations=held.attemptedLocations;storage.attemptedPayloads=held.attemptedPayloads;storage.requiredBytes=held.requiredBytes;
        storage.attemptedHeaps=held.attemptedHeaps;
    }
}
static bool tick(Context& c,uint64_t& value){if(value==UINT64_MAX){fail(c,BeamRTResourceFailureCounterOverflow);return false;}++value;return true;}
static void pressure(Context& c,uint32_t kind,uint32_t limit,uint32_t attempted=0){tick(c,c.status.pressure);fail(c,kind,limit,UINT_MAX,attempted);}
struct Call {
    Context* c;bool owner;uint32_t method;uint64_t ordinal=0;
    explicit Call(ID3D12Device* d,uint32_t m):c(context()),owner(c && owns(*c,d)),method(m){
        if(!owner)return;const auto active=c->inFlight.fetch_add(1);std::lock_guard<std::mutex> g(c->mutex);
        if(c->status.enabled){ordinal=c->status.callbacks==UINT64_MAX?UINT64_MAX:c->status.callbacks+1;Site site(*c,method,ordinal);
            tick(*c,c->status.callbacks);if(active){tick(*c,c->status.overlaps);fail(*c,BeamRTResourceFailureOverlap,0,active+1);}}
    }
    ~Call(){if(owner)c->inFlight.fetch_sub(1);}
};
struct LastError {DWORD value;~LastError(){SetLastError(value);}};
template<class F>static F original(void* d,unsigned method){
    auto c=context();auto address=beamrtResourceSDKSlot(d,method);
    if(c && method<c->slotsPublished.load() && c->slots[method].address==address)return reinterpret_cast<F>(c->slots[method].original);
    std::terminate(); // A cached callback from an incompatible table is unsupported.
}
template<class F>static void observe(Call& call,F action)noexcept{
    if(!call.owner)return;
    try {std::lock_guard<std::mutex> g(call.c->mutex);Site site(*call.c,call.method,call.ordinal);if(call.c->status.enabled && call.c->status.healthy)action(*call.c);}
    catch(...){std::lock_guard<std::mutex> g(call.c->mutex);Site site(*call.c,call.method,call.ordinal);fail(*call.c,BeamRTResourceFailureMetadataException);}
}
static bool storeTag(Context& c,ID3D12Object* object,const GUID& guid,std::shared_ptr<Life>& life){
    UINT size=0;if(object->GetPrivateData(guid,&size,nullptr)!=DXGI_ERROR_NOT_FOUND){fail(c,BeamRTResourceFailureTagPresent);return false;}
    if(!tick(c,c.nextId))return false;auto value=std::make_shared<Life>();value->id=c.nextId;
    ComPtr<IUnknown> tag;tag.Attach(new LifeTag(value));
    if(FAILED(object->SetPrivateDataInterface(guid,tag.Get()))){fail(c,BeamRTResourceFailureTagStore);return false;}
    life=std::move(value);return true;
}
static Object* track(Context& c,ID3D12Resource* resource){
    if(!child(c,resource))return nullptr;ComPtr<IUnknown> id;if(FAILED(resource->QueryInterface(IID_PPV_ARGS(&id)))){fail(c,BeamRTResourceFailureResourceIdentity);return nullptr;}
    const auto identity=reinterpret_cast<uint64_t>(id.Get());
    for(auto& o:c.objects)if(live(o.life) && o.identity==identity)return &o;
    for(auto& o:c.objects)if(!live(o.life)){
        // Retire the old ID BEFORE replacing its registry slot. Otherwise the
        // dead lifetime becomes undiscoverable by the registry-based reaper.
        if(o.life && c.views.reapDeadResource(o.life->id)!=viewStore::Result::Ok){fail(c,BeamRTResourceFailureMetadataException);return nullptr;}
        Object next;next.identity=identity;next.desc=resource->GetDesc();
        next.address=next.desc.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER?resource->GetGPUVirtualAddress():0;
        if(!storeTag(c,resource,resourceGuid,next.life))return nullptr;o=std::move(next);return &o;
    }
    pressure(c,BeamRTResourceFailureObjectCapacity,beamrtResourceObjectLimit);return nullptr;
}
static void reap(Context& c){
    // Aggregate counts may shrink after first failure, but no descriptor becomes
    // readable and neither immutable failure nor revision watermark is reset.
    for(const auto& h:c.heaps)if(h.life && !live(h.life))c.views.reapDeadHeap(h.life->id);
    for(const auto& o:c.objects)if(o.life && !live(o.life))c.views.reapDeadResource(o.life->id);
}
static void createdHeap(Context& c,ID3D12DescriptorHeap* object){
    if(!child(c,object))return;const auto d=object->GetDesc();
    if(d.Type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV && d.Type!=D3D12_DESCRIPTOR_HEAP_TYPE_RTV)return;
    ComPtr<IUnknown> id;if(FAILED(object->QueryInterface(IID_PPV_ARGS(&id)))){fail(c,BeamRTResourceFailureHeapIdentity);return;}
    Heap next;next.identity=reinterpret_cast<uint64_t>(id.Get());next.type=d.Type;next.count=d.NumDescriptors;
    next.stride=c.device->GetDescriptorHandleIncrementSize(d.Type);next.visible=(d.Flags&D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)!=0;
    next.cpu=object->GetCPUDescriptorHandleForHeapStart().ptr;if(next.visible)next.gpu=object->GetGPUDescriptorHandleForHeapStart().ptr;
    const auto span=uint64_t(next.count)*next.stride;
    if(!next.count || !next.stride || !next.cpu || span>UINT64_MAX-next.cpu || (next.visible && (!next.gpu || span>UINT64_MAX-next.gpu))){fail(c,BeamRTResourceFailureHeapExtent);return;}
    for(const auto& h:c.heaps)if(live(h.life) && h.type==next.type){
        const auto oldSpan=uint64_t(h.count)*h.stride;
        if(next.cpu<h.cpu+oldSpan && h.cpu<next.cpu+span){fail(c,BeamRTResourceFailureHeapAlias);return;}
    }
    reap(c);for(auto& h:c.heaps)if(!live(h.life)){if(storeTag(c,object,heapGuid,next.life))h=std::move(next);return;}
    pressure(c,BeamRTResourceFailureHeapCapacity,beamrtResourceHeapLimit);
}
static Heap* locate(Context& c,uint64_t cpu,D3D12_DESCRIPTOR_HEAP_TYPE type,uint64_t& index){
    Heap* result=nullptr;
    for(auto& h:c.heaps)if(live(h.life) && h.type==type && cpu>=h.cpu && h.stride && (cpu-h.cpu)%h.stride==0 && (cpu-h.cpu)/h.stride<h.count){
        if(result){fail(c,BeamRTResourceFailureDescriptorAlias);return nullptr;}result=&h;index=(cpu-h.cpu)/h.stride;
    }
    return result;
}
static bool find(Context& c,uint64_t heap,uint64_t index,BeamRTResourceView& out){
    out={};if(index>UINT32_MAX){fail(c,BeamRTResourceFailureMetadataException);return false;}
    const auto result=c.views.get(heap,static_cast<uint32_t>(index),out);
    if(result==viewStore::Result::Ok)return true;if(result==viewStore::Result::NotFound)return false;
    // Never silently turn an internal storage refusal into an unknown view.
    fail(c,BeamRTResourceFailureMetadataException);return false;
}
static void clear(Context& c,uint64_t cpu,D3D12_DESCRIPTOR_HEAP_TYPE type){
    uint64_t index=0;auto h=locate(c,cpu,type,index);if(h){
        if(index>UINT32_MAX || c.views.erase(h->life->id,static_cast<uint32_t>(index))!=viewStore::Result::Ok)fail(c,BeamRTResourceFailureMetadataException);
    }
}
static void write(Context& c,uint64_t cpu,D3D12_DESCRIPTOR_HEAP_TYPE type,const BeamRTResourceView& value){
    uint64_t index=0;auto h=locate(c,cpu,type,index);if(!h)return;
    clear(c,cpu,type);if(!c.status.healthy || !value.resourceId)return;reap(c);
    if(index>UINT32_MAX){fail(c,BeamRTResourceFailureMetadataException);return;}
    const auto result=c.views.put(h->life->id,static_cast<uint32_t>(index),value);if(result==viewStore::Result::Ok)return;
    if(result==viewStore::Result::Capacity){
        const auto held=c.views.failure();
        if(held.cause==viewStore::Cause::LocationCapacity){pressure(c,BeamRTResourceFailureViewCapacity,beamrtResourceLocationLimit(c.profile),held.attemptedLocations);return;}
        if(c.profile!=beamrtResourceStorageLegacy && held.cause==viewStore::Cause::PayloadCapacity){pressure(c,BeamRTResourceFailureViewPayloadCapacity,beamrtResourceStoragePayloadLimit,held.attemptedPayloads);return;}
        if(c.profile!=beamrtResourceStorageLegacy && held.cause==viewStore::Cause::ByteCapacity){pressure(c,BeamRTResourceFailureViewByteCapacity,beamrtResourceStorageByteLimit,held.requiredBytes);return;}
        if(c.profile==beamrtResourceStorageInterned && held.cause==viewStore::Cause::HeapCapacity){pressure(c,BeamRTResourceFailureViewHeapCapacity,32,held.attemptedHeaps);return;}
    }
    fail(c,BeamRTResourceFailureMetadataException);
}
static bool supportedTexture(const D3D12_RESOURCE_DESC& d){
    return d.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D && d.DepthOrArraySize==1 && d.SampleDesc.Count==1 && d.Width && d.Height && d.MipLevels
        && (d.Format==DXGI_FORMAT_R32G32B32A32_FLOAT || d.Format==DXGI_FORMAT_R32_FLOAT || d.Format==DXGI_FORMAT_R8G8B8A8_UNORM);
}
static void srvWritten(Context& c,ID3D12Resource* resource,const D3D12_SHADER_RESOURCE_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE dst){
    clear(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);Object* o=nullptr;D3D12_RESOURCE_DESC resourceDesc{};
    if(c.mode==beamrtResourceDescriptorTextures){
        uint64_t index=0;if(!locate(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,index) || !child(c,resource))return;
        resourceDesc=resource->GetDesc();
    }else {o=track(c,resource);if(!o)return;resourceDesc=o->desc;}
    if(!supportedTexture(resourceDesc))return;
    BeamRTResourceView value{};value.bytes=sizeof(value);value.abi=beamrtResourceABI;value.kind=1;value.defaultView=desc?0u:1u;
    value.resource=resourceDesc;
    if(desc){value.srv=*desc;const auto& v=desc->Texture2D;
        if(desc->ViewDimension!=D3D12_SRV_DIMENSION_TEXTURE2D || desc->Format!=resourceDesc.Format || desc->Shader4ComponentMapping!=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING
            || v.MostDetailedMip>=resourceDesc.MipLevels || !v.MipLevels || (v.MipLevels!=UINT_MAX && v.MipLevels>resourceDesc.MipLevels-v.MostDetailedMip)
            || v.PlaneSlice || !std::isfinite(v.ResourceMinLODClamp) || v.ResourceMinLODClamp<0)return;
    }else {value.srv.Format=resourceDesc.Format;value.srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;value.srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;value.srv.Texture2D.MipLevels=resourceDesc.MipLevels;}
    if(!o)o=track(c,resource);if(!o)return;
    value.resourceId=o->life->id;value.canonicalIdentity=o->identity;
    if(!tick(c,c.status.serial))return;value.revision=c.status.serial;write(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,value);
}
static void rtvWritten(Context& c,ID3D12Resource* resource,const D3D12_RENDER_TARGET_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE dst){
    clear(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_RTV);Object* o=nullptr;D3D12_RESOURCE_DESC resourceDesc{};
    if(c.mode==beamrtResourceDescriptorTextures){
        uint64_t index=0;if(!locate(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_RTV,index) || !child(c,resource))return;
        resourceDesc=resource->GetDesc();
    }else {o=track(c,resource);if(!o)return;resourceDesc=o->desc;}
    if(!supportedTexture(resourceDesc) || !(resourceDesc.Flags&D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET))return;
    BeamRTResourceView value{};value.bytes=sizeof(value);value.abi=beamrtResourceABI;value.kind=2;value.defaultView=desc?0u:1u;
    value.resource=resourceDesc;
    if(desc){value.rtv=*desc;if(desc->ViewDimension!=D3D12_RTV_DIMENSION_TEXTURE2D || desc->Format!=resourceDesc.Format || desc->Texture2D.MipSlice>=resourceDesc.MipLevels || desc->Texture2D.PlaneSlice)return;}
    else {value.rtv.Format=resourceDesc.Format;value.rtv.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D;}
    if(!o)o=track(c,resource);if(!o)return;
    value.resourceId=o->life->id;value.canonicalIdentity=o->identity;
    if(!tick(c,c.status.serial))return;value.revision=c.status.serial;write(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_RTV,value);
}
static bool flatten(Context& c,UINT ranges,const D3D12_CPU_DESCRIPTOR_HANDLE* starts,const UINT* sizes,D3D12_DESCRIPTOR_HEAP_TYPE type,std::array<uint64_t,beamrtResourceCopyLimit>& result,UINT& count,BeamRTResourceCopyRange* recorded){
    count=0;if(ranges>beamrtResourceCopyLimit || (ranges && !starts))return false;
    const auto stride=c.device->GetDescriptorHandleIncrementSize(type);if(!stride)return false;
    for(UINT i=0;i<ranges;++i){const auto n=sizes?sizes[i]:1u;if(n>beamrtResourceCopyLimit-count)return false;
        recorded[i]={starts[i].ptr,n,0};
        for(UINT j=0;j<n;++j){const auto offset=uint64_t(j)*stride;if(offset>UINT64_MAX-starts[i].ptr)return false;result[count++]=starts[i].ptr+offset;}}
    return true;
}
// Historical occupied-table counts: never reap while freezing failure evidence.
static uint32_t occupiedViews(const Context& c,uint64_t heap=0){
    return c.views.occupied(heap);
}
static void copyEntryHeaps(const Context& c,BeamRTResourceCopyFailure& out){
    out.entryViews=occupiedViews(c);
    for(const auto& h:c.heaps)if(h.life){auto& dst=out.heaps[out.heapCount++];
        dst.heapId=h.life->id;dst.cpuBase=h.cpu;dst.descriptorCount=h.count;dst.stride=h.stride;
        dst.type=h.type;dst.visible=h.visible?1u:0u;dst.entryViews=occupiedViews(c,h.life->id);dst.aliveAtEntry=live(h.life)?1u:0u;}
}
static void copyClearedHeaps(const Context& c,BeamRTResourceCopyFailure& out){
    out.afterClearViews=occupiedViews(c);
    for(unsigned i=0;i<out.heapCount;++i)out.heaps[i].afterClearViews=occupiedViews(c,out.heaps[i].heapId);
}
static void freezeCopyFailure(Context& c,BeamRTResourceCopyFailure& pending,UINT failedLane){
    if(c.copyFailure.present || !beamrtResourceStorageCapacityKind(c.firstFailure.kind)
        || c.firstFailure.method!=c.method || (c.method!=BeamRTResourceMethodCopySimple && c.method!=BeamRTResourceMethodCopyRanges))return;
    pending.present=1;pending.failedLane=failedLane;pending.appliedLanes=failedLane;pending.firstFailure=c.firstFailure;
    pending.storageFailure=c.storageFailure;
    for(unsigned i=0;i<pending.heapCount;++i)pending.heaps[i].failureViews=occupiedViews(c,pending.heaps[i].heapId);
    c.copyFailure=pending;
}
static void copied(Context& c,UINT dn,const D3D12_CPU_DESCRIPTOR_HANDLE* ds,const UINT* dz,UINT sn,const D3D12_CPU_DESCRIPTOR_HANDLE* ss,const UINT* sz,D3D12_DESCRIPTOR_HEAP_TYPE type){
    if(type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV && type!=D3D12_DESCRIPTOR_HEAP_TYPE_RTV)return;
    auto& pending=c.pendingCopy;pending={};pending.bytes=sizeof(pending);pending.abi=beamrtResourceCopyFailureABI;
    pending.mode=c.mode;pending.profile=c.profile;pending.method=c.method;pending.descriptorType=type;pending.callerThread=GetCurrentThreadId();
    pending.destinationRanges=dn;pending.sourceRanges=sn;pending.descriptorStride=c.device->GetDescriptorHandleIncrementSize(type);
    // Simple has a direct count, not caller-supplied size arrays. The shared
    // flatten helper still normalizes it to one range with that effective count.
    pending.destinationSizesExplicit=c.method==BeamRTResourceMethodCopyRanges && dz?1u:0u;
    pending.sourceSizesExplicit=c.method==BeamRTResourceMethodCopyRanges && sz?1u:0u;
    std::array<uint64_t,beamrtResourceCopyLimit> dst{},src{};UINT dc=0,sc=0;
    if(!flatten(c,dn,ds,dz,type,dst,dc,pending.destinations) || !flatten(c,sn,ss,sz,type,src,sc,pending.sources) || dc!=sc){fail(c,BeamRTResourceFailureCopyExtent);return;}
    pending.laneCount=dc;std::array<BeamRTResourceView,beamrtResourceCopyLimit> values{};reap(c);copyEntryHeaps(c,pending);
    for(UINT i=0;i<dc;++i){
        for(UINT j=0;j<dc;++j)if(dst[i]==src[j] || (i!=j && dst[i]==dst[j])){fail(c,BeamRTResourceFailureCopyAlias);return;}
        auto& lane=pending.lanes[i];lane.sourceCpu=src[i];lane.destinationCpu=dst[i];
        uint64_t index=0;auto h=locate(c,src[i],type,index);
        if(!c.status.healthy)return;
        if(h){lane.sourceHeapKnown=1;lane.sourceVisible=h->visible?1u:0u;lane.sourceHeapId=h->life->id;lane.sourceIndex=index;}
        if(h && !h->visible){find(c,h->life->id,index,values[i]);if(!c.status.healthy)return;}
        lane.source=values[i];
        uint64_t destinationIndex=0;auto destination=locate(c,dst[i],type,destinationIndex);if(!c.status.healthy)return;
        if(destination){lane.destinationHeapKnown=1;lane.destinationVisible=destination->visible?1u:0u;
            lane.destinationHeapId=destination->life->id;lane.destinationIndex=destinationIndex;
            find(c,destination->life->id,destinationIndex,lane.previousDestination);if(!c.status.healthy)return;}
        if(!values[i].resourceId && !tick(c,c.status.unknownCopies))return;
    }
    // Every source is already a value snapshot and all destinations are unique.
    // Release the entire batch's replaced associations before allocating any:
    // a later unknown-source clear can make an otherwise full-table copy fit.
    // The existing observation mutex covers both phases. This is not rollback:
    // a true overflow poisons health and all metadata reads remain refused.
    for(UINT i=0;i<dc;++i){
        clear(c,dst[i],type);if(!c.status.healthy)return;
    }
    copyClearedHeaps(c,pending);
    for(UINT i=0;i<dc;++i){
        if(!tick(c,c.status.serial))return;values[i].revision=c.status.serial;
        write(c,dst[i],type,values[i]);if(!c.status.healthy){freezeCopyFailure(c,pending,i);return;}
    }
}
using CreateHeap=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,const D3D12_DESCRIPTOR_HEAP_DESC*,REFIID,void**);
static HRESULT STDMETHODCALLTYPE createHeap(ID3D12Device* d,const D3D12_DESCRIPTOR_HEAP_DESC* desc,REFIID iid,void** out){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCreateHeap);SetLastError(incoming);const auto result=original<CreateHeap>(d,0)(d,desc,iid,out);LastError e{GetLastError()};
    observe(call,[&](Context& c){if(SUCCEEDED(result) && out && *out){ComPtr<ID3D12DescriptorHeap> h;if(SUCCEEDED(static_cast<IUnknown*>(*out)->QueryInterface(IID_PPV_ARGS(&h))))createdHeap(c,h.Get());else fail(c,BeamRTResourceFailureCreatedIdentity);}});return result;
}
static void STDMETHODCALLTYPE createSRV(ID3D12Device* d,ID3D12Resource* r,const D3D12_SHADER_RESOURCE_VIEW_DESC* v,D3D12_CPU_DESCRIPTOR_HANDLE dst){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCreateSRV);SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12Device*,ID3D12Resource*,const D3D12_SHADER_RESOURCE_VIEW_DESC*,D3D12_CPU_DESCRIPTOR_HANDLE)>(d,1)(d,r,v,dst);LastError e{GetLastError()};
    observe(call,[&](Context& c){srvWritten(c,r,v,dst);});
}
static void STDMETHODCALLTYPE createRTV(ID3D12Device* d,ID3D12Resource* r,const D3D12_RENDER_TARGET_VIEW_DESC* v,D3D12_CPU_DESCRIPTOR_HANDLE dst){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCreateRTV);SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12Device*,ID3D12Resource*,const D3D12_RENDER_TARGET_VIEW_DESC*,D3D12_CPU_DESCRIPTOR_HANDLE)>(d,2)(d,r,v,dst);LastError e{GetLastError()};
    observe(call,[&](Context& c){rtvWritten(c,r,v,dst);});
}
static void STDMETHODCALLTYPE createCBV(ID3D12Device* d,const D3D12_CONSTANT_BUFFER_VIEW_DESC* v,D3D12_CPU_DESCRIPTOR_HANDLE dst){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCreateCBV);SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12Device*,const D3D12_CONSTANT_BUFFER_VIEW_DESC*,D3D12_CPU_DESCRIPTOR_HANDLE)>(d,3)(d,v,dst);LastError e{GetLastError()};
    observe(call,[&](Context& c){clear(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);});
}
static void STDMETHODCALLTYPE createUAV(ID3D12Device* d,ID3D12Resource* r,ID3D12Resource* counter,const D3D12_UNORDERED_ACCESS_VIEW_DESC* v,D3D12_CPU_DESCRIPTOR_HANDLE dst){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCreateUAV);SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12Device*,ID3D12Resource*,ID3D12Resource*,const D3D12_UNORDERED_ACCESS_VIEW_DESC*,D3D12_CPU_DESCRIPTOR_HANDLE)>(d,4)(d,r,counter,v,dst);LastError e{GetLastError()};
    observe(call,[&](Context& c){clear(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);});
}
static void STDMETHODCALLTYPE copySimple(ID3D12Device* d,UINT n,D3D12_CPU_DESCRIPTOR_HANDLE dst,D3D12_CPU_DESCRIPTOR_HANDLE src,D3D12_DESCRIPTOR_HEAP_TYPE type){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCopySimple);SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12Device*,UINT,D3D12_CPU_DESCRIPTOR_HANDLE,D3D12_CPU_DESCRIPTOR_HANDLE,D3D12_DESCRIPTOR_HEAP_TYPE)>(d,5)(d,n,dst,src,type);LastError e{GetLastError()};
    observe(call,[&](Context& c){copied(c,1,&dst,&n,1,&src,&n,type);});
}
static void STDMETHODCALLTYPE copyRanges(ID3D12Device* d,UINT dn,const D3D12_CPU_DESCRIPTOR_HANDLE* ds,const UINT* dz,UINT sn,const D3D12_CPU_DESCRIPTOR_HANDLE* ss,const UINT* sz,D3D12_DESCRIPTOR_HEAP_TYPE type){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCopyRanges);SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12Device*,UINT,const D3D12_CPU_DESCRIPTOR_HANDLE*,const UINT*,UINT,const D3D12_CPU_DESCRIPTOR_HANDLE*,const UINT*,D3D12_DESCRIPTOR_HEAP_TYPE)>(d,6)(d,dn,ds,dz,sn,ss,sz,type);LastError e{GetLastError()};
    observe(call,[&](Context& c){copied(c,dn,ds,dz,sn,ss,sz,type);});
}
static void createdResource(Call& call,HRESULT result,void** out){observe(call,[&](Context& c){
    // Even skipped allocation callbacks retain forwarding, accounting and the
    // overlap guard. Only lifetime/index admission is descriptor-scoped.
    if(c.mode==beamrtResourceDescriptorTextures)return;
    if(SUCCEEDED(result) && out && *out){ComPtr<ID3D12Resource> r;if(SUCCEEDED(static_cast<IUnknown*>(*out)->QueryInterface(IID_PPV_ARGS(&r))))track(c,r.Get());else fail(c,BeamRTResourceFailureCreatedIdentity);}
});}
using Committed=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,const D3D12_HEAP_PROPERTIES*,D3D12_HEAP_FLAGS,const D3D12_RESOURCE_DESC*,D3D12_RESOURCE_STATES,const D3D12_CLEAR_VALUE*,REFIID,void**);
static HRESULT STDMETHODCALLTYPE committed(ID3D12Device* d,const D3D12_HEAP_PROPERTIES* h,D3D12_HEAP_FLAGS f,const D3D12_RESOURCE_DESC* desc,D3D12_RESOURCE_STATES s,const D3D12_CLEAR_VALUE* clearValue,REFIID iid,void** out){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodCommitted);SetLastError(incoming);const auto result=original<Committed>(d,7)(d,h,f,desc,s,clearValue,iid,out);LastError e{GetLastError()};createdResource(call,result,out);return result;
}
using Placed=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,ID3D12Heap*,UINT64,const D3D12_RESOURCE_DESC*,D3D12_RESOURCE_STATES,const D3D12_CLEAR_VALUE*,REFIID,void**);
static HRESULT STDMETHODCALLTYPE placed(ID3D12Device* d,ID3D12Heap* h,UINT64 offset,const D3D12_RESOURCE_DESC* desc,D3D12_RESOURCE_STATES s,const D3D12_CLEAR_VALUE* clearValue,REFIID iid,void** out){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodPlaced);SetLastError(incoming);const auto result=original<Placed>(d,8)(d,h,offset,desc,s,clearValue,iid,out);LastError e{GetLastError()};createdResource(call,result,out);return result;
}
using Reserved=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,const D3D12_RESOURCE_DESC*,D3D12_RESOURCE_STATES,const D3D12_CLEAR_VALUE*,REFIID,void**);
static HRESULT STDMETHODCALLTYPE reserved(ID3D12Device* d,const D3D12_RESOURCE_DESC* desc,D3D12_RESOURCE_STATES s,const D3D12_CLEAR_VALUE* clearValue,REFIID iid,void** out){
    const auto incoming=GetLastError();Call call(d,BeamRTResourceMethodReserved);SetLastError(incoming);const auto result=original<Reserved>(d,9)(d,desc,s,clearValue,iid,out);LastError e{GetLastError()};createdResource(call,result,out);return result;
}
static void* replacements[]={reinterpret_cast<void*>(createHeap),reinterpret_cast<void*>(createSRV),reinterpret_cast<void*>(createRTV),
    reinterpret_cast<void*>(createCBV),reinterpret_cast<void*>(createUAV),reinterpret_cast<void*>(copySimple),reinterpret_cast<void*>(copyRanges),
    reinterpret_cast<void*>(committed),reinterpret_cast<void*>(placed),reinterpret_cast<void*>(reserved)};
static HRESULT exchange(Slot& s,void* expected,void* value,bool& changed){
    changed=false;MEMORY_BASIC_INFORMATION m{};
    if(!VirtualQuery(s.address,&m,sizeof(m)) || m.AllocationBase!=s.table || m.State!=MEM_COMMIT || m.Type!=MEM_IMAGE
        || (m.Protect!=PAGE_READONLY && m.Protect!=PAGE_READWRITE && m.Protect!=PAGE_WRITECOPY))return E_ACCESSDENIED;
    DWORD old=0;if(!VirtualProtect(s.address,sizeof(void*),PAGE_READWRITE,&old))return HRESULT_FROM_WIN32(GetLastError());
    changed=InterlockedCompareExchangePointer(s.address,value,expected)==expected;DWORD unused=0;
    if(!VirtualProtect(s.address,sizeof(void*),old,&unused))return HRESULT_FROM_WIN32(GetLastError());
    return changed?S_OK:HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
}
} // namespace: resource implementation types, not exported ABI
static HRESULT startResources(ID3D12Device* d,uint32_t mode,uint32_t profile=beamrtResourceStorageLegacy){
    if(!d)return E_INVALIDARG;std::lock_guard<std::mutex> setup(control);if(context())return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
    std::unique_ptr<Context> pending(new(std::nothrow) Context(profile));if(!pending)return E_OUTOFMEMORY;auto& c=*pending;c.mode=mode;c.device=d;
    if(FAILED(d->GetDeviceRemovedReason()) || FAILED(c.device.As(&c.identity)))return E_INVALIDARG;
    c.status.bytes=sizeof(c.status);c.status.abi=beamrtResourceStatusABI(profile);c.status.healthy=1;c.status.ownerThread=GetCurrentThreadId();
    c.firstFailure.bytes=sizeof(c.firstFailure);c.firstFailure.abi=beamrtResourceStatusABI(profile);
    c.storageFailure.bytes=sizeof(c.storageFailure);c.storageFailure.abi=2;
    c.copyFailure.bytes=sizeof(c.copyFailure);c.copyFailure.abi=beamrtResourceCopyFailureABI;
    auto resident=pending.release();InterlockedExchangePointer(&published,resident);std::lock_guard<std::mutex> g(resident->mutex);Site site(*resident,BeamRTResourceMethodStart,0);
    for(unsigned i=0;i<10;++i){auto& s=resident->slots[i];s.address=beamrtResourceSDKSlot(d,i);
        if(!s.address || reinterpret_cast<ULONG_PTR>(s.address)%alignof(void*)){fail(*resident,BeamRTResourceFailureHookSlot);return E_INVALIDARG;}
        s.original=*s.address;
        if(!s.original || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(s.address),&s.table)
            || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(s.original),&s.code)){fail(*resident,BeamRTResourceFailureHookModule);return E_ACCESSDENIED;}
        resident->slotsPublished.store(i+1);bool changed=false;const auto result=exchange(s,s.original,replacements[i],changed);s.attached=changed;
        if(changed)++resident->status.attachedSlots;if(FAILED(result)){fail(*resident,BeamRTResourceFailureHookExchange);return result;}
    }
    resident->status.enabled=1;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesStart(ID3D12Device* d){return startResources(d,beamrtResourceAllAllocations);}
extern "C" HRESULT WINAPI BeamRT_ResourcesStartConfigured(ID3D12Device* d,const BeamRTResourceConfig* config){
    if(!config || config->bytes!=sizeof(*config) || config->abi!=beamrtResourceConfigABI || config->reserved
        || config->mode>beamrtResourceDescriptorTextures)return E_INVALIDARG;
    return startResources(d,config->mode);
}
extern "C" HRESULT WINAPI BeamRT_ResourcesStartProfiled(ID3D12Device* d,const BeamRTResourceProfileConfig* config){
    if(!config || config->bytes!=sizeof(*config) || config->abi!=beamrtResourceProfileConfigABI || config->reserved[0] || config->reserved[1]
        || config->mode>beamrtResourceDescriptorTextures || config->profile>beamrtResourceStorageCompact
        || (config->profile==beamrtResourceStorageCompact && config->mode!=beamrtResourceDescriptorTextures))return E_INVALIDARG;
    return startResources(d,config->mode,config->profile);
}
extern "C" HRESULT WINAPI BeamRT_ResourcesStartInterned(ID3D12Device* d,const BeamRTResourceProfileConfig* config){
    if(!config || config->bytes!=sizeof(*config) || config->abi!=beamrtResourceInternedConfigABI
        || config->reserved[0] || config->reserved[1] || config->mode!=beamrtResourceDescriptorTextures
        || config->profile!=beamrtResourceStorageInterned)return E_INVALIDARG;
    return startResources(d,config->mode,config->profile);
}
static bool readable(Context* c){return c && c->status.enabled && c->status.healthy && c->inFlight.load()==0;}
static BeamRTResourceStatus currentStatus(Context& c){
    auto out=c.status;for(const auto& h:c.heaps)if(live(h.life))++out.liveHeaps;
    for(const auto& o:c.objects)if(live(o.life))++out.liveResources;reap(c);
    out.views=c.views.occupied();return out;
}
static HRESULT describe(Context& c,D3D12_CPU_DESCRIPTOR_HANDLE handle,D3D12_DESCRIPTOR_HEAP_TYPE type,BeamRTResourceView& out,uint64_t expectedHeap=0){
    out={};uint64_t index=0;auto h=locate(c,handle.ptr,type,index);if(!h)return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    if(expectedHeap && h->identity!=expectedHeap)return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    if(!find(c,h->life->id,index,out))return HRESULT_FROM_WIN32(c.status.healthy?ERROR_NOT_FOUND:ERROR_NOT_READY);return S_OK;
}
static HRESULT bufferCandidate(Context& c,uint64_t address,uint64_t span,BeamRTBufferCandidate& out){
    out={};if(!address || address%D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT || !span || span>UINT64_MAX-address)return E_INVALIDARG;
    // The descriptor policy intentionally omits allocations. Searching a partial
    // buffer index could conceal another equal-VA allocation and invent uniqueness.
    if(c.mode==beamrtResourceDescriptorTextures)return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    const Object* match=nullptr;
    for(const auto& o:c.objects)if(live(o.life) && o.address && address>=o.address && address-o.address<o.desc.Width && span<=o.desc.Width-(address-o.address)){
        if(match)return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);match=&o;
    }
    if(!match)return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);out.bytes=sizeof(out);out.abi=beamrtResourceABI;out.candidateOnly=1;
    out.resourceId=match->life->id;out.canonicalIdentity=match->identity;out.address=address;out.offset=address-match->address;
    out.availableBytes=match->desc.Width-out.offset;out.resource=match->desc;return S_OK;
}
static bool tokenMatches(Context& c,const BeamRTResourceDrawToken& token){
    if(!token.ticket || token.slot>=beamrtResourceDrawLimit || token.thread!=GetCurrentThreadId())return false;
    const auto& held=c.draws[token.slot];return held.ticket==token.ticket && held.callbacks==token.callbacks && held.thread==token.thread && held.slot==token.slot;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesBeginDraw(BeamRTResourceDrawToken* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return S_FALSE;
    std::lock_guard<std::mutex> g(c->mutex);Site site(*c,BeamRTResourceMethodBeginDraw,c->status.callbacks);if(!readable(c))return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    for(unsigned i=0;i<beamrtResourceDrawLimit;++i)if(!c->draws[i].ticket){
        if(!tick(*c,c->nextDrawTicket))return E_FAIL;
        *out={c->nextDrawTicket,c->status.callbacks,i,GetCurrentThreadId()};c->draws[i]=*out;return S_OK;
    }
    pressure(*c,BeamRTResourceFailureDrawCapacity,beamrtResourceDrawLimit);return E_OUTOFMEMORY;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesCheckpoint(BeamRTResourceCheckpoint* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return S_FALSE;
    std::lock_guard<std::mutex> g(c->mutex);if(!readable(c))return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    *out={sizeof(*out),1,1,GetCurrentThreadId(),c->status.callbacks};return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesCancelDraw(BeamRTResourceDrawToken* token,uint32_t bytes){
    if(!token || bytes!=sizeof(*token))return E_INVALIDARG;const auto value=*token;*token={};if(!value.ticket)return S_FALSE;
    auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);std::lock_guard<std::mutex> g(c->mutex);
    if(!tokenMatches(*c,value))return E_INVALIDARG;c->draws[value.slot]={};return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesFinishDraw(BeamRTResourceDrawToken* token,uint32_t tokenBytes,const BeamRTResourceCheckpoint* outputCheckpoint,uint32_t checkpointBytes,const BeamRTBindingSnapshot* frame,uint32_t frameBytes,
    uint32_t probe,BeamRTResourceDrawObservation* out,uint32_t bytes){
    if(!token || tokenBytes!=sizeof(*token) || !out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};
    if(!frame || frameBytes!=sizeof(*frame) || frame->bytes!=sizeof(*frame) || frame->abi!=1 || !frame->recordedDraw
        || !frame->commandId || !frame->generation || !frame->serial || !frame->renderTargetCount || frame->renderTargetCount>8 || probe>65536)return E_INVALIDARG;
    const auto value=*token;*token={};out->bytes=sizeof(*out);out->abi=beamrtResourceDrawABI;out->attempted=1;out->recordThread=GetCurrentThreadId();
    out->srvCount=6;out->rtvCount=frame->renderTargetCount;out->cbvProbeBytes=probe;out->commandId=frame->commandId;out->generation=frame->generation;
    out->snapshotSerial=frame->serial;out->ticket=value.ticket;out->callbacksBegin=value.callbacks;
    if(outputCheckpoint && checkpointBytes==sizeof(*outputCheckpoint) && outputCheckpoint->bytes==sizeof(*outputCheckpoint)
        && outputCheckpoint->abi==1 && outputCheckpoint->valid==1){out->outputCheckpointValid=1;out->outputThread=outputCheckpoint->thread;out->outputCallbacks=outputCheckpoint->callbacks;}
    out->result=HRESULT_FROM_WIN32(ERROR_NOT_READY);out->cbvResult=S_FALSE;for(auto& h:out->srvResults)h=S_FALSE;for(auto& h:out->rtvResults)h=S_FALSE;
    auto c=context();if(!c)return out->result;std::lock_guard<std::mutex> g(c->mutex);Site site(*c,BeamRTResourceMethodFinishDraw,c->status.callbacks);
    out->status=currentStatus(*c);out->firstFailure=c->firstFailure;out->callbacksEnd=c->status.callbacks;
    out->storage=storageSnapshot(*c);out->storageFailure=c->storageFailure;
    if(!tokenMatches(*c,value)){out->result=E_INVALIDARG;return out->result;}c->draws[value.slot]={};
    if(!readable(c) || value.callbacks!=c->status.callbacks || !out->outputCheckpointValid
        || out->outputThread!=GetCurrentThreadId() || out->outputCallbacks!=value.callbacks)return out->result;
    out->intervalAccepted=1;out->result=S_OK;
    for(unsigned i=0;i<6;++i)out->srvResults[i]=describe(*c,{frame->srvCpu[i]},D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,out->srvs[i],frame->srvHeap.identity);
    for(unsigned i=0;i<frame->renderTargetCount;++i)out->rtvResults[i]=describe(*c,{frame->renderTargets[i]},D3D12_DESCRIPTOR_HEAP_TYPE_RTV,out->rtvs[i]);
    if(probe)out->cbvResult=bufferCandidate(*c,frame->cbv,probe,out->cbv);
    out->status=currentStatus(*c);out->firstFailure=c->firstFailure;
    out->storage=storageSnapshot(*c);out->storageFailure=c->storageFailure;
    if(!c->status.healthy){out->intervalAccepted=0;out->result=HRESULT_FROM_WIN32(ERROR_NOT_READY);
        for(auto& v:out->srvs)v={};for(auto& v:out->rtvs)v={};out->cbv={};out->cbvResult=S_FALSE;
        for(auto& h:out->srvResults)h=S_FALSE;for(auto& h:out->rtvResults)h=S_FALSE;return out->result;}
    return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesStatus(BeamRTResourceStatus* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    std::lock_guard<std::mutex> g(c->mutex);*out=currentStatus(*c);return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesFirstFailure(BeamRTResourceFailure* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    std::lock_guard<std::mutex> g(c->mutex);*out=c->firstFailure;return out->kind?S_OK:S_FALSE;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesCopyFailure(BeamRTResourceCopyFailure* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    std::lock_guard<std::mutex> g(c->mutex);*out=c->copyFailure;return out->present?S_OK:S_FALSE;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesDiagnostics(BeamRTResourceDiagnostics* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    std::lock_guard<std::mutex> g(c->mutex);out->status=currentStatus(*c);out->firstFailure=c->firstFailure;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesDiagnosticsProfiled(BeamRTResourceProfileDiagnostics* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    std::lock_guard<std::mutex> g(c->mutex);out->status=currentStatus(*c);out->firstFailure=c->firstFailure;
    out->storage=storageSnapshot(*c);out->storageFailure=c->storageFailure;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_ResourcesDescriptor(D3D12_CPU_DESCRIPTOR_HANDLE handle,D3D12_DESCRIPTOR_HEAP_TYPE type,BeamRTResourceView* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    std::lock_guard<std::mutex> g(c->mutex);Site site(*c,BeamRTResourceMethodDescriptor,c->status.callbacks);
    if(!readable(c))return HRESULT_FROM_WIN32(ERROR_NOT_READY);reap(*c);return describe(*c,handle,type,*out);
}
extern "C" HRESULT WINAPI BeamRT_ResourcesBufferCandidate(uint64_t address,uint64_t span,BeamRTBufferCandidate* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};
    if(!address || address%D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT || !span || span>UINT64_MAX-address)return E_INVALIDARG;
    auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);std::lock_guard<std::mutex> g(c->mutex);
    if(c->mode==beamrtResourceDescriptorTextures)return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    if(!readable(c))return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    return bufferCandidate(*c,address,span,*out);
}
extern "C" HRESULT WINAPI BeamRT_ResourcesDisable(){
    auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);std::lock_guard<std::mutex> g(c->mutex);
    if(c->status.ownerThread!=GetCurrentThreadId())return E_ACCESSDENIED;Site site(*c,BeamRTResourceMethodDisable,c->status.callbacks);c->status.enabled=0;HRESULT first=S_OK;
    for(unsigned i=0;i<c->slotsPublished.load();++i){auto& s=c->slots[i];if(!s.attached)continue;bool changed=false;const auto result=exchange(s,replacements[i],s.original,changed);
        if(changed){s.attached=false;--c->status.attachedSlots;++c->status.restoredSlots;}if(FAILED(result)){fail(*c,BeamRTResourceFailureRestore);if(SUCCEEDED(first))first=result;}}
    // Immutable originals, module leases and CPU session storage remain resident.
    // No heap/resource COM references or GPU allocations are owned by the tracker.
    return first;
}
