// v0.030 adds optional isotropic GGX visible-normal directions and correctly
// weighted radiance to the existing authoritative first-surface SSR trace.
// reflectionSamplingMode=0 retains the mirror-ray path and its source math.
#define BEAMRT_REFLECTION_GGX 1
#include "beamrtReflectionTraceP_v029.hlsl"
