// v0.031 keeps valid black reflection hits distinct from geometric misses.
// Mirror history stores signed receiver depth and has one finite grace frame.
// GGX includes eligible zero estimator samples in spatial/history means;
// positive history depth in that mode records estimator validity, not a hit.
#define BEAMRT_REFLECTION_VALID_BLACK_HITS 1
#define BEAMRT_REFLECTION_GGX_HISTORY 1
#include "beamrtReflectionTemporalP_v025.hlsl"
