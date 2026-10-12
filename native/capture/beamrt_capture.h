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
struct BeamRTCaptureConfig {
    const void* shader;uint64_t shaderBytes;
    const void* rootSignature;uint64_t rootSignatureBytes;
    uint32_t kind; // 1 graphics PS, 2 compute CS
    uint32_t tableParameter,inputCount,reserved;
    uint32_t offsets[8]; // SRV indices inside the exact matched root table
    DXGI_FORMAT formats[8]; // UNKNOWN for structured-buffer inputs
    D3D12_SRV_DIMENSION dimensions[8]; // single-mip Texture2D or structured Buffer
};
struct BeamRTCaptureInfo {
    uint64_t submission,recordingGeneration;
    uint32_t count,kind;
    ID3D12Resource* resources[8]; // borrowed until snapshot release
    D3D12_SHADER_RESOURCE_VIEW_DESC views[8];
    // Capture alone does not certify camera data, states, fences or lighting.
    uint32_t cameraVerified,gpuOrderingVerified,lightingConsumed,reserved;
};
struct BeamRTCaptureStatus {
    uint64_t interceptedCalls,matchedCommands,capturedSubmissions;
    uint32_t attached,captureHealthy,snapshotAvailable,reserved;
};
extern "C" {
BEAMRT_CAPTURE_API uint32_t BeamRT_CaptureAbiVersion();
BEAMRT_CAPTURE_API const char* BeamRT_CaptureLastError();
// Before target root/pipeline/heaps/views/list creation; outside DllMain.
// Prototype: one D3D12 API-calling thread, the Start caller. Caller must quiesce
// all API callers for Start/Stop and pass apiCallersQuiescent=1. It cannot be
// inferred from a timer or hooked Present. Other-thread activity poisons capture
// while original API calls continue. NOT a game-ready multi-thread loader.
BEAMRT_CAPTURE_API int BeamRT_CaptureStart(ID3D12Device*,const BeamRTCaptureConfig*,
    uint32_t apiCallersQuiescent,BeamRTCapture**);
BEAMRT_CAPTURE_API int BeamRT_CaptureGetStatus(BeamRTCapture*,BeamRTCaptureStatus*);
BEAMRT_CAPTURE_API int BeamRT_CaptureGetSnapshot(BeamRTCapture*,BeamRTCaptureSnapshot**);
BEAMRT_CAPTURE_API int BeamRT_CaptureReadSnapshot(BeamRTCaptureSnapshot*,BeamRTCaptureInfo*);
BEAMRT_CAPTURE_API void BeamRT_CaptureReleaseSnapshot(BeamRTCaptureSnapshot**);
// Explicit quiescent detach. Failure retains host/hooks: don't unload the DLL.
// Stop does not submit GPU work or release a caller's graphics ownership.
BEAMRT_CAPTURE_API int BeamRT_CaptureStop(BeamRTCapture**,uint32_t apiCallersQuiescent);
}
