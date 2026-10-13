#pragma once
#include "device_observer.h"
inline constexpr GUID beamrtEntryGuid={0x64c45531,0x0a88,0x4b84,{0xa4,0x9a,0x15,0x25,0x92,0x2e,0x7f,0x5a}};
inline constexpr uint64_t beamrtEntryMagic=0x425254454e545259ull;
struct BeamRTEntryPayload {
    uint32_t bytes,abi;
    uint64_t magic;
    uint32_t processId,initialThread;
    uint64_t receiptEvent;
    uint64_t statusMapping;
    uint32_t expectedEntryRva,reserved;
};
static_assert(sizeof(BeamRTEntryPayload)==48,"entry payload layout");
inline bool beamrtEntryPayloadValid(const BeamRTEntryPayload* p,DWORD bytes,DWORD pid,DWORD tid) {
    return p && bytes==sizeof(*p) && p->bytes==sizeof(*p) && p->abi==1 && p->magic==beamrtEntryMagic
        && pid && tid && p->processId==pid && p->initialThread==tid && p->expectedEntryRva && !p->reserved
        && p->receiptEvent && p->receiptEvent!=UINT64_MAX && p->statusMapping && p->statusMapping!=UINT64_MAX;
}
struct BeamRTEntryStatus {
    uint32_t bytes,abi,armed,reached,released,hookAttached,entryBytesRestored,ownerThread;
    HRESULT result,deviceResult;
    uint32_t deviceStarted,deviceStopped;
    uint32_t graphicsQuiescenceVerified,cameraVerified,gpuOrderingVerified,lightingConsumed;
};
struct BeamRTEntryTestFrame { uint64_t registers[7],flags;uint8_t xmm[96]; };
static_assert(sizeof(BeamRTEntryTestFrame)==160,"defined volatile entry frame");
// Internal arming only, during the opt-in startup attach; not a graphics hook.
HRESULT BeamRT_EntryArmFromPayload();
#ifdef BEAMRT_ENTRY_BUILD
#define BEAMRT_ENTRY_API __declspec(dllexport)
#else
#define BEAMRT_ENTRY_API __declspec(dllimport)
#endif
extern "C" {
BEAMRT_ENTRY_API HRESULT WINAPI BeamRT_EntryQuery(BeamRTEntryStatus*,uint32_t bytes);
BEAMRT_ENTRY_API HRESULT WINAPI BeamRT_EntryGetDeviceObserver(BeamRTDeviceObserver** borrowed);
BEAMRT_ENTRY_API HRESULT WINAPI BeamRT_EntryStopDeviceObserver(uint32_t apiCallersQuiescent);
}
