#pragma once
#include "resource_tracker.h"
inline constexpr uint32_t beamrtResourceCopyFailureABI=3;
struct BeamRTResourceCopyRange {uint64_t start;uint32_t count,reserved;};
struct BeamRTResourceCopyHeap {
    uint64_t heapId,cpuBase;
    uint32_t descriptorCount,stride,type,visible;
    uint32_t entryViews,afterClearViews,failureViews,aliveAtEntry;
    uint32_t reserved[2];
};
struct BeamRTResourceCopyLane {
    uint64_t sourceCpu,destinationCpu,sourceHeapId,sourceIndex,destinationHeapId,destinationIndex;
    uint32_t sourceHeapKnown,sourceVisible,destinationHeapKnown,destinationVisible;
    BeamRTResourceView source,previousDestination;
};
// Only the first location/heap/payload/byte-capacity failure in a fully snapshotted copy.
// Counts describe occupied CPU associations, not native totals or GPU lifetime.
// Heap summaries include retained retired heap slots; aliveAtEntry is a sample.
// No caller pointers, resource references, states, fences or GPU proof are held.
struct BeamRTResourceCopyFailure {
    uint32_t bytes,abi,present,mode;
    uint32_t method,descriptorType,callerThread,laneCount;
    uint32_t failedLane,appliedLanes,destinationRanges,sourceRanges;
    uint32_t destinationSizesExplicit,sourceSizesExplicit,entryViews,afterClearViews;
    uint32_t heapCount,descriptorStride,reserved[2];
    BeamRTResourceFailure firstFailure;
    BeamRTResourceCopyHeap heaps[beamrtResourceHeapLimit];
    BeamRTResourceCopyRange destinations[beamrtResourceCopyLimit],sources[beamrtResourceCopyLimit];
    BeamRTResourceCopyLane lanes[beamrtResourceCopyLimit];
    uint32_t profile,reservedProfile;BeamRTResourceStorageFailure storageFailure;
};
static_assert(sizeof(BeamRTResourceCopyRange)==16,"bounded copy range ABI v1");
static_assert(sizeof(BeamRTResourceCopyHeap)==56,"bounded copy heap ABI v1");
static_assert(sizeof(BeamRTResourceCopyLane)==400,"bounded copy lane ABI v1");
static_assert(sizeof(BeamRTResourceCopyFailure)==29728,"first copy-capacity topology ABI v3 with physical storage evidence");
extern "C" {
// Before Start: NOT_READY and cleared output. Started but no applicable first
// failure: S_FALSE, typed empty. Captured: S_OK, immutable including after OFF.
// Wrong-sized/null outputs are rejected without writing. No game resource lease.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesCopyFailure(BeamRTResourceCopyFailure*,uint32_t);
}
