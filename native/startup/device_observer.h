#pragma once
#include "startup_contract.h"
#include <d3d12.h>
#ifdef BEAMRT_DEVICE_OBSERVER_BUILD
#define BEAMRT_DEVICE_API __declspec(dllexport)
#else
#define BEAMRT_DEVICE_API __declspec(dllimport)
#endif
struct BeamRTDeviceObserver;
struct BeamRTDeviceObservation {
    uint32_t bytes,abi,hookAttached,complete,ownerThread,lastCallerThread;
    uint64_t calls,deviceResults,probes,failedCalls,generation;
    LUID adapterLuid;
    D3D_FEATURE_LEVEL requestedMinimum;
    HRESULT lastResult;
    uint32_t cameraVerified,resourceStateChainVerified,gpuOrderingVerified,lightingConsumed;
};
extern "C" {
// Explicit post-loader host call ONLY. The host must already have loaded D3D12
// and quiesce ALL target/trampoline/control/query callers throughout Start/Stop.
// Counters do not prove quiescence. No BeamNG initialization point is provided.
BEAMRT_DEVICE_API HRESULT WINAPI BeamRT_DeviceObserveStart(uint32_t apiCallersQuiescent,BeamRTDeviceObserver**);
BEAMRT_DEVICE_API HRESULT WINAPI BeamRT_DeviceObserveQuery(BeamRTDeviceObserver*,BeamRTDeviceObservation*,uint32_t bytes);
// Transfers one COM reference; output cleared on rejection. Creation observation
// is NOT render-device selection or discovery of already-existing scene resources.
BEAMRT_DEVICE_API HRESULT WINAPI BeamRT_DeviceObserveAcquire(BeamRTDeviceObserver*,uint64_t expectedGeneration,ID3D12Device**);
// Original Start thread + externally established quiescence. On failure retain
// session/module/hooks; do not unload code. No DllMain or process-exit cleanup.
BEAMRT_DEVICE_API HRESULT WINAPI BeamRT_DeviceObserveStop(BeamRTDeviceObserver**,uint32_t apiCallersQuiescent);
}
