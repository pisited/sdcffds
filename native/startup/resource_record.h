#pragma once
#include "resource_tracker.h"
#include "gi_bindings.h"
inline constexpr uint32_t beamrtResourceDrawABI=5;
struct BeamRTResourceCheckpoint {uint32_t bytes,abi,valid,thread;uint64_t callbacks;};
struct BeamRTResourceDrawToken {uint64_t ticket,callbacks;uint32_t slot,thread;};
struct BeamRTResourceDrawObservation {
    uint32_t bytes,abi,attempted,intervalAccepted,recordThread,srvCount,rtvCount,cbvProbeBytes;
    uint64_t commandId,generation,snapshotSerial,ticket,callbacksBegin,callbacksEnd,outputCallbacks;
    HRESULT result,cbvResult,srvResults[6],rtvResults[8];
    BeamRTResourceView srvs[6],rtvs[8];BeamRTBufferCandidate cbv;BeamRTResourceStatus status;
    uint32_t descriptorProvenanceVerified,cbvContentsVerified,cameraVerified,gpuOrderingVerified,lightingConsumed,outputCheckpointValid,outputThread,reserved;
    BeamRTResourceFailure firstFailure;
    BeamRTResourceStorageSnapshot storage;BeamRTResourceStorageFailure storageFailure;
};
static_assert(sizeof(BeamRTResourceDrawToken)==24,"CPU draw-interval token");
static_assert(sizeof(BeamRTResourceDrawObservation)==3000,"CPU resource observation ABI v5 with physical storage evidence");
extern "C" {
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesCheckpoint(BeamRTResourceCheckpoint*,uint32_t);
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesBeginDraw(BeamRTResourceDrawToken*,uint32_t);
// Consumes an exact caller/token once. No lock is held across the native draw.
// Request span is explicit diagnostic metadata, not shader-required CBV size.
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesFinishDraw(BeamRTResourceDrawToken*,uint32_t,const BeamRTResourceCheckpoint*,uint32_t,const BeamRTBindingSnapshot*,uint32_t,
    uint32_t,BeamRTResourceDrawObservation*,uint32_t);
BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourcesCancelDraw(BeamRTResourceDrawToken*,uint32_t);
}
