// v0.066 makes BeamNG's 128x128 GTAO texture the actual primary GI
// sequence instead of using it merely to perturb the legacy hash RNG.
// giBlueNoiseStrength=0 remains the exact v0.065 sampling path.
#define BEAMRT_ADAPTIVE_RAY_BUDGET 1
#define BEAMRT_BLUE_NOISE 1
#define BEAMRT_TRUE_BLUE_NOISE 1
#define BEAMRT_REFINED_HITS 1
#define BEAMRT_SCREEN_DDA 1
#define BEAMRT_HIT_VALIDATION 1
#define BEAMRT_CANDIDATE_CONTINUATION 1
#define BEAMRT_EMISSIVE_SEPARATION 1
#include "beamrtGITraceP_v065_core.hlsl"
