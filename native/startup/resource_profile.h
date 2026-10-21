#pragma once
#include <cstdint>
inline constexpr uint32_t beamrtResourceStorageLegacy=0,beamrtResourceStorageCompact=1,beamrtResourceStorageInterned=2;
inline constexpr uint32_t beamrtResourceStoragePayloadLimit=256,beamrtResourceStorageByteLimit=47104;
inline constexpr uint32_t beamrtResourceProfileConfigABI=2;
inline constexpr uint32_t beamrtResourceInternedConfigABI=3;
inline bool beamrtResourceStorageProfileValid(uint32_t profile){return profile<=beamrtResourceStorageInterned;}
inline uint32_t beamrtResourceLocationLimit(uint32_t profile){return profile==beamrtResourceStorageLegacy?256u:profile==beamrtResourceStorageCompact?1024u:profile==beamrtResourceStorageInterned?4096u:0u;}
inline uint32_t beamrtResourceLocationBytes(uint32_t profile){return profile==beamrtResourceStorageInterned?14u:24u;}
inline uint32_t beamrtResourceDirectoryBytes(uint32_t profile){return profile==beamrtResourceStorageInterned?512u:0u;}
inline uint32_t beamrtResourceStorageHeapLimit(uint32_t profile){return profile==beamrtResourceStorageInterned?32u:0u;}
// Same numeric layouts, explicit semantic discriminator. Legacy validators must
// reject compact/interned even when their current population is below256.
inline uint32_t beamrtResourceStatusABI(uint32_t profile){return beamrtResourceStorageProfileValid(profile)?profile+1:0;}
struct BeamRTResourceProfileConfig {uint32_t bytes,abi,mode,profile,reserved[2];};
static_assert(sizeof(BeamRTResourceProfileConfig)==24,"profile config numeric layout: ABI2 legacy/compact, ABI3 interned");
struct BeamRTResourceStorageSnapshot {
    uint32_t bytes,abi,profile,locationLimit,payloadLimit,byteLimit,locations,payloads,usedBytes,reserved[3];
    uint32_t directoryBytes,locationBytes,heaps,heapLimit;
};
inline constexpr uint32_t beamrtResourceStorageFailureNone=0,beamrtResourceStorageFailureLocations=1,
    beamrtResourceStorageFailurePayloads=2,beamrtResourceStorageFailureBytes=3,beamrtResourceStorageFailureHeaps=4;
// Immutable sample at the OUTER observer's original first failure, including
// non-storage causes. Current occupancy may later shrink through dead-ID reaping.
struct BeamRTResourceStorageFailure {
    uint32_t bytes,abi,present,cause;BeamRTResourceStorageSnapshot atFailure;
    uint32_t attemptedLocations,attemptedPayloads,requiredBytes,reserved;
    uint32_t attemptedHeaps,reserved2;
};
static_assert(sizeof(BeamRTResourceStorageSnapshot)==64,"explicit physical storage accounting ABI v2");
static_assert(sizeof(BeamRTResourceStorageFailure)==104,"immutable storage first-failure sample ABI v2");
inline bool beamrtResourceStorageSnapshotValid(const BeamRTResourceStorageSnapshot& s,uint32_t profile){
    return beamrtResourceStorageProfileValid(profile) && s.bytes==sizeof(s) && s.abi==2 && s.profile==profile
        && s.locationLimit==beamrtResourceLocationLimit(profile) && s.payloadLimit==beamrtResourceStoragePayloadLimit
        && s.byteLimit==beamrtResourceStorageByteLimit && !s.reserved[0] && !s.reserved[1] && !s.reserved[2]
        && s.locations<=s.locationLimit && s.payloads<=s.payloadLimit && s.payloads<=s.locations
        && ((!s.locations && !s.payloads) || (s.locations && s.payloads))
        && s.directoryBytes==beamrtResourceDirectoryBytes(profile) && s.locationBytes==beamrtResourceLocationBytes(profile)
        && s.heapLimit==beamrtResourceStorageHeapLimit(profile) && s.heaps<=s.heapLimit && s.heaps<=s.locations
        && (profile!=beamrtResourceStorageInterned? !s.heaps : bool(s.locations)==bool(s.heaps))
        && uint64_t(s.usedBytes)==uint64_t(s.directoryBytes)+uint64_t(s.locations)*s.locationBytes+uint64_t(s.payloads)*160
        && s.usedBytes<=s.byteLimit;
}
