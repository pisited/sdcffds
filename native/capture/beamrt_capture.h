#pragma once
#include <stdint.h>
#include <d3d12.h>
#ifdef BEAMRT_CAPTURE_BUILD
#define BEAMRT_CAPTURE_API __declspec(dllexport)
#else
#define BEAMRT_CAPTURE_API __declspec(dllimport)
#endif
// Read-only D3D12 interception prototype. No loader, renderer replacement or
// BeamNG attachment. Real native interfaces only; no Lua/scene pointers.
struct BeamRTCapture;
struct BeamRTCaptureSnapshot;
static const uint32_t BEAMRT_CAPTURE_MAX_VIEWPORTS=16;
static const uint32_t BEAMRT_CAPTURE_MAX_OUTPUTS=8;
static const uint32_t BEAMRT_CAPTURE_MAX_ROOT_VALUES=64;
static const uint32_t BEAMRT_CAPTURE_MAX_TRANSITIONS=32;
enum BeamRTCaptureThreadMode : uint32_t {
    BEAMRT_CAPTURE_SINGLE_THREAD=0,
    BEAMRT_CAPTURE_MULTITHREAD=1
};
struct BeamRTCaptureConfig {
    const void* shader;uint64_t shaderBytes;
    const void* rootSignature;uint64_t rootSignatureBytes;
    uint32_t kind; // 1 graphics PS, 2 compute CS
    uint32_t tableParameter,inputCount,reserved;
    uint32_t offsets[8]; // SRV indices inside the exact matched root table
    DXGI_FORMAT formats[8]; // UNKNOWN for structured-buffer inputs
    D3D12_SRV_DIMENSION dimensions[8]; // single-mip Texture2D or structured Buffer
    uint32_t threadMode,reserved2; // ABI v3; single-thread is the default
};
struct BeamRTCaptureRootValue { uint32_t parameter,offset,value; };
struct BeamRTCaptureRootAddress { uint32_t parameter,reserved;uint64_t address; };
struct BeamRTCaptureTransition {
    ID3D12Resource* resource;
    uint32_t before,after,subresource;
};
struct BeamRTCaptureInfo {
    uint64_t submission,recordingGeneration;
    uint32_t count,kind;
    ID3D12Resource* resources[8]; // borrowed until snapshot release
    D3D12_SHADER_RESOURCE_VIEW_DESC views[8];
    ID3D12CommandQueue* queue; // borrowed until snapshot release; NOT a GPU fence
    uint32_t viewportCount,scissorCount,renderTargetCount,rootValueCount;
    uint32_t rootCbvCount,rootUavCount,transitionCount,contextComplete;
    D3D12_VIEWPORT viewports[BEAMRT_CAPTURE_MAX_VIEWPORTS];
    D3D12_RECT scissors[BEAMRT_CAPTURE_MAX_VIEWPORTS];
    ID3D12Resource* renderTargets[BEAMRT_CAPTURE_MAX_OUTPUTS]; // borrowed until snapshot release
    DXGI_FORMAT renderTargetFormats[BEAMRT_CAPTURE_MAX_OUTPUTS];
    BeamRTCaptureRootValue rootValues[BEAMRT_CAPTURE_MAX_ROOT_VALUES];
    BeamRTCaptureRootAddress rootCbvs[64],rootUavs[64]; // GPU VAs, not copied constant contents
    BeamRTCaptureTransition transitions[BEAMRT_CAPTURE_MAX_TRANSITIONS]; // observed list barriers, not a state-chain proof
    uint64_t queueExecutionSerial,queueEventSerial,queueSignalValue,queueWaitValue;
    ID3D12Fence* queueSignalFence; // borrowed until snapshot release
    ID3D12Fence* queueWaitFence; // borrowed until snapshot release
    // Observation flags only. These never certify engine camera, complete state,
    // cross-queue GPU order or lighting consumption.
    uint32_t resourceStateChainVerified,gpuOrderingVerified,cameraVerified,lightingConsumed;
};
struct BeamRTCaptureStatus {
    uint64_t interceptedCalls,matchedCommands,capturedSubmissions;
    uint32_t attached,captureHealthy,snapshotAvailable,reserved;
    uint32_t threadMode,queueCount;
};
extern "C" {
BEAMRT_CAPTURE_API uint32_t BeamRT_CaptureAbiVersion();
BEAMRT_CAPTURE_API const char* BeamRT_CaptureLastError();
// Before target root/pipeline/heaps/views/list creation; outside DllMain.
// Caller must quiesce ALL API callers for the entire Start/Stop transaction and
// pass apiCallersQuiescent=1. No target/trampoline code may be executing there.
// It cannot be inferred from a timer or hooked Present. Runtime MULTITHREAD mode
// serializes metadata only; it does not manage game threads, queue fences or
// same-list/same-descriptor API races. NOT a game-ready loading mechanism.
BEAMRT_CAPTURE_API int BeamRT_CaptureStart(ID3D12Device*,const BeamRTCaptureConfig*,
    uint32_t apiCallersQuiescent,BeamRTCapture**);
BEAMRT_CAPTURE_API int BeamRT_CaptureGetStatus(BeamRTCapture*,BeamRTCaptureStatus*);
BEAMRT_CAPTURE_API int BeamRT_CaptureGetSnapshot(BeamRTCapture*,BeamRTCaptureSnapshot**);
// Queue-specific historical result. Draw context, barriers and queue events are
// observed metadata only; availability is not freshness or synchronization proof.
BEAMRT_CAPTURE_API int BeamRT_CaptureGetSnapshotForQueue(BeamRTCapture*,ID3D12CommandQueue*,BeamRTCaptureSnapshot**);
BEAMRT_CAPTURE_API int BeamRT_CaptureReadSnapshot(BeamRTCaptureSnapshot*,BeamRTCaptureInfo*);
BEAMRT_CAPTURE_API void BeamRT_CaptureReleaseSnapshot(BeamRTCaptureSnapshot**);
// Explicit quiescent detach. Failure retains host/hooks: don't unload the DLL.
// Stop does not submit GPU work or release a caller's graphics ownership.
BEAMRT_CAPTURE_API int BeamRT_CaptureStop(BeamRTCapture**,uint32_t apiCallersQuiescent);
}
