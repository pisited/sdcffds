// v0.070 preserves ray-hit confidence through temporal accumulation. Historical
// depth is read from the moments history, leaving TemporalGI alpha available as
// a support signal for confidence-aware reconstruction and composition.
#define BEAMRT_LOW_PATH_RESCUE 1
#define BEAMRT_VARIANCE_GUIDED 1
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_ECHO_HISTORY_GUARD 1
#define BEAMRT_COMPATIBLE_HISTORY_CLAMP 1
#define BEAMRT_CAMERA_MOTION_GUARD 1
#define BEAMRT_PRESERVE_HIT_CONFIDENCE 1
#include "beamrtTemporalP_v061.hlsl"
