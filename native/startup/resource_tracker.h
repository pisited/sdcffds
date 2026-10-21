#pragma once
#include <d3d12.h>
#include <cstdint>
#include "resource_profile.h"
inline constexpr uint32_t beamrtResourceABI=1;
inline constexpr unsigned beamrtResourceHeapLimit=32,beamrtResourceObjectLimit=128,beamrtResourceViewLimit=256,beamrtResourceCopyLimit=64;
inline constexpr unsigned beamrtResourceDrawLimit=16;
inline constexpr uint32_t beamrtResourceConfigABI=1;
inline constexpr uint32_t beamrtResourceAllAllocations=0,beamrtResourceDescriptorTextures=1;
struct BeamRTResourceConfig {uint32_t bytes,abi,mode,reserved;};
static_assert(sizeof(BeamRTResourceConfig)==16,"explicit resource admission configuration ABI v1");
// Numeric metadata only. Never an ID3D12Resource pointer, lease, state or fence.
struct BeamRTResourceView {
    uint32_t bytes,abi,kind,defaultView;
    uint64_t heapId,resourceId,canonicalIdentity,revision;
    D3D12_RESOURCE_DESC resource;
    D3D12_SHADER_RESOURCE_VIEW_DESC srv;
    D3D12_RENDER_TARGET_VIEW_DESC rtv;
};
struct BeamRTBufferCandidate {
    uint32_t bytes,abi,candidateOnly,reserved;
    uint64_t resourceId,canonicalIdentity,address,offset,availableBytes;
    D3D12_RESOURCE_DESC resource;
};
struct BeamRTResourceStatus {
    uint32_t bytes,abi,enabled,healthy,ownerThread,attachedSlots,restoredSlots,reserved;
    uint64_t callbacks,overlaps,pressure,unknownCopies,serial;
    uint32_t liveHeaps,liveResources,views,reserved2;
};
static_assert(sizeof(BeamRTResourceView)==168,"resource view metadata ABI v1");
static_assert(sizeof(BeamRTBufferCandidate)==112,"observed buffer candidate ABI v1");
static_assert(sizeof(BeamRTResourceStatus)==88,"resource tracker status numeric layout; semantic ABI legacy1/compact2/interned3");
enum BeamRTResourceFailureKind : uint32_t {
    BeamRTResourceFailureNone=0,BeamRTResourceFailureCounterOverflow,
    BeamRTResourceFailureOverlap,BeamRTResourceFailureHeapCapacity,
    BeamRTResourceFailureObjectCapacity,BeamRTResourceFailureViewCapacity,
    BeamRTResourceFailureDrawCapacity,BeamRTResourceFailureMetadataException,
    BeamRTResourceFailureTagPresent,BeamRTResourceFailureTagStore,
    BeamRTResourceFailureResourceIdentity,BeamRTResourceFailureHeapIdentity,
    BeamRTResourceFailureHeapExtent,BeamRTResourceFailureHeapAlias,
    BeamRTResourceFailureDescriptorAlias,BeamRTResourceFailureCopyExtent,
    BeamRTResourceFailureCopyAlias,BeamRTResourceFailureCreatedIdentity,
    BeamRTResourceFailureHookSlot,BeamRTResourceFailureHookModule,
    BeamRTResourceFailureHookExchange,BeamRTResourceFailureRestore,
    BeamRTResourceFailureViewPayloadCapacity,BeamRTResourceFailureViewByteCapacity,
    BeamRTResourceFailureViewHeapCapacity,
    BeamRTResourceFailureKindCount
};
enum BeamRTResourceMethod : uint32_t {
    BeamRTResourceMethodNone=0,BeamRTResourceMethodCreateHeap,BeamRTResourceMethodCreateSRV,
    BeamRTResourceMethodCreateRTV,BeamRTResourceMethodCreateCBV,BeamRTResourceMethodCreateUAV,
    BeamRTResourceMethodCopySimple,BeamRTResourceMethodCopyRanges,BeamRTResourceMethodCommitted,
    BeamRTResourceMethodPlaced,BeamRTResourceMethodReserved,BeamRTResourceMethodStart,
    BeamRTResourceMethodBeginDraw,BeamRTResourceMethodFinishDraw,BeamRTResourceMethodDescriptor,
    BeamRTResourceMethodDisable,BeamRTResourceMethodCount
};
// First invalidation RECORDED under the metadata mutex, not absolute API-entry
// chronology, peer-call identity, timestamps, a resource lease or GPU proof.
// activeCallbacks is the observed entry count for Overlap, sampled at failure
// otherwise. Counts are bounded CPU table/lifetime observations, not native totals.
// Status/failure ABI is1 for legacy,2 for compact,3 for interned. Storage-capacity
// units are locations/payloads/bytes/heaps; byte attemptedCount is actual demand.
struct BeamRTResourceFailure {
    uint32_t bytes,abi,kind,method;
    uint32_t callerThread,activeCallbacks,capacityLimit,attemptedCount;
    uint64_t callbackOrdinal,observedCallbacks,overlaps,pressure,serial;
    uint32_t liveHeaps,liveResources,views,drawTokens,reserved,reserved2;
};
static_assert(sizeof(BeamRTResourceFailure)==96,"immutable first failure numeric layout; semantic ABI legacy1/compact2/interned3");
struct BeamRTResourceDiagnostics {BeamRTResourceStatus status;BeamRTResourceFailure firstFailure;};
static_assert(sizeof(BeamRTResourceDiagnostics)==184,"paired CPU status/first failure");
struct BeamRTResourceProfileDiagnostics {
    BeamRTResourceStatus status;BeamRTResourceFailure firstFailure;
    BeamRTResourceStorageSnapshot storage;BeamRTResourceStorageFailure storageFailure;
};
static_assert(sizeof(BeamRTResourceProfileDiagnostics)==352,"coherent explicit storage diagnostics");
inline bool beamrtResourceFailureValid(const BeamRTResourceFailure& f,const BeamRTResourceStatus& s,uint32_t profile=beamrtResourceStorageLegacy){
    if(!beamrtResourceStorageProfileValid(profile) || s.abi!=beamrtResourceStatusABI(profile)
        || s.views>beamrtResourceLocationLimit(profile) || f.bytes!=sizeof(f) || f.abi!=beamrtResourceStatusABI(profile)
        || f.kind>=BeamRTResourceFailureKindCount || f.reserved || f.reserved2)return false;
    if(!f.kind)return s.healthy && !f.method && !f.callerThread && !f.activeCallbacks && !f.capacityLimit && !f.attemptedCount
        && !f.callbackOrdinal && !f.observedCallbacks && !f.overlaps && !f.pressure && !f.serial
        && !f.liveHeaps && !f.liveResources && !f.views && !f.drawTokens;
    if(s.healthy || !f.method || f.method>=BeamRTResourceMethodCount || !f.callerThread
        || f.callbackOrdinal>f.observedCallbacks || f.observedCallbacks>s.callbacks || f.overlaps>s.overlaps
        || f.pressure>s.pressure || f.serial>s.serial || f.liveHeaps>beamrtResourceHeapLimit
        || f.liveResources>beamrtResourceObjectLimit || f.views>beamrtResourceLocationLimit(profile) || f.drawTokens>beamrtResourceDrawLimit)return false;
    if(f.kind==BeamRTResourceFailureOverlap && (f.activeCallbacks<2 || !f.callbackOrdinal || !f.overlaps
        || f.method>BeamRTResourceMethodReserved))return false;
    uint32_t limit=0;
    if(f.kind==BeamRTResourceFailureHeapCapacity)limit=beamrtResourceHeapLimit;
    if(f.kind==BeamRTResourceFailureObjectCapacity)limit=beamrtResourceObjectLimit;
    if(f.kind==BeamRTResourceFailureViewCapacity)limit=beamrtResourceLocationLimit(profile);
    if(f.kind==BeamRTResourceFailureViewPayloadCapacity || f.kind==BeamRTResourceFailureViewByteCapacity){
        if(profile==beamrtResourceStorageLegacy)return false;
        limit=f.kind==BeamRTResourceFailureViewPayloadCapacity?beamrtResourceStoragePayloadLimit:beamrtResourceStorageByteLimit;
    }
    if(f.kind==BeamRTResourceFailureViewHeapCapacity){if(profile!=beamrtResourceStorageInterned)return false;limit=32;}
    if(f.kind==BeamRTResourceFailureDrawCapacity)limit=beamrtResourceDrawLimit;
    if(limit && !f.pressure)return false;
    if(f.kind==BeamRTResourceFailureDrawCapacity && f.method!=BeamRTResourceMethodBeginDraw)return false;
    if((f.kind==BeamRTResourceFailureViewCapacity || f.kind==BeamRTResourceFailureViewPayloadCapacity || f.kind==BeamRTResourceFailureViewByteCapacity || f.kind==BeamRTResourceFailureViewHeapCapacity)
        && f.method!=BeamRTResourceMethodCreateSRV && f.method!=BeamRTResourceMethodCreateRTV
        && f.method!=BeamRTResourceMethodCopySimple && f.method!=BeamRTResourceMethodCopyRanges)return false;
    if(f.kind==BeamRTResourceFailureViewByteCapacity)return f.capacityLimit==limit && f.attemptedCount>limit && f.attemptedCount<=limit+beamrtResourceLocationBytes(profile)+160;
    return f.capacityLimit==limit && f.attemptedCount==(limit?limit+1:0);
}
#if defined(BEAMRT_RESOURCE_BUILD) || defined(BEAMRT_RESOURCE_EMBEDDED)
#define BEAMRT_RESOURCE_API __declspec(dllexport)
#else
#define BEAMRT_RESOURCE_API __declspec(dllimport)
#endif
extern "C" {
// Offline candidate only. Explicit outside DllMain, process lifetime, no restart.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesStart(ID3D12Device*);
// Legacy Start keeps all-allocation admission. Configured descriptor mode admits
// only supported SRV/RTV resources in tracked destination heaps. It never evicts
// a live lifetime entry, and deliberately cannot supply buffer/CBV candidates.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesStartConfigured(ID3D12Device*,const BeamRTResourceConfig*);
// Config v1 above and legacy Start never select compact. Config v2 is immutable;
// compact requires descriptor-texture admission, with no CBV inference.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesStartProfiled(ID3D12Device*,const BeamRTResourceProfileConfig*);
// Separate Config ABI3/profile2 gate. Config ABI2 above still accepts only0/1.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesStartInterned(ID3D12Device*,const BeamRTResourceProfileConfig*);
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesStatus(BeamRTResourceStatus*,uint32_t);
// S_FALSE with a typed empty record before failure; immutable after failure,
// including after OFF. Wrong-sized buffers are rejected without writing.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesFirstFailure(BeamRTResourceFailure*,uint32_t);
// Status and first failure read under one mutex for coherent transport pairing.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesDiagnostics(BeamRTResourceDiagnostics*,uint32_t);
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesDiagnosticsProfiled(BeamRTResourceProfileDiagnostics*,uint32_t);
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesDescriptor(D3D12_CPU_DESCRIPTOR_HANDLE,D3D12_DESCRIPTOR_HEAP_TYPE,BeamRTResourceView*,uint32_t);
// Only a unique candidate among OBSERVED buffers. Modern/unobserved allocations,
// aliases, actual CBV span/contents and camera meaning are NOT certified.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesBufferCandidate(uint64_t,uint64_t,BeamRTBufferCandidate*,uint32_t);
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesDisable();
}
