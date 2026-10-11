// v0.070 turns screen DDA into a bounded near-field experiment and gives raw
// ray diagnostics a deterministic world-oriented direction. v0.067 remains
// available as the unbounded A/B entry.
#define BEAMRT_ADAPTIVE_RAY_BUDGET 1
#define BEAMRT_BLUE_NOISE 1
#define BEAMRT_TRUE_BLUE_NOISE 1
#define BEAMRT_REFINED_HITS 1
#define BEAMRT_SCREEN_DDA 1
#define BEAMRT_SCREEN_DDA_REPAIR 1
#define BEAMRT_BOUNDED_SCREEN_DDA 1
#define BEAMRT_STABLE_DIAGNOSTIC_RAY 1
#define BEAMRT_HIT_VALIDATION 1
#define BEAMRT_CANDIDATE_CONTINUATION 1
#define BEAMRT_EMISSIVE_SEPARATION 1
#include "beamrtGITraceP_v067_core.hlsl"
