// v0.071 preserves the bounded v0.070 Screen DDA and adds views that separate
// a stable world-space ray direction from view-dependent screen-depth coverage.
#define BEAMRT_ADAPTIVE_RAY_BUDGET 1
#define BEAMRT_BLUE_NOISE 1
#define BEAMRT_TRUE_BLUE_NOISE 1
#define BEAMRT_REFINED_HITS 1
#define BEAMRT_SCREEN_DDA 1
#define BEAMRT_SCREEN_DDA_REPAIR 1
#define BEAMRT_BOUNDED_SCREEN_DDA 1
#define BEAMRT_STABLE_DIAGNOSTIC_RAY 1
#define BEAMRT_DIAGNOSTIC_DIRECTION_VIEWS 1
#define BEAMRT_HIT_VALIDATION 1
#define BEAMRT_CANDIDATE_CONTINUATION 1
#define BEAMRT_EMISSIVE_SEPARATION 1
#include "beamrtGITraceP_v067_core.hlsl"
