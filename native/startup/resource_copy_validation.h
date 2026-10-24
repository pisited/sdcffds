#pragma once
#include "resource_copy_diagnostics.h"
#include "resource_view_validation.h"
#include "resource_storage_validation.h"
#include <array>

inline bool beamrtResourceCopyFailureExpected(const BeamRTResourceFailure& failure){
    return beamrtResourceStorageCapacityKind(failure.kind)
        && (failure.method==BeamRTResourceMethodCopySimple || failure.method==BeamRTResourceMethodCopyRanges);
}

namespace beamrt_resource_copy_validation_detail {
inline bool statusValid(const BeamRTResourceStatus& status,uint32_t profile){
    return beamrtResourceStorageProfileValid(profile) && status.bytes==sizeof(status) && status.abi==beamrtResourceStatusABI(profile) && status.enabled<=1 && status.healthy<=1
        && status.ownerThread && status.attachedSlots<=10 && status.restoredSlots<=10 && status.attachedSlots+status.restoredSlots<=10
        && !status.reserved && !status.reserved2
        && status.liveHeaps<=beamrtResourceHeapLimit && status.liveResources<=beamrtResourceObjectLimit
        && status.views<=beamrtResourceLocationLimit(profile) && status.serial!=UINT64_MAX;
}
inline bool empty(const BeamRTResourceCopyFailure& copy){
    // Do not construct another 29 KiB object merely to check a typed empty.
    const auto* bytes=reinterpret_cast<const unsigned char*>(&copy);
    for(size_t i=sizeof(copy.bytes)+sizeof(copy.abi);i<sizeof(copy);++i)if(bytes[i])return false;
    return true;
}
inline bool flatten(const BeamRTResourceCopyRange* ranges,uint32_t rangeCount,uint32_t explicitSizes,bool simple,
    uint32_t stride,uint32_t expectedLanes,std::array<uint64_t,beamrtResourceCopyLimit>& addresses){
    uint32_t used=0;
    for(uint32_t i=0;i<beamrtResourceCopyLimit;++i){
        const auto& range=ranges[i];
        if(i>=rangeCount){if(!beamrtResourceZero(range))return false;continue;}
        if(range.reserved || (!simple && !explicitSizes && range.count!=1) || range.count>beamrtResourceCopyLimit-used
            || (range.count && !range.start))return false;
        for(uint32_t j=0;j<range.count;++j){
            const auto offset=uint64_t(j)*stride;if(offset>UINT64_MAX-range.start)return false;
            addresses[used++]=range.start+offset;
        }
    }
    return used==expectedLanes;
}
inline const BeamRTResourceCopyHeap* heap(const BeamRTResourceCopyFailure& copy,uint64_t id){
    for(uint32_t i=0;i<copy.heapCount;++i)if(copy.heaps[i].heapId==id)return &copy.heaps[i];
    return nullptr;
}
inline bool location(const BeamRTResourceCopyFailure& copy,uint64_t cpu,uint64_t id,uint64_t index,uint32_t known,uint32_t visible){
    if(known>1 || visible>1)return false;
    if(!known)return !id && !index && !visible;
    const auto* h=heap(copy,id);
    return h && h->type==copy.descriptorType && h->stride==copy.descriptorStride && h->visible==visible
        && index<h->descriptorCount && cpu==h->cpuBase+index*h->stride;
}
inline bool snapshot(const BeamRTResourceView& view,uint32_t kind,uint64_t heapId,uint64_t failureRevision){
    if(beamrtResourceZero(view))return true;
    // Both values predate this batch's failed write. They are numeric snapshots,
    // not claims that the resource or heap is still alive at a later stage.
    return heapId && beamrtResourceViewValid(view,kind) && view.heapId==heapId && view.revision<failureRevision;
}
}

inline bool beamrtResourceCopyFailureValid(const BeamRTResourceCopyFailure& copy,const BeamRTResourceFailure& failure,
    const BeamRTResourceStatus& status,uint32_t expectedMode,uint32_t expectedProfile=beamrtResourceStorageLegacy){
    using namespace beamrt_resource_copy_validation_detail;
    if(expectedMode>beamrtResourceDescriptorTextures || !statusValid(status,expectedProfile) || !beamrtResourceFailureValid(failure,status,expectedProfile)
        || (expectedProfile!=beamrtResourceStorageLegacy && expectedMode!=beamrtResourceDescriptorTextures)
        || copy.bytes!=sizeof(copy) || copy.abi!=beamrtResourceCopyFailureABI)return false;
    if(!beamrtResourceCopyFailureExpected(failure))return empty(copy);
    if(copy.present!=1 || copy.mode!=expectedMode || copy.method!=failure.method || copy.callerThread!=failure.callerThread
        || !copy.callerThread || !failure.callbackOrdinal || !failure.activeCallbacks || copy.profile!=expectedProfile || copy.reservedProfile
        || !beamrtResourceStorageFailureValid(copy.storageFailure,failure,status,expectedProfile)
        || (copy.descriptorType!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV && copy.descriptorType!=D3D12_DESCRIPTOR_HEAP_TYPE_RTV)
        || !copy.laneCount || copy.laneCount>beamrtResourceCopyLimit || copy.failedLane>=copy.laneCount
        || copy.appliedLanes!=copy.failedLane || !copy.destinationRanges || copy.destinationRanges>beamrtResourceCopyLimit
        || !copy.sourceRanges || copy.sourceRanges>beamrtResourceCopyLimit || copy.destinationSizesExplicit>1 || copy.sourceSizesExplicit>1
        || copy.entryViews>beamrtResourceLocationLimit(expectedProfile) || copy.afterClearViews>copy.entryViews
        || !copy.heapCount || copy.heapCount>beamrtResourceHeapLimit || !copy.descriptorStride || copy.reserved[0] || copy.reserved[1]
        || std::memcmp(&copy.firstFailure,&failure,sizeof(failure)))return false;
    const bool simple=copy.method==BeamRTResourceMethodCopySimple;
    if(simple && (copy.destinationRanges!=1 || copy.sourceRanges!=1 || copy.destinationSizesExplicit || copy.sourceSizesExplicit
        || copy.destinations[0].count!=copy.laneCount || copy.sources[0].count!=copy.laneCount))return false;

    uint32_t entry=0,afterClear=0,atFailure=0,occupiedHeaps=0;
    for(uint32_t i=0;i<beamrtResourceHeapLimit;++i){
        const auto& h=copy.heaps[i];
        if(i>=copy.heapCount){if(!beamrtResourceZero(h))return false;continue;}
        if(!h.heapId || !h.cpuBase || !h.descriptorCount || !h.stride || h.visible>1 || h.aliveAtEntry>1 || h.reserved[0] || h.reserved[1]
            || (h.type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV && h.type!=D3D12_DESCRIPTOR_HEAP_TYPE_RTV)
            || (h.type==D3D12_DESCRIPTOR_HEAP_TYPE_RTV && h.visible)
            || (h.type==copy.descriptorType && h.stride!=copy.descriptorStride)
            || h.entryViews>h.descriptorCount || h.afterClearViews>h.entryViews || h.failureViews>h.descriptorCount
            || h.entryViews>beamrtResourceLocationLimit(expectedProfile) || h.failureViews>beamrtResourceLocationLimit(expectedProfile))return false;
        const auto span=uint64_t(h.descriptorCount)*h.stride;if(span>UINT64_MAX-h.cpuBase)return false;
        for(uint32_t j=0;j<i;++j){const auto& other=copy.heaps[j];
            if(other.heapId==h.heapId)return false;
            if(h.aliveAtEntry && other.aliveAtEntry && h.type==other.type
                && h.cpuBase<other.cpuBase+uint64_t(other.descriptorCount)*other.stride && other.cpuBase<h.cpuBase+span)return false;
        }
        entry+=h.entryViews;afterClear+=h.afterClearViews;atFailure+=h.failureViews;if(h.failureViews)++occupiedHeaps;
    }
    // These are occupied-slot sums. No cross-stage liveness or exact
    // entry-minus-destinations equation is inferred from the observations.
    if(entry!=copy.entryViews || afterClear!=copy.afterClearViews || atFailure!=failure.views)return false;
    if(expectedProfile==beamrtResourceStorageInterned && copy.storageFailure.atFailure.heaps!=occupiedHeaps)return false;
    std::array<uint64_t,beamrtResourceCopyLimit> sourceCpu{},destinationCpu{};
    if(!flatten(copy.sources,copy.sourceRanges,copy.sourceSizesExplicit,simple,copy.descriptorStride,copy.laneCount,sourceCpu)
        || !flatten(copy.destinations,copy.destinationRanges,copy.destinationSizesExplicit,simple,copy.descriptorStride,copy.laneCount,destinationCpu))return false;
    const uint32_t kind=copy.descriptorType==D3D12_DESCRIPTOR_HEAP_TYPE_RTV?2u:1u;
    for(uint32_t i=0;i<beamrtResourceCopyLimit;++i){
        const auto& lane=copy.lanes[i];
        if(i>=copy.laneCount){if(!beamrtResourceZero(lane))return false;continue;}
        if(lane.sourceCpu!=sourceCpu[i] || lane.destinationCpu!=destinationCpu[i]
            || !location(copy,lane.sourceCpu,lane.sourceHeapId,lane.sourceIndex,lane.sourceHeapKnown,lane.sourceVisible)
            || !location(copy,lane.destinationCpu,lane.destinationHeapId,lane.destinationIndex,lane.destinationHeapKnown,lane.destinationVisible)
            || !snapshot(lane.source,kind,lane.sourceHeapId,failure.serial)
            || !snapshot(lane.previousDestination,kind,lane.destinationHeapId,failure.serial)
            || ((!lane.sourceHeapKnown || lane.sourceVisible) && !beamrtResourceZero(lane.source))
            || (!lane.destinationHeapKnown && !beamrtResourceZero(lane.previousDestination)))return false;
        for(uint32_t j=0;j<copy.laneCount;++j)
            if(destinationCpu[i]==sourceCpu[j] || (i!=j && destinationCpu[i]==destinationCpu[j]))return false;
    }
    const auto& failed=copy.lanes[copy.failedLane];
    if(!failed.sourceHeapKnown || failed.sourceVisible || !failed.destinationHeapKnown || beamrtResourceZero(failed.source))return false;
    const auto* destination=heap(copy,failed.destinationHeapId);
    return expectedProfile!=beamrtResourceStorageInterned || (destination
        && copy.storageFailure.attemptedHeaps==occupiedHeaps+(destination->failureViews?0u:1u));
}
