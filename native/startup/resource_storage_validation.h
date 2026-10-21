#pragma once
#include "resource_tracker.h"
#include <cstring>
inline bool beamrtResourceStorageCapacityKind(uint32_t kind){
    return kind==BeamRTResourceFailureViewCapacity || kind==BeamRTResourceFailureViewPayloadCapacity || kind==BeamRTResourceFailureViewByteCapacity || kind==BeamRTResourceFailureViewHeapCapacity;
}
inline bool beamrtResourceStorageFailureValid(const BeamRTResourceStorageFailure& e,const BeamRTResourceFailure& f,
    const BeamRTResourceStatus& status,uint32_t profile){
    if(!beamrtResourceFailureValid(f,status,profile) || e.bytes!=sizeof(e) || e.abi!=2 || e.present>1 || e.reserved || e.reserved2)return false;
    if(!f.kind){
        const auto* bytes=reinterpret_cast<const unsigned char*>(&e);
        for(size_t i=8;i<sizeof(e);++i)if(bytes[i])return false;return true;
    }
    const auto& s=e.atFailure;
    if(e.present!=1 || !beamrtResourceStorageSnapshotValid(s,profile) || s.locations!=f.views)return false;
    if(!beamrtResourceStorageCapacityKind(f.kind))return e.cause==beamrtResourceStorageFailureNone
        && !e.attemptedLocations && !e.attemptedPayloads && !e.requiredBytes && !e.attemptedHeaps;
    if(e.attemptedLocations!=s.locations+1 || (e.attemptedPayloads!=s.payloads && e.attemptedPayloads!=s.payloads+1)
        || (profile==beamrtResourceStorageInterned?(e.attemptedHeaps!=s.heaps && e.attemptedHeaps!=s.heaps+1):e.attemptedHeaps!=0)
        || uint64_t(e.requiredBytes)!=uint64_t(s.usedBytes)+s.locationBytes+(e.attemptedPayloads>s.payloads?160:0))return false;
    if(f.kind==BeamRTResourceFailureViewCapacity)return e.cause==beamrtResourceStorageFailureLocations
        && s.locations==s.locationLimit && e.attemptedLocations==f.attemptedCount;
    // Preserve Location -> Heap (interned only) -> Payload -> Bytes precedence.
    // A lower-priority cause cannot conceal an exceeded earlier limit.
    if(e.attemptedLocations>s.locationLimit)return false;
    if(f.kind==BeamRTResourceFailureViewHeapCapacity)return e.cause==beamrtResourceStorageFailureHeaps
        && s.heaps==s.heapLimit && e.attemptedHeaps==s.heapLimit+1 && e.attemptedHeaps==f.attemptedCount;
    if(e.attemptedHeaps>s.heapLimit)return false;
    if(f.kind==BeamRTResourceFailureViewPayloadCapacity)return e.cause==beamrtResourceStorageFailurePayloads
        && s.payloads==s.payloadLimit && e.attemptedPayloads==s.payloadLimit+1 && e.attemptedPayloads==f.attemptedCount;
    return e.cause==beamrtResourceStorageFailureBytes && e.attemptedPayloads<=s.payloadLimit
        && e.requiredBytes>s.byteLimit && e.requiredBytes==f.attemptedCount;
}
inline bool beamrtResourceStorageEvidenceValid(const BeamRTResourceStorageSnapshot& storage,const BeamRTResourceStorageFailure& first,
    const BeamRTResourceFailure& failure,const BeamRTResourceStatus& status,uint32_t profile){
    return beamrtResourceStorageSnapshotValid(storage,profile) && storage.locations==status.views
        && beamrtResourceStorageFailureValid(first,failure,status,profile)
        // Once the outer observer latches a failure, callbacks cannot insert
        // metadata. Only observed dead-ID reaping may reduce current occupancy.
        && (!failure.kind || (storage.locations<=first.atFailure.locations
            && storage.payloads<=first.atFailure.payloads && storage.heaps<=first.atFailure.heaps && storage.usedBytes<=first.atFailure.usedBytes));
}
