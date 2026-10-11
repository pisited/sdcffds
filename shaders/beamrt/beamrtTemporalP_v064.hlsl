// v0.064 keeps the v0.063 variance-guided temporal path and adds a motion-only
// echo guard. Strength zero is the exact v0.063 temporal behavior.
#define BEAMRT_LOW_PATH_RESCUE 1
#define BEAMRT_VARIANCE_GUIDED 1
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_ECHO_HISTORY_GUARD 1
#include "beamrtTemporalP_v061.hlsl"
