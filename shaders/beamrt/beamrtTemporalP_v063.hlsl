// v0.063 adds persistent first/second luminance moments as an optional guide
// for the accepted temporal + bilateral reconstruction. This is an SVGF-style
// prototype, not a claim of a complete multi-pass SVGF implementation.
#define BEAMRT_LOW_PATH_RESCUE 1
#define BEAMRT_VARIANCE_GUIDED 1
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#include "beamrtTemporalP_v061.hlsl"
