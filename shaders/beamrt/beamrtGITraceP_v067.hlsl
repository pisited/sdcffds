// v0.067 repairs the experimental screen-space DDA and makes ray diagnostics
// deterministic. v0.066 remains on disk as the exact accepted fallback.
#define BEAMRT_ADAPTIVE_RAY_BUDGET 1
#define BEAMRT_BLUE_NOISE 1
#define BEAMRT_TRUE_BLUE_NOISE 1
#define BEAMRT_REFINED_HITS 1
#define BEAMRT_SCREEN_DDA 1
#define BEAMRT_SCREEN_DDA_REPAIR 1
#define BEAMRT_HIT_VALIDATION 1
#define BEAMRT_CANDIDATE_CONTINUATION 1
#define BEAMRT_EMISSIVE_SEPARATION 1
#include "beamrtGITraceP_v067_core.hlsl"
