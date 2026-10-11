// v0.064 adds confidence-scored screen-hit validation and permits uncertain
// screen hits to fall through to the world/surfel representation. v0.063 is
// preserved as the exact pre-validation fallback.
#define BEAMRT_ADAPTIVE_RAY_BUDGET 1
#define BEAMRT_BLUE_NOISE 1
#define BEAMRT_REFINED_HITS 1
#define BEAMRT_SCREEN_DDA 1
#define BEAMRT_HIT_VALIDATION 1
#include "beamrtGITraceP_v061.hlsl"
