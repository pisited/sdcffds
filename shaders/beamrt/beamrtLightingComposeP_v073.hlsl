// v0.073 reconstructs GI with both geometry compatibility and accumulated hit
// support. Sparse false hits can no longer normalize into a full-strength glossy
// coating merely because they are the only samples in the reconstruction tap set.
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_CONFIDENCE_AWARE_COMPOSE 1
#define BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE 1
#include "beamrtLightingComposeP_v052.hlsl"
