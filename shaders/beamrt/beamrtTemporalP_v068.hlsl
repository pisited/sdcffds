// v0.068 keeps the v0.064 variance-guided temporal path and adds a
// geometry-compatible, motion-aware history clamp. echoHistoryGuard=0 keeps
// the previous loose clamp as an A/B fallback.
#define BEAMRT_LOW_PATH_RESCUE 1
#define BEAMRT_VARIANCE_GUIDED 1
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_ECHO_HISTORY_GUARD 1
#define BEAMRT_COMPATIBLE_HISTORY_CLAMP 1
#include "beamrtTemporalP_v061.hlsl"
