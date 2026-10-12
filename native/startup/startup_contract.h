#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <stdint.h>

// Startup presence ONLY. This is not a camera, graphics-device or GI contract.
inline constexpr GUID beamrtStartupGuid={0xbb3966c7,0x2130,0x4dbb,{0x87,0x9b,0x25,0x5f,0x2a,0x80,0x66,0x41}};
inline constexpr uint64_t beamrtStartupMagic=0x4252545354415254ull;
inline constexpr uint32_t beamrtStartupObservationOnly=1;
struct BeamRTStartupPayload {
    uint32_t bytes,abi;
    uint64_t magic;
    uint32_t processId,mode;
    uint64_t receiptEvent;
    uint64_t reserved[2];
};
static_assert(sizeof(void*)==8,"review host supports x64 only; no mixed-bitness helper");
static_assert(sizeof(BeamRTStartupPayload)==48,"startup payload ABI");
inline bool beamrtStartupPayloadValid(const BeamRTStartupPayload* p,DWORD bytes,DWORD processId) {
    return p && bytes==sizeof(*p) && p->bytes==sizeof(*p) && p->abi==1
        && p->magic==beamrtStartupMagic && processId && p->processId==processId
        && p->mode==beamrtStartupObservationOnly && p->receiptEvent && p->receiptEvent!=UINT64_MAX
        && !p->reserved[0] && !p->reserved[1];
}
struct BeamRTStartupStatus {
    uint32_t bytes,abi,attached,processId,attachThread;
    uint32_t captureInstalled,gpuWorkSubmitted,lightingConsumed;
};
