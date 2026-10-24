#pragma once
#include "../worker/beamrt_worker.h"
#ifdef BEAMRT_GI_BUILD
#define BEAMRT_GI_API __declspec(dllexport)
#else
#define BEAMRT_GI_API __declspec(dllimport)
#endif

// Native GI resource adapter, NOT a game loader, hook or resource-discovery API.
// All native pointers must be real, live, same-process D3D12 interfaces supplied
// by a verified host. Unknown view/state/producer ordering must retain baseline.
struct BeamRTGIFrame;
struct BeamRTGIInputs {
    void* mesh;      // ID3D12Resource*, full linear RGBA8 packed mesh, 1 mip
    void* receivers; // ID3D12Resource*, full RGBA32_FLOAT receiver export, 1 mip
    uint32_t meshState, receiverState; // known legacy D3D12_RESOURCE_STATES
    BeamRTScene scene; // exactly matched imported instance + live material policy
    uint32_t width,height,surfelCount,reserved;
    float key[4]; // exact positive <=2^24-1 view/frame, geometry, surfel tokens; ABI=1
    float surfels[32][4]; // copied position/radius constants from the owned GI draw
};
extern "C" {
BEAMRT_GI_API uint32_t BeamRT_GIAbiVersion();
BEAMRT_GI_API const char* BeamRT_GILastError();
BEAMRT_GI_API int BeamRT_GICreateFrame(void* device,const void* computeShader,
    uint64_t shaderBytes,const BeamRTGIInputs*,BeamRTGIFrame**);
// Record once on a fresh/dedicated open DIRECT list, with no previous host state
// to restore. Host submits this between matched receiver export and GI consumer
// on the SAME ordered DIRECT queue. No queues/submission/readback/CPU waits here.
BEAMRT_GI_API int BeamRT_GIRecord(BeamRTGIFrame*,void* commandList);
// Borrowed resource + non-shader-visible staging SRV. Copy into the consumer's own
// compatible t5 heap; never bind this compute heap to an original game draw.
BEAMRT_GI_API int BeamRT_GIGetOutput(BeamRTGIFrame*,void** resource,uint64_t* cpuSrv);
// Host records/signals this fence after BOTH native compute and GI consumer.
// Keeping the resource/descriptor/CB lifetime until that completion is required.
BEAMRT_GI_API int BeamRT_GIMarkSubmitted(BeamRTGIFrame*,void* fence,uint64_t value);
// Only if the host reset/discarded the recorded list WITHOUT executing it.
// Never cancel submitted or potentially submitted work to bypass retirement.
BEAMRT_GI_API int BeamRT_GIDiscardRecorded(BeamRTGIFrame*,uint32_t listDiscardConfirmed);
// Nonblocking: fails, retaining the frame/pointer, while in flight or unmarked.
// Stop/join callers first. Device removal permits release; DLL unload does not.
BEAMRT_GI_API int BeamRT_GIDestroyFrame(BeamRTGIFrame**);
}
