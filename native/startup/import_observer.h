#pragma once
#include "startup_contract.h"
#include <d3d12.h>
inline constexpr GUID beamrtImportGuid={0x5be24276,0x50ad,0x4397,{0x9a,0xc7,0x16,0x39,0x21,0x60,0xac,0xed}};
inline constexpr uint64_t beamrtImportMagic=0x425254494d504f52ull;
struct BeamRTImportPayload {
    uint32_t bytes,abi;
    uint64_t magic;
    uint32_t processId,initialThread;
    uint64_t receiptEvent,statusMapping;
    uint32_t reserved[2];
};
static_assert(sizeof(BeamRTImportPayload)==48,"import payload layout");
inline bool beamrtImportPayloadValid(const BeamRTImportPayload* p,DWORD bytes,DWORD pid,DWORD tid) {
    return p && bytes==sizeof(*p) && p->bytes==sizeof(*p) && p->abi==1 && p->magic==beamrtImportMagic
        && pid && tid && p->processId==pid && p->initialThread==tid && !p->reserved[0] && !p->reserved[1]
        && p->receiptEvent && p->receiptEvent!=UINT64_MAX && p->statusMapping && p->statusMapping!=UINT64_MAX;
}
struct BeamRTImportObservation {
    uint32_t bytes,abi,processId,ownerThread,hookAttached,complete,candidateReady,disabled;
    uint32_t slotRva,protectionRestored,lastCallerThread,slotRestored;
    HRESULT installResult,lastResult;
    uint64_t calls,deviceResults,probes,failedCalls;
    LUID adapterLuid;
    D3D_FEATURE_LEVEL requestedMinimum;
    uint32_t ambiguous;
    uint32_t cameraVerified,resourceStateChainVerified,gpuOrderingVerified,lightingConsumed;
};
static_assert(sizeof(BeamRTImportObservation)==120,"import observation layout");
// Internal, called only outside DLL attach after the one-shot entry is restored.
// Absence of the separate payload is a no-op. Never declares caller quiescence.
HRESULT BeamRT_ImportStartFromPayload();
#ifdef BEAMRT_IMPORT_OBSERVER_BUILD
#define BEAMRT_IMPORT_API __declspec(dllexport)
#else
#define BEAMRT_IMPORT_API __declspec(dllimport)
#endif
extern "C" {
BEAMRT_IMPORT_API HRESULT WINAPI BeamRT_ImportObserveQuery(BeamRTImportObservation*,uint32_t bytes);
// Same-process acquisition of one candidate; NOT render-device selection.
BEAMRT_IMPORT_API HRESULT WINAPI BeamRT_ImportObserveAcquire(uint32_t expectedProcessId,ID3D12Device**);
// Atomically restores only our import slot. Code, original function and bounded
// metadata/device/module leases remain resident until process exit. No hot-unload.
BEAMRT_IMPORT_API HRESULT WINAPI BeamRT_ImportObserveDisable();
}
