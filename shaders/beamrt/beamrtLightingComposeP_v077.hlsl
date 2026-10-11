// v0.087 routes raw GI through the established primary GI input and separates
// direct light, roughness, F0, and estimated reflectance for local inspection.
// Production composition and the tracer remain unchanged.
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_CONFIDENCE_AWARE_COMPOSE 1
#define BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE 1
#define BEAMRT_RECEIVER_REFLECTANCE 1
#define BEAMRT_PREMULTIPLIED_GI_COMPOSE 1
#define BEAMRT_LIGHTING_STAGE_DIAGNOSTICS 1
#define BEAMRT_RAW_DIAGNOSTIC_PRIMARY_INPUT 1
#define BEAMRT_RECEIVER_INPUT_DIAGNOSTICS 1
#include "beamrtLightingComposeP_v052.hlsl"
