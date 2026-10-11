// v0.065 adds multi-candidate continuation and emitter-aware screen-hit
// weighting while keeping v0.064 controls available for direct A/B tests.
#define BEAMRT_ADAPTIVE_RAY_BUDGET 1
#define BEAMRT_BLUE_NOISE 1
#define BEAMRT_REFINED_HITS 1
#define BEAMRT_SCREEN_DDA 1
#define BEAMRT_HIT_VALIDATION 1
#define BEAMRT_CANDIDATE_CONTINUATION 1
#define BEAMRT_EMISSIVE_SEPARATION 1
#include "beamrtGITraceP_v065_core.hlsl"
