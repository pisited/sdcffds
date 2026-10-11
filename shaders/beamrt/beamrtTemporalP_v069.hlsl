// v0.069 keeps the receiver-compatible v0.068 temporal clamp and adds a
// real-camera motion fallback for views where the sampled velocity buffer is
// absent, near-zero, or otherwise unsuitable for reliable GI reprojection.
#define BEAMRT_LOW_PATH_RESCUE 1
#define BEAMRT_VARIANCE_GUIDED 1
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_ECHO_HISTORY_GUARD 1
#define BEAMRT_COMPATIBLE_HISTORY_CLAMP 1
#define BEAMRT_CAMERA_MOTION_GUARD 1
#include "beamrtTemporalP_v061.hlsl"
