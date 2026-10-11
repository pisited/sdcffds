// v0.056: preserve the optimized v0.052 tracer while correcting material-color
// reconstruction and giving lightinfo its own PostFX target-space UV transform.
#define BEAMRT_DIRECT_DIFFUSE_SOURCE 1
#define BEAMRT_RADIANCE_CLEANUP_V056 1
#define BEAMRT_LIGHTINFO_SLOT3 1
#include "beamrtGITraceP_v052.hlsl"
