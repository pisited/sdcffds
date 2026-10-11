#pragma once
#include <stdint.h>

#ifdef BEAMRT_WORKER_BUILD
#define BEAMRT_API __declspec(dllexport)
#else
#define BEAMRT_API __declspec(dllimport)
#endif

// Offline native GPU worker ABI, NOT a BeamNG loader or renderer attachment.
// Explicit supplied-device or exact-adapter candidate acquisition; no process discovery.
struct BeamRTWorker;
struct BeamRTScene {
    float origin[4], inverseX[4], inverseY[4], inverseZ[4];
    float quantMin[4], quantExtent[4];
    uint32_t counts[4]; // node count, triangle count, triangle pixel offset, reserved
    uint32_t atlas[4];  // width, height, reserved, reserved
    uint32_t materials[16]; // live-policy codes: 1 opaque, 0/2/3 uncertain
};
struct BeamRTRay {
    float origin[3], reach;
    float direction[3], startBias; // unit world direction; distances in world metres
};
struct BeamRTHit { int32_t category; uint32_t visits; };
struct BeamRTDeviceInfo {
    uint32_t luidLow;
    int32_t luidHigh;
    uint32_t acquisition; // 1 supplied device, 2 adapter candidate; NOT game attachment
    uint32_t reserved;
};
// category: 2 definite opaque, 1 uncertain hit, 0 miss, -1 invalid, -2 incomplete.

extern "C" {
BEAMRT_API uint32_t BeamRT_WorkerAbiVersion();
BEAMRT_API const char* BeamRT_WorkerLastError(); // thread-local; copy before next call
BEAMRT_API int BeamRT_WorkerCreate(void* device, const void* computeShader,
                                  uint64_t shaderBytes, BeamRTWorker** output);
// D3D12CreateDevice normally reuses a same-process device for this exact adapter.
// It MAY create a new one if none exists. Explicit candidateCreationAllowed=1
// is required; this never claims the game device was found or changes other devices.
BEAMRT_API int BeamRT_WorkerCreateOnAdapter(uint32_t luidLow, int32_t luidHigh,
    uint32_t candidateCreationAllowed, const void* computeShader,
    uint64_t shaderBytes, BeamRTWorker** output);
BEAMRT_API int BeamRT_WorkerGetDeviceInfo(BeamRTWorker*, BeamRTDeviceInfo*);
// Borrow only an actual valid same-process ID3D12Resource pointer supplied by a
// verified native host. Never guess addresses or pass Lua scene-object pointers.
// Reports canonical COM device identity, not resource role/camera/sync validity.
BEAMRT_API int BeamRT_WorkerDeviceMatchesResource(BeamRTWorker*, void* resource,
                                                 uint32_t* matches);
BEAMRT_API int BeamRT_WorkerUpload(BeamRTWorker*, const BeamRTScene*,
                                  const uint8_t* rgba, uint64_t byteCount);
BEAMRT_API int BeamRT_WorkerTrace(BeamRTWorker*, const BeamRTRay*, uint32_t count,
                                 BeamRTHit* output);
// Synchronous validation API: not a production per-frame CPU readback path.
// 0 success, -1 error. Destroy leaves the pointer intact if GPU retirement fails;
// retry later rather than unloading the DLL with live GPU work.
// The owner must stop/join callers before Destroy; concurrent teardown is invalid.
BEAMRT_API int BeamRT_WorkerDestroy(BeamRTWorker**);
}
