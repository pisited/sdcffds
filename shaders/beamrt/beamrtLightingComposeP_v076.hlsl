// v0.085 exposes the actual raw, filtered, receiver, and visible indirect
// terms while keeping the production GI pipeline running for local captures.
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_CONFIDENCE_AWARE_COMPOSE 1
#define BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE 1
#define BEAMRT_RECEIVER_REFLECTANCE 1
#define BEAMRT_PREMULTIPLIED_GI_COMPOSE 1
#define BEAMRT_LIGHTING_STAGE_DIAGNOSTICS 1
#include "beamrtLightingComposeP_v052.hlsl"
